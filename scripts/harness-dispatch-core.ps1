# Harness dispatch core module — main dispatch orchestration, chain control, verify gate, and pipeline management.
# Depends on: harness-io.ps1, harness-lock.ps1, harness-ledger.ps1, harness-verdict.ps1, harness-contracts.ps1
# Depends on: harness-stage-engine.ps1, harness-model-chain.ps1, harness-session-continuation.ps1, model-profile.ps1
# Caller must provide: $RepoRoot, $LogDir, $TaskId, $TaskLogPrefix, $StageConfig, $ProfileConfig, $PipelineRouting
# Caller must provide: $ProviderHealthPath, $RuntimeRoleBinding, $HardTimeoutMinutes, $HangWaitSeconds
# Also depends on main dispatcher functions: Resolve-RepoPath, Write-Log, Get-TreeState, Write-StageState
# Also depends on: Validate-TaskId, Assert-ModelIdentifier, Build-ToolCommand, Resolve-BashExe, Measure-ContextBytes
# Also depends on: Get-SessionHealthRole, Invoke-SessionHealthCheck, Find-PacketByTaskId, New-DispatchCycle

function Test-StageDispatchAllowed {
    param([string]$Stage)
    $blockedMarker = Get-BlockedMarkerPath $Stage
    if (Test-Path -LiteralPath $blockedMarker) {
        $markerText = Get-Content -LiteralPath $blockedMarker -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        return @{ Allowed = $false; Reason = "차단 마커 존재 ($markerText)" }
    }
    $ledger = Read-StageLedger -Stage $Stage
    foreach ($prop in @($ledger.attempts.psobject.Properties)) {
        $sig = $prop.Name
        $entry = $prop.Value
        $fClass = [string]$entry.failureClass
        $cnt = [int]$entry.count
        $max = if ($fClass -eq 'deterministic') { 1 } else { 3 }
        if ($cnt -ge $max) {
            Write-BlockedMarker -Stage $Stage -Reason "시도 한도 도달 (${sig}: ${cnt}회 / 상한 ${max}회)" -OwnerTaskId $TaskId -OwnerProcessId $PID
            return @{ Allowed = $false; Reason = "원장 시도 한도 도달 (${sig}: ${cnt} / ${max})" }
        }
    }
    return @{ Allowed = $true }
}

function Get-PacketFileSnapshot {
    $packetDir = Resolve-RepoPath '.agents/briefs/packets'
    if (-not (Test-Path -LiteralPath $packetDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $packetDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

function Get-RouterTableSnapshot {
    $routerPath = Resolve-RepoPath '.agents/briefs/handoff-log.md'
    if (-not (Test-Path -LiteralPath $routerPath)) { return @{} }
    $rows = @{}
    $lines = Get-Content -LiteralPath $routerPath -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ($line -match '^\s*\|\s*([^|]+)\s*\|') {
            $tId = $Matches[1].Trim()
            if ($tId -and $tId -notmatch '^-+$' -and $tId -ne '작업 ID' -and $tId -ne 'Task ID') {
                $rows[$tId] = $line.Trim()
            }
        }
    }
    return $rows
}

function Test-ProtocolPollution {
    param(
        [string]$Stage,
        [string[]]$PacketsBefore,
        [hashtable]$RouterBefore
    )
    if ($Stage -ne 'impl') { return @{ Polluted = $false } }
    $packetsAfter = Get-PacketFileSnapshot
    $newPackets = @($packetsAfter | Where-Object { $_ -notin $PacketsBefore })
    if ($newPackets.Count -gt 0) {
        $msg = "신규 패킷 파일 생성 감지 ($($newPackets -join ', ')) — 구현 단계 권한 초과"
        Write-Log "❌ [$Stage] $msg" ERROR
        return @{ Polluted = $true; Reason = $msg }
    }
    $routerAfter = Get-RouterTableSnapshot
    foreach ($k in $RouterBefore.Keys) {
        if ($k -eq $TaskId -or $k -eq (Get-NormalizedTaskId $TaskId)) { continue }
        if ($routerAfter.ContainsKey($k) -and $routerAfter[$k] -ne $RouterBefore[$k]) {
            $msg = "타 작업($k) 라우터 행 임의 변경 감지 — 구현 단계 권한 초과"
            Write-Log "❌ [$Stage] $msg" ERROR
            return @{ Polluted = $true; Reason = $msg }
        }
    }
    return @{ Polluted = $false }
}

function Invoke-VerifyGateCore {
    param([string]$Stage, [string]$AttemptLabel)

    Write-Log "검증 게이트(scripts/verify.ps1) 실행${AttemptLabel}..." INFO
    # CFG074: 재시도 시도는 별도 파일에 남긴다 — 같은 경로에 덮어쓰면 최초(스퓨리어스일 수 있는)
    # 실패의 verify.ps1 출력이 재검증 통과와 동시에 사라져, 나중에 CFG-BL-047 근본 원인을
    # 진단할 유일한 증거가 소실된다.
    $verifyLogSuffix = if ($AttemptLabel) { '-retry' } else { '' }
    $verifyLogRel = "$LogDir/$TaskId-verify-$Stage$verifyLogSuffix.log"
    $verifyLogAbs = Resolve-RepoPath $verifyLogRel
    # PS 5.1: 이 파일은 전역이 $ErrorActionPreference='Stop'인데, native 명령의 stderr를 2>&1로
    # 성공 스트림에 합치면 stderr 한 줄마다 NativeCommandError가 terminating error로 승격된다.
    # verify가 exit 0으로 끝나도 하위 프로세스(테스트 러너 등)가 stderr를 한 줄만 쓰면 디스패치
    # 스크립트 전체가 그 자리에서 죽어 — 폴백도 실패 마커도 남지 않는다. 이 호출 구간만 Continue로 낮춘다.
    $verifyOut = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-$TaskId-$Stage-$([guid]::NewGuid().ToString('N')).out")
    $verifyErr = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-$TaskId-$Stage-$([guid]::NewGuid().ToString('N')).err")
    $verifyMinutes = [Math]::Max(5, $HardTimeoutMinutes)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        # See Invoke-StageProcess: keep the verify PowerShell invisible without mixing the
        # incompatible -WindowStyle Hidden and -NoNewWindow parameters on PS 5.1.
        $verifyArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'scripts\verify.ps1'))
        if ($Stage -eq 'integration') { $verifyArgs += '-NoSkip' }
        $verify = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList $verifyArgs -PassThru -RedirectStandardOutput $verifyOut -RedirectStandardError $verifyErr
        $null = $verify.Handle
        if (-not $verify.WaitForExit($verifyMinutes * 60 * 1000)) {
            Stop-ProcessTree $verify.Id
            Write-Log "❌ [$Stage] verify 게이트가 ${verifyMinutes}분 안에 끝나지 않아 종료했습니다" ERROR
            return @{ Success = $false; FailureReason = 'verify 게이트 시간 초과'; Output = @() }
        }
        $verifyExit = $verify.ExitCode
        $verifyEncoding = [Console]::OutputEncoding
        $verifyOutput = @()
        foreach ($capture in @($verifyOut, $verifyErr)) {
            if (-not (Test-Path $capture)) { continue }
            $captureText = [System.IO.File]::ReadAllText($capture, $verifyEncoding)
            if ($captureText.Length -gt 0) { $verifyOutput += ($captureText.TrimEnd("`r", "`n") -split "`r?`n") }
        }
    } finally {
        $ErrorActionPreference = $prevEap
        Remove-Item $verifyOut, $verifyErr -ErrorAction SilentlyContinue
    }
    $verifyOutput | Out-File $verifyLogAbs -Encoding UTF8
    if ($verifyExit -ne 0) {
        Write-Log "❌ [$Stage] 검증 게이트 실패 — verify 로그: $verifyLogRel" ERROR
        Write-Log "마지막 30줄:" WARN
        $verifyOutput | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" }
        return @{ Success = $false; FailureReason = "verify 게이트 실패 ($verifyLogRel)"; Output = $verifyOutput }
    }

    return @{ Success = $true; FailureReason = $null; Output = $verifyOutput }
}

function Invoke-VerifyGate {
    param([string]$Stage)

    $firstResult = Invoke-VerifyGateCore -Stage $Stage -AttemptLabel ''
    if ($firstResult.Success) {
        return @{ Success = $true; FailureReason = $null; Retried = $false; RetryRecovered = $false }
    }

    Write-Log "⚠️ [$Stage] 검증 게이트 최초 실패 — 자동 단독 재검증 시작 (상한 1회, CFG074)" WARN
    $retryResult = Invoke-VerifyGateCore -Stage $Stage -AttemptLabel ' (자동 재검증)'

    if ($retryResult.Success) {
        Write-Log "✅ [$Stage] 검증 게이트 자동 재검증 통과 — 최초 실패는 스퓨리어스로 판단, 정상 진행 (CFG074)" SUCCESS
        return @{ Success = $true; FailureReason = $null; Retried = $true; RetryRecovered = $true }
    }

    Write-Log "❌ [$Stage] 검증 게이트 자동 재검증도 실패 — 진짜 실패로 확정 (CFG074)" ERROR
    return @{ Success = $false; FailureReason = $retryResult.FailureReason; Retried = $true; RetryRecovered = $false }
}

function Get-PacketGateTier {
    param([string]$PacketPath)
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return 'full' }
    $text = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8
    if ($text -match '(?im)^-\s*게이트\s*등급\s*[:：]\s*경량\b') { return 'light' }
    return 'full'
}

function Assert-PlanningChallengeReviewReady {
    param([string]$PacketPath)
    $status = Get-PlanningChallengeReviewStatus -PacketPath $PacketPath
    if (-not $status.Ready) {
        throw "Planning Challenge Review blocks implementation: $($status.Reason) (Decision=$($status.Decision))"
    }
    return $status
}

