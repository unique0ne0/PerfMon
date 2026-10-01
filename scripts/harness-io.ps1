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
    # CFG087: PS 5.1의 Move-Item -Force는 대상 삭제 후 이동(비원자)이라, 대상 파일을
    # FILE_SHARE_DELETE 없이 열고 있는 reader(대시보드·lease 판정·백신 등)가 있으면
    # ERROR_ALREADY_EXISTS로 실패한다. 대상이 있으면 File.Replace, 없으면 File.Move로
    # 교체하고, IOException·UnauthorizedAccessException은 짧은 백오프로 재시도한다.
    # Move 도중 대상이 경합으로 생기면 다음 시도의 Replace 분기가 처리한다.
    # 최종 실패 시 tmp를 지우고 예외를 다시 던진다. 시그니처와 UTF-8 BOM 인코딩은 유지한다.
    $maxAttempts = 5
    for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
        try {
            if ([System.IO.File]::Exists($Path)) {
                # PS 5.1은 .NET 메서드의 string 인자에 $null을 그대로 넘기지 못한다 —
                # 백업 없음은 [NullString]::Value로 명시해야 ArgumentException이 나지 않는다.
                [System.IO.File]::Replace($temporary, $Path, [NullString]::Value)
            } else {
                [System.IO.File]::Move($temporary, $Path)
            }
            return
        } catch {
            # PowerShell 5.1 wraps static .NET invocation failures in MethodInvocationException.
            # Classify the deepest exception so IOException/UnauthorizedAccessException really
            # take the promised retry path instead of failing immediately on the wrapper type.
            $writeException = $_.Exception
            while ($writeException.InnerException) { $writeException = $writeException.InnerException }
            $retryable = ($writeException -is [System.IO.IOException]) -or ($writeException -is [System.UnauthorizedAccessException])
            if (-not $retryable -or $attempt -ge $maxAttempts) {
                Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
                throw
            }
            Start-Sleep -Milliseconds 200
        }
    }
}

function Write-AtomicRMW {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][scriptblock]$Transform,
        [int]$Depth = 6,
        [int]$TimeoutMs = 5000
    )
    $absPath = $Path
    if (-not [System.IO.Path]::IsPathRooted($absPath)) {
        $absPath = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $absPath))
    }
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($absPath.ToLowerInvariant()))
    $hash = [System.BitConverter]::ToString($hashBytes).Replace('-','').Substring(0, 16)
    $mutexName = "Local\harness-rmw-$hash"
    $createdNew = $false
    $rmwMutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
    try {
        if (-not $rmwMutex.WaitOne($TimeoutMs)) {
            throw "RMW mutex timeout (${TimeoutMs}ms) for $absPath (name: $mutexName)"
        }
        $current = $null
        if (Test-Path -LiteralPath $absPath) {
            try { $current = Get-Content -LiteralPath $absPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $current = $null }
        }
        $newValue = & $Transform $current
        if ($null -eq $newValue) { return }
        Write-AtomicJson -Path $absPath -Value $newValue -Depth $Depth
    } finally {
        try { $rmwMutex.ReleaseMutex() } catch { }
        try { $rmwMutex.Dispose() } catch { }
    }
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
        [string]$Owner = 'dispatcher',
        [switch]$ManualIntervention
    )
    if ([string]::IsNullOrWhiteSpace($Model)) { $Model = 'unknown' }
    $capturedTaskId = $TaskId
    $capturedStage = $Stage
    $capturedCycle = $Cycle
    $capturedState = $State
    $capturedProcessId = $ProcessId
    $capturedEvidencePaths = @($EvidencePaths)
    $capturedReason = $Reason
    $capturedModel = $Model
    $capturedOwner = $Owner
    $capturedManualIntervention = [bool]$ManualIntervention
    Write-AtomicRMW -Path $Path -Transform {
        param($previous)
        $sameStage = $previous -and ([string]$previous.stage -eq $capturedStage)
        $previousCycle = 0
        $cycleInt = 0
        if ($sameStage -and [int]::TryParse([string]$previous.cycle, [ref]$previousCycle) -and [int]::TryParse([string]$capturedCycle, [ref]$cycleInt) -and $previousCycle -gt $cycleInt) { return $null }
        $sequence = if ($previous -and $previous.sequence) { [int]$previous.sequence + 1 } else { 1 }
        $now = [datetime]::UtcNow.ToString('o')
        $sameCycle = $sameStage -and ($previous -and [string]$previous.cycle -eq [string]$capturedCycle)
        $wasRunning = $previous -and ([string]$previous.state -match '^(starting|running)$')
        $startedAt = if ($sameCycle -and $wasRunning -and $previous.startedAt) { [string]$previous.startedAt } else { $now }
        return [ordered]@{
            schemaVersion = 1
            taskId = $capturedTaskId
            stage = $capturedStage
            cycle = $capturedCycle
            sequence = $sequence
            state = $capturedState
            owner = $capturedOwner
            pid = $capturedProcessId
            model = $capturedModel
            startedAt = $startedAt
            heartbeatAt = $now
            eventAt = $now
            evidencePaths = $capturedEvidencePaths
            reason = $capturedReason
            manualIntervention = ($capturedManualIntervention -or ($previous -and [bool]$previous.manualIntervention))
        }
    } -Depth 6
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
