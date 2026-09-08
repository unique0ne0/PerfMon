# Harness session/continuation module — session ID extraction, continuation commands, approval records, and hang retry.
# Depends on: harness-io.ps1 (Write-AtomicJson), harness-stage-engine.ps1 (New-DispatchScript)
# Caller must provide: $RepoRoot, $LogDir, $TaskId, $StageConfig, $HardTimeoutProgressBytes
# Also depends on main dispatcher functions: Resolve-RepoPath, Write-Log, ConvertTo-BashSingleQuoted

function Get-AttemptLogPath {
    param([string]$LogFile, [int]$CycleNumber, [int]$AttemptNumber)
    $extension = [System.IO.Path]::GetExtension($LogFile)
    $base = $LogFile.Substring(0, $LogFile.Length - $extension.Length)
    return ('{0}.cycle{1:D4}.attempt{2:D2}{3}' -f $base, $CycleNumber, $AttemptNumber, $extension)
}

function Update-LatestAttemptLog {
    param([string]$AttemptLog, [string]$LatestLog)
    $attemptAbs = Resolve-RepoPath $AttemptLog
    $latestAbs = Resolve-RepoPath $LatestLog
    if (-not (Test-Path $attemptAbs)) { return }
    [System.IO.File]::Copy($attemptAbs, $latestAbs, $true)
}

function Get-ApprovalRecordPath {
    param([string]$Stage, [int]$CycleNumber)
    # 승인 요청 자체도 cycle의 불변 증거다. stage별 단일 파일이면 연속된 승인 요청이
    # 앞 기록을 덮어 감사 공백이 생기므로, 반드시 cycle을 경로에 포함한다.
    return (Resolve-RepoPath ('{0}/{1}-{2}-cycle{3:D4}-approval.json' -f $LogDir, $TaskId, $Stage, $CycleNumber))
}

function Get-AntigravityTerminalEvidence {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    foreach ($line in @(Get-Content -LiteralPath $logAbs -Tail 80 -ErrorAction SilentlyContinue)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $eventName = [string](@($event.event, $event.type, $event.kind) | Where-Object { $_ } | Select-Object -First 1)
        $rawError = (@($event.error, $event.message, $event.detail, $event.result.error, $event.result.message) | Where-Object { $_ } | Select-Object -First 1)
        $approvalEventNames = @('error', 'result', 'terminal', 'permission', 'permission_denied', 'tool_confirmation')
        if ($approvalEventNames -notcontains $eventName.ToLowerInvariant() -or -not $rawError) { continue }
        $rawError = [string]$rawError
        if ($rawError -notmatch '(?i)(permission.+headless mode|requir[ea][sd]?\s+the\s+["``]?command["``]?\s+permission|auto-denied.+permission|user denied permission|permission check failed)') { continue }
        $target = (@($event.command, $event.input.command, $event.arguments.command, $event.tool_input.command) | Where-Object { $_ } | Select-Object -First 1)
        $conversationId = (@($event.conversation_id, $event.result.conversation_id) | Where-Object { $_ } | Select-Object -First 1)
        $stepId = (@($event.step_id, $event.step, $event.result.step_id) | Where-Object { $_ } | Select-Object -First 1)
        return [pscustomobject]@{
            Target = if ($target) { [string]$target } else { $null }
            TargetExtractionReason = if ($target) { $null } else { 'structured terminal approval event omitted command' }
            ConversationId = if ($conversationId) { [string]$conversationId } else { $null }
            StepId = if ($stepId) { [string]$stepId } else { $null }
            RawError = $rawError
        }
    }
    return $null
}

function Write-ApprovalRecord {
    param([string]$Stage, [int]$CycleNumber, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [object]$Evidence)
    $path = Get-ApprovalRecordPath -Stage $Stage -CycleNumber $CycleNumber
    $parent = Split-Path -Parent $path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $adapter = if ($StageConfig[$Stage].Adapter) { $StageConfig[$Stage].Adapter } else { 'opencode' }
    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        stage = $Stage
        cycle = $CycleNumber
        attempt = $AttemptNumber
        adapter = $adapter
        model = $Model
        timestamp = [datetime]::UtcNow.ToString('o')
        approval_required = $true
        target = if ($Evidence) { $Evidence.Target } else { $null }
        targetExtractionReason = if ($Evidence) { $Evidence.TargetExtractionReason } else { 'no structured terminal approval evidence' }
        conversationId = if ($Evidence) { $Evidence.ConversationId } else { $null }
        stepId = if ($Evidence) { $Evidence.StepId } else { $null }
        rawError = if ($Evidence) { $Evidence.RawError } else { $null }
        evidencePaths = @($AttemptLog)
        decisionNeeded = 'Inspect the exact target, arrange approval outside the headless process, then start one explicit fresh stage dispatch (new cycle).'
        status = 'pending'
    }
    Write-AtomicJson -Path $path -Value $value -Depth 6
    return $path
}

