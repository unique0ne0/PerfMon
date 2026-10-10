<#
.SYNOPSIS
    여러 프로젝트의 ACTIVE 패킷 실행 상태를 보여주는 읽기 전용 WinForms 대시보드.
#>
param(
    [ValidateRange(1, 3600)]
    [int]$IntervalSeconds = 10
)
# WinForms는 STA 스레드가 필요하다. 사용자가 -sta를 기억하지 않아도 되도록 재실행한다.
if ($MyInvocation.InvocationName -ne '.' -and ($MyInvocation.Line -notmatch '^\s*\.\s' -or $MyInvocation.Line -eq $null)) {
    if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
        $arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -IntervalSeconds {1}' -f $PSCommandPath, $IntervalSeconds
        Start-Process -FilePath 'powershell.exe' -ArgumentList $arguments -WindowStyle Hidden | Out-Null
        exit 0
    }
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
# SHA-256은 파일 수정시각·크기가 같으면 재계산하지 않는다. 동기화 요약은 자산 수 × 프로젝트 수 × 2회
# (정본은 프로젝트마다 다시) 해시를 뜨므로 Get-FileHash 호출 자체가 갱신 시간의 대부분이었다.
if (-not $script:FileParseCache) { $script:FileParseCache = @{} }
function Get-CachedFileHash {
    param([string]$Path)
    $fileInfo = [System.IO.FileInfo]::new($Path)
    if (-not $fileInfo.Exists) { throw "file not found: $Path" }
    $hashStamp = "$($fileInfo.LastWriteTimeUtc.Ticks)|$($fileInfo.Length)"
    $hashKey = "hash|$($fileInfo.FullName)"
    $hashCached = $script:FileParseCache[$hashKey]
    if ($hashCached -and $hashCached.Stamp -eq $hashStamp) { return $hashCached.Value }
    $hashValue = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $script:FileParseCache[$hashKey] = @{ Stamp = $hashStamp; Value = $hashValue }
    return $hashValue
}
function Test-HarnessOverrideState {
    param([hashtable]$OverrideLookup, [string]$Target, [string]$Asset, [string]$Master)
    $key = "$([System.IO.Path]::GetFullPath($Target))|$Asset"
    $entries = @($OverrideLookup[$key])
    if ($entries.Count -ne 1 -or $entries[0].localOverride -ne $true -or [string]::IsNullOrWhiteSpace([string]$entries[0].lastSyncedHash)) { return $false }
    $copy = Join-Path $Target "scripts\$Asset"
    if (-not (Test-Path -LiteralPath $copy)) { return $false }
    try { return (Get-CachedFileHash -Path $copy) -ne $Master }
    catch { return $false }
}
$harnessIoModule = $null
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $harnessIoModule = Join-Path $PSScriptRoot 'harness-io.ps1' }
if ([string]::IsNullOrWhiteSpace($harnessIoModule) -or -not (Test-Path -LiteralPath $harnessIoModule)) {
    $harnessIoModule = Join-Path (Join-Path $root 'global\harness') 'harness-io.ps1'
}
if (-not (Test-Path -LiteralPath $harnessIoModule)) { throw "Required harness I/O module not found: $harnessIoModule" }
. $harnessIoModule
# ── CFG100(B): 정본 HEAD 기준 비교용 헬퍼 ────────────────────────────────────
# 정본 작업 트리에 미커밋 하네스 변경이 있어도 "하류 사본이 정본 HEAD와 같은가"로 판정해
# "정본 편집 중(미커밋)"을 진짜 드리프트로 오인하지 않는다(CFG-BL-081 (a)). 줄바꿈·BOM을
# 정규화해 비교한다(WorldSaju 67d7277 선례). 순수 함수라 회귀 테스트가 AST로 직접 부른다.
function Get-HarnessNormalizedText {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $t = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    $list = New-Object System.Collections.ArrayList
    foreach ($ln in @($t -split "`n")) { [void]$list.Add($ln) }
    while ($list.Count -gt 0 -and $list[$list.Count - 1] -eq '') { $list.RemoveAt($list.Count - 1) }
    return ([string]::Join("`n", $list.ToArray()))
}
function Get-HarnessContentHash {
    param([string]$Text)
    if ($null -eq $Text) { return $null }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return ([System.BitConverter]::ToString($bytes)).Replace('-', '').ToUpperInvariant()
    } finally { $sha.Dispose() }
}
function Get-HarnessNormalizedFileHash {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return (Get-HarnessContentHash -Text (Get-HarnessNormalizedText -Text $text))
}
function Get-HarnessHeadBlobHash {
    param([string]$ConfigRoot, [string]$Asset)
    try {
        $text = (& git -C $ConfigRoot show ("HEAD:global/harness/" + $Asset) 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $null }
    } catch { return $null }
    return (Get-HarnessContentHash -Text (Get-HarnessNormalizedText -Text $text))
}
# 정본 작업 트리에서 미커밋인 하네스 자산 이름 집합을 돌려준다(수정·추가·삭제 포함).
# git 이 없거나 저장소가 아니면 빈 집합 — 그럼 호출자는 기존 작업 트리 기준으로 판정한다.
function Get-HarnessDirtyAssets {
    param([string]$ConfigRoot)
    $dirty = @{}
    if (-not (Test-Path (Join-Path $ConfigRoot '.git'))) { return $dirty }
    try {
        foreach ($line in @(& git -C $ConfigRoot status --porcelain -- global/harness/ 2>$null)) {
            if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -lt 4) { continue }
            $p = $line.Substring(3).Trim().Trim('"') -replace '\\', '/'
            if ($p -match '^global/harness/(.+)$') { $dirty[$Matches[1]] = $true }
        }
    } catch { }
    return $dirty
}

# ── CFG102: 이력 blob·락·배지 분류 — CFG100 판정 기준(정본 HEAD)은 바꾸지 않고 표시 상태만 계산한다 ──
# 정본 자산의 과거 커밋 blob(정규화 해시) 집합. 사본이 정본 HEAD 와 다르지만 이 집합의 한 원소와
# 같으면 "배포 대기"(정본 수정 후 아직 하류로 배포되지 않음), 어디에도 없으면 "진짜 드리프트"다.
# 자산·정본 HEAD 스탬프별로 캐시해 대시보드 갱신(10초)마다 git 이력을 다시 읽지 않는다.
if (-not $script:HarnessAssetHistoryCache) { $script:HarnessAssetHistoryCache = @{} }
# 회귀 테스트가 "캐시 히트 시 추가 git 호출 0회"를 셀 수 있게 이력 조회(log·show) 호출 수를 센다.
# rev-parse(HEAD 스탬프)·status(더티 판정)은 CFG100 이 이미 쓰던 별개 호출이라 세지 않는다.
$script:HarnessHistoryGitCalls = 0
function Invoke-HarnessHistoryGit {
    # 이력 조회 전용 git 실행 래퍼. 빈 출력(파일이 그 커밋에 없음)과 실패를 구분하도록 종료 코드를 함께 준다.
    param([string]$ConfigRoot, [string[]]$GitArgs)
    $script:HarnessHistoryGitCalls++
    $output = @()
    $code = 1
    try {
        $output = @(& git -C $ConfigRoot @GitArgs 2>$null)
        $code = $LASTEXITCODE
    } catch { $output = @(); $code = 1 }
    return [pscustomobject]@{ Output = $output; Code = $code }
}
function Get-HarnessHeadCommit {
    param([string]$ConfigRoot)
    if ([string]::IsNullOrWhiteSpace($ConfigRoot) -or -not (Test-Path (Join-Path $ConfigRoot '.git'))) { return $null }
    try {
        $sha = (@(& git -C $ConfigRoot rev-parse HEAD 2>$null) | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$sha)) { return $null }
        return ([string]$sha).Trim()
    } catch { return $null }
}
function Get-HarnessAssetHistoryHashes {
    # 해당 자산을 바꾼 정본 커밋들의 blob 을 정규화 해시 집합으로 돌려준다(자산·HEAD 스탬프별 캐시).
    param([string]$ConfigRoot, [string]$Asset, [string]$HeadStamp)
    $key = "$Asset|$HeadStamp"
    if ($script:HarnessAssetHistoryCache.ContainsKey($key)) { return $script:HarnessAssetHistoryCache[$key] }
    $hashes = @{}
    if (-not [string]::IsNullOrWhiteSpace($ConfigRoot) -and (Test-Path (Join-Path $ConfigRoot '.git'))) {
        $rel = 'global/harness/' + $Asset
        $logResult = Invoke-HarnessHistoryGit -ConfigRoot $ConfigRoot -GitArgs @('log', '--format=%H', '--', $rel)
        if ($logResult.Code -eq 0) {
            foreach ($line in $logResult.Output) {
                $sha = ([string]$line).Trim()
                if ([string]::IsNullOrWhiteSpace($sha)) { continue }
                $showResult = Invoke-HarnessHistoryGit -ConfigRoot $ConfigRoot -GitArgs @('show', ($sha + ':' + $rel))
                if ($showResult.Code -ne 0) { continue }
                $h = Get-HarnessContentHash -Text (Get-HarnessNormalizedText -Text (($showResult.Output) -join "`n"))
                if ($h) { $hashes[$h] = $true }
            }
        }
    }
    $script:HarnessAssetHistoryCache[$key] = $hashes
    return $hashes
}
function Get-HarnessBusyLock {
    # CFG089 함수(sync-configs.ps1 Get-HarnessBusyLock)와 같은 판정을 공유한다 — 그 저장소에 살아
    # 있는 디스패치 락(impl/qa/integration)이 있으면 그 정보를, 없거나 전부 스테일이면 $null 을 준다.
    # 생존 판정은 Read-HarnessLockFile(PID + 프로세스 시작 시각)에 위임하고 여기서 재구현하지 않는다.
    param([string]$ProjRoot)
    foreach ($stage in @('impl', 'qa', 'integration')) {
        $lock = Get-DispatchLock -ProjectPath $ProjRoot -Stage $stage
        if ($lock -and $lock.Alive) {
            return [pscustomobject]@{ Stage = $stage; TaskId = $lock.TaskId; ProcessId = $lock.ProcessId }
        }
    }
    return $null
}

