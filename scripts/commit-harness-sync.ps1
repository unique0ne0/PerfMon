<#
commit-harness-sync.ps1 — sync-configs.ps1 -Push 로 배포된 하네스 사본을 안전하게 커밋하는 헬퍼.

동작: harness-targets.txt 의 각 다운스트림 저장소를 순회하며, 하네스 자산 파일만
      pathspec-scoped 로 커밋한다. 무관한 staged/modified 변경이 있어도 절대 함께 커밋하지 않는다.
      자동 push는 하지 않는다 — 커밋까지만 수행하고 push는 사용자/오케스트레이터의 별도 확인을 거친다.

스킵 사유:
  - no-git-repo: 대상 저장소에 .git 이 없음
  - active-pipeline-lock: 살아있는 디스패치 락이 감지됨
  - nothing-to-commit: 하네스 자산에 변경 없음
  - skipped-unrelated-only: 무관한 파일만 변경됨

출력: 결과 테이블 + JSON 리포트 (global/harness/logs/sync-commit/ 또는 상대 로그 경로)

Windows PowerShell 5.1 호환, UTF-8 + BOM 저장.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$TargetList,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ── 경로 설정 ──────────────────────────────────────────────────────────────────
if ([string]::IsNullOrEmpty($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrEmpty($TargetList)) { $TargetList = Join-Path $RepoRoot 'harness-targets.txt' }

# CFG044: 커밋 대상 자산도 sync-configs.ps1과 같은 매니페스트(global/harness/harness-assets.txt)를
# 읽는다. 매니페스트 자체(harness-assets.txt 항목)도 함께 배포·커밋되므로 이 목록을 유일 원천으로 쓴다.
function Read-HarnessAssets {
    param([string]$ManifestPath)
    $assets = @()
    if (-not (Test-Path -LiteralPath $ManifestPath)) { return $assets }
    foreach ($line in @(Get-Content -LiteralPath $ManifestPath -Encoding UTF8)) {
        $name = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($name) -or $name.StartsWith('#')) { continue }
        if ($name -match '[/\\]' -or $name -eq '.' -or $name -eq '..' -or $name -like '..*') { continue }
        if ($assets -notcontains $name) { $assets += $name }
    }
    return $assets
}
$harnessAssets = @(Read-HarnessAssets -ManifestPath (Join-Path $RepoRoot 'global\harness\harness-assets.txt'))

$logDir = Join-Path $RepoRoot 'global\harness\logs\sync-commit'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $logDir "sync-commit-$stamp.json"

# ── 대상 목록 읽기 ──────────────────────────────────────────────────────────────
function Get-HarnessTargets {
    if (-not (Test-Path $TargetList)) { return @() }
    return @(
        Get-Content $TargetList |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') }
    )
}

# ── native git 호출 헬퍼 ──────────────────────────────────────────────────────
# PS 5.1 + $ErrorActionPreference='Stop' 조합에서는 git이 stderr에 쓰는 비치명적
# 경고(예: LF/CRLF 줄바꿈 변환 안내)조차 터미네이팅 에러로 승격된다 — 2>$null로
# 리다이렉트해도 승격은 stderr 라인 처리 시점에 먼저 일어나 리다이렉트보다 앞선다.
# 그래서 이 헬퍼 안에서만 EAP를 로컬로 완화하고, 실패 판정은 원래 로직대로
# $LASTEXITCODE로만 한다(예외에 의존하지 않음).
function Invoke-GitQuiet {
    param(
        [Parameter(Mandatory)][string]$ProjRoot,
        [Parameter(Mandatory)][string[]]$GitArgs
    )
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & git -C $ProjRoot @GitArgs 2>$null
    } finally {
        $ErrorActionPreference = $prevEAP
    }
}

# ── 락 마커 감지 (Read-DispatchLock 과 동일한 이중 검증) ─────────────────────────
# dispatch-with-hang-detect.ps1 의 Read-DispatchLock 을 dot-source 하지 않고,
# 같은 판정 로직(PID 존재 + StartTime 일치)을 독립 구현한다.
function Test-ActiveLock {
    param([string]$ProjRoot)

    $logDirRel = '.agents\briefs\logs'
    $lockPrefix = '.dispatch-lock'
    $lockDir = Join-Path $ProjRoot $logDirRel
    if (-not (Test-Path $lockDir)) { return $null }

    foreach ($stage in @('impl', 'qa', 'integration')) {
        $lockPath = Join-Path $lockDir "$lockPrefix-$stage"
        if (-not (Test-Path $lockPath)) { continue }
        $raw = $null
        try { $raw = (Get-Content $lockPath -Raw -ErrorAction SilentlyContinue) } catch { continue }
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }
        $parts = $raw.Trim() -split '\|'
        if ($parts.Count -lt 3) { continue }
        $procId = 0
        if (-not [int]::TryParse($parts[0], [ref]$procId)) { continue }
        $process = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if ($null -eq $process) { continue }
        # StartTime 이중 검증
        if ($parts.Count -ge 5) {
            try {
                [datetime]$recordedStart = [datetime]::MinValue
                if (-not [datetime]::TryParse($parts[4], [ref]$recordedStart)) { continue }
                if ([math]::Abs(($process.StartTime - $recordedStart).TotalSeconds) -gt 2) { continue }
            } catch { continue }
        }
        return @{ Stage = $stage; TaskId = $parts[1]; ProcId = $procId; StartedAt = $parts[2] }
    }
    return $null
}

