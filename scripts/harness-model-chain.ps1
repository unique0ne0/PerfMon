# Harness model chain module — model chain resolution, provider health, failure classification, and rate limiting.
# Depends on: harness-io.ps1 (Write-AtomicJson), harness-stage-engine.ps1 (Invoke-StageProcess)
# Caller must provide: $RepoRoot, $LogDir, $TaskId, $StageConfig, $ProfileConfig, $ProviderHealthPath
# Also depends on main dispatcher functions: Resolve-RepoPath, Write-Log, Get-TreeState, Write-StageState

function Get-SwitchableFailureClass {
    param([string]$Tail, [int64]$LogBytes, [double]$ElapsedSeconds, [bool]$TreeChanged, [int64]$LogStartBytes = 0)

    $patterns = @(
        'Insufficient balance',
        'insufficient_quota',
        'insufficient credit',
        'credit balance is too low',
        'quota exceeded',
        'exceeded your current quota',
        'Payment Required'
    )
    foreach ($p in $patterns) {
        if ($Tail -match [regex]::Escape($p)) { return 'billing' }
    }

    $unavailablePatterns = @(
        'only available hosted in China',
        'requires explicit opt in',
        'model not found',
        'Unknown model',
        'No such model',
        'model is not available',
        'invalid api key',
        '401 Unauthorized',
        '403 Forbidden',
        # 맨 '429'는 쓰지 않는다 — 부분 문자열 매칭이라 스택트레이스 줄번호('line 429')·소요시간
        # ('429ms')·바이트수·커밋해시에 걸려 진짜 구현 실패를 모델 전환 사유로 오판했다
        # (2026-08-10 CFG-004 ⑤ 실측). 레이트리밋은 아래 문구형 두 개로 잡는다.
        'HTTP 429',
        'Too Many Requests',
        'rate limit exceeded'
    )
    foreach ($p in $unavailablePatterns) {
        if ($Tail -match [regex]::Escape($p)) { return 'unavailable' }
    }

    # The no-output guard measures bytes written by this attempt, not historical log size.
    # Attempt logs start at zero today; retaining the offset keeps this contract safe if that changes.
    $logGrowth = [math]::Max(0, $LogBytes - $LogStartBytes)
    if ($logGrowth -lt 2KB -and $ElapsedSeconds -lt 60 -and -not $TreeChanged) {
        return 'noop'
    }
    return ''
}

