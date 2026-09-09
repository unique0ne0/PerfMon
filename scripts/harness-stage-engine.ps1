# Harness stage engine module — stage execution, hang/timeout monitoring, and process tree management.
# Depends on: harness-io.ps1 (Write-AtomicJson), harness-contracts.ps1 (Get-PacketScopePaths)
# Caller must provide: $RepoRoot, $LogDir, $TaskId, $StageConfig, $BusyCpuRate, $BusyIoBytesPerSec, $HardTimeoutMinutes, $HangWaitSeconds, $HardTimeoutProgressBytes
# Also depends on main dispatcher functions: Resolve-RepoPath, Write-Log, Get-TreeState, Write-StageState

function New-DispatchScript {
    param([string]$ToolCmd, [string]$LogFile, [string]$Suffix)
    $shPath = Join-Path ([System.IO.Path]::GetTempPath()) ("dispatch-$Suffix.sh")
    $bashRoot = $RepoRoot -replace '\\','/'
    $body = "cd `"$bashRoot`" || exit 1`n$ToolCmd </dev/null > `"$LogFile`" 2>&1`n"
    [System.IO.File]::WriteAllText($shPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    return $shPath
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    & taskkill /PID $ProcessId /T /F 2>$null | Out-Null
}

function Get-RepeatedErrorObservation {
    param([string]$LogPath, [int]$MaxLines = 200, [int]$MinimumOccurrences = 3)

    $result = @{ Repeated = $false; Line = $null; Count = 0; SampledLines = 0 }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $result }
    $lines = @(Get-Content -LiteralPath $LogPath -Tail $MaxLines -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -match '(?i)(error|exception|failed|fatal|오류|실패|예외)' })
    $result.SampledLines = $lines.Count
    if ($lines.Count -eq 0) { return $result }
    $mostFrequent = @($lines | Group-Object | Sort-Object Count -Descending | Select-Object -First 1)
    if ($mostFrequent.Count -eq 0) { return $result }
    $result.Line = $mostFrequent[0].Name
    $result.Count = $mostFrequent[0].Count
    $result.Repeated = $result.Count -ge $MinimumOccurrences
    return $result
}

function Get-ProcessTreeMetrics {
    param([int]$RootProcessId)

    $cpu = [TimeSpan]::Zero; [Int64]$io = 0; [Int64]$workingSet = 0; [int]$handleCount = 0
    $pids = @()
    $queryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        $processes = @()
        $script:CimFailureCount++
        Write-Log "Win32_Process CIM 조회 실패 (누적 $($script:CimFailureCount)회): $($_.Exception.Message)" WARN
    } finally {
        $queryStopwatch.Stop()
    }
    $children = @{}
    $byId = @{}
    foreach ($process in $processes) {
        $byId[[int]$process.ProcessId] = $process
        $parent = [int]$process.ParentProcessId
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = New-Object 'System.Collections.Generic.List[object]'
        }
        [void]$children[$parent].Add($process)
    }
    $pending = New-Object 'System.Collections.Generic.Queue[int]'
    $seen = @{}
    $pending.Enqueue($RootProcessId)

    while ($pending.Count -gt 0) {
        $processId = $pending.Dequeue()
        if ($seen.ContainsKey($processId)) { continue }
        $seen[$processId] = $true
        $pids += $processId

        $procObj = $null
        try {
            $procObj = Get-Process -Id $processId -ErrorAction Stop
            $cpu += $procObj.TotalProcessorTime
            $workingSet += [Int64]$procObj.WorkingSet64
            $handleCount += [int]$procObj.HandleCount
        } catch { }
        if ($byId.ContainsKey($processId)) {
            $current = $byId[$processId]
            $read = if ($null -eq $current.ReadTransferCount) { 0 } else { [Int64]$current.ReadTransferCount }
            $write = if ($null -eq $current.WriteTransferCount) { 0 } else { [Int64]$current.WriteTransferCount }
            $io += $read + $write
            if (-not $procObj) {
                if ($current.WorkingSetSize) { $workingSet += [Int64]$current.WorkingSetSize }
                if ($current.HandleCount) { $handleCount += [int]$current.HandleCount }
            }
        }
        if ($children.ContainsKey($processId)) {
            foreach ($child in $children[$processId]) {
                $pending.Enqueue([int]$child.ProcessId)
            }
        }
    }
    return @{
        Cpu = $cpu
        Io = $io
        WorkingSet = $workingSet
        HandleCount = $handleCount
        ProcessIds = @($pids)
        ChildProcessIds = @($pids | Where-Object { $_ -ne $RootProcessId })
        QueryMs = $queryStopwatch.ElapsedMilliseconds
        CimFailures = $script:CimFailureCount
    }
}