function Set-PacketCheckboxes {
    param([string]$PacketPath, [int[]]$Indexes, [string]$Annotation)
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return $false }
    $lines = @(Get-Content -LiteralPath $PacketPath -Encoding UTF8)
    $inSection = $false
    $changed = $false
    $circles = '①②③④⑤'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^##\s+Pipeline Status\s*$') { $inSection = $true; continue }
        if ($inSection -and $line -match '^##\s+') { break }
        if (-not $inSection -or $line -notmatch '^\s*-\s*\[([ xX])\]') { continue }
        if ($line -match '^\s*-\s*\[[xX]\]') { continue }
        $stageMatch = [regex]::Match($line, '[①②③④⑤]')
        if (-not $stageMatch.Success) { continue }
        $idx = $circles.IndexOf($stageMatch.Value) + 1
        if ($Indexes -notcontains $idx) { continue }
        $newLine = $line -replace '^(\s*-\s*)\[ \]', '$1[x]'
        if ($Annotation) { $newLine = "$newLine $Annotation" }
        $lines[$i] = $newLine
        $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllLines($PacketPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $changed
}

function Get-StagePipelineIndexes {
    param([string]$Stage)
    switch ($Stage) {
        'impl' { return @(2, 3) }
        'qa' { return @(4) }
        'integration' { return @(5) }
    }
}

function Get-EffectivePipelineStage {
    param([object]$PipelineStatus)
    if ($null -eq $PipelineStatus -or -not $PipelineStatus.HasPipelineStatus -or $null -eq $PipelineStatus.FirstUnchecked) { return $null }
    switch ([int]$PipelineStatus.FirstUnchecked.Index) {
        { $_ -in @(2, 3) } { return 'impl' }
        4 { return 'qa' }
        5 { return 'integration' }
        default { return $null }
    }
}

function Test-PipelineRoleContention {
    param(
        [string]$ImplPrincipal,
        [string]$QaPrincipal,
        [string]$IntegrationPrincipal
    )
    $stages = [ordered]@{
        impl = $ImplPrincipal
        qa = $QaPrincipal
        integration = $IntegrationPrincipal
    }
    $seen = @{}
    $contentions = @()
    foreach ($stageName in $stages.Keys) {
        $p = $stages[$stageName]
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($seen.ContainsKey($p)) {
            $otherStage = $seen[$p]
            $contentions += "$otherStage & $stageName share principal '$p'"
        } else {
            $seen[$p] = $stageName
        }
    }
    if ($contentions.Count -gt 0) {
        return [pscustomobject]@{ Contention = $true; Details = ($contentions -join '; ') }
    }
    return [pscustomobject]@{ Contention = $false; Details = $null }
}

function Show-StageDryRun {
    param([string]$Stage, [hashtable]$Config, [string]$LogRel, [string]$PromptOverride, [string]$Model, [bool]$BypassToolPermissions)

    $toolCmd = Build-ToolCommand -Config $Config -Stage $Stage -PromptOverride $PromptOverride -Model $Model -BypassToolPermissions:$BypassToolPermissions
    Write-Log "작업 $TaskId [$Stage] 디스패치" INFO
    Write-Log "명령: $toolCmd" INFO
    Write-Log "로그: $LogRel" INFO
    $shPath = New-DispatchScript -ToolCmd $toolCmd -LogFile $LogRel -Suffix "dryrun-$TaskId-$Stage"
    try {
        Write-Log "[DryRun] 실행 생략 — 생성될 bash 스크립트:" WARN
        Write-Host ([System.IO.File]::ReadAllText($shPath, [System.Text.UTF8Encoding]::new($false)))
    } finally {
        Remove-Item $shPath -ErrorAction SilentlyContinue
    }
    return @{ Success = $true; FailureReason = $null; QaDispatchedAt = $null }
}

function Initialize-StageDispatch {
    param([string]$Stage, [hashtable]$Config, [string]$LogRel)

    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path $logDirAbs)) { New-Item -ItemType Directory -Path $logDirAbs -Force | Out-Null }
    Initialize-WatcherLog -Stage $Stage
    $cycle = New-DispatchCycle -Stage $Stage
    Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'starting' -ProcessId $PID -EvidencePaths @($LogRel) -Reason 'dispatcher accepted stage' -Model $null
    Write-Log "디스패치 사이클: $($cycle.Token) (id $($cycle.Id))" INFO
    return $cycle
}

function Clear-QaArtifacts {
    param([string]$Stage, [hashtable]$Config)

    if ($Stage -ne 'qa') { return $null }
    foreach ($rel in @($Config.VerdictFile, $Config.ReportFile)) {
        $abs = Resolve-RepoPath $rel
        if (Test-Path $abs) {
            Remove-Item $abs -Force
            Write-Log "이전 실행 산출물 삭제: $rel" INFO
        }
    }
    return (Get-Date)
}

function Invoke-StagePreflightGate {
    param([string]$Stage, [hashtable]$config, $Cycle, [string]$LogRel, $qaDispatchedAt)

    $preflight = Test-AntigravityPreflight -Stage $Stage
    if (-not $preflight.Ready) {
        $reason = "Antigravity preflight 실패: $($preflight.Warnings -join '; ')"
        if (($config.AdapterChain -and $config.AdapterChain.Count -gt 0) -or ($config.AdapterMap -and $config.AdapterMap.Count -gt 1)) {
            Write-Log "⚠️ [$Stage] $reason (AdapterChain 설정됨 — 슬롯별 폴백을 위해 모델 루프 계속 진행)" WARN
        } else {
            Write-Log "❌ [$Stage] $reason" ERROR
            Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $reason -Model $null
            return @{ Abort = $true; Reason = $reason }
        }
    }
    if ($config.Adapter -eq 'antigravity' -and $preflight.Executable) { $config.Executable = $preflight.Executable }
    if ($preflight.Diagnostics.Count -gt 0) { Write-Log "[$Stage] preflight: $($preflight.Diagnostics -join ' | ')" INFO }
    return @{ Abort = $false }
}

function Resolve-SlotAdapter {
    param([hashtable]$config, [string]$Stage, [int]$ModelIndex, [string]$Model, [string]$RepoRoot)

    # impl 체인은 preflight cooldown 필터로 슬롯이 걸러지므로 인덱스 기반 AdapterChain은 필터 후
    # 어긋난다. AdapterMap(모델 식별자 → 어댑터)이 있으면 그쪽을 우선한다.
    if ($config.AdapterMap -and $Model -and $config.AdapterMap.ContainsKey($Model)) {
        $config.Adapter = [string]$config.AdapterMap[$Model]
    } elseif ($config.AdapterChain -and $ModelIndex -lt $config.AdapterChain.Count) {
        $config.Adapter = $config.AdapterChain[$ModelIndex]
    } else {
        return @{ Next = $false; Failure = $null }
    }
    if ($config.Adapter -ne 'antigravity') { return @{ Next = $false; Failure = $null } }
    try {
        $config.ProjectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot
        $slotPreflight = Test-AntigravityPreflight -Stage $Stage
        if ($slotPreflight.Executable) { $config.Executable = $slotPreflight.Executable }
        return @{ Next = $false; Failure = $null }
    } catch {
        $slotReason = "슬롯 $($ModelIndex + 1) antigravity 매핑/preflight 실패: $($_.Exception.Message)"
        Write-Log "⚠️ [$Stage] $slotReason — 다음 슬롯 모델로 전환합니다" WARN
        return @{ Next = $true; Failure = "model $($ModelIndex + 1) ($Model): $slotReason" }
    }
}

function Complete-StageApprovalRequired {
    param([string]$Stage, [hashtable]$config, $Cycle, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [string]$LogRel, $qaDispatchedAt, $Evidence)

    $target = if ($Evidence) { $Evidence.Target } else { $null }
    $targetLabel = if ($target) { $target } elseif ($Evidence) { "null ($($Evidence.TargetExtractionReason))" } else { 'null (structured terminal evidence missing)' }
    $approvalPath = Write-ApprovalRecord -Stage $Stage -CycleNumber $Cycle.Id -AttemptNumber $AttemptNumber -Model $Model -AttemptLog $AttemptLog -Evidence $Evidence
    Write-Log "❌ [$Stage] Antigravity headless 권한 요청 → 승인 대기 (approval_required)" ERROR
    Write-Log "대상 명령: $targetLabel" WARN
    Write-Log "승인 기록: $approvalPath" INFO
    Write-Log "동작: 대상 확인 후 headless 프로세스 밖에서 승인을 마치고, 명시적으로 새 사이클의 fresh 디스패치를 시작하세요." WARN
    Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'approval_required' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $targetLabel -Model $Model
    $null = Record-StageAttempt -Stage $Stage -Signature "deterministic:$($config.Adapter):approval_required" -FailureClass 'deterministic'
    return @{ Success = $false; Outcome = 'approval_required'; ApprovalPath = $approvalPath; QaDispatchedAt = $qaDispatchedAt; CycleId = $Cycle.Id }
}

function Resolve-OutcomeReason {
    param([string]$Outcome)

    if ($Outcome -eq 'hang') { return 'hang' }
    elseif ($Outcome -eq 'timeout') { return '하드 상한 초과' }
    elseif ($Outcome -eq 'provider_timeout') { return 'provider print timeout (자동 재개 한도 또는 건강도 미충족)' }
    elseif ($Outcome -eq 'quota') { return '잔액·쿼터 부족' }
    elseif ($Outcome -eq 'billing') { return '잔액·쿼터 부족' }
    elseif ($Outcome -eq 'rate_limited') { return '사전 시간당 호출 상한 도달' }
    elseif ($Outcome -eq 'authentication') { return '인증 실패' }
    elseif ($Outcome -eq 'unavailable') { return '모델·프로바이더 사용 불가' }
    elseif ($Outcome -eq 'noop') { return '무산출 조기 실패' }
    elseif ($Outcome -eq 'pollution') { return '프로토콜 오염 감지' }
    return '알 수 없는 실행 실패'
}

function Ensure-PreviousSlotCleared {
    param([string]$Stage)

    if (-not $script:ActiveChildProcessId) { return $true }
    try {
        $orphanProc = Get-Process -Id $script:ActiveChildProcessId -ErrorAction SilentlyContinue
        if ($orphanProc -and -not $orphanProc.HasExited) {
            Write-Log "⚠️ [$Stage] 이전 슬롯 프로세스(PID $($script:ActiveChildProcessId)) 정리 및 종료 확인" INFO
            Stop-ProcessTree -ProcessId $script:ActiveChildProcessId
            Start-Sleep -Milliseconds 500
            $checkProc = Get-Process -Id $script:ActiveChildProcessId -ErrorAction SilentlyContinue
            if ($checkProc -and -not $checkProc.HasExited) {
                Write-Log "❌ [$Stage] 프로세스 트리(PID $($script:ActiveChildProcessId)) 종료 확인 실패 — 좀비 방지를 위해 전진하지 않고 중단" ERROR
                return $false
            }
        }
    } catch { }
    $script:ActiveChildProcessId = $null
    return $true
}

