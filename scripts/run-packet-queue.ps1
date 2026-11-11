# run-packet-queue.ps1 — CFG122
# 기획이 끝난 패킷 여러 건을 "한 번에 작성 → 순차 무인 실행"하기 위한 얇은 큐 러너다.
# 각 항목은 기존 dispatch-with-hang-detect.ps1 -Chain 을 그대로 호출하며(디스패처 본체 무변경),
# 스폰은 항상 1개 체인씩 순차다. 병렬·worktree 는 쓰지 않는다(promotion-notes 2차 보류 유지).
#
# 사용 예:
#   powershell -File scripts\run-packet-queue.ps1 -TaskIds CFG123,CFG124,CFG125
#   powershell -File scripts\run-packet-queue.ps1 -TaskIds CFG123,CFG124 -DryRun
#
# 백그라운드 기동(콘솔 로그는 저장소 밖 — 트리 안 로그는 무변경 감지를 깨뜨린다):
#   Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File',
#       'scripts\run-packet-queue.ps1','-TaskIds','CFG123,CFG124' `
#       -RedirectStandardOutput "$env:TEMP\packet-queue.log" -RedirectStandardError "$env:TEMP\packet-queue.err"
#
# 시작 전 검사(하나라도 실패하면 스폰 0건, exit 1, 사유 전부 출력):
#   1. 라우터 행 존재 + 상태 ACTIVE/WAITING (+ 패킷·Planning Challenge Review 준비)
#   2. 의존(라우터 `Blocked by`) — DONE 이거나 같은 묶음에서 앞 순서
#   3. Scope paths 겹침 — 뒤 패킷이 앞 패킷을 Blocked by 로 선언한 경우만 허용(history.md 면제)
#   4. 큐 락(.packet-queue.lock)·단계 락(.dispatch-lock-*)·살아 있는 단계 lease 부재
#   5. 각 패킷 Planning Challenge Review Decision = not-required|completed
#
# 실행: 항목 디스패치 직전 기존 chain-summary 를 삭제하고 동기 실행. 성공은
#   exit 0 + 요약 파일 존재 + state='completed' 3조건 모두. 하나라도 불충족이면 즉시 중단
#   (요약 JSON + Console.Beep()). 항목 간 가드(의존 재확인·락 잔존·더티/드리프트 겹침)도 있다.
param(
    [Parameter(Mandatory = $false)][string[]]$TaskIds,
    [Parameter(Mandatory = $false)][int]$MaxPackets = 5,
    [Parameter(Mandatory = $false)][string]$DispatcherPath,
    [Parameter(Mandatory = $false)][switch]$DryRun,
    [Parameter(Mandatory = $false)][string]$RepoRoot
)

$ErrorActionPreference = 'Stop'

function Write-QueueLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')][string]$Level = 'INFO')
    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function Resolve-QueueRepoRoot {
    param([string]$Explicit, [string]$ScriptDir)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return (Resolve-Path -LiteralPath $Explicit).Path }
    $dir = (Resolve-Path -LiteralPath $ScriptDir).Path
    for ($i = 0; $i -lt 4; $i++) {
        if (Test-Path -LiteralPath (Join-Path $dir '.agents\briefs\handoff-log.md')) { return $dir }
        $parent = Split-Path -Parent $dir
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $dir) { break }
        $dir = $parent
    }
    return (Split-Path -Parent $ScriptDir)
}