function Test-GitOperationInFlight {
    param([string]$RepoRoot, [int[]]$ChildProcessIds)
    $indexLock = Join-Path $RepoRoot '.git\index.lock'
    if (Test-Path -LiteralPath $indexLock -PathType Leaf) { return $true }
    if ($ChildProcessIds -and $ChildProcessIds.Count -gt 0) {
        foreach ($childPid in $ChildProcessIds) {
            try {
                $childProc = Get-Process -Id $childPid -ErrorAction Stop
                if ($childProc.ProcessName -eq 'git') { return $true }
            } catch { }
        }
    }
    return $false
}

function Resolve-StageLimits {
    param([hashtable]$Config)

    $hangLimit = if ($Config.HangSeconds) { $Config.HangSeconds } else { $HangWaitSeconds }
    $hardLimit = if ($Config.HardTimeoutMinutes) { $Config.HardTimeoutMinutes } else { $HardTimeoutMinutes }
    $hardMax = $hardLimit * 3
    $extendStep = [Math]::Max(1, [Math]::Round($hardLimit / 3.0, 2))
    # 로그 무변화(hang)/하드 상한 감시 간격: 요청한 임계값보다 늦게 감지하지 않도록 제한한다.
    # 로그 파일이 아직 만들어지지 않은 경우도 무출력 상태이므로 0바이트로 취급한다.
    $interval = [Math]::Min(10, [Math]::Max(1, $hangLimit))
    return @{ HangLimit = $hangLimit; HardLimit = $hardLimit; HardMax = $hardMax; ExtendStep = $extendStep; Interval = $interval }
}

function New-StageMonitorBaseline {
    param($Proc, [datetime]$StartedAt, [hashtable]$Limits)

    $deadline = $StartedAt.AddMinutes($Limits.HardLimit)
    $absoluteDeadline = $StartedAt.AddMinutes($Limits.HardMax)
    $lastSize = 0; $lastLogChangedAt = $StartedAt; $hangReported = $false
    # 연장 판정용 롤링 창 — $extendStep 마다 그 구간의 로그 증가량을 확정한다.
    $windowStartAt = $StartedAt; $windowStartSize = 0; $lastWindowGrowth = 0
    $idleStartedMetrics = Get-ProcessTreeMetrics -RootProcessId $Proc.Id
    $lastHeartbeatAt = $StartedAt; $lastHeartbeatSize = 0; $lastHeartbeatCpu = $idleStartedMetrics.Cpu
    return @{
        Deadline = $deadline; AbsoluteDeadline = $absoluteDeadline
        LastSize = $lastSize; LastLogChangedAt = $lastLogChangedAt; HangReported = $hangReported
        WindowStartAt = $windowStartAt; WindowStartSize = $windowStartSize; LastWindowGrowth = $lastWindowGrowth
        IdleStartedMetrics = $idleStartedMetrics
        LastHeartbeatAt = $lastHeartbeatAt; LastHeartbeatSize = $lastHeartbeatSize; LastHeartbeatCpu = $lastHeartbeatCpu
    }
}

function Advance-StageWindow {
    param([hashtable]$Monitor, [long]$LogSize, [double]$ExtendStep)

    if (((Get-Date) - $Monitor.WindowStartAt).TotalMinutes -ge $ExtendStep) {
        $Monitor.LastWindowGrowth = [math]::Max(0, $LogSize - $Monitor.WindowStartSize)
        $Monitor.WindowStartAt = Get-Date; $Monitor.WindowStartSize = $LogSize
    }
}

