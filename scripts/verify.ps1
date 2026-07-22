# scripts/verify.ps1 — ②④⑤ 공통 검증 게이트. 구현·QA·Integration 모두 동일 스크립트로 검증한다.
# 사용법: pwsh scripts/verify.ps1   (또는 powershell -File scripts\verify.ps1)
# 종료 코드: 전원 통과 0, 하나라도 실패 1. 실패해도 나머지 스텝은 끝까지 돌려 전체 결과를 보고한다.
#
# PerfMon 실제 스택: .NET 8 WPF 단일 프로젝트(PerfMonCS.csproj), 테스트 프로젝트 없음.
# 자동 테스트가 생기면 여기에 Invoke-Step을 추가한다.

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $PSScriptRoot
$results = @()

function Invoke-Step {
    param([string]$Name, [string]$Dir, [scriptblock]$Command)
    Write-Host ""
    Write-Host "== $Name ==" -ForegroundColor Cyan
    Push-Location $Dir
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Command
    $code = $LASTEXITCODE
    $sw.Stop()
    Pop-Location
    $script:results += [pscustomobject]@{ Step = $Name; Pass = ($code -eq 0); Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}

Invoke-Step "dotnet build (Release)" $root { dotnet build -c Release }

Write-Host ""
Write-Host "== Verify Summary ==" -ForegroundColor Cyan
foreach ($r in $results) {
    $mark = if ($r.Pass) { "PASS" } else { "FAIL" }
    $color = if ($r.Pass) { "Green" } else { "Red" }
    Write-Host ("  [{0}] {1} ({2}s)" -f $mark, $r.Step, $r.Seconds) -ForegroundColor $color
}

if ($results | Where-Object { -not $_.Pass }) { exit 1 }
Write-Host "ALL PASS" -ForegroundColor Green
exit 0
