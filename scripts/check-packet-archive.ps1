# 완료 상태인 패킷이 packets/에 남았는지 경고한다. 기본은 관찰만 하며 -Strict만 실패한다.
param(
    [Parameter(Mandatory=$true)][string]$RepoRoot,
    [switch]$Strict
)

$briefs = Join-Path $RepoRoot '.agents\briefs'
$router = Join-Path $briefs 'handoff-log.md'
$packets = Join-Path $briefs 'packets'
if (-not (Test-Path -LiteralPath $router) -or -not (Test-Path -LiteralPath $packets)) { exit 0 }

# 라우터 표의 섹션 제목은 저장소마다 다르다(ai-agents-config·claude-zen-fallback은 '## Router',
# AIStaff·AC-II·WorldScheduler·PerfMon은 '## Packets'). 상태 열 위치도 표마다 달라질 수 있으므로
# 헤더 행에서 '상태' 열 인덱스를 직접 찾는다. ID는 항상 첫 열이다.
$doneIds = @()
$inRouter = $false
$statusIdx = -1
foreach ($line in Get-Content -LiteralPath $router -Encoding UTF8) {
    if ($line -match '^##\s+(Router|Packets)\s*$') { $inRouter = $true; $statusIdx = -1; continue }
    if ($inRouter -and $line -match '^##\s+') { $inRouter = $false; continue }
    if (-not $inRouter -or $line -notmatch '^\|') { continue }
    $cells = @($line.Trim() -split '\|' | ForEach-Object { $_.Trim() })
    if ($cells.Count -lt 5 -or $cells[1] -match '^-+$') { continue }
    if ($statusIdx -lt 0) {
        $statusIdx = [array]::IndexOf($cells, '상태')
        continue
    }
    if ($statusIdx -lt 0 -or $cells.Count -le $statusIdx) { continue }
    if ($cells[$statusIdx] -eq 'DONE') { $doneIds += $cells[1] }
}

$leftovers = @()
foreach ($id in $doneIds) {
    foreach ($packet in @(Get-ChildItem -LiteralPath $packets -Filter "$id-*.md" -File -ErrorAction SilentlyContinue)) {
        $leftovers += "$id ($($packet.Name))"
    }
}
if ($leftovers.Count -eq 0) { exit 0 }
Write-Host 'WARN: DONE 상태인데 packets/에 남은 패킷:' -ForegroundColor Yellow
$leftovers | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
if ($Strict) { exit 1 }
exit 0