function Write-StageHeartbeat {
    param([string]$Stage, [datetime]$StartedAt, [hashtable]$Monitor, [long]$LogSize, $CpuNow, $metricsNow)

    if (((Get-Date) - $Monitor.LastHeartbeatAt).TotalSeconds -lt 300) { return }
    $elapsed = [math]::Floor(((Get-Date) - $StartedAt).TotalMinutes)
    $logDelta = [math]::Max(0, $LogSize - $Monitor.LastHeartbeatSize)
    $cpuDelta = [math]::Max(0, [math]::Round(($CpuNow - $Monitor.LastHeartbeatCpu).TotalSeconds, 2))
    Write-Log "진행중 [$Stage] 경과 ${elapsed}분 · 로그 +${logDelta}B · 트리 CPU +${cpuDelta}s · CIM $($metricsNow.QueryMs)ms · CIM 실패 $($metricsNow.CimFailures)회" INFO
    $Monitor.LastHeartbeatAt = Get-Date; $Monitor.LastHeartbeatSize = $LogSize; $Monitor.LastHeartbeatCpu = $CpuNow
}

function Test-StageHangProgress {
    param([string]$Stage, [hashtable]$Monitor, $metricsNow, [double]$noChange, [double]$noChangeText, [hashtable]$Config)

    $idleCpuDelta = [math]::Max(0, [math]::Round(($metricsNow.Cpu - $Monitor.IdleStartedMetrics.Cpu).TotalSeconds, 2))
    $idleIoDelta = [math]::Max(0, $metricsNow.Io - $Monitor.IdleStartedMetrics.Io)
    $ratePct = [math]::Round(($idleCpuDelta / $noChange) * 100, 1)
    $ioRate = [math]::Round($idleIoDelta / $noChange, 0)
    $thresholdPct = [math]::Round($BusyCpuRate * 100, 1)
    $decision = @{ Action = 'wait' }
    if (($idleCpuDelta / $noChange) -ge $BusyCpuRate) {
        # CS-022의 의도(조용히 계산 중인 에이전트를 죽이지 않는다)는 여기서 그대로 유지된다.
        Write-Log "[$Stage] 로그 무변화 ${noChangeText}초지만 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}%) — 계산 중으로 보고 계속 대기" INFO
        $Monitor.LastLogChangedAt = Get-Date; $Monitor.IdleStartedMetrics = $metricsNow; $Monitor.HangReported = $false
    } elseif (($idleIoDelta / $noChange) -ge $BusyIoBytesPerSec) {
        Write-Log "[$Stage] 로그 무변화 ${noChangeText}초지만 트리 I/O +${idleIoDelta}B(${ioRate}B/s) — I/O 작업 중으로 보고 계속 대기" INFO
        $Monitor.LastLogChangedAt = Get-Date; $Monitor.IdleStartedMetrics = $metricsNow; $Monitor.HangReported = $false
    } elseif ($Config.KillOnHang) {
        Write-Log "⚠️ hang 감지 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 프로세스 트리 종료" WARN
        $decision = @{ Action = 'kill-hang' }
    } elseif (-not $Monitor.HangReported) {
        # CFG031 3분법: KillOnHang=$false 스테이지에서 git 진행 중이면 대기, 아니면 즉시 종료.
        # 특정 스테이지 이름을 하드코딩하지 않는다 — $Config.KillOnHang=$false인 모든 스테이지에 일반 적용.
        $gitInFlight = Test-GitOperationInFlight -RepoRoot $RepoRoot -ChildProcessIds $metricsNow.ChildProcessIds
        $wsMb = [math]::Round($metricsNow.WorkingSet / 1MB, 1)
        $handles = $metricsNow.HandleCount
        $childPids = if ($metricsNow.ChildProcessIds -and $metricsNow.ChildProcessIds.Count -gt 0) {
            $metricsNow.ChildProcessIds -join ', '
        } else {
            '없음'
        }
        if ($gitInFlight) {
            Write-Log "⚠️ hang 후보 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 점유 자원: WS ${wsMb}MB, 핸들 ${handles}개, 자식 PID: [$childPids]; git 작업 중이라 하드 상한까지 대기" WARN
            $Monitor.HangReported = $true
        } else {
            Write-Log "⚠️ hang 감지 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 진행 중인 git 커밋/푸시 없음(index.lock 없음, git 자식 프로세스 없음) — 프로세스 트리 종료" WARN
            $decision = @{ Action = 'kill-git' }
        }
    }
    return $decision
}

