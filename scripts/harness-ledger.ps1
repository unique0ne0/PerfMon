# Harness ledger module — stage attempt ledger, chain runtime tracking, and chain summary.
# Depends on: harness-io.ps1 (Write-AtomicJson)
# Caller must provide: $LogDir, $TaskId, $TaskLogPrefix
# Also depends on main dispatcher functions: Resolve-RepoPath, Write-Log

function Get-StageLedgerPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$LogDir/$TaskId-$Stage-ledger.json")
}

function Read-StageLedger {
    param([string]$Stage)
    $path = Get-StageLedgerPath $Stage
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ schemaVersion = 1; attempts = [pscustomobject]@{} } }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json.attempts) { $json | Add-Member -NotePropertyName attempts -NotePropertyValue ([pscustomobject]@{}) -Force }
        return $json
    } catch {
        return [pscustomobject]@{ schemaVersion = 1; attempts = [pscustomobject]@{} }
    }
}


function Write-StageLedger {
    param([string]$Stage, [object]$Ledger)
    $path = Get-StageLedgerPath $Stage
    Write-AtomicJson -Path $path -Value $Ledger -Depth 6
}


function Record-StageAttempt {
    param([string]$Stage, [string]$Signature, [string]$FailureClass)
    $ledger = Read-StageLedger -Stage $Stage
    $prior = $ledger.attempts.$Signature
    $count = if ($prior) { [int]$prior.count + 1 } else { 1 }
    $entry = [pscustomobject]@{ count = $count; failureClass = $FailureClass; lastObservedAt = [datetime]::UtcNow.ToString('o') }
    $ledger.attempts | Add-Member -NotePropertyName $Signature -NotePropertyValue $entry -Force
    Write-StageLedger -Stage $Stage -Ledger $ledger

    $maxAllowed = if ($FailureClass -eq 'deterministic') { 1 } else { 3 }
    if ($count -ge $maxAllowed) {
        Write-BlockedMarker -Stage $Stage -Reason "시도 한도 도달 (${Signature}: ${count}회 / 상한 ${maxAllowed}회)" -OwnerTaskId $TaskId -OwnerProcessId $PID
        return @{ Blocked = $true; Count = $count; MaxAllowed = $maxAllowed }
    }
    return @{ Blocked = $false; Count = $count; MaxAllowed = $maxAllowed }
}

# ── CFG065: 체인 단위 런타임 기록 ─────────────────────────────────────────
# 각 단계의 실제 모델(family·adapter·principal)을 덮어쓰이지 않는 곳에 남긴다.
# 기존 stage-state.json은 단계 진입 시 -Model $null로 초기화되고, 단계 원장은
# CFG027/CFG037 구조적 수정 시 초기화되므로 체인 단위 독립 기록을 신설한다.

function Get-ChainRuntimePath {
    return (Resolve-RepoPath "$LogDir/$TaskId-chain-runtime.json")
}


function Read-ChainRuntime {
    $path = Get-ChainRuntimePath
    if (-not (Test-Path -LiteralPath $path)) {
        return [pscustomobject]@{ schemaVersion = 1; taskId = $TaskId; stages = [pscustomobject]@{} }
    }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json.stages) { $json | Add-Member -NotePropertyName stages -NotePropertyValue ([pscustomobject]@{}) -Force }
        return $json
    } catch {
        return [pscustomobject]@{ schemaVersion = 1; taskId = $TaskId; stages = [pscustomobject]@{} }
    }
}


function Write-ChainRuntime {
    param([object]$Runtime)
    $path = Get-ChainRuntimePath
    Write-AtomicJson -Path $path -Value $Runtime -Depth 6
}


function Reset-ChainRuntime {
    $runtime = [pscustomobject]@{ schemaVersion = 1; taskId = $TaskId; stages = [pscustomobject]@{} }
    Write-ChainRuntime -Runtime $runtime
    Write-Log "체인 런타임 초기화 (TaskId: $TaskId)" INFO
}