function Resolve-ApprovalRecords {
    param([string]$Stage, [int]$ResolvingCycle)
    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path -LiteralPath $logDirAbs)) { return }
    # 같은 TaskId/stage의 모든 pending cycle을 해소한다. 파일은 수정만 하고 절대 삭제하지 않는다.
    foreach ($path in @(Get-ChildItem -LiteralPath $logDirAbs -Filter ("$TaskId-$Stage-cycle*-approval.json") -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
      try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $record -or $record.taskId -ne $TaskId -or $record.stage -ne $Stage -or $record.status -ne 'pending') { continue }
        $record.status = 'resolved'
        $record | Add-Member -NotePropertyName resolvedCycle -NotePropertyValue $ResolvingCycle -Force
        $record | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
        Write-AtomicJson -Path $path -Value $record -Depth 6
        Write-Log "✅ [$TaskId/$Stage] 승인 대기(cycle $($record.cycle))를 fresh cycle $ResolvingCycle 성공으로 해소 — 감사 기록 보존" SUCCESS
      } catch {
        Write-Log "승인 기록 해소 중 실패(감사에 영향 없음): $($_.Exception.Message)" WARN
      }
    }
}

function Get-AntigravityConversationId {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    $ids = @()
    foreach ($line in @(Get-Content -LiteralPath $logAbs -ErrorAction SilentlyContinue)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $eventName = [string](@($event.event, $event.type, $event.kind) | Where-Object { $_ } | Select-Object -First 1)
        if (@('init', 'result') -notcontains $eventName.ToLowerInvariant()) { continue }
        $candidate = @($event.conversation_id, $event.result.conversation_id) | Where-Object { $_ } | Select-Object -First 1
        if ($candidate -and [string]$candidate -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            $ids += ([string]$candidate).ToLowerInvariant()
        }
    }
    $ids = @($ids | Select-Object -Unique)
    if ($ids.Count -ne 1) { return $null }
    return $ids[0]
}

function Get-OpencodeSessionId {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    $sessionIds = @()
    foreach ($line in @(Get-Content -LiteralPath $logAbs -ErrorAction SilentlyContinue)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $sid = [string]$event.sessionID
        if ($sid -and $sid -match '^ses_[A-Za-z0-9]+$') {
            $sessionIds += $sid
        }
    }
    $sessionIds = @($sessionIds | Select-Object -Unique)
    if ($sessionIds.Count -ne 1) { return $null }
    return $sessionIds[0]
}

function Get-CodexSessionId {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    $sessionIds = @()
    foreach ($line in @(Get-Content -LiteralPath $logAbs -ErrorAction SilentlyContinue)) {
        if ($line -match 'session id:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            $sessionIds += $Matches[1].ToLowerInvariant()
        }
    }
    $sessionIds = @($sessionIds | Select-Object -Unique)
    if ($sessionIds.Count -ne 1) { return $null }
    return $sessionIds[0]
}

function Test-AntigravityPrintTimeout {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $false }
    $tail = (Get-Content -LiteralPath $logAbs -Tail 80 -ErrorAction SilentlyContinue) -join "`n"
    return $tail -match '(?i)(print mode:\s*timed out|timeout waiting for response|timed out after\s+\d+\s+polls)'
}

function Test-AntigravityContinuationActivity {
    param([string]$AttemptLog, [Int64]$LogStartBytes = 0, [double]$RecentWindowMinutes = 10)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $false }
    $logItem = Get-Item -LiteralPath $logAbs
    $growth = [math]::Max(0, $logItem.Length - $LogStartBytes)
    # 실행 중인 프로세스의 유연 연장과 같은 창을 사용한다. 종료된 provider CLI에는
    # CPU/I/O를 다시 관찰할 수 없으므로, 마지막 stream-json 기록 시점이 이 창 안에
    # 있어야 한다. 초반 출력만 남기고 오래 멈춘 세션은 누적 바이트가 커도 재개하지 않는다.
    $recent = ([datetime]::UtcNow - $logItem.LastWriteTimeUtc).TotalMinutes -le $RecentWindowMinutes
    return $growth -ge $HardTimeoutProgressBytes -and $recent
}

function Get-ContinuationRecordPath {
    param([string]$Stage, [int]$CycleNumber)
    return (Resolve-RepoPath ('{0}/{1}-{2}-cycle{3:D4}-continuation.json' -f $LogDir, $TaskId, $Stage, $CycleNumber))
}