function Resolve-ModelChain {
    param([hashtable]$Config, [string]$Stage)

    # PS 5.1 주의: `$models = if (...) {...} else { @($null) }` 형태로 쓰면 @($null)이
    # 단일 원소 언랩으로 $models 자체가 $null이 되어버린다(2026-08-08 CFG-001 QA 무동작 실측 —
    # while ($modelIndex -lt $models.Count)가 0 -lt 0으로 죽어 프로세스가 아예 안 뜸). 분기 안에서
    # 직접 대입해야 배열이 보존된다.
    # CFG024: qa·integration은 modelCatalog(어댑터 고정, opencode-go/big-pickle식 slash 식별자)가
    # 아니라 profiles(어댑터가 슬롯마다 달라질 수 있는 model-profile 체인)에서 해석되므로 별도 필드로
    # 구분한다 — ModelFallback의 slash-format Assert-ModelIdentifier 검증을 우회하지 않기 위함이다.
    # ContainsKey로 판정하는 이유: 후보가 전부 family 충돌로 걸러지면 @() 빈 배열을 명시적으로 넣어
    # "슬롯 없음"을 뒤 elseif(.Model)로 조용히 새지 않게 만든다(§Done When 4 — 사람 개입 필요 실패).
    if ($config.ContainsKey('ModelChain')) { $models = @($config.ModelChain) } elseif ($config.ModelFallback) { $models = @($config.ModelFallback) } elseif ($config.Model) { $models = @($config.Model) } else { $models = @($null) }

    # -Model: 작업 성격에 맞는 1번 모델을 기획 단계에서 지정한다(예: 리팩토링 위주면 코딩 특화 모델).
    # 폴백 체인의 나머지는 '이 모델/프로바이더가 막혔을 때의 탈출 경로'라 성격과 무관하게 유지해야 하므로,
    # 지정 모델을 맨 앞에 놓고 나머지를 뒤에 붙인다(중복 제거 — 같은 모델을 두 번 부르지 않는다).
    # $script:Model은 최상위 param()의 $Model을 스크립트 스코프에서 읽는 것이다. 별도 대입은 없다.
    # $script: 로 명시하는 이유: 아래 루프가 로컬 $model에 대입하는데 PowerShell 변수명은
    # 대소문자를 구분하지 않아 그 뒤로는 스크립트 파라미터 $Model이 가려진다. 여기선 아직 가려지기
    # 전이지만, 루프 순서가 바뀌면 조용히 잘못된 값을 읽게 되므로 스코프를 못박아 둔다.
    if ($config.ModelFallback -and -not [string]::IsNullOrWhiteSpace($script:Model)) {
        $picked = $script:Model
        $rest = @($config.ModelFallback | Where-Object { $_ -ne $picked })
        $models = @($picked) + $rest
        Write-Log "[$Stage] 1번 모델 override: $picked (폴백: $($rest -join ' → '))" INFO
    }

    if ($Stage -eq 'impl' -and $script:ProviderHealthPath) {
        $health = Read-ProviderHealth -Path $script:ProviderHealthPath
        $filtered = @()
        foreach ($m in $models) {
            $mKey = "model:$m"
            $mEntry = $health.providers.$mKey
            if ($mEntry -and $mEntry.nextProbeAt) {
                [datetime]$nextProbe = [datetime]::MinValue
                if (-not [datetime]::TryParse([string]$mEntry.nextProbeAt, [ref]$nextProbe)) {
                    Write-Log "provider health nextProbeAt is unreadable for $m; ignoring the corrupt cooldown entry" WARN
                } elseif ($nextProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                    Write-Log "[$Stage] preflight skip: $m (cooldown until $($nextProbe.ToUniversalTime().ToString('o')))" INFO
                    continue
                }
            }
            $mCatalog = $null
            if ($script:ProfileConfig.modelCatalog) { $mCatalog = $script:ProfileConfig.modelCatalog.$m }
            if ($mCatalog) {
                $principal = [string]$mCatalog.principal
                $pKey = "principal:$principal"
                $pEntry = $health.providers.$pKey
                if ($pEntry -and $pEntry.nextProbeAt) {
                    [datetime]$pProbe = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$pEntry.nextProbeAt, [ref]$pProbe) -and $pProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                        Write-Log "[$Stage] preflight skip: $m (principal $principal cooldown until $($pProbe.ToUniversalTime().ToString('o')))" INFO
                        continue
                    }
                }
                $rateCap = $null
                if ($script:ProfileConfig.rateLimit -and $script:ProfileConfig.rateLimit.$principal) { $rateCap = $script:ProfileConfig.rateLimit.$principal.maxCallsPerHour }
                if ($rateCap) {
                    $rateCount = Get-CallRateCount -State $health -Principal $principal -WindowMinutes 60
                    if ($rateCount -ge [int]$rateCap) {
                        Write-Log "[$Stage] preflight skip: $m (principal $principal rate limit: $rateCount/$rateCap calls in last 60m)" INFO
                        continue
                    }
                }
            }
            $filtered += $m
        }
        if ($filtered.Count -eq 0) {
            $blockedPrincipals = @()
            foreach ($prop in @($health.providers.psobject.Properties | Where-Object { $_.Name -like 'principal:*' })) {
                $pEntry = $health.providers.($prop.Name)
                if ($pEntry.nextProbeAt) {
                    [datetime]$pProbe = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$pEntry.nextProbeAt, [ref]$pProbe) -and $pProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                        $blockedPrincipals += "$($prop.Name -replace 'principal:','') (until $($pProbe.ToUniversalTime().ToString('o')))"
                    }
                }
            }
            if ($script:ProfileConfig.rateLimit) {
                foreach ($prop in @($script:ProfileConfig.rateLimit.psobject.Properties)) {
                    $rateCap = $prop.Value.maxCallsPerHour
                    if (-not $rateCap) { continue }
                    $rateCount = Get-CallRateCount -State $health -Principal $prop.Name -WindowMinutes 60
                    if ($rateCount -ge [int]$rateCap) {
                        $blockedPrincipals += "$($prop.Name) (rate limit: $rateCount/$rateCap calls in last 60m)"
                    }
                }
            }
            Write-Log "[$Stage] 모든 슬롯이 쿼터/health cooldown 중 — 모델을 띄우지 않고 즉시 실패. Blocked: $($blockedPrincipals -join '; ')" ERROR
            $models = @()
        } else {
            $models = $filtered
            Write-Log "[$Stage] preflight 결과: $($models.Count)개 슬롯 가용 ($($models -join ' → '))" INFO
        }
    }

    # 슬롯은 서로 다른 과금·인증 주체여야 한 슬롯의 장애가 체인 전체를 막지 않는다.
    # -Model override 뒤의 실제 목록으로 검사해 DryRun에서도 구성 실수를 바로 드러낸다.
    $providers = @{}
    for ($i = 0; $i -lt $models.Count; $i++) {
        $candidate = $models[$i]
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -notmatch '/') { continue }
        $provider = $candidate.Split('/')[0]
        if (-not $providers.ContainsKey($provider)) { $providers[$provider] = @() }
        $providers[$provider] += ($i + 1)
    }
    foreach ($provider in $providers.Keys) {
        if ($providers[$provider].Count -gt 1) {
            $slots = ($providers[$provider] | ForEach-Object { "${_}번" }) -join ', '
            Write-Log "⚠️ [$Stage] 폴백 체인에 프로바이더가 중복됩니다: $provider ($slots) — 한쪽이 막히면 같이 막힙니다" WARN
        }
    }

    # Preserve a one-slot chain for stages without ModelFallback. PowerShell unwraps a
    # one-item array on normal return, turning @($null) into $null for the caller.
    return ,$models
}

