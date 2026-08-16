param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [string]$DriverProfile,
    [int]$HardTimeoutMinutes = 120,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
if ($TaskId -notmatch '^(?:[A-Z][A-Z0-9]*)?[0-9]{3}$') { throw ('Invalid TaskId [' + $TaskId + ']. Expected NNN or PREFIXNNN without separators.') }
$repoRoot = Split-Path -Parent $PSScriptRoot
# Deployed copies live in <repo>\scripts; the canonical source lives in
# <repo>\global\harness. Supporting the latter makes its dry-run a safe smoke check.
if (-not (Test-Path (Join-Path $repoRoot 'scripts\verify.ps1'))) { $repoRoot = Split-Path -Parent $repoRoot }
$logs = Join-Path $repoRoot '.agents\briefs\logs'
$packet = @(Get-ChildItem -Path (Join-Path $repoRoot '.agents\briefs\packets') -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue)
if ($packet.Count -ne 1) { throw "Expected exactly one active packet for $TaskId; found $($packet.Count)." }
if ($HardTimeoutMinutes -lt 1 -or $HardTimeoutMinutes -gt 120) { throw 'HardTimeoutMinutes must be between 1 and 120.' }

function Write-AtomicJson {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temp = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Write-OrchestrationEscalation {
    param([string]$ReasonCode, [string]$Summary, [string[]]$EvidencePaths, [object[]]$Attempts, [string]$DecisionNeeded)
    $path = Join-Path $logs "$TaskId-orchestration-escalation.json"
    Write-AtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; taskId = $TaskId; driverCycleId = $driverCycleId; state = 'judgment_required'; reasonCode = $ReasonCode; summary = $Summary; evidencePaths = @($EvidencePaths); attempts = @($Attempts); decisionNeeded = $DecisionNeeded; stoppedAt = [datetime]::UtcNow.ToString('o') })
    return $path
}

function Write-StartingStageState {
    $path = Join-Path $logs "$TaskId-stage-state.json"
    $now = [datetime]::UtcNow.ToString('o')
    Write-AtomicJson -Path $path -Value ([ordered]@{ schemaVersion = 1; taskId = $TaskId; stage = 'unknown'; cycle = $driverCycleId; sequence = 1; state = 'starting'; owner = 'host'; pid = $PID; startedAt = $now; heartbeatAt = $now; eventAt = $now; evidencePaths = @($logPath); reason = 'hidden host launcher started' })
}

function Get-DriverFailureReason {
    param([string]$LogPath)
    # CFG017: 구조화 승인 상태가 정규식 분류보다 우선한다. dispatcher가 chain-summary를
    # 'approval_required'로 끝냈으면 권한 요청을 driver_failed·provider 문제로 오분류하지 않는다.
    $approvalSummary = Join-Path $logs "$TaskId-chain-summary.json"
    if (Test-Path -LiteralPath $approvalSummary) {
        try {
            $chain = Get-Content -LiteralPath $approvalSummary -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($chain.state -eq 'approval_required') { return 'approval_required' }
        } catch { }
    }
    if (-not (Test-Path $LogPath)) { return 'driver_failed' }
    $text = Get-Content -LiteralPath $LogPath -Raw -ErrorAction SilentlyContinue
    if ($text -match 'authentication|unauthorized|login required') { return 'authentication' }
    if ($text -match 'quota|rate limit|insufficient balance|payment required') { return 'quota' }
    if ($text -match 'unavailable|model not found|provider.*error|connection refused') { return 'provider_unavailable' }
    return 'driver_failed'
}

function Get-PendingApprovalEvidence {
    $pending = @()
    foreach ($path in @(Get-ChildItem -LiteralPath $logs -Filter "$TaskId-*-cycle*-approval.json" -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
        try {
            $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record.taskId -eq $TaskId -and $record.status -eq 'pending' -and $record.approval_required) { $pending += $path }
        } catch { }
    }
    return @($pending)
}

function Stop-DriverProcessTree {
    param([int]$ProcessId)
    & taskkill.exe /PID $ProcessId /T /F 2>$null | Out-Null
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) { Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue }
}

