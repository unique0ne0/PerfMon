# Harness contracts module — packet and TaskId pure contract functions.
# This module is self-contained and exposes pure contract functions only.

function Get-NormalizedTaskId {
    param([string]$TaskId)
    if ($null -eq $TaskId) { return '' }
    return ($TaskId -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
}

# CFG096: 어댑터(실행 CLI)→소속 팀 매핑의 단일 정본. 대시보드(task-status.ps1)와 라우터 다음
# 단계 라벨(harness-ledger.ps1)이 같은 표를 공유한다 — UI 스크립트가 하네스 백엔드 함수를
# 참조하는 의존성 역전을 없애고, 매핑 중복 드리프트를 막는다.
# antigravity(agy)는 개발2팀(Gemini)의 실행 레이어다(WorldSaju WS001 실측: gemini-3.8-flash).
function Get-AdapterTeamMap {
    return @{
        opencode    = '개발1팀'
        codex       = 'QA팀'
        claude      = '기획팀'
        gemini      = '개발2팀'
        antigravity = '개발2팀'
    }
}

function Get-TeamByAdapter {
    param([string]$Adapter)
    if ([string]::IsNullOrWhiteSpace($Adapter)) { return $null }
    $map = Get-AdapterTeamMap
    $key = $Adapter.Trim().ToLowerInvariant()
    if ($map.ContainsKey($key)) { return $map[$key] }
    return $null
}

function Get-PlanningChallengeReviewStatus {
    param([string]$PacketPath)
    $result = [ordered]@{
        Present = $false
        Legacy = $true
        Decision = $null
        Ready = $true
        Reason = $null
    }
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return [pscustomobject]$result }

    $text = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8
    $section = [regex]::Match($text, '(?ms)^##\s+Planning Challenge Review\s*$\r?\n(.*?)(?=^##\s+|\z)')
    if (-not $section.Success) { return [pscustomobject]$result }

    $result.Present = $true
    $result.Legacy = $false
    $decision = [regex]::Match($section.Groups[1].Value, '(?im)^-\s*Decision\s*:\s*`?([^`\r\n]+?)`?\s*$')
    if (-not $decision.Success) {
        $result.Ready = $false
        $result.Reason = 'planning_challenge_decision_missing'
        return [pscustomobject]$result
    }

    $result.Decision = $decision.Groups[1].Value.Trim().ToLowerInvariant()
    if ($result.Decision -eq 'not-required' -or $result.Decision -eq 'completed') { return [pscustomobject]$result }
    $result.Ready = $false
    $result.Reason = if ($result.Decision -eq 'requested') { 'planning_challenge_pending' } else { 'planning_challenge_decision_invalid' }
    return [pscustomobject]$result
}

function Get-PacketPipelineStatus {
    param([string]$PacketPath)
    $result = @{ Items = @(); FirstUnchecked = $null; HasPipelineStatus = $false }
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return $result }
    $inSection = $false
    foreach ($line in Get-Content -LiteralPath $PacketPath -Encoding UTF8) {
        if ($line -match '^##\s+Pipeline Status\s*$') { $inSection = $true; $result.HasPipelineStatus = $true; continue }
        if ($inSection -and $line -match '^##\s+') { break }
        if (-not $inSection -or $line -notmatch '^\s*-\s*\[([ xX])\]') { continue }
        $stageMatch = [regex]::Match($line, '[①②③④⑤]')
        if (-not $stageMatch.Success) { continue }
        $checked = $Matches[1] -match '[xX]'
        $item = @{ Index = '①②③④⑤'.IndexOf($stageMatch.Value) + 1; Label = $line.Trim(); Checked = $checked }
        $result.Items += $item
        if ($null -eq $result.FirstUnchecked -and -not $item.Checked) { $result.FirstUnchecked = $item }
    }
    return $result
}

