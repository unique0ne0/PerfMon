# Harness lock/admission module — dispatch lock, admission mutex, and failure/blocked markers.
# Depends on: harness-io.ps1 (Read-HarnessLockFile), harness-contracts.ps1 (Get-PacketScopePaths)
# Caller must provide: $LockPrefix, $LogDir, $TaskId, $FailedPrefix, $BlockedPrefix, $script:ActiveLockStage, $script:RepoRoot
# Also depends on main dispatcher functions: Resolve-RepoPath, Write-Log, Get-TreeState, Find-PacketByTaskId

function Get-LockPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$LockPrefix-$Stage")
}


function Read-DispatchLock {
    param([string]$Stage)
    $p = Get-LockPath $Stage
    $lock = Read-HarnessLockFile -Path $p
    if (-not $lock -or [string]::IsNullOrWhiteSpace($lock.Raw)) { return $null }
    return @{
        Path = $lock.Path
        Raw = $lock.Raw
        ProcId = $lock.ProcessId
        TaskId = $lock.TaskId
        StartedAt = [string]$lock.StartedAt
        ProcessStartedAt = $lock.ProcessStartedAt
        Alive = $lock.Alive
    }
}


function Remove-StaleDispatchLock {
    param([hashtable]$Lock)

    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Lock.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true, 1024, $true)
        try { $currentRaw = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        if ($currentRaw -ne $Lock.Raw) { return $false }
    } catch [System.IO.IOException] {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }

    $stream2 = $null
    try {
        $stream2 = [System.IO.File]::Open($Lock.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $reader2 = New-Object System.IO.StreamReader($stream2, [System.Text.Encoding]::UTF8, $true, 1024, $true)
        try { $reverifyRaw = $reader2.ReadToEnd().Trim() } finally { $reader2.Dispose() }
        if ($reverifyRaw -ne $Lock.Raw) { return $false }
    } catch [System.IO.IOException] {
        return $false
    } finally {
        if ($stream2) { $stream2.Dispose() }
    }

    try {
        Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}


function Get-AdmissionMutexName {
    $repoRoot = if ($script:RepoRoot) { $script:RepoRoot } else { '.' }
    try {
        $absRoot = (Resolve-Path $repoRoot -ErrorAction Stop).Path
    } catch {
        $absRoot = [System.IO.Path]::GetFullPath($repoRoot)
    }
    $hashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([System.Text.Encoding]::UTF8.GetBytes($absRoot.ToLowerInvariant()))
    $hash = [System.BitConverter]::ToString($hashBytes).Replace('-','').Substring(0, 16)
    return "Local\dispatch-admission-$hash"
}

function Enter-AdmissionMutex {
    $mutexName = Get-AdmissionMutexName
    $createdNew = $false
    $mutex = New-Object System.Threading.Mutex($false, $mutexName, [ref]$createdNew)
    $timeoutMs = 10000
    if (-not $mutex.WaitOne($timeoutMs)) {
        $mutex.Dispose()
        return $null
    }
    return $mutex
}

function Exit-AdmissionMutex {
    param([System.Threading.Mutex]$Mutex)
    if ($null -eq $Mutex) { return }
    try { $Mutex.ReleaseMutex() } catch { }
    try { $Mutex.Dispose() } catch { }
}


function Enter-DispatchLock {
    param([string]$Stage, [string]$PacketPath)
    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path $logDirAbs)) { New-Item -ItemType Directory -Path $logDirAbs -Force | Out-Null }

    $admissionMutex = Enter-AdmissionMutex
    if ($null -eq $admissionMutex) {
        $mutexName = Get-AdmissionMutexName
        Write-Log "⛔ [$Stage] admission 뮤텍스 획득 타임아웃(10초) — 다른 프로세스가 보유 중이거나 시스템 부하가 높습니다. 재시도하세요. (name: $mutexName)" ERROR
        Write-BlockedMarker -Stage $Stage -Reason 'Admission mutex timeout (10s)' -OwnerTaskId '-' -OwnerProcessId '-'
        return $false
    }
    try {

    foreach ($s in @('impl','qa','integration')) {
        $lock = Read-DispatchLock $s
        if ($null -eq $lock) { continue }
        if (-not $lock.Alive) {
            if (Remove-StaleDispatchLock -Lock $lock) {
                Write-Log "스테일 락 정리: [$s] PID $($lock.ProcId) 는 이미 종료됨" INFO
                continue
            }
            $reRead = Read-DispatchLock $s
            if ($reRead -and $reRead.Alive) {
                $lock = $reRead
            } else {
                if ($s -eq $Stage) {
                    Write-Log "⛔ [$s] 스테일 락 정리 실패 후 재확인 불가 — 자기 단계이므로 차단" ERROR
                    Write-BlockedMarker -Stage $Stage -Reason '스테일 락 정리 실패 (자기 단계)' -OwnerTaskId '-' -OwnerProcessId '-'
                    return $false
                }
                Write-Log "⚠️ [$s] 스테일 락 정리 실패 — 무관한 단계이므로 계속 진행" WARN
                continue
            }
        }
        if ($s -eq $Stage) {
            Write-Log "⛔ [$Stage]가 이 저장소에서 이미 실행 중 — 작업 $($lock.TaskId), PID $($lock.ProcId), 시작 $($lock.StartedAt)" ERROR
            Write-Log "§3.9: 같은 저장소에서 한 팀에 두 패킷을 동시에 디스패치하지 않는다. 먼저 끝난 뒤 실행하세요." ERROR
            Write-BlockedMarker -Stage $Stage -Reason "[$Stage] 단계가 이미 실행 중" -OwnerTaskId $lock.TaskId -OwnerProcessId $lock.ProcId
            return $false
        }
        if ($s -eq 'integration' -or $Stage -eq 'integration') {
            Write-Log "⛔ ⑤ Integration은 저장소당 하나 — 현재 [$s] 실행 중(작업 $($lock.TaskId), PID $($lock.ProcId))" ERROR
            Write-Log "§3.9: 커밋·푸시·history.md·라우터를 공유하므로 동시 실행 시 병합 충돌·기록 유실이 난다." ERROR
            Write-BlockedMarker -Stage $Stage -Reason 'Integration 단계가 실행 중이라 배타적으로 차단됨' -OwnerTaskId $lock.TaskId -OwnerProcessId $lock.ProcId
            return $false
        }
        Write-Log "⚠️ 같은 저장소에서 [$s](작업 $($lock.TaskId))가 병행 중 — §3.9 상한표상 N=2 조건부 구간" WARN
        Write-Log "⚠️ 무변경 감지·기준점 롤백이 무력화되고, verify가 남의 중간 상태 때문에 실패할 수 있습니다." WARN
    }

    # ── Scope paths 겹침 차단 (CFG072) ──────────────────────────────────────
    # 서로 다른 패킷이 같은 파일을 건드리는 것을 admission 단계에서 방지한다.
    # 기존 락 체크는 같은 스테이지·integration 배타만 보았으나, 서로 다른 스테이지라도
    # Scope paths가 겹치면 병합 충돌 위험이 있다(CFG069+CFG071 사례).
    try {
        $myScopePaths = $null
        if ($PacketPath) {
            $myScopePaths = Get-PacketScopePaths -PacketPath $PacketPath
        }
        if ($null -ne $myScopePaths -and $myScopePaths.Count -gt 0) {
            $repoRoot = Resolve-RepoPath '.'
            foreach ($s in @('impl','qa','integration')) {
                $existingLock = Read-DispatchLock $s
                if ($null -eq $existingLock -or -not $existingLock.Alive) { continue }
                if ($existingLock.TaskId -eq $TaskId) { continue }
                $otherPacket = Find-PacketByTaskId -SearchTaskId $existingLock.TaskId -ProjectPath $repoRoot
                if (-not $otherPacket) {
                    Write-Log "⚠️ [$s] 작업 $($existingLock.TaskId)의 패킷을 찾을 수 없음 — Scope 비교 건너뜀" WARN
                    continue
                }
                $otherScopePaths = $null
                try {
                    $otherScopePaths = Get-PacketScopePaths -PacketPath $otherPacket
                } catch {
                    Write-Log "⚠️ [$s] 작업 $($existingLock.TaskId) Scope paths 파싱 예외 — 허용 쪽으로 fail: $($_.Exception.Message)" WARN
                    continue
                }
                if ($null -eq $otherScopePaths -or $otherScopePaths.Count -eq 0) {
                    Write-Log "⚠️ [$s] 작업 $($existingLock.TaskId)에 Scope paths 선언 없음 — 차단하지 않음" WARN
                    continue
                }
                $overlap = @($myScopePaths | Where-Object {
                    $mine = $_ -replace '\\', '/'
                    @($otherScopePaths | Where-Object {
                        $theirs = $_ -replace '\\', '/'
                        $mine -eq $theirs -or $mine.StartsWith("$theirs/") -or $theirs.StartsWith("$mine/")
                    }).Count -gt 0
                })
                if ($overlap.Count -gt 0) {
                    $overlapList = $overlap -join ', '
                    Write-Log "⛔ [$Stage] Scope paths 겹침 — 작업 $($existingLock.TaskId)와 [$overlapList] 공유" ERROR
                    Write-Log "§3.9: 서로 다른 패킷이 같은 파일을 건드리면 병합 충돌이 난다. 먼저 끝난 뒤 실행하세요." ERROR
                    Write-BlockedMarker -Stage $Stage -Reason "Scope paths 겹침: 작업 $($existingLock.TaskId) — [$overlapList]" -OwnerTaskId $existingLock.TaskId -OwnerProcessId $existingLock.ProcId
                    return $false
                }
            }
        }
    } catch {
        Write-Log "⚠️ Scope overlap 검사 중 예외 — 허용 쪽으로 fail: $($_.Exception.Message)" WARN
    }

    # 재실행은 이전 실패 판정을 무효화한다 — 대시보드가 RUNNING 옆에 낡은 FAILED를 같이 들고 있지 않도록.
    # CFG017: 같은 TaskId의 다른 단계 마커나 다른 TaskId 마커는 절대 지우지 않는다 — 증거 보존.
    Clear-FailureMarker -Stage $Stage
    Clear-BlockedMarker -Stage $Stage

    $processStartedAt = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('o')
    $body = "$PID|$TaskId|$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))|$env:COMPUTERNAME|$processStartedAt"
    try {
        $stream = [System.IO.File]::Open((Get-LockPath $Stage), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
            try { $writer.Write($body) } finally { $writer.Dispose() }
        } finally { $stream.Dispose() }
        $script:ActiveLockStage = $Stage
        return $true
    } catch [System.IO.IOException] {
        $lock = Read-DispatchLock $Stage
        if ($lock -and $lock.Alive) {
            Write-Log "⛔ [$Stage] 락 획득 경합 — 작업 $($lock.TaskId), PID $($lock.ProcId)가 먼저 시작됨" ERROR
            Write-BlockedMarker -Stage $Stage -Reason '락 파일 생성 경합' -OwnerTaskId $lock.TaskId -OwnerProcessId $lock.ProcId
            return $false
        }
        Write-Log "⛔ [$Stage] 락 파일 생성 경합 후 상태를 확정할 수 없습니다. 재시도하세요." ERROR
        Write-BlockedMarker -Stage $Stage -Reason '락 파일 생성 경합 후 점유자 상태를 확정할 수 없음' -OwnerTaskId '-' -OwnerProcessId '-'
        return $false
    }

    } finally {
        Exit-AdmissionMutex -Mutex $admissionMutex
    }
}


