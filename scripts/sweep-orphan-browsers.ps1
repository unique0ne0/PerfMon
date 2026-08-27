<#
CFG-BL-030: agent-browser / playwright MCP ?ㅻ뱶由ъ뒪 Chrome 怨좎븘 ?꾨줈?몄뒪 ?ㅼ쐲.

諛곌꼍: dispatch-with-hang-detect.ps1??湲곗〈 ?뺣━(Stop-ProcessTree)???붿뒪?⑥쿂媛 吏곸젒 ?꾩슫
CLI(agy.exe ?????꾨줈?몄뒪 ?몃━留?taskkill /T濡?二쎌씤?? 洹몃윴??agent-browser/@playwright/mcp媛
?꾩슦??Chrome? Antigravity IDE???곸＜ 諛깃렇?쇱슫???쒕퉬??language_server_windows_x64.exe)媛
?깅줉??MCP ?쒕쾭 諛묒뿉???대젮, 洹??몃━ 諛붽묑???⑤뒗?????대뼡 ?붿뒪?⑥튂瑜?二쎌뿬???우? ?딅뒗??
?ㅼ륫(2026-08-22, ?ъ슜??吏?쒕줈 媛쒕컻2? 議곗궗): 諛⑹튂???ㅻ뱶由ъ뒪 Chrome 29媛??뺤씤.

洹몃옒?????ㅽ겕由쏀듃??dispatch-with-hang-detect.ps1??finally/cleanup 寃쎈줈???뱀? ?딄퀬
?낅┰ ?ㅽ뻾?쒕떎. 湲곕낯 ?숈옉? advisory(蹂닿퀬留? ???먮룞 kill? -AutoKill??紐낆떆?덉쓣 ?뚮쭔,
洹몃━怨?"遺紐??꾨줈?몄뒪媛 ?대? 二쎌?" 吏꾩쭨 orphan留???곸쑝濡??쒕떎. 遺紐④? ?댁븘 ?덉쑝硫?吏湲??곕뒗 以묒씪 ???덉쑝誘濡?-AutoKill??以섎룄 ?덈? 二쎌씠吏 ?딄퀬 "?뺤씤 ?꾩슂"濡쒕쭔 蹂닿퀬?쒕떎.
#>
[CmdletBinding()]
param(
    [switch]$AutoKill,
    [int]$MinAgeMinutes = 5
)

$ErrorActionPreference = 'Stop'

$logDir = Join-Path $PSScriptRoot 'logs\orphan-sweep'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$reportPath = Join-Path $logDir "sweep-$stamp.json"

# agent-browser/playwright MCP媛 ?꾩슦???꾨줈?몄뒪留?寃⑤깷?쒕떎. ?ъ슜?먯쓽 ?뺤긽 Chrome(?ㅻⅨ ?ㅼ튂
# 寃쎈줈)?대굹 ?붾㈃ ?뱁솕 ?꾧뎄 媛숈? 臾닿????꾨줈?몄뒪?????쒓렇?덉쿂?ㅺ낵 留ㅼ튂?섏? ?딆븘 ?먯뿰???쒖쇅?쒕떎.
$signaturePatterns = @(
    '\.agent-browser\\browsers\\',
    '@playwright[/\\]mcp',
    'agent-browser'
)
$candidateNames = @('chrome.exe', 'node.exe', 'bun.exe')

function Test-SignatureMatch {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $false }
    foreach ($pattern in $signaturePatterns) {
        if ($Text -match $pattern) { return $true }
    }
    return $false
}

Write-Host "agent-browser/playwright 怨좎븘 ?꾨줈?몄뒪 ?ㅼ쐲 ?쒖옉 (紐⑤뱶: $(if ($AutoKill) { 'AutoKill(吏꾩쭨 orphan留?' } else { 'Report-Only' }))" -ForegroundColor Cyan