function Test-StageDeadlineElapsed {
    param([string]$Stage, [hashtable]$Monitor, [long]$LogSize, [hashtable]$Limits, [string]$logAbs, [datetime]$StartedAt, $CpuNow)

    if ((Get-Date) -le $Monitor.Deadline) { return @{ Action = 'continue' } }
    # 창 경계 직후에 상한이 걸려 진행 중인 프로세스가 "이번 창은 아직 0B"라는 이유로 죽는 일을 막는다.
    $growth = [math]::Max($Monitor.LastWindowGrowth, [math]::Max(0, $LogSize - $Monitor.WindowStartSize))
    if ($growth -ge $HardTimeoutProgressBytes -and $Monitor.Deadline -lt $Monitor.AbsoluteDeadline) {
        $repeatedError = Get-RepeatedErrorObservation -LogPath $logAbs
        if ($repeatedError.Repeated) {
            Write-Log "⚠️ 반복 오류 관찰 [$Stage] — 최근 $($repeatedError.SampledLines)개 오류 줄 중 같은 문구 $($repeatedError.Count)회: $($repeatedError.Line) (경고 전용; 하드 상한 연장·종료 정책은 유지)" WARN
        }
        $Monitor.Deadline = $Monitor.Deadline.AddMinutes($Limits.ExtendStep)
        if ($Monitor.Deadline -gt $Monitor.AbsoluteDeadline) { $Monitor.Deadline = $Monitor.AbsoluteDeadline }
        $remain = [math]::Round(($Monitor.AbsoluteDeadline - (Get-Date)).TotalMinutes, 1)
        Write-Log "⏳ 하드 상한 연장 [$Stage] — 최근 $($Limits.ExtendStep)분 로그 +${growth}B(진행 중), 절대 상한($($Limits.HardMax)분)까지 ${remain}분 남음" WARN
        return @{ Action = 'continue' }
    }
    if ($Monitor.Deadline -ge $Monitor.AbsoluteDeadline) { $why = "절대 상한 $($Limits.HardMax)분 도달" }
    else { $why = "최근 $($Limits.ExtendStep)분 로그 +${growth}B < ${HardTimeoutProgressBytes}B(정체)" }
    $spent = [math]::Round(((Get-Date) - $StartedAt).TotalMinutes, 1)
    return @{ Action = 'die'; Message = "⛔ 하드 상한 초과 [$Stage] — $why; 경과 ${spent}분, 로그 ${LogSize} B, 트리 CPU +$([math]::Round($CpuNow.TotalSeconds, 2))s; 프로세스 트리 종료" }
}