function Resolve-StageProfileSlots {
    param([string[]]$ProfileNames, [object]$Config, [string[]]$ImplementerFamilies = @(), [string]$Stage)
    $slots = @()
    foreach ($name in $ProfileNames) {
        $p = $Config.profiles.$name
        if ($null -eq $p) { Write-Log "[$Stage] 알 수 없는 프로필 건너뜀: $name" WARN; continue }
        $family = [string]$p.family
        if ($family -and $family -ne 'unknown' -and $ImplementerFamilies -contains $family) {
            Write-Log "[$Stage] 후보 건너뜀: $name (family=$family, 구현자와 동일 — must 위반)" WARN
            continue
        }
        $slots += [pscustomobject]@{ Name = $name; Adapter = [string]$p.adapter; Model = [string]$p.model }
    }
    return ,$slots
}

function Invoke-ModelAttempt {
    param([string]$Stage, [hashtable]$Config, [string]$ToolCmd, [string]$AttemptLog, [string]$LatestLog, [int]$Cycle, [string]$Model)

    $attemptConfig = @{}
    foreach ($key in $Config.Keys) { $attemptConfig[$key] = $Config[$key] }
    $attemptConfig.LogFile = $AttemptLog
    # 시도 시작 시점의 로그 크기를 기록한다. noop 판정이 절대 크기가 아니라 이 시도가 쓴 증가량을
    # 봐야 하므로, 시작 오프셋을 측정해 Classify-AttemptFailure에 넘겨야truncate/공유 로그로 바뀌어도
    # CFG-004의 무산출 안전망이 살아있다. 현재는 매 시도 새 파일이라 항상 0이지만, 계약을 이곳에서 확정한다.
    $attemptLogAbs = Resolve-RepoPath $AttemptLog
    $logStartBytes = if (Test-Path $attemptLogAbs) { (Get-Item $attemptLogAbs).Length } else { 0 }
    if (-not (Update-CallRate -Model $Model)) {
        return @{ Outcome = 'rate_limited'; ExitCode = $null; ElapsedSeconds = 0; LogStartBytes = $logStartBytes; Adapter = $Config.Adapter }
    }
    $exit = $null; $elapsedSeconds = 0
    $outcome = Invoke-StageProcess -Stage $Stage -Config $attemptConfig -ToolCmd $ToolCmd -Cycle $Cycle -ExitCode ([ref]$exit) -ElapsedSeconds ([ref]$elapsedSeconds) -Model $Model
    Update-LatestAttemptLog -AttemptLog $AttemptLog -LatestLog $LatestLog
    return @{ Outcome = $outcome; ExitCode = $exit; ElapsedSeconds = $elapsedSeconds; LogStartBytes = $logStartBytes; Adapter = $Config.Adapter }
}