function Record-ChainRuntime {
    param([string]$Stage, [string]$Model, [string]$Status, [string]$Reason, [string]$ProfileName, [string]$Adapter)
    $runtime = Read-ChainRuntime
    $family = ''; $adapter = ''; $principal = ''
    $catalog = $null
    if ($script:ProfileConfig -and $script:ProfileConfig.modelCatalog -and $Model) {
        $catalog = $script:ProfileConfig.modelCatalog.$Model
    } elseif ($Model) {
        try {
            $cfgPath = Join-Path $PSScriptRoot 'model-profiles.json'
            if (Test-Path -LiteralPath $cfgPath) {
                $cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($cfg.modelCatalog) { $catalog = $cfg.modelCatalog.$Model }
            }
        } catch { }
    }
    if ($catalog) {
        $family = [string]$catalog.family
        $principal = [string]$catalog.principal
        if ($catalog.adapter) { $adapter = [string]$catalog.adapter }
    }
    # CFG079: 호출자가 슬롯 어댑터를 직접 주면 catalog 부재(adapter 빈 값)와 무관하게 채운다 —
    # qa/integration 모델(gpt-5.6-terra, sonnet 등)은 modelCatalog에 없어 adapter가 빠지던 결함.
    if (-not $adapter -and $Adapter) { $adapter = [string]$Adapter }
    if (-not $principal -and $Adapter) { $principal = [string]$Adapter }
    # Planning is not spawned by this dispatcher, so its identity comes from the
    # packet's Runtime Role Binding rather than modelCatalog's route slots.
    if ($ProfileName -and $script:ProfileConfig -and $script:ProfileConfig.profiles) {
        $profile = $script:ProfileConfig.profiles.$ProfileName
        if ($profile) {
            if (-not $Model) { $Model = [string]$profile.model }
            if (-not $family) { $family = [string]$profile.family }
            if (-not $adapter) { $adapter = [string]$profile.adapter }
            if (-not $principal) { $principal = [string]$profile.adapter }
        }
    }
    $entry = [pscustomobject]@{
        stage = $Stage
        model = $Model
        family = $family
        adapter = $adapter
        principal = $principal
        status = $Status
        reason = $Reason
        recordedAt = [datetime]::UtcNow.ToString('o')
    }
    $runtime.stages | Add-Member -NotePropertyName $Stage -NotePropertyValue $entry -Force
    Write-ChainRuntime -Runtime $runtime
    Write-Log "체인 런타임 기록: [$Stage] model=$Model family=$family status=$Status" INFO
}


function Test-ChainAdjacency {
    param([string]$Stage)
    $predecessorMap = @{ 'impl' = 'planning'; 'qa' = 'impl'; 'integration' = 'qa' }
    if (-not $predecessorMap.ContainsKey($Stage)) {
        return @{ Allowed = $true }
    }
    $predecessor = $predecessorMap[$Stage]
    $runtime = Read-ChainRuntime
    $preEntry = $runtime.stages.$predecessor
    if (-not $preEntry) {
        return @{ Allowed = $true }
    }
    $preFamily = [string]$preEntry.family
    $preModel = [string]$preEntry.model
    $preStatus = [string]$preEntry.status
    if ($preStatus -eq 'manual' -or $preModel -eq 'human' -or $preModel -eq 'unknown' -or -not $preModel) {
        return @{ Allowed = $true }
    }
    if (-not $preFamily -or $preFamily -eq 'unknown') {
        return @{ Allowed = $true }
    }
    $currentFamily = ''
    $currentModel = ''
    if ($Stage -eq 'impl' -and $script:PipelineRouting) {
        $implModels = @($script:PipelineRouting.ImplementationModels)
        if ($implModels.Count -gt 0) {
            $firstModel = $implModels[0]
            $currentModel = $firstModel
            if ($script:ProfileConfig -and $script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$firstModel) {
                $currentFamily = [string]$script:ProfileConfig.modelCatalog.$firstModel.family
            }
        }
    } else {
        $currentStageCfg = $null
        if ($StageConfig) { $currentStageCfg = $StageConfig[$Stage] }
        if ($currentStageCfg) {
            $models = @()
            if ($currentStageCfg.ModelChain) { $models = @($currentStageCfg.ModelChain) }
            elseif ($currentStageCfg.ModelFallback) { $models = @($currentStageCfg.ModelFallback) }
            elseif ($currentStageCfg.Model) { $models = @($currentStageCfg.Model) }
            if ($models.Count -gt 0) {
                $currentModel = $models[0]
                $cat = $null
                if ($script:ProfileConfig -and $script:ProfileConfig.modelCatalog) { $cat = $script:ProfileConfig.modelCatalog.$currentModel }
                if ($cat) { $currentFamily = [string]$cat.family }
            }
        }
    }
    if (-not $currentFamily -or $currentFamily -eq 'unknown') {
        return @{ Allowed = $true }
    }
    if ($preFamily -eq $currentFamily) {
        return @{
            Allowed = $false
            Predecessor = $predecessor
            PredecessorModel = $preModel
            PredecessorFamily = $preFamily
            CurrentFamily = $currentFamily
            CurrentModel = $currentModel
        }
    }
    return @{ Allowed = $true }
}