function Test-CompletedChainSummary {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @{ Valid = $false; Reason = 'chain_summary_missing' } }
    try { $summary = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { return @{ Valid = $false; Reason = 'chain_summary_invalid' } }
    if ($summary.taskId -ne $TaskId -or $summary.driverCycleId -ne $driverCycleId) { return @{ Valid = $false; Reason = 'chain_summary_identity_mismatch' } }
    if ($summary.state -ne 'completed') { return @{ Valid = $false; Reason = "chain_summary_$($summary.state)" } }
    return @{ Valid = $true; Reason = $null }
}

$existingEscalation = Join-Path $logs "$TaskId-orchestration-escalation.json"
if (Test-Path $existingEscalation) { throw "Existing escalation blocks automatic restart: $existingEscalation" }
$driverCycleId = [guid]::NewGuid().ToString('N')
$summaryPath = Join-Path $logs "$TaskId-chain-summary.json"
if (-not $DryRun -and (Test-Path -LiteralPath $summaryPath)) { Remove-Item -LiteralPath $summaryPath -Force }
$logPath = Join-Path $logs "$TaskId-orchestration.log"
$dispatcher = Join-Path $repoRoot 'scripts\dispatch-with-hang-detect.ps1'
$attempts = @()

# CFG019: orchestration is deterministic.  A separate LLM "driver" previously spent a
# full model turn deciding to run this same command, then imposed a second timeout and
# frequently left the dashboard with no trustworthy child state.  Start the dispatcher
# directly, once, under the one logical deadline.  The dispatcher remains the only
# component allowed to select stage models, retry, or request narrowly-scoped approval.
Write-Host "direct-dispatch task=$TaskId driverCycleId=$driverCycleId deadline=${HardTimeoutMinutes}m"
if ($DryRun) {
    Write-Host "[DryRun] direct execution omitted: powershell -File scripts/dispatch-with-hang-detect.ps1 -TaskId $TaskId -Chain"
    exit 0
}

$runner = Join-Path ([IO.Path]::GetTempPath()) ("orchestrate-$driverCycleId.ps1")
try {
    # The dashboard must show a hidden host launch before the dispatcher acquires a lock.
    Write-StartingStageState
    $runnerText = "`$env:ORCHESTRATION_DRIVER_CYCLE_ID = '$driverCycleId'`r`nSet-Location -LiteralPath '$($repoRoot.Replace("'", "''"))'`r`n& '$($dispatcher.Replace("'", "''"))' -TaskId '$TaskId' -Chain`r`nexit `$LASTEXITCODE`r`n"
    [IO.File]::WriteAllText($runner, $runnerText, (New-Object Text.UTF8Encoding($true)))
    $process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) -PassThru -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
    $null = $process.Handle
    if (-not $process.WaitForExit($HardTimeoutMinutes * 60 * 1000)) {
        Stop-DriverProcessTree -ProcessId $process.Id
        $path = Write-OrchestrationEscalation -ReasonCode 'chain_timeout' -Summary 'The deterministic chain exceeded its single logical deadline.' -EvidencePaths @($logPath) -Attempts $attempts -DecisionNeeded 'Inspect the chain summary before an explicit fresh restart.'
        Write-Host "Escalation: $path"; exit 1
    }
    $attempts += @{ mode = 'direct-dispatch'; exitCode = $process.ExitCode }
    $summaryCheck = Test-CompletedChainSummary -Path $summaryPath
    if ($process.ExitCode -eq 0 -and $summaryCheck.Valid) { exit 0 }
    $reason = Get-DriverFailureReason -LogPath $logPath
    $approvalEvidence = if ($reason -eq 'approval_required') { @(Get-PendingApprovalEvidence) } else { @() }
    $decisionNeeded = if ($reason -eq 'approval_required') { 'Inspect the exact target, arrange approval outside the headless process, then start one explicit fresh direct stage dispatch (new cycle).' } else { 'Inspect the chain summary and evidence before an explicit fresh restart.' }
    $path = Write-OrchestrationEscalation -ReasonCode $(if ($summaryCheck.Valid) { $reason } else { $summaryCheck.Reason }) -Summary "Direct chain exited $($process.ExitCode)." -EvidencePaths @(@($summaryPath, $logPath) + @($approvalEvidence)) -Attempts $attempts -DecisionNeeded $decisionNeeded
    Write-Host "Escalation: $path"; exit 1
} finally { if (Test-Path $runner) { Remove-Item $runner -Force } }