function Classify-AttemptFailure {
    param([hashtable]$Attempt, [hashtable]$Before, [string]$AttemptLog)

    $outcome = $Attempt.Outcome
    if ($outcome -ne 'ok' -or $null -eq $Attempt.ExitCode) { return $outcome }
    $logAbs = Resolve-RepoPath $AttemptLog
    # CFG018: quoted handoff/test text is never terminal evidence. Only the adapter's parsed
    # stream-json event can put a stage into approval_required.
    $Attempt.ApprovalEvidence = if ($Attempt.Adapter -eq 'antigravity') { Get-AntigravityTerminalEvidence -AttemptLog $AttemptLog } else { $null }
    if ($Attempt.ApprovalEvidence) { return 'approval_required' }
    if ($Attempt.Adapter -eq 'antigravity' -and (Test-AntigravityPrintTimeout -AttemptLog $AttemptLog)) { return 'provider_timeout' }
    if ($Attempt.ExitCode -eq 0) { return $outcome }
    $logBytes = if (Test-Path $logAbs) { (Get-Item $logAbs).Length } else { 0 }
    $tail = if (Test-Path $logAbs) { (Get-Content $logAbs -Tail 40 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
    $afterAttempt = Get-TreeState
    $treeChanged = $null -eq $Before -or $null -eq $afterAttempt -or
        $Before.Head -ne $afterAttempt.Head -or $Before.Dirty -ne $afterAttempt.Dirty
    if (-not $treeChanged) { $treeChanged = $Before.Fingerprint -ne $afterAttempt.Fingerprint }
    $startBytes = if ($Attempt.ContainsKey('LogStartBytes')) { $Attempt.LogStartBytes } else { 0 }
    return (Get-SwitchableFailureClass -Tail $tail -LogBytes $logBytes -ElapsedSeconds $Attempt.ElapsedSeconds -TreeChanged $treeChanged -LogStartBytes $startBytes)
}

function Get-FailureClass {
    param([string]$Outcome)
    if ($Outcome -in @('quota', 'billing', 'authentication', 'pollution', 'approval_required', 'config', 'rate_limited')) {
        return 'deterministic'
    }
    return 'transient'
}

function Get-FailureSignature {
    param([string]$FailureClass, [string]$Adapter, [string]$Reason)
    $cleanReason = if ($Reason) { $Reason } else { 'unknown' }
    $cleanReason = $cleanReason -replace '\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?', ''
    $cleanReason = $cleanReason -replace '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}', ''
    $cleanReason = $cleanReason -replace '\b(?:PID|pid)\s*[:=]?\s*\d+\b', ''
    $cleanReason = $cleanReason -replace '[A-Za-z]:\\[^\s"'']+', ''
    $cleanReason = ($cleanReason -replace '\s+', ' ').Trim()
    if ($cleanReason.Length -gt 60) { $cleanReason = $cleanReason.Substring(0, 60) }
    $safeAdapter = if ($Adapter) { $Adapter } else { 'default' }
    return "${FailureClass}:${safeAdapter}:${cleanReason}"
}

function Resolve-ForceFreeModelChain {
    param(
        [string[]]$ModelFallback,
        [object]$ProfileConfig,
        [bool]$ForceFreeModel
    )
    $shouldForceFree = $ForceFreeModel -or ($ProfileConfig.preferCost -and [string]$ProfileConfig.preferCost -eq 'free')
    if (-not $shouldForceFree) { return @($ModelFallback) }
    $freeModels = @($ModelFallback | Where-Object {
        $ProfileConfig.modelCatalog.$_ -and [string]$ProfileConfig.modelCatalog.$_.cost -eq 'free'
    })
    $sourceLabel = if ($ForceFreeModel) { '-ForceFreeModel' } else { 'preferCost: free' }
    if ($freeModels.Count -eq 0) {
        Write-Log ("⛔ {0} 지정됐지만 modelCatalog에 cost=free 슬롯이 없음 — 원래 체인 유지" -f $sourceLabel) ERROR
        return @($ModelFallback)
    }
    Write-Log ("[impl] {0}: 유료 슬롯 건너뛰고 무료로 직행 ({1})" -f $sourceLabel, ($freeModels -join ' → ')) INFO
    return @($freeModels)
}

function Read-ProviderHealth {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ schemaVersion = 1; providers = [pscustomobject]@{}; callRate = [pscustomobject]@{} } }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.schemaVersion -ne 1 -or $null -eq $state.providers) { throw 'invalid schema' }
        # callRate는 구 상태 파일(rate-limit 도입 이전)에는 없을 수 있다 — 없으면 빈 객체로 채워
        # 하위호환을 유지한다(opencode 시간당 호출 상한).
        if ($null -eq $state.callRate) { $state | Add-Member -NotePropertyName callRate -NotePropertyValue ([pscustomobject]@{}) -Force }
        return $state
    } catch {
        Write-Log "provider health state corrupt; ignoring it until the next classified result: $($_.Exception.Message)" WARN
        return [pscustomobject]@{ schemaVersion = 1; providers = [pscustomobject]@{}; callRate = [pscustomobject]@{} }
    }
}