function Exit-DispatchLock {
    param([string]$Stage)
    $p = Get-LockPath $Stage
    $lock = Read-DispatchLock $Stage
    if ($lock -and $lock.ProcId -eq $PID -and $lock.TaskId -eq $TaskId) {
        Remove-Item $p -Force -ErrorAction SilentlyContinue
    }
    # 락 해제 시 자기 TaskId/Stage의 blocked 마커도 함께 지운다. 실행 도중 재귀·다른 경로에서
    # 같은 TaskId/Stage로 디스패치를 시도해 blocked 마커가 찍히면, Clear-BlockedMarker는
    # 락 획득 시점에만 도므로 그 이후에 생긴 마커는 성공 후에도 잔존한다(CFG-BL-013).
    Clear-BlockedMarker -Stage $Stage
    if ($script:ActiveLockStage -eq $Stage) { $script:ActiveLockStage = $null }
}


$FailedPrefix = "$LogDir/.dispatch-failed"


function Get-FailureMarkerPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$FailedPrefix-$TaskId-$Stage")
}


function Clear-FailureMarker {
    param([string]$Stage)
    $p = Get-FailureMarkerPath $Stage
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

function Write-FailureMarker {
    param([string]$Stage, [string]$Reason)
    $state = Get-TreeState
    if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.Dirty)) { $dirty = 1 } else { $dirty = 0 }
    # 파이프는 필드 구분자다. 사유 문구에 섞여 들어오면 대시보드 파싱이 어긋나므로 치환한다.
    $safeReason = ($Reason -replace '\|', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($safeReason)) { $safeReason = '알 수 없는 실패' }
    $body = "$TaskId|$Stage|$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))|$safeReason|$dirty"
    try {
        [System.IO.File]::WriteAllText((Get-FailureMarkerPath $Stage), $body, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "실패 마커 기록: $FailedPrefix-$TaskId-$Stage ($safeReason)" WARN
    } catch {
        # 마커를 못 써도 단계 결과 자체를 뒤집지 않는다 — 사유는 이미 워처 로그에 남아 있다.
    }
}