function Get-RuntimeRoleBinding {
    param([string]$PacketPath)
    $result = [ordered]@{
        Present = $false
        Valid = $false
        Legacy = $true
        PlanningProfile = $null
        PlanningAdapter = $null
        QaProfile = $null
        QaAdapter = $null
        IntegrationProfile = $null
        IntegrationAdapter = $null
        ImplementationRoute = $null
        RoleContentionAck = $null
        Error = $null
    }
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return [pscustomobject]$result }
    $text = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8

    # CFG066 Done When 4: ## Runtime Role Binding 섹션으로 스코프 한정
    # Get-PacketPipelineStatus와 동일 패턴 — Amendments·예시 블록·인용문 매치를 방지한다.
    $sectionMatch = [regex]::Match($text, '(?ms)^##\s+Runtime Role Binding\s*$\r?\n(.*?)(?=^##\s+|\z)')
    if (-not $sectionMatch.Success) { return [pscustomobject]$result }
    $sectionText = $sectionMatch.Groups[1].Value

    $profileMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Actual\s+Planning\s+Profile|actual\s+planning\s+profile)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $adapterMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Actual\s+Planning\s+Adapter|actual\s+planning\s+adapter)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $qaProfileMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Actual\s+QA\s+Profile|actual\s+qa\s+profile)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $qaAdapterMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Actual\s+QA\s+Adapter|actual\s+qa\s+adapter)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $integrationProfileMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Actual\s+Integration\s+Profile|actual\s+integration\s+profile)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $integrationAdapterMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Actual\s+Integration\s+Adapter|actual\s+integration\s+adapter)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $implRouteMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Actual\s+Implementation\s+Route|actual\s+implementation\s+route)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $ackMatch = [regex]::Match($sectionText, '(?im)^-\s*(?:Role\s+Contention\s+Ack|role\s+contention\s+ack)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $legacyMatch = [regex]::Match($sectionText, '(?im)^-\s*legacy\s+packet\s*:\s*`?(true|false)`?\s*$')

    $result.Present = $profileMatch.Success -or $adapterMatch.Success -or $qaProfileMatch.Success -or $qaAdapterMatch.Success -or $integrationProfileMatch.Success -or $integrationAdapterMatch.Success -or $implRouteMatch.Success -or $ackMatch.Success -or $legacyMatch.Success

    # CFG066 Done When 3: 필드가 하나라도 있으면 레거시가 아니다(명시적 선언이 있으면 따름).
    # 하나라도 있는데 쌍이 안 맞거나 필드가 빠지면 Valid=false + 비어 있지 않은 Error.
    if ($legacyMatch.Success) {
        $result.Legacy = $legacyMatch.Groups[1].Value -eq 'true'
    } else {
        $result.Legacy = -not $result.Present
    }

    if ($ackMatch.Success) { $result.RoleContentionAck = $ackMatch.Groups[1].Value.Trim() }

    # Planning pair check
    if (-not ($profileMatch.Success -and $adapterMatch.Success)) {
        if ($result.Present) { $result.Error = 'Runtime Role Binding must contain both actual planning profile and adapter.' }
        return [pscustomobject]$result
    }

    # QA pair check
    if ($qaProfileMatch.Success -ne $qaAdapterMatch.Success) {
        $result.Error = 'Runtime Role Binding must contain both actual QA profile and adapter when specified.'
        return [pscustomobject]$result
    }

    # Integration pair check
    if ($integrationProfileMatch.Success -ne $integrationAdapterMatch.Success) {
        $result.Error = 'Runtime Role Binding must contain both actual Integration profile and adapter when specified.'
        return [pscustomobject]$result
    }

    $result.PlanningProfile = $profileMatch.Groups[1].Value.Trim()
    $result.PlanningAdapter = $adapterMatch.Groups[1].Value.Trim()
    if ($qaProfileMatch.Success) {
        $result.QaProfile = $qaProfileMatch.Groups[1].Value.Trim()
        $result.QaAdapter = $qaAdapterMatch.Groups[1].Value.Trim()
    }
    if ($integrationProfileMatch.Success) {
        $result.IntegrationProfile = $integrationProfileMatch.Groups[1].Value.Trim()
        $result.IntegrationAdapter = $integrationAdapterMatch.Groups[1].Value.Trim()
    }
    if ($implRouteMatch.Success) {
        $result.ImplementationRoute = $implRouteMatch.Groups[1].Value.Trim()
    }
    $result.Valid = $true
    return [pscustomobject]$result
}

# CFG119(BL-114): Scope 경로 표기 정규화 — 백슬래시→슬래시, 앞뒤 공백·따옴표·백틱 제거,
# `./` 접두 제거, 끝 `/`(디렉터리 접두)와 끝 `/*`(하위 전체) 제거. 매칭 판정은 대소문자 무시.
function ConvertTo-CommitScopePath {
    param([string]$ScopePath)
    if ([string]::IsNullOrWhiteSpace($ScopePath)) { return '' }
    $p = $ScopePath.Trim().Trim(' ', '"', "'", [char]96)
    $p = $p -replace '\\', '/'
    while ($p.StartsWith('./')) { $p = $p.Substring(2) }
    $p = $p.TrimEnd('/')
    if ($p.EndsWith('/*')) { $p = $p.Substring(0, $p.Length - 2).TrimEnd('/') }
    return $p.Trim()
}