function Write-ProviderHealth {
    param([string]$Path, [object]$Value)
    Write-AtomicJson -Path $Path -Value $Value -Depth 5
}

function Invoke-WithProviderHealthLock {
    param([scriptblock]$Action)
    $mutex = $null
    $locked = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'ai-agents-harness-provider-health-v1')
        $locked = $mutex.WaitOne(10000)
        if (-not $locked) { throw 'provider health state lock timeout' }
        return (& $Action)
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Update-ProviderHealth {
    param([string]$Model, [string]$Outcome, [string]$AttemptLog)
    if (-not $script:ProviderHealthPath -or $Model -notmatch '^([^/]+)/') { return }
    Invoke-WithProviderHealthLock -Action {
        $provider = $Matches[1]
        $state = Read-ProviderHealth -Path $script:ProviderHealthPath
        if ($null -eq $state.providers) { $state | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force }
        if ($Outcome -eq 'ok') {
            $modelKey = "model:$Model"
            $state.providers.psobject.Properties.Remove($modelKey)
            $principal = if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$Model) { [string]$script:ProfileConfig.modelCatalog.$Model.principal } else { '' }
            if ($principal) {
                $principalKey = "principal:$principal"
                $principalModels = @($state.providers.psobject.Properties | Where-Object { $_.Name -like "model:*" -and [string]$_.Value.principal -eq $principal })
                if ($principalModels.Count -eq 0) { $state.providers.psobject.Properties.Remove($principalKey) }
            }
            Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
            return
        }
        if ($Outcome -notin @('quota', 'billing', 'unavailable')) { return }
        $modelKey = "model:$Model"
        $prior = $state.providers.$modelKey
        $count = if ($prior) { [int]$prior.consecutiveFailures + 1 } else { 1 }
        $hours = if ($count -gt 1) { [int]$script:ProfileConfig.providerCooldown.repeatedQuotaHours } elseif ($Outcome -eq 'unavailable') { 1 } else { [int]$script:ProfileConfig.providerCooldown.quotaDefaultHours }
        $nextProbe = [datetime]::UtcNow.AddHours($hours)
        if ($AttemptLog) {
            $logPath = Resolve-RepoPath $AttemptLog
            if (Test-Path -LiteralPath $logPath) {
                $retry = [regex]::Match((Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue), '(?im)retry-after\s*[:=]\s*(\d+)')
                if ($retry.Success) { $nextProbe = [datetime]::UtcNow.AddSeconds([int]$retry.Groups[1].Value) }
            }
        }
        $entry = [pscustomobject]@{ reason = $Outcome; consecutiveFailures = $count; observedAt = [datetime]::UtcNow.ToString('o'); nextProbeAt = $nextProbe.ToString('o') }
        $state.providers | Add-Member -NotePropertyName $modelKey -NotePropertyValue $entry -Force
        $principal = if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$Model) { [string]$script:ProfileConfig.modelCatalog.$Model.principal } else { '' }
        if ($principal) {
            $principalKey = "principal:$principal"
            $principalModels = @($state.providers.psobject.Properties | Where-Object { $_.Name -like "model:*" -and [string]($state.providers.($_.Name)).reason -in @('quota', 'billing', 'unavailable') })
            if ($principalModels.Count -ge 2) {
                $longestHours = $hours
                foreach ($pm in $principalModels) {
                    $pmEntry = $state.providers.($pm.Name)
                    if ($pmEntry.nextProbeAt) {
                        try {
                            $pmProbe = ([datetime]$pmEntry.nextProbeAt).ToUniversalTime()
                            $diff = ($pmProbe - [datetime]::UtcNow).TotalHours
                            if ($diff -gt $longestHours) { $longestHours = [math]::Ceiling($diff) }
                        } catch { }
                    }
                }
                $principalEntry = [pscustomobject]@{ reason = $Outcome; consecutiveFailures = $count; observedAt = [datetime]::UtcNow.ToString('o'); nextProbeAt = [datetime]::UtcNow.AddHours($longestHours).ToString('o') }
                $state.providers | Add-Member -NotePropertyName $principalKey -NotePropertyValue $principalEntry -Force
            }
        }
        Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
    }
}

