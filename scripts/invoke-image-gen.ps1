<#
이미지 생성 직접 호출 래퍼 (패킷·락·QA 단계와 무관).

이미지 생성은 팀 역할(기획·구현·QA)이 아니라 모델 능력이라서, 호출할 때마다 생성 모델을 지정한다.
Codex(`codex exec`)와 Gemini(`agy -p`)는 내장 이미지 생성 도구로 현재 폴더에 PNG를 저장한다
(2026-10-30 실측: 둘 다 성공 — Codex는 ~/.codex/generated_images 에 만든 뒤 현재 폴더로 복사, agy는 image-generator 서브에이전트).
이 스크립트는 그 호출에 런북 규칙을 입힌다: stdin 닫기(안 닫으면 codex가 <stdin> 블록을 기다리며 무한 대기),
타임아웃 시 프로세스 트리 종료, 산출 파일 존재·PNG 시그니처 검증, 결과 JSON 한 줄.

예)
  invoke-image-gen.ps1 -Tool agy -OutDir D:\out -ExpectFiles a.png,b.png -Prompt "웹툰 스타일 ... 2장"
  invoke-image-gen.ps1 -Tool codex -OutDir D:\out -ExpectFiles hero.png -PromptFile D:\out\hero-prompt.txt
  invoke-image-gen.ps1 -OutDir D:\out -ExpectFiles a.png -VerifyOnly     # 생성 없이 산출물만 검증

종료 코드: 0 = 기대 파일 전부 유효, 1 = 실패(타임아웃·누락·PNG 아님·도구 없음).
로그는 저장소 밖($env:TEMP\invoke-image-gen)에 둔다 — 작업 트리 안에 두면 Get-TreeState를 흔든다.
#>
[CmdletBinding()]
param(
    [ValidateSet('codex', 'agy')][string]$Tool,
    [string]$Prompt,
    [string]$PromptFile,
    [Parameter(Mandatory)][string]$OutDir,
    [string[]]$ExpectFiles = @(),
    [int]$TimeoutSec = 600,
    [switch]$DryRun,
    [switch]$VerifyOnly
)

$ErrorActionPreference = 'Stop'

function Test-PngFile {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $fs = [IO.File]::OpenRead($Path)
    try {
        if ($fs.Length -lt 8) { return $false }
        $head = New-Object byte[] 8
        [void]$fs.Read($head, 0, 8)
        $sig = 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A
        for ($i = 0; $i -lt 8; $i++) { if ($head[$i] -ne $sig[$i]) { return $false } }
        return $true
    } finally { $fs.Dispose() }
}

function Get-OutputReport {
    param([string]$Dir, [string[]]$Expect, [datetime]$Since)
    $files = @()
    $ok = $true
    if ($Expect.Count -gt 0) {
        foreach ($name in $Expect) {
            $p = Join-Path $Dir $name
            $valid = Test-PngFile $p
            if (-not $valid) { $ok = $false }
            $files += [ordered]@{ name = $name; valid = $valid; bytes = $(if (Test-Path -LiteralPath $p) { (Get-Item -LiteralPath $p).Length } else { 0 }) }
        }
    } else {
        # 파일명을 지정하지 않으면 이번 실행 이후 새로 생긴 PNG가 1개 이상이어야 한다.
        $fresh = @(Get-ChildItem -LiteralPath $Dir -Filter *.png -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -ge $Since })
        foreach ($f in $fresh) { $files += [ordered]@{ name = $f.Name; valid = (Test-PngFile $f.FullName); bytes = $f.Length } }
        if ($files.Count -eq 0 -or @($files | Where-Object { -not $_.valid }).Count -gt 0) { $ok = $false }
    }
    return [pscustomobject]@{ ok = $ok; files = $files }
}

function Write-Result {
    param([bool]$Ok, [string]$Reason, $Report, [string]$Log)
    $obj = [ordered]@{ ok = $Ok; tool = $Tool; outDir = $OutDir; reason = $Reason; files = @($(if ($Report) { $Report.files })); log = $Log }
    Write-Output ($obj | ConvertTo-Json -Compress -Depth 5)
}