function Resolve-QueueDispatcherPath {
    param([string]$Explicit)
    if (-not [string]::IsNullOrWhiteSpace($Explicit)) {
        if ([System.IO.Path]::IsPathRooted($Explicit)) { return $Explicit }
        return (Join-Path $script:QueueRepoRoot ($Explicit -replace '/', '\'))
    }
    $default = Join-Path $script:QueueRepoRoot 'scripts\dispatch-with-hang-detect.ps1'
    if (Test-Path -LiteralPath $default) { return $default }
    $sibling = Join-Path $PSScriptRoot 'dispatch-with-hang-detect.ps1'
    if (Test-Path -LiteralPath $sibling) { return $sibling }
    return $default
}

function Get-QueueLogDir {
    return (Join-Path $script:QueueRepoRoot '.agents\briefs\logs')
}

function Get-QueueRouterRows {
    # 캐시하지 않는다 — 항목 간 의존 재검증은 항상 디스크를 다시 읽는다.
    $rows = @{}
    if (-not (Test-Path -LiteralPath $script:QueueRouterPath)) { return $rows }
    foreach ($line in @(Get-Content -LiteralPath $script:QueueRouterPath -Encoding UTF8)) {
        $info = Get-RouterRowInfo -Line $line
        if (-not $info) { continue }
        $rows[(Get-NormalizedTaskId -TaskId $info.TaskId)] = $info
    }
    return $rows
}

function Get-QueueBlockedByColumnIndex {
    if (-not (Test-Path -LiteralPath $script:QueueRouterPath)) { return -1 }
    foreach ($line in @(Get-Content -LiteralPath $script:QueueRouterPath -Encoding UTF8)) {
        if ($line -notmatch '^\s*\|') { continue }
        $cells = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        for ($i = 0; $i -lt $cells.Count; $i++) {
            if ($cells[$i] -match '^(?i)blocked\s+by$') { return $i }
        }
    }
    return -1
}

function Test-QueueArchivedDone {
    param([string]$TaskId)
    $norm = Get-NormalizedTaskId -TaskId $TaskId
    if ([string]::IsNullOrWhiteSpace($norm)) { return $false }
    if (-not (Test-Path -LiteralPath $script:QueueArchiveDir)) { return $false }
    foreach ($f in @(Get-ChildItem -LiteralPath $script:QueueArchiveDir -Filter 'router-done-rows-*.md' -File -ErrorAction SilentlyContinue)) {
        foreach ($line in @(Get-Content -LiteralPath $f.FullName -Encoding UTF8)) {
            $info = Get-RouterRowInfo -Line $line
            if (-not $info) { continue }
            if ((Get-NormalizedTaskId -TaskId $info.TaskId) -ne $norm) { continue }
            if ($info.Status.Trim().ToUpperInvariant() -eq 'DONE') { return $true }
        }
    }
    return $false
}

function Resolve-QueuePacketPath {
    param([object]$Row, [string]$TaskId)
    $briefsDir = Join-Path $script:QueueRepoRoot '.agents\briefs'
    if ($Row -and $Row.Cells.Count -ge 2) {
        $m = [regex]::Match([string]$Row.Cells[1], '\]\(([^)]+)\)')
        if ($m.Success) {
            $candidate = Join-Path $briefsDir ($m.Groups[1].Value.Trim() -replace '/', '\')
            if (Test-Path -LiteralPath $candidate) { return $candidate }
        }
    }
    foreach ($dir in @((Join-Path $briefsDir 'packets'), $script:QueueArchiveDir)) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $hit = Get-ChildItem -LiteralPath $dir -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    return $null
}

function ConvertTo-QueueScopePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $p = $Path.Trim().Trim('"').Trim("'") -replace '\\', '/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $p = $p.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($p)) { return $null }
    return $p
}

function Test-QueueScopeExempt {
    # history.md 는 누적 기록 파일이라 여러 패킷이 동시에 만지는 것이 정상이다.
    param([string]$Path)
    return ((Split-Path -Leaf $Path) -ieq 'history.md')
}

function Get-QueueScopePaths {
    param([string]$PacketPath)
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return @() }
    $text = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8
    $section = [regex]::Match($text, '(?ms)^##\s+Scope Map\s*$\r?\n(.*?)(?=^##\s+|\z)')
    if (-not $section.Success) { return @() }
    $line = [regex]::Match($section.Groups[1].Value, '(?m)^\s*-\s*Scope paths:\s*(.+)$')
    if (-not $line.Success) { return @() }
    $paths = @()
    foreach ($m in [regex]::Matches($line.Groups[1].Value, '`([^`]+)`')) {
        $norm = ConvertTo-QueueScopePath -Path $m.Groups[1].Value
        if ($null -eq $norm) { continue }
        if (Test-QueueScopeExempt -Path $norm) { continue }
        if ($paths -notcontains $norm) { $paths += $norm }
    }
    return @($paths)
}

function Test-QueueScopeOverlap {
    param([string]$A, [string]$B)
    if ([string]::IsNullOrWhiteSpace($A) -or [string]::IsNullOrWhiteSpace($B)) { return $false }
    if ($A.Equals($B, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($A.StartsWith("$B/", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($B.StartsWith("$A/", [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    return $false
}

function Get-QueueBlockedByIds {
    param([string]$Cell)
    $ids = @()
    if ([string]::IsNullOrWhiteSpace($Cell)) { return $ids }
    foreach ($m in [regex]::Matches($Cell, '[A-Za-z]+\s*[-_]?\s*\d+')) {
        $norm = Get-NormalizedTaskId -TaskId $m.Value
        if ($norm -notmatch '^[A-Z]+\d+$') { continue }
        if ($ids -notcontains $norm) { $ids += $norm }
    }
    return $ids
}

function Get-QueueRowBlockedByIds {
    param([hashtable]$Rows, [string]$TaskId)
    $norm = Get-NormalizedTaskId -TaskId $TaskId
    if (-not $Rows.ContainsKey($norm)) { return @() }
    $row = $Rows[$norm]
    if ($script:QueueBlockedByIndex -lt 0) { return @() }
    if ($row.Cells.Count -le $script:QueueBlockedByIndex) { return @() }
    return @(Get-QueueBlockedByIds -Cell ([string]$row.Cells[$script:QueueBlockedByIndex]))
}

function Get-QueueHead {
    $lines = @(Invoke-GitPathList -RepoRoot $script:QueueRepoRoot -GitArgs @('rev-parse', 'HEAD'))
    $head = ($lines | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($head)) { return $null }
    return ([string]$head).Trim()
}

function Get-QueueDirtyFiles {
    $lines = @(Invoke-GitPathList -RepoRoot $script:QueueRepoRoot -GitArgs @('status', '--porcelain', '--untracked-files=all'))
    $files = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line.Length -lt 4) { continue }
        $p = $line.Substring(3).Trim()
        # A staged rename changes both paths: the source is deleted as well as
        # the destination created. Both can overlap the next packet's scope.
        $paths = if ($line.Substring(0, 2) -match 'R') { @($p -split ' -> ', 2) } else { @($p) }
        foreach ($path in $paths) {
            $path = $path.Trim().Trim('"') -replace '\\', '/'
            if (-not [string]::IsNullOrWhiteSpace($path)) { $files += $path }
        }
    }
    return @($files | Sort-Object -Unique)
}

function Get-QueueChangedFiles {
    param([string]$FromHead, [string]$ToHead)
    if ([string]::IsNullOrWhiteSpace($FromHead) -or [string]::IsNullOrWhiteSpace($ToHead)) { return @() }
    if ($FromHead -eq $ToHead) { return @() }
    $lines = @(Invoke-GitPathList -RepoRoot $script:QueueRepoRoot -GitArgs @('diff', '--name-only', $FromHead, $ToHead) -NullDelimited)
    return @($lines | ForEach-Object { ($_ -replace '\\', '/') } | Where-Object { $_ })
}

function Get-QueueFilesOverlappingScope {
    param([string[]]$Files, [string[]]$ScopePaths)
    $hits = @()
    foreach ($f in $Files) {
        if ([string]::IsNullOrWhiteSpace($f)) { continue }
        $norm = $f -replace '\\', '/'
        if (Test-QueueScopeExempt -Path $norm) { continue }
        foreach ($sp in $ScopePaths) {
            if (Test-QueueScopeOverlap -A $norm -B $sp) { $hits += $norm; break }
        }
    }
    return @($hits | Sort-Object -Unique)
}

function Get-QueueDispatchLocks {
    $out = @()
    $logDir = Get-QueueLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { return $out }
    foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Filter '.dispatch-lock-*' -File -ErrorAction SilentlyContinue)) {
        $lock = Read-HarnessLockFile -Path $f.FullName
        $out += [pscustomobject]@{
            Name = $f.Name
            Alive = [bool]($lock -and $lock.Alive)
            TaskId = if ($lock) { [string]$lock.TaskId } else { $null }
            ProcessId = if ($lock) { [int]$lock.ProcessId } else { 0 }
        }
    }
    return $out
}

function Get-QueueActiveLeases {
    $active = @()
    $logDir = Get-QueueLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { return $active }
    foreach ($f in @(Get-ChildItem -LiteralPath $logDir -Filter '*-stage-state.json' -File -ErrorAction SilentlyContinue)) {
        $state = $null
        try { $state = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if (-not $state) { continue }
        $stateName = ([string]$state.state).Trim().ToLowerInvariant()
        if ($stateName -ne 'starting' -and $stateName -ne 'running') { continue }
        $procId = 0
        if (-not [int]::TryParse([string]$state.pid, [ref]$procId) -or $procId -le 0) { continue }
        if (-not (Get-Process -Id $procId -ErrorAction SilentlyContinue)) { continue }
        $active += [pscustomobject]@{
            File = $f.Name
            TaskId = [string]$state.taskId
            Stage = [string]$state.stage
            ProcessId = $procId
        }
    }
    return $active
}

function Get-QueueLockPath {
    return (Join-Path (Get-QueueLogDir) '.packet-queue.lock')
}

function Get-QueueLockBody {
    $processStartedAt = ''
    try { $processStartedAt = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('o') } catch { $processStartedAt = '' }
    return "$PID|packet-queue|$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))|$env:COMPUTERNAME|$processStartedAt"
}

function New-QueueLockFile {
    param([string]$Path, [string]$Body)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
        try { $writer.Write($Body) } finally { $writer.Dispose() }
    } finally {
        $stream.Dispose()
    }
}

function Enter-QueueLock {
    param([System.Collections.Generic.List[string]]$Failures)
    $logDir = Get-QueueLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $path = Get-QueueLockPath
    $body = Get-QueueLockBody
    try {
        New-QueueLockFile -Path $path -Body $body
        return @{ Acquired = $true; Path = $path }
    } catch [System.IO.IOException] {
        $lock = Read-HarnessLockFile -Path $path
        if ($lock -and $lock.Alive) {
            $Failures.Add("큐 락이 살아 있는 프로세스에 점유됨: PID $($lock.ProcessId) ($($lock.TaskId))")
            return @{ Acquired = $false; Path = $path }
        }
        Write-QueueLog "스테일 큐 락 회수(죽은 PID): $path" WARN
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        try {
            New-QueueLockFile -Path $path -Body $body
            return @{ Acquired = $true; Path = $path }
        } catch [System.IO.IOException] {
            $again = Read-HarnessLockFile -Path $path
            $holder = if ($again -and $again.ProcessId -gt 0) { "PID $($again.ProcessId)" } else { '소유자 미확인' }
            $Failures.Add("큐 락 획득 경합 후 상태 확정 불가 ($holder)")
            return @{ Acquired = $false; Path = $path }
        }
    }
}

function Exit-QueueLock {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    $lock = Read-HarnessLockFile -Path $Path
    if ($lock -and $lock.ProcessId -eq $PID) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}

function Write-QueueSummary {
    param(
        [object[]]$Items,
        [object]$StoppedAt,
        [datetime]$StartedAt
    )
    $logDir = Get-QueueLogDir
    if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    $stamp = $StartedAt.ToLocalTime().ToString('yyyyMMdd-HHmmss')
    $path = Join-Path $logDir ".packet-queue-$stamp.json"
    $value = [ordered]@{
        schemaVersion = 1
        startedAt = $StartedAt.ToUniversalTime().ToString('o')
        completedAt = [datetime]::UtcNow.ToString('o')
        items = @($Items)
        stoppedAt = $StoppedAt
    }
    Write-AtomicJson -Path $path -Value $value -Depth 8
    return $path
}

function New-QueueItemResult {
    param([string]$TaskId, [string]$State, [string]$Reason, [datetime]$StartedAt, [datetime]$CompletedAt)
    return [ordered]@{
        taskId = $TaskId
        state = $State
        reason = $Reason
        startedAt = $StartedAt.ToUniversalTime().ToString('o')
        completedAt = $CompletedAt.ToUniversalTime().ToString('o')
        elapsedSeconds = [math]::Round(($CompletedAt - $StartedAt).TotalSeconds, 1)
    }
}

function Print-QueueFailures {
    param([System.Collections.Generic.List[string]]$Failures)
    Write-QueueLog "시작 전 검사 실패 — 스폰 0건" ERROR
    $n = 0
    foreach ($f in $Failures) {
        $n++
        Write-Host "  [FAIL $n] $f" -ForegroundColor Red
    }
}

# ── 준비 ────────────────────────────────────────────────────────────────────
$script:QueueRepoRoot = Resolve-QueueRepoRoot -Explicit $RepoRoot -ScriptDir $PSScriptRoot
$script:QueueRouterPath = Join-Path $script:QueueRepoRoot '.agents\briefs\handoff-log.md'
$script:QueueArchiveDir = Join-Path $script:QueueRepoRoot '.agents\briefs\archive'

foreach ($moduleName in @('harness-contracts.ps1', 'harness-io.ps1', 'harness-dispatch-core.ps1')) {
    $modulePath = Join-Path $PSScriptRoot $moduleName
    if (-not (Test-Path -LiteralPath $modulePath)) { throw "Required harness module not found: $modulePath" }
    . $modulePath
}

$failures = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

if (-not $TaskIds -or $TaskIds.Count -eq 0) {
    Write-QueueLog "-TaskIds 로 실행할 작업 ID 를 1개 이상 지정해야 합니다." ERROR
    exit 1
}

# `powershell -File ... -TaskIds CFG123,CFG124` 는 쉼표 목록을 단일 문자열 하나로 전달한다
# (-Command 와 달리 배열 파싱을 하지 않는다). 두 호출 형태를 모두 받도록 쉼표로 다시 나눈다.
$expandedIds = @()
foreach ($entry in $TaskIds) {
    foreach ($piece in ([string]$entry -split ',')) {
        $trimmed = $piece.Trim()
        if (-not [string]::IsNullOrWhiteSpace($trimmed)) { $expandedIds += $trimmed }
    }
}
$TaskIds = @($expandedIds)
if ($TaskIds.Count -eq 0) {
    Write-QueueLog "-TaskIds 가 비어 있습니다(쉼표 목록 확인)." ERROR
    exit 1
}

$dispatcherFull = Resolve-QueueDispatcherPath -Explicit $DispatcherPath
$script:QueueBlockedByIndex = Get-QueueBlockedByColumnIndex

# ── 검사 1: 상한·중복·ID 형식 ────────────────────────────────────────────────
if ($MaxPackets -le 0 -or $MaxPackets -gt 5) { $failures.Add("MaxPackets 는 1 이상, 상한 5 이하여야 합니다(현재 $MaxPackets).") }
if ($TaskIds.Count -gt $MaxPackets) {
    $failures.Add("작업이 $($TaskIds.Count)건입니다 — 묶음당 상한 $($MaxPackets)건을 초과했습니다. 패킷을 나눠 실행하세요.")
}

$normIds = @()
foreach ($rawId in $TaskIds) {
    $norm = Get-NormalizedTaskId -TaskId $rawId
    if ($norm -notmatch '^[A-Z]+\d+$') {
        $failures.Add("작업 ID 형식이 잘못됨: '$rawId' (프리픽스+숫자만, 예: CFG123)")
        $normIds += ''
        continue
    }
    if ($normIds -contains $norm) { $failures.Add("작업 ID 중복: $norm") }
    $normIds += $norm
}

# ── 검사 5/1: 라우터 행·상태·패킷·챌린지 리뷰 ───────────────────────────────
$rows = Get-QueueRouterRows
$packetPaths = New-Object System.Collections.Generic.List[string]
$scopePathsByIndex = New-Object System.Collections.Generic.List[object]
for ($i = 0; $i -lt $normIds.Count; $i++) {
    $norm = $normIds[$i]
    $packetPaths.Add($null)
    $scopePathsByIndex.Add(@())
    if ([string]::IsNullOrWhiteSpace($norm)) { continue }

    if (-not $rows.ContainsKey($norm)) {
        $failures.Add("$norm — 라우터에 작업 행이 없습니다.")
        continue
    }
    $row = $rows[$norm]
    $status = ([string]$row.Status).Trim().ToUpperInvariant()
    if ($status -ne 'ACTIVE' -and $status -ne 'WAITING') {
        $failures.Add("$norm — 라우터 상태가 '$status' 입니다. ACTIVE 또는 WAITING 만 큐에 넣을 수 있습니다.")
    }

    $packetPath = Resolve-QueuePacketPath -Row $row -TaskId $norm
    if (-not $packetPath) {
        $failures.Add("$norm — 패킷 파일을 찾을 수 없습니다(라우터 링크·packets/·archive/ 확인).")
        continue
    }
    $packetPaths[$i] = $packetPath

    $challenge = Get-PlanningChallengeReviewStatus -PacketPath $packetPath
    if (-not $challenge.Ready) {
        $failures.Add("$norm — Planning Challenge Review 가 준비되지 않았습니다: $($challenge.Reason) (Decision=$($challenge.Decision))")
    }

    $scopes = @(Get-QueueScopePaths -PacketPath $packetPath)
    if ($scopes.Count -eq 0) {
        $warnings.Add("$norm — Scope paths 선언이 없어 겹침 검사를 완화합니다(현행 디스패처와 동일).")
    }
    $scopePathsByIndex[$i] = $scopes
}

# ── 검사 2: 의존(Blocked by) ────────────────────────────────────────────────
if ($script:QueueBlockedByIndex -lt 0) {
    $failures.Add("라우터 헤더에서 'Blocked by' 열을 찾을 수 없어 의존 검사를 할 수 없습니다.")
} else {
    for ($i = 0; $i -lt $normIds.Count; $i++) {
        $norm = $normIds[$i]
        if ([string]::IsNullOrWhiteSpace($norm)) { continue }
        foreach ($pred in @(Get-QueueRowBlockedByIds -Rows $rows -TaskId $norm)) {
            $batchIndex = [Array]::IndexOf($normIds, $pred)
            if ($batchIndex -ge 0) {
                if ($batchIndex -ge $i) {
                    $failures.Add("$norm — Blocked by $pred 가 같은 묶음에서 뒤 순서(또는 자기 자신)입니다. 앞 순서로 배치하세요.")
                }
                continue
            }
            $done = $false
            if ($rows.ContainsKey($pred)) { $done = (([string]$rows[$pred].Status).Trim().ToUpperInvariant() -eq 'DONE') }
            if (-not $rows.ContainsKey($pred)) { $done = Test-QueueArchivedDone -TaskId $pred }
            if (-not $done) {
                $failures.Add("$norm — Blocked by $pred 가 미완이거나 묶음 밖입니다(현재 행 없음 또는 DONE 아님).")
            }
        }
    }
}

# ── 검사 3: Scope paths 겹침 ────────────────────────────────────────────────
for ($i = 0; $i -lt $normIds.Count; $i++) {
    if ([string]::IsNullOrWhiteSpace($normIds[$i])) { continue }
    for ($j = $i + 1; $j -lt $normIds.Count; $j++) {
        if ([string]::IsNullOrWhiteSpace($normIds[$j])) { continue }
        $pairs = @()
        foreach ($a in @($scopePathsByIndex[$i])) {
            foreach ($b in @($scopePathsByIndex[$j])) {
                if (Test-QueueScopeOverlap -A $a -B $b) { $pairs += "$a <-> $b" }
            }
        }
        if ($pairs.Count -eq 0) { continue }
        $declared = @(Get-QueueRowBlockedByIds -Rows $rows -TaskId $normIds[$j])
        if ($declared -contains $normIds[$i]) { continue }
        $pairText = ($pairs | Select-Object -Unique) -join ', '
        $failures.Add("Scope paths 겹침: $($normIds[$i]) 와 $($normIds[$j]) — [$pairText]. 뒤 패킷이 앞 패킷을 Blocked by 로 선언해야 허용됩니다.")
    }
}

# ── 검사 4: 락·lease ────────────────────────────────────────────────────────
$existingLocks = @(Get-QueueDispatchLocks)
if ($existingLocks.Count -gt 0) {
    $lockText = ($existingLocks | ForEach-Object { "$($_.Name)(PID $($_.ProcessId), $($_.TaskId))" }) -join ', '
    $failures.Add("단계 락 파일이 존재합니다: $lockText — 실행 중인 체인이 끝난 뒤 재시도하세요.")
}
$existingLeases = @(Get-QueueActiveLeases)
if ($existingLeases.Count -gt 0) {
    $leaseText = ($existingLeases | ForEach-Object { "$($_.TaskId)/$($_.Stage)(PID $($_.ProcessId))" }) -join ', '
    $failures.Add("살아 있는 단계 lease 가 있습니다: $leaseText")
}
$queueLockPath = Get-QueueLockPath
if (Test-Path -LiteralPath $queueLockPath) {
    $queueLock = Read-HarnessLockFile -Path $queueLockPath
    if ($queueLock -and $queueLock.Alive) {
        $failures.Add("큐 락이 살아 있는 프로세스에 점유됨: PID $($queueLock.ProcessId)")
    }
}

if ($failures.Count -gt 0) {
    Print-QueueFailures -Failures $failures
    exit 1
}

foreach ($w in $warnings) { Write-QueueLog $w WARN }
Write-QueueLog ("검사 통과: " + ($normIds -join ', ') + " ($($normIds.Count)건, 상한 $MaxPackets)") SUCCESS

if ($DryRun) {
    for ($i = 0; $i -lt $normIds.Count; $i++) {
        Write-Host "  [DRY-RUN] $($i + 1)/$($normIds.Count) $($normIds[$i]) → $dispatcherFull -TaskId $($normIds[$i]) -Chain"
    }
    Write-QueueLog "DryRun 완료 — 스폰 0건." SUCCESS
    exit 0
}

if (-not (Test-Path -LiteralPath $dispatcherFull)) {
    Write-QueueLog "디스패처를 찾을 수 없습니다: $dispatcherFull" ERROR
    exit 1
}

# ── 큐 락 획득 후 락·lease 재확인(검사→스폰 사이 틈새 축소) ─────────────────
$lockState = Enter-QueueLock -Failures $failures
if (-not $lockState.Acquired) {
    Print-QueueFailures -Failures $failures
    exit 1
}
$queueLockPath = $lockState.Path
$exitCode = 0
try {
    $raceLocks = @(Get-QueueDispatchLocks)
    $raceLeases = @(Get-QueueActiveLeases)
    if ($raceLocks.Count -gt 0 -or $raceLeases.Count -gt 0) {
        $failures.Add("큐 락 획득 직후 단계 락/lease 가 감지되었습니다 — 스폰하지 않습니다.")
        Print-QueueFailures -Failures $failures
        exit 1
    }

    $startedAt = [datetime]::UtcNow
    $itemResults = New-Object System.Collections.Generic.List[object]
    $stoppedAt = $null
    $stoppedReason = $null

    for ($i = 0; $i -lt $normIds.Count; $i++) {
        $id = $normIds[$i]

        # 항목 간 가드 — 앞 체인이 끝난 뒤, 다음 항목을 스폰하기 전에만 실행한다.
        if ($i -gt 0) {
            $guardFailures = New-Object System.Collections.Generic.List[string]
            $freshRows = Get-QueueRouterRows

            # (a) 의존 재검증 — 캐시 금지. 앞 순서 항목도 라우터가 DONE 이어야 한다.
            foreach ($pred in @(Get-QueueRowBlockedByIds -Rows $freshRows -TaskId $id)) {
                $done = $false
                if ($freshRows.ContainsKey($pred)) { $done = (([string]$freshRows[$pred].Status).Trim().ToUpperInvariant() -eq 'DONE') }
                if (-not $freshRows.ContainsKey($pred)) { $done = Test-QueueArchivedDone -TaskId $pred }
                if (-not $done) { $guardFailures.Add("Blocked by $pred 가 체인 종료 후에도 DONE 이 아닙니다(라우터 미갱신).") }
            }

            # (b) 락·lease 잔존
            $leftLocks = @(Get-QueueDispatchLocks)
            if ($leftLocks.Count -gt 0) {
                $guardFailures.Add("앞 체인 종료 후 단계 락이 남아 있습니다: " + (($leftLocks | ForEach-Object { $_.Name }) -join ', '))
            }
            $leftLeases = @(Get-QueueActiveLeases)
            if ($leftLeases.Count -gt 0) {
                $guardFailures.Add("앞 체인 종료 후 살아 있는 lease 가 남아 있습니다: " + (($leftLeases | ForEach-Object { "$($_.TaskId)/$($_.Stage)" }) -join ', '))
            }

            # (c) 더티 파일이 다음 패킷 Scope 와 겹침
            $nextScopes = @($scopePathsByIndex[$i])
            if ($nextScopes.Count -gt 0) {
                $dirtyHits = @(Get-QueueFilesOverlappingScope -Files @(Get-QueueDirtyFiles) -ScopePaths $nextScopes)
                if ($dirtyHits.Count -gt 0) {
                    $guardFailures.Add("uncommitted dirty files overlap next packet scope: " + ($dirtyHits -join ', '))
                }
            }

            # (d) 앞 패킷이 실제로 바꾼 파일이 다음 Scope 와 겹치는데 Blocked by 선언이 없음
            if ($nextScopes.Count -gt 0 -and $prevHeadBefore -and $prevHeadAfter) {
                $prevChanges = @(Get-QueueChangedFiles -FromHead $prevHeadBefore -ToHead $prevHeadAfter)
                $driftHits = @(Get-QueueFilesOverlappingScope -Files $prevChanges -ScopePaths $nextScopes)
                if ($driftHits.Count -gt 0) {
                    $declared = @(Get-QueueRowBlockedByIds -Rows $freshRows -TaskId $id)
                    if ($declared -notcontains $prevId) {
                        $guardFailures.Add("runtime scope drift: 앞 패킷 $prevId 변경분이 다음 Scope 와 겹칩니다 — " + ($driftHits -join ', '))
                    }
                }
            }

            if ($guardFailures.Count -gt 0) {
                $stoppedAt = $id
                $stoppedReason = ($guardFailures -join ' / ')
                foreach ($g in $guardFailures) { Write-QueueLog $g ERROR }
                Write-QueueLog "항목 간 가드 실패 — $id 스폰하지 않고 중단합니다." ERROR
                break
            }
        }

        # 이전 실행의 요약이 남아 있어도 성공으로 오판하지 않도록 스폰 직전 삭제한다.
        $chainSummaryPath = Join-Path (Get-QueueLogDir) "$id-chain-summary.json"
        if (Test-Path -LiteralPath $chainSummaryPath) {
            try { Remove-Item -LiteralPath $chainSummaryPath -Force -ErrorAction Stop } catch { }
        }
        if (Test-Path -LiteralPath $chainSummaryPath) {
            # 삭제 실패 시 스폰하지 않는다 — 남은 completed 요약을 성공으로 오판할 수 있다.
            $now = [datetime]::UtcNow
            $stoppedAt = $id
            $stoppedReason = 'stale chain-summary could not be removed before dispatch'
            $itemResults.Add((New-QueueItemResult -TaskId $id -State 'failed' -Reason $stoppedReason -StartedAt $now -CompletedAt $now))
            Write-QueueLog "$id 중단: $stoppedReason" ERROR
            break
        }

        $prevHeadBefore = Get-QueueHead
        $itemStartedAt = [datetime]::UtcNow
        Write-QueueLog "디스패치 시작: $id (체인)" INFO
        $dispatchExit = 0
        Push-Location $script:QueueRepoRoot
        try {
            & powershell -NoProfile -ExecutionPolicy Bypass -File $dispatcherFull -TaskId $id -Chain
            $dispatchExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $itemCompletedAt = [datetime]::UtcNow
        $prevHeadAfter = Get-QueueHead
        $prevId = $id

        $itemState = 'failed'
        $itemReason = $null
        if (-not (Test-Path -LiteralPath $chainSummaryPath)) {
            $itemReason = "dispatcher exited ($dispatchExit) without chain-summary"
        } else {
            $chainState = $null
            try { $chainState = [string](Get-Content -LiteralPath $chainSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json).state } catch { $chainState = $null }
            if ($dispatchExit -ne 0) {
                $itemReason = "dispatcher exited ($dispatchExit); chain state=$chainState"
            } elseif ($chainState -eq 'completed') {
                $itemState = 'completed'
            } elseif ([string]::IsNullOrWhiteSpace($chainState)) {
                $itemReason = 'chain-summary has no readable state'
            } else {
                $itemReason = "chain state: $chainState"
            }
        }

        $itemResults.Add((New-QueueItemResult -TaskId $id -State $itemState -Reason $itemReason -StartedAt $itemStartedAt -CompletedAt $itemCompletedAt))

        if ($itemState -ne 'completed') {
            $stoppedAt = $id
            $stoppedReason = $itemReason
            Write-QueueLog "$id 중단: $itemReason" ERROR
            break
        }
        Write-QueueLog "$id 완료 (chain state=completed)" SUCCESS
    }

    $summaryPath = Write-QueueSummary -Items $itemResults.ToArray() -StoppedAt $stoppedAt -StartedAt $startedAt
    if ($null -ne $stoppedAt) {
        Write-QueueLog "큐 중단 — stoppedAt=$stoppedAt ($stoppedReason)" ERROR
        Write-QueueLog "요약: $summaryPath" WARN
        try { [Console]::Beep() } catch { }
        $exitCode = 1
    } else {
        Write-QueueLog "큐 완료 — $($itemResults.Count)건 전부 completed. 요약: $summaryPath" SUCCESS
        $exitCode = 0
    }
} finally {
    Exit-QueueLock -Path $queueLockPath
}

exit $exitCode