# ── 메인 루프 ──────────────────────────────────────────────────────────────────
$results = @()
$targets = Get-HarnessTargets

foreach ($proj in $targets) {
    $entry = [pscustomobject]@{
        Repo     = $proj
        Status   = $null
        Detail   = $null
        Files    = @()
    }

    if (-not (Test-Path $proj)) {
        $entry.Status = 'skipped-no-repo'
        $entry.Detail = '대상 경로가 존재하지 않음'
        $results += $entry
        continue
    }

    $gitDir = Join-Path $proj '.git'
    if (-not (Test-Path $gitDir)) {
        $entry.Status = 'skipped-no-repo'
        $entry.Detail = '.git 디렉터리 없음'
        $results += $entry
        continue
    }

    # 활성 락 검사
    $activeLock = Test-ActiveLock -ProjRoot $proj
    if ($null -ne $activeLock) {
        $entry.Status = 'skipped-locked'
        $entry.Detail = "활성 락: [$($activeLock.Stage)] 작업 $($activeLock.TaskId), PID $($activeLock.ProcId)"
        $results += $entry
        continue
    }

    # 하네스 자산 경로 (해당 저장소의 scripts/ 아래)
    $assetPaths = @($harnessAssets | ForEach-Object { "scripts/$_" })

    # 전체 상태는 "무관한 변경만 있음"을 구분하는 데만 사용한다. 커밋 대상 판정은
    # 반드시 아래 pathspec-scoped status 결과로만 한다.
    $allStatusOutput = @(Invoke-GitQuiet -ProjRoot $proj -GitArgs @('status', '--porcelain'))

    # git status --porcelain -- <pathspec> 로 하네스 자산만 확인
    $statusOutput = @(Invoke-GitQuiet -ProjRoot $proj -GitArgs (@('status', '--porcelain', '--') + $assetPaths))
    $statusText = ($statusOutput -join "`n").Trim()

    if ([string]::IsNullOrWhiteSpace($statusText)) {
        if (@($allStatusOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            $entry.Status = 'skipped-unrelated-only'
            $entry.Detail = '무관한 파일만 변경됨'
        } else {
            $entry.Status = 'nothing-to-commit'
            $entry.Detail = '하네스 자산에 변경 없음'
        }
        $results += $entry
        continue
    }

    # 변경된 하네스 자산 경로 추출
    $changedAssets = @()
    foreach ($line in $statusOutput) {
        if ($line.Length -lt 4) { continue }
        $filePath = $line.Substring(3).Trim()
        if ($filePath -match '^scripts/(.+)$') {
            $changedAssets += $Matches[1]
        }
    }

    if ($changedAssets.Count -eq 0) {
        $entry.Status = 'skipped-unrelated-only'
        $entry.Detail = '무관한 파일만 변경됨'
        $results += $entry
        continue
    }

    $entry.Files = $changedAssets

    if ($DryRun) {
        $entry.Status = 'dry-run'
        $entry.Detail = "커밋 대상: $($changedAssets -join ', ')"
        $results += $entry
        continue
    }

    # pathspec-scoped 커밋: git add + git commit 에서 하네스 자산 경로만 지정
    $commitPaths = @($changedAssets | ForEach-Object { "scripts/$_" })
    try {
        $addArgs = @('add') + $commitPaths
        Invoke-GitQuiet -ProjRoot $proj -GitArgs $addArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git add 실패 (exit $LASTEXITCODE)" }

        $commitMsg = "chore(harness): sync harness assets from ai-agents-config`n`nAssets: $($changedAssets -join ', ')"
        $commitArgs = @('commit', '-m', $commitMsg, '--') + $commitPaths
        Invoke-GitQuiet -ProjRoot $proj -GitArgs $commitArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git commit 실패 (exit $LASTEXITCODE)" }

        $entry.Status = 'committed'
        $entry.Detail = "커밋 완료: $($changedAssets -join ', ')"
    } catch {
        $entry.Status = 'error'
        $entry.Detail = $_.Exception.Message
    }

    $results += $entry
}

# ── 결과 출력 ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "== Harness Sync Commit Results ==" -ForegroundColor Cyan
foreach ($r in $results) {
    $color = switch ($r.Status) {
        'committed'           { 'Green' }
        'nothing-to-commit'   { 'DarkGray' }
        'skipped-no-repo'     { 'Yellow' }
        'skipped-locked'      { 'Yellow' }
        'skipped-unrelated-only' { 'Yellow' }
        'dry-run'             { 'Cyan' }
        'error'               { 'Red' }
        default               { 'White' }
    }
    $filesStr = if ($r.Files.Count -gt 0) { " ($($r.Files -join ', '))" } else { '' }
    Write-Host ("  [{0}] {1}{2} — {3}" -f $r.Status, $r.Repo, $filesStr, $r.Detail) -ForegroundColor $color
}

# ── JSON 리포트 ────────────────────────────────────────────────────────────────
$report = [pscustomobject]@{
    Timestamp = (Get-Date).ToString('o')
    DryRun    = $DryRun.IsPresent
    Targets   = $results
}
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host ""
Write-Host "리포트: $reportPath" -ForegroundColor Cyan

$hasErrors = @($results | Where-Object { $_.Status -eq 'error' }).Count -gt 0
if ($hasErrors) { exit 1 }
exit 0