# CFG119(BL-114): 정규화된 저장소 상대 경로가 Scope paths 안에 드는지 판정하는 공용 헬퍼.
# 디렉터리 접두사(끝 `/`)·`/*` 글롭·대소문자·`./` 표기를 모두 흡수한다. Get-IntegrationCommitExclusions
# · Get-ScopeDriftWarnings · Get-IntegrationCommitScopeClassification이 공유한다.
function Test-CommitScopePathMatch {
    param([string]$NormalizedPath, [string[]]$ScopePaths)
    if ([string]::IsNullOrWhiteSpace($NormalizedPath) -or $null -eq $ScopePaths) { return $false }
    $p = ($NormalizedPath -replace '\\', '/').Trim('/').ToLowerInvariant()
    if ([string]::IsNullOrEmpty($p)) { return $false }
    foreach ($sp in $ScopePaths) {
        $s = (ConvertTo-CommitScopePath -ScopePath $sp).ToLowerInvariant()
        if ([string]::IsNullOrEmpty($s)) { continue }
        if ($p -eq $s -or $p.StartsWith("$s/") -or $s.StartsWith("$p/")) { return $true }
    }
    return $false
}

# CFG119(BL-114): `git status --porcelain` 한 줄에서 저장소 상대 경로를 뽑아 정규화한다. rename은
# `old -> new`로 오므로 새 경로를 쓴다. 호출부가 `--untracked-files=all`을 주면 미추적 디렉터리
# 접약(`?? dir/`)이 파일 단위로 전개된다(끝 `/`는 방어적으로 제거).
function ConvertFrom-GitStatusPorcelainLine {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line) -or $Line.Length -le 3) { return $null }
    $path = $Line.Substring(3).Trim()
    if ($path -match ' -> ') { $path = @($path -split ' -> ')[-1].Trim() }
    $path = $path.Trim('"') -replace '\\', '/'
    $path = $path.TrimEnd('/')
    if ([string]::IsNullOrWhiteSpace($path)) { return $null }
    return $path
}

function Get-PacketScopePaths {
    # CFG119(BL-114): `## Scope Map` 섹션 안의 `- Scope paths:` 줄만 읽는다. 종전에는 파일 전체의
    # 첫 `- Scope paths:` 줄을 읽어, 앞쪽 Amendments·배경 인용에 같은 형식의 가짜 줄이 있으면
    # 오독했다(원인 B 후보). Get-RuntimeRoleBinding과 같은 섹션 한정 방식이다.
    param([string]$PacketPath)
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return $null }
    $text = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8
    $section = [regex]::Match($text, '(?ms)^##\s+Scope Map\s*$\r?\n(.*?)(?=^##\s+|\z)')
    if (-not $section.Success) { return $null }
    $line = [regex]::Match($section.Groups[1].Value, '(?m)^\s*-\s*Scope paths:\s*(.+)$')
    if (-not $line.Success) { return $null }
    $paths = @()
    $regex = [regex]'`([^`]+)`'
    foreach ($m in $regex.Matches($line.Groups[1].Value)) {
        $norm = ConvertTo-CommitScopePath -ScopePath $m.Groups[1].Value
        if (-not [string]::IsNullOrEmpty($norm)) { $paths += $norm }
    }
    if ($paths.Count -eq 0) { return $null }
    return $paths
}

# CFG107: ⑤ Integration 완료 커밋의 범위는 패킷 Scope paths + 하네스 정상 산출물로 한정한다.
# 정상 산출물(라우터·패킷·history.md·archive 이동분)을 코드와 프롬프트가 공유하는 단일 목록으로 둔다.
# 경로는 저장소 상대이며 '/'로 끝나는 항목은 디렉터리 접두사로 취급한다. 패킷은 이 작업 것만
# 허용한다(다른 세션의 패킷 변경을 이 커밋에 끌어들이지 않기 위함).
function Get-HarnessCommitAllowedArtifacts {
    param([string]$TaskId)
    $artifacts = @(
        '.agents/briefs/handoff-log.md'
        '.agents/briefs/archive/'
        'history.md'
    )
    if (-not [string]::IsNullOrWhiteSpace($TaskId)) {
        $artifacts += ".agents/briefs/packets/${TaskId}-"
    }
    return $artifacts
}

# CFG107: 정규화된 저장소 상대 경로가 정상 산출물 허용 목록에 드는지 판정한다.
function Test-HarnessCommitArtifactPath {
    param([string]$NormalizedPath, [string]$TaskId)
    if ([string]::IsNullOrWhiteSpace($NormalizedPath)) { return $false }
    $norm = $NormalizedPath -replace '\\', '/'
    foreach ($artifact in (Get-HarnessCommitAllowedArtifacts -TaskId $TaskId)) {
        if ($artifact.EndsWith('/') -or $artifact.EndsWith('-')) {
            if ($norm.StartsWith($artifact)) { return $true }
        } elseif ($norm -eq $artifact) {
            return $true
        }
    }
    return $false
}