function Get-CallRateCount {
    param([object]$State, [string]$Principal, [int]$WindowMinutes = 60)
    if ($null -eq $State.callRate) { return 0 }
    $entry = $State.callRate."principal:$Principal"
    if (-not $entry) { return 0 }
    $cutoff = [datetime]::UtcNow.AddMinutes(-$WindowMinutes)
    $count = 0
    foreach ($ts in @($entry)) {
        [datetime]$parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$ts, [ref]$parsed) -and $parsed.ToUniversalTime() -gt $cutoff) { $count++ }
    }
    return $count
}

function Update-CallRate {
    param([string]$Model)
    if (-not $script:ProviderHealthPath -or $Model -notmatch '^([^/]+)/') { return $true }
    $principal = if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$Model) { [string]$script:ProfileConfig.modelCatalog.$Model.principal } else { '' }
    # rateLimit 설정이 없는 principal은 기록하지 않는다 — 상한 검사에 쓰이지 않을 타임스탬프로
    # 공유 상태 파일(provider-health.json)이 모든 어댑터 호출마다 무한정 커지는 것을 막기 위함이다.
    if (-not $principal -or -not ($script:ProfileConfig.rateLimit -and $script:ProfileConfig.rateLimit.$principal)) { return $true }
    return (Invoke-WithProviderHealthLock -Action {
        $state = Read-ProviderHealth -Path $script:ProviderHealthPath
        $key = "principal:$principal"
        $cutoff = [datetime]::UtcNow.AddMinutes(-60)
        $existing = @($state.callRate.$key) | Where-Object {
            [datetime]$parsed = [datetime]::MinValue
            [datetime]::TryParse([string]$_, [ref]$parsed) -and $parsed.ToUniversalTime() -gt $cutoff
        }
        $rateCap = [int]$script:ProfileConfig.rateLimit.$principal.maxCallsPerHour
        if ($existing.Count -ge $rateCap) {
            Write-Log "[impl] execution skip: $Model (principal $principal rate limit: $($existing.Count)/$rateCap calls in last 60m)" INFO
            return $false
        }
        $updated = @($existing) + @([datetime]::UtcNow.ToString('o'))
        $state.callRate | Add-Member -NotePropertyName $key -NotePropertyValue $updated -Force
        Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
        return $true
    })
}

