param(
    [switch]$CheckAndRecord,
    [string]$ProjectRoot,
    [string]$TaskId,
    [string]$Stage,
    [ValidateSet('planning','orchestration','implementation','qa','integration','unknown')][string]$Role = 'unknown',
    [string]$DriverCycleId,
    [string]$TelemetryPath,
    [datetime]$Now = ([datetime]::UtcNow)
)

$ErrorActionPreference = 'Stop'

function Read-HealthState {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json) }
    catch { Write-Output "session health state is unreadable; starting a new activity window"; return $null }
}

function Read-Telemetry {
    param([string]$Path, [ref]$Diagnostic)
    $Diagnostic.Value = $null
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $telemetry = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($telemetry.observedAt) {
            $observedAt = [datetime]::Parse([string]$telemetry.observedAt).ToUniversalTime()
            if (($Now.ToUniversalTime() - $observedAt).TotalHours -gt 2 -or $observedAt -gt $Now.ToUniversalTime()) {
                $Diagnostic.Value = 'session telemetry is stale; telemetry-specific warnings skipped'
                return $null
            }
        }
        return $telemetry
    } catch { $Diagnostic.Value = 'session telemetry is unreadable; telemetry-specific warnings skipped'; return $null }
}

function Add-ThresholdWarning {
    param([System.Collections.ArrayList]$Warnings, [hashtable]$Issued, [string]$Key, [string]$Message, [datetime]$Current)
    $last = $null
    if ($Issued.ContainsKey($Key)) {
        [datetime]$parsedLast = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Issued[$Key], [ref]$parsedLast)) { $last = $parsedLast }
    }
    if ($null -eq $last -or ($Current.ToUniversalTime() - $last.ToUniversalTime()).TotalMinutes -ge 60) {
        [void]$Warnings.Add($Message)
        $Issued[$Key] = $Current.ToUniversalTime().ToString('o')
    }
}