function Complete-StageFailure {
    param([string]$Stage, $Cycle, [string]$Outcome, $AttemptFailures, $Before, [string]$Model, [string]$LogRel, $qaDispatchedAt)

    $attemptSummary = if ($AttemptFailures.Count -gt 0) { " (시도별 사유: $($AttemptFailures -join '; '))" } else { '' }
    $failureOutcomes = @{
        hang = @{ Reason = 'hang'; KilledContext = '강제 종료'; ShowLogTail = $false }
        timeout = @{ Reason = '하드 상한 초과'; KilledContext = '하드 상한 초과로 강제 종료'; ShowLogTail = $false }
        provider_timeout = @{ Reason = 'provider print timeout'; KilledContext = $null; ShowLogTail = $true }
        quota = @{ Reason = '잔액·쿼터 부족'; KilledContext = $null; ShowLogTail = $true }
        billing = @{ Reason = '잔액·쿼터 부족'; KilledContext = $null; ShowLogTail = $true }
        authentication = @{ Reason = '인증 실패'; KilledContext = $null; ShowLogTail = $true }
        unavailable = @{ Reason = '모델·프로바이더 사용 불가'; KilledContext = $null; ShowLogTail = $false }
        noop = @{ Reason = '무산출 조기 실패'; KilledContext = $null; ShowLogTail = $false }
        pollution = @{ Reason = 'impl 폴루션 감지'; KilledContext = $null; ShowLogTail = $true }
    }
    if (-not $failureOutcomes.ContainsKey($Outcome)) { return $null }
    $failure = $failureOutcomes[$Outcome]
    $failureMessage = "$($failure.Reason) — 모델 체인 전부 소진, 중단"
    if ($Outcome -in @('quota', 'billing')) { $failureMessage += '. 프로바이더 결제 상태를 확인하세요.' }
    Write-Log "❌ [$Stage] $failureMessage$attemptSummary" ERROR
    $failureReason = "$($failure.Reason) — 모델 체인 전부 소진$attemptSummary"
    if ($failure.KilledContext) {
        Write-KilledLeftover -Before $Before -Stage $Stage -Context $failure.KilledContext
    }
    if ($failure.ShowLogTail) {
        $logAbs = Resolve-RepoPath $LogRel
        if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
    }
    Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $failureReason -Model $Model
    Record-ChainRuntime -Stage $Stage -Model $Model -Status 'failed' -Reason $failureReason
    return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $qaDispatchedAt }
}

function Complete-StageExitFailure {
    param([string]$Stage, $Cycle, $Exit, [string]$LogRel, [string]$Model, $qaDispatchedAt)

    $exitLabel = if ($null -eq $Exit) { '<unknown>' } else { $Exit }
    Write-Log "프로세스 종료 (Exit Code: $exitLabel)" INFO
    if ($null -eq $Exit) {
        Write-Log "⚠️ [$Stage] 종료 코드를 읽지 못함 — 검증 게이트 결과로 판정" WARN
        return $null
    }
    if ($Exit -eq 0) { return $null }
    Write-Log "⚠️ [$Stage] 실패 (Exit $Exit) — 로그 끝부분:" WARN
    $failureReason = "종료 코드 $Exit"
    $logAbs = Resolve-RepoPath $LogRel
    if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
    Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $failureReason -Model $Model
    Record-ChainRuntime -Stage $Stage -Model $Model -Status 'failed' -Reason $failureReason
    return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $qaDispatchedAt }
}

function Warn-UnchangedTree {
    param([string]$Stage, $Before)

    $after = Get-TreeState
    if ($null -eq $Before -or $null -eq $after) { return }
    if (-not $Before.FingerprintOk -or -not $after.FingerprintOk) {
        Write-Log "[$Stage] 작업트리 변경 여부 판정 불가 (지문 계산 실패) — 무변경 경고를 생략합니다" WARN
    } elseif ($Before.Head -eq $after.Head -and $Before.Dirty -eq $after.Dirty -and
              $Before.Fingerprint -eq $after.Fingerprint) {
        Write-Log "⚠️ [$Stage] 작업트리 변경 없음 (HEAD·미커밋 파일 모두 동일) — 이 단계가 실제로 무엇을 했는지 다음 리뷰 단계에서 확인할 것" WARN
    }
}

