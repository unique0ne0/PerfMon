<#
commit-harness-sync.ps1 — sync-configs.ps1 -Push 로 배포된 하네스 사본을 안전하게 커밋하는 헬퍼.

동작: harness-targets.txt 의 각 다운스트림 저장소를 순회하며, 하네스 자산 파일만
      pathspec-scoped 로 커밋한다. 무관한 staged/modified 변경이 있어도 절대 함께 커밋하지 않는다.
      -PushTargets 지정 시에만 원격에 push를 수행한다.
      CFG088: `.gitattributes` 의 `# BEGIN/END harness-generated` 블록 변경도(그 diff의
      추가·삭제 줄이 전부 블록 안에 있을 때만) 같은 커밋에 포함한다. 블록 밖 변경이
      섞이면 .gitattributes만 제외하고 사유를 Detail 에 남긴다.

스킵 사유:
  - skipped-no-repo: 대상 저장소에 .git 이 없거나 디렉터리가 존재하지 않음
  - skipped-locked: 살아있는 디스패치 락이 감지됨
  - deferred-busy: sync-configs.ps1 -Push 가 실행 중 체인 때문에 이번 배포를 지연함(CFG089)
  - nothing-to-commit: 하네스 자산에 변경 없음
  - skipped-unrelated-only: 무관한 파일만 변경됨

출력: 결과 테이블 + JSON 리포트 (global/harness/logs/sync-commit/ 또는 상대 로그 경로)

Windows PowerShell 5.1 호환, UTF-8 + BOM 저장.
#>
[CmdletBinding()]
param(
    [string]$RepoRoot,
    [string]$TargetList,
    # CFG089: sync-configs.ps1 이 실행 중 체인 때문에 이번 Push에서 배포를 지연한 대상 경로 목록
    # (한 줄에 하나). 이 대상은 배포가 없었으니 커밋할 것도 없고, 아래 Test-ActiveLock 이 같은
    # 락을 감지해 하류 skipped-locked(오류 집계)로 오인하는 것도 막는다 — 지연은 실패가 아니다.
    [string]$DeferredTargetList,
    [switch]$DryRun,
    [switch]$PushTargets,
    [string]$CommitMessage
)

$ErrorActionPreference = 'Stop'

# ── 경로 설정 ──────────────────────────────────────────────────────────────────
if ([string]::IsNullOrEmpty($RepoRoot)) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrEmpty($TargetList)) { $TargetList = Join-Path $RepoRoot 'harness-targets.txt' }

$harnessIoModule = Join-Path $PSScriptRoot 'harness-io.ps1'
if (-not (Test-Path -LiteralPath $harnessIoModule)) { $harnessIoModule = Join-Path $RepoRoot 'global\harness\harness-io.ps1' }
if (-not (Test-Path -LiteralPath $harnessIoModule)) { throw "Required harness I/O module not found: $harnessIoModule" }
. $harnessIoModule
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

# ── CFG088: .gitattributes 하네스 블록 변경 감지 ───────────────────────────────
# sync-configs.ps1 의 Set-HarnessGitAttributes(L195 부근)가 하류 .gitattributes 에
# `# BEGIN/END harness-generated` 블록을 갱신하지만, 이 스크립트는 scripts/ 자산만
# pathspec 으로 잡아 그 변경이 영원히 미커밋으로 남았다(CFG-BL-065). 아래 상수는
# sync-configs.ps1 의 $beginMarker/$endMarker 와 반드시 같아야 한다(공유 모듈이 없어
# 상호 참조 주석으로 묶는다 — sync-configs.ps1 도 이 위치를 주석으로 가리킨다).
$HarnessBeginMarker = '# BEGIN harness-generated (managed-by: ai-agents-config sync-configs.ps1 — do not edit by hand)'
$HarnessEndMarker = '# END harness-generated'

