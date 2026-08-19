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

function Get-GitWorktreePaths {
    param([string]$RepositoryRoot)
    $paths = @()
    foreach ($command in @(@('diff', '--name-only', 'HEAD'), @('diff', '--cached', '--name-only'), @('ls-files', '--others', '--exclude-standard'))) {
        # PS 5.1: 2>$null alone does not prevent $ErrorActionPreference = 'Stop'
        # from converting native stderr warnings (e.g. git CRLF notices) into
        # terminating NativeCommandError. Temporarily relax EAP around the call.
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $output = @(& git -C $RepositoryRoot @command 2>$null)
        } finally {
            $ErrorActionPreference = $prevEAP
        }
        if ($LASTEXITCODE -ne 0) { throw "Git baseline command failed: git $($command -join ' ')" }
        $paths += @($output | ForEach-Object { ([string]$_).Trim().Replace('\', '/') } | Where-Object { $_ })
    }
    return @($paths | Sort-Object -Unique)
}

function Test-PathInDeclaredScope {
    param([string]$Path, [string[]]$Scope)
    foreach ($allowed in $Scope) {
        if ($Path -eq $allowed -or $Path.StartsWith($allowed.TrimEnd('/') + '/')) { return $true }
    }
    return $false
}

function Invoke-ApprovedAutopublish {
    param([string]$PacketPath, [string[]]$BaselinePaths, [object]$ChainSummary)
    $permission = Get-PacketSectionText -Path $PacketPath -Heading 'Permission Handoff'
    $scope = Get-DeclaredPublishScope -PacketPath $PacketPath
    if ($permission -notmatch '(?i)conditional autopublish authority') { throw 'Autopublish escalation: packet Permission Handoff lacks conditional autopublish authority.' }
    if ($scope.Count -eq 0) { throw 'Autopublish escalation: packet Declared Scope is missing or empty.' }
    if (@($BaselinePaths | Where-Object { Test-PathInDeclaredScope -Path $_ -Scope $scope }).Count -gt 0) { throw 'Autopublish escalation: the baseline already contains a dirty file inside the declared scope.' }
    if (@(& git -C $repoRoot diff --cached --name-only 2>$null).Count -gt 0) { throw 'Autopublish escalation: pre-existing staged changes prevent selective staging.' }
    if ($ChainSummary.state -ne 'completed' -or @($ChainSummary.stages | Where-Object { -not $_.success }).Count -gt 0) { throw 'Autopublish escalation: chain completion and Verify evidence are incomplete.' }

    $currentPaths = Get-GitWorktreePaths -RepositoryRoot $repoRoot
    $newPaths = @($currentPaths | Where-Object { $BaselinePaths -notcontains $_ })
    $scopeDrift = @($newPaths | Where-Object { -not (Test-PathInDeclaredScope -Path $_ -Scope $scope) })
    if ($scopeDrift.Count -gt 0) { throw "Autopublish escalation: scope drift detected: $($scopeDrift -join ', ')" }
    if ($newPaths -notcontains 'history.md') { throw 'Autopublish escalation: successful Integration did not add the required history.md record.' }
    if ($newPaths.Count -eq 0) { throw 'Autopublish escalation: no declared-scope changes are available to publish.' }

    $upstream = (& git -C $repoRoot rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>$null | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($upstream)) { throw 'Autopublish escalation: the current branch has no tracking branch.' }
    & git -C $repoRoot fetch --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Autopublish escalation: remote authentication or fetch failed.' }
    & git -C $repoRoot merge-base --is-ancestor $upstream HEAD 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'Autopublish escalation: local branch is behind its tracking branch (non-fast-forward risk).' }

    & git -C $repoRoot add -- $scope
    if ($LASTEXITCODE -ne 0) { throw 'Autopublish escalation: selective staging failed.' }
    $staged = @(& git -C $repoRoot diff --cached --name-only 2>$null | ForEach-Object { ([string]$_).Trim().Replace('\', '/') } | Where-Object { $_ })
    if ($staged.Count -eq 0 -or @($staged | Where-Object { -not (Test-PathInDeclaredScope -Path $_ -Scope $scope) }).Count -gt 0) { throw 'Autopublish escalation: staged set is empty or exceeds the declared scope.' }
    & git -C $repoRoot commit -m "feat(harness): complete $TaskId autopublish contract"
    if ($LASTEXITCODE -ne 0) { throw 'Autopublish escalation: selective commit failed.' }
    & git -C $repoRoot push
    if ($LASTEXITCODE -ne 0) { throw 'Autopublish escalation: tracking-branch push failed.' }
}

function Build-CoordinatorContext {
    param([string]$PacketPath, [string]$TaskId, [string]$LogsDir)

    # Read packet content
    $packetContent = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8

    # Read stage-state if exists
    $stageStatePath = Join-Path $LogsDir "$TaskId-stage-state.json"
    $stageState = if (Test-Path $stageStatePath) {
        Get-Content -LiteralPath $stageStatePath -Raw -Encoding UTF8
    } else { $null }

    # Read chain-summary if exists
    $chainSummaryPath = Join-Path $LogsDir "$TaskId-chain-summary.json"
    $chainSummary = if (Test-Path $chainSummaryPath) {
        Get-Content -LiteralPath $chainSummaryPath -Raw -Encoding UTF8
    } else { $null }

    # Read qa-verdict if exists
    $qaVerdictPath = Join-Path $LogsDir "$TaskId-qa-verdict.json"
    $qaVerdict = if (Test-Path $qaVerdictPath) {
        Get-Content -LiteralPath $qaVerdictPath -Raw -Encoding UTF8
    } else { $null }

    # Read last 100 lines of orchestration log
    $orchLogPath = Join-Path $LogsDir "$TaskId-orchestration.log"
    $orchLog = if (Test-Path $orchLogPath) {
        Get-Content -LiteralPath $orchLogPath -Tail 100 -Encoding UTF8 | Out-String
    } else { $null }

    # Get git status
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

    # Extract pipeline status
    $pipelineStatusText = Get-PacketSectionText -Path $PacketPath -Heading 'Pipeline Status'

    # Build context object
    $context = [ordered]@{
        taskId = $TaskId
        packetPath = $PacketPath
        packetContent = $packetContent
        declaredScope = $declaredScope
        pipelineStatus = $pipelineStatusText
        stageState = $stageState
        chainSummary = $chainSummary
        qaVerdict = $qaVerdict
        orchestrationLog = $orchLog
        gitStatus = $gitStatus
        gitDiffStat = $gitDiffStat
        repoRoot = $repoRoot
    }

    return $context | ConvertTo-Json -Depth 10 -Compress
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
$publishBaseline = if ($DryRun) { @() } else { Get-GitWorktreePaths -RepositoryRoot $repoRoot }
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
    Write-Host "[DryRun] Would invoke: agy --project <id> --model $dryModel --mode accept-edits --dangerously-skip-permissions --output-format stream-json --print-timeout ${HardTimeoutMinutes}m --print <prompt>"
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
$agyCommand = "$agyExe --project $projectId --model $agyModel --mode accept-edits --dangerously-skip-permissions --output-format stream-json --print-timeout ${HardTimeoutMinutes}m --print"

Write-StartingStageState

$runner = Join-Path ([IO.Path]::GetTempPath()) ("orchestrate-$driverCycleId.ps1")
try {
    # Create runner script that invokes agy with the prompt
    $escapedPrompt = $prompt -replace "'", "''"
    $runnerText = @"
`$env:ORCHESTRATION_DRIVER_CYCLE_ID = '$driverCycleId'
Set-Location -LiteralPath '$($repoRoot.Replace("'", "''"))'
& $agyCommand '$escapedPrompt'
exit `$LASTEXITCODE
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
        try {
            $summary = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Invoke-ApprovedAutopublish -PacketPath $packet[0].FullName -BaselinePaths $publishBaseline -ChainSummary $summary
            exit 0
        } catch {
            $path = Write-OrchestrationEscalation -ReasonCode 'autopublish_precondition_failed' -Summary $_.Exception.Message -EvidencePaths @($summaryPath, $logPath) -Attempts $attempts -DecisionNeeded 'Resolve the reported safety precondition, then start one explicit fresh direct stage dispatch.'
            Write-Host "Escalation: $path"; exit 1
        }
    }

    $reason = Get-DriverFailureReason -LogPath $logPath
    $approvalEvidence = if ($reason -eq 'approval_required') { @(Get-PendingApprovalEvidence) } else { @() }
    $decisionNeeded = if ($reason -eq 'approval_required') { 'Inspect the exact target, arrange approval outside the headless process, then start one explicit fresh direct stage dispatch (new cycle).' } else { 'Inspect the chain summary and evidence before an explicit fresh restart.' }
    $path = Write-OrchestrationEscalation -ReasonCode $(if ($summaryCheck.Valid) { $reason } else { $summaryCheck.Reason }) -Summary "Agy coordinator exited $($process.ExitCode)." -EvidencePaths @(@($summaryPath, $logPath) + @($approvalEvidence)) -Attempts $attempts -DecisionNeeded $decisionNeeded
    Write-Host "Escalation: $path"; exit 1
} finally { if (Test-Path $runner) { Remove-Item $runner -Force } }