function Write-ChainBlockedMarker {
    param([string]$Reason, [string]$PredecessorStage, [string]$PredecessorModel, [string]$CurrentStage, [string]$CurrentModel, [string[]]$RecoverySteps)
    $path = Resolve-RepoPath "$LogDir/$TaskId-blocked.json"
    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        timestamp = [datetime]::UtcNow.ToString('o')
        reason = $Reason
        stages = [ordered]@{
            predecessor = [ordered]@{ stage = $PredecessorStage; model = $PredecessorModel }
            current = [ordered]@{ stage = $CurrentStage; model = $CurrentModel }
        }
        recoverySteps = @($RecoverySteps)
    }
    Write-AtomicJson -Path $path -Value $value -Depth 6
    Write-Log "중단 마커 기록: $path" WARN
}

# CFG079: 단계 완료 시 라우터 행의 "다음 단계"·갱신일 칸을 하네스가 직접 갱신한다.
# 라우터 행 갱신을 에이전트 기탁에 두면 갱신이 늦어지거나 누락되고, 대시보드의 Owner 칸이
# 오래된 산문("다음: ⑤(기획팀)")을 그대로 보여준다. 하네스는 단계 성공(verify 통과)을
# 기계적으로 확정하므로 그 시점의 다음 단계·담당을 SSOT에서 파생해 쓴다.
# 원칙: 자기 작업 행만 고친다(타 작업 행 변조는 Test-ProtocolPollution이 이미 차단).
# 갱신 칸 외의 다른 칸(상태·Blocked by 등)은 절대 손대지 않는다 — 상태 전환 권한은 기획팀에 남는다.

function Get-RouterNextStageLabel {
    param([string]$Stage)
    switch ($Stage) {
        'impl'        { return '③ 자체 리뷰(개발1팀)' }
        'qa'          { return '⑤ 최종 리뷰 및 Integration(기획팀)' }
        'integration' { return $null }
    }
    return $null
}