if (-not $CheckAndRecord) { return }
if ([string]::IsNullOrWhiteSpace($ProjectRoot)) { throw 'ProjectRoot is required.' }
$logs = Join-Path $ProjectRoot '.agents\briefs\logs'
if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
$statePath = Join-Path $logs '.session-health.json'
if ([string]::IsNullOrWhiteSpace($TelemetryPath)) { $TelemetryPath = Join-Path $logs '.session-telemetry.json' }
$current = $Now.ToUniversalTime()
$previous = Read-HealthState -Path $statePath
$isConversationRole = $Role -eq 'planning' -or $Role -eq 'orchestration'
$previousSchemaVersion = 0
if ($previous -and $previous.schemaVersion) {
    try { $previousSchemaVersion = [int]$previous.schemaVersion } catch { $previousSchemaVersion = 0 }
}
$convLastActivity = $null
$convWindowStartedAt = $current
$convPreviousWindow = $null
if ($previousSchemaVersion -ge 2 -and $previous.lastActivityAt) {
    [datetime]$parsedConv = [datetime]::MinValue
    if ([datetime]::TryParse([string]$previous.lastActivityAt, [ref]$parsedConv)) { $convLastActivity = $parsedConv }
}
$convIdleHours = if ($convLastActivity) { [math]::Max(0, ($current - $convLastActivity.ToUniversalTime()).TotalHours) } else { $null }
if ($convLastActivity -and $convIdleHours -lt 2 -and $previous.activityWindowStartedAt) {
    [datetime]$parsedConvStart = [datetime]::MinValue
    if ([datetime]::TryParse([string]$previous.activityWindowStartedAt, [ref]$parsedConvStart) -and $parsedConvStart.ToUniversalTime() -le $current) { $convWindowStartedAt = $parsedConvStart.ToUniversalTime() }
} elseif ($previous -and $previous.activityWindowStartedAt -and $previousSchemaVersion -ge 2) {
    $convPreviousWindow = [ordered]@{ startedAt = $previous.activityWindowStartedAt; endedAt = if ($convLastActivity) { $convLastActivity.ToUniversalTime().ToString('o') } else { $null } }
}
$pipelineLastActivity = $null
$pipelineWindowStartedAt = $current
$pipelinePreviousWindow = $null
if ($previousSchemaVersion -ge 2 -and $previous.pipelineLastActivityAt) {
    [datetime]$parsedPipe = [datetime]::MinValue
    if ([datetime]::TryParse([string]$previous.pipelineLastActivityAt, [ref]$parsedPipe)) { $pipelineLastActivity = $parsedPipe }
}
$pipelineIdleHours = if ($pipelineLastActivity) { [math]::Max(0, ($current - $pipelineLastActivity.ToUniversalTime()).TotalHours) } else { $null }
if ($pipelineLastActivity -and $pipelineIdleHours -lt 2 -and $previous.pipelineActivityWindowStartedAt) {
    [datetime]$parsedPipeStart = [datetime]::MinValue
    if ([datetime]::TryParse([string]$previous.pipelineActivityWindowStartedAt, [ref]$parsedPipeStart) -and $parsedPipeStart.ToUniversalTime() -le $current) { $pipelineWindowStartedAt = $parsedPipeStart.ToUniversalTime() }
} elseif ($previous -and $previous.pipelineActivityWindowStartedAt -and $previousSchemaVersion -ge 2) {
    $pipelinePreviousWindow = [ordered]@{ startedAt = $previous.pipelineActivityWindowStartedAt; endedAt = if ($pipelineLastActivity) { $pipelineLastActivity.ToUniversalTime().ToString('o') } else { $null } }
}
$issued = @{}
if ($previous -and $previous.issuedWarnings) { foreach ($property in @($previous.issuedWarnings.psobject.Properties)) { $issued[$property.Name] = [string]$property.Value } }
$warnings = New-Object System.Collections.ArrayList
if ($isConversationRole) {
    if ($convIdleHours -ge 1) { Add-ThresholdWarning -Warnings $warnings -Issued $issued -Key 'idle-resume' -Message 'idle for 60+ minutes: record the packet handoff before resuming an old conversation' -Current $current }
    $activityHours = [math]::Max(0, ($current - $convWindowStartedAt).TotalHours)
    foreach ($threshold in @(4, 6, 8)) {
        if ($activityHours -ge $threshold) {
            $message = if ($threshold -eq 8) { 'project continuous activity reached 8h: record Task Handoff Summary and start a new conversation/session' } else { "project continuous activity reached ${threshold}h: consider a fresh conversation/session" }
            Add-ThresholdWarning -Warnings $warnings -Issued $issued -Key "activity-$threshold" -Message $message -Current $current
        }
    }
}
$telemetryDiagnostic = $null
$telemetry = Read-Telemetry -Path $TelemetryPath -Diagnostic ([ref]$telemetryDiagnostic)
if ($telemetryDiagnostic) {
    $diagnosticKey = if ($telemetryDiagnostic -match 'stale') { 'telemetry-stale' } else { 'telemetry-unreadable' }
    Add-ThresholdWarning -Warnings $warnings -Issued $issued -Key $diagnosticKey -Message $telemetryDiagnostic -Current $current
}
if ($telemetry) {
    if ($telemetry.sessionDurationMs -ge 0) {
        foreach ($threshold in @(4, 6, 8)) {
            if (($telemetry.sessionDurationMs / 3600000) -ge $threshold) { Add-ThresholdWarning -Warnings $warnings -Issued $issued -Key "session-$threshold" -Message "actual session duration reached ${threshold}h" -Current $current }
        }
    }
    foreach ($threshold in @(80000, 100000)) {
        if ($telemetry.contextTokens -ge $threshold) { Add-ThresholdWarning -Warnings $warnings -Issued $issued -Key "context-$threshold" -Message "context reached $threshold tokens" -Current $current }
    }
    foreach ($field in @('contextUsedPercentage', 'fiveHourUsedPercentage', 'sevenDayUsedPercentage')) {
        if ($telemetry.$field -ge 70) { Add-ThresholdWarning -Warnings $warnings -Issued $issued -Key $field -Message "$field reached $($telemetry.$field)%" -Current $current }
    }
}
$finalConvWindowStartedAt = if ($isConversationRole) { $convWindowStartedAt } elseif ($previous -and $previous.activityWindowStartedAt -and $previousSchemaVersion -ge 2) { [datetime]$parsed = [datetime]::MinValue; if ([datetime]::TryParse([string]$previous.activityWindowStartedAt, [ref]$parsed)) { $parsed.ToUniversalTime() } else { $current } } else { $current }
$finalConvLastActivityAt = if ($isConversationRole) { $current } elseif ($convLastActivity) { $convLastActivity.ToUniversalTime() } else { $null }
$finalPipeWindowStartedAt = if (-not $isConversationRole) { $pipelineWindowStartedAt } elseif ($previous -and $previous.pipelineActivityWindowStartedAt -and $previousSchemaVersion -ge 2) { [datetime]$parsed = [datetime]::MinValue; if ([datetime]::TryParse([string]$previous.pipelineActivityWindowStartedAt, [ref]$parsed)) { $parsed.ToUniversalTime() } else { $current } } else { $current }
$finalPipeLastActivityAt = if (-not $isConversationRole) { $current } elseif ($pipelineLastActivity) { $pipelineLastActivity.ToUniversalTime() } else { $null }
$state = [ordered]@{ schemaVersion = 2; activityWindowStartedAt = $finalConvWindowStartedAt.ToString('o'); previousWindow = $convPreviousWindow; lastActivityAt = if ($finalConvLastActivityAt) { $finalConvLastActivityAt.ToString('o') } else { $null }; pipelineActivityWindowStartedAt = $finalPipeWindowStartedAt.ToString('o'); pipelinePreviousWindow = $pipelinePreviousWindow; pipelineLastActivityAt = if ($finalPipeLastActivityAt) { $finalPipeLastActivityAt.ToString('o') } else { $null }; role = $Role; taskId = $TaskId; stage = $Stage; driverCycleId = $DriverCycleId; issuedWarnings = $issued }
$tempPath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
[System.IO.File]::WriteAllText($tempPath, ($state | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
Move-Item -LiteralPath $tempPath -Destination $statePath -Force
$warnings | ForEach-Object { Write-Output $_ }