# 줄바꿈·BOM을 정규화하고 EOF 뒤쪽 빈 줄을 제거한 줄 배열을 돌려준다.
# git diff 의 줄 번호(1-based)와 배열 인덱스(0-based)를 맞추려면 블록보다 뒤에 있는
# EOF 개행 잔여물을 없애야 한다(블록 앞쪽 인덱스는 영향받지 않는다).
function ConvertTo-NormalizedLines {
    param([string]$Text)
    if ($null -eq $Text) { return ,@() }
    $t = $Text.Replace("`r`n", "`n").Replace("`r", "`n")
    if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
    $list = New-Object System.Collections.ArrayList
    foreach ($ln in @($t -split "`n")) { [void]$list.Add($ln) }
    while ($list.Count -gt 0 -and $list[$list.Count - 1] -eq '') { $list.RemoveAt($list.Count - 1) }
    return ,@($list.ToArray())
}

# 하네스 블록의 줄 범위(0-based 인덱스)를 찾는다. Exact 는 새 파일용으로 마커 전문이
# 정확히 일치해야 하고(손편집 마커를 관리 블록으로 오인하지 않기 위함), 아니면
# `# BEGIN/END harness-generated` 접두 일치로 옛 블록 위치를 잡아 마커 변경을 탐지한다.
function Find-HarnessBlockRange {
    param([string[]]$Lines, [switch]$Exact)
    $begin = -1
    $end = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $t = $Lines[$i].Trim()
        $beginMatch = if ($Exact) { $t -eq $HarnessBeginMarker } else { $t.StartsWith('# BEGIN harness-generated') }
        $endMatch = if ($Exact) { $t -eq $HarnessEndMarker } else { $t.StartsWith('# END harness-generated') }
        if ($begin -lt 0) {
            if ($beginMatch) { $begin = $i }
        } elseif ($endMatch) {
            $end = $i
            break
        }
    }
    if ($begin -lt 0 -or $end -lt 0) { return $null }
    return [pscustomobject]@{ Start = $begin; End = $end }
}