function Dispatch-Stage {
    param([string]$Stage, [string]$PromptOverride)
    $config = $StageConfig[$Stage]
    $logRel = $config.LogFile

    # 컨텍스트 측정은 순수 관측이다 — 여기서 난 예외로 파이프라인이 멈춰서는 안 된다.
    try { Measure-ContextBytes -Stage $Stage } catch { Write-Log "[context-size] 측정 실패(무시하고 진행): $($_.Exception.Message)" WARN }

    # CFG025: 헤드리스 antigravity는 모든 run_command를 승인 대기로 거부한다. QA는 이미 직접 수정
    # 권한을 가진 신뢰 단계이므로 사용자 승인(2026-08-19)에 따라 항상 --dangerously-skip-permissions를 부여한다.
    if ($Stage -eq 'qa') { $BypassToolPermissions = $true }
    # CFG024: 디스패치 전 원장/차단 마커 검사 — 상한 도달 시 모델을 띄우기 전에 즉시 거부한다.
    $allowed = Test-StageDispatchAllowed -Stage $Stage
    if (-not $allowed.Allowed) {
        $failureReason = "디스패치 거부: $($allowed.Reason)"
        Write-Log "❌ [$Stage] $failureReason" ERROR
        return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $null }
    }

    $models = Resolve-ModelChain -Config $config -Stage $Stage
    if ($models.Count -eq 0) {
        $quotaExhausted = $false
        $blockedPrincipalsList = @()
        # qa/integration의 ModelChain은 Resolve-ProfileChain/Resolve-StageProfileSlots가 정적으로
        # 미리 계산해 채워 넣으며(3370행 부근), 그 계산에는 provider-health.json 쿨다운이 관여하지
        # 않는다 — family 충돌·알 수 없는 프로필로만 비워진다. impl만 Resolve-ModelChain 내부에서
        # 쿨다운으로 필터링되어 0개가 될 수 있으므로(1167행), 쿼터 소진 판정도 impl로 한정한다.
        # 그렇지 않으면 qa/integration의 family 충돌(모델 체인 비어있음)이 무관한 principal의
        # 쿨다운과 우연히 겹칠 때 "쿼터 소진"으로 오분류되어 잘못된 재개 절차를 안내하게 된다.
        if ($Stage -eq 'impl' -and $script:ProviderHealthPath -and (Test-Path -LiteralPath $script:ProviderHealthPath)) {
            try {
                $health = Read-ProviderHealth -Path $script:ProviderHealthPath
                foreach ($prop in @($health.providers.psobject.Properties)) {
                    if ($prop.Name -like 'principal:*') {
                        $pEntry = $prop.Value
                        if ($pEntry.nextProbeAt) {
                            [datetime]$pProbe = [datetime]::MinValue
                            if ([datetime]::TryParse([string]$pEntry.nextProbeAt, [ref]$pProbe) -and $pProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                                $quotaExhausted = $true
                                $blockedPrincipalsList += "$($prop.Name -replace 'principal:','') (until $($pProbe.ToUniversalTime().ToString('o')))"
                            }
                        }
                    }
                }
            } catch { }
        }
        if ($quotaExhausted) {
            $failureReason = "쿼터 소진 — 역할 재배정 필요 (차단된 principal: $($blockedPrincipalsList -join ', '))"
            Write-Log "❌ [$Stage] $failureReason" ERROR
            Write-Log "재개 절차: 패킷의 Runtime Role Binding 5필드 또는 model-profiles.local.json을 편집해 쿼터가 남은 팀으로 재배정하세요." ERROR
            Write-BlockedMarker -Stage $Stage -Reason $failureReason -OwnerTaskId $TaskId -OwnerProcessId $PID
            $firstModel = ''
            if ($config.ModelFallback) { $firstModel = @($config.ModelFallback)[0] }
            elseif ($config.ModelChain) { $firstModel = @($config.ModelChain)[0] }
            Record-ChainRuntime -Stage $Stage -Model $firstModel -Status 'quota_exhausted' -Reason $failureReason
            $blockedPath = Resolve-RepoPath "$LogDir/$TaskId-blocked.json"
            $blockedValue = [ordered]@{
                schemaVersion = 1
                taskId = $TaskId
                timestamp = [datetime]::UtcNow.ToString('o')
                reason = $failureReason
                stages = [ordered]@{ current = [ordered]@{ stage = $Stage; model = $firstModel } }
                recoverySteps = @(
                    '패킷의 Runtime Role Binding 5필드(Planning Profile/Adapter, QA Profile/Adapter, Integration Profile/Adapter)를 쿼터가 남은 팀으로 변경'
                    '또는 model-profiles.local.json의 roles 항목을 편집해 쿼터가 남은 프로필로 재배정'
                    'provider-health.json의 nextProbeAt 만료 후 재시도 가능'
                )
            }
            Write-AtomicJson -Path $blockedPath -Value $blockedValue -Depth 6
            try { [System.Console]::Beep() } catch { }
            return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $null }
        }
        $failureReason = '모델 체인이 비어 있음 — 단계 구성 오류'
        Write-Log "❌ [$Stage] $failureReason" ERROR
        return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $null }
    }

    if ($DryRun) {
        return (Show-StageDryRun -Stage $Stage -Config $config -LogRel $logRel -PromptOverride $PromptOverride -Model $models[0] -BypassToolPermissions $BypassToolPermissions)
    }
    $cycle = Initialize-StageDispatch -Stage $Stage -Config $config -LogRel $logRel
    # CFG073: QA agent가 추측하지 않도록, cycle을 할당한 뒤 실제 값을 기본 프롬프트에 넣는다.
    # PromptOverride는 호출자의 명시적 지시이므로 덮어쓰지 않는다.
    if ($Stage -eq 'qa' -and [string]::IsNullOrWhiteSpace($PromptOverride)) {
        $PromptOverride = "$($config.DefaultPrompt) 이번 QA verdict JSON의 cycle은 $($cycle.Id)로 기록해."
    }
    $qaDispatchedAt = Clear-QaArtifacts -Stage $Stage -Config $config
    Invoke-SessionHealthCheck -Stage $Stage
    $preflight = Invoke-StagePreflightGate -Stage $Stage -config $config -Cycle $cycle -LogRel $logRel -qaDispatchedAt $qaDispatchedAt
    if ($preflight.Abort) {
        return @{ Success = $false; FailureReason = $preflight.Reason; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
    }

    # CFG024: 구현(②) 단계 전 스냅숏 확보 (프로토콜 오염 감지용)
    $packetsBefore = if ($Stage -eq 'impl') { Get-PacketFileSnapshot } else { @() }
    $routerBefore = if ($Stage -eq 'impl') { Get-RouterTableSnapshot } else { @{} }
    $before = Get-TreeState
    $logicalStartedAt = Get-Date
    $logicalHardLimit = if ($config.HardTimeoutMinutes) { $config.HardTimeoutMinutes } else { $HardTimeoutMinutes }
    $logicalAbsoluteDeadline = $logicalStartedAt.AddMinutes($logicalHardLimit * 3)
    $continuationCount = 0
    $exit = $null; $outcome = $null; $attemptFailures = @()
    $modelIndex = 0; $attemptNumber = 0; $lastDeterministicSig = $null; $consecutiveDeterministicCount = 0

    while ($modelIndex -lt $models.Count) {
        $model = $models[$modelIndex]
        $slot = Resolve-SlotAdapter -config $config -Stage $Stage -ModelIndex $modelIndex -Model $model -RepoRoot $RepoRoot
        if ($slot.Next) {
            $attemptFailures += $slot.Failure
            $modelIndex++
            continue
        }
        $toolCmd = Build-ToolCommand -Config $config -Stage $Stage -PromptOverride $PromptOverride -Model $model -BypassToolPermissions:$BypassToolPermissions
        $modelTag = if ($model) { " (모델 $($modelIndex + 1)/$($models.Count): $model)" } else { "" }
        Write-Log "작업 $TaskId [$Stage] 디스패치$modelTag" INFO
        Write-Log "명령: $toolCmd" INFO
        Write-Log "로그: $logRel" INFO
        $attempt = 1
        while ($true) {
            $attemptNumber++
            $attemptLog = Get-AttemptLogPath -LogFile $logRel -CycleNumber $cycle.Id -AttemptNumber $attemptNumber
            Write-Log "시도 로그: $attemptLog (latest: $logRel)" INFO
            $attemptResult = Invoke-ModelAttempt -Stage $Stage -Config $config -ToolCmd $toolCmd -AttemptLog $attemptLog -LatestLog $logRel -Cycle $cycle.Id -Model $model
            $exit = $attemptResult.ExitCode
            $outcome = Classify-AttemptFailure -Attempt $attemptResult -Before $before -AttemptLog $attemptLog
            if ($Stage -eq 'impl' -and (Get-Command Update-ProviderHealth -ErrorAction SilentlyContinue)) { Update-ProviderHealth -Model $model -Outcome $outcome -AttemptLog $attemptLog }

            # CFG024: 정상 종료 직전 프로토콜 오염 감지
            if ($outcome -eq 'ok') {
                $pollutionResult = Test-ProtocolPollution -Stage $Stage -PacketsBefore $packetsBefore -RouterBefore $routerBefore
                if ($pollutionResult.Polluted) {
                    $outcome = 'pollution'
                    Write-Log "❌ [$Stage] 프로토콜 오염 감지: $($pollutionResult.Reason) → 실패 처리" ERROR
                }
            }
            if ($outcome -eq 'approval_required') {
                return (Complete-StageApprovalRequired -Stage $Stage -config $config -Cycle $cycle -AttemptNumber $attemptNumber -Model $model -AttemptLog $attemptLog -LogRel $logRel -qaDispatchedAt $qaDispatchedAt -Evidence $attemptResult.ApprovalEvidence)
            }
            if ($outcome -eq 'provider_timeout') {
                $resume = Resume-ProviderTimeout -Stage $Stage -config $config -Cycle $cycle -Attempt $attemptResult -AttemptNumber $attemptNumber -Model $model -AttemptLog $attemptLog -ContinuationCount $continuationCount -LogicalHardLimit $logicalHardLimit -LogicalAbsoluteDeadline $logicalAbsoluteDeadline
                if ($resume.Continue) { $continuationCount = $resume.ContinuationCount; $toolCmd = $resume.ToolCmd; continue }
            }
            $fClass = Get-FailureClass -Outcome $outcome
            if ($outcome -eq 'hang' -and $config.Retry -and $attempt -eq 1 -and $fClass -ne 'deterministic') {
                $retry = Prepare-HangRetry -Stage $Stage -config $config -Cycle $cycle -Attempt $attemptResult -AttemptNumber $attemptNumber -Model $model -AttemptLog $attemptLog -LogicalHardLimit $logicalHardLimit -Before $before
                if ($retry.ShouldRetry) {
                    $attempt = 2
                    if ($retry.ToolCmd) { $toolCmd = $retry.ToolCmd }
                    Write-Log "⚠️ 재시도는 위 상태를 정리하지 않고 그대로 이어서 실행합니다." WARN
                    continue
                }
            }
            break
        }
        if ($outcome -eq 'ok') { break }
        $reason = Resolve-OutcomeReason -Outcome $outcome
        $attemptFailures += "${model}: $reason"
        $fClass = Get-FailureClass -Outcome $outcome
        $sig = Get-FailureSignature -FailureClass $fClass -Adapter $config.Adapter -Reason $reason
        $rec = Record-StageAttempt -Stage $Stage -Signature $sig -FailureClass $fClass

        # CFG024 §6-4: 동일 결정적 실패 서명 2회 연속 시 전역 실패 판정(체인 중단). 로컬 상태 3개를
        # 함께 돌려줘야 해서 인라인 유지(CFG040 결정) — 루프 제어를 도우미로 옮기면 분산 위험이 크다.
        if ($fClass -eq 'deterministic' -and $sig -eq $lastDeterministicSig) {
            $consecutiveDeterministicCount++
            if ($consecutiveDeterministicCount -ge 2) {
                Write-Log "⚠️ [$Stage] 동일 결정적 실패 서명($sig) 연속 2회 발생 — 전역 실패로 판정하고 체인 즉시 중단" WARN
                $modelIndex = $models.Count
                continue
            }
        } elseif ($fClass -eq 'deterministic') {
            $lastDeterministicSig = $sig
            $consecutiveDeterministicCount = 1
        }

        # provider timeout / pollution / unknown 은 모델 폴백 없이 현재 cycle 종료
        if ($outcome -in @('provider_timeout', 'unknown', 'pollution')) { $modelIndex = $models.Count; continue }
        $modelIndex++
        if ($modelIndex -lt $models.Count) {
            if (-not (Ensure-PreviousSlotCleared -Stage $Stage)) { $modelIndex = $models.Count; continue }
            Write-Log "⚠️ [$Stage] $model 에서 $reason — 다음 모델로 전환: $($models[$modelIndex])" WARN
            Write-KilledLeftover -Before $before -Stage $Stage -Context "$reason — 모델 전환"
        }
    }

    $failure = Complete-StageFailure -Stage $Stage -Cycle $cycle -Outcome $outcome -AttemptFailures $attemptFailures -Before $before -Model $model -LogRel $logRel -qaDispatchedAt $qaDispatchedAt
    if ($null -ne $failure) { return $failure }
    $exitFailure = Complete-StageExitFailure -Stage $Stage -Cycle $cycle -Exit $exit -LogRel $logRel -Model $model -qaDispatchedAt $qaDispatchedAt
    if ($null -ne $exitFailure) { return $exitFailure }

    $verifyResult = Invoke-VerifyGate -Stage $Stage
    if (-not $verifyResult.Success) {
        # CFG042 완료 정리 경계 ①: Integration이 검증 게이트를 통과하지 못하면 파이프라인 완료 정리
        # (⑤ 체크·router DONE·아카이브 이동·완료 커밋 메시지)를 금지한다. 패킷은 미완료 상태로 남아
        # 오케스트레이터가 실패를 전제로 재진행해야 한다 — 이 경계 이전에 완료를 주장하는 정리는 없어야 한다.
        if ($Stage -eq 'integration') {
            Write-Log '⛔ [integration] 검증 실패 — 완료 정리 금지 (⑤ 체크·router DONE·아카이브·완료 커밋 불가, 패킷 미완료 유지)' ERROR
        }
        $failReason = $verifyResult.FailureReason
        if ($verifyResult.Retried) { $failReason = "$failReason (auto-retry also failed)" }
        Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($logRel) -Reason $failReason -Model $model
        Record-ChainRuntime -Stage $Stage -Model $model -Status 'failed' -Reason $failReason
        return @{ Success = $false; FailureReason = $failReason; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
    }

    # CFG017: 이전 승인 대기 상태가 fresh cycle 성공 시 resolved로 해소된다 (qa는 verdict 통과 후 별도 해소).
    if ($Stage -ne 'qa') { Resolve-ApprovalRecords -Stage $Stage -ResolvingCycle $cycle.Id }
    Warn-UnchangedTree -Stage $Stage -Before $before

    $successReason = 'stage succeeded and verify passed'
    if ($verifyResult.Retried -and $verifyResult.RetryRecovered) {
        $successReason = 'stage succeeded and verify passed (auto-retry after spurious failure)'
    }
    Write-Log "✅ [$Stage] 성공 + 검증 통과" SUCCESS
    # CFG042 완료 정리 경계 ②: Integration이 검증 게이트를 통과한 이 지점에 이르러서야 완료 정리
    # (⑤ 체크·router DONE·아카이브 이동·완료 커밋·push)가 허용된다. 이 경계 앞에서는 할 수 없다.
    if ($Stage -eq 'integration') {
        Write-Log '✅ [integration] 검증 성공 — 완료 정리 허용 (⑤ 체크·router DONE·아카이브·완료 커밋 가능)' INFO
    }
    Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'completed' -ProcessId $PID -EvidencePaths @($logRel) -Reason $successReason -Model $model
    Record-ChainRuntime -Stage $Stage -Model $model -Status 'success' -Reason $successReason
    return @{ Success = $true; FailureReason = $null; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
}

function Test-LiveStageActivity {
    param([string]$TargetTaskId = $TaskId, [string[]]$StagesToCheck = @('impl','qa','integration'))
    $target = if ([string]::IsNullOrWhiteSpace($TargetTaskId)) { $TaskId } else { $TargetTaskId }
    $live = @()
    foreach ($s in $StagesToCheck) {
        $lock = Read-DispatchLock $s
        if ($lock -and $lock.Alive) { $live += "[$s] 살아있는 락 PID $($lock.ProcId)" }
        $leasePath = Resolve-RepoPath "$LogDir/$target-stage-state.json"
        if (Test-Path -LiteralPath $leasePath) {
            try {
                $lease = Get-Content -LiteralPath $leasePath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { $lease = $null }
            if ($lease -and [string]$lease.stage -eq $s -and [string]$lease.state -match '^(starting|running)$') {
                try {
                    $heartbeat = ([datetime]$lease.heartbeatAt).ToUniversalTime()
                    $fresh = (([datetime]::UtcNow) - $heartbeat).TotalSeconds -lt 600
                } catch { $fresh = $false }
                if ($fresh) { $live += "[$s] 살아있는 running lease cycle $($lease.cycle) PID $($lease.pid)" }
            }
        }
    }
    if ($live.Count -eq 0) { return $null }
    return ($live -join ', ')
}

function Invoke-ManualStageTermination {
    param([string]$Stage, [switch]$Complete, [string]$ReasonText)
    if (-not $Stage -or @('impl','qa','integration') -notcontains $Stage) {
        Write-Log '오류: 수동 완료/중단은 -Stage impl|qa|integration 과 함께 사용하세요.' ERROR
        return 1
    }
    # 살아 있는 실행이 있으면 종결하지 않는다 — 사용자 개입이라도 실제 진행 중 lease를 덮어쓰지 않는다.
    $live = Test-LiveStageActivity
    if ($live) {
        Write-Log "⛔ [수동종결] 살아 있는 실행이 있어 lease를 종결하지 않습니다: $live" ERROR
        Write-Log '수동 완료/중단은 실행이 종료된 뒤(또는 만료된 lease)에만 사용 가능합니다. 실행이 끝나기를 기다리거나 해당 세션을 정리하세요.' ERROR
        return 1
    }
    $statePath = Resolve-RepoPath "$LogDir/$TaskId-stage-state.json"
    $cycle = 1
    $evidence = @()
    try {
        if (Test-Path -LiteralPath $statePath) {
            $prev = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$prev.stage -eq $Stage) {
                $c = 0
                if ([int]::TryParse([string]$prev.cycle, [ref]$c)) { $cycle = $c }
                foreach ($e in @($prev.evidencePaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$e)) { $evidence += [string]$e } }
            }
        }
    } catch { }
    $target = if ($Complete) { 'completed' } else { 'failed' }
    $detail = if ([string]::IsNullOrWhiteSpace($ReasonText)) { '' } else { " — $ReasonText" }
    $reason = if ($Complete) { "수동 완료 — 사용자 권한으로 단계 실행 종결$detail" } else { "수동 중단 — 사용자 권한으로 실행 중단$detail" }
    Write-StageState -Stage $Stage -Cycle $cycle -State $target -ProcessId $PID -EvidencePaths $evidence -Reason $reason -Model $null -ManualIntervention
    $mark = if ($Complete) { '✅' } else { '❌' }
    Write-Log "$mark [$Stage] 수동 $(if ($Complete) { '완료' } else { '중단' }) — terminal lease '$target' 기록 (cycle $cycle, reason: $reason)" SUCCESS
    return 0
}

function Invoke-DispatcherCleanup {
    if ($script:CleanupStarted) { return }
    $script:CleanupStarted = $true
    try {
        if ($script:ActiveChildProcessId) {
            if ($script:ActiveChildStage -eq 'integration') {
                Write-Log "⚠️ dispatcher interruption left integration PID $script:ActiveChildProcessId running; do not kill a commit/push stage automatically." WARN
            } else {
                Stop-ProcessTree $script:ActiveChildProcessId
                Write-Log "dispatcher interruption stopped child process tree PID $script:ActiveChildProcessId" WARN
            }
        }
    } finally {
        if ($script:ActiveLockStage) { Exit-DispatchLock -Stage $script:ActiveLockStage }
    }
}

function Invoke-StageWithLock {
    param([string]$Stage, [string]$PromptOverride, [bool]$CheckPipelineBefore, [string]$CheckPipelinePacket)
    if ($DryRun) { return (Dispatch-Stage -Stage $Stage -PromptOverride $PromptOverride) }
    # 락 획득 실패는 이 작업의 실패가 아니라 "지금은 때가 아님"이므로 마커를 남기지 않는다.
    if (-not (Enter-DispatchLock -Stage $Stage -PacketPath $CheckPipelinePacket)) { return $false }
    try {
        $scopeSnapshot = Get-ChangedFileSnapshot
        if ($CheckPipelineBefore) { Test-RequestedPipelineStage -Stage $Stage -PacketPath $CheckPipelinePacket }
        # 성공/실패 어느 쪽이든 마커 상태를 확정한다 — 실패는 다음 실행까지 눈에 남고, 성공은 즉시 지운다.
        $result = Dispatch-Stage -Stage $Stage -PromptOverride $PromptOverride
        $cycleId = if ($result.CycleId) { [int]$result.CycleId } else { 0 }
        Write-SyntheticQaVerdict -Stage $Stage -Result $result -CycleNumber $cycleId
        Ensure-QaLedger -Stage $Stage -Result $result
        if ($result.Success) { Test-PipelineStageUpdated -Stage $Stage -PacketPath $CheckPipelinePacket }
        if ($result.Success) { Clear-FailureMarker -Stage $Stage }
        if ($result.Success) {
            $drift = Get-ScopeDriftWarnings -PacketPath $CheckPipelinePacket -BeforeSnapshot $scopeSnapshot
            if ($drift.Count -gt 0) {
                Write-Log "⚠️ [$Stage] Scope 범위 이탈 감지 — 선언된 Scope paths 밖 파일 변경: $($drift -join ', ')" WARN
            }
        }
        elseif ($result.Outcome -eq 'approval_required') {
            # CFG017: 승인 대기는 failure 마커를 남기지 않는다 — 승인 기록 파일 자체가 상태·감사 증거다.
            # 자동 재시도 계기가 될 만한 "실패" 흔적을 남기지 않기 위함이다.
            Write-Log "[$Stage] 승인 대기 — failure 마커 대신 승인 기록이 상태를 나타냅니다 ($($result.ApprovalPath))" INFO
        }
        else { Write-FailureMarker -Stage $Stage -Reason $result.FailureReason }
        return $result
    } catch {
        Write-FailureMarker -Stage $Stage -Reason "예외: $($_.Exception.Message)"
        throw
    } finally {
        Exit-DispatchLock -Stage $Stage
    }
}

function Resolve-DispatchPlan {
    param(
        [Parameter(Mandatory=$true)][string]$TaskId,
        [Parameter(Mandatory=$false)][string]$Stage,
        [Parameter(Mandatory=$false)][string]$Prompt,
        [Parameter(Mandatory=$false)][string]$Model,
        [Parameter(Mandatory=$false)][switch]$Chain,
        [Parameter(Mandatory=$false)][switch]$DryRun,
        [Parameter(Mandatory=$false)][switch]$SkipVerdictGate,
        [Parameter(Mandatory=$false)][switch]$ForceFreeModel,
        [Parameter(Mandatory=$false)][switch]$ResetStageLedger,
        [Parameter(Mandatory=$false)][string]$ResetReason,
        [Parameter(Mandatory=$false)][switch]$ManualComplete,
        [Parameter(Mandatory=$false)][switch]$ManualAbort,
        [Parameter(Mandatory=$false)][string]$Reason,
        [Parameter(Mandatory=$false)][hashtable]$StageConfig,
        [Parameter(Mandatory=$false)][string]$RepoRoot,
        [Parameter(Mandatory=$false)][string]$ProfileModule,
        [Parameter(Mandatory=$false)][string]$ProfileConfigPath
    )

    Validate-TaskId -Id $TaskId

    if ($ResetStageLedger) {
        if (-not $Stage) {
            Write-Log '오류: -ResetStageLedger는 -Stage와 함께 사용하세요 (예: -Stage qa).' ERROR
            return [pscustomobject]@{ EarlyExit = $true; ExitCode = 1; Reason = 'ResetStageLedger requires Stage' }
        }
        if ([string]::IsNullOrWhiteSpace($ResetReason)) {
            Write-Log '오류: -ResetStageLedger는 -ResetReason으로 초기화 사유를 반드시 남기세요 (예: "구조적 원인 수정 완료 — BypassToolPermissions 적용").' ERROR
            return [pscustomobject]@{ EarlyExit = $true; ExitCode = 1; Reason = 'ResetStageLedger requires ResetReason' }
        }
        return [pscustomobject]@{ EarlyExit = $true; ExitCode = 0; Reason = 'StageLedger reset requested'; Action = 'resetStageLedger'; ActionStage = $Stage; ActionReason = $ResetReason }
    }

    # ── CFG043: 수동 완료/중단 (실행 대신 lease 종결) ──
    if ($ManualComplete -and $ManualAbort) {
        Write-Log '-ManualComplete와 -ManualAbort는 동시에 사용할 수 없습니다.' ERROR
        return [pscustomobject]@{ EarlyExit = $true; ExitCode = 1; Reason = 'Mutually exclusive manual complete/abort' }
    }
    if ($ManualComplete) {
        return [pscustomobject]@{ EarlyExit = $true; ExitCode = 0; Reason = 'ManualComplete requested'; Action = 'manualStageTermination'; ActionStage = $Stage; ActionComplete = $true; ActionReason = $Reason }
    }
    if ($ManualAbort) {
        return [pscustomobject]@{ EarlyExit = $true; ExitCode = 0; Reason = 'ManualAbort requested'; Action = 'manualStageTermination'; ActionStage = $Stage; ActionComplete = $false; ActionReason = $Reason }
    }

    if ($Chain -and $Stage) {
        Write-Log '-Chain and -Stage are mutually exclusive.' ERROR
        return [pscustomobject]@{ EarlyExit = $true; ExitCode = 1; Reason = 'Chain and Stage mutually exclusive' }
    }
    if ($Chain -and $Prompt) {
        Write-Log '-Prompt is ignored in -Chain mode; using each stage default prompt.' WARN
    }
    if (-not $Chain -and $Stage -ne 'impl' -and $Model) {
        Write-Log "-Model is ignored for [$Stage]." WARN
    }
    if ($Model) {
        Assert-ModelIdentifier -Value $Model -Source '-Model'
    }

    # $StageConfig 불변성 보장을 위한 딥 복제(Clone)
    $resolvedStageConfig = @{}
    if ($StageConfig) {
        foreach ($k in $StageConfig.Keys) {
            $resolvedStageConfig[$k] = @{}
            foreach ($subKey in $StageConfig[$k].Keys) {
                $val = $StageConfig[$k][$subKey]
                if ($val -is [System.Array]) {
                    $resolvedStageConfig[$k][$subKey] = @($val)
                } else {
                    $resolvedStageConfig[$k][$subKey] = $val
                }
            }
        }
    }

    foreach ($configuredStage in $resolvedStageConfig.Keys) {
        if ($resolvedStageConfig[$configuredStage].ModelFallback) {
            foreach ($configuredModel in $resolvedStageConfig[$configuredStage].ModelFallback) {
                Assert-ModelIdentifier -Value $configuredModel -Source "StageConfig.$configuredStage.ModelFallback"
            }
        }
    }

    $packetMatches = @(Get-ChildItem -Path (Join-Path $RepoRoot '.agents\briefs\packets') -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue)
    $archiveMatches = @(Get-ChildItem -Path (Join-Path $RepoRoot '.agents\briefs\archive') -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue)
    if ($packetMatches.Count -eq 0 -and $archiveMatches.Count -eq 0) {
        Write-Log "작업 패킷을 찾지 못했습니다: $TaskId (저장소별 패킷 경로가 다를 수 있어 경고만 남기고 진행)" WARN
    }
    $checkPipelinePacket = if ($packetMatches.Count -eq 1) { $packetMatches[0].FullName } else { $null }

    # CFG041: 조건부 기획 챌린지 리뷰 게이트
    if ($checkPipelinePacket) {
        try {
            Assert-PlanningChallengeReviewReady -PacketPath $checkPipelinePacket | Out-Null
        } catch {
            Write-Log $_.Exception.Message ERROR
            return [pscustomobject]@{ EarlyExit = $true; ExitCode = 1; Reason = "PlanningChallengeReview not ready: $($_.Exception.Message)" }
        }
    }

    if ($ProfileModule -and (Test-Path -LiteralPath $ProfileModule)) {
        . $ProfileModule
    }
    $profileConfig = Read-ModelProfileConfig -CentralPath $ProfileConfigPath -LocalPath (Join-Path $RepoRoot 'model-profiles.local.json')
    $configuredPlanning = Resolve-RoleProfile -Role planning -Config $profileConfig
    $planningProfile = $configuredPlanning.Name
    $planningAdapter = $configuredPlanning.Adapter
    $runtimeRoleBinding = [pscustomobject]@{
        source = 'config'
        legacy = $false
        planningProfile = $planningProfile
        planningAdapter = $planningAdapter
    }
    $packetQaProfile = $null
    $packetQaAdapter = $null
    $packetIntegrationProfile = $null
    $packetIntegrationAdapter = $null
    $packetImplRoute = $null
    $packetRoleContentionAck = $null

    if ($checkPipelinePacket) {
        $runtimeBinding = Get-RuntimeRoleBinding -PacketPath $checkPipelinePacket
        if ($runtimeBinding.Valid) {
            $planningProfile = $runtimeBinding.PlanningProfile
            $planningAdapter = $runtimeBinding.PlanningAdapter
            $packetQaProfile = $runtimeBinding.QaProfile
            $packetQaAdapter = $runtimeBinding.QaAdapter
            $packetIntegrationProfile = $runtimeBinding.IntegrationProfile
            $packetIntegrationAdapter = $runtimeBinding.IntegrationAdapter
            $packetImplRoute = $runtimeBinding.ImplementationRoute
            $packetRoleContentionAck = $runtimeBinding.RoleContentionAck

            $runtimeRoleBinding = [pscustomobject]@{
                source = 'packet'
                legacy = $false
                planningProfile = $planningProfile
                planningAdapter = $planningAdapter
                qaProfile = $packetQaProfile
                qaAdapter = $packetQaAdapter
                integrationProfile = $packetIntegrationProfile
                integrationAdapter = $packetIntegrationAdapter
                implementationRoute = $packetImplRoute
                roleContentionAck = $packetRoleContentionAck
            }
        } elseif ($runtimeBinding.Error) {
            throw $runtimeBinding.Error
        } else {
            $runtimeRoleBinding = [pscustomobject]@{
                source = 'config'
                legacy = $true
                planningProfile = $planningProfile
                planningAdapter = $planningAdapter
            }
            Write-Log 'Runtime Role Binding missing; using configured planning profile for legacy packet.' WARN
        }
    }

    $pipelineRouting = Resolve-PipelineRouting -Config $profileConfig -PlanningProfile $planningProfile -PlanningAdapter $planningAdapter -QaProfile $packetQaProfile -QaAdapter $packetQaAdapter -IntegrationProfile $packetIntegrationProfile -IntegrationAdapter $packetIntegrationAdapter -ImplementationRoute $packetImplRoute
    $resolvedStageConfig.impl.ModelFallback = @($pipelineRouting.ImplementationModels)
    $resolvedStageConfig.impl.ModelFallback = @(Resolve-ForceFreeModelChain -ModelFallback $resolvedStageConfig.impl.ModelFallback -ProfileConfig $profileConfig -ForceFreeModel $ForceFreeModel)

    $implAdapterMap = @{}
    $implModelMap = @{}
    foreach ($implSlot in @($resolvedStageConfig.impl.ModelFallback)) {
        $implMeta = $null
        if ($profileConfig.modelCatalog) { $implMeta = $profileConfig.modelCatalog.$implSlot }
        $implAdapterMap[$implSlot] = if ($implMeta -and $implMeta.adapter) { [string]$implMeta.adapter } else { 'opencode' }
        if ($implMeta -and $implMeta.invokeModel) { $implModelMap[$implSlot] = [string]$implMeta.invokeModel }
    }
    $resolvedStageConfig.impl.AdapterMap = $implAdapterMap
    $resolvedStageConfig.impl.ModelMap = $implModelMap
    $implFirstSlot = @($resolvedStageConfig.impl.ModelFallback)[0]
    if ($implFirstSlot -and $implAdapterMap.ContainsKey($implFirstSlot)) { $resolvedStageConfig.impl.Adapter = $implAdapterMap[$implFirstSlot] }
    if ($resolvedStageConfig.impl.Adapter -eq 'antigravity') { $resolvedStageConfig.impl.ProjectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot }

    $implFamilies = @($pipelineRouting.ImplementationModels | ForEach-Object {
        if ($profileConfig.modelCatalog.$_) { [string]$profileConfig.modelCatalog.$_.family }
    } | Where-Object { $_ -and $_ -ne 'unknown' } | Select-Object -Unique)

    $qaChainNames = Resolve-ProfileChain -ProfileName $pipelineRouting.QaProfile.Name -Config $profileConfig
    $qaSlots = Resolve-StageProfileSlots -ProfileNames $qaChainNames -Config $profileConfig -ImplementerFamilies $implFamilies -Stage 'qa'
    if ($qaSlots.Count -eq 0) {
        $resolvedStageConfig.qa.ModelChain = @()
        Write-Log "❌ [qa] 구현자와 family가 겹치지 않는 QA 후보가 없음 — 사람 개입 필요 (구현 family: $($implFamilies -join ', '))" ERROR
    } else {
        $resolvedStageConfig.qa.ModelChain = @($qaSlots | ForEach-Object { $_.Model })
        $resolvedStageConfig.qa.AdapterChain = @($qaSlots | ForEach-Object { $_.Adapter })
        $resolvedStageConfig.qa.Adapter = $qaSlots[0].Adapter
        $resolvedStageConfig.qa.Model = $qaSlots[0].Model
    }
    if ($resolvedStageConfig.qa.Adapter -eq 'antigravity') { $resolvedStageConfig.qa.ProjectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot }

    $integrationChainNames = Resolve-ProfileChain -ProfileName $pipelineRouting.IntegrationProfile.Name -Config $profileConfig
    $integrationSlots = Resolve-StageProfileSlots -ProfileNames $integrationChainNames -Config $profileConfig -Stage 'integration'
    if ($integrationSlots.Count -eq 0) {
        $resolvedStageConfig.integration.ModelChain = @()
        Write-Log "❌ [integration] Integration 후보를 하나도 해석하지 못함 — 사람 개입 필요" ERROR
    } else {
        $resolvedStageConfig.integration.ModelChain = @($integrationSlots | ForEach-Object { $_.Model })
        $resolvedStageConfig.integration.AdapterChain = @($integrationSlots | ForEach-Object { $_.Adapter })
        $resolvedStageConfig.integration.Adapter = $integrationSlots[0].Adapter
        $resolvedStageConfig.integration.Model = $integrationSlots[0].Model
    }
    $resolvedStageConfig.integration.ReportFile = "$TaskLogPrefix-integration-last.md"

    $stateRoot = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.agents\harness-state' } else { Join-Path ([IO.Path]::GetTempPath()) 'agents-harness-state' }
    $providerHealthPath = Join-Path $stateRoot 'provider-health.json'

    $implPrincipal = if ($implFirstSlot -and $profileConfig.modelCatalog -and $profileConfig.modelCatalog.$implFirstSlot) {
        if ($profileConfig.modelCatalog.$implFirstSlot.principal) { [string]$profileConfig.modelCatalog.$implFirstSlot.principal } else { [string]$resolvedStageConfig.impl.Adapter }
    } else { [string]$resolvedStageConfig.impl.Adapter }

    $qaPrincipal = if ($pipelineRouting.QaProfile) {
        $qaModel = $pipelineRouting.QaProfile.Model
        if ($profileConfig.modelCatalog -and $profileConfig.modelCatalog.$qaModel -and $profileConfig.modelCatalog.$qaModel.principal) {
            [string]$profileConfig.modelCatalog.$qaModel.principal
        } else {
            [string]$pipelineRouting.QaProfile.Adapter
        }
    } else { $null }

    $integrationPrincipal = if ($pipelineRouting.IntegrationProfile) {
        $intModel = $pipelineRouting.IntegrationProfile.Model
        if ($profileConfig.modelCatalog -and $profileConfig.modelCatalog.$intModel -and $profileConfig.modelCatalog.$intModel.principal) {
            [string]$profileConfig.modelCatalog.$intModel.principal
        } else {
            [string]$pipelineRouting.IntegrationProfile.Adapter
        }
    } else { $null }

    $contentionCheck = Test-PipelineRoleContention -ImplPrincipal $implPrincipal -QaPrincipal $qaPrincipal -IntegrationPrincipal $integrationPrincipal
    if ($contentionCheck.Contention) {
        if ([string]::IsNullOrWhiteSpace($packetRoleContentionAck)) {
            Write-Log "⛔ [role-contention] 파이프라인 단계 간 principal 경합 감지: $($contentionCheck.Details)" ERROR
            Write-Log "동일 principal(계정/어댑터)이 복수 단계를 수행하면 쿼터 경합 또는 독립성 훼손이 발생할 수 있습니다. 패킷에 '- Role Contention Ack: <사유>'를 명시하거나 역할을 분리하세요." ERROR
            return [pscustomobject]@{ EarlyExit = $true; ExitCode = 1; Reason = "Role contention detected without Ack: $($contentionCheck.Details)" }
        } else {
            Write-Log "⚠️ [role-contention] 파이프라인 단계 간 principal 경합 ($($contentionCheck.Details)) — Role Contention Ack 확인됨: $packetRoleContentionAck" WARN
        }
    }

    Write-Log "planner=$planningProfile/$planningAdapter impl-route=$($pipelineRouting.ImplementationRoute) impl=$implFirstSlot(adapter=$($resolvedStageConfig.impl.Adapter)) qa=$($resolvedStageConfig.qa.Adapter)/$($resolvedStageConfig.qa.Model) project=$($resolvedStageConfig.qa.ProjectId) integration=$($resolvedStageConfig.integration.Adapter)/$($resolvedStageConfig.integration.Model)" INFO

    return [pscustomobject]@{
        EarlyExit = $false
        ExitCode = 0
        Reason = $null
        TaskId = $TaskId
        Stage = $Stage
        Prompt = $Prompt
        Model = $Model
        Chain = [bool]$Chain
        DryRun = [bool]$DryRun
        SkipVerdictGate = [bool]$SkipVerdictGate
        CheckPipelinePacket = $checkPipelinePacket
        ProfileConfig = $profileConfig
        RuntimeRoleBinding = $runtimeRoleBinding
        PipelineRouting = $pipelineRouting
        ResolvedStageConfig = $resolvedStageConfig
        ProviderHealthPath = $providerHealthPath
        PlanningProfile = $planningProfile
        PlanningAdapter = $planningAdapter
        ImplFirstSlot = $implFirstSlot
    }
}

function Invoke-DispatchChain {
    param(
        [Parameter(Mandatory=$true)][pscustomobject]$Plan
    )

    # 계획 단계가 표현한 상태 변경은 여기서만 실행한다. 계획 자체는 파일·프로세스 상태를 바꾸지 않는다.
    if ($Plan.EarlyExit) {
        if ($Plan.Action -eq 'resetStageLedger') {
            Reset-StageLedger -Stage $Plan.ActionStage -Reason $Plan.ActionReason
            return 0
        }
        if ($Plan.Action -eq 'manualStageTermination') {
            return (Invoke-ManualStageTermination -Stage $Plan.ActionStage -Complete:$Plan.ActionComplete -ReasonText $Plan.ActionReason)
        }
        return [int]$Plan.ExitCode
    }

    trap {
        Invoke-DispatcherCleanup
        break
    }

    try {
        $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
            $event.SourceEventArgs.Cancel = $true
            Invoke-DispatcherCleanup
        }
        $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-DispatcherCleanup }
    } catch {
        Write-Log "⚠️ 종료 이벤트 등록 실패: $($_.Exception.Message)" WARN
    }

    $verifyGate = Join-Path $RepoRoot "scripts\verify.ps1"
    if (-not (Test-Path $verifyGate)) {
        Write-Log "저장소 루트로 판정된 경로에 scripts\verify.ps1 이 없습니다: $RepoRoot" ERROR
        Write-Log "각 프로젝트의 scripts\ 에 배포된 사본으로 실행하세요 — 중앙 저장소 harness\ 에서 직접 실행하면 루트가 어긋납니다." ERROR
        return 1
    }

    $script:BashExe = Resolve-BashExe
    if (-not $Plan.DryRun -and -not $script:BashExe) {
        Write-Log "bash를 찾을 수 없습니다 — Git Bash 설치/PATH를 확인하세요." ERROR
        return 1
    }

    $checkPipelinePacket = $Plan.CheckPipelinePacket
    $DryRun = $Plan.DryRun

    if ($Plan.Chain) {
        Write-Log "📋 자동 연쇄 모드 시작 (TaskId: $($Plan.TaskId)): 패킷 첫 미완료 단계부터 수렴" INFO
        $chainPipelineBefore = Get-PacketPipelineStatus -PacketPath $checkPipelinePacket
        $chainEffectiveStage = Get-EffectivePipelineStage -PipelineStatus $chainPipelineBefore
        $stagesToCheck = if ($chainEffectiveStage) { @($chainEffectiveStage) } else { @('impl','qa','integration') }
        $liveActivity = Test-LiveStageActivity -StagesToCheck $stagesToCheck
        if ($liveActivity) {
            Write-Log "⛔ 자동 연쇄/재개 중단 — 살아 있는 단계 실행이 있어 재개하지 않습니다: $liveActivity" ERROR
            Write-Log '살아 있는 lease·락·승인 대기를 보존한 채 종료합니다. 실행이 끝난 뒤 다시 재개하세요.' ERROR
            Write-ChainSummary -State 'blocked' -Stages @() -Warnings @("살아 있는 실행으로 인한 재개 보류 — $liveActivity") -StartedAt (Get-Date) -PipelineBefore $chainPipelineBefore -PipelineAfter $chainPipelineBefore -TreeBefore (Get-TreeState) -TreeAfter (Get-TreeState) -QaVerdict @{ verdict = $null; fresh = $false } | Out-Null
            return 1
        }
        $chainStartedAt = Get-Date
        Set-CompletedStageApprovalsSuperseded -PipelineStatus $chainPipelineBefore -Evidence $checkPipelinePacket | Out-Null
        $chainTreeBefore = Get-TreeState
        $gateTier = Get-PacketGateTier -PacketPath $checkPipelinePacket
        $chainQaVerdict = @{ verdict = if ($gateTier -eq 'light') { 'skipped_light_tier' } else { $null }; fresh = $false }
        $chainStages = @()
        $effectiveStage = Get-EffectivePipelineStage -PipelineStatus $chainPipelineBefore
        $allStages = @('impl','qa','integration')
        $effectiveIndex = [array]::IndexOf($allStages, $effectiveStage)
        foreach ($fs in $allStages) {
            $fsIdx = [array]::IndexOf($allStages, $fs)
            if ($effectiveIndex -ge 0 -and $fsIdx -ge $effectiveIndex) { break }
            $failedMarkerPath = Resolve-RepoPath "$LogDir/.dispatch-failed-$TaskId-$fs"
            if (Test-Path -LiteralPath $failedMarkerPath) {
                Write-Log "⚠️ [$fs] 체크박스는 완료로 표시되었으나 실패 마커가 해소되지 않음 — 이 단계부터 재개" WARN
                $effectiveStage = $fs
                $effectiveIndex = $fsIdx
                break
            }
        }
        if ($effectiveIndex -lt 0) {
            Write-ChainSummary -State 'completed' -Stages @() -Warnings @('packet has no incomplete executable stage') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter $chainPipelineBefore -TreeBefore $chainTreeBefore -TreeAfter $chainTreeBefore -QaVerdict $chainQaVerdict | Out-Null
            Write-Log '✅ 패킷에 미완료 실행 단계가 없습니다 — 재디스패치 없이 종료' SUCCESS
            return 0
        }
        $stagesToRun = @($allStages[$effectiveIndex..($allStages.Count - 1)])
        Write-Log "유효 시작 단계: $effectiveStage (완료 단계 재디스패치 금지)" INFO
        # A task can resume at QA or Integration after a prior chain invocation.
        # Preserve its per-stage runtime identities: resetting here would erase
        # the logical predecessor before the adjacency check runs.
        $existingRuntime = Read-ChainRuntime
        if (-not $existingRuntime.stages.planning -and $script:PipelineRouting) {
            $planningProfile = [string]$script:PipelineRouting.PlanningProfile
            $planningModel = ''
            if ($script:ProfileConfig.profiles.$planningProfile) { $planningModel = [string]$script:ProfileConfig.profiles.$planningProfile.model }
            Record-ChainRuntime -Stage 'planning' -Model $planningModel -Status 'success' -Reason 'Runtime Role Binding planning identity' -ProfileName $planningProfile
        }
        foreach ($stage in $stagesToRun) {
            if ($stage -ne $stagesToRun[0]) {
                $adjCheck = Test-ChainAdjacency -Stage $stage
                if (-not $adjCheck.Allowed) {
                    $adjReason = "인접 단계 family 중복: [$($adjCheck.Predecessor)]($($adjCheck.PredecessorModel), family=$($adjCheck.PredecessorFamily)) → [$stage](family=$($adjCheck.CurrentFamily)) — 동일 family 연속 처리"
                    Write-Log "⛔ [$stage] $adjReason" ERROR
                    Write-Log "원칙 4: 동일 모델이 2단계 이상 연속 처리되지 않도록 해야 합니다. 사용자 지침을 받으세요." ERROR
                    Write-BlockedMarker -Stage $stage -Reason $adjReason -OwnerTaskId $TaskId -OwnerProcessId $PID
                    Record-ChainRuntime -Stage $stage -Model $adjCheck.CurrentModel -Status 'blocked_adjacency' -Reason $adjReason
                    Write-ChainBlockedMarker -Reason $adjReason -PredecessorStage $adjCheck.Predecessor -PredecessorModel $adjCheck.PredecessorModel -CurrentStage $stage -CurrentModel $adjCheck.CurrentModel -RecoverySteps @(
                        '패킷의 Runtime Role Binding을 변경해 다른 family의 팀으로 재배정'
                        'model-profiles.local.json의 roles 항목을 편집해 쿼터가 남은 프로필로 재배정'
                    )
                    try { [System.Console]::Beep(1000, 2000); [System.Console]::Beep(800, 2000) } catch { }
                    Write-ChainSummary -State 'blocked' -Stages $chainStages -Warnings @($adjReason) -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
                    return 1
                }
            }
            if ($stage -eq 'integration' -and -not $DryRun -and $gateTier -eq 'light') {
                Write-Log 'ℹ️ 경량 게이트 등급(패킷 선언) — QA verdict 게이트 생략, ⑤ 그대로 진행' INFO
            } elseif ($stage -eq 'integration' -and -not $DryRun -and -not (Test-QaVerdict -QaDispatchedAt $null)) {
                Write-FailureMarker -Stage 'integration' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
                Write-ChainSummary -State 'blocked' -Stages $chainStages -Warnings @('QA verdict 미통과 — ⑤ 진행 중단') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
                return 1
            }
            if ($stage -eq 'integration' -and -not $DryRun) {
                Write-Log '📌 [integration] QA verdict pass — 자동 연쇄 진행. 완료 정리는 검증 통과 후에만 허용' INFO
            }
            $result = Invoke-StageWithLock -Stage $stage -PromptOverride '' -CheckPipelineBefore ($stage -eq 'impl') -CheckPipelinePacket $checkPipelinePacket
            $chainStages += [ordered]@{ stage = $stage; success = [bool]$result.Success; failureReason = $result.FailureReason; verifyPassed = [bool]$result.Success; logPath = $StageConfig[$stage].LogFile }
            if (-not $result.Success) {
                $chainState = if ($result.Outcome -eq 'approval_required') { 'approval_required' } else { 'failed' }
                $chainWarnings = if ($result.Outcome -eq 'approval_required') { @("승인 대기 — 기록: $($result.ApprovalPath)") } else { @($result.FailureReason) }
                if ($stage -eq 'qa') {
                    try {
                        $vfPath = Resolve-RepoPath ($StageConfig['qa'].VerdictFile)
                        if (Test-Path -LiteralPath $vfPath) {
                            $vfJson = Get-Content -LiteralPath $vfPath -Raw -Encoding UTF8 | ConvertFrom-Json
                            $chainQaVerdict = @{ verdict = [string]$vfJson.verdict; reason = [string]$vfJson.reason; fresh = $true; synthetic = [bool]$vfJson.synthetic }
                        }
                    } catch { }
                }
                Write-ChainSummary -State $chainState -Stages $chainStages -Warnings $chainWarnings -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
                Write-Log "❌ [$stage] 파이프라인 중단 (상태: $chainState, 로그: $($StageConfig[$stage].LogFile))" ERROR
                return 1
            }
            if ($stage -eq 'qa' -and -not $DryRun -and -not (Test-QaVerdict -QaDispatchedAt $result.QaDispatchedAt -ExpectedCycle $result.CycleId)) {
                $actualQaVerdict = $null
                try {
                    $vfPath = Resolve-RepoPath ($StageConfig['qa'].VerdictFile)
                    if (Test-Path -LiteralPath $vfPath) {
                        $vfJson = Get-Content -LiteralPath $vfPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $actualQaVerdict = @{ verdict = [string]$vfJson.verdict; reason = [string]$vfJson.reason; fresh = $true; synthetic = [bool]$vfJson.synthetic }
                    }
                } catch { }
                if ($actualQaVerdict) { $chainQaVerdict = $actualQaVerdict }
                Write-FailureMarker -Stage 'qa' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
                Write-ChainSummary -State 'blocked' -Stages $chainStages -Warnings @('QA verdict 미통과 — ⑤ 진행 중단') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
                return 1
            }
            if ($stage -eq 'qa') {
                $actualQaVerdict = $null
                try {
                    $vfPath = Resolve-RepoPath ($StageConfig['qa'].VerdictFile)
                    if (Test-Path -LiteralPath $vfPath) {
                        $vfJson = Get-Content -LiteralPath $vfPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $actualQaVerdict = @{ verdict = [string]$vfJson.verdict; fresh = $true; synthetic = [bool]$vfJson.synthetic }
                    }
                } catch { }
                $chainQaVerdict = if ($actualQaVerdict) { $actualQaVerdict } else { @{ verdict = 'pass'; fresh = $true } }
            }
            if ($stage -eq 'qa' -and -not $DryRun -and $result.CycleId) { Resolve-ApprovalRecords -Stage 'qa' -ResolvingCycle $result.CycleId }
            Start-Sleep -Seconds 2
        }
        Write-ChainSummary -State 'completed' -Stages $chainStages -Warnings @() -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
        Write-Log "🎉 파이프라인 완료 — impl/qa/integration 로그는 $LogDir 참조" SUCCESS
        return 0
    } else {
        $singleStage = $Plan.Stage
        if (-not $singleStage) { Write-Log "오류: -Stage 또는 -Chain 옵션이 필요합니다." ERROR; return 1 }
        $standalonePipeline = Get-PacketPipelineStatus -PacketPath $checkPipelinePacket
        Set-CompletedStageApprovalsSuperseded -PipelineStatus $standalonePipeline -Evidence $checkPipelinePacket | Out-Null
        $effectiveStage = Get-EffectivePipelineStage -PipelineStatus $standalonePipeline
        if ($effectiveStage -and $effectiveStage -ne $singleStage) {
            $requestedIndexes = Get-StagePipelineIndexes -Stage $singleStage
            $requestedItems = @($standalonePipeline.Items | Where-Object { $requestedIndexes -contains $_.Index })
            if ($requestedItems.Count -gt 0 -and @($requestedItems | Where-Object { -not $_.Checked }).Count -eq 0) {
                Write-Log "✅ [$singleStage] 이미 완료됨 — 재디스패치하지 않고 첫 미완료 단계 [$effectiveStage]로 수렴" SUCCESS
                $singleStage = $effectiveStage
            }
        }
        if ($singleStage -eq 'integration' -and -not $DryRun) {
            if ($Plan.SkipVerdictGate) {
                Write-Log 'WARNING: -SkipVerdictGate bypasses the standalone integration QA verdict gate.' WARN
            } elseif ((Get-PacketGateTier -PacketPath $checkPipelinePacket) -eq 'light') {
                Write-Log 'ℹ️ 경량 게이트 등급(패킷 선언) — QA verdict 게이트 생략, ⑤ 그대로 진행' INFO
            } elseif (-not (Test-QaVerdict -QaDispatchedAt $null)) {
                Write-FailureMarker -Stage 'integration' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
                return 1
            }
        }
        $result = Invoke-StageWithLock -Stage $singleStage -PromptOverride $Plan.Prompt -CheckPipelineBefore $true -CheckPipelinePacket $checkPipelinePacket
        $ok = $result.Success
        if ($ok -and $singleStage -eq 'qa' -and -not $DryRun) {
            $ok = Test-QaVerdict -QaDispatchedAt $result.QaDispatchedAt -ExpectedCycle $result.CycleId
            if (-not $ok) { Write-FailureMarker -Stage 'qa' -Reason 'QA verdict 미통과 — ⑤ 진행 중단' }
            if ($ok -and $result.CycleId) { Resolve-ApprovalRecords -Stage 'qa' -ResolvingCycle $result.CycleId }
        }
        return [int](-not $ok)
    }
}


