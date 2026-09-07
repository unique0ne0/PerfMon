param(
    [string]$ProjectRoot,
    [int]$ContextWindowSize = 200000
)

$ErrorActionPreference = 'Stop'

function Exit-Silent { exit 0 }

# A hook failure must never reject a prompt.  This also covers state-directory
# creation and atomic-state replacement failures below, outside the parsing
# try/catch blocks.
trap { Exit-Silent }

try {
    $stdinText = [Console]::In.ReadToEnd()
    if ([string]::IsNullOrWhiteSpace($stdinText)) { Exit-Silent }
    $hookPayload = $stdinText | ConvertFrom-Json
} catch { Exit-Silent }

$transcriptPath = $null
$sessionId = $null
if ($hookPayload.transcript_path) { $transcriptPath = [string]$hookPayload.transcript_path }
if ($hookPayload.session_id) { $sessionId = [string]$hookPayload.session_id }
if ([string]::IsNullOrWhiteSpace($transcriptPath) -or [string]::IsNullOrWhiteSpace($sessionId)) { Exit-Silent }
if (-not (Test-Path -LiteralPath $transcriptPath)) { Exit-Silent }

if ([string]::IsNullOrWhiteSpace($ProjectRoot)) {
    if ($hookPayload.cwd) { $ProjectRoot = [string]$hookPayload.cwd } else { Exit-Silent }
}

$now = [datetime]::UtcNow
$logs = Join-Path $ProjectRoot '.agents\briefs\logs'
if (-not (Test-Path -LiteralPath $logs)) { New-Item -ItemType Directory -Path $logs -Force | Out-Null }
$statePath = Join-Path $logs '.session-health.json'

$state = $null
if (Test-Path -LiteralPath $statePath) {
    try { $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $state = $null }
}

$hookSessions = @{}
if ($state -and $state.hookSessions) {
    foreach ($prop in @($state.hookSessions.psobject.Properties)) {
        $hookSessions[$prop.Name] = $prop.Value
    }
}

$issued = @{}
if ($state -and $state.issuedWarnings) {
    foreach ($prop in @($state.issuedWarnings.psobject.Properties)) {
        $issued[$prop.Name] = [string]$prop.Value
    }
}

$sessionKey = "hook-$sessionId"
$firstTimestamp = $null
if ($hookSessions.ContainsKey($sessionKey)) {
    [datetime]$parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$hookSessions[$sessionKey], [ref]$parsed)) { $firstTimestamp = $parsed.ToUniversalTime() }
}

$lastContextTokens = $null

try {
    if (-not $firstTimestamp) {
        $reader = [System.IO.StreamReader]::new($transcriptPath, [System.Text.Encoding]::UTF8)
        try {
            while ($null -ne ($line = $reader.ReadLine())) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try {
                    $obj = $line | ConvertFrom-Json
                    if ($obj.type -eq 'user' -and $obj.timestamp) {
                        $firstTimestamp = [datetime]::Parse([string]$obj.timestamp).ToUniversalTime()
                        break
                    }
                } catch { continue }
            }
        } finally { $reader.Close() }
    }

    if (-not $firstTimestamp) { Exit-Silent }

    $tailLines = 200
    $tailContent = $null
    try { $tailContent = @(Get-Content -LiteralPath $transcriptPath -Tail $tailLines -Encoding UTF8) } catch { Exit-Silent }
    if (-not $tailContent) { Exit-Silent }

    for ($i = $tailContent.Count - 1; $i -ge 0; $i--) {
        $line = $tailContent[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $obj = $line | ConvertFrom-Json
            if ($obj.type -eq 'assistant' -and $obj.message -and $obj.message.usage) {
                $u = $obj.message.usage
                $inputT = 0; $cacheCreateT = 0; $cacheReadT = 0
                if ($u.input_tokens) { $inputT = [int]$u.input_tokens }
                if ($u.cache_creation_input_tokens) { $cacheCreateT = [int]$u.cache_creation_input_tokens }
                if ($u.cache_read_input_tokens) { $cacheReadT = [int]$u.cache_read_input_tokens }
                $lastContextTokens = $inputT + $cacheCreateT + $cacheReadT
                break
            }
        } catch { continue }
    }
} catch { Exit-Silent }

$warnings = New-Object System.Collections.ArrayList
$elapsedHours = [math]::Max(0, ($now - $firstTimestamp).TotalHours)

foreach ($threshold in @(4, 6, 8)) {
    if ($elapsedHours -ge $threshold) {
        $key = "${sessionKey}-activity-$threshold"
        $lastIssued = $null
        if ($issued.ContainsKey($key)) {
            [datetime]$parsedLast = [datetime]::MinValue
            if ([datetime]::TryParse([string]$issued[$key], [ref]$parsedLast)) { $lastIssued = $parsedLast }
        }
        if ($null -eq $lastIssued -or ($now - $lastIssued.ToUniversalTime()).TotalMinutes -ge 60) {
            $message = if ($threshold -eq 8) { "Session has been active for $([math]::Round($elapsedHours, 1))h (>=${threshold}h). Consider recording a handoff and starting a new session." } else { "Session has been active for $([math]::Round($elapsedHours, 1))h (>=${threshold}h). Consider a fresh session." }
            [void]$warnings.Add($message)
            $issued[$key] = $now.ToString('o')
        }
    }
}

if ($null -ne $lastContextTokens -and $ContextWindowSize -gt 0) {
    $usedPercentage = [math]::Round(($lastContextTokens / $ContextWindowSize) * 100, 1)
    if ($usedPercentage -ge 70) {
        $key = "${sessionKey}-context-70"
        $lastIssued = $null
        if ($issued.ContainsKey($key)) {
            [datetime]$parsedLast = [datetime]::MinValue
            if ([datetime]::TryParse([string]$issued[$key], [ref]$parsedLast)) { $lastIssued = $parsedLast }
        }
        if ($null -eq $lastIssued -or ($now - $lastIssued.ToUniversalTime()).TotalMinutes -ge 60) {
            [void]$warnings.Add("Context usage is at ${usedPercentage}% ($lastContextTokens / $ContextWindowSize tokens). Consider /compact or starting a new session.")
            $issued[$key] = $now.ToString('o')
        }
    }
}

$hookSessions[$sessionKey] = $firstTimestamp.ToString('o')

$updatedHookSessions = [ordered]@{}
foreach ($k in $hookSessions.Keys) { $updatedHookSessions[$k] = $hookSessions[$k] }
$updatedIssued = [ordered]@{}
foreach ($k in $issued.Keys) { $updatedIssued[$k] = $issued[$k] }

$stateObj = [ordered]@{ schemaVersion = 3; hookSessions = $updatedHookSessions; issuedWarnings = $updatedIssued }
if ($state) {
    foreach ($prop in @($state.psobject.Properties)) {
        if ($prop.Name -notin @('schemaVersion', 'hookSessions', 'issuedWarnings')) {
            if (-not $stateObj.Contains($prop.Name)) { $stateObj[$prop.Name] = $prop.Value }
        }
    }
}

$tempPath = "$statePath.$([guid]::NewGuid().ToString('N')).tmp"
[System.IO.File]::WriteAllText($tempPath, ($stateObj | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
Move-Item -LiteralPath $tempPath -Destination $statePath -Force

if ($warnings.Count -gt 0) {
    $output = "=== Session Health Warning ==="
    foreach ($w in $warnings) { $output += "`n$w" }
    Write-Output $output
}

exit 0