# CFG077 (CFG-BL-047): 에이전트 단계 종료 직후 하네스가 호출하는 post-hoc verify
# 게이트의 스퓨리어스 FAIL을 막는다. $proc.WaitForExit()는 직계 자식(에이전트 셸)만
# 기다린다 — 에이전트가 자기 턴 안에서 스폰한 손자 프로세스(테스트 러너·브라우저·
# python 등)는 부모가 종료돼도 잠시 살아남아, 하네스가 그 직후 곧바로 verify.ps1을
# 호출하면 파일 핸들·포트·CPU를 놓고 경합해 게이트가 일시 실패한다(CFG077 재현으로
# 확정). 여기서는 루트 종료 시점의 자손 PID 집합을 캡처해 그들이 완전히 정리될
# 때까지 짧은 상한(기본 수 초) 안에서 기다린다 — 경계 확정·비차단이며, 정리되지
# 않아도 파이프라인을 멈추지 않고 진행한다(진짜 실패는 Invoke-VerifyGate의 재시도
# 후에도 여전히 잡힌다).
function Wait-AgentTreeDrained {
    param([int]$RootProcessId, [string]$Stage, [int]$MaxWaitMs = 5000)
    $capture = Get-ProcessTreeMetrics -RootProcessId $RootProcessId
    $lingering = @($capture.ChildProcessIds | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($lingering.Count -eq 0) { return }
    Write-Log "⏳ [$Stage] 에이전트 종료 후 잔존 자식 프로세스 $($lingering.Count)개 정리 대기 (PID: $($lingering -join ','))..." INFO
    $deadline = [DateTime]::UtcNow.AddMilliseconds($MaxWaitMs)
    $pending = @($lingering)
    while ($pending.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline) {
        $stillAlive = @($pending | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
        if ($stillAlive.Count -eq 0) { break }
        $pending = $stillAlive
        Start-Sleep -Milliseconds 200
    }
    $remaining = @($pending | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
    if ($remaining.Count -gt 0) {
        Write-Log "⚠️ [$Stage] 잔존 자식 프로세스 $($remaining.Count)개가 상한 내 정리되지 않음 (PID: $($remaining -join ',')) — 경계 후 진행 (비차단)" WARN
    } else {
        Write-Log "✅ [$Stage] 잔존 자식 프로세스 트리 정리 확인" SUCCESS
    }
}

function Invoke-StageProcess {
    param([string]$Stage, [hashtable]$Config, [string]$ToolCmd, [int]$Cycle, [ref]$ExitCode, [ref]$ElapsedSeconds, [string]$Model)

    $logRel = $Config.LogFile
    $logAbs = Resolve-RepoPath $logRel
    $limits = Resolve-StageLimits -Config $Config
    $hangLimit = $limits.HangLimit

    # 자식 셸 스크립트를 만든 뒤 숨김 창으로 기동한다. -WindowStyle Hidden과 -NoNewWindow는
    # Windows PowerShell 5.1에서 같은 Start-Process에 함께 줄 수 없으므로, 별도 hidden child로
    # 시작해야 콘솔도 노출하지 않고 parameter-set 예외도 피한다.
    $shPath = New-DispatchScript -ToolCmd $ToolCmd -LogFile $logRel -Suffix ([guid]::NewGuid().ToString("N"))
    $startedAt = $null
    # hang·하드 상한으로 "정책상" 끊은 경우를 표시한다. taskkill은 종료를 요청만 하므로 직후
    # $proc.HasExited가 아직 $false일 수 있어, 생존 여부로 중단을 판정하면 정상 종료 경로에서
    # 중단 로그가 뜨고 이미 죽은(재활용됐을 수도 있는) PID를 한 번 더 죽이게 된다.
    $policyKilled = $false
    $proc = $null
    try {
        $startedAt = Get-Date
        $proc = Start-Process -FilePath $script:BashExe -WindowStyle Hidden -ArgumentList @($shPath) -PassThru
        $script:ActiveChildProcessId = $proc.Id; $script:ActiveChildStage = $Stage
        Write-StageState -Stage $Stage -Cycle $Cycle -State 'running' -ProcessId $proc.Id -EvidencePaths @($logRel) -Reason 'child process started' -Model $Model
        # Windows PowerShell 5.1은 Start-Process -PassThru의 Process 핸들을 미리 캐시하지 않으면
        # 종료 뒤 ExitCode가 $null로 남을 수 있다. 여기서 Handle을 한 번 읽어 캐시한다.
        $null = $proc.Handle
        Write-Log "진행 시작 [$Stage] (PID: $($proc.Id), 명령: $ToolCmd) — 실시간: Get-Content $logRel -Wait" INFO

        # 로그 무변화(hang) 감지 + 하드 상한 + 프로세스 종료 대기: 단일 루프로 전 구간 감시.
        $monitor = New-StageMonitorBaseline -Proc $proc -StartedAt $startedAt -Limits $limits
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds $limits.Interval
            # 대기 중 정상 종료된 무출력 프로세스를 hang 임계 도달로 오판하지 않는다.
            # 특히 종료 시점이 임계 직전이면 이 재확인 없이 아래 noChange가 임계에 닿아
            # 이미 끝난 정상 프로세스를 'hang'으로 반환할 수 있다.
            $proc.Refresh()
            if ($proc.HasExited) { break }
            Write-StageState -Stage $Stage -Cycle $Cycle -State 'running' -ProcessId $proc.Id -EvidencePaths @($logRel) -Reason 'watcher heartbeat' -Model $Model
            $sz = if (Test-Path $logAbs) { (Get-Item $logAbs).Length } else { 0 }
            $logChanged = $sz -ne $monitor.LastSize
            if ($logChanged) { $monitor.LastLogChangedAt = Get-Date; $monitor.LastSize = $sz; $monitor.HangReported = $false }
            $noChange = [math]::Max(0, ((Get-Date) - $monitor.LastLogChangedAt).TotalSeconds)
            # 아래에서 $noChange를 증가율의 '분모'로 그대로 쓰므로 값 자체를 반올림하지 않는다.
            # 사람이 읽는 로그 문구에만 반올림한 별도 변수를 쓴다.
            $noChangeText = [math]::Round($noChange)

            # 자식 에이전트/도구를 포함한 트리 CPU. 무변화 구간의 '증가율'로 hang을 판정하므로,
            # 기준점(IdleStartedMetrics)은 로그가 변한 시점에만 리셋한다 — CPU 변화로도 리셋하면
            # 아래 계산이 늘 직전 한 틱만 보게 되어 판정이 무의미해진다.
            $metricsNow = Get-ProcessTreeMetrics -RootProcessId $proc.Id
            if ($logChanged) { $monitor.IdleStartedMetrics = $metricsNow }

            Advance-StageWindow -Monitor $monitor -LogSize $sz -ExtendStep $limits.ExtendStep
            Write-StageHeartbeat -Stage $Stage -StartedAt $startedAt -Monitor $monitor -LogSize $sz -CpuNow $metricsNow.Cpu -metricsNow $metricsNow

            if ($noChange -ge $hangLimit) {
                $hangDecision = Test-StageHangProgress -Stage $Stage -Monitor $monitor -metricsNow $metricsNow -noChange $noChange -noChangeText $noChangeText -Config $Config
                if ($hangDecision.Action -eq 'kill-hang') {
                    Stop-ProcessTree $proc.Id
                    $policyKilled = $true
                    Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" WARN
                    return 'hang'
                }
                if ($hangDecision.Action -eq 'kill-git') {
                    Stop-ProcessTree $proc.Id
                    $policyKilled = $true
                    Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" WARN
                    return 'hang'
                }
            }

            $deadlineDecision = Test-StageDeadlineElapsed -Stage $Stage -Monitor $monitor -LogSize $sz -Limits $limits -logAbs $logAbs -StartedAt $startedAt -CpuNow $metricsNow.Cpu
            if ($deadlineDecision.Action -eq 'die') {
                Write-Log $deadlineDecision.Message ERROR
                Stop-ProcessTree $proc.Id
                $policyKilled = $true
                Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" ERROR
                return 'timeout'
            }
        }

        $proc.WaitForExit()
        $ExitCode.Value = $proc.ExitCode
        Write-Log "진행 완료 [$Stage] (PID: $($proc.Id), Exit Code: $($proc.ExitCode), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" INFO
        # CFG077 (CFG-BL-047): 정상 종료 뒤에도 잔존할 수 있는 손자 프로세스가 post-hoc
        # verify 게이트와 경합하지 않도록, 루트 종료 시점의 자손 트리가 완전히 정리될
        # 때까지 짧은 상한 안에서 대기한다(비차단·경계 확정).
        Wait-AgentTreeDrained -RootProcessId $proc.Id -Stage $Stage
        return 'ok'
    } finally {
        if ($null -ne $startedAt) {
            $ElapsedSeconds.Value = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        }
        # Ctrl+C(파이프라인 중단)는 이 finally를 **동기적으로** 먼저 실행한다. 비동기 이벤트
        # 액션(Invoke-DispatcherCleanup)은 그 뒤에야 큐에서 돌기 때문에, 여기서 추적 변수를
        # 그냥 비우면 정리 함수가 항상 $null을 보고 아무것도 못 한다 — 모델 자식 프로세스가
        # 살아남아 다음 디스패치와 같은 저장소를 동시에 쓴다(§3.9가 막으려던 바로 그 상태).
        # 자식이 아직 살아 있다는 건 정상 종료가 아니라는 뜻이므로, 여기서 직접 끊는다.
        # 정리 함수 쪽 경로도 그대로 두어, finally가 돌지 않는 경우에도 한쪽은 반드시 걸린다
        # (양쪽 다 $script:CleanupStarted / HasExited로 중복 실행을 막는다).
        if ($proc -and -not $policyKilled -and -not $proc.HasExited) {
            if ($Stage -eq 'integration') {
                Write-Log "⚠️ 디스패처 중단 — integration PID $($proc.Id)는 커밋/푸시 단계라 자동 종료하지 않는다." WARN
            } else {
                Stop-ProcessTree $proc.Id
                Write-Log "디스패처 중단 — 자식 프로세스 트리 종료 PID $($proc.Id)" WARN
            }
        }
        Remove-Item $shPath -ErrorAction SilentlyContinue
        $script:ActiveChildProcessId = $null; $script:ActiveChildStage = $null
    }
}
