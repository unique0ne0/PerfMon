# Harness contracts module — packet and TaskId pure contract functions.
# This module is self-contained and exposes pure contract functions only.

function Get-NormalizedTaskId {
    param([string]$TaskId)
    if ($null -eq $TaskId) { return '' }
    return ($TaskId -replace '[^A-Za-z0-9]', '').ToUpperInvariant()
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
    $profileMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+Planning\s+Profile|actual\s+planning\s+profile)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $adapterMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+Planning\s+Adapter|actual\s+planning\s+adapter)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $qaProfileMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+QA\s+Profile|actual\s+qa\s+profile)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $qaAdapterMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+QA\s+Adapter|actual\s+qa\s+adapter)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $integrationProfileMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+Integration\s+Profile|actual\s+integration\s+profile)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $integrationAdapterMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+Integration\s+Adapter|actual\s+integration\s+adapter)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $implRouteMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+Implementation\s+Route|actual\s+implementation\s+route)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $ackMatch = [regex]::Match($text, '(?im)^-\s*(?:Role\s+Contention\s+Ack|role\s+contention\s+ack)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $legacyMatch = [regex]::Match($text, '(?im)^-\s*legacy\s+packet\s*:\s*`?(true|false)`?\s*$')

    $result.Present = $profileMatch.Success -or $adapterMatch.Success -or $qaProfileMatch.Success -or $qaAdapterMatch.Success -or $integrationProfileMatch.Success -or $integrationAdapterMatch.Success -or $implRouteMatch.Success -or $ackMatch.Success -or $legacyMatch.Success
    if ($legacyMatch.Success) { $result.Legacy = $legacyMatch.Groups[1].Value -eq 'true' }
    if ($ackMatch.Success) { $result.RoleContentionAck = $ackMatch.Groups[1].Value.Trim() }

    # Planning pair check
    if (-not ($profileMatch.Success -and $adapterMatch.Success)) {
        if ($result.Present -and -not $result.Legacy) { $result.Error = 'Runtime Role Binding must contain both actual planning profile and adapter.' }
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

