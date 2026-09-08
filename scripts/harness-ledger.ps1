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
    param([string]$Stage, [string]$Model, [string]$Status, [string]$Reason, [string]$ProfileName)
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

