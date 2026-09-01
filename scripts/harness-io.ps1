# Harness I/O module — state file I/O, lock inspection, and manifest parser contract functions.
# This module is self-contained and exposes pure helper functions only.

function Write-AtomicJson {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][object]$Value,
        [int]$Depth = 6
    )
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $json = $Value | ConvertTo-Json -Depth $Depth
    [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Write-HarnessStageState {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$TaskId,
        [Parameter(Mandatory = $true)][string]$Stage,
        [Parameter(Mandatory = $true)]$Cycle,
        [Parameter(Mandatory = $true)][string]$State,
        [Parameter(Mandatory = $true)][int]$ProcessId,
        [string[]]$EvidencePaths = @(),
        [string]$Reason = '',
        [string]$Model = $null,
        [string]$Owner = 'dispatcher'
    )
    # A producer may not yet know its final model at the first state transition.
    # The shared schema still requires an explicit, non-empty value for dashboards
    # and downstream tooling, so encode that fact rather than serializing $null.
    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = 'unknown' }
    $previous = $null
    try { if (Test-Path -LiteralPath $Path) { $previous = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    # 사이클은 단계마다 독립적으로 증가하므로 비교를 같은 단계로 한정한다. 같은 단계의 늦은
    # 과거 사이클 기록만 거부하고, 새 단계(impl→qa→integration)는 이전 단계 lease를 대체한다.
    # CFG020: impl cycle 5 완료 후 qa cycle 1이 이전 단계 cycle에 막혀 'starting'을 쓰지 못하면
    # 대시보드가 실제 진행 중인 qa를 이전 단계 상태로 계속 보여주는 오탐이 생긴다.
    $sameStage = $previous -and ([string]$previous.stage -eq $Stage)
    $previousCycle = 0
    $cycleInt = 0
    if ($sameStage -and [int]::TryParse([string]$previous.cycle, [ref]$previousCycle) -and [int]::TryParse([string]$Cycle, [ref]$cycleInt) -and $previousCycle -gt $cycleInt) { return }
    $sequence = if ($previous -and $previous.sequence) { [int]$previous.sequence + 1 } else { 1 }
    $now = [datetime]::UtcNow.ToString('o')
    $sameCycle = $sameStage -and ($previous -and [string]$previous.cycle -eq [string]$Cycle)
    $wasRunning = $previous -and ([string]$previous.state -match '^(starting|running)$')
    $startedAt = if ($sameCycle -and $wasRunning -and $previous.startedAt) { [string]$previous.startedAt } else { $now }
    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        stage = $Stage
        cycle = $Cycle
        sequence = $sequence
        state = $State
        owner = $Owner
        pid = $ProcessId
        model = $Model
        startedAt = $startedAt
        heartbeatAt = $now
        eventAt = $now
        evidencePaths = @($EvidencePaths)
        reason = $Reason
    }
    Write-AtomicJson -Path $Path -Value $value -Depth 6
}


function Read-HarnessLockFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )
    $result = [ordered]@{
        Path = $Path
        Raw = $null
        ProcessId = 0
        TaskId = $null
        StartedAt = $null
        ProcessStartedAt = $null
        Alive = $false
    }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$result }

    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { return [pscustomobject]$result }
    $rawTrimmed = $raw.Trim()
    $result.Raw = $rawTrimmed

    $parts = $rawTrimmed -split '\|'
    if ($parts.Count -lt 3) { return [pscustomobject]$result }

    $procId = 0
    if (-not [int]::TryParse($parts[0], [ref]$procId)) { return [pscustomobject]$result }
    $result.ProcessId = $procId
    $result.TaskId = $parts[1]

    [datetime]$parsedStartedAt = [datetime]::MinValue
    if ([datetime]::TryParse($parts[2], [ref]$parsedStartedAt)) {
        $result.StartedAt = $parsedStartedAt
    } else {
        $result.StartedAt = $parts[2]
    }

    $process = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $alive = ($null -ne $process)
    $processStartedAt = $null
    if ($alive -and $parts.Count -ge 5) {
        try {
            $processStartedAt = $process.StartTime
            $result.ProcessStartedAt = $processStartedAt
            [datetime]$recordedStart = [datetime]::MinValue
            if (-not [datetime]::TryParse($parts[4], [ref]$recordedStart) -or
                [math]::Abs(($processStartedAt - $recordedStart).TotalSeconds) -gt 2) {
                $alive = $false
            }
        } catch {
            $alive = $false
        }
    }
    $result.Alive = $alive
    return [pscustomobject]$result
}

function Read-HarnessAssets {
    param([string]$ManifestPath)
    $assets = @()
    if (-not (Test-Path -LiteralPath $ManifestPath)) { throw "Harness asset manifest is missing: $ManifestPath" }
    foreach ($line in @(Get-Content -LiteralPath $ManifestPath -Encoding UTF8)) {
        $name = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('#')) { continue }
        if ($name -match '[<>:"/\\|?*\x00-\x1F]' -or $name -eq '.' -or $name -eq '..' -or $name -like '..*') { throw "Invalid harness asset manifest entry '$name' in $ManifestPath" }
        if ($assets -notcontains $name) { $assets += $name }
    }
    return $assets
}