# `.gitattributes` 변경이 하네스 블록 내부에만 있는지 판정한다.
#   Changed       : .gitattributes 에 변경이 있음(status 로 확인)
#   Include       : 같은 커밋 pathspec 에 포함해도 안전(추가·삭제 줄이 전부 블록 내부)
#   OutsideChange : 블록 밖 변경이거나 블록 경계를 신뢰할 수 없음 → 자동 커밋 금지
function Get-GitAttributesDecision {
    param([Parameter(Mandatory)][string]$ProjRoot)

    $decision = [pscustomobject]@{
        Changed       = $false
        Include       = $false
        OutsideChange = $false
    }

    $gaName = '.gitattributes'
    $status = @(Invoke-GitQuiet -ProjRoot $ProjRoot -GitArgs @('status', '--porcelain', '--', $gaName) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($LASTEXITCODE -ne 0) { throw "git status .gitattributes 판정 실패 (exit $LASTEXITCODE)" }
    if ($status.Count -eq 0) { return $decision }
    $decision.Changed = $true

    $gaPath = Join-Path $ProjRoot $gaName
    $newRaw = if (Test-Path -LiteralPath $gaPath) { [System.IO.File]::ReadAllText($gaPath) } else { '' }
    $newLines = ConvertTo-NormalizedLines -Text $newRaw
    $newBlock = Find-HarnessBlockRange -Lines $newLines -Exact
    if ($null -eq $newBlock) {
        # 새 파일에서 관리 블록을 확정할 수 없으면 자동 커밋하지 않는다(수동 확인).
        $decision.OutsideChange = $true
        return $decision
    }

    # HEAD에 파일이 없는 신규 추가와 `git show` 자체의 실패를 구분한다. native git은
    # non-zero exit를 PowerShell 예외로 바꾸지 않으므로 매 호출 직후 명시적으로 검사한다.
    $headEntry = @(Invoke-GitQuiet -ProjRoot $ProjRoot -GitArgs @('ls-tree', '--name-only', 'HEAD', '--', $gaName))
    if ($LASTEXITCODE -ne 0) { throw "git ls-tree .gitattributes 판정 실패 (exit $LASTEXITCODE)" }
    if ($headEntry.Count -gt 0) {
        $oldRaw = (Invoke-GitQuiet -ProjRoot $ProjRoot -GitArgs @('show', ('HEAD:' + $gaName))) -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "git show .gitattributes 판정 실패 (exit $LASTEXITCODE)" }
    } else {
        $oldRaw = ''
    }
    $oldLines = ConvertTo-NormalizedLines -Text $oldRaw
    $oldBlock = if ($oldLines.Count -gt 0) { Find-HarnessBlockRange -Lines $oldLines } else { $null }

    # 블록 마커 줄 자체가 바뀌면 블록 경계를 신뢰할 수 없다 — 블록 밖 변경으로 본다.
    # (아래 diff 루프에서 마커 줄이 변경분에 나타나는지로 판정한다. git show 출력은 콘솔
    #  코드페이지로 디코드돼 비ASCII 부분이 깨질 수 있으므로 마커 텍스트 비교는 하지 않고,
    #  인코딩에 영향받지 않는 ASCII 접두 일치로 확인한다.)
    $isUntracked = ($status[0] -match '^\?\?')
    $markerTouched = $false
    $addedLines = New-Object System.Collections.ArrayList
    $removedLines = New-Object System.Collections.ArrayList
    if ($isUntracked) {
        # 추적 전 새 파일: 전체 내용이 "추가"다. 블록만 있으면 전 줄이 블록 안이다.
        for ($i = 0; $i -lt $newLines.Count; $i++) { [void]$addedLines.Add($i + 1) }
    } else {
        $diff = @(Invoke-GitQuiet -ProjRoot $ProjRoot -GitArgs @('diff', '-U0', 'HEAD', '--no-color', '--', $gaName))
        if ($LASTEXITCODE -ne 0) { throw "git diff .gitattributes 판정 실패 (exit $LASTEXITCODE)" }
        $curOld = 0
        $curNew = 0
        foreach ($dl in $diff) {
            if ($dl -match '^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@') {
                $curOld = [int]$Matches[1]
                $curNew = [int]$Matches[2]
                continue
            }
            if ($dl.StartsWith('---') -or $dl.StartsWith('+++')) { continue }
            if ($dl.StartsWith('+') -or $dl.StartsWith('-')) {
                $content = $dl.Substring(1).Trim()
                # 기존 블록이 있던 파일에서 마커 줄이 추가/삭제되면 마커 자체가 바뀐 것이다.
                if ($null -ne $oldBlock -and
                    ($content.StartsWith('# BEGIN harness-generated') -or $content.StartsWith('# END harness-generated'))) {
                    $markerTouched = $true
                }
                if ($dl.StartsWith('+')) { [void]$addedLines.Add($curNew); $curNew++ }
                else { [void]$removedLines.Add($curOld); $curOld++ }
            }
        }
    }

    if ($markerTouched) {
        $decision.OutsideChange = $true
        return $decision
    }

    foreach ($l in $removedLines) {
        if ($null -eq $oldBlock -or $l -lt ($oldBlock.Start + 1) -or $l -gt ($oldBlock.End + 1)) {
            $decision.OutsideChange = $true
            return $decision
        }
    }
    foreach ($l in $addedLines) {
        if ($l -lt ($newBlock.Start + 1) -or $l -gt ($newBlock.End + 1)) {
            $decision.OutsideChange = $true
            return $decision
        }
    }

    $decision.Include = $true
    return $decision
}

# ── CFG053: Read-HarnessLockFile 공용 함수에 위임 ─────────────────────────
function Test-ActiveLock {
    param([string]$ProjRoot)

    $logDirRel = '.agents\briefs\logs'
    $lockPrefix = '.dispatch-lock'
    $lockDir = Join-Path $ProjRoot $logDirRel
    if (-not (Test-Path $lockDir)) { return $null }

    foreach ($stage in @('impl', 'qa', 'integration')) {
        $lockPath = Join-Path $lockDir "$lockPrefix-$stage"
        $lock = Read-HarnessLockFile -Path $lockPath
        if ($lock -and $lock.Alive) {
            return @{ Stage = $stage; TaskId = $lock.TaskId; ProcId = $lock.ProcessId; StartedAt = $lock.StartedAt }
        }
    }
    return $null
}