# ── CFG042: 하네스 배포 동기화 요약 — 오버라이드(추적 가능한 로컬 예외)와 드리프트 분리 ──
function Get-HarnessSyncSummary {
    $masterDir = Join-Path $root 'global\harness'
    # 정본(SSOT) 매니페스트를 우선 읽는다. $PSScriptRoot(호스트 파일 경로) 우선은 dot-source한 호스트의
    # 옆 매니페스트로 치우쳐 hermetic 검증을 깨고, 배포 사본은 스테일 목록이라 오판 위험이 있다.
    # 정본이 없는 예외적 문맥(global\harness에서 직접 실행된 연산자 등)에서만 호스트 옆 파일로 폴백한다.
    $manifestPath = Join-Path $masterDir 'harness-assets.txt'
    if (-not (Test-Path -LiteralPath $manifestPath) -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $manifestPath = Join-Path $PSScriptRoot 'harness-assets.txt'
    }
    try { $assets = @(Read-HarnessAssets -ManifestPath $manifestPath) }
    catch { return [pscustomobject]@{ MasterChecks = 0; Overrides = @(); Drifts = @("manifest ($($_.Exception.Message))"); DeployPending = @(); Projects = @(); CanonicalEditing = @(); CanonicalEditingMinutes = $null; ProjectStates = @() } }
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
    # CFG100: 정본이 편집 중인 자산은 HEAD blob 을 기준으로 비교하고 "정본 편집 중"으로 분류한다.
    $dirtyAssets = Get-HarnessDirtyAssets -ConfigRoot $root
    $canonicalEditing = @($assets | Where-Object { $dirtyAssets.ContainsKey($_) })
    # CFG102: 정본 편집 경과 시간 — 가장 오래된 편집 자산의 mtime 기준. 헤더 배지에 "정본 편집 중 N분"으로 병기.
    $canonicalEditingMinutes = $null
    if ($canonicalEditing.Count -gt 0) {
        $oldestEdit = $null
        foreach ($editAsset in $canonicalEditing) {
            $editPath = Join-Path $masterDir $editAsset
            if (-not (Test-Path -LiteralPath $editPath)) { continue }
            try { $editMtime = (Get-Item -LiteralPath $editPath).LastWriteTime } catch { continue }
            if ($null -eq $oldestEdit -or $editMtime -lt $oldestEdit) { $oldestEdit = $editMtime }
        }
        if ($null -ne $oldestEdit) {
            $editMins = [int][math]::Floor(((Get-Date) - $oldestEdit).TotalMinutes)
            if ($editMins -lt 0) { $editMins = 0 }
            $canonicalEditingMinutes = $editMins
        }
    }
    # CFG102: 이력 조회는 사본이 다를 때만 필요하다 — 정본 HEAD 스탬프는 지연 계산해 in-sync 틱의 git 호출을 늘리지 않는다.
    $headStamp = $null
    $headStampResolved = $false
    $overrides = @(); $drifts = @(); $deployPending = @(); $checked = 0
    $projectStates = @()
    foreach ($proj in $harnessProjects) {
        # 자산별 차이를 모은 뒤 저장소 단위 상태를 정한다(상태는 저장소당 하나 —
        # CFG102 우선순위: 락 지연 > 오버라이드 > 진짜 드리프트 > 배포 대기).
        $projDiff = @()      # 정본 HEAD 와 다른 비오버라이드 사본 (@{ Asset; Hash(정규화) })
        $projMissing = @()   # 사본 없음 — 이력 대조 불가라 항상 진짜 드리프트
        $projOverride = $false
        foreach ($asset in $assets) {
            $isDirty = $dirtyAssets.ContainsKey($asset)
            $masterWorkTreeHash = $null
            if ($isDirty) {
                # 정본 HEAD 에 없는 새 자산이면 하류와 비교할 기준이 없다 — 편집 중으로만 분류한다.
                $masterHash = Get-HarnessHeadBlobHash -ConfigRoot $root -Asset $asset
                if (-not $masterHash) { continue }
                # 정본 미커밋 편집 자체와도 비교한다 — 정본 미러·개발 중(-AllowDirtyCanonical) 배포 사본은
                # HEAD 가 아니라 이 작업 트리와 같으므로 "정본 편집 중"이지 진짜 드리프트가 아니다.
                try { $masterWorkTreeHash = Get-HarnessNormalizedFileHash -Path (Join-Path $masterDir $asset) } catch { $masterWorkTreeHash = $null }
            } else {
                $master = Join-Path $masterDir $asset
                # 대시보드는 읽기 전용 모니터라 활성 git/디스패치가 이 파일을 쥐고 있는 순간과 겹치는 건
                # 정상 상황이다. 예외를 삼키고 이번 틱은 건너뛴다 — 5초 뒤 다음 틱에서 락이 풀려 있으면
                # 정상 판정된다. 여기서 죽으면 WinForms Timer.Tick 핸들러까지 예외가 올라가 앱 전체가
                # 크래시한다(2026-09-08 실제 크래시 덤프로 확인: file in use → ActionPreferenceStopException).
                try { $masterHash = Get-CachedFileHash -Path $master }
                catch { continue }
            }
            $copy = Join-Path $proj "scripts\$asset"
            if (-not (Test-Path -LiteralPath $copy)) { $drifts += "$proj|$asset (missing)"; $projMissing += $asset; continue }
            try {
                if ($isDirty) { $copyHash = Get-HarnessNormalizedFileHash -Path $copy }
                else { $copyHash = Get-CachedFileHash -Path $copy }
            } catch { continue }
            if ($copyHash -eq $masterHash) { $checked++; continue }
            if ($isDirty -and $masterWorkTreeHash -and $copyHash -eq $masterWorkTreeHash) { $checked++; continue }
            if (Test-HarnessOverrideState -OverrideLookup $overrideLookup -Target $proj -Asset $asset -Master $masterHash) {
                $overrides += "$proj|$asset"
                $projOverride = $true
            } else {
                # 이력 대조는 정규화 해시 기준이다 — HEAD 비교(비더티 때는 원시 해시)와 별개로 계산한다.
                $normCopyHash = $null
                try { $normCopyHash = Get-HarnessNormalizedFileHash -Path $copy } catch { $normCopyHash = $null }
                $projDiff += [pscustomobject]@{ Asset = $asset; Hash = $normCopyHash }
            }
        }
        $hasAnyDiff = ($projDiff.Count -gt 0) -or ($projMissing.Count -gt 0) -or $projOverride
        if (-not $hasAnyDiff) { continue }
        # CFG089 락 판정은 분류 우선순위의 최상단이라 오버라이드만 있는 저장소에도 적용한다.
        $busy = $null
        try { $busy = Get-HarnessBusyLock -ProjRoot $proj } catch { $busy = $null }
        if ($projDiff.Count -eq 0 -and $projMissing.Count -eq 0) {
            $projStatus = if ($busy) { 'lock-deferred' } else { 'override' }
            $projectStates += [pscustomobject]@{ Project = $proj; Status = $projStatus; Detail = @($overrides | Where-Object { $_ -like "$proj|*" }) }
            continue
        }
        # 정본 HEAD 와 다른 사본을 정본 이력과 대조해 배포 대기/진짜 드리프트로 가른다. 이력 어디에도
        # 없는 사본은 진짜 드리프트다. 사본 없음은 대조가 불가능하므로 진짜 드리프트로 센다.
        if (-not $headStampResolved) { $headStamp = Get-HarnessHeadCommit -ConfigRoot $root; $headStampResolved = $true }
        $projDrift = ($projMissing.Count -gt 0)
        foreach ($diff in $projDiff) {
            $isPending = $false
            if ($headStamp -and $diff.Hash) {
                $history = Get-HarnessAssetHistoryHashes -ConfigRoot $root -Asset $diff.Asset -HeadStamp $headStamp
                if ($history.ContainsKey($diff.Hash)) { $isPending = $true }
            }
            if ($isPending) { $deployPending += "$proj|$($diff.Asset)" }
            else { $drifts += "$proj|$($diff.Asset)"; $projDrift = $true }
        }
        $projStatus = if ($busy) { 'lock-deferred' }
                      elseif ($projOverride) { 'override' }
                      elseif ($projDrift) { 'real-drift' }
                      else { 'deploy-pending' }
        $projectStates += [pscustomobject]@{ Project = $proj; Status = $projStatus; Detail = @($projDiff | ForEach-Object { $_.Asset }) }
    }
    return [pscustomobject]@{
        MasterChecks = $checked
        Overrides = @($overrides)
        Drifts = @($drifts)
        DeployPending = @($deployPending)
        Projects = @($harnessProjects)
        CanonicalEditing = @($canonicalEditing)
        CanonicalEditingMinutes = $canonicalEditingMinutes
        ProjectStates = @($projectStates)
    }
}
# CFG102: 배지 텍스트·색·툴팁을 순수 함수로 분리한다 — WinForms 없이 회귀 테스트가 직접 단언한다.
# 경고색(Crimson)은 진짜 드리프트에만 준다. 0건 상태는 표시하지 않고 텍스트를 축약하며,
# 정본 편집 중은 정본의 속성이라 저장소별 상태가 아니라 헤더에 한 번 별도로 표기한다.
function Format-HarnessBadge {
    param($Summary)
    $states = @($Summary.ProjectStates)
    $drift = @($states | Where-Object { $_.Status -eq 'real-drift' }).Count
    $lock = @($states | Where-Object { $_.Status -eq 'lock-deferred' }).Count
    $override = @($states | Where-Object { $_.Status -eq 'override' }).Count
    $pending = @($states | Where-Object { $_.Status -eq 'deploy-pending' }).Count
    $editing = @($Summary.CanonicalEditing).Count
    $parts = @()
    if ($drift -gt 0) { $parts += "진짜 드리프트 $drift" }
    if ($lock -gt 0) { $parts += "락 지연 $lock" }
    if ($override -gt 0) { $parts += "오버라이드 $override" }
    if ($pending -gt 0) { $parts += "배포 대기 $pending" }
    $editSuffix = ''
    if ($editing -gt 0) {
        if ($null -ne $Summary.CanonicalEditingMinutes) { $editSuffix = " · 정본 편집 중 $($Summary.CanonicalEditingMinutes)분" }
        else { $editSuffix = ' · 정본 편집 중' }
    }
    if ($parts.Count -gt 0) { $text = '🔗 하네스: ' + ($parts -join ' · ') + $editSuffix }
    else { $text = '🔗 하네스: 동기화됨' + $editSuffix }
    $fore = if ($drift -gt 0) { 'Crimson' }
            elseif ($parts.Count -gt 0) { 'DarkSlateGray' }
            else { 'DarkOliveGreen' }
    $tipLines = @()
    if ($drift -gt 0) {
        $tipLines += '진짜 드리프트 — 정본 이력 어디에도 없는 사본 (Push/수정 필요):'
        $Summary.Drifts | ForEach-Object { $tipLines += "  $_" }
    }
    if ($lock -gt 0) {
        $tipLines += '락 지연 — 실행 중 체인 때문에 이번 배포가 미뤄진 저장소:'
        $states | Where-Object { $_.Status -eq 'lock-deferred' } | ForEach-Object { $tipLines += "  $($_.Project)" }
    }
    if ($override -gt 0) {
        $tipLines += '오버라이드 — 기록된 로컬 예외 (동기화 제외 대상):'
        $Summary.Overrides | ForEach-Object { $tipLines += "  $_" }
    }
    if ($pending -gt 0) {
        $tipLines += '배포 대기 — 정본 수정 후 아직 배포되지 않음:'
        $Summary.DeployPending | ForEach-Object { $tipLines += "  $_" }
    }
    if ($editing -gt 0) {
        $minsText = if ($null -ne $Summary.CanonicalEditingMinutes) { " · 편집중 $($Summary.CanonicalEditingMinutes)분" } else { '' }
        $tipLines += "정본 편집 중 — 미커밋 정본 자산 ${editing}개${minsText}:"
        $Summary.CanonicalEditing | ForEach-Object { $tipLines += "  $_" }
    }
    if ($tipLines.Count -eq 0) { $tipLines += "전 대상 자산 $($Summary.MasterChecks)개가 정본과 동기화됨" }
    return [pscustomobject]@{ Text = $text; Fore = $fore; Tip = ($tipLines -join "`n") }
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
# 갱신마다 같은 파일을 다시 파싱하지 않도록 (경로 → 수정시각·크기 스탬프, 파싱 결과)를 둔다.
# 스탬프가 같으면 내용도 같다고 보므로 오래된 값이 남지 않는다 — TTL 캐시가 아니다.
if (-not $script:FileParseCache) { $script:FileParseCache = @{} }
function Get-FileStamp {
    param([System.IO.FileInfo]$File)
    return "$($File.LastWriteTimeUtc.Ticks)|$($File.Length)"
}
function Get-RouterTasks {
    param([string]$ProjectPath)
    $routerPath = Join-Path $ProjectPath '.agents\briefs\handoff-log.md'
    if (-not (Test-Path $routerPath)) { return @() }
    $routerStamp = Get-FileStamp -File (Get-Item -LiteralPath $routerPath)
    $routerCacheKey = "router|$routerPath"
    $routerCached = $script:FileParseCache[$routerCacheKey]
    if ($routerCached -and $routerCached.Stamp -eq $routerStamp) { return $routerCached.Value }
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
    $script:FileParseCache[$routerCacheKey] = @{ Stamp = $routerStamp; Value = $tasks }
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
            $recordStamp = Get-FileStamp -File $recordFile
            $recordCacheKey = "json|$($recordFile.FullName)"
            $recordCached = $script:FileParseCache[$recordCacheKey]
            if ($recordCached -and $recordCached.Stamp -eq $recordStamp) {
                $record = $recordCached.Value
            } else {
                $record = Get-Content $recordFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
                $script:FileParseCache[$recordCacheKey] = @{ Stamp = $recordStamp; Value = $record }
            }
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
    # WMI 프로세스 조회는 한 번에 ~0.4초라 갱신 주기를 지배한다. 명령줄은 프로세스 생애 동안 변하지
    # 않으므로, powershell/pwsh 프로세스 집합(PID+시작시각)이 지난번과 같으면 지난 결과를 그대로 쓴다.
    # 새 디스패처는 새 PID이므로 집합이 바뀌어 즉시 감지된다 — TTL 캐시와 달리 지연이 없다.
    $psKey = (@(Get-Process -Name powershell, pwsh -ErrorAction SilentlyContinue | ForEach-Object {
        $started = try { $_.StartTime.Ticks } catch { 0 }
        "$($_.Id):$started"
    }) | Sort-Object) -join ','
    if ($script:ChainDispatcherCache -and $script:ChainDispatcherCache.Key -eq $psKey) {
        return $script:ChainDispatcherCache.Value
    }
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
    $script:ChainDispatcherCache = @{ Key = $psKey; Value = $dispatchers }
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
    $teamByAdapter = Get-AdapterTeamMap
    if (-not $defaultTeam) { return [pscustomobject]@{ Owner = $RouterOwner; Model = '-' } }
    # CFG079: 하네스가 기록한 chain-runtime.json(단계별 실제 실행 model/adapter)이 최우선 근거다.
    # host 로그 라인 파싱보다 정확하고, 라우터 산문보다 항상 최신이다 — 라우터 갱신이 늦어도
    # 화면이 stale 라벨("기획팀/Claude")로 되돌아가지 않는다.
    $runtimePath = Join-Path $ProjectPath ('.agents\briefs\logs\' + $TaskId + '-chain-runtime.json')
    if (-not (Test-Path -LiteralPath $runtimePath)) {
        $norm = Get-NormalizedTaskId -TaskId $TaskId
        if ($norm) { $runtimePath = Join-Path $ProjectPath ('.agents\briefs\logs\' + $norm + '-chain-runtime.json') }
    }
    if (Test-Path -LiteralPath $runtimePath) {
        try {
            $runtime = Get-Content -LiteralPath $runtimePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $entry = $runtime.stages.$Stage
            # adapter가 비어 있으면 principal에서 파생한다(opencode-go → opencode). modelCatalog에
            # adapter 필드가 없는 항목은 Record-ChainRuntime가 adapter를 빈 값으로 남기므로 폴백이 필요하다.
            $adapter = if ($entry -and [string]$entry.adapter) { ([string]$entry.adapter).ToLowerInvariant() }
                       elseif ($entry -and [string]$entry.principal) {
                           $p = ([string]$entry.principal).ToLowerInvariant()
                           foreach ($known in @('antigravity','codex','claude','gemini','opencode')) {
                               if ($p -match "^$known") { $known; break }
                           }
                       } else { $null }
            if ($adapter) {
                $cli = @{ antigravity = 'Antigravity CLI'; codex = 'Codex CLI'; claude = 'Claude CLI'; gemini = 'Gemini CLI'; opencode = 'OpenCode CLI' }[$adapter]
                if ($cli) {
                    $actualTeam = if ($teamByAdapter.ContainsKey($adapter)) { $teamByAdapter[$adapter] } else { $defaultTeam }
                    $owner = if ($actualTeam -ne $defaultTeam) { "$actualTeam 대행($defaultTeam) / $cli" } else { "$actualTeam / $cli" }
                    $model = if ($LeaseModel) { $LeaseModel } elseif ([string]$entry.model) { [string]$entry.model } else { '-' }
                    return [pscustomobject]@{ Owner = $owner; Model = $model }
                }
            }
        } catch { }
    }
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
            # 어댑터→팀 매핑은 공용 harness-contracts.ps1(Get-AdapterTeamMap)이 SSOT다(CFG096).
            # 매핑에 없는 어댑터만 근거가 없으므로 단계 기본팀 이름을 그대로 쓴다.
            $actualTeam = if ($teamByAdapter.ContainsKey($adapter)) { $teamByAdapter[$adapter] } else { $defaultTeam }
            $owner = if ($actualTeam -ne $defaultTeam) { "$actualTeam 대행($defaultTeam) / $cli" } else { "$actualTeam / $cli" }
            return [pscustomobject]@{ Owner = $owner; Model = if ($LeaseModel) { $LeaseModel } else { $model } }
        }
    }
    return [pscustomobject]@{ Owner = $RouterOwner; Model = if ($LeaseModel) { $LeaseModel } else { '-' } }
}
# .agents/briefs/backlog.md 파서. 프로젝트마다 backlog.md를 가질 수 있어 Get-TaskStatuses가 각 프로젝트를
# 순회하며 이 함수를 부른다. 두 가지 표 형식을 읽는다(ID는 `<접두사>-BL-NNN`, 접두사는 저장소마다 다르다).
# (1) 하네스 형식 — 800ac06(2026-09-09) 재설계로 표가 셋으로 나뉘었고 컬럼도 서로 다르다. '## 미해결' 표(5열:
#     ID/내용/우선순위/최초 발견/관찰 조건)만 읽는다. '해결·승격 완료' 표는 이미 종결된 항목이라 노출할
#     필요가 없고, 표 자체가 곧 open/closed 판정이라(미해결 표에 있으면 open) 상태 문구를 추측하지 않는다.
# (2) 상태 열 형식 — 첫 '## ' 헤딩 앞의 단일 표(5열: ID/항목/등록일/상태/근거). 상태 칸이 OPEN으로
#     시작하는 행만 미해결로 본다('→ ai0076'·'DONE (날짜)'는 종결/승격). 우선순위 칸이 없어 '-'로 채운다.
function Get-BacklogTasks {
    param([string]$ProjectPath)
    if ([string]::IsNullOrWhiteSpace($ProjectPath)) { return @() }
    $path = Join-Path $ProjectPath '.agents\briefs\backlog.md'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $items = @()
    $inOpenSection = $false
    $inPreamble = $true
    foreach ($line in @(Get-Content -LiteralPath $path -Encoding UTF8)) {
        if ($line -match '^##\s') { $inPreamble = $false; $inOpenSection = ($line -match '미해결'); continue }
        if (-not ($inOpenSection -or $inPreamble)) { continue }
        if ($line -notmatch '^\|\s*([A-Za-z][A-Za-z0-9]*-BL-\d+)\s*\|') { continue }
        $parts = $line.Trim() -split '\|'
        if ($inPreamble) {
            # [0]/[-1]은 선두/말미 빈 셀. 5열이면 [1..5] = ID/항목/등록일/상태/근거.
            if ($parts.Count -ne 7 -or $parts[4].Trim() -notmatch '^OPEN\b') { continue }
            $items += [pscustomobject]@{
                Id = $parts[1].Trim()
                Content = $parts[2].Trim()
                Priority = '-'
                FirstFound = $parts[3].Trim()
                ObserveCondition = $parts[5].Trim()
            }
            continue
        }
        # [0]/[-1]은 선두/말미 빈 셀. 끝 4셀이 [우선순위, 최초발견, 관찰 조건, 빈]이다.
        # 내용 셀에 '|'가 섞인 행에 대비해 끝에서 5번째부터 두번째 셀까지 전부 내용으로 합친다.
        if ($parts.Count -lt 7) { continue }
        $contentCells = if ($parts.Count -gt 7) { $parts[2..($parts.Count - 5)] } else { @($parts[2]) }
        $items += [pscustomobject]@{
            Id = $parts[1].Trim()
            Content = ($contentCells -join '|').Trim()
            Priority = $parts[-4].Trim()
            FirstFound = $parts[-3].Trim()
            ObserveCondition = $parts[-2].Trim()
        }
    }
    return $items
}
# '최초 발견' 칸은 자유 텍스트(예: '기획팀 CFG062 ⑤ Integration 독립 검증 (2026-09-06)')다.
# 그 안의 날짜만 뽑아 관찰 시작일로 삼고 오늘까지 경과 일수를 보여준다 — 날짜가 없으면 '-'.
function Format-BacklogElapsedDays {
    param([string]$FirstFoundText)
    if ($FirstFoundText -notmatch '(\d{4}-\d{2}-\d{2})') { return '-' }
    try { $started = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd', $null) } catch { return '-' }
    $days = [math]::Floor(((Get-Date).Date - $started.Date).TotalDays)
    if ($days -lt 0) { return '-' }
    if ($days -eq 0) { return '오늘부터' }
    return "${days}일째"
}
# 대시보드 LastActivity 칸(그리드 셀, 폭 제한)에는 관찰 조건의 굵은 요지 문장만, 툴팁에는
# 원문 전체를 보여준다 — backlog.md 해결 표의 '요약/원문' 분리 관행과 동일한 방식.
function Get-BacklogObserveSummary {
    param([string]$ObserveCondition)
    if ([string]::IsNullOrWhiteSpace($ObserveCondition)) { return '-' }
    if ($ObserveCondition -match '\*\*(.+?)\*\*') { return $Matches[1].Trim() }
    if ($ObserveCondition.Length -gt 80) { return $ObserveCondition.Substring(0, 80) + '…' }
    return $ObserveCondition
}
# 백로그 항목이 어느 작업(패킷)과 관련 있는지 관찰 조건/내용에서 뽑는다(예: '작업 CFG064' → 'CFG064').
# 백로그 ID(CFG-BL-042)는 하이픈으로 문자·숫자가 분리돼 있어 이 패턴(문자 바로 뒤 숫자)에 걸리지 않는다.
function Get-BacklogRelatedTask {
    param([string]$ObserveCondition, [string]$Content)
    foreach ($text in @($ObserveCondition, $Content)) {
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($text -match '\b([A-Z]{2,6}\d{3,})\b') { return $Matches[1] }
    }
    return $null
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
        # 프로젝트당 .dispatch-* 파일 이름을 한 번만 열거하고, 해당 단계 파일이 있을 때만 읽기 함수를 부른다.
        # (단계 3개 × 락·실패·차단 9회의 개별 디렉터리 조회를 1회로 줄인다 — 읽기 결과는 동일하다.)
        $dispatchLogDir = Join-Path $projectPath '.agents\briefs\logs'
        $dispatchNames = @()
        if (Test-Path -LiteralPath $dispatchLogDir) {
            $dispatchNames = @(Get-ChildItem -LiteralPath $dispatchLogDir -Filter '.dispatch-*' -Force -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        }
        foreach ($stage in $scanStages) {
            if ($dispatchNames -contains ".dispatch-lock-$stage") {
                $lock = Get-DispatchLock -ProjectPath $projectPath -Stage $stage
                if ($lock) { $locks[$lock.TaskId] = $lock }
            }
            if (@($dispatchNames | Where-Object { $_ -like ".dispatch-failed-*$stage" }).Count -gt 0) {
                foreach ($failure in @(Get-DispatchFailures -ProjectPath $projectPath -Stage $stage)) {
                    if ($failure) { $failures[$failure.TaskId] = $failure }
                }
            }
            if (@($dispatchNames | Where-Object { $_ -like ".dispatch-blocked-*-$stage" }).Count -gt 0) {
                foreach ($blocked in @(Get-DispatchBlocked -ProjectPath $projectPath -Stage $stage)) {
                    if ($blocked) { $blockedMarkers[$blocked.TaskId] = $blocked }
                }
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
            $orphanLock = $locks[$orphanId]
            $isStaleDone = $routerStatus -eq 'DONE' -and $orphanLock -and -not $orphanLock.Alive
            $note = if ($isStaleDone) { 'ℹ️ 정리 대기 — 다음 디스패치 시 자동 정리됨' }
                    elseif ($routerStatus) { "⚠ 라우터 상태 $routerStatus — ACTIVE 아님" }
                    else { '⚠ 라우터에 행 없음' }
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
        # 프로젝트마다 자기 backlog.md를 가진다 — 첫 하나만 읽으면 나머지 프로젝트의 백로그가 대시보드에서 사라진다.
        $backlogHosts = @()
        foreach ($p in @(Get-HarnessProjects)) {
            if (Test-Path -LiteralPath (Join-Path $p '.agents\briefs\backlog.md')) { $backlogHosts += $p }
        }
        if ($backlogHosts.Count -eq 0 -and (Test-Path -LiteralPath (Join-Path $root '.agents\briefs\backlog.md'))) { $backlogHosts += $root }
        foreach ($backlogHost in $backlogHosts) {
            # Get-BacklogTasks가 이미 미해결 항목만 읽으므로 별도 필터 불필요.
            foreach ($bl in @(Get-BacklogTasks -ProjectPath $backlogHost)) {
                $backlogItems += [pscustomobject]@{
                    HostPath = $backlogHost
                    Item = $bl
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
        $relatedTask = Get-BacklogRelatedTask -ObserveCondition $task.ObserveCondition -Content $task.Content
        $rows += [pscustomobject]@{
            Project = Split-Path -Leaf $hostPath
            ProjectPath = $hostPath
            Task = $task.Id
            Stage = '백로그'
            StageKey = 'backlog'
            Status = '장기보류'
            PID = '-'
            Elapsed = Format-BacklogElapsedDays -FirstFoundText $task.FirstFound
            LastActivity = Get-BacklogObserveSummary -ObserveCondition $task.ObserveCondition
            LastActivityFull = $task.ObserveCondition
            StageFull = $task.Content
            Owner = if ($relatedTask) { "→ $relatedTask" } else { '-' }
            Model = '-'
        }
    }
    return $rows
}
# claude-zen-fallback/lib/routing-plan.mjs의 tierCoolingDown()과 동일 판정 — 실제 프록시가 라우팅에
# 쓰는 기준을 그대로 이식한다. status가 'exhausted'여도 resetTime이 이미 지났으면 더 이상 쿨다운
# 중이 아니라고 본다(단, 그 이후 실제 재시도로 갱신된 건 아니므로 '확정 정상'과는 구분해 표시한다).
function Test-ZenTierCoolingDown {
    param($Tier)
    if (-not $Tier -or $Tier.status -ne 'exhausted') { return $false }
    if (-not $Tier.resetTime) { return $false }
    try { return ([datetime]$Tier.resetTime).ToLocalTime() -gt (Get-Date) } catch { return $false }
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
            $estimatedNotes = @()
            if ($zen.tiers) {
                if ($zen.tiers.go) {
                    $goTier = $zen.tiers.go
                    $goStatus = if (Test-ZenTierCoolingDown -Tier $goTier) {
                        $dt = ([datetime]$goTier.resetTime).ToLocalTime()
                        $diff = $dt - (Get-Date)
                        $d = [math]::Floor($diff.TotalDays)
                        $h = $diff.Hours
                        $resetMsg = if ($d -gt 0) { " (리셋: ${d}일 ${h}시간)" } else { " (리셋: ${h}시간)" }
                        "Go: 소진$resetMsg"
                    } elseif ($goTier.status -eq 'exhausted') {
                        $estimatedNotes += 'Go'
                        "Go: 정상(추정)"
                    } else { "Go: 정상" }
                    $parts += $goStatus
                }
                if ($zen.tiers.free) {
                    $freeTier = $zen.tiers.free
                    $freeStatus = if (Test-ZenTierCoolingDown -Tier $freeTier) {
                        "Free: 소진"
                    } elseif ($freeTier.status -eq 'exhausted') {
                        $estimatedNotes += 'Free'
                        "Free: 정상(추정)"
                    } else { "Free: 정상" }
                    $parts += $freeStatus
                }
                if ($zen.tiers.paid) {
                    # paid는 잔액 소진이라 시간 기반 리셋 개념이 없다 — resetTime 재해석 대상에서 제외.
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
            if ($estimatedNotes.Count -gt 0) {
                $tierToolTip += "`n(추정) " + ($estimatedNotes -join ', ') + ": 리셋 예정 시각은 지났으나 그 이후 실제 재시도가 없어 확정 갱신은 안 됨"
            }
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
# 디스크·프로세스 스캔을 모두 모은다. UI 컨트롤을 건드리지 않으므로 별도 runspace(백그라운드 스레드)에서
# 돌려도 안전하다 — 화면 스레드는 결과를 그리기만 한다(Update-Dashboard).
function Get-DashboardData {
    param([switch]$ShowAll)
    $projects = @(Get-HarnessProjects)
    [pscustomobject]@{
        ShowAll   = [bool]$ShowAll
        Harness   = Get-HarnessSyncSummary
        Health    = Get-DefenseHealthSummary -Projects $projects
        Rows      = @(Get-TaskStatuses -ShowAll:$ShowAll)
        Approvals = @($projects | ForEach-Object { Get-DispatchApprovals -ProjectPath $_ })
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
        [Parameter(Mandatory)]$Data
    )
    $ShowAll = [bool]$Data.ShowAll
    if ($HarnessBadge) {
        # CFG102: 상태 분류(진짜 드리프트/락 지연/오버라이드/배포 대기/정본 편집 중)를 배지로 보여준다.
        # 경고색은 진짜 드리프트에만 — 나머지는 중립색. 렌더 규칙은 Format-HarnessBadge 순수 함수가 SSOT다.
        $badge = Format-HarnessBadge -Summary $Data.Harness
        $HarnessBadge.Text = $badge.Text
        $HarnessBadge.ForeColor = [System.Drawing.Color]::FromName($badge.Fore)
        if ($ToolTip) { $ToolTip.SetToolTip($HarnessBadge, $badge.Tip) }
    }
    if ($TierBadge -or $SessionBadge -or $ApprovalBadge) {
        $health = $Data.Health
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
    $rows = @($Data.Rows)
    if ($ApprovalBadge) {
        $runningCount = @($rows | Where-Object { $_.Status -eq 'RUNNING' }).Count
        $pendingApprovals = @($Data.Approvals)
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
# ── CFG111: 이벤트+폴링 혼합 스케줄러의 dot-source 가능한 순수 함수들 ─────────
# GUI(STA) 밖에서도 테스트할 수 있도록 스케줄 판정·lifecycle을 순수 함수로 분리한다.
# 시간/수집 경계는 인자로 주입해 30초·5초를 실제로 기다리지 않고 검증한다(설계 §D.2).

function Test-DashboardWatchTarget {
    # briefs 루트 기준 상대경로를 받아 감시 대상 여부/Changed 한정 heartbeat 여부를 돌려준다.
    # C# 브리지 DashboardWatcherBridge.IsWatchedPath와 같은 계약이다(파리티는 회귀 테스트가 대조).
    param([Parameter(Mandatory=$true)][string]$RelativePath)
    $rel = $RelativePath.Replace('\', '/').TrimStart('/')
    if ($rel -eq 'handoff-log.md' -or $rel -eq 'backlog.md') { return [pscustomobject]@{ Watched = $true; Heartbeat = $false } }
    if ($rel -like 'packets/*.md' -or $rel -like 'archive/*.md') { return [pscustomobject]@{ Watched = $true; Heartbeat = $false } }
    if ($rel -like 'logs/*') {
        $leaf = $rel.Substring(5)
        # heartbeat(Changed 한정 live 주기 병합): 락/lease. 나머지 logs 자산은 즉시 경로(CR09).
        if ($leaf -like '*-stage-state.json' -or $leaf -like '.dispatch-lock-*') { return [pscustomobject]@{ Watched = $true; Heartbeat = $true } }
        if ($leaf -like '.dispatch-*') { return [pscustomobject]@{ Watched = $true; Heartbeat = $false } }
        if ($leaf -like '*-approval.json' -or $leaf -like '*-chain-runtime.json') { return [pscustomobject]@{ Watched = $true; Heartbeat = $false } }
        if ($leaf -eq '.session-health.json') { return [pscustomobject]@{ Watched = $true; Heartbeat = $false } }
    }
    return [pscustomobject]@{ Watched = $false; Heartbeat = $false }
}

function Get-DashboardRefreshDecision {
    # dirty 이벤트가 있을 때 "지금 수집을 요청해야 하는가"를 판정한다(트레일링 debounce + 최대 대기).
    # 첫 dirty 이후 500ms가 지나면 요청(1초 이내), 연속 이벤트가 이어져도 2초를 넘기지 않는다.
    param(
        [bool]$Dirty,
        [bool]$Visible,
        [bool]$Collecting,
        [datetime]$FirstDirtyAt,
        [datetime]$LastDirtyAt,
        [datetime]$Now,
        [int]$DebounceMs = 500,
        [int]$MaxWaitMs = 2000
    )
    if (-not $Dirty) { return $false }
    if (-not $Visible) { return $false }
    if ($Collecting) { return $false }
    $sinceLast = ($Now - $LastDirtyAt).TotalMilliseconds
    $sinceFirst = ($Now - $FirstDirtyAt).TotalMilliseconds
    return (($sinceLast -ge $DebounceMs) -or ($sinceFirst -ge $MaxWaitMs))
}

function Get-DashboardPollMilliseconds {
    # RUNNING/live는 기존 주기(기본 10초), 유휴는 90초 폴링(이벤트 유실·lease 만료 보완).
    param([bool]$HasLive, [int]$IntervalSeconds = 10, [int]$IdleSeconds = 90)
    if ($HasLive) { return ([math]::Max(1, $IntervalSeconds)) * 1000 }
    return ([math]::Max(1, $IdleSeconds)) * 1000
}

function Resolve-DashboardCollectionTimeout {
    # 수집 lifecycle 판정(순수): 수집 중 30초 초과 → 'timeout', 중단 유예 5초 초과 → 'fault'.
    param(
        [string]$Phase,
        [double]$CollectingMs,
        [double]$StoppingMs,
        [int]$TimeoutMs = 30000,
        [int]$StopGraceMs = 5000
    )
    if ($Phase -eq 'collecting' -and $CollectingMs -ge $TimeoutMs) { return 'timeout' }
    if ($Phase -eq 'stopping' -and $StoppingMs -ge $StopGraceMs) { return 'fault' }
    return 'none'
}

function Get-DashboardTimeoutRetryDecision {
    # 자동 재수집은 연속 타임아웃 1회까지 — 자동 재시도 포함 2회째에서 차단(F5 명시 재시도만 허용).
    param([int]$ConsecutiveTimeouts, [int]$MaxConsecutive = 2)
    return ($ConsecutiveTimeouts -lt $MaxConsecutive)
}

function Resolve-DashboardRequestOutcome {
    # 수집 요청 판정(순수): idle이면 즉시 수집('start'), 이미 수집 중이면 대기 슬롯 1개만 예약('queue'),
    # stopping/fault(정리 완료 전)면 수집 불가('blocked' — 재시작만이 복구 수단).
    param([string]$Phase)
    if ($Phase -eq 'collecting') { return 'queue' }
    if ($Phase -eq 'stopping' -or $Phase -eq 'fault') { return 'blocked' }
    return 'start'
}

function Test-DashboardStaleResult {
    # 수집 도중 필터가 바뀌었으면(결과의 ShowAll ≠ 현재 필터) 구결과를 폐기하고 최신 필터로 다시 수집한다.
    param([bool]$ResultShowAll, [bool]$CurrentShowAll)
    return ($ResultShowAll -ne $CurrentShowAll)
}

# C# 브리지 소스 — CLR 파일 감시 콜백이 경로 허용목록을 필터한 뒤 lock 안에서 dirty 상태만
# 병합한다(CR01: PowerShell scriptblock을 ThreadPool에서 직접 실행하지 않는다). Add-Type은 여기서
# 하지 않고 GUI 영역에서 형식 존재 검사를 거쳐 한 번만 컴파일한다. 단일 인용 here-string이라
# PowerShell 5.1에서도 그대로 안전하게 파싱된다.
$script:DashboardWatcherBridgeSource = @'
using System;
using System.Collections.Generic;
using System.IO;

public class DashboardWatcherBridge
{
    private readonly object _lock = new object();
    private readonly Dictionary<string, FileSystemWatcher> _watchers = new Dictionary<string, FileSystemWatcher>(StringComparer.OrdinalIgnoreCase);
    private FileSystemWatcher _targetsWatcher = null;
    private long _earliestTicks = 0;
    private long _latestTicks = 0;
    private bool _hasImmediate = false;
    private bool _overflow = false;
    private bool _targetsDirty = false;
    private string _error = null;

    public int WatcherCount
    {
        get { lock (_lock) { return _watchers.Count; } }
    }

    public static bool IsWatchedPath(string relPath, out bool heartbeat)
    {
        heartbeat = false;
        if (string.IsNullOrEmpty(relPath)) { return false; }
        string rel = relPath.Replace('\\', '/').TrimStart('/');
        if (rel == "handoff-log.md" || rel == "backlog.md") { return true; }
        if (rel.StartsWith("packets/", StringComparison.OrdinalIgnoreCase) && rel.EndsWith(".md", StringComparison.OrdinalIgnoreCase)) { return true; }
        if (rel.StartsWith("archive/", StringComparison.OrdinalIgnoreCase) && rel.EndsWith(".md", StringComparison.OrdinalIgnoreCase)) { return true; }
        if (rel.StartsWith("logs/", StringComparison.OrdinalIgnoreCase))
        {
            string leaf = rel.Substring("logs/".Length);
            if (leaf.EndsWith("-stage-state.json", StringComparison.OrdinalIgnoreCase)) { heartbeat = true; return true; }
            if (leaf.StartsWith(".dispatch-lock-", StringComparison.OrdinalIgnoreCase)) { heartbeat = true; return true; }
            if (leaf.StartsWith(".dispatch-", StringComparison.OrdinalIgnoreCase)) { return true; }
            if (leaf.EndsWith("-approval.json", StringComparison.OrdinalIgnoreCase)) { return true; }
            if (leaf.EndsWith("-chain-runtime.json", StringComparison.OrdinalIgnoreCase)) { return true; }
            if (leaf.Equals(".session-health.json", StringComparison.OrdinalIgnoreCase)) { return true; }
        }
        return false;
    }

    public void Configure(string[] roots)
    {
        HashSet<string> desired = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        if (roots != null) { foreach (string r in roots) { if (!string.IsNullOrEmpty(r)) { desired.Add(r); } } }
        lock (_lock)
        {
            List<string> remove = new List<string>();
            foreach (KeyValuePair<string, FileSystemWatcher> kv in _watchers) { if (!desired.Contains(kv.Key)) { remove.Add(kv.Key); } }
            foreach (string key in remove) { RemoveWatcherLocked(key); }
        }
        foreach (string root in desired)
        {
            lock (_lock) { if (_watchers.ContainsKey(root)) { continue; } }
            if (!Directory.Exists(root)) { continue; }
            try
            {
                FileSystemWatcher w = new FileSystemWatcher(root);
                w.Filter = "*";
                w.IncludeSubdirectories = true;
                w.NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size;
                w.Created += OnFsEvent;
                w.Changed += OnFsEvent;
                w.Deleted += OnFsEvent;
                w.Renamed += OnRenamed;
                w.Error += OnError;
                w.EnableRaisingEvents = true;
                lock (_lock)
                {
                    if (_watchers.ContainsKey(root)) { w.Dispose(); }
                    else { _watchers[root] = w; }
                }
            }
            catch (Exception ex) { RecordError(ex.Message); }
        }
    }

    public void ConfigureTargetsWatch(string filePath)
    {
        lock (_lock) { RemoveTargetsWatcherLocked(); }
        if (string.IsNullOrEmpty(filePath) || !File.Exists(filePath)) { return; }
        try
        {
            string dir = Path.GetDirectoryName(filePath);
            FileSystemWatcher w = new FileSystemWatcher(dir);
            w.Filter = Path.GetFileName(filePath);
            w.IncludeSubdirectories = false;
            w.NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size;
            w.Changed += OnTargetsEvent;
            w.Created += OnTargetsEvent;
            w.Deleted += OnTargetsEvent;
            w.Renamed += OnTargetsRenamed;
            w.Error += OnError;
            w.EnableRaisingEvents = true;
            lock (_lock) { _targetsWatcher = w; }
        }
        catch (Exception ex) { RecordError(ex.Message); }
    }

    private void OnTargetsEvent(object sender, FileSystemEventArgs e) { lock (_lock) { _targetsDirty = true; } }
    private void OnTargetsRenamed(object sender, RenamedEventArgs e) { lock (_lock) { _targetsDirty = true; } }

    private static string RelativeOf(FileSystemWatcher w, string fullPath)
    {
        string root = w.Path;
        if (!root.EndsWith(Path.DirectorySeparatorChar.ToString())) { root += Path.DirectorySeparatorChar; }
        if (fullPath.StartsWith(root, StringComparison.OrdinalIgnoreCase)) { return fullPath.Substring(root.Length); }
        return fullPath;
    }

    private void OnFsEvent(object sender, FileSystemEventArgs e)
    {
        FileSystemWatcher w = sender as FileSystemWatcher;
        if (w == null) { return; }
        bool heartbeat;
        if (!IsWatchedPath(RelativeOf(w, e.FullPath), out heartbeat)) { return; }
        bool changed = (e.ChangeType == WatcherChangeTypes.Changed);
        Record(!(changed && heartbeat));
    }

    private void OnRenamed(object sender, RenamedEventArgs e)
    {
        FileSystemWatcher w = sender as FileSystemWatcher;
        if (w == null) { return; }
        bool heartbeat;
        if (!IsWatchedPath(RelativeOf(w, e.FullPath), out heartbeat)) { return; }
        Record(true);
    }

    private void OnError(object sender, ErrorEventArgs e)
    {
        Exception ex = e.GetException();
        lock (_lock)
        {
            if (ex is InternalBufferOverflowException) { _overflow = true; }
            if (ex != null) { _error = ex.Message; }
        }
    }

    private void Record(bool immediate)
    {
        long now = DateTime.UtcNow.Ticks;
        lock (_lock)
        {
            if (_earliestTicks == 0) { _earliestTicks = now; }
            _latestTicks = now;
            if (immediate) { _hasImmediate = true; }
        }
    }

    private void RecordError(string message)
    {
        lock (_lock) { _error = message; }
    }

    private void RemoveWatcherLocked(string key)
    {
        FileSystemWatcher w;
        if (!_watchers.TryGetValue(key, out w)) { return; }
        try
        {
            w.EnableRaisingEvents = false;
            w.Created -= OnFsEvent;
            w.Changed -= OnFsEvent;
            w.Deleted -= OnFsEvent;
            w.Renamed -= OnRenamed;
            w.Error -= OnError;
            w.Dispose();
        }
        catch { }
        _watchers.Remove(key);
    }

    private void RemoveTargetsWatcherLocked()
    {
        if (_targetsWatcher == null) { return; }
        try
        {
            _targetsWatcher.EnableRaisingEvents = false;
            _targetsWatcher.Changed -= OnTargetsEvent;
            _targetsWatcher.Created -= OnTargetsEvent;
            _targetsWatcher.Deleted -= OnTargetsEvent;
            _targetsWatcher.Renamed -= OnTargetsRenamed;
            _targetsWatcher.Error -= OnError;
            _targetsWatcher.Dispose();
        }
        catch { }
        _targetsWatcher = null;
    }

    public object[] SnapshotAndClear()
    {
        lock (_lock)
        {
            object[] snap = new object[] { _earliestTicks, _latestTicks, _hasImmediate, _overflow, _error, _targetsDirty, _watchers.Count };
            _earliestTicks = 0;
            _latestTicks = 0;
            _hasImmediate = false;
            _overflow = false;
            _error = null;
            _targetsDirty = false;
            return snap;
        }
    }

    public void DisposeAll()
    {
        lock (_lock)
        {
            List<string> keys = new List<string>(_watchers.Keys);
            foreach (string key in keys) { RemoveWatcherLocked(key); }
            RemoveTargetsWatcherLocked();
        }
    }
}
'@

if ($MyInvocation.InvocationName -ne '.' -and ($MyInvocation.Line -notmatch '^\s*\.\s' -or $MyInvocation.Line -eq $null)) {
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
$harnessBadge.AccessibleName = '하네스 동기화 상태 (진짜 드리프트·배포 대기·락 지연·오버라이드·정본 편집 중)'
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
        Request-DashboardRefresh -Queue
    }
})
$radioAll.Add_CheckedChanged({
    if ($radioAll.Checked) {
        $script:showAllFilter = $true
        Request-DashboardRefresh -Queue
    }
})
# 강제 새로고침 공통 핸들러 — 버튼 클릭과 F5 모두 이 경로를 탄다.
$refreshAction = {
    # 수집이 진행 중이면 끝난 직후 한 번 더 돌도록 예약만 하고, 버튼은 수집이 끝날 때까지 비활성화한다.
    $refreshButton.Enabled = $false
    Request-DashboardRefresh -Queue
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
# 디스크·프로세스 스캔(갱신 1회 ~1초)은 화면 스레드에서 돌리면 그동안 클릭·마우스 입력이 멈춘다.
# 그래서 수집은 별도 runspace에서 하고, 화면 스레드는 끝난 결과만 그린다.
# runspace는 한 번 만들어 재사용한다 — 파일 파싱 캐시(FileParseCache 등)가 갱신 사이에 유지된다.
$script:dashRunspace = $null
$script:dashPs = $null
$script:dashHandle = $null
$script:dashQueued = $false
$script:dashLoaded = $false
# CFG111 lifecycle: idle → collecting → (completed | stopping → idle/fault).
$script:dashPhase = 'idle'
$script:dashGeneration = 0
$script:dashStartedAt = $null
$script:dashStopAsync = $null
$script:dashStopStartedAt = $null
$script:dashConsecutiveTimeouts = 0
$script:dashHasLive = $false
# CFG111 이벤트 스케줄: 브리지가 회수한 dirty를 PS 쪽에 누적하고 debounce로 요청한다.
$script:dashDirtyFirst = $null
$script:dashDirtyLast = $null
$script:dashLastVisible = $true
$script:dashWatchError = $null
$script:dashWatchOverflow = $false
$script:dashWatchDegraded = $false
$script:dashWatchLastRecovery = [datetime]::MinValue
$script:watcherBridge = $null

# CFG111: C# 브리지 컴파일(형식 존재 검사로 중복 로드 방지). PS 5.1 C# 컴파일러 문법만 사용한다.
if (-not ([System.Management.Automation.PSTypeName]'DashboardWatcherBridge').Type) {
    try { Add-Type -TypeDefinition $script:DashboardWatcherBridgeSource -ErrorAction Stop } catch { $script:dashWatchError = $_.Exception.Message }
}
try { $script:watcherBridge = New-Object DashboardWatcherBridge } catch { $script:watcherBridge = $null; $script:dashWatchError = $_.Exception.Message }

function Update-DashboardWatchers {
    # briefs 감시 집합을 현재 프로젝트 목록으로 교체하고, harness-targets.txt는 별도 watcher로 감시한다.
    if (-not $script:watcherBridge) { return }
    try {
        $roots = @(Get-HarnessProjects | ForEach-Object { Join-Path $_ '.agents\briefs' })
        $script:watcherBridge.Configure([string[]]$roots)
        $script:watcherBridge.ConfigureTargetsWatch((Join-Path $root 'harness-targets.txt'))
    } catch {
        $script:dashWatchError = $_.Exception.Message
        $script:dashWatchDegraded = $true
    }
}
Update-DashboardWatchers

function Request-DashboardRefresh {
    param([switch]$Queue)
    $outcome = Resolve-DashboardRequestOutcome -Phase $script:dashPhase
    if ($outcome -eq 'blocked') {
        # fault/stopping(정리 완료 전) 상태에서는 수집을 시작할 수 없다 — 재시작만이 복구 수단(CR07).
        $script:dashQueued = $false
        return
    }
    if ($outcome -eq 'queue') {
        # 이미 수집 중이면 겹쳐 돌리지 않는다. 수동·이벤트 요청은 끝난 직후 한 번 더 돌도록 예약만 한다.
        if ($Queue) { $script:dashQueued = $true }
        return
    }
    if (-not $script:dashRunspace) {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::MTA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
        $rs.Open()
        $script:dashRunspace = $rs
    }
    $ps = [powershell]::Create()
    $ps.Runspace = $script:dashRunspace
    # 첫 수집에서만 이 스크립트를 dot-source해 함수를 올린다(dot-source 안전 — 본체 GUI는 실행되지 않는다).
    # 한 스크립트 안에서 dot-source와 호출을 같이 한다. AddStatement로 나누거나 param/AddArgument를 쓰면
    # runspace가 응답 없이 멈추는 것을 실측했다(2026-10-07) — 플래그는 리터럴로 박아 넣는다.
    $callText = if ($script:showAllFilter) { 'Get-DashboardData -ShowAll:$true' } else { 'Get-DashboardData -ShowAll:$false' }
    # 수집은 배경 작업이므로 다른 프로그램과 CPU를 다툴 때 양보한다(ReuseThread라 한 번 낮추면 유지된다).
    $callText = '[System.Threading.Thread]::CurrentThread.Priority = ''BelowNormal''; ' + $callText
    if (-not $script:dashLoaded) {
        $callText = ". '{0}'; {1}" -f ($PSCommandPath -replace "'", "''"), $callText
    }
    [void]$ps.AddScript($callText)
    $script:dashPs = $ps
    $script:dashGeneration++
    $script:dashStartedAt = [System.Diagnostics.Stopwatch]::StartNew()
    $script:dashPhase = 'collecting'
    $script:dashHandle = $ps.BeginInvoke()
}

function Reset-DashboardRunspace {
    # CR08: 재생성 때 runspace를 닫고 dashLoaded=false로 초기화한다(다음 수집에서 dot-source+Get-DashboardData 재실행).
    if ($script:dashRunspace) {
        try { $script:dashRunspace.Dispose() } catch { }
        $script:dashRunspace = $null
    }
    $script:dashLoaded = $false
}

function Start-DashboardCollectionStop {
    # 30초 초과: 기존 결과를 무효화(generation 증가)하고 BeginStop으로 비동기 중단한다(UI 대기 없음).
    $script:dashGeneration++
    $script:dashConsecutiveTimeouts++
    $script:dashPhase = 'stopping'
    $script:dashStopStartedAt = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $script:dashStopAsync = $script:dashPs.BeginStop($null, $null)
    } catch {
        $script:dashStopAsync = $null
        Enter-DashboardFault -Reason ('수집 중단 요청 실패: ' + $_.Exception.Message)
    }
}

function Complete-DashboardStopCleanup {
    # 중단이 완료됨(IsCompleted) — EndStop·EndInvoke 예외 수거·Dispose 후 runspace 재생성.
    $ps = $script:dashPs
    $async = $script:dashStopAsync
    if ($ps) {
        try { if ($async) { $ps.EndStop($async) } } catch { }
        try { [void]$ps.EndInvoke($script:dashHandle) } catch { }
        try { $ps.Dispose() } catch { }
    }
    $script:dashPs = $null
    $script:dashHandle = $null
    $script:dashStopAsync = $null
    $script:dashStopStartedAt = $null
    Reset-DashboardRunspace
    $script:dashPhase = 'idle'
    $refreshButton.Enabled = $true
    if (Get-DashboardTimeoutRetryDecision -ConsecutiveTimeouts $script:dashConsecutiveTimeouts) {
        # 중단 유예 5초 이내 정상 정리 → 최신 필터로 자동 재수집 1회.
        $updatedLabel.Text = '데이터 수집 타임아웃 — 자동 재수집 중...'
        Request-DashboardRefresh
    } else {
        # 연속 타임아웃: 자동 재시도 중지, F5로만 명시 재시도(CR07).
        $updatedLabel.Text = '데이터 수집 타임아웃이 연속 발생했습니다 — F5로 명시 재시도하세요.'
    }
}

function Enter-DashboardFault {
    # 중단 자체가 5초를 넘거나 중단 요청이 실패: 수집 핸들을 활성 슬롯에서 분리하고 fault로 전환한다.
    # 기존 화면·시계·재시작 버튼은 유지하고 새 runspace를 계속 만들지 않는다 — 재시작 버튼이 복구 수단이다.
    param([string]$Reason)
    $script:dashPs = $null
    $script:dashHandle = $null
    $script:dashStopAsync = $null
    $script:dashStopStartedAt = $null
    $script:dashRunspace = $null
    $script:dashLoaded = $false
    $script:dashPhase = 'fault'
    $script:dashQueued = $false
    $refreshButton.Enabled = $false
    $updatedLabel.Text = '데이터 수집 복구 실패 — [↺ 대시보드 재시작]을 사용하세요.'
    if ($Reason) { Write-Host $Reason }
}

function Update-DashboardEventSchedule {
    # 200ms 틱마다: 브리지 dirty 회수 → debounce 판정 → 요청. heartbeat는 live 중 병합하고
    # 유휴에서만 즉시 경로를 탄다(CR09).
    if ($script:watcherBridge) {
        try {
            $snap = $script:watcherBridge.SnapshotAndClear()
            if ($snap) {
                $earliest = [long]$snap[0]
                $latest = [long]$snap[1]
                $immediate = [bool]$snap[2]
                $overflow = [bool]$snap[3]
                $err = $snap[4]
                $targetsDirty = [bool]$snap[5]
                $script:dashWatchOverflow = $overflow
                if ($overflow) { $script:dashWatchDegraded = $true }
                if ($err) { $script:dashWatchError = [string]$err; $script:dashWatchDegraded = $true }
                if ($targetsDirty) {
                    # 대상 목록 변경 → 감시 집합 재구성 + 즉시 갱신.
                    Update-DashboardWatchers
                    if (-not $script:dashDirtyFirst) { $script:dashDirtyFirst = [datetime]::UtcNow }
                    $script:dashDirtyLast = [datetime]::UtcNow
                }
                # heartbeat-only(Changed on lock/stage-state)는 live 중 무시하고 유휴에서만 actionable(CR09).
                $actionable = $immediate -or (-not $script:dashHasLive)
                if ($earliest -gt 0 -and $actionable) {
                    $e = [datetime]::FromFileTimeUtc($earliest)
                    $l = [datetime]::FromFileTimeUtc($latest)
                    if (-not $script:dashDirtyFirst -or $e -lt $script:dashDirtyFirst) { $script:dashDirtyFirst = $e }
                    if (-not $script:dashDirtyLast -or $l -gt $script:dashDirtyLast) { $script:dashDirtyLast = $l }
                }
            }
        } catch {
            $script:dashWatchError = $_.Exception.Message
            $script:dashWatchDegraded = $true
        }
    }

    # 가시성 전환 감지 — SizeChanged만으로 cloaked 해제를 놓치지 않도록 pollTimer에서 비교한다.
    $visible = -not (Test-DashboardHidden)
    if ($visible -and -not $script:dashLastVisible -and $script:dashPhase -eq 'idle') {
        # 복원/가상 데스크톱 복귀 → 1초 이내 한 번 요청.
        $script:dashLastVisible = $visible
        Request-DashboardRefresh -Queue
        return
    }
    $script:dashLastVisible = $visible

    if ($script:dashWatchDegraded) {
        # 감시가 불완전한 동안에는 폴링을 기존 주기로 되돌리고(빠른 보완), 90초마다 watcher 복구를 시도한다.
        $timer.Interval = ([math]::Max(1, $IntervalSeconds)) * 1000
        $suffix = if ($script:dashWatchOverflow) { ' · 감시 버퍼 overflow(폴링 복구)' } else { ' · 감시 열화' }
        if ($updatedLabel.Text -notlike ('*' + $suffix + '*')) { $updatedLabel.Text = $updatedLabel.Text + $suffix }
        if (([datetime]::UtcNow - $script:dashWatchLastRecovery).TotalSeconds -ge 90) {
            if ($script:dashWatchOverflow -and $script:watcherBridge) { try { $script:watcherBridge.DisposeAll() } catch { } }
            Update-DashboardWatchers
            $script:dashWatchLastRecovery = [datetime]::UtcNow
            if (-not $script:dashWatchError) { $script:dashWatchDegraded = $false; $script:dashWatchOverflow = $false }
        }
    }

    if ($null -eq $script:dashDirtyFirst) { return }
    if ($script:dashPhase -eq 'collecting') {
        # 수집 중이면 끝난 뒤 한 번 더 돌도록 예약만 한다(대기 요청 최대 1개).
        $script:dashQueued = $true
        $script:dashDirtyFirst = $null
        $script:dashDirtyLast = $null
        return
    }
    if ($script:dashPhase -ne 'idle') { return }   # stopping/fault: 수집 불가 — dirty를 유지해 복구 후 반영한다.
    if (Get-DashboardRefreshDecision -Dirty $true -Visible $visible -Collecting $false -FirstDirtyAt $script:dashDirtyFirst -LastDirtyAt $script:dashDirtyLast -Now ([datetime]::UtcNow)) {
        $script:dashDirtyFirst = $null
        $script:dashDirtyLast = $null
        Request-DashboardRefresh
    }
}

function Complete-DashboardRefresh {
    # stopping: 완료/유예만 확인한다(비동기 — UI 블로킹 없음).
    if ($script:dashPhase -eq 'stopping') {
        if ($script:dashStopAsync -and $script:dashStopAsync.IsCompleted) {
            Complete-DashboardStopCleanup
        } elseif ($script:dashStopStartedAt -and (Resolve-DashboardCollectionTimeout -Phase 'stopping' -CollectingMs 0 -StoppingMs $script:dashStopStartedAt.Elapsed.TotalMilliseconds) -eq 'fault') {
            Enter-DashboardFault -Reason '수집 중단이 5초를 넘겨 정리하지 못했습니다.'
        }
        return
    }
    if ($script:dashPhase -eq 'fault') { return }

    # collecting: 30초 초과면 중단 시작.
    if ($script:dashPhase -eq 'collecting' -and $script:dashHandle -and $script:dashStartedAt) {
        if ((Resolve-DashboardCollectionTimeout -Phase 'collecting' -CollectingMs $script:dashStartedAt.Elapsed.TotalMilliseconds -StoppingMs 0) -eq 'timeout') {
            Start-DashboardCollectionStop
            return
        }
    }

    if (-not $script:dashHandle -or -not $script:dashHandle.IsCompleted) { return }
    $ps = $script:dashPs
    $handle = $script:dashHandle
    $script:dashPs = $null
    $script:dashHandle = $null
    $script:dashStartedAt = $null
    $script:dashPhase = 'idle'
    $data = $null
    $errorText = $null
    try {
        $data = @($ps.EndInvoke($handle) | Where-Object { $_ -and $_.PSObject.Properties['Rows'] }) | Select-Object -Last 1
        if (-not $data) {
            $errorText = if ($ps.Streams.Error.Count -gt 0) { [string]$ps.Streams.Error[0] } else { '결과 없음' }
        } else {
            $script:dashLoaded = $true
            $script:dashConsecutiveTimeouts = 0   # 정상 수집 성공 → 타임아웃 카운터 초기화(CR07).
        }
    } catch {
        $errorText = $_.Exception.Message
    } finally {
        $ps.Dispose()
    }
    $refreshButton.Enabled = $true
    if ($errorText) {
        $updatedLabel.Text = '데이터 갱신 실패: ' + $errorText
    } elseif (Test-DashboardStaleResult -ResultShowAll $data.ShowAll -CurrentShowAll $script:showAllFilter) {
        # 수집 도중 필터가 바뀌었다 — 이 결과는 버리고 현재 필터로 다시 수집한다.
        $script:dashQueued = $true
    } else {
        Update-Dashboard -Grid $grid -EmptyLabel $emptyLabel -UpdatedLabel $updatedLabel -TierBadge $tierBadge -SessionBadge $sessionBadge -ApprovalBadge $approvalBadge -HarnessBadge $harnessBadge -SessionGrid $sessionGrid -ToolTip $toolTip -Data $data
        # RUNNING/live 면 기존 주기(기본 10초), 유휴면 90초 폴링으로 늘린다(CFG111).
        $liveStatuses = @('RUNNING', 'HANG', 'STANDBY', 'STALLED', 'RESUME', 'BLOCKED')
        $hasLive = @($data.Rows | Where-Object { $liveStatuses -contains $_.Status }).Count -gt 0
        $script:dashHasLive = $hasLive
        $timer.Interval = Get-DashboardPollMilliseconds -HasLive $hasLive -IntervalSeconds $IntervalSeconds -IdleSeconds 90
    }
    if ($script:dashQueued) {
        $script:dashQueued = $false
        Request-DashboardRefresh
    }
}
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = Get-DashboardPollMilliseconds -HasLive $false -IntervalSeconds $IntervalSeconds -IdleSeconds 90
# 최소화된 창은 아무도 보지 않으므로 갱신하지 않는다. 복원되면 pollTimer가 가시성 전환을 잡아 갱신한다.
# 최소화되었거나 DWM이 숨김(cloaked: 다른 가상 데스크톱 등)으로 표시한 창은 보는 사람이 없다.
# 다른 창에 단순히 가려진 경우는 공개 API로 판정할 수 없어 갱신을 유지한다.
Add-Type -Namespace DashWin32 -Name Dwm -MemberDefinition '[System.Runtime.InteropServices.DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(System.IntPtr hwnd, int attr, out int value, int size);'
function Test-DashboardHidden {
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) { return $true }
    $cloaked = 0
    try { [void][DashWin32.Dwm]::DwmGetWindowAttribute($form.Handle, 14, [ref]$cloaked, 4) } catch { return $false }
    return ($cloaked -ne 0)
}
# 주기 폴링: live는 기존 주기, 유휴는 90초. hidden이면 새 수집은 보류한다(타임아웃/정리는 pollTimer가 계속 처리).
$timer.Add_Tick({ if (-not (Test-DashboardHidden)) { Request-DashboardRefresh } })
$script:dashLastWindowState = $form.WindowState
$form.Add_SizeChanged({
    $current = $form.WindowState
    if ($script:dashLastWindowState -eq [System.Windows.Forms.FormWindowState]::Minimized -and $current -ne [System.Windows.Forms.FormWindowState]::Minimized) {
        Request-DashboardRefresh -Queue
    }
    $script:dashLastWindowState = $current
})
# 200ms 폴링 틱: 이벤트 스케줄 + 완료/오류/타임아웃 처리(CFG111 — 고정 30초 단조 증가 Stopwatch).
$pollTimer = New-Object System.Windows.Forms.Timer
$pollTimer.Interval = 200
$pollTimer.Add_Tick({ Update-DashboardEventSchedule; Complete-DashboardRefresh })
$clockTimer = New-Object System.Windows.Forms.Timer
$clockTimer.Interval = 1000
$clockTimer.Add_Tick({ $clockLabel.Text = '현재: ' + (Get-Date).ToString('HH:mm:ss KST') })
$updatedLabel.Text = '데이터 수집 중...'
$clockLabel.Text = '현재: ' + (Get-Date).ToString('HH:mm:ss KST')
$timer.Start()
$pollTimer.Start()
$clockTimer.Start()
Request-DashboardRefresh
[void]$form.ShowDialog()
# 종료: 새 수집을 막기 위해 phase를 fault로 전환하고 timer 정지·watcher 해제/Dispose.
# 수집 정리가 지연돼도 폼 종료를 무기한 기다리지 않는다(정상 정리는 비동기 — FormClosed가 기다리지 않음).
$script:dashPhase = 'fault'
$timer.Stop()
$pollTimer.Stop()
$clockTimer.Stop()
if ($script:watcherBridge) { try { $script:watcherBridge.DisposeAll() } catch { } }
if ($script:dashPs) { try { $script:dashPs.Dispose() } catch { } }
if ($script:dashRunspace) { try { $script:dashRunspace.Dispose() } catch { } }
$script:dashPs = $null
$script:dashHandle = $null
$script:dashQueued = $false
}