function Resume-ProviderTimeout {
    param([string]$Stage, [hashtable]$config, $Cycle, $Attempt, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [int]$ContinuationCount, [double]$LogicalHardLimit, [datetime]$LogicalAbsoluteDeadline)

    $conversationId = $null
    $sessionId = $null
    $active = $false
    $withinBudget = (Get-Date) -lt $LogicalAbsoluteDeadline
    $activityWindowMinutes = [Math]::Max(1, [Math]::Round($LogicalHardLimit / 3.0, 2))

    if ($config.Adapter -eq 'antigravity') {
        $conversationId = Get-AntigravityConversationId -AttemptLog $AttemptLog
        $active = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $activityWindowMinutes
    } elseif ($config.Adapter -eq 'opencode') {
        $sessionId = Get-OpencodeSessionId -AttemptLog $AttemptLog
        $active = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $activityWindowMinutes
    } elseif ($config.Adapter -eq 'codex') {
        $sessionId = Get-CodexSessionId -AttemptLog $AttemptLog
        $active = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $activityWindowMinutes
    }

    $canContinue = $false
    $continuationReason = ''
    if ($config.Adapter -eq 'antigravity') {
        $canContinue = $active -and $conversationId -and $ContinuationCount -lt 2 -and $withinBudget
        if (-not $conversationId) { $continuationReason = 'exact conversation ID missing or ambiguous' }
        elseif (-not $active) { $continuationReason = 'no healthy stream-json activity' }
        elseif (-not $withinBudget) { $continuationReason = 'logical absolute deadline reached' }
        elseif ($ContinuationCount -ge 2) { $continuationReason = 'automatic continuation limit reached' }
        else { $continuationReason = 'healthy provider timeout; resume same conversation' }
    } elseif ($config.Adapter -eq 'opencode') {
        $canContinue = $active -and $sessionId -and $ContinuationCount -lt 2 -and $withinBudget
        if (-not $sessionId) { $continuationReason = 'opencode session ID missing or ambiguous' }
        elseif (-not $active) { $continuationReason = 'no healthy log activity' }
        elseif (-not $withinBudget) { $continuationReason = 'logical absolute deadline reached' }
        elseif ($ContinuationCount -ge 2) { $continuationReason = 'automatic continuation limit reached' }
        else { $continuationReason = 'healthy provider timeout; resume same session' }
    } elseif ($config.Adapter -eq 'codex') {
        $canContinue = $active -and $sessionId -and $ContinuationCount -lt 2 -and $withinBudget
        if (-not $sessionId) { $continuationReason = 'codex session ID missing or ambiguous' }
        elseif (-not $active) { $continuationReason = 'no healthy log activity' }
        elseif (-not $withinBudget) { $continuationReason = 'logical absolute deadline reached' }
        elseif ($ContinuationCount -ge 2) { $continuationReason = 'automatic continuation limit reached' }
        else { $continuationReason = 'healthy provider timeout; resume same session' }
    }

    # CFG029 Integration 수정: PowerShell -or는 불리언 $true/$false를 반환하므로 문자열
    # 세션 ID가 그대로 전달되지 않고 "True"/"False"로 뭉개진다. 실제 값을 보존하려면 값 자체를 골라야 한다.
    $recordConversationId = if ($conversationId) { $conversationId } elseif ($sessionId) { $sessionId } else { $null }
    $continuationPath = Write-ContinuationRecord -Stage $Stage -CycleNumber $Cycle.Id -AttemptNumber $AttemptNumber -AttemptLog $AttemptLog -ConversationId $recordConversationId -Active $active -Resumed $canContinue -Reason $continuationReason
    if (-not $canContinue) {
        Write-Log "⛔ [$Stage] provider print timeout 재개 불가: $continuationReason (cycle $($Cycle.Token), 기록: $continuationPath)" ERROR
        return @{ Continue = $false; ContinuationCount = $ContinuationCount; ToolCmd = $null }
    }
    $nextCount = $ContinuationCount + 1
    $toolCmd = if ($config.Adapter -eq 'antigravity') {
        Build-AntigravityContinuationCommand -Config $config -Model $Model -ConversationId $conversationId
    } elseif ($config.Adapter -eq 'opencode') {
        Build-OpencodeContinuationCommand -Config $config -Model $Model -SessionId $sessionId
    } elseif ($config.Adapter -eq 'codex') {
        Build-CodexContinuationCommand -Config $config -Model $Model -SessionId $sessionId
    }
    Write-Log "⏳ [$Stage] provider print timeout 뒤 건강한 동일 세션 자동 재개 $nextCount/2 (cycle $($Cycle.Token), 기록: $continuationPath)" WARN
    return @{ Continue = $true; ContinuationCount = $nextCount; ToolCmd = $toolCmd }
}