# CFG107: ⑤ 착수 시점의 작업 트리(`git status --porcelain`)를 패킷 Scope paths·정상 산출물
# 허용 목록과 대조해 "이번 커밋에서 제외할 파일"을 계산한다. 스냅샷 diff가 아니라 현재 작업
# 트리 기준이다 — 다른 세션이 남긴 미커밋 변경(예: 출처 불명 README.md)을 그대로 드러낸다.
# CFG119: 매칭은 공용 헬퍼(Test-CommitScopePathMatch)로 통일하고, 미추적 디렉터리를 파일
# 단위로 전개한다(--untracked-files=all). 이 함수는 string[] 반환·시그니처를 유지한다(CFG107
# 테스트 호환). ⑤ 실사용 경로는 Get-IntegrationCommitScopeNotice가 대체한다.
function Get-IntegrationCommitExclusions {
    param([string]$PacketPath, [string]$RepoRoot, [string]$TaskId)
    $exclusions = @()
    if ([string]::IsNullOrWhiteSpace($RepoRoot)) { return $exclusions }
    if ([string]::IsNullOrWhiteSpace($TaskId) -and $PacketPath) {
        $leaf = Split-Path -Leaf $PacketPath
        $m = [regex]::Match($leaf, '^([A-Za-z0-9]+)-')
        if ($m.Success) { $TaskId = $m.Groups[1].Value }
    }
    $scopePaths = @()
    if ($PacketPath -and (Test-Path -LiteralPath $PacketPath)) {
        $scopePaths = @(Get-PacketScopePaths -PacketPath $PacketPath)
    }
    $lines = @()
    # CFG119: 경로 목록은 가능하면 CFG117의 공용 창구(Invoke-GitPathList)로 받는다. 이 모듈은
    # self-contained 순수 모듈이라 헬퍼가 없을 수 있으므로(harness-contracts.ps1만 로드) 그때는
    # 직접 git을 호출하되 -c core.quotepath=false + UTF-8 콘솔 인코딩으로 한글 경로를 보존한다.
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        if (Get-Command Invoke-GitPathList -ErrorAction SilentlyContinue) {
            $lines = @(Invoke-GitPathList -RepoRoot $RepoRoot -GitArgs @('status', '--porcelain', '--untracked-files=all'))
        } else {
            $prevEnc = $null; $switchedEnc = $false
            try {
                try { $prevEnc = [Console]::OutputEncoding; [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $switchedEnc = $true } catch { }
                $lines = @(& git -C $RepoRoot -c core.quotepath=false status --porcelain --untracked-files=all 2>$null)
            } finally {
                if ($switchedEnc) { try { [Console]::OutputEncoding = $prevEnc } catch { } }
            }
        }
    } catch {
        return $exclusions
    } finally {
        $ErrorActionPreference = $prevEap
    }
    foreach ($line in $lines) {
        $path = ConvertFrom-GitStatusPorcelainLine -Line $line
        if ($null -eq $path) { continue }
        if (Test-HarnessCommitArtifactPath -NormalizedPath $path -TaskId $TaskId) { continue }
        if (Test-CommitScopePathMatch -NormalizedPath $path -ScopePaths $scopePaths) { continue }
        $exclusions += $path
    }
    return @($exclusions | Sort-Object -Unique)
}