try {
    $allProcesses = @(Get-CimInstance Win32_Process -ErrorAction Stop)
} catch {
    Write-Host "Win32_Process 議고쉶 ?ㅽ뙣: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
$aliveIds = [System.Collections.Generic.HashSet[int]]::new()
foreach ($p in $allProcesses) { [void]$aliveIds.Add([int]$p.ProcessId) }

$now = Get-Date
$results = @()

foreach ($proc in $allProcesses) {
    if ($candidateNames -notcontains $proc.Name) { continue }
    $matched = (Test-SignatureMatch $proc.ExecutablePath) -or (Test-SignatureMatch $proc.CommandLine)
    if (-not $matched) { continue }

    $parentAlive = $aliveIds.Contains([int]$proc.ParentProcessId)
    $ageMinutes = if ($proc.CreationDate) { [Math]::Round(($now - $proc.CreationDate).TotalMinutes, 1) } else { $null }
    $isOldEnough = ($null -eq $ageMinutes) -or ($ageMinutes -ge $MinAgeMinutes)
    # 吏꾩쭨 orphan ?먯젙: 遺紐④? ?대? 二쎌뿀怨? 諛⑷툑 ??寃??꾨땲?댁꽌 ?ㅽ룿 吏곹썑 寃쏀빀 李쎌씠 ?꾨떂???뺤떎???뚮쭔.
    $orphanConfirmed = (-not $parentAlive) -and $isOldEnough

    $results += [pscustomobject]@{
        ProcessId       = [int]$proc.ProcessId
        Name            = $proc.Name
        ParentProcessId = [int]$proc.ParentProcessId
        ParentAlive     = $parentAlive
        AgeMinutes      = $ageMinutes
        OrphanConfirmed = $orphanConfirmed
        ExecutablePath  = $proc.ExecutablePath
        CommandLine     = $proc.CommandLine
    }
}

$orphans = @($results | Where-Object { $_.OrphanConfirmed })
$needsReview = @($results | Where-Object { -not $_.OrphanConfirmed })

Write-Host "`n?꾨낫 ?꾨줈?몄뒪 珥?$($results.Count)媛???吏꾩쭨 orphan(遺紐??щ㈇) $($orphans.Count)媛? ?뺤씤 ?꾩슂(遺紐??앹〈) $($needsReview.Count)媛?n" -ForegroundColor Yellow

if ($results.Count -gt 0) {
    $results | Sort-Object OrphanConfirmed -Descending | Format-Table ProcessId, Name, ParentProcessId, ParentAlive, AgeMinutes, OrphanConfirmed -AutoSize | Out-Host
}

$killed = @()
$killFailed = @()
if ($AutoKill -and $orphans.Count -gt 0) {
    foreach ($o in $orphans) {
        try {
            Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop
            $killed += $o.ProcessId
            Write-Host "  醫낅즺: PID $($o.ProcessId) ($($o.Name), 遺紐?PID $($o.ParentProcessId) ?щ㈇, $($o.AgeMinutes)遺?寃쎄낵)" -ForegroundColor Green
        } catch {
            $killFailed += $o.ProcessId
            Write-Host "  醫낅즺 ?ㅽ뙣: PID $($o.ProcessId) ??$($_.Exception.Message)" -ForegroundColor Red
        }
    }
} elseif ($orphans.Count -gt 0) {
    Write-Host "Report-Only 紐⑤뱶?낅땲?? ?ㅼ젣濡?醫낅즺?섎젮硫?-AutoKill??遺숈뿬 ?ъ떎?됲븯?몄슂." -ForegroundColor DarkGray
}

if ($needsReview.Count -gt 0) {
    Write-Host "`n遺紐④? ?댁븘 ?덉뼱 ?먮룞 醫낅즺 ??곸뿉???쒖쇅???꾨줈?몄뒪 (?섎룞 ?뺤씤 ?꾩슂):" -ForegroundColor Yellow
    $needsReview | Format-Table ProcessId, Name, ParentProcessId, AgeMinutes -AutoSize | Out-Host
}

$report = [pscustomobject]@{
    Timestamp       = $now.ToString('o')
    Mode            = if ($AutoKill) { 'AutoKill' } else { 'ReportOnly' }
    MinAgeMinutes   = $MinAgeMinutes
    CandidateCount  = $results.Count
    OrphanCount     = $orphans.Count
    NeedsReviewCount = $needsReview.Count
    Killed          = $killed
    KillFailed      = $killFailed
    Candidates      = $results
}
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $reportPath -Encoding UTF8
Write-Host "`n由ы룷????? $reportPath" -ForegroundColor Cyan