# ── 메인 루프 ──────────────────────────────────────────────────────────────────
$results = @()
$targets = Get-HarnessTargets

# CFG089: 지연 대상 집합(정규화된 전체 경로). 파일이 없거나 비면 빈 배열 — 기존 동작과 동일하다.
$deferredTargets = @()
if (-not [string]::IsNullOrWhiteSpace($DeferredTargetList) -and (Test-Path -LiteralPath $DeferredTargetList)) {
    $deferredTargets = @(Get-Content -LiteralPath $DeferredTargetList |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ } |
        ForEach-Object { [System.IO.Path]::GetFullPath($_) })
}

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

    # CFG089: 이번 Push가 실행 중 체인 때문에 지연한 저장소는 배포가 없었으므로 커밋 대상도 없다.
    # 아래 Test-ActiveLock 이 같은 락을 감지해 하류 'skipped-locked'(오류 집계)로 오인하기 전에
    # 여기서 먼저 걸러 'deferred-busy'(비오류)로 표시한다. git 저장소 여부보다 먼저 판정한다 —
    # 지연은 배포 자체가 없었으므로 커밋 상태를 볼 필요가 없다.
    if ($deferredTargets -contains [System.IO.Path]::GetFullPath($proj)) {
        $entry.Status = 'deferred-busy'
        $entry.Detail = '실행 중 파이프라인 체인 — 이번 Push 배포 지연(체인 종료 후 재실행)'
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
        # 잠긴 저장소는 안전하게 건너뛴다. 다만 마지막 exit 판정에서 이 상태를
        # 실패로 집계해 호출자가 배포-커밋이 닫히지 않았음을 알 수 있게 한다.
        $entry.Status = 'skipped-locked'
        $entry.Detail = "활성 락: [$($activeLock.Stage)] 작업 $($activeLock.TaskId), PID $($activeLock.ProcId)"
        $results += $entry
        continue
    }

    # 하네스 자산 경로 (해당 저장소의 scripts/ 아래)
    $assetPaths = @($harnessAssets | ForEach-Object { "scripts/$_" })

    # CFG088: .gitattributes 하네스 블록 변경도 scripts/ 자산과 같은 커밋에 포함한다.
    # 블록 내부 변경일 때만 Include=true 이고, 블록 밖 변경이면 OutsideChange=true 로
    # 자동 커밋을 막고 사유를 Detail 에 남긴다(scripts 자산 커밋은 그대로 진행).
    # 판정 중 예외(파일 잠김 등)는 fail-safe 로 "수동 확인 필요"로 처리한다 — 잘못
    # 자동 커밋하느니 건너뛰고 사유를 남기는 쪽이 안전하다.
    try {
        $gaDecision = Get-GitAttributesDecision -ProjRoot $proj
    } catch {
        $gaDecision = [pscustomobject]@{ Changed = $true; Include = $false; OutsideChange = $true }
    }
    $gaWarning = if ($gaDecision.OutsideChange) { '.gitattributes 블록 밖 변경 — 수동 확인 필요' } else { $null }

    # 전체 상태는 "무관한 변경만 있음"을 구분하는 데만 사용한다. 커밋 대상 판정은
    # 반드시 아래 pathspec-scoped status 결과로만 한다.
    $allStatusOutput = @(Invoke-GitQuiet -ProjRoot $proj -GitArgs @('status', '--porcelain'))

    # git status --porcelain -- <pathspec> 로 하네스 자산만 확인
    $statusOutput = @(Invoke-GitQuiet -ProjRoot $proj -GitArgs (@('status', '--porcelain', '--') + $assetPaths))
    $statusText = ($statusOutput -join "`n").Trim()

    # 변경된 하네스 자산 경로 추출
    $changedAssets = @()
    foreach ($line in $statusOutput) {
        if ($line.Length -lt 4) { continue }
        $filePath = $line.Substring(3).Trim()
        if ($filePath -match '^scripts/(.+)$') {
            $changedAssets += $Matches[1]
        }
    }

    if ([string]::IsNullOrWhiteSpace($statusText) -and -not $gaDecision.Include) {
        if (@($allStatusOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
            $entry.Status = 'skipped-unrelated-only'
            $entry.Detail = if ($gaWarning) { "무관한 파일만 변경됨 — $gaWarning" } else { '무관한 파일만 변경됨' }
        } else {
            $entry.Status = 'nothing-to-commit'
            $entry.Detail = '하네스 자산에 변경 없음'
        }
        $results += $entry
        continue
    }

    # pathspec-scoped 커밋: 하네스 자산 + (블록 내부 변경일 때만) .gitattributes
    $commitPaths = @($changedAssets | ForEach-Object { "scripts/$_" })
    if ($gaDecision.Include) { $commitPaths += '.gitattributes' }

    if ($commitPaths.Count -eq 0) {
        $entry.Status = 'skipped-unrelated-only'
        $entry.Detail = if ($gaWarning) { "무관한 파일만 변경됨 — $gaWarning" } else { '무관한 파일만 변경됨' }
        $results += $entry
        continue
    }

    $entry.Files = @($changedAssets)
    if ($gaDecision.Include) { $entry.Files += '.gitattributes' }

    if ($DryRun) {
        $entry.Status = 'dry-run'
        $entry.Detail = "커밋 대상: $($commitPaths -join ', ')"
        $results += $entry
        continue
    }

    try {
        $addArgs = @('add') + $commitPaths
        Invoke-GitQuiet -ProjRoot $proj -GitArgs $addArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git add 실패 (exit $LASTEXITCODE)" }

        $commitMsg = if (-not [string]::IsNullOrWhiteSpace($CommitMessage)) {
            $CommitMessage
        } else {
            "chore(harness): sync harness assets from ai-agents-config`n`nAssets: $($commitPaths -join ', ')"
        }
        $commitArgs = @('commit', '-m', $commitMsg, '--') + $commitPaths
        Invoke-GitQuiet -ProjRoot $proj -GitArgs $commitArgs | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "git commit 실패 (exit $LASTEXITCODE)" }

        if ($PushTargets) {
            Invoke-GitQuiet -ProjRoot $proj -GitArgs @('push') | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "git push 실패 (exit $LASTEXITCODE)" }
            $entry.Status = 'committed'
            $entry.Detail = "커밋 및 푸시 완료: $($commitPaths -join ', ')"
        } else {
            $entry.Status = 'committed'
            $entry.Detail = "커밋 완료: $($commitPaths -join ', ')"
        }
    } catch {
        $entry.Status = 'error'
        $entry.Detail = $_.Exception.Message
    }

    if ($gaWarning -and $entry.Status -ne 'error') { $entry.Detail = "$($entry.Detail) — $gaWarning" }

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
        'deferred-busy'       { 'Yellow' }
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

$canonicalRepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
# 현재 파이프라인이 실행 중인 정본 저장소는 자기 락 때문에 사본 커밋을 할 수 없다.
# 정본은 이후 Integration에서 커밋하므로 이 한 대상의 skipped-locked는 정상이다.
# 반대로 하류 대상의 락은 배포-커밋 미완료이므로 성공으로 숨기지 않는다.
$hasErrors = @($results | Where-Object {
    $_.Status -eq 'error' -or
    ($_.Status -eq 'skipped-locked' -and [System.IO.Path]::GetFullPath($_.Repo) -ne $canonicalRepoRoot)
}).Count -gt 0
if ($hasErrors) { exit 1 }
exit 0
