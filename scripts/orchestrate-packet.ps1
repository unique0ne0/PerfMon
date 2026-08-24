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

function Get-PacketSectionText {
    param([string]$Path, [string]$Heading)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $match = [regex]::Match($text, '(?ms)^##\s+' + [regex]::Escape($Heading) + '\s*$\r?\n(.*?)(?=^##\s+|\z)')
    if ($match.Success) { return $match.Groups[1].Value }
    return ''
}

function Get-DeclaredPublishScope {
    param([string]$PacketPath)
    $section = Get-PacketSectionText -Path $PacketPath -Heading 'Declared Scope'
    if ([string]::IsNullOrWhiteSpace($section)) { return @() }
    return @($section -split "`r?`n" | ForEach-Object {
        $match = [regex]::Match($_, '^\s*-\s+`([^`]+)`\s*$')
        if ($match.Success) { $match.Groups[1].Value.Trim().Replace('\', '/') }
    } | Where-Object { $_ })
}

function Build-CoordinatorContext {
    param([string]$PacketPath, [string]$TaskId, [string]$LogsDir)

    # Get git status (naturally small — current working-tree delta only)
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $gitStatus = & git -C $repoRoot status --short 2>$null | Out-String
        $gitDiffStat = & git -C $repoRoot diff --stat 2>$null | Out-String
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    # Extract declared scope
    $declaredScope = Get-DeclaredPublishScope -PacketPath $PacketPath

    # The coordinator agent has its own file-read tools and the prompt template
    # already tells it to open chain-summary/orchestration-log/qa-verdict itself
    # (fixed paths under LogsDir, keyed by TaskId). Inlining their full content
    # here — plus the entire packet file and 100 log lines — used to balloon this
    # context to tens of KB per dispatch (CFG029's own "context waste" finding),
    # and pushed the rendered prompt past Windows' ~32K CreateProcess command-line
    # limit when passed to `agy --print`, causing agy.exe invocation to fail
    # silently. Pass pointers only; the agent reads what it needs on demand.
    $context = [ordered]@{
        taskId = $TaskId
        packetPath = $PacketPath
        declaredScope = $declaredScope
        logsDir = $LogsDir
        gitStatus = $gitStatus
        gitDiffStat = $gitDiffStat
        repoRoot = $repoRoot
    }

    # Explicit -InputObject (not piped) avoids ConvertTo-Json enumerating the
    # OrderedDictionary as a pipeline sequence; Depth 3 is ample headroom for
    # this flat object and bounds worst-case serialization cost. Observed
    # once in practice: piped + Depth 10 let a live orchestrate-packet.ps1
    # run for CFG029 balloon to 8.6GB RSS and spin one core for 20+ minutes
    # inside this call, with an isolated repro on identical input completing
    # in milliseconds — state-dependent, not reproduced on demand.
    return ConvertTo-Json -InputObject $context -Depth 3 -Compress
}

function Build-CoordinatorPrompt {
    param([string]$TemplatePath, [string]$ContextJson, [string]$TaskId, [string]$RepoRoot)

    $template = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8

    # Replace placeholders
    $prompt = $template -replace '\{\{CONTEXT\}\}', $ContextJson
    $prompt = $prompt -replace '\{\{TASK_ID\}\}', $TaskId
    $prompt = $prompt -replace '\{\{REPO_ROOT\}\}', $RepoRoot

    return $prompt
}

function Resolve-AntigravityProjectId {
    param([string]$RepositoryRoot)
    if (-not $env:USERPROFILE) { throw 'Antigravity project resolution requires USERPROFILE.' }
    $projectsDir = Join-Path $env:USERPROFILE '.gemini\config\projects'
    if (-not (Test-Path -LiteralPath $projectsDir)) { throw "Antigravity projects directory not found: $projectsDir" }
    $wanted = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\').Replace('\','/').ToLowerInvariant()
    foreach ($file in @(Get-ChildItem -LiteralPath $projectsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { $project = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($resource in @($project.projectResources.resources)) {
            $uri = if ($resource.folderUri) { [string]$resource.folderUri } elseif ($resource.gitFolder.folderUri) { [string]$resource.gitFolder.folderUri } else { '' }
            if (-not $uri.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $decoded = [Uri]::UnescapeDataString(($uri -replace '^file:/+', ''))
            $candidate = $decoded.TrimEnd('/').ToLowerInvariant()
            if ($candidate -eq $wanted) {
                $id = [string]$project.id
                if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,127}$') { throw "Invalid Antigravity project id in $($file.FullName)" }
                return $id
            }
        }
    }
    throw "No Antigravity project maps repository '$RepositoryRoot'. Run 'agy --new-project' from that repository root after explicit user approval."
}

$existingEscalation = Join-Path $logs "$TaskId-orchestration-escalation.json"
if (Test-Path $existingEscalation) { throw "Existing escalation blocks automatic restart: $existingEscalation" }
$driverCycleId = [guid]::NewGuid().ToString('N')
$summaryPath = Join-Path $logs "$TaskId-chain-summary.json"
if (-not $DryRun -and (Test-Path -LiteralPath $summaryPath)) { Remove-Item -LiteralPath $summaryPath -Force }
$logPath = Join-Path $logs "$TaskId-orchestration.log"
$attempts = @()

# Gemini coordinator: agy가 파이프라인을 직접 모니터링하고 제어합니다.
# orchestrate-packet.ps1은 컨텍스트를 구성하고 agy를 호출한 후 결과를 해석합니다.
# agy는 dispatch-with-hang-detect.ps1을 직접 호출하고, Tier 1 실패를 자동 수정하며, Tier 2만 에스컬레이션합니다.

Write-Host "agy-coordinator task=$TaskId driverCycleId=$driverCycleId deadline=${HardTimeoutMinutes}m"

# Load model profile config for orchestration profile resolution
$ProfileModule = Join-Path $repoRoot 'global\harness\model-profile.ps1'
$ProfileConfigPath = Join-Path $repoRoot 'global\harness\model-profiles.json'
. $ProfileModule
$script:ProfileConfig = Read-ModelProfileConfig -CentralPath $ProfileConfigPath -LocalPath (Join-Path $repoRoot 'model-profiles.local.json')

if ($DryRun) {
    $dryModel = 'gemini-3.7-flash'
    if ($script:ProfileConfig.roles.orchestration -and $script:ProfileConfig.profiles.($script:ProfileConfig.roles.orchestration)) {
        $dryModel = [string]$script:ProfileConfig.profiles.($script:ProfileConfig.roles.orchestration).model
    }
    Write-Host "[DryRun] direct-dispatch task=$TaskId agy coordinator execution omitted"
    Write-Host "[DryRun] Would build context from packet: $($packet[0].FullName)"
    Write-Host "[DryRun] Would render prompt from template: gy-orchestrator-prompt.md"
    $dryEffortFlag = if ($dryModel -eq 'gemini-3.7-flash') { ' --effort medium' } else { '' }
    Write-Host "[DryRun] Would invoke: agy --project <id> --model $dryModel$dryEffortFlag --mode accept-edits --dangerously-skip-permissions --output-format stream-json --print-timeout ${HardTimeoutMinutes}m --print <prompt>"
    exit 0
}

# Build coordinator context
$contextJson = Build-CoordinatorContext -PacketPath $packet[0].FullName -TaskId $TaskId -LogsDir $logs

# Render prompt from template
$templatePath = Join-Path $PSScriptRoot 'gy-orchestrator-prompt.md'
if (-not (Test-Path $templatePath)) { throw "Coordinator prompt template not found: $templatePath" }
$prompt = Build-CoordinatorPrompt -TemplatePath $templatePath -ContextJson $contextJson -TaskId $TaskId -RepoRoot $repoRoot

# Resolve Antigravity project ID
$projectId = Resolve-AntigravityProjectId -RepositoryRoot $repoRoot

# Build agy command — resolve model from orchestration profile
$agyExe = 'agy'
$orchProfile = $null
if ($DriverProfile -and $script:ProfileConfig.profiles.$DriverProfile) {
    $orchProfile = $script:ProfileConfig.profiles.$DriverProfile
} elseif ($script:ProfileConfig.roles.orchestration -and $script:ProfileConfig.profiles.($script:ProfileConfig.roles.orchestration)) {
    $orchProfile = $script:ProfileConfig.profiles.($script:ProfileConfig.roles.orchestration)
}
$agyModel = if ($orchProfile) { [string]$orchProfile.model } else { 'gemini-3.7-flash' }
# agy requires --effort whenever --model selects a gemini-3.7-flash family model
# (mirrors dispatch-with-hang-detect.ps1's Build-ToolCommand antigravity branch).
$agyArgs = @('--project', $projectId, '--model', $agyModel)
if ($agyModel -eq 'gemini-3.7-flash') { $agyArgs += @('--effort', 'medium') }
$agyArgs += @('--mode', 'accept-edits', '--dangerously-skip-permissions', '--output-format', 'stream-json', '--print-timeout', "${HardTimeoutMinutes}m")
$agyArgsLiteral = ($agyArgs | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ', '

Write-StartingStageState

$runner = Join-Path ([IO.Path]::GetTempPath()) ("orchestrate-$driverCycleId.ps1")
$promptFile = Join-Path ([IO.Path]::GetTempPath()) ("orchestrate-$driverCycleId-prompt.txt")
try {
    # agy's prompt is NEVER handed to PowerShell's own `&` native-command
    # invocation. PowerShell 5.1's argument-to-command-line marshalling
    # corrupts a long string once it contains many embedded double-quote
    # characters (the JSON coordinator context is full of "key":"value"
    # pairs) — reproduced live twice: once with the prompt embedded as
    # source text, once passed as a runtime variable to `& $agyExe ...`;
    # both fragmented into 62 argv entries, one of them literally "M" (from
    # a git-status " M " marker), which agy rejected as "unexpected
    # argument \"M\"" (CFG-BL-031). `ProcessStartInfo.ArgumentList` (which
    # does its own correct per-element escaping) is unavailable on this
    # .NET Framework build, so the runner instead escapes every argument
    # itself using the documented CommandLineToArgvW quoting algorithm and
    # invokes agy via System.Diagnostics.Process with a pre-escaped
    # .Arguments string, bypassing PowerShell's marshalling entirely.
    # Verified via a harmless echo-args stand-in before wiring this in:
    # a 2052-char, 104-quote synthetic prompt (with an embedded " M "
    # marker) arrived as exactly one argv token, unfragmented. Bare
    # `--print` with no value is separately invalid: agy 1.1.18 hardened
    # --print to require an explicit value ("a valueless prompt flag
    # swallowing the next flag as its prompt ... is now an error").
    [IO.File]::WriteAllText($promptFile, $prompt, (New-Object Text.UTF8Encoding($true)))
    $runnerText = @"
`$env:ORCHESTRATION_DRIVER_CYCLE_ID = '$driverCycleId'
Set-Location -LiteralPath '$($repoRoot.Replace("'", "''"))'
`$promptText = [IO.File]::ReadAllText('$($promptFile.Replace("'", "''"))', [Text.Encoding]::UTF8)
function ConvertTo-EscapedArgument {
    param([string]`$Arg)
    if (`$Arg.Length -gt 0 -and `$Arg -notmatch '[\s"]') { return `$Arg }
    `$sb = New-Object Text.StringBuilder
    [void]`$sb.Append('"')
    `$len = `$Arg.Length
    `$i = 0
    while (`$true) {
        `$backslashes = 0
        while (`$i -lt `$len -and `$Arg[`$i] -eq '\') { `$backslashes++; `$i++ }
        if (`$i -eq `$len) {
            [void]`$sb.Append('\', (`$backslashes * 2))
            break
        } elseif (`$Arg[`$i] -eq '"') {
            [void]`$sb.Append('\', (`$backslashes * 2 + 1))
            [void]`$sb.Append('"')
            `$i++
        } else {
            [void]`$sb.Append('\', `$backslashes)
            [void]`$sb.Append(`$Arg[`$i])
            `$i++
        }
    }
    [void]`$sb.Append('"')
    return `$sb.ToString()
}
`$argTokens = @($agyArgsLiteral, '--print', `$promptText)
`$commandLine = (`$argTokens | ForEach-Object { ConvertTo-EscapedArgument `$_ }) -join ' '
`$psi = New-Object System.Diagnostics.ProcessStartInfo
`$psi.FileName = '$agyExe'
`$psi.Arguments = `$commandLine
`$psi.UseShellExecute = `$false
`$proc = [System.Diagnostics.Process]::Start(`$psi)
`$proc.WaitForExit()
exit `$proc.ExitCode
"@
    [IO.File]::WriteAllText($runner, $runnerText, (New-Object Text.UTF8Encoding($true)))

    $process = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner) -PassThru -RedirectStandardOutput $logPath -RedirectStandardError "$logPath.err"
    $null = $process.Handle

    if (-not $process.WaitForExit($HardTimeoutMinutes * 60 * 1000)) {
        Stop-DriverProcessTree -ProcessId $process.Id
        $path = Write-OrchestrationEscalation -ReasonCode 'chain_timeout' -Summary "The agy coordinator exceeded its ${HardTimeoutMinutes}m deadline." -EvidencePaths @($logPath) -Attempts $attempts -DecisionNeeded 'Inspect the orchestration log and chain summary before an explicit fresh restart.'
        Write-Host "Escalation: $path"; exit 1
    }

    $attempts += @{ mode = 'agy-coordinator'; exitCode = $process.ExitCode }
    $summaryCheck = Test-CompletedChainSummary -Path $summaryPath

    if ($process.ExitCode -eq 0 -and $summaryCheck.Valid) {
        Write-Host "Completed: $summaryPath"
        exit 0
    }

    $reason = Get-DriverFailureReason -LogPath $logPath
    $approvalEvidence = if ($reason -eq 'approval_required') { @(Get-PendingApprovalEvidence) } else { @() }
    $decisionNeeded = if ($reason -eq 'approval_required') { 'Inspect the exact target, arrange approval outside the headless process, then start one explicit fresh direct stage dispatch (new cycle).' } else { 'Inspect the chain summary and evidence before an explicit fresh restart.' }
    $path = Write-OrchestrationEscalation -ReasonCode $(if ($summaryCheck.Valid) { $reason } else { $summaryCheck.Reason }) -Summary "Agy coordinator exited $($process.ExitCode)." -EvidencePaths @(@($summaryPath, $logPath) + @($approvalEvidence)) -Attempts $attempts -DecisionNeeded $decisionNeeded
    Write-Host "Escalation: $path"; exit 1
} finally { if (Test-Path $runner) { Remove-Item $runner -Force }; if (Test-Path $promptFile) { Remove-Item $promptFile -Force } }