# CFG119(BL-114): ⑤ 커밋 범위 밖 변경을 세 갈래로 분류한다. 종전에는 "②~④ 중 파이프라인이 바꾼
# Scope 밖 파일"과 "시작 전부터 더티였던 무관 파일"을 구분하지 못해 필요한 파일이 커밋에서 빠졌다.
#  (a) Exclusions = ② 착수 시점에 이미 더티였고 기준선 대비 내용 해시도 그대로인 Scope 밖 파일(무관한 선행 변경).
#  (b) Drift      = ② 착수 시점에는 없었는데(또는 깨끗했는데) 파이프라인이 바꾼 Scope 밖 파일 — 제외로 취급하지 않는다.
#  (c) Overlaps   = ② 착수 시점에 더티였고 기준선 대비 내용 해시가 바뀐 Scope 밖 파일(선행+파이프라인 혼재) — 자동 커밋 금지.
# 기준선($Baseline)이 $null이면 이탈 여부를 판단할 수 없으므로 전부 (a)로 보수 처리하고
# BaselineMissing=$true로 알린다(조용히 커밋에서 빠지는 경로를 만들지 않는다 — fail-safe).
function Get-IntegrationCommitScopeClassification {
    param(
        [string]$PacketPath,
        [string]$TaskId,
        [string[]]$StatusLines,
        [hashtable]$Baseline,
        [hashtable]$CurrentHashes
    )
    $exclusions = New-Object System.Collections.Generic.List[string]
    $drift = New-Object System.Collections.Generic.List[string]
    $overlaps = New-Object System.Collections.Generic.List[string]
    $scopePaths = @()
    if ($PacketPath -and (Test-Path -LiteralPath $PacketPath)) {
        $scopePaths = @(Get-PacketScopePaths -PacketPath $PacketPath)
    }
    $baselineMissing = ($null -eq $Baseline)
    foreach ($line in @($StatusLines)) {
        $path = ConvertFrom-GitStatusPorcelainLine -Line $line
        if ($null -eq $path) { continue }
        if (Test-HarnessCommitArtifactPath -NormalizedPath $path -TaskId $TaskId) { continue }
        if (Test-CommitScopePathMatch -NormalizedPath $path -ScopePaths $scopePaths) { continue }
        if ($baselineMissing) { $exclusions.Add($path); continue }
        if ($Baseline.ContainsKey($path)) {
            $baseHash = $Baseline[$path]
            $curHash = $null
            if ($CurrentHashes -and $CurrentHashes.ContainsKey($path)) { $curHash = $CurrentHashes[$path] }
            if ($baseHash -eq $curHash) { $exclusions.Add($path) } else { $overlaps.Add($path) }
        } else {
            $drift.Add($path)
        }
    }
    return [pscustomobject]@{
        Exclusions = @($exclusions | Sort-Object -Unique)
        Drift = @($drift | Sort-Object -Unique)
        Overlaps = @($overlaps | Sort-Object -Unique)
        BaselineMissing = $baselineMissing
    }
}

# CFG119(BL-114): ⑤ Integration 프롬프트에 주입할 커밋 범위 안내 문구를 만든다. 순수 함수다 —
# git 호출·파일 I/O 없이 인자(StatusLines·Baseline·CurrentHashes)만으로 동작한다(호출자가 git/파일
# 목록을 모아 넘긴다). 종전 도입부의 "그 밖의 변경 파일은 커밋하지 마" 단독 금지는 (a)/(b)/(c)
# 규칙과 정면 충돌하므로 쓰지 않고, 이탈·겹침 목록이 있을 때만 해당 지시 문구를 덧붙인다.
function Get-IntegrationCommitScopeNotice {
    param(
        [string]$PacketPath,
        [string]$TaskId,
        [string[]]$StatusLines,
        [hashtable]$Baseline,
        [hashtable]$CurrentHashes
    )
    $cls = Get-IntegrationCommitScopeClassification -PacketPath $PacketPath -TaskId $TaskId -StatusLines $StatusLines -Baseline $Baseline -CurrentHashes $CurrentHashes
    $notice = ' [커밋 범위] 패킷 Scope paths와 아래 정상 산출물만 커밋해.'
    $allowed = @(Get-HarnessCommitAllowedArtifacts -TaskId $TaskId)
    $notice += " 정상 산출물 허용 목록: $($allowed -join ', ')."
    if ($cls.Exclusions.Count -gt 0) {
        $notice += " 선행 변경으로 이미 더티였던 Scope 밖 파일(무관한 변경 — 커밋 금지): $($cls.Exclusions -join ', ')."
    }
    if ($cls.Drift.Count -gt 0) {
        $notice += " Scope 이탈 변경(② 착수 이후 파이프라인이 Scope 밖에서 바꾼 파일): $($cls.Drift -join ', ') — 각 파일이 커밋 대상 파일이 import/참조하는 파일이면 함께 커밋하고, 참조하지 않으면 커밋하지 말고 경로를 최종 보고에 남겨. 참조 여부를 판단할 수 없으면 커밋하지 말고 중단·보고해."
    }
    if ($cls.Overlaps.Count -gt 0) {
        $notice += " 선행 더티 + 추가 수정 겹침(선행 변경과 파이프라인 변경이 섞임 — 자동 커밋 금지): $($cls.Overlaps -join ', ') — 커밋하지 말고 중단·보고해."
    }
    if ($cls.BaselineMissing) {
        $notice += ' 기준선 없음 — 이탈 여부를 판단할 수 없으니 Scope 밖 변경은 커밋 전 반드시 보고해.'
    }
    return $notice
}