function Get-DispatchCycleStatePath {
    param([string]$Stage)
    return (Resolve-RepoPath "$LogDir/$TaskId-$Stage-cycles.json")
}

# 사이클 원자 할당(읽기-증가-쓰기, temp-file + Move-Item). 동일 단계는 Enter-DispatchLock 안에서만
# 호출되므로 같은 TaskId/Stage 사이클 번호가 동시에 두 프로세스에서 갈라지지 않는다.
# 상태 파일이 손상되면 로그 파일명에서 마지막 cycle을 재스캔해 복구한다(재사용 금지).
function New-DispatchCycle {
    param([string]$Stage)
    $path = Get-DispatchCycleStatePath $Stage
    $parent = Split-Path -Parent $path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $existing = @()
    $nextId = 1
    if (Test-Path -LiteralPath $path) {
        try {
            $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $state -and $null -ne $state.cycles) {
                $existing = @($state.cycles | Where-Object { $null -ne $_.id })
                $ids = @($existing | ForEach-Object { try { [int]$_.id } catch { 0 } })
                if ($ids.Count -gt 0) { $nextId = ([int]($ids | Measure-Object -Maximum).Maximum) + 1 }
            }
        } catch {
            # 손상 상태는 조용히 1로 되돌리지 않는다 — 재사용을 막기 위해 attempt 로그명에서 마지막 cycle을 찾는다.
            Write-Log "⚠️ 디스패치 사이클 상태 파일 손상($path) — 로그에서 마지막 cycle 재스캔으로 복구합니다" WARN
            $existing = @()
            $lastKnown = 0
            $logDirAbs = Resolve-RepoPath $LogDir
            if (Test-Path $logDirAbs) {
                foreach ($f in @(Get-ChildItem -LiteralPath $logDirAbs -File -Filter "$TaskId-$Stage.cycle*.attempt*" -ErrorAction SilentlyContinue)) {
                    $m = [regex]::Match($f.Name, '\.cycle(?<id>\d+)\.attempt')
                    if ($m.Success) {
                        $cid = 0
                        if ([int]::TryParse($m.Groups['id'].Value, [ref]$cid) -and $cid -gt $lastKnown) { $lastKnown = $cid }
                    }
                }
            }
            $nextId = $lastKnown + 1
        }
    }

    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        stage = $Stage
        cycles = @($existing) + @([ordered]@{ id = $nextId; token = ('cycle{0:D4}' -f $nextId); allocatedAt = [datetime]::UtcNow.ToString('o') })
    }
    Write-AtomicJson -Path $path -Value $value -Depth 6
    return @{ Id = $nextId; Token = ('cycle{0:D4}' -f $nextId) }
}