function Write-ContinuationRecord {
    param([string]$Stage, [int]$CycleNumber, [int]$AttemptNumber, [string]$AttemptLog, [string]$ConversationId, [bool]$Active, [bool]$Resumed, [string]$Reason)
    $path = Get-ContinuationRecordPath -Stage $Stage -CycleNumber $CycleNumber
    $record = $null
    if (Test-Path -LiteralPath $path) {
        try { $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $record = $null }
    }
    if ($null -eq $record) {
        $record = [ordered]@{ schemaVersion = 1; taskId = $TaskId; stage = $Stage; cycle = $CycleNumber; segments = @() }
    }
    $segment = [ordered]@{ attempt = $AttemptNumber; timestamp = [datetime]::UtcNow.ToString('o'); attemptLog = $AttemptLog; conversationId = $ConversationId; active = $Active; resumed = $Resumed; reason = $Reason }
    $record.segments = @($record.segments) + @($segment)
    Write-AtomicJson -Path $path -Value $record -Depth 8
    return $path
}

function Build-AntigravityContinuationCommand {
    param([hashtable]$Config, [string]$Model, [string]$ConversationId)
    if (-not $Config.ProjectId -or -not $ConversationId) { throw 'Antigravity continuation requires project and conversation IDs.' }
    $agyCommand = if ($Config.Executable) { ConvertTo-BashSingleQuoted ([string]$Config.Executable).Replace('\\','/') } else { 'agy' }
    $prompt = ConvertTo-BashSingleQuoted 'Continue the same assigned stage from the existing conversation. Do not restart discovery, do not create a fresh dispatch cycle, and preserve all existing safety restrictions.'
    return "$agyCommand --project $($Config.ProjectId) --model $Model --mode accept-edits --output-format stream-json --print-timeout 25m --conversation $ConversationId --print $prompt"
}

function Build-OpencodeContinuationCommand {
    param([hashtable]$Config, [string]$Model, [string]$SessionId)
    if (-not $SessionId) { throw 'Opencode continuation requires session ID.' }
    $prompt = ConvertTo-BashSingleQuoted 'Continue the same assigned stage from the existing session. Do not restart discovery, do not create a fresh dispatch cycle, and preserve all existing safety restrictions.'
    return "opencode run --pure --auto -m $Model -s $SessionId $prompt"
}

function Build-CodexContinuationCommand {
    param([hashtable]$Config, [string]$Model, [string]$SessionId)
    if (-not $SessionId) { throw 'Codex continuation requires session ID.' }
    $prompt = ConvertTo-BashSingleQuoted 'Continue the same assigned stage from the existing session. Do not restart discovery, do not create a fresh dispatch cycle, and preserve all existing safety restrictions.'
    return "codex exec resume $SessionId -m $Model --dangerously-bypass-approvals-and-sandbox -o $(ConvertTo-BashSingleQuoted $Config.ReportFile) $prompt"
}

function Prepare-HangRetry {
    param([string]$Stage, [hashtable]$config, $Cycle, $Attempt, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [double]$LogicalHardLimit, $Before)

    Write-KilledLeftover -Before $Before -Stage $Stage -Context "1차 시도 강제 종료"
    $hangSessionId = $null
    $hangActive = $false
    if ($config.Adapter -eq 'opencode') {
        $hangSessionId = Get-OpencodeSessionId -AttemptLog $AttemptLog
    } elseif ($config.Adapter -eq 'codex') {
        $hangSessionId = Get-CodexSessionId -AttemptLog $AttemptLog
    }
    $toolCmd = $null
    if ($hangSessionId) {
        $hangActivityWindowMinutes = [Math]::Max(1, [Math]::Round($LogicalHardLimit / 3.0, 2))
        $hangActive = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $hangActivityWindowMinutes
    }
    if ($hangSessionId -and $hangActive) {
        $continuationPath = Write-ContinuationRecord -Stage $Stage -CycleNumber $Cycle.Id -AttemptNumber $AttemptNumber -AttemptLog $AttemptLog -ConversationId $hangSessionId -Active $hangActive -Resumed $true -Reason 'hang retry; resume same session'
        if ($config.Adapter -eq 'opencode') {
            $toolCmd = Build-OpencodeContinuationCommand -Config $config -Model $Model -SessionId $hangSessionId
        } else {
            $toolCmd = Build-CodexContinuationCommand -Config $config -Model $Model -SessionId $hangSessionId
        }
        Write-Log "⚠️ HANG [1/2] $Stage — 강제 종료 전 세션($hangSessionId) 이어받아 1회 재디스패치 (기록: $continuationPath)" WARN
    } else {
        Write-Log "⚠️ HANG [1/2] $Stage — 동일 명령으로 1회 재디스패치" WARN
    }
    return @{ ShouldRetry = $true; ToolCmd = $toolCmd }
}
