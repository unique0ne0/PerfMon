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

