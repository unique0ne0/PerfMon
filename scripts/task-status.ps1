<#
.SYNOPSIS
    여러 프로젝트의 ACTIVE 패킷 실행 상태를 보여주는 읽기 전용 WinForms 대시보드.
#>
param(
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 5
)
# WinForms는 STA 스레드가 필요하다. 사용자가 -sta를 기억하지 않아도 되도록 재실행한다.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -IntervalSeconds {1}' -f $PSCommandPath, $IntervalSeconds
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    exit 0
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$stages = @('impl', 'qa', 'integration')
# ── 단계별 임계 정본 로드 (stage-thresholds.json) ────────────────────────────
# CFG039: dispatcher($StageConfig.HangSeconds)와 dashboard($hangThresholds)는 같은
# stage-thresholds.json을 읽는다. 파일에서 읽지 못한 단계만 안전 폴백(대시보드 기존 기본 600)을
# 채우며, 단계별 임계 자체를 하드코딩하지 않는다.
$hangThresholds = @{}
$stageThresholdsPath = Join-Path $PSScriptRoot 'stage-thresholds.json'
if (-not (Test-Path -LiteralPath $stageThresholdsPath)) {
    $stageThresholdsPath = Join-Path $root 'stage-thresholds.json'
}
$stageThresholdsRaw = $null
if (Test-Path -LiteralPath $stageThresholdsPath) {
    try { $stageThresholdsRaw = Get-Content -LiteralPath $stageThresholdsPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $stageThresholdsRaw = $null }
}
foreach ($st in $stages) {
    $t = $null
    if ($stageThresholdsRaw) { try { $t = $stageThresholdsRaw.stages.$st } catch { $t = $null } }
    if ($t -and $t.hangSeconds) { $hangThresholds[$st] = [int]$t.hangSeconds } else { $hangThresholds[$st] = 600 }
}
# 작업 ID는 하네스가 파일명·락·로그에 그대로 쓰므로 -, 공백, 밑줄 등은 동일 ID를
# 서로 다른 문자열로 쪼개 대시보드가 같은 작업을 다른 것으로 오인한다(예: CS-030 락과
# CS-030 라우터 행이 분리되어 "라우터에 행 없음" 오펀으로 중복 표시).
# 비교 전에 알파벳/숫자만 남긴 정규 형태로 맞춘다 — 표시값은 원본 그대로 유지.
# Dot-source shared harness contracts module (CFG052)
$ContractsModule = Join-Path $PSScriptRoot 'harness-contracts.ps1'
if (-not (Test-Path -LiteralPath $ContractsModule)) {
    $ContractsModule = Join-Path $root 'harness-contracts.ps1'
}
if (-not (Test-Path -LiteralPath $ContractsModule)) {
    throw "Required harness contracts module not found: $ContractsModule"
}
. $ContractsModule
function Get-HarnessProjects {
    $targetList = Join-Path $root 'harness-targets.txt'
    if (-not (Test-Path $targetList)) { return @() }
    return @(
        Get-Content $targetList |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            Where-Object { Test-Path $_ }
    )
}
# ── CFG042: 사본 classified as local exception(오버라이드)인지 판정 ─────────────────
# verify.ps1의 'Harness deploy drift' 단계와 sync-configs.ps1의 Test-HarnessDrift가 쓰는
# 엄격 조건을 그대로 옮긴다(단일 엔트리 + localOverride + 비어 있지 않은 기준 해시 + 정본/사본 존재 +
# 해시 상이). 대시보드는 읽기 전용 모니터이므로 여기 어긋나게 전시하면 운영자가 어느 쪽을 봐도
# 같은 결론을 못 낸다 — 세 곳이 항상 같은 판정을 공유해야 한다(CFG042 드리프트 행렬이 이를 강제).
function Test-HarnessOverrideState {
    param([hashtable]$OverrideLookup, [string]$Target, [string]$Asset, [string]$Master)
    $key = "$([System.IO.Path]::GetFullPath($Target))|$Asset"
    $entries = @($OverrideLookup[$key])
    if ($entries.Count -ne 1 -or $entries[0].localOverride -ne $true -or [string]::IsNullOrWhiteSpace([string]$entries[0].lastSyncedHash)) { return $false }
    $copy = Join-Path $Target "scripts\$Asset"
    return (Test-Path -LiteralPath $copy) -and ((Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash -ne $Master)
}
$harnessIoModule = $null
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $harnessIoModule = Join-Path $PSScriptRoot 'harness-io.ps1' }
if ([string]::IsNullOrWhiteSpace($harnessIoModule) -or -not (Test-Path -LiteralPath $harnessIoModule)) {
    $harnessIoModule = Join-Path (Join-Path $root 'global\harness') 'harness-io.ps1'
}
if (-not (Test-Path -LiteralPath $harnessIoModule)) { throw "Required harness I/O module not found: $harnessIoModule" }
. $harnessIoModule
# ── CFG042: 하네스 배포 동기화 요약 — 오버라이드(추적 가능한 로컬 예외)와 드리프트 분리 ──
function Get-HarnessSyncSummary {
    $masterDir = Join-Path $root 'global\harness'
    # 배포된 사본은 자기 옆(scripts\) 매니페스트를 먼저 읽는다. AST 임포트 테스트처럼 $PSScriptRoot가
    # 없는 문맥이면 그대로 중앙 정본 경로로 폴백한다 — 딱 하나의 목록을 두 소비자가 공유하게 한다.
    $manifestPath = $null
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $manifestPath = Join-Path $PSScriptRoot 'harness-assets.txt' }
    if ([string]::IsNullOrWhiteSpace($manifestPath) -or -not (Test-Path -LiteralPath $manifestPath)) { $manifestPath = Join-Path $masterDir 'harness-assets.txt' }
    try { $assets = @(Read-HarnessAssets -ManifestPath $manifestPath) }
    catch { return [pscustomobject]@{ MasterChecks = 0; Overrides = @(); Drifts = @("manifest ($($_.Exception.Message))"); Projects = @() } }
    $harnessProjects = @(Get-HarnessProjects)
    $overrideLookup = @{}
    $statePath = Join-Path $root '.agents\briefs\.harness-sync-state.json'
    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($entry in @($state.entries)) {
                $key = "$([System.IO.Path]::GetFullPath($entry.target))|$($entry.asset)"
                if (-not $overrideLookup.ContainsKey($key)) { $overrideLookup[$key] = @() }
                $overrideLookup[$key] += $entry
            }
        } catch { $overrideLookup = @{} }
    }
    $overrides = @(); $drifts = @(); $checked = 0
    foreach ($proj in $harnessProjects) {
        foreach ($asset in $assets) {
            $master = Join-Path $masterDir $asset
            $masterHash = (Get-FileHash -LiteralPath $master -Algorithm SHA256).Hash
            $copy = Join-Path $proj "scripts\$asset"
            if (-not (Test-Path -LiteralPath $copy)) { $drifts += "$proj|$asset (missing)"; continue }
            $copyHash = (Get-FileHash -LiteralPath $copy -Algorithm SHA256).Hash
            if ($copyHash -eq $masterHash) { $checked++; continue }
            if (Test-HarnessOverrideState -OverrideLookup $overrideLookup -Target $proj -Asset $asset -Master $masterHash) {
                $overrides += "$proj|$asset"
            } else {
                $drifts += "$proj|$asset"
            }
        }
    }
    return [pscustomobject]@{ MasterChecks = $checked; Overrides = @($overrides); Drifts = @($drifts); Projects = @($harnessProjects) }
}
# 라우터 표의 헤더 행이면 컬럼 이름 → 인덱스 매핑을 돌려주고, 아니면 $null.
# 작업 ID와 상태 두 칸이 모두 있어야 라우터 표로 인정한다 — 같은 파일 안의 다른 표
# (Dispatch rules의 "기본 팀 | 담당 모델 | 역할" 등)를 표로 오인하지 않기 위해서다.
function Find-RouterColumns {
    param([string[]]$Columns)
    $index = @{}
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        switch -Regex ($Columns[$i]) {
            '^(작업\s*)?ID$'  { if (-not $index.ContainsKey('Task')) { $index['Task'] = $i }; break }
            '^상태$'          { $index['Status'] = $i; break }
            '^다음\s*단계'    { $index['NextStage'] = $i; break }
            '^담당$'          { $index['Owner'] = $i; break }
            '^갱신'           { $index['Updated'] = $i; break }
        }
    }
    if ($index.ContainsKey('Task') -and $index.ContainsKey('Status') -and $index.ContainsKey('NextStage')) { return $index }
    return $null
}
# 6컬럼 방언은 담당을 별도 칸이 아니라 "다음 단계(담당)" 한 칸에 문장으로 담는다
# (예: "작업 AC007 ④ QA Review 완료 — 다음: ⑤ Final Review & Integration(기획팀/Claude)").
# 좁은 Stage 칸에 문장 전체를 넣으면 읽을 수 없으므로 "다음:" 뒤와 끝의 괄호를 분리한다.
function Split-NextStage {
    param([string]$Text)
    $stage = if ($null -eq $Text) { '' } else { $Text.Trim() }
    $owner = ''
    if ($stage -match '다음\s*:\s*(.+)$') { $stage = $Matches[1].Trim() }
    if ($stage -match '^(.*\S)\s*\(([^()]+)\)$') { $owner = $Matches[2].Trim(); $stage = $Matches[1].Trim() }
    return @{ Stage = $stage; Owner = $owner }
}
function Get-RouterTasks {
    param([string]$ProjectPath)
    $routerPath = Join-Path $ProjectPath '.agents\briefs\handoff-log.md'
    if (-not (Test-Path $routerPath)) { return @() }
    # 라우터 표는 프로젝트마다 방언이 다르다 — 제목이 '## Router'인 곳과 '## Packets'인 곳,
    # 담당을 별도 칸으로 둔 7컬럼과 '다음 단계(담당)'로 합친 6컬럼이 공존한다. 제목과 컬럼 위치를
    # 고정하면 방언 하나만 읽혀 나머지 프로젝트가 통째로 안 보인다(2026-08-09 AC-II AC007 미표시).
    # 그래서 제목은 보지 않고, 헤더 행의 컬럼 이름으로 매핑을 잡아 그 표의 행을 읽는다.
    $map = $null
    $tasks = @()
    # Router markdown is UTF-8 and may not carry a BOM. Windows PowerShell 5.1
    # otherwise decodes it with the active ANSI code page and corrupts Korean text.
    foreach ($line in Get-Content $routerPath -Encoding UTF8) {
        # 표가 아닌 줄(빈 줄·제목·산문)을 만나면 직전 표의 매핑을 버린다 — 한 파일에 표가 여러 개다.
        if ($line -notmatch '^\s*\|.+\|\s*$') { if ([string]::IsNullOrWhiteSpace($line)) { continue }; $map = $null; continue }
        $columns = @($line.Trim().Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        if ($columns[0] -match '^:?-{2,}') { continue }
        $header = Find-RouterColumns -Columns $columns
        if ($header) { $map = $header; continue }
        if (-not $map -or $columns.Count -le $map['Status']) { continue }
        $rawTaskId = $columns[$map['Task']]
        $normTaskId = Get-NormalizedTaskId -TaskId $rawTaskId
        $rawStatus = $columns[$map['Status']]
        if ([string]::IsNullOrWhiteSpace($normTaskId) -or $normTaskId -in @('NONE', 'NULL', 'NA') -or [string]::IsNullOrWhiteSpace($rawStatus) -or $rawStatus.Trim() -in @('-', '—', 'none', 'null', 'n/a')) { continue }
        if ($rawStatus -match '장기\s*보류') { $rawStatus = '장기보류' }
        $nextRaw = if ($map.ContainsKey('NextStage') -and $columns.Count -gt $map['NextStage']) { $columns[$map['NextStage']] } else { '' }
        $split = Split-NextStage -Text $nextRaw
        $owner = if ($map.ContainsKey('Owner') -and $columns.Count -gt $map['Owner']) { $columns[$map['Owner']] } else { '' }
        if ([string]::IsNullOrWhiteSpace($owner)) { $owner = $split.Owner }
        $updated = if ($map.ContainsKey('Updated') -and $columns.Count -gt $map['Updated']) { $columns[$map['Updated']] } else { '' }
        # 6컬럼 방언은 갱신일 칸이 날짜뿐이라 진행 내용이 없다. 그 정보는 '다음 단계' 칸에 있으므로
        # 날짜만 있는 경우 원문을 이어 붙여 LastActivity가 빈껍데기가 되지 않게 한다.
        if ($updated -match '^\d{4}-\d{2}-\d{2}$' -and $nextRaw) { $updated = "$updated — $nextRaw" }
        $tasks += [pscustomobject]@{
            TaskId = $columns[$map['Task']]
            Status = $columns[$map['Status']]
            NextStage = if ($split.Stage) { $split.Stage } else { '-' }
            NextStageFull = $nextRaw
            Owner = if ($owner) { $owner } else { '-' }
            UpdatedAt = $updated
        }
    }
    return $tasks
}
# 패킷의 Pipeline Status 섹션만 파싱해 단계별 체크 상태와 첫 미체크 단계를 돌려준다.
function Get-DispatchLock {
    param([string]$ProjectPath, [string]$Stage)
    $lockPath = Join-Path $ProjectPath ('.agents\briefs\logs\.dispatch-lock-' + $Stage)
    $lock = Read-HarnessLockFile -Path $lockPath
    if (-not $lock -or [string]::IsNullOrWhiteSpace($lock.Raw)) { return $null }
    return [pscustomobject]@{
        Stage = $Stage
        TaskId = $lock.TaskId
        ProcessId = $lock.ProcessId
        StartedAt = $lock.StartedAt
        Alive = $lock.Alive
    }
}
# 디스패처가 실패로 중단될 때 남기는 마커(dispatch-with-hang-detect.ps1의 Write-FailureMarker).
# 락은 finally에서 지워지므로 이 마커가 없으면 "실패로 멈춤"과 "아직 시작 안 함"이 구분되지 않는다.
# 포맷: TaskId|Stage|실패시각|사유|작업트리더러움(1/0)
function Get-DispatchFailures {
    param([string]$ProjectPath, [string]$Stage)
    $logDir = Join-Path $ProjectPath '.agents\briefs\logs'
    if (-not (Test-Path $logDir)) { return @() }
    $markers = @(Get-ChildItem -Path $logDir -Filter ('.dispatch-failed-*-' + $Stage) -File -ErrorAction SilentlyContinue)
    # Legacy stage-scoped markers remain readable until their owning task is retried.
    $legacy = Join-Path $logDir ('.dispatch-failed-' + $Stage)
    if (Test-Path $legacy) { $markers += Get-Item $legacy }
    $failures = @()
    foreach ($markerPath in $markers) {
        $raw = (Get-Content $markerPath.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $parts = @($raw.Trim() -split '\|')
        if ($parts.Count -lt 4) { continue }
        $failures += [pscustomobject]@{
            TaskId = $parts[0]
            Stage = $parts[1]
            FailedAt = $parts[2]
            Reason = $parts[3]
            Dirty = ($parts.Count -ge 5 -and $parts[4] -eq '1')
        }
    }
    return $failures
}
# 락 경합은 실패가 아니라 대기 후 재시도할 상태다. 마커 포맷은 6칸으로 고정된다.
function Get-DispatchBlocked {
    param([string]$ProjectPath, [string]$Stage)
    $logDir = Join-Path $ProjectPath '.agents\briefs\logs'
    if (-not (Test-Path $logDir)) { return @() }
    $blocked = @()
    foreach ($markerPath in @(Get-ChildItem -Path $logDir -Filter ('.dispatch-blocked-*-' + $Stage) -File -ErrorAction SilentlyContinue)) {
        $raw = Get-Content $markerPath.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $parts = @($raw.Trim() -split '\|')
        if ($parts.Count -ne 6) { continue }
        $blocked += [pscustomobject]@{
            TaskId = $parts[0]; Stage = $parts[1]; BlockedAt = $parts[2]
            Reason = $parts[3]; OwnerTaskId = $parts[4]; OwnerProcessId = $parts[5]
        }
    }
    return $blocked
}
# CFG017: 승인 대기 기록 — dispatcher가 남기는 <TaskId>-<stage>-approval.json 중 status='pending'만 읽는다.
# 실패 마커와 달리 "재시도 가능한 실패"가 아니라 "명시적 승인이 필요한 종결 상태"다. 기록은 fresh cycle
# 성공 시 resolved로 바뀔 뿐 삭제되지 않으므로, 감사 이력은 여기서 판정하지 않고 상태 반영만 한다.
function Get-DispatchApprovals {
    param([string]$ProjectPath)
    $logDir = Join-Path $ProjectPath '.agents\briefs\logs'
    if (-not (Test-Path $logDir)) { return @() }
    $approvals = @()
    foreach ($recordFile in @(Get-ChildItem -Path $logDir -Filter '*-approval.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $record = Get-Content $recordFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { continue }
        if ($null -eq $record -or $record.status -ne 'pending' -or -not $record.approval_required) { continue }
        $created = [string]$record.timestamp
        try { $created = ([datetime]$record.timestamp).ToLocalTime().ToString('yyyy-MM-dd HH:mm') } catch { }
        $approvals += [pscustomobject]@{
            TaskId = [string]$record.taskId
            Stage = [string]$record.stage
            Cycle = $record.cycle
            CreatedAt = $created
            Target = if ($record.target) { [string]$record.target } elseif ($record.targetExtractionReason) { "target null: $($record.targetExtractionReason)" } else { 'target null: extraction reason unavailable' }
            ConversationId = [string]$record.conversationId
            StepId = [string]$record.stepId
            RawError = [string]$record.rawError
            RecordPath = $recordFile.FullName
        }
    }
    return $approvals
}
# 디스패처는 기동~첫 락 획득 사이, 그리고 단계와 단계 사이(Start-Sleep 2초 + 다음 락 획득)에
# 아무 락도 들지 않는다. verify 게이트는 락 안에서 도니까 이 공백 자체는 길지 않지만(수 초),
# 그 순간 화면은 "아무도 안 몰고 있음"과 글자 하나 다르지 않은 IDLE이 된다. 락이 없다는 사실과
# 디스패처가 없다는 사실은 다른 말이므로 프로세스 표를 직접 보고 STANDBY(체인대기)로 분리한다.
# 프로젝트 단위로 나누지 않는다 — 디스패처는 `-File scripts\dispatch-with-hang-detect.ps1`을
# 상대경로로 받아 명령줄에 프로젝트 경로가 남지 않는다. 작업 ID는 라우터마다 고유 프리픽스를
# 쓰는 것이 규칙(agent-handoff-protocol)이라 ID만으로 사실상 유일하므로 ID로 매칭한다.
function Get-ChainDispatchers {
    $dispatchers = @{}
    $processes = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        if (-not $process.CommandLine) { continue }
        if ($process.CommandLine -notmatch 'dispatch-with-hang-detect\.ps1') { continue }
        if ($process.CommandLine -notmatch '-TaskId\s+["'']?([A-Za-z0-9_-]+)') { continue }
        $normalized = Get-NormalizedTaskId -TaskId $Matches[1]
        if ($dispatchers.ContainsKey($normalized)) { continue }
        $dispatchers[$normalized] = [pscustomobject]@{
            ProcessId = $process.ProcessId
            StartedAt = $process.CreationDate
        }
    }
    return $dispatchers
}
function Format-Elapsed {
    param([datetime]$StartedAt)
    if ($null -eq $StartedAt -or $StartedAt -eq [datetime]::MinValue) { return '-' }
    $elapsed = (Get-Date) - $StartedAt
    if ($elapsed.TotalSeconds -lt 0) { return '00:00:00' }
    return ('{0:00}:{1:00}:{2:00}' -f [math]::Floor($elapsed.TotalHours), $elapsed.Minutes, $elapsed.Seconds)
}
# 라우터 갱신일 칸은 "2026-08-09 — 작업 CS-024 ① 기획 완료 — 다음: ② 구현(개발1팀)" 형태다.
# 작업 ID는 Task 칸, "다음: <단계>(<담당>)"은 Stage·Owner 칸이 이미 보여주므로 표에서는 잘라낸다 —
# 남는 폭을 실제로 새로운 정보(무슨 단계가 언제 끝났는지)에 쓰기 위해서다. 원문은 셀 툴팁에 남긴다.
function Compress-RouterActivity {
    param([string]$Text, [string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $Text }
    $trimmed = $Text -replace '\s*[—\-]\s*다음\s*:.*$', ''
    $trimmed = $trimmed -replace ('\s*작업\s+' + [regex]::Escape($TaskId) + '\s*'), ' '
    return $trimmed.Trim()
}
function Get-StageStateLease {
    param([string]$ProjectPath, [string]$TaskId)
    $norm = Get-NormalizedTaskId -TaskId $TaskId
    $path = Join-Path $ProjectPath ('.agents\briefs\logs\' + $TaskId + '-stage-state.json')
    if (-not (Test-Path -LiteralPath $path) -and $norm) {
        $path = Join-Path $ProjectPath ('.agents\briefs\logs\' + $norm + '-stage-state.json')
    }
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try { $lease = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
    if ((Get-NormalizedTaskId -TaskId $lease.taskId) -ne $norm -or [string]::IsNullOrWhiteSpace([string]$lease.stage) -or [string]::IsNullOrWhiteSpace([string]$lease.heartbeatAt)) { return $null }
    try { $heartbeat = ([datetime]$lease.heartbeatAt).ToUniversalTime() } catch { return $null }
    [datetime]$startedAt = [datetime]::MinValue
    $parsedStartedAt = $null
    if ($lease.startedAt -and [datetime]::TryParse([string]$lease.startedAt, [ref]$startedAt)) {
        $parsedStartedAt = $startedAt.ToLocalTime()
    }
    $limit = if ($hangThresholds -and $hangThresholds[[string]$lease.stage]) { [int]$hangThresholds[[string]$lease.stage] } else { 600 }
    return [pscustomobject]@{ Lease = $lease; Fresh = (([datetime]::UtcNow - $heartbeat).TotalSeconds -lt $limit); Heartbeat = $heartbeat; StartedAt = $parsedStartedAt }
}
# CFG043: 만료된 'running'/'starting' lease가 가리키는 단계가 패킷 Pipeline Status에서 이미 완료됐는지
# 판정한다. 수동 완료/대체로 파이프라인이 그 단계를 실제로 마쳤다면 stale lease는 "정지"가 아니라
# "재개 필요"의 신호다(Done When 2 — 패킷 ②③이 완료된 경우 '정지 감지' 대신 '재개 필요'를 표시).
function Test-LeaseStageCompleteInPacket {
    param([string]$ProjectPath, [string]$TaskId, $Lease)
    $stage = [string]$Lease.Lease.stage
    if ($stage -eq 'unknown' -or @('impl','qa','integration') -notcontains $stage) { return $false }
    $indexes = switch ($stage) {
        'impl' { @(2, 3) }
        'qa' { @(4) }
        'integration' { @(5) }
        default { @() }
    }
    foreach ($dir in @((Join-Path $ProjectPath '.agents\briefs\packets'), (Join-Path $ProjectPath '.agents\briefs\archive'))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        $pk = @(Get-ChildItem -Path $dir -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue)
        if ($pk.Count -ne 1) { continue }
        $ps = Get-PacketPipelineStatus -PacketPath $pk[0].FullName
        if (-not $ps.HasPipelineStatus -or $ps.Items.Count -eq 0) { continue }
        $allChecked = $true
        foreach ($i in $indexes) {
            $item = @($ps.Items | Where-Object { $_.Index -eq $i })
            if ($item.Count -eq 0 -or -not $item[0].Checked) { $allChecked = $false; break }
        }
        if ($allChecked) { return $true }
    }
    return $false
}
# Stage/Owner are presentation contracts, not a copy of stale router prose.  Normal
# pipeline work always keeps its circled step; exceptional states deliberately replace
# it with an unnumbered explanation so the grid does not imply that a stage is healthy.
function Format-DashboardStage {
    param([string]$Stage, [string]$Status, [string]$Fallback)
    $exception = @{
        HANG = '무응답 의심'; APPROVAL_REQUIRED = '승인 대기'; FAILED = '실패 중단'
        STALE = '죽은 락 잔존'; STANDBY = '체인 전환'; BLOCKED = '락 대기'
        RESUME = '재개 필요'
    }
    if ($exception.ContainsKey($Status)) { return $exception[$Status] }
    if ($Status -eq '장기보류' -or $Stage -match '장기\s*보류') { return '-' }
    switch ($Stage.ToLowerInvariant()) {
        'impl' { if ($Fallback -match '③') { return '③ 자체 리뷰' }; return '② 구현' }
        'qa' { return '④ QA 리뷰' }
        'integration' { return '⑤ 최종 리뷰 및 Integration' }
        default {
            if ($Fallback -match '[①②③④⑤]') { return $Fallback }
            return $Stage
        }
    }
}
function Get-StageRuntimeIdentity {
    param([string]$ProjectPath, [string]$TaskId, [string]$Stage, [string]$RouterOwner, [string]$LeaseModel)
    $defaultTeam = @{ impl = '개발1팀'; qa = 'QA팀'; integration = '기획팀' }[$Stage]
    # 단계의 "기본" 담당팀(쿼터 정상일 때의 팀 배정)과, 그 단계를 실제로 실행한 CLI가 평소
    # 소속되는 팀은 다를 수 있다 — 쿼터 소진 등으로 다른 팀이 대행하는 경우다(예: CFG012/CFG013
    # 처럼 기획팀/Claude가 멈춰 QA팀/Codex가 Integration을 대행). 이때 로그에서 읽은 어댑터를
    # 여전히 단계 기본팀 이름에 붙이면 "기획팀 / Codex CLI"처럼 실제로 존재하지 않는 조합이
    # 표시된다. 어댑터가 평소 어느 팀 소속인지 알고 있으면 그 팀 이름을 쓰고, 기본팀과 다르면
    # "대행"을 붙여 조정 사실 자체를 화면에서 알 수 있게 한다.
    $teamByAdapter = @{ opencode = '개발1팀'; codex = 'QA팀'; claude = '기획팀'; gemini = '개발2팀' }
    if (-not $defaultTeam) { return [pscustomobject]@{ Owner = $RouterOwner; Model = '-' } }
    # The dispatcher emits its routing line near the start of the host log.  A binding
    # warning may precede it, so inspect the short header rather than assuming line one.
    # Use this evidence instead of a historical router label such as "기획팀/Claude".
    $logs = Join-Path $ProjectPath '.agents\briefs\logs'
    $routeLine = @(Get-ChildItem -LiteralPath $logs -Filter "$TaskId-*-host.out.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | ForEach-Object {
            Get-Content -LiteralPath $_.FullName -TotalCount 12 -ErrorAction SilentlyContinue |
                Where-Object { $_ -match ("\b" + [regex]::Escape($Stage) + '=') } |
                Select-Object -First 1
        } |
        Where-Object { $_ -match ("\b" + [regex]::Escape($Stage) + '=') } | Select-Object -First 1)
    if ($routeLine.Count -gt 0 -and $routeLine[0] -match (([regex]::Escape($Stage)) + '=([^/\s]+)/([^\s]+)')) {
        $adapter = $Matches[1].ToLowerInvariant(); $model = $Matches[2]
        $cli = @{ antigravity = 'Antigravity CLI'; codex = 'Codex CLI'; claude = 'Claude CLI'; gemini = 'Gemini CLI'; opencode = 'OpenCode CLI' }[$adapter]
        if ($cli) {
            # antigravity는 여러 팀이 공용으로 쓰는 실행 레이어라 소속팀이 고정되지 않는다 — 그런
            # 어댑터는 대행 여부를 판정할 근거가 없으므로 단계 기본팀 이름을 그대로 쓴다.
            $actualTeam = if ($teamByAdapter.ContainsKey($adapter)) { $teamByAdapter[$adapter] } else { $defaultTeam }
            $owner = if ($actualTeam -ne $defaultTeam) { "$actualTeam 대행($defaultTeam) / $cli" } else { "$actualTeam / $cli" }
            return [pscustomobject]@{ Owner = $owner; Model = if ($LeaseModel) { $LeaseModel } else { $model } }
        }
    }
    return [pscustomobject]@{ Owner = $RouterOwner; Model = if ($LeaseModel) { $LeaseModel } else { '-' } }
}
# .agents/briefs/backlog.md 파서. 이 저장소에 한정된 로컬 파일이라 멀티 프로젝트 순회 불필요.
# 표 행은 '| ID | 내용 | 심각도 | 최초 발견 | 상태 |' 단일 라인 형태. 내용 셀에 '|'가
# 들어가는 행이 있다(CFG-BL-012·CFG-BL-031이 실측 예) — 그래서 끝 4셀을 메타데이터로 보고
# 그 앞 전체를 내용으로 합친다. 헤더/푸터는 '|'로 시작하지 않거나 ID 패턴이 없어서 자연 스킵.
function Get-BacklogTasks {
    param([string]$ProjectPath)
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { return @() }
    $path = Join-Path $ProjectPath '.agents\briefs\backlog.md'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $items = @()
    foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
        if ($line -notmatch '^\|\s*(CFG-BL-\d+)\s*\|') { continue }
        $parts = $line.Trim() -split '\|'
        # [0]/[-1]은 선두/말미 빈 셀. 끝 4셀이 [심각도, 최초발견, 상태, 빈]이다.
        # 끝에서 5번째(=cells[-5])부터 두번째 셀(=cells[2])까지 전부 내용 셀로 본다.
        if ($parts.Count -lt 7) { continue }
        $contentCells = if ($parts.Count -gt 7) { $parts[2..($parts.Count - 5)] } else { @($parts[2]) }
        $items += [pscustomobject]@{
            Id = $parts[1].Trim()
            Content = ($contentCells -join '|').Trim()
            Severity = $parts[-4].Trim()
            FirstFound = $parts[-3].Trim()
            StatusText = $parts[-2].Trim()
        }
    }
    return $items
}
# 미해결 백로그 판정. '상태' 칸은 자유 텍스트라 완벽한 파싱은 불가능하지만 이 파일의 작성 관행
# (append-only 서술, '해결/해소 완료' 또는 단순 '해결 (날짜)'이 최종 확정 문구)을 이용해 최선 근사치를 낸다.
# 불확실하면 OPEN 쪽으로 기운다 — 조용한 누락보다 과다 노출이 이 하네스 전반의 안전 방향.
# '미착수/잔여/남은/보류/판단 대기/아직/재오픈' 같은 꼬리표가 마지막 종료 마커 뒤에 붙어
# 있으면 부분 해결 상태로 보고 다시 OPEN으로 본다(예: CFG-BL-030 '1단계 해결 완료... 남은 과제 아직 미착수').
# 첫머리의 '대기 —'처럼 추후 종료 마커로 대체된 케이스는 마지막 종료 마커 기준으로 판정한다.
# '승격'(다른 작업 ID로 이관)·'폐기'(재논의 전까지 재등록 안 함)도 실질적 종결 마커로 인정한다
# (CFG-BL-033 발견 — '해결'이라는 단어를 쓰지 않고 승격/폐기로만 마무리되는 경우가 흔함).
# 단, 마지막 마커가 '부분 승격'이면 잔여분이 아직 처리되지 않았다는 뜻이므로 그 자체로 OPEN 유지.
function Test-BacklogItemOpen {
    param([string]$StatusText)
    if ([string]::IsNullOrWhiteSpace($StatusText)) { return $true }
    # 마지막 종료 마커를 찾는다 — '해결/해소 완료', '**해결 (', '승격', '폐기'.
    $matches = [regex]::Matches($StatusText, '((해결|해소)\s*완료|\*\*해결\s*\(|승격|폐기)')
    if ($matches.Count -eq 0) { return $true }
    $last = $matches[$matches.Count - 1]
    $trailing = $StatusText.Substring($last.Index + $last.Length)
    if ($trailing -match '(미착수|잔여|남은|보류|판단\s*대기|아직|재오픈)') { return $true }
    $prefixStart = [Math]::Max(0, $last.Index - 6)
    $prefixWindow = $StatusText.Substring($prefixStart, $last.Index - $prefixStart)
    if ($prefixWindow -match '부분\s*$') { return $true }
    return $false
}
function Get-DashboardStageKey {
    param([string]$Stage)
    if ([string]::IsNullOrWhiteSpace($Stage)) { return '' }
    switch -Regex ($Stage) {
        '^[②③]|\bimpl\b|구현|자체.*리뷰' { return 'impl' }
        '^[④]|\bqa\b|QA.*리뷰' { return 'qa' }
        '^[⑤]|\bintegration\b|최종.*리뷰|통합' { return 'integration' }
        default { return '' }
    }
}
function Get-RawTaskStates {
    param([switch]$ShowAll)
    $rawItems = @()
    # state lease는 대시보드의 우선 상태 원천이다. 먼저 라우터 작업별 lease를 읽고,
    # 그 다음에만 보조 증거인 프로세스·락·마커를 스캔한다.
    $dispatchers = $null
    foreach ($projectPath in Get-HarnessProjects) {
        $routerTasks = @(Get-RouterTasks -ProjectPath $projectPath)
        $nonClosedTasks = @($routerTasks | Where-Object { $_.Status -ne 'DONE' -and $_.Status -ne '폐기' })
        $leases = @{}
        foreach ($task in $nonClosedTasks) {
            $leases[(Get-NormalizedTaskId -TaskId $task.TaskId)] = Get-StageStateLease -ProjectPath $projectPath -TaskId $task.TaskId
        }
        if ($ShowAll) {
            $tasks = $nonClosedTasks
        } else {
            $tasks = @($nonClosedTasks | Where-Object { $_.Status -eq 'ACTIVE' })
            # ACTIVE만은 정상적인 다음 단계 대기는 숨기되, 만료된 시작/실행 lease는 라우터가 WAITING이어도
            # 조치가 필요한 실제 정지 증거다. 이 경우를 숨기면 CFG021처럼 사용자가 멈춘 작업을 알 수 없다.
            foreach ($task in @($nonClosedTasks | Where-Object { $_.Status -ne 'ACTIVE' })) {
                $lease = $leases[(Get-NormalizedTaskId -TaskId $task.TaskId)]
                if ($lease -and -not $lease.Fresh -and ([string]$lease.Lease.state -match '^(starting|running)$')) {
                    $tasks += $task
                }
            }
        }
        # 프로세스 표 조회는 프로젝트 수와 무관하므로 갱신마다 한 번만 돈되, lease 이후에만 수행한다.
        if ($null -eq $dispatchers) { $dispatchers = Get-ChainDispatchers }
        $locks = @{}
        $failures = @{}
        $blockedMarkers = @{}
        $approvals = @()
        $scanStages = if ($stages -and $stages.Count -gt 0) { $stages } else { @('impl', 'qa', 'integration') }
        foreach ($stage in $scanStages) {
            $lock = Get-DispatchLock -ProjectPath $projectPath -Stage $stage
            if ($lock) { $locks[$lock.TaskId] = $lock }
            foreach ($failure in @(Get-DispatchFailures -ProjectPath $projectPath -Stage $stage)) {
                if ($failure) { $failures[$failure.TaskId] = $failure }
            }
            foreach ($blocked in @(Get-DispatchBlocked -ProjectPath $projectPath -Stage $stage)) {
                if ($blocked) { $blockedMarkers[$blocked.TaskId] = $blocked }
            }
        }
        $approvals = @(Get-DispatchApprovals -ProjectPath $projectPath)
        # 라우터 행보다 실행 사실이 우선한다. 락이 살아 있는데 라우터에 ACTIVE 행이 없으면
        # (예: Integration 후 WAITING→ACTIVE 전환 누락) 그 작업이 통째로 화면에서 사라져
        # 대시보드가 존재 이유를 잃는다 — 2026-08-09 CS-025가 실제로 돌면서 안 보였다.
        # 실패 마커는 다르다. 마커는 그 단계를 성공적으로 재실행할 때만 지워지므로, 다른 경로로
        # 해소되고 작업이 끝나면 영구히 남는다. 이미 판이 끝난 작업(DONE)이거나 착수 자체가 금지된
        # 작업(장기보류·폐기)의 마커는 실패가 아니라 잔여물이라 표시하지 않는다 — 특히 장기보류는
        # 디스패치 대상에서 제외된 상태라 실행 목록에 되살아나면 안 된다.
        # 그 외 상태(WAITING 등)는 아직 해소 전이므로 표시한다.
        $closedStatuses = @('DONE', '장기보류', '폐기')
        $statusById = @{}
        foreach ($routerTask in $routerTasks) {
            $norm = Get-NormalizedTaskId -TaskId $routerTask.TaskId
            if (-not $statusById.ContainsKey($norm)) { $statusById[$norm] = $routerTask.Status }
        }
        $known = @($tasks | ForEach-Object { Get-NormalizedTaskId -TaskId $_.TaskId })
        foreach ($orphanId in @(@($locks.Keys) + @($failures.Keys) + @($blockedMarkers.Keys) + @($approvals | ForEach-Object { $_.TaskId }))) {
            $orphanNorm = Get-NormalizedTaskId -TaskId $orphanId
            if ([string]::IsNullOrWhiteSpace($orphanNorm) -or $orphanNorm -in @('NONE', 'NULL', 'NA')) { continue }
            if ($known -contains $orphanNorm) { continue }
            $routerStatus = $statusById[$orphanNorm]
            $isClosed = $routerStatus -and ($closedStatuses -contains $routerStatus)
            # 승인 대기는 실패와 달리 사용자가 풀어야 하는 종결 상태라, 라우터가 DONE이라고 해도
            # (예: 상태 갱신 누락) 숨기지 않는다 — 풀리지 않은 승인은 감사상 놓치면 안 된다.
            $hasPendingApproval = @($approvals | Where-Object { (Get-NormalizedTaskId -TaskId $_.TaskId) -eq $orphanNorm }).Count -gt 0
            if (-not $locks.ContainsKey($orphanId) -and -not $hasPendingApproval -and $isClosed) { continue }
            # archive/ 에 통합 완료 패킷이 있는 고아는 라우터 DONE과 동급으로 제외한다. 라우터에서
            # 빠진 뒤 packets/ 가 비고 archive/ 로 이동했음에도 residual 마커로 대시보드에
            # ○ 기동대기로 다시 살아나던 회귀(CFG018~023 — 2026-08-23 실측)를 닫는다.
            # 단, 라이브 락이나 pending 승인이 있으면 의도적 재실행 가능성이 있어 그대로 둔다.
            if (-not $locks.ContainsKey($orphanId) -and -not $hasPendingApproval) {
                $archiveComplete = $false
                foreach ($dir in @(
                    (Join-Path $projectPath '.agents\briefs\packets'),
                    (Join-Path $projectPath '.agents\briefs\archive')
                )) {
                    if (-not (Test-Path -LiteralPath $dir)) { continue }
                    $matched = @(Get-ChildItem -Path $dir -Filter "$($orphanId)-*.md" -File -ErrorAction SilentlyContinue)
                    if ($matched.Count -ne 1) { continue }
                    $archivePs = Get-PacketPipelineStatus -PacketPath $matched[0].FullName
                    if ($archivePs.HasPipelineStatus -and $archivePs.Items.Count -gt 0) {
                        $allChecked = $true
                        foreach ($it in $archivePs.Items) {
                            if (-not $it.Checked) { $allChecked = $false; break }
                        }
                        if ($allChecked) { $archiveComplete = $true; break }
                    }
                }
                if ($archiveComplete) { continue }
            }
            # 락이 살아 있으면 상태와 무관하게 보여준다 — 실행 중인 프로세스를 숨기는 것이 더 위험하고,
            # 장기보류·DONE 패킷에서 도는 디스패치는 그 자체가 규칙 위반이라 오히려 눈에 띄어야 한다.
            # 대신 라우터가 뭐라고 말하는지를 활동 칸에 적어 정상 진행과 구분되게 한다.
            $note = if ($routerStatus) { "⚠ 라우터 상태 $routerStatus — ACTIVE 아님" } else { '⚠ 라우터에 행 없음' }
            $known += $orphanNorm
            $tasks += [pscustomobject]@{
                TaskId = $orphanId
                Status = 'ACTIVE'
                NextStage = '-'
                NextStageFull = ''
                Owner = '-'
                UpdatedAt = $note
            }
        }
        if ($tasks.Count -eq 0) { continue }
        foreach ($task in $tasks) {
            $taskNorm = Get-NormalizedTaskId -TaskId $task.TaskId
            $lock = $null
            foreach ($k in $locks.Keys) {
                if ((Get-NormalizedTaskId -TaskId $k) -eq $taskNorm) { $lock = $locks[$k]; break }
            }
            $failure = $null
            foreach ($k in $failures.Keys) {
                if ((Get-NormalizedTaskId -TaskId $k) -eq $taskNorm) { $failure = $failures[$k]; break }
            }
            $blocked = $null
            foreach ($k in $blockedMarkers.Keys) {
                if ((Get-NormalizedTaskId -TaskId $k) -eq $taskNorm) { $blocked = $blockedMarkers[$k]; break }
            }
            # 여러 cycle의 pending 기록은 모두 보존·수집한다. 표에는 가장 최근 cycle을 요약하되
            # 툴팁에 전체 record path/target을 남겨 어떤 승인도 화면에서 사라지지 않게 한다.
            $taskApprovals = @($approvals | Where-Object { (Get-NormalizedTaskId -TaskId $_.TaskId) -eq $taskNorm } | Sort-Object @{ Expression = { [int]$_.Cycle }; Descending = $true })
            $approval = if ($taskApprovals.Count -gt 0) { $taskApprovals[0] } else { $null }
            $lease = $leases[$taskNorm]
            # 파이프라인이 재개되거나 단계가 완료된 경우 과거의 실패/차단 마커는 무효(stale)로 판정한다.
            if ($failure -or $blocked) {
                # 통합 단계가 끝난 패킷은 packets/ 가 비고 archive/ 에 있다. 라우터에서
                # 이미 제거된(DONE) 과거 작업의 잔여 실패 마커가 archive 의 Pipeline Status 만으로
                # stale 판정되도록 두 디렉터리를 함께 본다(CFG018~023이 FAILED로 오표시되던 회귀).
                $packetSearchDirs = @(
                    (Join-Path $projectPath '.agents\briefs\packets'),
                    (Join-Path $projectPath '.agents\briefs\archive')
                )
                $packetFiles = @()
                foreach ($dir in $packetSearchDirs) {
                    if (Test-Path -LiteralPath $dir) {
                        $packetFiles += @(Get-ChildItem -Path $dir -Filter "$($task.TaskId)-*.md" -File -ErrorAction SilentlyContinue)
                    }
                }
                if ($packetFiles.Count -eq 1) {
                    $packetStatus = Get-PacketPipelineStatus -PacketPath $packetFiles[0].FullName
                    if ($packetStatus.HasPipelineStatus -and $packetStatus.Items.Count -gt 0) {
                        if ($failure) {
                            $stageIndexes = switch ($failure.Stage) {
                                'impl' { @(2, 3) }
                                'qa' { @(4) }
                                'integration' { @(5) }
                                default { @() }
                            }
                            $allChecked = $true
                            foreach ($idx in $stageIndexes) {
                                $item = @($packetStatus.Items | Where-Object { $_.Index -eq $idx })
                                if ($item.Count -eq 0 -or -not $item[0].Checked) { $allChecked = $false; break }
                            }
                            if ($allChecked -or ($null -ne $packetStatus.FirstUnchecked -and -not ($stageIndexes -contains $packetStatus.FirstUnchecked.Index))) {
                                $failure = $null
                            }
                        }
                        if ($blocked) {
                            $stageIndexes = switch ($blocked.Stage) {
                                'impl' { @(2, 3) }
                                'qa' { @(4) }
                                'integration' { @(5) }
                                default { @() }
                            }
                            $allChecked = $true
                            foreach ($idx in $stageIndexes) {
                                $item = @($packetStatus.Items | Where-Object { $_.Index -eq $idx })
                                if ($item.Count -eq 0 -or -not $item[0].Checked) { $allChecked = $false; break }
                            }
                            if ($allChecked -or ($null -ne $packetStatus.FirstUnchecked -and -not ($stageIndexes -contains $packetStatus.FirstUnchecked.Index))) {
                                $blocked = $null
                            }
                        }
                    }
                } elseif ($task.NextStage) {
                    $routerStage = switch -Regex ($task.NextStage) {
                        '[②③]|impl|구현|리뷰' { 'impl' }
                        '[④]|qa|QA'         { 'qa' }
                        '[⑤]|integration|통합|Final' { 'integration' }
                        default             { '' }
                    }
                    if ($routerStage) {
                        if ($failure -and $routerStage -ne $failure.Stage) { $failure = $null }
                        if ($blocked -and $routerStage -ne $blocked.Stage) { $blocked = $null }
                    }
                }
            }
            $isLeaseComplete = $false
            if ($lease -and -not $lease.Fresh -and ([string]$lease.Lease.state -match '^(starting|running)$')) {
                $isLeaseComplete = Test-LeaseStageCompleteInPacket -ProjectPath $projectPath -TaskId $task.TaskId -Lease $lease
            }
            $rawItems += [pscustomobject]@{
                ProjectPath = $projectPath
                Task = $task
                TaskNorm = $taskNorm
                Lease = $lease
                Lock = $lock
                Failure = $failure
                Blocked = $blocked
                Approval = $approval
                TaskApprovals = $taskApprovals
                IsLeaseStageComplete = $isLeaseComplete
                Dispatcher = if ($dispatchers -and $dispatchers.ContainsKey($taskNorm)) { $dispatchers[$taskNorm] } else { $null }
            }
        }
    }
    $backlogItems = @()
    if ($ShowAll) {
        $backlogHost = $null
        foreach ($p in @(Get-HarnessProjects)) {
            if (Test-Path -LiteralPath (Join-Path $p '.agents\briefs\backlog.md')) { $backlogHost = $p; break }
        }
        if (-not $backlogHost) {
            if (Test-Path -LiteralPath (Join-Path $root '.agents\briefs\backlog.md')) { $backlogHost = $root }
        }
        if ($backlogHost) {
            foreach ($bl in @(Get-BacklogTasks -ProjectPath $backlogHost)) {
                if (Test-BacklogItemOpen -StatusText $bl.StatusText) {
                    $backlogItems += [pscustomobject]@{
                        HostPath = $backlogHost
                        Item = $bl
                    }
                }
            }
        }
    }
    return [pscustomobject]@{
        RawItems = $rawItems
        BacklogItems = $backlogItems
    }
}
function Reduce-TaskState {
    param([pscustomobject]$RawItem)
    $task = $RawItem.Task
    $taskNorm = $RawItem.TaskNorm
    $lease = $RawItem.Lease
    $lock = $RawItem.Lock
    $failure = $RawItem.Failure
    $blocked = $RawItem.Blocked
    $approval = $RawItem.Approval
    $taskApprovals = $RawItem.TaskApprovals
    $isLeaseStageComplete = $RawItem.IsLeaseStageComplete
    $dispatcher = $RawItem.Dispatcher
    $status = 'IDLE'
    $stage = $task.NextStage
    $processId = '-'
    $elapsed = '-'
    $lastActivityFull = $task.UpdatedAt
    $lastActivity = Compress-RouterActivity -Text $task.UpdatedAt -TaskId $task.TaskId
    # 우선순위: fresh running lease > approval/failure/blocked 마커 > lease 종결 상태 >
    # expired lease(STALLED) > live lock > stale lock > chain transition > IDLE.
    if ($lease -and $lease.Fresh -and ([string]$lease.Lease.state -match '^(starting|running)$')) {
        $stage = if ($lease.Lease.stage -eq 'unknown') { $task.NextStage } else { $lease.Lease.stage.ToUpperInvariant() }
        $processId = if ($lease.Lease.pid) { $lease.Lease.pid } else { '-' }
        $status = 'RUNNING'
        if ($processId -ne '-' -and $processId -match '^\d+$') {
            try {
                $p = Get-Process -Id ([int]$processId) -ErrorAction SilentlyContinue
                if ($p -and $p.StartTime) { $elapsed = Format-Elapsed -StartedAt $p.StartTime }
            } catch { }
        }
        if ($elapsed -eq '-' -and $lease.StartedAt) {
            $elapsed = Format-Elapsed -StartedAt $lease.StartedAt
        } elseif ($elapsed -eq '-' -and $lock -and $lock.StartedAt) {
            $elapsed = Format-Elapsed -StartedAt $lock.StartedAt
        }
        $lastActivity = $lease.Heartbeat.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' · ' + $lease.Lease.state
        $lastActivityFull = $lastActivity
    } elseif ($approval) {
        $status = 'APPROVAL_REQUIRED'
        $stage = $approval.Stage.ToUpperInvariant()
        $lastActivity = "$($approval.CreatedAt) · 승인 대기 (pending $($taskApprovals.Count), 최신 cycle $($approval.Cycle)) — $($approval.Target)"
        $lastActivityFull = (@($taskApprovals | ForEach-Object { "승인 기록: $($_.RecordPath)`ncycle $($_.Cycle) · target: $($_.Target)`nconversation: $($_.ConversationId) · step: $($_.StepId)`n원시 오류: $($_.RawError)" }) -join "`n`n")
    } elseif ($failure) {
        $status = 'FAILED'
        $stage = $failure.Stage.ToUpperInvariant()
        $dirtyNote = if ($failure.Dirty) { ' · 작업트리 더러움' } else { '' }
        $lastActivity = $failure.FailedAt + ' · ' + $failure.Reason + $dirtyNote
        $lastActivityFull = $lastActivity
    } elseif ($lease) {
        # 만료된 lease이거나 종결 상태를 담은 lease다. 종결 lease는 마커 없이도 자기 상태를 말한다.
        $leaseState = [string]$lease.Lease.state
        $leaseStage = if ($lease.Lease.stage -eq 'unknown') { $task.NextStage } else { $lease.Lease.stage.ToUpperInvariant() }
        $leasePid = if ($lease.Lease.pid) { $lease.Lease.pid } else { '-' }
        if ($leaseState -eq 'completed') {
            $status = 'READY'
            $stage = $task.NextStage
            $lastActivity = '단계 완료 · 다음 단계 대기'
            $lastActivityFull = $lastActivity
        } elseif ($leaseState -eq 'failed') {
            $status = 'FAILED'
            $stage = $leaseStage
            $lastActivity = $lease.Heartbeat.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' · 실패: ' + [string]$lease.Lease.reason
            $lastActivityFull = $lastActivity
        } elseif ($leaseState -eq 'blocked') {
            $status = 'BLOCKED'
            $stage = $leaseStage
            $lastActivity = $lease.Heartbeat.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' · 락 대기: ' + [string]$lease.Lease.reason
            $lastActivityFull = $lastActivity
        } elseif ($leaseState -eq 'approval_required') {
            $status = 'APPROVAL_REQUIRED'
            $stage = $leaseStage
            $lastActivity = $lease.Heartbeat.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' · 승인 대기: ' + [string]$lease.Lease.reason
            $lastActivityFull = $lastActivity
        } elseif ($lease.Fresh) {
            $status = 'STALLED'
            $stage = $leaseStage
            $processId = $leasePid
            $lastActivity = $lease.Heartbeat.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' · state lease 상태 판정 불가'
            $lastActivityFull = $lastActivity
        } else {
            # 기본은 '정지 감지'. 그러나 만료된 running/starting lease가 가리키는 단계가 패킷에서
            # 이미 완료됐다면(수동 완료/대체) 웅크린 정지가 아니라 '재개 필요'로 표시한다(CFG043 DW2).
            $resume = ([string]$lease.Lease.state -match '^(starting|running)$') -and $isLeaseStageComplete
            if ($resume) {
                $status = 'RESUME'
                $stage = $leaseStage
                $processId = $leasePid
                $lastActivity = $lease.Heartbeat.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' · 종결됨 — 첫 미완료 단계부터 재개 필요'
                $lastActivityFull = $lastActivity
            } else {
                $status = 'STALLED'
                $stage = $leaseStage
                $processId = $leasePid
                $lastActivity = $lease.Heartbeat.ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' · state lease 만료'
                $lastActivityFull = $lastActivity
            }
        }
    } elseif ($lock -and $lock.Alive) {
        $stage = $lock.Stage.ToUpperInvariant()
        $processId = $lock.ProcessId
        $elapsed = Format-Elapsed -StartedAt $lock.StartedAt
        $activityTime = $lock.StartedAt
        if ($activityTime -and ((Get-Date) - $activityTime).TotalSeconds -ge $hangThresholds[$lock.Stage]) {
            $status = 'HANG'
        } else {
            $status = 'RUNNING'
        }
    } elseif ($lock) {
        $status = 'STALE'
        $stage = $lock.Stage.ToUpperInvariant()
        $processId = $lock.ProcessId
        $elapsed = Format-Elapsed -StartedAt $lock.StartedAt
    } elseif ($dispatcher) {
        # 락은 없지만 디스패처 프로세스는 살아 있다 = 단계 사이 전환 중.
        # 경과는 단계가 아니라 디스패처가 뜬 시각 기준이다(체인 전체 경과).
        $status = 'STANDBY'
        $processId = $dispatcher.ProcessId
        $elapsed = Format-Elapsed -StartedAt $dispatcher.StartedAt
    } elseif ($blocked) {
        $status = 'BLOCKED'
        $stage = $blocked.Stage.ToUpperInvariant()
        $owner = if ($blocked.OwnerTaskId -eq '-') { '점유자 미상' } else { "작업 $($blocked.OwnerTaskId)/PID $($blocked.OwnerProcessId)" }
        $lastActivity = "$($blocked.BlockedAt) · $($blocked.Reason) · $owner"
        $lastActivityFull = $lastActivity
    }
    # WAITING·장기보류는 디스패치 대상이 아니라 락·마커가 없으므로 IDLE로 떨어진다.
    # 라우터 상태를 그대로 보여줘야 "왜 안 도는지"를 알 수 있다.
    if ($status -eq 'IDLE' -and $task.Status -ne 'ACTIVE') {
        if ($task.Status -match '장기\s*보류') {
            $status = '장기보류'
        } else {
            $status = $task.Status
        }
    } elseif ($status -eq 'IDLE' -and $task.Status -eq 'ACTIVE') {
        # 호스트/다른 세션에서 실행한 에이전트는 이 프로세스 목록에서 보이지 않을 수 있다.
        # 실행 증거가 없다는 사실만으로 '정지'라고 단정하면 QA/Integration을 거짓 경보로
        # 표시한다. 실제 만료 락은 위에서 STALE로, 실패·승인대기는 각각 증거 파일로 표시한다.
        $status = 'READY'
        $lastActivity = "실행 증거 없음 · 다음 단계 $($task.NextStage) 대기"
        $lastActivityFull = $lastActivity
    }
    return [pscustomobject]@{
        Status = $status
        Stage = $stage
        PID = $processId
        Elapsed = $elapsed
        LastActivity = $lastActivity
        LastActivityFull = $lastActivityFull
    }
}
function Format-TaskStatusRow {
    param(
        [pscustomobject]$RawItem,
        [pscustomobject]$ReducedState
    )
    $task = $RawItem.Task
    $projectPath = $RawItem.ProjectPath
    $lease = $RawItem.Lease
    $lock = $RawItem.Lock
    $status = $ReducedState.Status
    $stage = $ReducedState.Stage
    $displayStage = Format-DashboardStage -Stage $stage -Status $status -Fallback $task.NextStage
    $stageKey = if ($lock) { $lock.Stage } else { Get-DashboardStageKey -Stage $stage }
    $leaseModel = if ($lease -and $lease.Fresh) { [string]$lease.Lease.model } else { $null }
    $identity = if ($status -eq '장기보류') { [pscustomobject]@{ Owner = '-'; Model = '-' } } else { Get-StageRuntimeIdentity -ProjectPath $projectPath -TaskId $task.TaskId -Stage $stageKey -RouterOwner $task.Owner -LeaseModel $leaseModel }
    return [pscustomobject]@{
        Project = Split-Path $projectPath -Leaf
        ProjectPath = $projectPath
        Task = $task.TaskId
        Stage = $displayStage
        StageKey = $stageKey
        Status = $status
        PID = $ReducedState.PID
        Elapsed = $ReducedState.Elapsed
        LastActivity = $ReducedState.LastActivity
        LastActivityFull = $ReducedState.LastActivityFull
        # 6컬럼 방언은 '다음 단계' 칸이 문장이라 Stage 칸에는 압축본만 들어간다. 원문은 툴팁에 남긴다.
        StageFull = if ($task.NextStageFull) { $task.NextStageFull } else { $displayStage }
        Owner = $identity.Owner
        Model = $identity.Model
    }
}
function Get-TaskStatuses {
    param([switch]$ShowAll)
    $raw = Get-RawTaskStates -ShowAll:$ShowAll
    $rows = @()
    foreach ($item in $raw.RawItems) {
        $reduced = Reduce-TaskState -RawItem $item
        $rows += Format-TaskStatusRow -RawItem $item -ReducedState $reduced
    }
    foreach ($bl in $raw.BacklogItems) {
        $hostPath = $bl.HostPath
        $task = $bl.Item
        $rows += [pscustomobject]@{
            Project = Split-Path -Leaf $hostPath
            ProjectPath = $hostPath
            Task = $task.Id
            Stage = '백로그'
            StageKey = 'backlog'
            Status = '백로그'
            PID = '-'
            Elapsed = '-'
            LastActivity = $task.FirstFound
            LastActivityFull = $task.StatusText
            StageFull = $task.Content
            Owner = "심각도:$($task.Severity)"
            Model = '-'
        }
    }
    return $rows
}
# 방어체계 및 시스템 건강 요약 — OpenCode 쿼터/티어 상태, 세션 연속 활동 시간, 승인 대기 집계.
function Get-DefenseHealthSummary {
    param([string[]]$Projects)
    # 1. OpenCode / Quota / Tier state
    $zenStatePath = Join-Path $env:USERPROFILE '.claude\zen-bigpickle-state.json'
    $tierStatus = 'OpenCode: 정상'
    $tierToolTip = ''
    if (Test-Path -LiteralPath $zenStatePath) {
        try {
            $zen = Get-Content -LiteralPath $zenStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $parts = @()
            if ($zen.tiers) {
                if ($zen.tiers.go) {
                    $goStatus = if ($zen.tiers.go.status -eq 'exhausted') {
                        $resetMsg = if ($zen.resetTime) {
                            try {
                                $dt = [datetime]$zen.resetTime
                                $diff = $dt.ToLocalTime() - (Get-Date)
                                if ($diff.TotalMinutes -gt 0) {
                                    $d = [math]::Floor($diff.TotalDays)
                                    $h = $diff.Hours
                                    if ($d -gt 0) { " (리셋: ${d}일 ${h}시간)" } else { " (리셋: ${h}시간)" }
                                } else { " (리셋 대기)" }
                            } catch { " (리셋: $([string]$zen.resetTime))" }
                        } else { '' }
                        "Go: 소진$resetMsg"
                    } else { "Go: 정상" }
                    $parts += $goStatus
                }
                if ($zen.tiers.free) {
                    $freeStatus = if ($zen.tiers.free.status -eq 'exhausted') { "Free: 소진" } else { "Free: 정상" }
                    $parts += $freeStatus
                }
                if ($zen.tiers.paid) {
                    $paidStatus = if ($zen.tiers.paid.status -eq 'exhausted') { "Paid: 잔액소진" } else { "Paid: 정상" }
                    $parts += $paidStatus
                }
            }
            if ($parts.Count -gt 0) {
                $tierStatus = "OpenCode: " + ($parts -join ' · ')
            } elseif ($zen.status) {
                $tierStatus = "OpenCode: $($zen.status) ($($zen.model))"
            }
            $tierToolTip = "OpenCode 쿼터 상태: $($zenStatePath)`n마지막 시도: $($zen.lastAttemptAt)`n카테고리: $($zen.category)"
            if ($zen.lastError) { $tierToolTip += "`n오류: $($zen.lastError)" }
        } catch { }
    }
    # 2. Session Health (프로젝트별 연속 활동 시간 — 대화 세션 트랙만)
    $maxActiveDuration = 0
    $maxProjectName = ''
    $maxTaskId = ''
    $sessionNotes = @()
    if ($Projects) {
        foreach ($p in $Projects) {
            $shPath = Join-Path $p '.agents\briefs\logs\.session-health.json'
            if (Test-Path -LiteralPath $shPath) {
                try {
                    $sh = Get-Content -LiteralPath $shPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $shSchema = 0
                    if ($sh.schemaVersion) { try { $shSchema = [int]$sh.schemaVersion } catch { $shSchema = 0 } }
                    if ($shSchema -ge 2 -and $sh.activityWindowStartedAt) {
                        $start = [datetime]$sh.activityWindowStartedAt
                        $span = (Get-Date) - $start.ToLocalTime()
                        if ($span.TotalMinutes -ge 0 -and $span.TotalHours -lt 48) {
                            $pName = Split-Path -Leaf $p
                            $taskInfo = if ($sh.taskId) { "$($sh.taskId)" + (if ($sh.stage) { " [$($sh.stage)]" } else { '' }) } else { '' }
                            if ($span.TotalMinutes -gt $maxActiveDuration) {
                                $maxActiveDuration = $span.TotalMinutes
                                $maxProjectName = $pName
                                $maxTaskId = $sh.taskId
                            }
                            $startLocal = $start.ToLocalTime().ToString('HH:mm')
                            $sessionNotes += "• [$pName] $taskInfo : $([math]::Floor($span.TotalHours))시간 $($span.Minutes)분 연속 (시작 $startLocal)"
                        }
                    }
                } catch { }
            }
        }
    }
    $sessionStatus = if ($maxActiveDuration -gt 0) {
        $hours = [math]::Floor($maxActiveDuration / 60)
        $mins = [int]($maxActiveDuration % 60)
        $warn = if ($hours -ge 6) { ' 🚨 새 세션 권고' } elseif ($hours -ge 4) { ' ⚠️ 주의' } else { '' }
        $projSuffix = if ($maxProjectName) { " ($maxProjectName" + (if ($maxTaskId) { ": $maxTaskId" } else { '' }) + ")" } else { '' }
        "⏱ 세션: ${hours}시간 ${mins}분$projSuffix$warn"
    } else {
        "⏱ 세션: 정상"
    }
    $sessionToolTip = if ($sessionNotes.Count -gt 0) {
        "프로젝트별 세션 연속 활동 시간:`n" + ($sessionNotes -join "`n") + "`n`n(4시간 이상 시 컨텍스트 비대화 주의, 6시간 이상 시 새 세션 권고)"
    } else { "프로젝트별 연속 활동 기록 없음" }
    return [pscustomobject]@{
        TierText = $tierStatus
        TierToolTip = $tierToolTip
        SessionText = $sessionStatus
        SessionToolTip = $sessionToolTip
    }
}
# 상태 표기 SSOT — 아이콘·글자색·행 배경을 한 곳에 모은다. 상태가 늘어도 여기만 고치면 된다.
# 아이콘은 컬러 이모지가 아니라 Segoe UI가 확실히 렌더하는 기호를 쓴다 — DataGridView 기본 폰트에서
# 이모지는 환경에 따라 두부(□)로 깨진다.
$statusStyles = [ordered]@{
    'RUNNING'  = @{ Text = '▶ RUNNING';  Fore = 'ForestGreen'; Back = 'Honeydew' }
    'HANG'     = @{ Text = '⚠ HANG?';    Fore = 'DarkOrange';  Back = 'LightYellow' }
    'APPROVAL_REQUIRED' = @{ Text = '⏳ 승인대기'; Fore = 'DarkViolet'; Back = 'LavenderBlush' }
    'FAILED'   = @{ Text = '✖ 실패중단';  Fore = 'Firebrick';   Back = 'MistyRose' }
    'STALE'    = @{ Text = '⚑ 스테일락';  Fore = 'Chocolate';   Back = 'Moccasin' }
    'STANDBY'  = @{ Text = '⏸ 체인대기';  Fore = 'SteelBlue';   Back = 'AliceBlue' }
    'READY'    = @{ Text = '○ 기동대기';  Fore = 'DimGray';     Back = 'White' }
    'STALLED'  = @{ Text = '⚠ 정지 감지'; Fore = 'DarkOrange';  Back = 'OldLace' }
    'RESUME'   = @{ Text = '▶ 재개 필요'; Fore = 'MediumBlue';  Back = 'LightCyan' }
    'BLOCKED'  = @{ Text = '⏳ 락 대기로 불발'; Fore = 'DarkGoldenrod'; Back = 'LemonChiffon' }
    'WAITING'  = @{ Text = '◇ 대기중';    Fore = 'RoyalBlue';   Back = 'Lavender' }
    '장기보류'  = @{ Text = '◆ 장기보류';  Fore = 'Gray';        Back = 'WhiteSmoke' }
    'IDLE'     = @{ Text = '○ 대기중';    Fore = 'DimGray';     Back = 'White' }
    '백로그'    = @{ Text = '◈ 백로그';    Fore = 'Teal';        Back = 'Azure' }
}
function Update-LongestSessionInfo {
    param([System.Windows.Forms.DataGridView]$Grid)
    if (-not $Grid) { return }
    $longestPath = Join-Path $env:USERPROFILE '.claude\.longest-session.json'
    if (-not (Test-Path -LiteralPath $longestPath)) {
        $Grid.Rows.Clear()
        $Grid.Visible = $false
        return
    }
    try {
        $data = Get-Content -LiteralPath $longestPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $data -or -not $data.observedAt) {
            $Grid.Rows.Clear()
            $Grid.Visible = $false
            return
        }
        $observedAt = [datetime]::Parse([string]$data.observedAt).ToUniversalTime()
        $ageMinutes = ([datetime]::UtcNow - $observedAt).TotalMinutes
        if ($ageMinutes -gt 3) {
            $Grid.Rows.Clear()
            $Grid.Visible = $false
            return
        }
        $sessionList = @($data.sessions)
        if ($sessionList.Count -eq 0) {
            $Grid.Rows.Clear()
            $Grid.Visible = $false
            return
        }
        $observedText = $observedAt.ToLocalTime().ToString('HH:mm')
        $Grid.Rows.Clear()
        # 리시버가 이미 contextUsedPercentage 내림차순으로 정렬해 보낸다 — 여기서는 그 순서를 그대로 렌더링한다.
        foreach ($sessionEntry in $sessionList) {
            $durationMs = [int]$sessionEntry.sessionDurationMs
            $hours = [math]::Floor($durationMs / 3600000)
            $minutes = [math]::Floor(($durationMs % 3600000) / 60000)
            $durationText = if ($hours -gt 0) { "${hours}h ${minutes}m" } else { "${minutes}m" }
            $tokens = [int]$sessionEntry.contextTokens
            $tokensText = if ($tokens -ge 1000) { "{0:N0}k" -f ($tokens / 1000) } else { "$tokens" }
            $pctText = if ($null -ne $sessionEntry.contextUsedPercentage) { "{0:N1}%" -f [double]$sessionEntry.contextUsedPercentage } else { '-' }
            $project = if ($sessionEntry.projectSlug) { $sessionEntry.projectSlug } else { '(unknown)' }
            $title = if ($sessionEntry.titleHint) { $sessionEntry.titleHint } else { '(no title)' }
            [void]$Grid.Rows.Add($project, $title, $durationText, $tokensText, $pctText, $observedText)
        }
        $Grid.Visible = $true
    } catch {
        $Grid.Rows.Clear()
        $Grid.Visible = $false
    }
}
function Update-Dashboard {
    param(
        [System.Windows.Forms.DataGridView]$Grid,
        [System.Windows.Forms.Label]$EmptyLabel,
        [System.Windows.Forms.Label]$UpdatedLabel,
        [System.Windows.Forms.Label]$TierBadge = $null,
        [System.Windows.Forms.Label]$SessionBadge = $null,
        [System.Windows.Forms.Label]$ApprovalBadge = $null,
        [System.Windows.Forms.Label]$HarnessBadge = $null,
        [System.Windows.Forms.DataGridView]$SessionGrid = $null,
        [System.Windows.Forms.ToolTip]$ToolTip = $null,
        [switch]$ShowAll
    )
    $harnessProjects = @(Get-HarnessProjects)
    if ($HarnessBadge) {
        # CFG042: 하네스 배포 동기화를 한 번에 보여준다. 드리프트가 있으면 Push가 필요하다는
        # 뜻이므로 가장 강하게, 유효 오버라이드만 있으면 기록된 로컬 예외이므로 그 다음 강도로,
        # 전부 정본과 같으면 동기화 완료로 표시한다. 세부 항목은 툴팁에 담는다.
        $summary = Get-HarnessSyncSummary
        if ($summary.Drifts.Count -gt 0) {
            $HarnessBadge.Text = "🔗 하네스: 드리프트 $($summary.Drifts.Count) · 오버라이드 $($summary.Overrides.Count)"
            $HarnessBadge.ForeColor = [System.Drawing.Color]::Crimson
        } elseif ($summary.Overrides.Count -gt 0) {
            $HarnessBadge.Text = "🔗 하네스: 오버라이드 $($summary.Overrides.Count)"
            $HarnessBadge.ForeColor = [System.Drawing.Color]::DarkGoldenrod
        } else {
            $HarnessBadge.Text = '🔗 하네스: 동기화됨'
            $HarnessBadge.ForeColor = [System.Drawing.Color]::DarkOliveGreen
        }
        if ($ToolTip) {
            $tipLines = @()
            if ($summary.Overrides.Count -gt 0) {
                $tipLines += "오버라이드 — 기록된 로컬 예외 (동기화 제외 대상):"
                $summary.Overrides | ForEach-Object { $tipLines += "  $_" }
            }
            if ($summary.Drifts.Count -gt 0) {
                $tipLines += "드리프트 — 미등록·누락·충돌 (Push 필요):"
                $summary.Drifts | ForEach-Object { $tipLines += "  $_" }
            }
            if ($tipLines.Count -eq 0) {
                $tipLines += "전 대상 자산 $($summary.MasterChecks)개가 정본과 동기화됨"
            }
            $ToolTip.SetToolTip($HarnessBadge, ($tipLines -join "`n"))
        }
    }
    if ($TierBadge -or $SessionBadge -or $ApprovalBadge) {
        $health = Get-DefenseHealthSummary -Projects $harnessProjects
        if ($TierBadge) {
            $TierBadge.Text = $health.TierText
            if ($ToolTip) { $ToolTip.SetToolTip($TierBadge, $health.TierToolTip) }
        }
        if ($SessionBadge) {
            $SessionBadge.Text = $health.SessionText
            if ($ToolTip) { $ToolTip.SetToolTip($SessionBadge, $health.SessionToolTip) }
        }
    }
    if ($SessionGrid) {
        Update-LongestSessionInfo -Grid $SessionGrid
    }
    # 디스크 스캔은 매번 수행하지만, 화면 데이터가 같으면 Rows.Clear()를 하지 않는다.
    # DataGridView의 전체 재생성은 행이 적어도 눈에 띄는 깜빡임을 유발한다.
    $rows = @(Get-TaskStatuses -ShowAll:$ShowAll)
    if ($ApprovalBadge) {
        $runningCount = @($rows | Where-Object { $_.Status -eq 'RUNNING' }).Count
        $pendingApprovals = @($harnessProjects | ForEach-Object { Get-DispatchApprovals -ProjectPath $_ })
        $approvalCount = $pendingApprovals.Count
        $failedCount = @($rows | Where-Object { $_.Status -eq 'FAILED' }).Count
        $ApprovalBadge.Text = "▶ 실행중: $runningCount · ⏳ 승인대기: $approvalCount · ✖ 실패: $failedCount"
        $approvalToolTip = if ($approvalCount -gt 0) {
            (@($pendingApprovals | ForEach-Object { "$($_.TaskId) [$($_.Stage)]: $($_.Target)" }) -join "`n")
        } else { "대기 중인 승인 요청 없음" }
        if ($ToolTip) { $ToolTip.SetToolTip($ApprovalBadge, $approvalToolTip) }
    }
    $snapshot = @(
        $rows | ForEach-Object {
            @($_.Project, $_.Task, $_.Stage, $_.Owner, $_.Model, $_.Status, $_.PID, $_.Elapsed, $_.LastActivity, $_.LastActivityFull, $_.StageFull) -join [char]31
        }
    ) -join [char]30
    if ($snapshot -eq $script:dashboardSnapshot) {
        $UpdatedLabel.Text = '데이터 확인: ' + (Get-Date).ToString('HH:mm:ss')
        return
    }
    # 실제 변경일 때만 갱신 전 스크롤 위치를 저장한다. Rows.Clear()가 이를 리셋하므로
    # 보고 있던 위치가 바뀐 갱신에서도 맨 위로 날아가지 않게 한다.
    $savedScrollIndex = -1
    if ($Grid.RowCount -gt 0 -and $Grid.FirstDisplayedScrollingRowIndex -ge 0) {
        $savedScrollIndex = $Grid.FirstDisplayedScrollingRowIndex
    }
    $Grid.Rows.Clear()
    $EmptyLabel.Text = if ($ShowAll) { '표시할 패킷 없음 (DONE·폐기 제외)' } else { '현재 ACTIVE 패킷 없음' }
    $EmptyLabel.Visible = $rows.Count -eq 0
    foreach ($row in $rows) {
        $style = $statusStyles[$row.Status]
        if (-not $style) { $style = $statusStyles['IDLE'] }
        $index = $Grid.Rows.Add($row.Project, $row.Task, $row.Stage, $row.Owner, $row.Model, $style.Text, $row.PID, $row.Elapsed, $row.LastActivity)
        $Grid.Rows[$index].Tag = $row
        $Grid.Rows[$index].Cells['LastActivity'].ToolTipText = $row.LastActivityFull
        $Grid.Rows[$index].Cells['Stage'].ToolTipText = $row.StageFull
        $back = [System.Drawing.Color]::FromName($style.Back)
        $Grid.Rows[$index].DefaultCellStyle.BackColor = $back
        # 읽기 전용 모니터라 선택에 의미가 없다. 기본 선택색(파란 배경)이 덮이면 상태색이 그 위에서
        # 읽히지 않으므로, 선택 시에도 행 색을 그대로 유지해 상태 구분이 사라지지 않게 한다.
        $Grid.Rows[$index].DefaultCellStyle.SelectionBackColor = $back
        $Grid.Rows[$index].DefaultCellStyle.SelectionForeColor = [System.Drawing.SystemColors]::ControlText
        # 글자색은 Status 셀에만 준다 — 행 전체를 물들이면 나머지 칸의 가독성이 떨어진다.
        # 셀 스타일은 행 스타일보다 우선하므로 선택 시에도 남도록 SelectionForeColor를 같이 지정한다.
        $statusCell = $Grid.Rows[$index].Cells['Status']
        $statusCell.Style.ForeColor = [System.Drawing.Color]::FromName($style.Fore)
        $statusCell.Style.SelectionForeColor = [System.Drawing.Color]::FromName($style.Fore)
    }
    $Grid.ClearSelection()
    # 스크롤 위치 복원 — 행 수가 줄었으면 마지막 행까지만 내린다.
    if ($savedScrollIndex -ge 0 -and $Grid.RowCount -gt 0) {
        if ($savedScrollIndex -ge $Grid.RowCount) { $savedScrollIndex = $Grid.RowCount - 1 }
        $Grid.FirstDisplayedScrollingRowIndex = $savedScrollIndex
    }
    $script:dashboardSnapshot = $snapshot
    $UpdatedLabel.Text = '데이터 갱신: ' + (Get-Date).ToString('HH:mm:ss')
}
function Open-PacketFile {
    param([pscustomobject]$Row)
    if (-not $Row -or -not $Row.Task -or -not $Row.ProjectPath) { return }
    if ($Row.StageKey -eq 'backlog') {
        $blPath = Join-Path $Row.ProjectPath '.agents\briefs\backlog.md'
        if (Test-Path $blPath) { Start-Process -FilePath $blPath | Out-Null }
        return
    }
    $packetsDir = Join-Path $Row.ProjectPath '.agents\briefs\packets'
    if (Test-Path $packetsDir) {
        $matchFiles = @(Get-ChildItem -Path $packetsDir -Filter "$($Row.Task)*.md" -File -ErrorAction SilentlyContinue)
        if ($matchFiles.Count -gt 0) {
            Start-Process -FilePath $matchFiles[0].FullName | Out-Null
            return
        }
    }
    $routerPath = Join-Path $Row.ProjectPath '.agents\briefs\handoff-log.md'
    if (Test-Path $routerPath) { Start-Process -FilePath $routerPath | Out-Null }
}
$form = New-Object System.Windows.Forms.Form
$form.Text = '패킷 상태 대시보드'
$form.ClientSize = New-Object System.Drawing.Size(1280, 430)
$form.MinimumSize = New-Object System.Drawing.Size(700, 280)
$form.StartPosition = 'CenterScreen'
$form.AccessibleName = '패킷 상태 대시보드'
# 키보드 단축키(F5)를 폼 수준에서 잡으려면 KeyPreview가 필요하다.
$form.KeyPreview = $true
# 상단 제어 행 — 캡처 한 장에서 필터·수동 갱신·데이터 시각·현재 시각을 함께 확인한다.
$script:showAllFilter = $true
$script:dashboardSnapshot = $null
$toolTip = New-Object System.Windows.Forms.ToolTip
$controlPanel = New-Object System.Windows.Forms.Panel
$controlPanel.Dock = 'Top'
$controlPanel.Height = 32
$controlPanel.Padding = New-Object System.Windows.Forms.Padding(4, 2, 4, 2)
$controlPanel.AccessibleName = '대시보드 제어 및 시간 정보'
$radioActive = New-Object System.Windows.Forms.RadioButton
$radioActive.Text = 'ACTIVE만'
$radioActive.AutoSize = $true
$radioActive.Location = New-Object System.Drawing.Point(6, 6)
$radioActive.Checked = $false
$radioActive.AccessibleName = 'ACTIVE만 표시'
$radioAll = New-Object System.Windows.Forms.RadioButton
$radioAll.Text = '전부 표시 (DONE·폐기 제외)'
$radioAll.AutoSize = $true
$radioAll.Location = New-Object System.Drawing.Point(88, 6)
$radioAll.AccessibleName = '전부 표시'
$refreshButton = New-Object System.Windows.Forms.Button
$refreshButton.Text = '지금 갱신 (F5)'
$refreshButton.Size = New-Object System.Drawing.Size(95, 25)
$refreshButton.Location = New-Object System.Drawing.Point(270, 3)
$refreshButton.AccessibleName = '강제 새로고침'
$refreshButton.AccessibleDescription = '대시보드를 즉시 다시 읽어옵니다'
$restartDashButton = New-Object System.Windows.Forms.Button
$restartDashButton.Text = '↺ 대시보드 재시작'
$restartDashButton.Size = New-Object System.Drawing.Size(125, 25)
$restartDashButton.Location = New-Object System.Drawing.Point(370, 3)
$restartDashButton.AccessibleName = '대시보드 재시작'
$restartDashButton.AccessibleDescription = '대시보드 창을 닫고 새 프로세스로 다시 실행합니다'
$updatedLabel = New-Object System.Windows.Forms.Label
$updatedLabel.AutoSize = $true
$updatedLabel.Location = New-Object System.Drawing.Point(505, 8)
$updatedLabel.AccessibleName = '데이터 갱신 시각'
$clockLabel = New-Object System.Windows.Forms.Label
$clockLabel.AutoSize = $true
$clockLabel.Location = New-Object System.Drawing.Point(640, 8)
$clockLabel.AccessibleName = '현재 시각'
$controlPanel.Controls.Add($radioActive)
$controlPanel.Controls.Add($radioAll)
# 같은 컨테이너에 라디오 버튼을 모두 넣은 뒤 선택해야 WinForms가 먼저 추가된 ACTIVE만 버튼을
# 기본값으로 다시 선택하지 않는다.
$radioAll.Checked = $true
$controlPanel.Controls.Add($refreshButton)
$controlPanel.Controls.Add($restartDashButton)
$controlPanel.Controls.Add($updatedLabel)
$controlPanel.Controls.Add($clockLabel)
# 방어체계 및 세션 건강 요약 패널 — 상단 제어부와 테이블 사이에 배치
$summaryPanel = New-Object System.Windows.Forms.FlowLayoutPanel
$summaryPanel.Dock = 'Top'
$summaryPanel.Height = 28
$summaryPanel.BackColor = [System.Drawing.Color]::FromArgb(242, 245, 250)
$summaryPanel.Padding = New-Object System.Windows.Forms.Padding(6, 4, 6, 2)
$summaryPanel.WrapContents = $false
$summaryPanel.AutoScroll = $false
$summaryPanel.AccessibleName = '방어체계 및 세션 건강 요약'
$tierBadge = New-Object System.Windows.Forms.Label
$tierBadge.AutoSize = $true
$tierBadge.Margin = New-Object System.Windows.Forms.Padding(4, 2, 16, 2)
$tierBadge.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
$tierBadge.ForeColor = [System.Drawing.Color]::DarkSlateBlue
$tierBadge.Text = 'OpenCode: 상태 확인중...'
$tierBadge.Cursor = [System.Windows.Forms.Cursors]::Hand
$tierBadge.AccessibleName = 'OpenCode 티어 상태'
$sessionBadge = New-Object System.Windows.Forms.Label
$sessionBadge.AutoSize = $true
$sessionBadge.Margin = New-Object System.Windows.Forms.Padding(4, 2, 16, 2)
$sessionBadge.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
$sessionBadge.ForeColor = [System.Drawing.Color]::DarkSlateGray
$sessionBadge.Text = '⏱ 세션: 확인중...'
$sessionBadge.Cursor = [System.Windows.Forms.Cursors]::Hand
$sessionBadge.AccessibleName = '세션 활동 시간'
$approvalBadge = New-Object System.Windows.Forms.Label
$approvalBadge.AutoSize = $true
$approvalBadge.Margin = New-Object System.Windows.Forms.Padding(4, 2, 8, 2)
$approvalBadge.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
$approvalBadge.ForeColor = [System.Drawing.Color]::DarkOliveGreen
$approvalBadge.Text = '▶ 실행중: 0 · ⏳ 승인대기: 0 · ✖ 실패: 0'
$approvalBadge.Cursor = [System.Windows.Forms.Cursors]::Hand
$approvalBadge.AccessibleName = '파이프라인 및 승인 요약'
$harnessBadge = New-Object System.Windows.Forms.Label
$harnessBadge.AutoSize = $true
$harnessBadge.Margin = New-Object System.Windows.Forms.Padding(4, 2, 8, 2)
$harnessBadge.Font = New-Object System.Drawing.Font($form.Font.FontFamily, 9, [System.Drawing.FontStyle]::Bold)
$harnessBadge.ForeColor = [System.Drawing.Color]::DarkSlateGray
$harnessBadge.Text = '🔗 하네스: 확인중...'
$harnessBadge.Cursor = [System.Windows.Forms.Cursors]::Hand
$harnessBadge.AccessibleName = '하네스 동기화 상태 (오버라이드·드리프트)'
$summaryPanel.Controls.Add($tierBadge)
$summaryPanel.Controls.Add($sessionBadge)
$summaryPanel.Controls.Add($approvalBadge)
$summaryPanel.Controls.Add($harnessBadge)
# 가장 오래된 세션 테이블 — 패킷 그리드와 분리된 0~1행 DataGridView.
$sessionGrid = New-Object System.Windows.Forms.DataGridView
$sessionGrid.Dock = 'Top'
$sessionGrid.Height = 50
$sessionGrid.Visible = $false
$sessionGrid.ReadOnly = $true
$sessionGrid.AllowUserToAddRows = $false
$sessionGrid.AllowUserToDeleteRows = $false
$sessionGrid.AllowUserToResizeRows = $false
$sessionGrid.RowHeadersVisible = $false
$sessionGrid.AutoSizeColumnsMode = 'Fill'
$sessionGrid.SelectionMode = 'FullRowSelect'
$sessionGrid.MultiSelect = $false
$sessionGrid.BackgroundColor = [System.Drawing.Color]::FromArgb(248, 249, 252)
$sessionGrid.AccessibleName = '가장 오래된 세션 정보'
foreach ($column in @(
    @('프로젝트', 20), @('제목 힌트', 40), @('경과 시간', 12), @('컨텍스트 토큰', 14), @('잔여 컨텍스트%', 12), @('관측 시각', 14)
)) {
    $index = $sessionGrid.Columns.Add([string]$column[0], [string]$column[0])
    $sessionGrid.Columns[$index].FillWeight = [single]$column[1]
}
$emptyLabel = New-Object System.Windows.Forms.Label
$emptyLabel.Text = '표시할 패킷 없음 (DONE·폐기 제외)'
$emptyLabel.Dock = 'Top'
$emptyLabel.Height = 28
$emptyLabel.TextAlign = 'MiddleCenter'
$emptyLabel.AccessibleName = '활성 패킷 안내'
$emptyLabel.Visible = $false
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = 'Fill'
$grid.AccessibleName = '활성 패킷 상태 표'
# 컬럼 순서와 폭. Owner를 Stage 옆에 붙여 "누가 어느 단계"를 한 눈에 읽게 하고, 남는 폭은
# LastActivity(라우터 갱신일 원문 — 가장 긴 텍스트)에 몰아준다. Fill 모드에서 FillWeight는
# 비율이고 MinimumWidth는 창을 줄였을 때의 하한이다.
$columnLayout = @(
    @{ Name = 'Project';      Weight = 105; Min = 80 },
    @{ Name = 'Task';         Weight = 55;  Min = 50 },
    @{ Name = 'Stage';        Weight = 58;  Min = 50 },
    @{ Name = 'Owner';        Weight = 105; Min = 86 },
    @{ Name = 'Model';        Weight = 115; Min = 96 },
    @{ Name = 'Status';       Weight = 100; Min = 86 },
    @{ Name = 'PID';          Weight = 42;  Min = 38 },
    @{ Name = 'Elapsed';      Weight = 62;  Min = 55 },
    @{ Name = 'LastActivity'; Weight = 400; Min = 160 }
)
foreach ($column in $columnLayout) {
    $index = $grid.Columns.Add($column.Name, $column.Name)
    $grid.Columns[$index].FillWeight = $column.Weight
    $grid.Columns[$index].MinimumWidth = $column.Min
}
# Status 칸만 굵게 — 컬럼 스타일이라 행마다 폰트 객체를 새로 만들지 않는다.
$grid.Columns['Status'].DefaultCellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$legendLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$legendLabel.Text = '▶ 실행중   ⚠ 무응답 의심   ⏳ 승인 대기   ✖ 실패로 중단   ⚑ 죽은 락 잔존   ⏸ 체인 전환   ○ 기동대기   ◇ WAITING   ◆ 장기보류   ◈ 백로그'
$legendLabel.ForeColor = [System.Drawing.Color]::DimGray
[void]$statusStrip.Items.Add($legendLabel)
# 라디오 선택 변경 핸들러 — 필터 상태를 즉시 반영한다.
$radioActive.Add_CheckedChanged({
    if ($radioActive.Checked) {
        $script:showAllFilter = $false
        Update-Dashboard -Grid $grid -EmptyLabel $emptyLabel -UpdatedLabel $updatedLabel -TierBadge $tierBadge -SessionBadge $sessionBadge -ApprovalBadge $approvalBadge -HarnessBadge $harnessBadge -SessionGrid $sessionGrid -ToolTip $toolTip
    }
})
$radioAll.Add_CheckedChanged({
    if ($radioAll.Checked) {
        $script:showAllFilter = $true
        Update-Dashboard -Grid $grid -EmptyLabel $emptyLabel -UpdatedLabel $updatedLabel -TierBadge $tierBadge -SessionBadge $sessionBadge -ApprovalBadge $approvalBadge -HarnessBadge $harnessBadge -SessionGrid $sessionGrid -ToolTip $toolTip -ShowAll
    }
})
# 강제 새로고침 공통 핸들러 — 버튼 클릭과 F5 모두 이 경로를 탄다.
$refreshAction = {
    # 타이머가 Tick 사이에 수동 갱신을 여러 번 눌러도 불필요한 부하만 생긴다.
    # 버튼을 즉시 비활성화하고 갱신이 끝난 뒤 풀어준다.
    $refreshButton.Enabled = $false
    try {
        Update-Dashboard -Grid $grid -EmptyLabel $emptyLabel -UpdatedLabel $updatedLabel -TierBadge $tierBadge -SessionBadge $sessionBadge -ApprovalBadge $approvalBadge -HarnessBadge $harnessBadge -SessionGrid $sessionGrid -ToolTip $toolTip -ShowAll:$script:showAllFilter
    } finally {
        $refreshButton.Enabled = $true
    }
}
$refreshButton.Add_Click($refreshAction)
$restartDashAction = {
    $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -IntervalSeconds {1}' -f $PSCommandPath, $IntervalSeconds
    Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
    $form.Close()
}
$restartDashButton.Add_Click($restartDashAction)
# DataGridView 컨텍스트 메뉴 (우클릭)
$contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
$menuOpenPacket = New-Object System.Windows.Forms.ToolStripMenuItem
$menuOpenPacket.Text = '📂 패킷 파일 열기'
$menuOpenPacket.Add_Click({
    if ($grid.SelectedRows.Count -gt 0 -and $grid.SelectedRows[0].Tag) {
        Open-PacketFile -Row $grid.SelectedRows[0].Tag
    }
})
$menuCopyTaskId = New-Object System.Windows.Forms.ToolStripMenuItem
$menuCopyTaskId.Text = '📋 작업 ID 복사'
$menuCopyTaskId.Add_Click({
    if ($grid.SelectedRows.Count -gt 0 -and $grid.SelectedRows[0].Tag) {
        $tId = $grid.SelectedRows[0].Tag.Task
        if ($tId) { [System.Windows.Forms.Clipboard]::SetText($tId) }
    }
})
[void]$contextMenu.Items.Add($menuOpenPacket)
[void]$contextMenu.Items.Add($menuCopyTaskId)
$grid.ContextMenuStrip = $contextMenu
# 우클릭 시 마우스 위치의 행을 자동 선택
$grid.Add_CellMouseDown({
    param([object]$sender, [System.Windows.Forms.DataGridViewCellMouseEventArgs]$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right -and $e.RowIndex -ge 0) {
        $grid.ClearSelection()
        $grid.Rows[$e.RowIndex].Selected = $true
    }
})
$form.Add_KeyDown({
    param([object]$sender, [System.Windows.Forms.KeyEventArgs]$e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::F5) {
        $e.Handled = $true
        $refreshButton.PerformClick()
    }
})
$form.Controls.Add($grid)
$form.Controls.Add($emptyLabel)
$form.Controls.Add($sessionGrid)
$form.Controls.Add($summaryPanel)
$form.Controls.Add($controlPanel)
$form.Controls.Add($statusStrip)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $IntervalSeconds * 1000
$timer.Add_Tick({ Update-Dashboard -Grid $grid -EmptyLabel $emptyLabel -UpdatedLabel $updatedLabel -TierBadge $tierBadge -SessionBadge $sessionBadge -ApprovalBadge $approvalBadge -HarnessBadge $harnessBadge -SessionGrid $sessionGrid -ToolTip $toolTip -ShowAll:$script:showAllFilter })
$clockTimer = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = 1000
$clockTimer.Add_Tick({ $clockLabel.Text = '현재: ' + (Get-Date).ToString('HH:mm:ss KST') })
Update-Dashboard -Grid $grid -EmptyLabel $emptyLabel -UpdatedLabel $updatedLabel -TierBadge $tierBadge -SessionBadge $sessionBadge -ApprovalBadge $approvalBadge -HarnessBadge $harnessBadge -SessionGrid $sessionGrid -ToolTip $toolTip -ShowAll
$clockLabel.Text = '현재: ' + (Get-Date).ToString('HH:mm:ss KST')
$timer.Start()
$clockTimer.Start()
[void]$form.ShowDialog()
$timer.Stop()
$clockTimer.Stop()