function Update-RouterRowAfterStage {
    param([string]$Stage, [string]$PacketPath)
    if (-not (Test-Path -LiteralPath (Resolve-RepoPath '.agents/briefs/handoff-log.md'))) { return $false }
    $next = Get-RouterNextStageLabel -Stage $Stage
    if (-not $next) { return $false }
    $routerPath = Resolve-RepoPath '.agents/briefs/handoff-log.md'
    $lines = @(Get-Content -LiteralPath $routerPath -Encoding UTF8)
    $changed = $false
    $normSelf = Get-NormalizedTaskId -TaskId $TaskId
    $stamp = [datetime]::Now.ToString('yyyy-MM-dd')
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\s*\|') { continue }
        $cells = @($lines[$i].Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($cells.Count -lt 3) { continue }
        if ((Get-NormalizedTaskId -TaskId $cells[0]) -ne $normSelf) { continue }
        # "다음 단계" 칸(3번째 이후)과 갱신 칸(마지막)을 찾는다 — 7컬럼/6컬럼 방언 모두 지원.
        $stageIdx = -1
        for ($c = 2; $c -lt $cells.Count; $c++) {
            if ($cells[$c] -match '다음\s*:|다음 단계') { $stageIdx = $c; break }
        }
        if ($stageIdx -lt 0) { $stageIdx = 3 }
        if ($stageIdx -ge $cells.Count) { continue }
        $newStage = "작업 $TaskId $Stage 단계 완료 — 다음: $next"
        if ($cells[$stageIdx] -eq $newStage) { return $false }
        $cells[$stageIdx] = $newStage
        # 갱신 칸은 마지막 칸(날짜만 있거나 비어 있음). 다른 칸과 구분되도록 날짜만 교체.
        $lastIdx = $cells.Count - 1
        if ($lastIdx -gt $stageIdx -and $cells[$lastIdx] -match '^\d{4}-\d{2}-\d{2}$') {
            $cells[$lastIdx] = $stamp
        }
        $lines[$i] = '| ' + ($cells -join ' | ') + ' |'
        $changed = $true
        break
    }
    if ($changed) {
        [System.IO.File]::WriteAllLines($routerPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "✅ 라우터 행 자동 갱신 [$TaskId] — $newStage" SUCCESS
    }
    return $changed
}

#endregion 승인·continuation·시도 판정·스테이지 원장
#region 원장 게이트·패킷·라우터 파싱·관측
# CFG037: QA 단계가 완료된 후 qa-verdict.json이 없으면 하네스가 직접 기록한다.
# QA 모델이 프롬프트 지시를 따르지 않거나 크래시·hang으로 파일 작성 전에 종료되면
# "verdict=fail"이 영원히 기록되지 않아 대시보드가 실제 QA 실패를 숨기는 결함이 있었다
# (실측: 34개 qa-verdict.json 전부 pass, fail 0건).

function Reset-StageLedger {
    param([string]$Stage, [string]$Reason)
    $prior = Read-StageLedger -Stage $Stage
    $priorCount = @($prior.attempts.psobject.Properties).Count
    $empty = [pscustomobject]@{ schemaVersion = 1; attempts = [pscustomobject]@{} }
    Write-StageLedger -Stage $Stage -Ledger $empty
    Clear-BlockedMarker -Stage $Stage
    $auditPath = Resolve-RepoPath "$LogDir/$TaskId-$Stage-ledger-resets.log"
    $safeReason = ($Reason -replace '\|', '/').Trim()
    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] cleared $priorCount attempt(s), blocked marker 해제 — $safeReason"
    try {
        [System.IO.File]::AppendAllText($auditPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # 감사 로그 기록 실패가 초기화 자체를 막지 않는다 — 초기화는 이미 완료됐다.
    }
    Write-Log "🔄 [$Stage] 원장 초기화 완료 (기존 $priorCount건 삭제, 차단 마커 해제) — $safeReason" SUCCESS
}


function Write-ChainSummary {
    param(
        [ValidateSet('completed','blocked','failed','approval_required','judgment_required')][string]$State,
        [object[]]$Stages,
        [string[]]$Warnings,
        [datetime]$StartedAt,
        [object]$PipelineBefore,
        [object]$PipelineAfter,
        [object]$TreeBefore,
        [object]$TreeAfter,
        [object]$QaVerdict
    )
    $summaryPath = Resolve-RepoPath "$LogDir/$TaskId-chain-summary.json"
    $parent = Split-Path -Parent $summaryPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        driverCycleId = $env:ORCHESTRATION_DRIVER_CYCLE_ID
        state = $State
        startedAt = $StartedAt.ToUniversalTime().ToString('o')
        completedAt = [datetime]::UtcNow.ToString('o')
        elapsedSeconds = [math]::Round(((Get-Date) - $StartedAt).TotalSeconds, 1)
        stages = @($Stages)
        qaVerdict = $QaVerdict
        pipelineStatus = @{ before = $PipelineBefore; after = $PipelineAfter }
        tree = @{ before = $TreeBefore; after = $TreeAfter; changedFileCount = if ($TreeAfter -and $TreeAfter.Dirty) { @(($TreeAfter.Dirty -split "`r?`n") | Where-Object { $_ }).Count } else { 0 }; fingerprintComparable = [bool]($TreeBefore -and $TreeAfter -and $TreeBefore.FingerprintOk -and $TreeAfter.FingerprintOk) }
        warnings = @($Warnings)
        runtimeRoleBinding = $script:RuntimeRoleBinding
        logDirectory = $LogDir
    }
    Write-AtomicJson -Path $summaryPath -Value $value -Depth 8
    return $summaryPath
}

# 락을 잡고 한 단계를 실행한다. 락 획득 실패 시 디스패치 자체를 하지 않는다 —
# Dispatch-Stage 안에서 잡으면 QA의 "이전 verdict 삭제"가 먼저 돌아, 차단된 실행이
# 정상 실행 중인 QA의 판정 파일을 지워버린다.

