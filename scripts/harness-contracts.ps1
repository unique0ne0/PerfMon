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

function Get-PacketScopePaths {
    param([string]$PacketPath)
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return $null }
    foreach ($line in Get-Content -LiteralPath $PacketPath -Encoding UTF8) {
        if ($line -match '^\s*-\s*Scope paths:\s*(.+)$') {
            $pathsStr = $Matches[1]
            $paths = @()
            $regex = [regex]'`([^`]+)`'
            foreach ($m in $regex.Matches($pathsStr)) {
                $paths += $m.Groups[1].Value
            }
            return $paths
        }
    }
    return $null
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
    $prevEap = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $lines = @(git -C $RepoRoot -c core.quotepath=false status --porcelain 2>$null)
    } catch {
        return $exclusions
    } finally {
        $ErrorActionPreference = $prevEap
    }
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line) -or $line.Length -le 3) { continue }
        $path = $line.Substring(3).Trim()
        if ($path -match ' -> ') { $path = ($path -split ' -> ')[-1].Trim() }
        $path = $path.Trim('"') -replace '\\', '/'
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (Test-HarnessCommitArtifactPath -NormalizedPath $path -TaskId $TaskId) { continue }
        $inScope = $false
        foreach ($sp in $scopePaths) {
            $spNorm = $sp -replace '\\', '/'
            if ($path -eq $spNorm -or $path.StartsWith("$spNorm/") -or $spNorm.StartsWith("$path/")) { $inScope = $true; break }
        }
        if (-not $inScope) { $exclusions += $path }
    }
    return @($exclusions | Sort-Object -Unique)
}