$BlockedPrefix = "$LogDir/.dispatch-blocked"


function Get-BlockedMarkerPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$BlockedPrefix-$TaskId-$Stage")
}


function Clear-BlockedMarker {
    param([string]$Stage)
    $p = Get-BlockedMarkerPath $Stage
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

function Write-BlockedMarker {
    param([string]$Stage, [string]$Reason, [string]$OwnerTaskId, [string]$OwnerProcessId)
    $safeReason = ($Reason -replace '\|', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($safeReason)) { $safeReason = '알 수 없는 차단' }
    if ([string]::IsNullOrWhiteSpace($OwnerTaskId)) { $OwnerTaskId = '-' }
    if ([string]::IsNullOrWhiteSpace($OwnerProcessId)) { $OwnerProcessId = '-' }
    $body = "$TaskId|$Stage|$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))|$safeReason|$OwnerTaskId|$OwnerProcessId"
    try {
        [System.IO.File]::WriteAllText((Get-BlockedMarkerPath $Stage), $body, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "차단 마커 기록: $BlockedPrefix-$TaskId-$Stage ($safeReason)" WARN
    } catch {
        # 차단 마커를 못 써도 실제 락 판정은 바꾸지 않는다.
    }
}
#endregion 락·디스패치 게이트 마커

function Write-KilledLeftover {
    param([hashtable]$Before, [string]$Stage, [string]$Context)
    $after = Get-TreeState
    if ($null -eq $Before -or $null -eq $after) { return }
    if ($Before.Head -ne $after.Head) {
        Write-Log "⚠️ [$Stage] $Context — 죽기 전에 커밋까지 진행됨 (HEAD $($Before.Head) → $($after.Head))" WARN
    }
    if ($Before.Dirty -ne $after.Dirty -or $Before.Fingerprint -ne $after.Fingerprint) {
        Write-Log "⚠️ [$Stage] $Context — 반쯤 편집된 작업트리가 남았습니다:" WARN
        @($after.Dirty -split "`n") | Where-Object { $_ } | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
        Write-Log "복구: 기준점(§3.1)으로 되돌리려면 git checkout -- <경로> / 보존하려면 git stash push -m '$TaskId $Stage 중단분'" WARN
    } elseif (-not $Before.FingerprintOk -or -not $after.FingerprintOk) {
        Write-Log "[$Stage] $Context — 작업트리 변경 여부 판정 불가(지문 계산 실패). 남은 변경을 직접 확인할 것" WARN
    } else {
        Write-Log "[$Stage] $Context — 작업트리 변경 없음(깨끗한 상태에서 중단)" INFO
    }
}