if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

if ($VerifyOnly) {
    $report = Get-OutputReport -Dir $OutDir -Expect $ExpectFiles -Since ([datetime]::MinValue)
    Write-Result -Ok $report.ok -Reason $(if ($report.ok) { 'verified' } else { 'missing-or-invalid-png' }) -Report $report -Log ''
    if ($report.ok) { exit 0 } else { exit 1 }
}

if (-not $Tool) { throw '-Tool (codex|agy) 은 생성 시 필수다. 검증만 하려면 -VerifyOnly.' }
if ($PromptFile) { $Prompt = Get-Content -LiteralPath $PromptFile -Raw -Encoding UTF8 }
if ([string]::IsNullOrWhiteSpace($Prompt)) { throw '-Prompt 또는 -PromptFile 이 필요하다.' }

# 인자 따옴표 깨짐 방지: PS 5.1 네이티브 호출은 내부 큰따옴표를 보존하지 못하므로 홑따옴표로 치환한다.
$Prompt = $Prompt.Replace('"', "'").Trim()
$nameClause = if ($ExpectFiles.Count -gt 0) { "파일명: $($ExpectFiles -join ', ')." } else { 'PNG 파일명은 내용을 알 수 있게 영문 소문자로 정한다.' }
$fullPrompt = "$Prompt`n`n[출력 규칙] 생성한 이미지를 각각 별도 PNG 파일로 현재 폴더에 저장해라. $nameClause 이미지 생성 도구가 없으면 생성하지 말고 '도구 없음'이라고만 답해라."
$fullPrompt = ($fullPrompt -replace "\r?\n", ' ')

$exe = (Get-Command $(if ($Tool -eq 'codex') { 'codex' } else { 'agy' }) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
if (-not $exe) { Write-Result -Ok $false -Reason "tool-not-found:$Tool" -Report $null -Log ''; exit 1 }

$argString = if ($Tool -eq 'codex') {
    "exec --skip-git-repo-check -s workspace-write `"$fullPrompt`""
} else {
    "-p `"$fullPrompt`""
}

$logDir = Join-Path $env:TEMP 'invoke-image-gen'
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outLog = Join-Path $logDir "$stamp-$Tool.out.log"
$errLog = Join-Path $logDir "$stamp-$Tool.err.log"

if ($DryRun) {
    Write-Output "[DryRun] cwd=$OutDir"
    Write-Output "[DryRun] $exe $argString"
    Write-Output "[DryRun] timeout=${TimeoutSec}s stdin=closed log=$outLog"
    exit 0
}

# stdin을 빈 파일로 닫는다 — codex는 닫히지 않은 stdin에서 EOF를 기다린다(런북 §2 플래그 근거).
$emptyIn = Join-Path $logDir "$stamp-empty.in"
[IO.File]::WriteAllBytes($emptyIn, [byte[]]@())

$started = Get-Date
$proc = Start-Process -FilePath $exe -ArgumentList $argString -WorkingDirectory $OutDir `
    -RedirectStandardInput $emptyIn -RedirectStandardOutput $outLog -RedirectStandardError $errLog `
    -NoNewWindow -PassThru
$finished = $proc.WaitForExit($TimeoutSec * 1000)
if (-not $finished) {
    & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null
    Write-Result -Ok $false -Reason "timeout-${TimeoutSec}s" -Report (Get-OutputReport -Dir $OutDir -Expect $ExpectFiles -Since $started) -Log $outLog
    exit 1
}
$proc.WaitForExit()

$report = Get-OutputReport -Dir $OutDir -Expect $ExpectFiles -Since $started.AddSeconds(-2)
$reason = if ($report.ok) { 'generated' } elseif ($proc.ExitCode -ne 0) { "tool-exit-$($proc.ExitCode)" } else { 'missing-or-invalid-png' }
Write-Result -Ok $report.ok -Reason $reason -Report $report -Log $outLog
if ($report.ok) { exit 0 } else { exit 1 }
