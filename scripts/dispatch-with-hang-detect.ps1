#!/usr/bin/env pwsh
<#
.SYNOPSIS
    헤드리스 디스패치 + Hang(로그 무변화) 감지 워처 — CLAUDE.md verbatim 표준 명령 기준.

.DESCRIPTION
    파이프라인 단계(②③ 구현 · ④ QA · ⑤ Integration)를 헤드리스 CLI로 디스패치하고,
    로그 무변화(hang)를 전 구간 감시한다. 각 단계의 명령·모델·프롬프트는 CLAUDE.md
    "Headless Dispatch — 단계별 표준 명령"과 동일(verbatim)하게 유지한다.

    실제 실행은 bash로 위임한다 — 표준 명령이 bash 기준이며, UTF-8 한국어 프롬프트와
    `</dev/null`(stdin 종료로 무한 대기 방지)가 그대로 보존된다. 명령은 임시 .sh(UTF-8, BOM 없음)로
    기록해 bash로 실행하므로, PowerShell의 리다이렉트/인코딩/따옴표 문제를 근본적으로 회피한다.

    단계 판정은 4중이다 — ① 종료 코드(불명이면 게이트에 위임) ② `scripts/verify.ps1` 게이트
    ③ 작업트리 변경 유무(경고) ④ QA는 이번 실행에서 새로 쓴 verdict만 인정.

    사용법:
        # 단일 단계
        powershell -ExecutionPolicy Bypass -File scripts\dispatch-with-hang-detect.ps1 -TaskId ai0024 -Stage impl
        powershell -ExecutionPolicy Bypass -File scripts\dispatch-with-hang-detect.ps1 -TaskId ai0024 -Stage qa
        powershell -ExecutionPolicy Bypass -File scripts\dispatch-with-hang-detect.ps1 -TaskId ai0024 -Stage integration
        # 자동 연쇄 (②③ → ④ → [QA verdict=pass일 때만] ⑤)
        powershell -ExecutionPolicy Bypass -File scripts\dispatch-with-hang-detect.ps1 -TaskId ai0024 -Chain
        # 실행 없이 생성 명령만 확인
        powershell -ExecutionPolicy Bypass -File scripts\dispatch-with-hang-detect.ps1 -TaskId ai0024 -Stage impl -DryRun

.PARAMETER TaskId             작업 ID — 프리픽스 뒤 숫자만, -·공백 금지 (예: 001, AC001, CS030, CFG005)
.PARAMETER Stage              impl(②③) · qa(④) · integration(⑤). -Chain과 배타.
.PARAMETER Prompt             단일 단계 실행 시 기본 프롬프트 override (미지정 시 CLAUDE.md verbatim 기본값).
.PARAMETER Model              impl 1번 모델 override — 작업 성격(리팩토링·신규 구현 등)에 맞는 모델을
                              기획 단계에서 골라 넘긴다. 폴백 체인의 나머지(장애·잔액 대비 경로)는 그대로 유지.
.PARAMETER Chain              자동 연쇄 모드.
.PARAMETER HangWaitSeconds    로그 무변화 감지 임계(기본 300초 = 5분). 단계별 기본값이 있으면 그쪽이 우선.
.PARAMETER HardTimeoutMinutes 단계 하드 상한(기본 30분). 이 시각에 로그가 계속 늘고 있으면 상한을 연장하고,
                              멈춰 있으면 종료시킨다. 연장 폭(상한÷3)과 절대 상한(상한×3)이 전부 이 값에서
                              파생되므로 — 별도의 상한 노브는 두지 않는다 — 이것만 줄이면 짧게 검증할 수 있다.
.PARAMETER DryRun             실제 실행 없이 생성될 명령/스크립트만 출력(단일 단계 검증용).
#>

param(
    [Parameter(Mandatory=$true)][string]$TaskId,
    [Parameter(Mandatory=$false)][ValidateSet('impl','qa','integration')][string]$Stage,
    [Parameter(Mandatory=$false)][string]$Prompt,
    [Parameter(Mandatory=$false)][string]$Model,
    [Parameter(Mandatory=$false)][switch]$Chain,
    [Parameter(Mandatory=$false)][int]$HangWaitSeconds = 300,
    [Parameter(Mandatory=$false)][int]$HardTimeoutMinutes = 30,
    [Parameter(Mandatory=$false)][switch]$DryRun,
    [Parameter(Mandatory=$false)][switch]$SkipVerdictGate
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = ".agents/briefs/logs"
$TaskLogPrefix = "$LogDir/$TaskId"

# 동시 디스패치 락. 로그 디렉터리 **안**에 둔다 — Get-TreeState가 이 경로를 이미 걸러내므로
# 락 파일 자체가 작업트리를 더럽혀 무변경 감지를 무력화하는 자충수를 피한다.
$LockPrefix = "$LogDir/.dispatch-lock"

# 하드 상한 연장 판정 임계 — 최근 창에서 로그가 이만큼 늘었으면 "진행 중"으로 본다.
# 낮게 잡은 건 의도적이다. 여기서 재는 건 속도가 아니라 생존 여부이고, 폭주는 절대 상한이 막는다.
$HardTimeoutProgressBytes = 1024
# hang 판정 임계 — 로그 무변화 구간의 트리 CPU 증가율(1.0 = 코어 하나를 100% 사용).
# 2026-08-09 CS-024 실측: 실제 작업 중 13~26%, 정지 상태 1.3~1.7%. 두 분포 사이에 둔다.
$BusyCpuRate = 0.05
# I/O-heavy package installation and archive extraction can be healthy while using
# little CPU and producing no output. This rate avoids killing those active stages.
$BusyIoBytesPerSec = 65536

# 마지막 실패 사유 — Dispatch-Stage가 채우고 Invoke-StageWithLock이 실패 마커에 기록한다.
$script:LastFailureReason = $null

# QA 단계 디스패치 시각 — verdict가 "이번 실행에서" 쓰였는지 판정하는 기준. 미실행이면 $null.
$script:QaDispatchedAt = $null
$script:WatcherLogAbs = $null
$script:ActiveChildProcessId = $null
$script:ActiveChildStage = $null
$script:ActiveLockStage = $null
$script:CimFailureCount = 0
$script:CleanupStarted = $false

# ── 단계별 설정 (모델·프롬프트는 CLAUDE.md verbatim) ─────────────────────────
# 개발1팀 기준 모델: openai/gpt-5.6-terra + reasoning medium(= opencode auth login으로 붙인 사용자
# OpenAI 구독 경로. 2026-08-06 gpt-5.5→terra 승급, 08-08 프로바이더 장애로 opencode/ 피신,
# 08-09 워크스페이스 크레딧 소진을 계기로 구독 경로 복귀 — 아래 ModelFallback 주석 참조).
# QA(④) 모델은 Build-ToolCommand의 -m gpt-5.6-sol — codex exec가 직접 OpenAI로 호출하므로
# opencode 프로바이더 네임스페이스(openai/·opencode/·opencode-go/)와 무관하고 이번 장애의 영향을 받지 않는다.
#
# ModelFallback (impl 전용, 2026-08-08 CFG-001 착수 중 openai/ 프로바이더 장애 실측으로 도입):
# opencode 프로바이더 장애로 -m openai/gpt-5.6-terra가 30분 하드 상한까지 완전 무응답으로 멈췄다(로그 0바이트,
# 그런데도 CPU는 계속 소모돼 hang 판정조차 안 뜨고 타임아웃까지 감). 같은 모델을 opencode/ 프로바이더로
# 부르면 즉시 응답 — 문제는 모델이 아니라 openai/ 라우팅이었다. 재발 시 매번 30분을 날리지 않도록,
# 1번째 모델에서 hang·timeout 어느 쪽이 나도 즉시 다음 모델로 넘어간다(같은 모델 재시도 없음 — 이미
# 그 라우팅/모델이 막혔다는 신호이므로).
#
# 체인 구성 원칙: 세 슬롯의 과금·인증 주체를 전부 다르게 둔다. 하나가 막혀도 나머지가 같이 막히지 않는다.
#   1번 openai/       = opencode auth login으로 붙인 사용자 OpenAI 구독(oauth)
#   2번 opencode-go/  = 별도 opencode-go API 키
#   3번 opencode/     = opencode.ai 워크스페이스. big-pickle은 그 안에서 크레딧을 안 쓰는 무료 최후 수단
#
# 이력: 2026-08-08 위 장애로 1번을 openai/ → opencode/ 로 피신시켰으나, 그 결과 1·3번이 모두
# opencode.ai 워크스페이스 과금이 되어 2026-08-09 CS-024에서 워크스페이스 크레딧 소진 하나로 1번이
# 통째로 죽었다(구독은 멀쩡했는데도 안 쓰이고 있었다). 하드 상한 timeout → 다음 모델 폴백이 그 사이
# 도입되어 무응답 hang은 30분 뒤 자동 복구되므로, 1번을 구독 경로(openai/)로 되돌린다.
# 2번 모델은 2026-08-09 kimi-k2.7-code에서 deepseek-v4-flash로 교체(사용자 지시).
# 2026-08-10 베이크오프(6회 실디스패치, 2라운드 × mimo-v2.5-pro/deepseek-v4-flash/deepseek-v4-pro)로
# 2번 슬롯을 deepseek-v4-flash로 확정했다. mimo는 가짜 패킷 생성·완료 보고로 프로토콜을 오염시켰고,
# pro는 같은 산출물에 2.4배 비용이 들었지만 품질 우위가 없었다.
# 쿼터 소진 등 다른 이유로 이 체인이 안 맞으면 -Prompt는 프롬프트만 override하므로 모델은 이 파일에서 고친다.
#
# KillOnHang: 로그 무변화 시 프로세스 트리를 죽여도 되는가.
#   impl/qa 는 재시작이 안전하므로 $true.
#   integration(⑤)은 커밋·푸시를 수행하므로 $false — 도중 kill 시 경합/절반 커밋 위험이다
#   (2026-07-25 ai0033 실측: 이미 커밋이 끝난 ⑤ 프로세스를 워처가 오탐 kill). stream-json 으로
#   flush 빈도를 올려 오탐을 줄였지만, 단일 도구 호출이 길면 여전히 조용할 수 있어 하드 상한에만 위임한다.
# Retry: hang 으로 죽인 뒤 동일 명령으로 1회 재디스패치할 것인가(hang-detect-agent Iron Law — 재시도는 최대 1회).
#   impl은 ModelFallback이 이 역할을 대신하므로 Retry=false(동일 모델 재시도 대신 다음 모델로 즉시 전환).
$StageConfig = @{
    'impl' = @{
        Command = 'opencode run --pure --auto -m {MODEL} --variant medium'
        ModelFallback = @('openai/gpt-5.6-terra', 'opencode-go/deepseek-v4-flash', 'opencode/big-pickle')
        DefaultPrompt = "작업 $TaskId — [②구현] handoff 확인하고 UI/UX 디자인, 프런트엔드, 백엔드, SNS/마케팅 관련 스킬 최대한 적용해서 다음 단계 구현 진행시켜. [③자체리뷰] 1차 구현이 완료되었는데 개발의도 및 계획이 코드에 잘 반영되었는지, 로직과 코드품질이 어떤지 관련스킬을 최대한 적용해서 제로베이스에서 자체 리뷰하고 수정해. 이어서 scripts/verify.ps1 게이트를 통과시키고 Pipeline Status ②③을 갱신해"
        LogFile = "$TaskLogPrefix-impl.log"
        KillOnHang = $true
        Retry = $false
        HangSeconds = 600
    }
    'qa' = @{
        Command = 'codex exec'
        DefaultPrompt = "작업 $TaskId — 개발팀의 1차 구현과 자체 리뷰가 완료되었어. Handoff 확인하고 제로베이스에서 서비스 및 제품 개발 QA 최종 책임자로서 관련스킬 전부 적용해서 구현 및 코드 품질에 대해 리뷰 실시해. 발견한 결함은 직접 수정한 뒤 scripts/verify.ps1 게이트를 통과시키고 Pipeline Status ④를 갱신해. 마지막으로 QA 판정을 .agents/briefs/logs/$TaskId-qa-verdict.json 파일에 JSON으로 남겨 — ⑤ 진행 가능하면 verdict를 pass, 차단성 이슈로 ⑤ 진행 불가면 verdict를 blocked(사유는 reason)로 기록해"
        LogFile = "$TaskLogPrefix-qa.log"
        ReportFile = "$TaskLogPrefix-qa-last.md"
        VerdictFile = "$TaskLogPrefix-qa-verdict.json"
        KillOnHang = $true
        Retry = $true
        # QA retries after a false hang, so use the same conservative threshold as impl.
        HangSeconds = 600
    }
    'integration' = @{
        Command = 'claude'
        DefaultPrompt = "작업 $TaskId — 개발1팀의 구현과 QA팀의 리뷰가 완료되었어. 최종 서비스/제품 개발 및 운영책임자로서 모든 스킬 적용해서 제로베이스에서 문제없는지 리뷰해봐. scripts/verify.ps1 게이트 통과 + 실동작 E2E 검증까지 마치고, 문제없으면 Integration을 완료 처리하고 Pipeline Status ⑤ 갱신 + 커밋·푸시·history.md 기록을 한 세트로 수행해"
        LogFile = "$TaskLogPrefix-integration.log"
        KillOnHang = $false
        Retry = $false
        HangSeconds = 900
    }
}

# ── 헬퍼 ─────────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [ValidateSet('INFO','WARN','ERROR','SUCCESS')]$Level='INFO')
    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
    Write-Host $line
    if ($script:WatcherLogAbs) {
        try {
            [System.IO.File]::AppendAllText($script:WatcherLogAbs, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
        } catch {
            # 워처 로그 실패가 실행 단계 자체를 중단시키면 사후 진단보다 더 큰 장애가 된다.
        }
    }
}

# 워처 판단은 단계 로그와 분리한다. 단계 로그에 하트비트를 쓰면 로그 무변화 감지가 무력화된다.
function Initialize-WatcherLog {
    param([string]$Stage)
    $script:WatcherLogAbs = Resolve-RepoPath "$LogDir/$TaskId-$Stage-watcher.log"
    $parent = Split-Path -Parent $script:WatcherLogAbs
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($script:WatcherLogAbs, '', (New-Object System.Text.UTF8Encoding($false)))
}

# 저장소 상대 경로(bash·프롬프트가 쓰는 형태)를 PowerShell 쪽 절대 경로로 변환.
# 스크립트를 하위 디렉터리에서 실행해도 PS 쪽 파일 조작이 어긋나지 않게 한다.
function Resolve-RepoPath {
    param([string]$RelativePath)
    return (Join-Path $RepoRoot ($RelativePath -replace '/','\'))
}

function Validate-TaskId {
    param([string]$Id)
    # 권장 형식(2026-08-10 통일): PREFIXNNN — 프리픽스 뒤에 숫자만. 예: 001 · AC001 · CS030 · CFG005
    # 하이픈 표기(AC-001, ac-II-042)는 기존 작업 재디스패치를 위해 계속 받되 경고한다.
    if ($Id -notmatch '^(?:[A-Za-z]{1,8}-)?[0-9]{3,}$' -and
        $Id -notmatch '^[A-Za-z]{1,8}[0-9]+$' -and
        $Id -notmatch '^[A-Za-z]{1,3}-[A-Za-z]{1,3}-[0-9]+$') {
        Write-Log "잘못된 작업 ID 형식: $Id (예: 001, AC001, CS030, CFG005)" ERROR
        exit 1
    }
    # TaskId는 락·로그·판정 파일명에 그대로 들어간다($TaskLogPrefix). 라우터 표기와 디스패치 표기가
    # 구분자 하나만 달라도 같은 작업이 두 개의 정체성으로 갈라져 대시보드가 오펀으로 중복 표시한다
    # (2026-08-10 실측: 라우터 `CS-030` ↔ 락/로그 `CS030`).
    if ($Id -match '[^A-Za-z0-9]') {
        Write-Log "⚠️ 작업 ID '$Id'에 구분자가 있습니다. 신규 작업은 '$($Id -replace '[^A-Za-z0-9]','')'처럼 -·공백 없이 만드세요." WARN
        Write-Log "⚠️ 라우터 표기와 한 글자라도 다르면 락·로그가 갈라져 대시보드가 같은 작업을 둘로 봅니다." WARN
    }
}

function Test-ModelIdentifier {
    param([string]$Value)
    return -not [string]::IsNullOrWhiteSpace($Value) -and $Value -match '^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
}

function Assert-ModelIdentifier {
    param([string]$Value, [string]$Source)
    if (-not (Test-ModelIdentifier -Value $Value)) {
        Write-Log "잘못된 모델 식별자 ($Source): $Value" ERROR
        exit 1
    }
}

# bash 실행 파일 경로. PATH에 없어도(예: Git 설치 시 `Git\cmd`만 PATH에 추가되는 기본 구성)
# 표준 설치 위치를 훑어 찾아낸다. 못 찾으면 $null.
function Resolve-BashExe {
    $onPath = Get-Command bash -CommandType Application -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }
    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path $env:ProgramFiles 'Git\usr\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Git\bin\bash.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path $c)) { return $c }
    }
    return $null
}

# bash 작은따옴표 리터럴로 감싼다 — 프롬프트 안의 $·백틱·"가 bash에서 확장되지 않도록.
# 전달되는 프롬프트 문자열 자체는 그대로다(verbatim 원칙 유지).
function ConvertTo-BashSingleQuoted {
    param([string]$Text)
    return "'" + ($Text -replace "'", "'\''") + "'"
}

# 단계별 도구 명령 문자열(리다이렉트 제외 — bash 래퍼에서 처리).
# $Model: ModelFallback 체인을 쓰는 단계(impl)에서 Command의 {MODEL} 자리에 넣을 값. 다른 단계는 무시.
function Build-ToolCommand {
    param([hashtable]$Config, [string]$Stage, [string]$PromptOverride, [string]$Model)
    $p = if ([string]::IsNullOrWhiteSpace($PromptOverride)) { $Config.DefaultPrompt } else { $PromptOverride }
    $q = ConvertTo-BashSingleQuoted $p
    $cmd = if ($Model) { $Config.Command -replace '\{MODEL\}', $Model } else { $Config.Command }
    switch ($Stage) {
        'impl'        { return "$cmd $q" }
        'qa'          { return "$cmd $q -m gpt-5.6-sol -s danger-full-access -o $(ConvertTo-BashSingleQuoted $Config.ReportFile)" }
        'integration' { return "$cmd -p $q --dangerously-skip-permissions --output-format stream-json --verbose" }
    }
}

# UTF-8(BOM 없음) 임시 .sh를 만들어 반환. cd + 도구명령 + </dev/null + 로그 리다이렉트.
function New-DispatchScript {
    param([string]$ToolCmd, [string]$LogFile, [string]$Suffix)
    $shPath = Join-Path ([System.IO.Path]::GetTempPath()) ("dispatch-$Suffix.sh")
    $bashRoot = $RepoRoot -replace '\\','/'
    $body = "cd `"$bashRoot`" || exit 1`n$ToolCmd </dev/null > `"$LogFile`" 2>&1`n"
    [System.IO.File]::WriteAllText($shPath, $body, (New-Object System.Text.UTF8Encoding($false)))
    return $shPath
}

function Stop-ProcessTree {
    param([int]$ProcessId)
    & taskkill /PID $ProcessId /T /F 2>$null | Out-Null
}

# 루트 bash와 그 자식들의 누적 CPU 시간을 합산한다. 실제 에이전트/도구는 bash의
# 자식으로 실행되므로 루트 PID만 보면 조용히 계산 중인 작업을 hang으로 오판한다.
function Get-ProcessTreeMetrics {
    param([int]$RootProcessId)

    $cpu = [TimeSpan]::Zero; [Int64]$io = 0
    $queryStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
    } catch {
        $processes = @()
        $script:CimFailureCount++
        Write-Log "Win32_Process CIM 조회 실패 (누적 $($script:CimFailureCount)회): $($_.Exception.Message)" WARN
    } finally {
        $queryStopwatch.Stop()
    }
    $children = @{}
    $byId = @{}
    foreach ($process in $processes) {
        $byId[[int]$process.ProcessId] = $process
        $parent = [int]$process.ParentProcessId
        if (-not $children.ContainsKey($parent)) {
            $children[$parent] = New-Object 'System.Collections.Generic.List[object]'
        }
        [void]$children[$parent].Add($process)
    }
    $pending = New-Object 'System.Collections.Generic.Queue[int]'
    $seen = @{}
    $pending.Enqueue($RootProcessId)

    while ($pending.Count -gt 0) {
        $processId = $pending.Dequeue()
        if ($seen.ContainsKey($processId)) { continue }
        $seen[$processId] = $true

        try { $cpu += (Get-Process -Id $processId -ErrorAction Stop).TotalProcessorTime } catch { }
        if ($byId.ContainsKey($processId)) {
            $current = $byId[$processId]
            $read = if ($null -eq $current.ReadTransferCount) { 0 } else { [Int64]$current.ReadTransferCount }
            $write = if ($null -eq $current.WriteTransferCount) { 0 } else { [Int64]$current.WriteTransferCount }
            $io += $read + $write
        }
        if ($children.ContainsKey($processId)) {
            foreach ($child in $children[$processId]) {
                $pending.Enqueue([int]$child.ProcessId)
            }
        }
    }
    return @{ Cpu = $cpu; Io = $io; QueryMs = $queryStopwatch.ElapsedMilliseconds; CimFailures = $script:CimFailureCount }
}

# 작업트리 스냅샷 — 단계가 실제로 무언가를 바꿨는지 판정하는 근거.
# 로그 디렉터리는 gitignore 대상이므로 이 스냅샷을 오염시키지 않는다.
function Get-TreeState {
    $head = $null; $dirty = $null; $fingerprint = $null
    Push-Location $RepoRoot
    try {
        $head = (& git rev-parse HEAD 2>$null | Out-String).Trim()
        # 로그 디렉터리는 제외한다 — 디스패치 자체가 로그를 쓰므로, 프로젝트가 이 경로를
        # gitignore 하지 않으면 "무엇도 바꾸지 않은 실행"이 항상 변경으로 보여 경고가 죽는다.
        $logPrefix = ($LogDir.Trim('/')) + '/'
        $dirty = (@(& git status --porcelain 2>$null |
            Where-Object { $_.Length -le 3 -or -not $_.Substring(3).Trim('"').StartsWith($logPrefix) }) -join "`n").Trim()

        # status 문자열은 "이미 수정된 파일을 더 수정한 경우"에도 그대로다. noop 폴백이 실제 편집을
        # 무변경으로 오판하지 않도록 tracked diff와 untracked 파일 내용을 함께 지문화한다.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashText = {
            param([string]$Text)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0) | Out-Null
        }
        # Stream git diff into SHA256 so a large binary diff cannot be duplicated in memory.
        & git diff --binary HEAD -- . 2>$null | ForEach-Object { & $hashText ($_ + "`n") }
        $untracked = @(& git ls-files --others --exclude-standard 2>$null |
            Where-Object { -not $_.Replace('\','/').StartsWith($logPrefix) } |
            Sort-Object)
        foreach ($rel in $untracked) {
            & $hashText "`nuntracked:$rel`n"
            $abs = Join-Path $RepoRoot $rel
            if (Test-Path -LiteralPath $abs -PathType Leaf) {
                & $hashText (Get-FileHash -LiteralPath $abs -Algorithm SHA256).Hash
            }
        }
        try {
            $sha.TransformFinalBlock(@(), 0, 0) | Out-Null
            $fingerprint = ([BitConverter]::ToString($sha.Hash)).Replace('-', '')
        }
        finally { $sha.Dispose() }
    } catch {
        # git 저장소가 아니거나 git이 없는 경우 — 변경 감지는 건너뛴다(경고 전용 기능).
    } finally {
        Pop-Location
    }
    if ([string]::IsNullOrEmpty($head)) { return $null }
    return @{ Head = $head; Dirty = $dirty; Fingerprint = $fingerprint }
}

# ── 동시 디스패치 락 (§3.9 강제) ─────────────────────────────────────────────
# §3.9는 "같은 저장소에서 한 팀에 두 패킷을 동시에 디스패치하지 않는다"를 규정하지만
# 지금까지 문서 규칙일 뿐이었다 — 위반해도 아무 저항이 없고, N≥2에서 무변경 감지·기준점
# 롤백이 조용히 죽기 때문에 위반한 줄도 모른 채 정상처럼 보인다. 여기서 기계로 강제한다.
#
# 단계별로 파일 하나를 쓴다 — "같은 단계 = 같은 팀"이라 판정이 단순해지고 경합도 없다.
# 판정: 같은 단계가 살아 있으면 차단(§3.9 본문) · ⑤가 얽히면 차단(저장소당 하나)
#       · 다른 단계면 경고 후 진행(N=2 조건부 구간).
function Get-LockPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$LockPrefix-$Stage")
}

function Read-DispatchLock {
    param([string]$Stage)
    $p = Get-LockPath $Stage
    if (-not (Test-Path $p)) { return $null }
    $raw = (Get-Content $p -Raw -ErrorAction SilentlyContinue)
    if ([string]::IsNullOrWhiteSpace($raw)) { return $null }
    $parts = $raw.Trim() -split '\|'
    if ($parts.Count -lt 3) { return $null }
    $procId = 0
    if (-not [int]::TryParse($parts[0], [ref]$procId)) { return $null }
    $process = Get-Process -Id $procId -ErrorAction SilentlyContinue
    $alive = $null -ne $process
    $processStartedAt = $null
    if ($alive -and $parts.Count -ge 5) {
        try {
            $processStartedAt = $process.StartTime
            [datetime]$recordedStart = [datetime]::MinValue
            if (-not [datetime]::TryParse($parts[4], [ref]$recordedStart) -or
                [math]::Abs(($processStartedAt - $recordedStart).TotalSeconds) -gt 2) { $alive = $false }
        } catch { $alive = $false }
    }
    return @{ Path = $p; Raw = $raw.Trim(); ProcId = $procId; TaskId = $parts[1]; StartedAt = $parts[2]; ProcessStartedAt = $processStartedAt; Alive = $alive }
}

function Remove-StaleDispatchLock {
    param([hashtable]$Lock)

    # Serialize stale cleanup against other cleaners. Without the exclusive open,
    # two dispatchers can both read an old lock; one replaces it and the other then
    # deletes the newly-created live lock (read/remove TOCTOU).
    $stream = $null
    try {
        $stream = [System.IO.File]::Open($Lock.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8, $true, 1024, $true)
        try { $currentRaw = $reader.ReadToEnd().Trim() } finally { $reader.Dispose() }
        if ($currentRaw -ne $Lock.Raw) { return $false }
    } catch [System.IO.IOException] {
        return $false
    } finally {
        if ($stream) { $stream.Dispose() }
    }

    try {
        Remove-Item -LiteralPath $Lock.Path -Force -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

function Enter-DispatchLock {
    param([string]$Stage)
    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path $logDirAbs)) { New-Item -ItemType Directory -Path $logDirAbs -Force | Out-Null }

    foreach ($s in @('impl','qa','integration')) {
        $lock = Read-DispatchLock $s
        if ($null -eq $lock) { continue }
        if (-not $lock.Alive) {
            if (Remove-StaleDispatchLock -Lock $lock) {
                Write-Log "스테일 락 정리: [$s] PID $($lock.ProcId) 는 이미 종료됨" INFO
            } else {
                Write-Log "⛔ [$s] 락 상태가 정리 중 변경되었습니다. 새 소유자를 지우지 않도록 중단하고 재시도를 요구합니다." ERROR
                Write-BlockedMarker -Stage $Stage -Reason '스테일 락 정리 중 상태 변경' -OwnerTaskId '-' -OwnerProcessId '-'
                return $false
            }
            continue
        }
        if ($s -eq $Stage) {
            Write-Log "⛔ [$Stage]가 이 저장소에서 이미 실행 중 — 작업 $($lock.TaskId), PID $($lock.ProcId), 시작 $($lock.StartedAt)" ERROR
            Write-Log "§3.9: 같은 저장소에서 한 팀에 두 패킷을 동시에 디스패치하지 않는다. 먼저 끝난 뒤 실행하세요." ERROR
            Write-BlockedMarker -Stage $Stage -Reason "[$Stage] 단계가 이미 실행 중" -OwnerTaskId $lock.TaskId -OwnerProcessId $lock.ProcId
            return $false
        }
        if ($s -eq 'integration' -or $Stage -eq 'integration') {
            Write-Log "⛔ ⑤ Integration은 저장소당 하나 — 현재 [$s] 실행 중(작업 $($lock.TaskId), PID $($lock.ProcId))" ERROR
            Write-Log "§3.9: 커밋·푸시·history.md·라우터를 공유하므로 동시 실행 시 병합 충돌·기록 유실이 난다." ERROR
            Write-BlockedMarker -Stage $Stage -Reason 'Integration 단계가 실행 중이라 배타적으로 차단됨' -OwnerTaskId $lock.TaskId -OwnerProcessId $lock.ProcId
            return $false
        }
        Write-Log "⚠️ 같은 저장소에서 [$s](작업 $($lock.TaskId))가 병행 중 — §3.9 상한표상 N=2 조건부 구간" WARN
        Write-Log "⚠️ 무변경 감지·기준점 롤백이 무력화되고, verify가 남의 중간 상태 때문에 실패할 수 있습니다." WARN
    }

    # 재실행은 이전 실패 판정을 무효화한다 — 대시보드가 RUNNING 옆에 낡은 FAILED를 같이 들고 있지 않도록.
    Clear-FailureMarker -Stage $Stage
    Clear-BlockedMarker -Stage $Stage

    $processStartedAt = (Get-Process -Id $PID -ErrorAction Stop).StartTime.ToString('o')
    $body = "$PID|$TaskId|$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))|$env:COMPUTERNAME|$processStartedAt"
    try {
        $stream = [System.IO.File]::Open((Get-LockPath $Stage), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $writer = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
            try { $writer.Write($body) } finally { $writer.Dispose() }
        } finally { $stream.Dispose() }
        $script:ActiveLockStage = $Stage
        return $true
    } catch [System.IO.IOException] {
        $lock = Read-DispatchLock $Stage
        if ($lock -and $lock.Alive) {
            Write-Log "⛔ [$Stage] 락 획득 경합 — 작업 $($lock.TaskId), PID $($lock.ProcId)가 먼저 시작됨" ERROR
            Write-BlockedMarker -Stage $Stage -Reason '락 파일 생성 경합' -OwnerTaskId $lock.TaskId -OwnerProcessId $lock.ProcId
            return $false
        }
        Write-Log "⛔ [$Stage] 락 파일 생성 경합 후 상태를 확정할 수 없습니다. 재시도하세요." ERROR
        Write-BlockedMarker -Stage $Stage -Reason '락 파일 생성 경합 후 점유자 상태를 확정할 수 없음' -OwnerTaskId '-' -OwnerProcessId '-'
        return $false
    }
}

function Exit-DispatchLock {
    param([string]$Stage)
    $p = Get-LockPath $Stage
    $lock = Read-DispatchLock $Stage
    if ($lock -and $lock.ProcId -eq $PID -and $lock.TaskId -eq $TaskId) {
        Remove-Item $p -Force -ErrorAction SilentlyContinue
    }
    # 락 해제 시 자기 TaskId/Stage의 blocked 마커도 함께 지운다. 실행 도중 재귀·다른 경로에서
    # 같은 TaskId/Stage로 디스패치를 시도해 blocked 마커가 찍히면, Clear-BlockedMarker는
    # 락 획득 시점에만 도므로 그 이후에 생긴 마커는 성공 후에도 잔존한다(CFG-BL-013).
    Clear-BlockedMarker -Stage $Stage
    if ($script:ActiveLockStage -eq $Stage) { $script:ActiveLockStage = $null }
}

# ── 실패 마커 ────────────────────────────────────────────────────────────────
# 락은 finally에서 지워지므로, 모델 체인이 전부 소진돼 중단돼도 대시보드에는 다시 IDLE로 보인다 —
# "실패로 멈춤"과 "아직 시작 안 함"이 구분되지 않아, 창을 안 보고 있으면 실패 사실 자체가 유실된다
# (2026-08-09 CS-024: 60분을 태우고 중단됐는데 남은 흔적은 워처 로그 텍스트뿐이었다).
# 실패 시 마커를 남기고, 같은 단계를 다시 디스패치하거나 성공하면 지운다.
# 락과 같은 로그 디렉터리에 둔다 — Get-TreeState가 이미 이 경로를 걸러내므로 무변경 감지를 오염시키지 않는다.
$FailedPrefix = "$LogDir/.dispatch-failed"

function Get-FailureMarkerPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$FailedPrefix-$TaskId-$Stage")
}

function Clear-FailureMarker {
    param([string]$Stage)
    $p = Get-FailureMarkerPath $Stage
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

function Write-FailureMarker {
    param([string]$Stage, [string]$Reason)
    $state = Get-TreeState
    if ($null -ne $state -and -not [string]::IsNullOrWhiteSpace($state.Dirty)) { $dirty = 1 } else { $dirty = 0 }
    # 파이프는 필드 구분자다. 사유 문구에 섞여 들어오면 대시보드 파싱이 어긋나므로 치환한다.
    $safeReason = ($Reason -replace '\|', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($safeReason)) { $safeReason = '알 수 없는 실패' }
    $body = "$TaskId|$Stage|$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))|$safeReason|$dirty"
    try {
        [System.IO.File]::WriteAllText((Get-FailureMarkerPath $Stage), $body, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "실패 마커 기록: $FailedPrefix-$TaskId-$Stage ($safeReason)" WARN
    } catch {
        # 마커를 못 써도 단계 결과 자체를 뒤집지 않는다 — 사유는 이미 워처 로그에 남아 있다.
    }
}

# ── 차단 마커 ────────────────────────────────────────────────────────────────
# 차단은 실패와 해소 방법이 다르다. 실패 마커와 합치지 않아 대시보드가 재시도 판단을 보존한다.
$BlockedPrefix = "$LogDir/.dispatch-blocked"

function Get-BlockedMarkerPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$BlockedPrefix-$TaskId-$Stage")
}

function Clear-BlockedMarker {
    param([string]$Stage)
    $p = Get-BlockedMarkerPath $Stage
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

function Write-BlockedMarker {
    param([string]$Stage, [string]$Reason, [string]$OwnerTaskId, [string]$OwnerProcessId)
    $safeReason = ($Reason -replace '\|', '/').Trim()
    if ([string]::IsNullOrWhiteSpace($safeReason)) { $safeReason = '알 수 없는 차단' }
    if ([string]::IsNullOrWhiteSpace($OwnerTaskId)) { $OwnerTaskId = '-' }
    if ([string]::IsNullOrWhiteSpace($OwnerProcessId)) { $OwnerProcessId = '-' }
    $body = "$TaskId|$Stage|$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))|$safeReason|$OwnerTaskId|$OwnerProcessId"
    try {
        [System.IO.File]::WriteAllText((Get-BlockedMarkerPath $Stage), $body, (New-Object System.Text.UTF8Encoding($false)))
        Write-Log "차단 마커 기록: $BlockedPrefix-$TaskId-$Stage ($safeReason)" WARN
    } catch {
        # 차단 마커를 못 써도 실제 락 판정은 바꾸지 않는다.
    }
}

# 강제 종료(hang·하드 상한)가 트리에 무엇을 남겼는지 보고한다.
# 재시도는 이 더러운 트리 위에서 그대로 다시 시작하므로, 반쪽 편집 위에 편집이 쌓일 수 있다.
# 스크립트는 이미 직전 상태($before)를 쥐고 있었는데 무변경 경고에만 쓰고 있었다.
function Write-KilledLeftover {
    param([hashtable]$Before, [string]$Stage, [string]$Context)
    $after = Get-TreeState
    if ($null -eq $Before -or $null -eq $after) { return }
    if ($Before.Head -ne $after.Head) {
        Write-Log "⚠️ [$Stage] $Context — 죽기 전에 커밋까지 진행됨 (HEAD $($Before.Head) → $($after.Head))" WARN
    }
    if ($Before.Dirty -ne $after.Dirty -or $Before.Fingerprint -ne $after.Fingerprint) {
        Write-Log "⚠️ [$Stage] $Context — 반쯤 편집된 작업트리가 남았습니다:" WARN
        @($after.Dirty -split "`n") | Where-Object { $_ } | Select-Object -First 20 | ForEach-Object { Write-Host "    $_" }
        Write-Log "복구: 기준점(§3.1)으로 되돌리려면 git checkout -- <경로> / 보존하려면 git stash push -m '$TaskId $Stage 중단분'" WARN
    } else {
        Write-Log "[$Stage] $Context — 작업트리 변경 없음(깨끗한 상태에서 중단)" INFO
    }
}

# 모델 전환이 안전한 실패를 순수하게 분류한다. 코드 작업 중 우연히 같은 단어가 나오는 오탐을 막기 위해
# 과금·가용성 문구는 좁게 고정하고, 무패턴 전환은 산출 없는 조기 실패 네 조건을 모두 요구한다.
function Get-SwitchableFailureClass {
    param([string]$Tail, [int64]$LogBytes, [double]$ElapsedSeconds, [bool]$TreeChanged, [int64]$LogStartBytes = 0)

    $patterns = @(
        'Insufficient balance',
        'insufficient_quota',
        'insufficient credit',
        'credit balance is too low',
        'quota exceeded',
        'exceeded your current quota',
        'Payment Required'
    )
    foreach ($p in $patterns) {
        if ($Tail -match [regex]::Escape($p)) { return 'billing' }
    }

    $unavailablePatterns = @(
        'only available hosted in China',
        'requires explicit opt in',
        'model not found',
        'Unknown model',
        'No such model',
        'model is not available',
        'invalid api key',
        '401 Unauthorized',
        '403 Forbidden',
        # 맨 '429'는 쓰지 않는다 — 부분 문자열 매칭이라 스택트레이스 줄번호('line 429')·소요시간
        # ('429ms')·바이트수·커밋해시에 걸려 진짜 구현 실패를 모델 전환 사유로 오판했다
        # (2026-08-10 CFG-004 ⑤ 실측). 레이트리밋은 아래 문구형 두 개로 잡는다.
        'HTTP 429',
        'Too Many Requests',
        'rate limit exceeded'
    )
    foreach ($p in $unavailablePatterns) {
        if ($Tail -match [regex]::Escape($p)) { return 'unavailable' }
    }

    # The no-output guard measures bytes written by this attempt, not historical log size.
    # Attempt logs start at zero today; retaining the offset keeps this contract safe if that changes.
    $logGrowth = [math]::Max(0, $LogBytes - $LogStartBytes)
    if ($logGrowth -lt 2KB -and $ElapsedSeconds -lt 60 -and -not $TreeChanged) {
        return 'noop'
    }
    return ''
}

# 프로세스 1회 실행 + hang/하드타임아웃 감시.
# 반환: 'ok'(정상 종료) · 'hang'(무변화로 강제 종료) · 'timeout'(하드 상한 초과로 강제 종료)
# 정상 종료 시 [ref]$ExitCode 에 종료 코드를 담는다($null이면 읽기 실패).
function Invoke-StageProcess {
    param([string]$Stage, [hashtable]$Config, [string]$ToolCmd, [ref]$ExitCode, [ref]$ElapsedSeconds)

    $logRel = $Config.LogFile
    $logAbs = Resolve-RepoPath $logRel
    $hangLimit = if ($Config.HangSeconds) { $Config.HangSeconds } else { $HangWaitSeconds }
    $hardLimit = if ($Config.HardTimeoutMinutes) { $Config.HardTimeoutMinutes } else { $HardTimeoutMinutes }
    # 하드 상한 유연화(2026-08-09 CS-024): 로그가 꾸준히 늘어나는 프로세스를 고정 상한에서 죽이면
    # 멀쩡히 일하던 구현이 통째로 날아간다(실측: 5분당 +3.9KB를 내던 모델이 30분에 강제 종료).
    # 상한에 닿았을 때 진행 중이면 $extendStep 만큼 연장하고, 절대 상한에서는 무조건 끊는다.
    # 노브를 늘리지 않으려고 연장 폭·절대 상한을 기본 상한에서 파생시킨다 —
    # -HardTimeoutMinutes 하나만 줄이면 셋 다 비례해 줄어 짧은 시간에 E2E 검증이 가능하다.
    $hardMax = $hardLimit * 3
    $extendStep = [Math]::Max(1, [Math]::Round($hardLimit / 3.0, 2))

    $shPath = New-DispatchScript -ToolCmd $ToolCmd -LogFile $logRel -Suffix ([guid]::NewGuid().ToString("N"))
    $startedAt = $null
    # hang·하드 상한으로 "정책상" 끊은 경우를 표시한다. taskkill은 종료를 요청만 하므로 직후
    # $proc.HasExited가 아직 $false일 수 있어, 생존 여부로 중단을 판정하면 정상 종료 경로에서
    # 중단 로그가 뜨고 이미 죽은(재활용됐을 수도 있는) PID를 한 번 더 죽이게 된다.
    $policyKilled = $false
    try {
        $startedAt = Get-Date
        $proc = Start-Process -FilePath $script:BashExe -ArgumentList @($shPath) -NoNewWindow -PassThru
        $script:ActiveChildProcessId = $proc.Id; $script:ActiveChildStage = $Stage
        # Windows PowerShell 5.1은 Start-Process -PassThru의 Process 핸들을 미리 캐시하지 않으면
        # 종료 뒤 ExitCode가 $null로 남을 수 있다. 여기서 Handle을 한 번 읽어 캐시한다.
        $null = $proc.Handle
        Write-Log "진행 시작 [$Stage] (PID: $($proc.Id), 명령: $ToolCmd) — 실시간: Get-Content $logRel -Wait" INFO

        # 로그 무변화(hang) 감지 + 하드 상한 + 프로세스 종료 대기: 단일 루프로 전 구간 감시.
        # 요청한 임계값보다 늦게 감지하지 않도록 점검 간격을 제한한다. 로그 파일이 아직
        # 만들어지지 않은 경우도 무출력 상태이므로 0바이트로 취급한다.
        $deadline = $startedAt.AddMinutes($hardLimit)
        $absoluteDeadline = $startedAt.AddMinutes($hardMax)
        $lastSize = 0; $lastLogChangedAt = $startedAt; $hangReported = $false
        # 연장 판정용 롤링 창 — $extendStep 마다 그 구간의 로그 증가량을 확정한다.
        $windowStartAt = $startedAt; $windowStartSize = 0; $lastWindowGrowth = 0
        $idleStartedMetrics = Get-ProcessTreeMetrics -RootProcessId $proc.Id
        $lastHeartbeatAt = $startedAt; $lastHeartbeatSize = 0; $lastHeartbeatCpu = $idleStartedMetrics.Cpu
        $interval = [Math]::Min(10, [Math]::Max(1, $hangLimit))
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds $interval
            # 대기 중 정상 종료된 무출력 프로세스를 hang 임계 도달로 오판하지 않는다.
            # 특히 종료 시점이 임계 직전이면 이 재확인 없이 아래 noChange가 임계에 닿아
            # 이미 끝난 정상 프로세스를 'hang'으로 반환할 수 있다.
            $proc.Refresh()
            if ($proc.HasExited) { break }
            $sz = if (Test-Path $logAbs) { (Get-Item $logAbs).Length } else { 0 }
            $logChanged = $sz -ne $lastSize
            if ($logChanged) { $lastLogChangedAt = Get-Date; $lastSize = $sz; $hangReported = $false }
            $noChange = [math]::Max(0, ((Get-Date) - $lastLogChangedAt).TotalSeconds)
            # 아래에서 $noChange를 증가율의 '분모'로 그대로 쓰므로 값 자체를 반올림하지 않는다.
            # 사람이 읽는 로그 문구에만 반올림한 별도 변수를 쓴다.
            $noChangeText = [math]::Round($noChange)

            # 자식 에이전트/도구를 포함한 트리 CPU. 무변화 구간의 '증가율'로 hang을 판정하므로,
            # 기준점($idleStartedCpu)은 로그가 변한 시점에만 리셋한다 — CPU 변화로도 리셋하면
            # 아래 계산이 늘 직전 한 틱만 보게 되어 판정이 무의미해진다.
            $metricsNow = Get-ProcessTreeMetrics -RootProcessId $proc.Id
            $cpuNow = $metricsNow.Cpu
            if ($logChanged) { $idleStartedMetrics = $metricsNow }

            # 연장 판정용 창 확정. 창 길이를 연장 폭과 맞춰 "최근 한 연장분 동안 진행이 있었나"를 본다.
            if (((Get-Date) - $windowStartAt).TotalMinutes -ge $extendStep) {
                $lastWindowGrowth = [math]::Max(0, $sz - $windowStartSize)
                $windowStartAt = Get-Date; $windowStartSize = $sz
            }

            if (((Get-Date) - $lastHeartbeatAt).TotalSeconds -ge 300) {
                $elapsed = [math]::Floor(((Get-Date) - $startedAt).TotalMinutes)
                # 재시도는 같은 단계 로그를 `>`로 다시 열어 크기가 줄 수 있다.
                # 하트비트는 증가량을 표시하므로 truncate 구간은 0으로 clamp한다.
                $logDelta = [math]::Max(0, $sz - $lastHeartbeatSize)
                # 종료된 자식은 다음 트리 샘플에서 빠질 수 있으므로 음수 증분은 0으로 표시한다.
                $cpuDelta = [math]::Max(0, [math]::Round(($cpuNow - $lastHeartbeatCpu).TotalSeconds, 2))
                Write-Log "진행중 [$Stage] 경과 ${elapsed}분 · 로그 +${logDelta}B · 트리 CPU +${cpuDelta}s · CIM $($metricsNow.QueryMs)ms · CIM 실패 $($metricsNow.CimFailures)회" INFO
                $lastHeartbeatAt = Get-Date; $lastHeartbeatSize = $sz; $lastHeartbeatCpu = $cpuNow
            }

            if ($noChange -ge $hangLimit) {
                # CPU '증가 여부'가 아니라 '증가율'로 판정한다(2026-08-09 CS-024).
                # 정지한 프로세스도 폴링·타이머로 초당 수십 ms는 태우므로, 조금이라도 늘면 살려주던
                # 기존 가드(CS-022)는 사실상 hang을 영원히 잡지 못했다 — 실측에서 로그 +0B가 15분
                # 이어지는 동안 코어 1.5%만 태우던 프로세스가 하드 상한까지 20분을 그냥 버렸다.
                $idleCpuDelta = [math]::Max(0, [math]::Round(($cpuNow - $idleStartedMetrics.Cpu).TotalSeconds, 2))
                $idleIoDelta = [math]::Max(0, $metricsNow.Io - $idleStartedMetrics.Io)
                $ratePct = [math]::Round(($idleCpuDelta / $noChange) * 100, 1)
                $ioRate = [math]::Round($idleIoDelta / $noChange, 0)
                $thresholdPct = [math]::Round($BusyCpuRate * 100, 1)
                if (($idleCpuDelta / $noChange) -ge $BusyCpuRate) {
                    # CS-022의 의도(조용히 계산 중인 에이전트를 죽이지 않는다)는 여기서 그대로 유지된다.
                    Write-Log "[$Stage] 로그 무변화 ${noChangeText}초지만 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}%) — 계산 중으로 보고 계속 대기" INFO
                    $lastLogChangedAt = Get-Date; $idleStartedMetrics = $metricsNow; $hangReported = $false
                } elseif (($idleIoDelta / $noChange) -ge $BusyIoBytesPerSec) {
                    Write-Log "[$Stage] 로그 무변화 ${noChangeText}초지만 트리 I/O +${idleIoDelta}B(${ioRate}B/s) — I/O 작업 중으로 보고 계속 대기" INFO
                    $lastLogChangedAt = Get-Date; $idleStartedMetrics = $metricsNow; $hangReported = $false
                } elseif ($Config.KillOnHang) {
                    Write-Log "⚠️ hang 감지 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 프로세스 트리 종료" WARN
                    Stop-ProcessTree $proc.Id
                    $policyKilled = $true
                    Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" WARN
                    return 'hang'
                } elseif (-not $hangReported) {
                    Write-Log "⚠️ hang 후보 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 커밋·푸시 단계라 하드 상한까지 대기" WARN
                    $hangReported = $true
                }
            }
            if ((Get-Date) -gt $deadline) {
                # 확정된 직전 창과 진행 중인 창 중 큰 쪽을 본다 — 창 경계 직후에 상한이 걸려
                # 진행 중인 프로세스가 "이번 창은 아직 0B"라는 이유로 죽는 일을 막는다.
                $growth = [math]::Max($lastWindowGrowth, [math]::Max(0, $sz - $windowStartSize))
                if ($growth -ge $HardTimeoutProgressBytes -and $deadline -lt $absoluteDeadline) {
                    $deadline = $deadline.AddMinutes($extendStep)
                    if ($deadline -gt $absoluteDeadline) { $deadline = $absoluteDeadline }
                    $remain = [math]::Round(($absoluteDeadline - (Get-Date)).TotalMinutes, 1)
                    Write-Log "⏳ 하드 상한 연장 [$Stage] — 최근 ${extendStep}분 로그 +${growth}B(진행 중), 절대 상한(${hardMax}분)까지 ${remain}분 남음" WARN
                } else {
                    if ($deadline -ge $absoluteDeadline) { $why = "절대 상한 ${hardMax}분 도달" }
                    else { $why = "최근 ${extendStep}분 로그 +${growth}B < ${HardTimeoutProgressBytes}B(정체)" }
                    $spent = [math]::Round(((Get-Date) - $startedAt).TotalMinutes, 1)
                    Write-Log "⛔ 하드 상한 초과 [$Stage] — $why; 경과 ${spent}분, 로그 $sz B, 트리 CPU +$([math]::Round($cpuNow.TotalSeconds, 2))s; 프로세스 트리 종료" ERROR
                    Stop-ProcessTree $proc.Id
                    $policyKilled = $true
                    Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" ERROR
                    return 'timeout'
                }
            }
        }

        $proc.WaitForExit()
        $ExitCode.Value = $proc.ExitCode
        Write-Log "진행 완료 [$Stage] (PID: $($proc.Id), Exit Code: $($proc.ExitCode), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" INFO
        return 'ok'
    } finally {
        if ($null -ne $startedAt) {
            $ElapsedSeconds.Value = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)
        }
        # Ctrl+C(파이프라인 중단)는 이 finally를 **동기적으로** 먼저 실행한다. 비동기 이벤트
        # 액션(Invoke-DispatcherCleanup)은 그 뒤에야 큐에서 돌기 때문에, 여기서 추적 변수를
        # 그냥 비우면 정리 함수가 항상 $null을 보고 아무것도 못 한다 — 모델 자식 프로세스가
        # 살아남아 다음 디스패치와 같은 저장소를 동시에 쓴다(§3.9가 막으려던 바로 그 상태).
        # 자식이 아직 살아 있다는 건 정상 종료가 아니라는 뜻이므로, 여기서 직접 끊는다.
        # 정리 함수 쪽 경로도 그대로 두어, finally가 돌지 않는 경우에도 한쪽은 반드시 걸린다
        # (양쪽 다 $script:CleanupStarted / HasExited로 중복 실행을 막는다).
        if ($proc -and -not $policyKilled -and -not $proc.HasExited) {
            if ($Stage -eq 'integration') {
                Write-Log "⚠️ 디스패처 중단 — integration PID $($proc.Id)는 커밋/푸시 단계라 자동 종료하지 않는다." WARN
            } else {
                Stop-ProcessTree $proc.Id
                Write-Log "디스패처 중단 — 자식 프로세스 트리 종료 PID $($proc.Id)" WARN
            }
        }
        Remove-Item $shPath -ErrorAction SilentlyContinue
        $script:ActiveChildProcessId = $null; $script:ActiveChildStage = $null
    }
}

function Resolve-ModelChain {
    param([hashtable]$Config, [string]$Stage)

    # PS 5.1 주의: `$models = if (...) {...} else { @($null) }` 형태로 쓰면 @($null)이
    # 단일 원소 언랩으로 $models 자체가 $null이 되어버린다(2026-08-08 CFG-001 QA 무동작 실측 —
    # while ($modelIndex -lt $models.Count)가 0 -lt 0으로 죽어 프로세스가 아예 안 뜸). 분기 안에서
    # 직접 대입해야 배열이 보존된다.
    if ($config.ModelFallback) { $models = $config.ModelFallback } else { $models = @($null) }

    # -Model: 작업 성격에 맞는 1번 모델을 기획 단계에서 지정한다(예: 리팩토링 위주면 코딩 특화 모델).
    # 폴백 체인의 나머지는 '이 모델/프로바이더가 막혔을 때의 탈출 경로'라 성격과 무관하게 유지해야 하므로,
    # 지정 모델을 맨 앞에 놓고 나머지를 뒤에 붙인다(중복 제거 — 같은 모델을 두 번 부르지 않는다).
    # $script: 로 명시하는 이유: 아래 루프가 로컬 $model에 대입하는데 PowerShell 변수명은
    # 대소문자를 구분하지 않아 그 뒤로는 스크립트 파라미터 $Model이 가려진다. 여기선 아직 가려지기
    # 전이지만, 루프 순서가 바뀌면 조용히 잘못된 값을 읽게 되므로 스코프를 못박아 둔다.
    if ($config.ModelFallback -and -not [string]::IsNullOrWhiteSpace($script:Model)) {
        $picked = $script:Model
        $rest = @($config.ModelFallback | Where-Object { $_ -ne $picked })
        $models = @($picked) + $rest
        Write-Log "[$Stage] 1번 모델 override: $picked (폴백: $($rest -join ' → '))" INFO
    }

    # 슬롯은 서로 다른 과금·인증 주체여야 한 슬롯의 장애가 체인 전체를 막지 않는다.
    # -Model override 뒤의 실제 목록으로 검사해 DryRun에서도 구성 실수를 바로 드러낸다.
    $providers = @{}
    for ($i = 0; $i -lt $models.Count; $i++) {
        $candidate = $models[$i]
        if ([string]::IsNullOrWhiteSpace($candidate) -or $candidate -notmatch '/') { continue }
        $provider = $candidate.Split('/')[0]
        if (-not $providers.ContainsKey($provider)) { $providers[$provider] = @() }
        $providers[$provider] += ($i + 1)
    }
    foreach ($provider in $providers.Keys) {
        if ($providers[$provider].Count -gt 1) {
            $slots = ($providers[$provider] | ForEach-Object { "${_}번" }) -join ', '
            Write-Log "⚠️ [$Stage] 폴백 체인에 프로바이더가 중복됩니다: $provider ($slots) — 한쪽이 막히면 같이 막힙니다" WARN
        }
    }

    # Preserve a one-slot chain for stages without ModelFallback. PowerShell unwraps a
    # one-item array on normal return, turning @($null) into $null for the caller.
    return ,$models
}

function Get-AttemptLogPath {
    param([string]$LogFile, [int]$AttemptNumber)
    $extension = [System.IO.Path]::GetExtension($LogFile)
    $base = $LogFile.Substring(0, $LogFile.Length - $extension.Length)
    return "${base}.attempt${AttemptNumber}${extension}"
}

function Update-LatestAttemptLog {
    param([string]$AttemptLog, [string]$LatestLog)
    $attemptAbs = Resolve-RepoPath $AttemptLog
    $latestAbs = Resolve-RepoPath $LatestLog
    if (-not (Test-Path $attemptAbs)) { return }
    [System.IO.File]::Copy($attemptAbs, $latestAbs, $true)
}

function Invoke-ModelAttempt {
    param([string]$Stage, [hashtable]$Config, [string]$ToolCmd, [string]$AttemptLog, [string]$LatestLog)

    $attemptConfig = @{}
    foreach ($key in $Config.Keys) { $attemptConfig[$key] = $Config[$key] }
    $attemptConfig.LogFile = $AttemptLog
    # 시도 시작 시점의 로그 크기를 기록한다. noop 판정이 절대 크기가 아니라 이 시도가 쓴 증가량을
    # 봐야 하므로, 시작 오프셋을 측정해 Classify-AttemptFailure에 넘겨야truncate/공유 로그로 바뀌어도
    # CFG-004의 무산출 안전망이 살아있다. 현재는 매 시도 새 파일이라 항상 0이지만, 계약을 이곳에서 확정한다.
    $attemptLogAbs = Resolve-RepoPath $AttemptLog
    $logStartBytes = if (Test-Path $attemptLogAbs) { (Get-Item $attemptLogAbs).Length } else { 0 }
    $exit = $null; $elapsedSeconds = 0
    $outcome = Invoke-StageProcess -Stage $Stage -Config $attemptConfig -ToolCmd $ToolCmd -ExitCode ([ref]$exit) -ElapsedSeconds ([ref]$elapsedSeconds)
    Update-LatestAttemptLog -AttemptLog $AttemptLog -LatestLog $LatestLog
    return @{ Outcome = $outcome; ExitCode = $exit; ElapsedSeconds = $elapsedSeconds; LogStartBytes = $logStartBytes }
}

function Classify-AttemptFailure {
    param([hashtable]$Attempt, [hashtable]$Before, [string]$AttemptLog)

    $outcome = $Attempt.Outcome
    if ($outcome -ne 'ok' -or $null -eq $Attempt.ExitCode -or $Attempt.ExitCode -eq 0) { return $outcome }
    $logAbs = Resolve-RepoPath $AttemptLog
    $logBytes = if (Test-Path $logAbs) { (Get-Item $logAbs).Length } else { 0 }
    $tail = if (Test-Path $logAbs) { (Get-Content $logAbs -Tail 40 -ErrorAction SilentlyContinue) -join "`n" } else { '' }
    $afterAttempt = Get-TreeState
    $treeChanged = $null -eq $Before -or $null -eq $afterAttempt -or
        $Before.Head -ne $afterAttempt.Head -or $Before.Dirty -ne $afterAttempt.Dirty
    if (-not $treeChanged) { $treeChanged = $Before.Fingerprint -ne $afterAttempt.Fingerprint }
    $startBytes = if ($Attempt.ContainsKey('LogStartBytes')) { $Attempt.LogStartBytes } else { 0 }
    return (Get-SwitchableFailureClass -Tail $tail -LogBytes $logBytes -ElapsedSeconds $Attempt.ElapsedSeconds -TreeChanged $treeChanged -LogStartBytes $startBytes)
}

function Invoke-VerifyGate {
    param([string]$Stage)

    Write-Log "검증 게이트(scripts/verify.ps1) 실행..." INFO
    $verifyLogRel = "$LogDir/$TaskId-verify-$Stage.log"
    $verifyLogAbs = Resolve-RepoPath $verifyLogRel
    # PS 5.1: 이 파일은 전역이 $ErrorActionPreference='Stop'인데, native 명령의 stderr를 2>&1로
    # 성공 스트림에 합치면 stderr 한 줄마다 NativeCommandError가 terminating error로 승격된다.
    # verify가 exit 0으로 끝나도 하위 프로세스(테스트 러너 등)가 stderr를 한 줄만 쓰면 디스패치
    # 스크립트 전체가 그 자리에서 죽어 — 폴백도 실패 마커도 남지 않는다. 이 호출 구간만 Continue로 낮춘다.
    $verifyOut = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-$TaskId-$Stage-$([guid]::NewGuid().ToString('N')).out")
    $verifyErr = Join-Path ([System.IO.Path]::GetTempPath()) ("verify-$TaskId-$Stage-$([guid]::NewGuid().ToString('N')).err")
    $verifyMinutes = [Math]::Max(5, $HardTimeoutMinutes)
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $verify = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'scripts\verify.ps1')) -NoNewWindow -PassThru -RedirectStandardOutput $verifyOut -RedirectStandardError $verifyErr
        $null = $verify.Handle
        if (-not $verify.WaitForExit($verifyMinutes * 60 * 1000)) {
            Stop-ProcessTree $verify.Id
            $script:LastFailureReason = 'verify 게이트 시간 초과'
            Write-Log "❌ [$Stage] verify 게이트가 ${verifyMinutes}분 안에 끝나지 않아 종료했습니다" ERROR
            return $false
        }
        $verifyExit = $verify.ExitCode
        $verifyEncoding = [Console]::OutputEncoding
        $verifyOutput = @()
        foreach ($capture in @($verifyOut, $verifyErr)) {
            if (-not (Test-Path $capture)) { continue }
            $captureText = [System.IO.File]::ReadAllText($capture, $verifyEncoding)
            if ($captureText.Length -gt 0) { $verifyOutput += ($captureText.TrimEnd("`r", "`n") -split "`r?`n") }
        }
    } finally {
        $ErrorActionPreference = $prevEap
        Remove-Item $verifyOut, $verifyErr -ErrorAction SilentlyContinue
    }
    $verifyOutput | Out-File $verifyLogAbs -Encoding UTF8
    if ($verifyExit -ne 0) {
        Write-Log "❌ [$Stage] 검증 게이트 실패 — verify 로그: $verifyLogRel" ERROR
        $script:LastFailureReason = "verify 게이트 실패 ($verifyLogRel)"
        Write-Log "마지막 30줄:" WARN
        $verifyOutput | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" }
        return $false
    }
    return $true
}

# 한 단계 디스패치 + hang 감지 + 판정. 성공(종료 코드 정상 + verify 통과) 시 $true.
# ModelFallback이 있는 단계(impl)는 모델을 바꿔가며 순서대로 시도한다 — 같은 모델을 두 번 부르지 않는다.
function Dispatch-Stage {
    param([string]$Stage, [string]$PromptOverride)
    $config = $StageConfig[$Stage]
    $logRel = $config.LogFile
    $models = Resolve-ModelChain -Config $config -Stage $Stage

    if ($models.Count -eq 0) {
        $script:LastFailureReason = '모델 체인이 비어 있음 — 단계 구성 오류'
        Write-Log "❌ [$Stage] $script:LastFailureReason" ERROR
        return $false
    }

    if ($DryRun) {
        # 임시 파일을 남기지 않고 실제로 실행될 .sh 본문을 그대로 보여준다(체인 1번째 모델 기준).
        $toolCmd = Build-ToolCommand -Config $config -Stage $Stage -PromptOverride $PromptOverride -Model $models[0]
        Write-Log "작업 $TaskId [$Stage] 디스패치" INFO
        Write-Log "명령: $toolCmd" INFO
        Write-Log "로그: $logRel" INFO
        $shPath = New-DispatchScript -ToolCmd $toolCmd -LogFile $logRel -Suffix "dryrun-$TaskId-$Stage"
        try {
            Write-Log "[DryRun] 실행 생략 — 생성될 bash 스크립트:" WARN
            Write-Host ([System.IO.File]::ReadAllText($shPath, [System.Text.UTF8Encoding]::new($false)))
        } finally {
            Remove-Item $shPath -ErrorAction SilentlyContinue
        }
        return $true
    }

    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path $logDirAbs)) { New-Item -ItemType Directory -Path $logDirAbs -Force | Out-Null }
    Initialize-WatcherLog -Stage $Stage

    # ④ QA: 이전 실행이 남긴 verdict·보고서를 먼저 지운다.
    # 이번 실행이 verdict를 쓰지 못하고 끝났을 때 직전 실행의 pass를 재사용해 ⑤로 넘어가는 오탐을 막는다.
    if ($Stage -eq 'qa') {
        foreach ($rel in @($config.VerdictFile, $config.ReportFile)) {
            $abs = Resolve-RepoPath $rel
            if (Test-Path $abs) {
                Remove-Item $abs -Force
                Write-Log "이전 실행 산출물 삭제: $rel" INFO
            }
        }
        $script:QaDispatchedAt = Get-Date
    }

    $before = Get-TreeState

    $exit = $null
    $outcome = $null
    $attemptFailures = @()
    $modelIndex = 0
    $attemptNumber = 0
    while ($modelIndex -lt $models.Count) {
        $model = $models[$modelIndex]
        $toolCmd = Build-ToolCommand -Config $config -Stage $Stage -PromptOverride $PromptOverride -Model $model
        $modelTag = if ($model) { " (모델 $($modelIndex + 1)/$($models.Count): $model)" } else { "" }
        Write-Log "작업 $TaskId [$Stage] 디스패치$modelTag" INFO
        Write-Log "명령: $toolCmd" INFO
        Write-Log "로그: $logRel" INFO

        $attempt = 1
        while ($true) {
            $attemptNumber++
            $attemptLog = Get-AttemptLogPath -LogFile $logRel -AttemptNumber $attemptNumber
            Write-Log "시도 로그: $attemptLog (latest: $logRel)" INFO
            $attemptResult = Invoke-ModelAttempt -Stage $Stage -Config $config -ToolCmd $toolCmd -AttemptLog $attemptLog -LatestLog $logRel
            $exit = $attemptResult.ExitCode
            $outcome = Classify-AttemptFailure -Attempt $attemptResult -Before $before -AttemptLog $attemptLog
            if ($outcome -eq 'hang' -and $config.Retry -and $attempt -eq 1) {
                # hang-detect-agent Iron Law: 재시도는 최대 1회. 두 번 멈추면 작업 자체가 깨진 것이다.
                $attempt = 2
                Write-Log "⚠️ HANG [1/2] $Stage — 동일 명령으로 1회 재디스패치" WARN
                Write-KilledLeftover -Before $before -Stage $Stage -Context "1차 시도 강제 종료"
                Write-Log "⚠️ 재시도는 위 상태를 정리하지 않고 그대로 이어서 실행합니다." WARN
                continue
            }
            break
        }

        if ($outcome -eq 'ok') { break }

        if ($outcome -eq 'hang') { $reason = 'hang' }
        elseif ($outcome -eq 'timeout') { $reason = '하드 상한 초과' }
        elseif ($outcome -eq 'billing') { $reason = '잔액·쿼터 부족' }
        elseif ($outcome -eq 'unavailable') { $reason = '모델·프로바이더 사용 불가' }
        elseif ($outcome -eq 'noop') { $reason = '무산출 조기 실패' }
        else { $reason = '알 수 없는 실행 실패' }
        $attemptFailures += "${model}: $reason"
        $modelIndex++
        if ($modelIndex -lt $models.Count) {
            Write-Log "⚠️ [$Stage] $model 에서 $reason — 다음 모델로 전환: $($models[$modelIndex])" WARN
            Write-KilledLeftover -Before $before -Stage $Stage -Context "$reason — 모델 전환"
        }
    }

    $attemptSummary = if ($attemptFailures.Count -gt 0) { " (시도별 사유: $($attemptFailures -join '; '))" } else { '' }

    $failureOutcomes = @{
        hang = @{ Reason = 'hang'; KilledContext = '강제 종료'; ShowLogTail = $false }
        timeout = @{ Reason = '하드 상한 초과'; KilledContext = '하드 상한 초과로 강제 종료'; ShowLogTail = $false }
        billing = @{ Reason = '잔액·쿼터 부족'; KilledContext = $null; ShowLogTail = $true }
        unavailable = @{ Reason = '모델·프로바이더 사용 불가'; KilledContext = $null; ShowLogTail = $false }
        noop = @{ Reason = '무산출 조기 실패'; KilledContext = $null; ShowLogTail = $false }
    }
    if ($failureOutcomes.ContainsKey($outcome)) {
        $failure = $failureOutcomes[$outcome]
        $failureMessage = "$($failure.Reason) — 모델 체인 전부 소진, 중단"
        if ($outcome -eq 'billing') { $failureMessage += '. 프로바이더 결제 상태를 확인하세요.' }
        Write-Log "❌ [$Stage] $failureMessage$attemptSummary" ERROR
        $script:LastFailureReason = "$($failure.Reason) — 모델 체인 전부 소진$attemptSummary"
        if ($failure.KilledContext) {
            Write-KilledLeftover -Before $before -Stage $Stage -Context $failure.KilledContext
        }
        if ($failure.ShowLogTail) {
            $logAbs = Resolve-RepoPath $logRel
            if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
        }
        return $false
    }

    $exitLabel = if ($null -eq $exit) { '<unknown>' } else { $exit }
    Write-Log "프로세스 종료 (Exit Code: $exitLabel)" INFO
    if ($null -eq $exit) {
        Write-Log "⚠️ [$Stage] 종료 코드를 읽지 못함 — 검증 게이트 결과로 판정" WARN
    } elseif ($exit -ne 0) {
        Write-Log "⚠️ [$Stage] 실패 (Exit $exit) — 로그 끝부분:" WARN
        $script:LastFailureReason = "종료 코드 $exit"
        $logAbs = Resolve-RepoPath $logRel
        if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
        return $false
    }

    if (-not (Invoke-VerifyGate -Stage $Stage)) { return $false }

    # 작업트리 변경 유무 — 경고만 한다(차단하지 않음).
    # 게이트는 손대지 않은 트리에서도 통과하므로, "성공했지만 아무것도 안 한" 단계를 게이트만으로는 걸러낼 수 없다.
    # 실제 수행 여부 판단은 다음 리뷰 단계(④ QA · ⑤ 최종리뷰)의 몫이다.
    $after = Get-TreeState
    if ($null -ne $before -and $null -ne $after -and
        $before.Head -eq $after.Head -and $before.Dirty -eq $after.Dirty -and
        $before.Fingerprint -eq $after.Fingerprint) {
        Write-Log "⚠️ [$Stage] 작업트리 변경 없음 (HEAD·미커밋 파일 모두 동일) — 이 단계가 실제로 무엇을 했는지 다음 리뷰 단계에서 확인할 것" WARN
    }

    Write-Log "✅ [$Stage] 성공 + 검증 통과" SUCCESS
    return $true
}

# 락을 잡고 한 단계를 실행한다. 락 획득 실패 시 디스패치 자체를 하지 않는다 —
# Dispatch-Stage 안에서 잡으면 QA의 "이전 verdict 삭제"가 먼저 돌아, 차단된 실행이
# 정상 실행 중인 QA의 판정 파일을 지워버린다.
function Invoke-StageWithLock {
    param([string]$Stage, [string]$PromptOverride)
    if ($DryRun) { return (Dispatch-Stage -Stage $Stage -PromptOverride $PromptOverride) }
    # 락 획득 실패는 이 작업의 실패가 아니라 "지금은 때가 아님"이므로 마커를 남기지 않는다.
    if (-not (Enter-DispatchLock -Stage $Stage)) { return $false }
    $script:LastFailureReason = $null
    try {
        # 성공/실패 어느 쪽이든 마커 상태를 확정한다 — 실패는 다음 실행까지 눈에 남고, 성공은 즉시 지운다.
        $ok = Dispatch-Stage -Stage $Stage -PromptOverride $PromptOverride
        if ($ok) { Clear-FailureMarker -Stage $Stage }
        else { Write-FailureMarker -Stage $Stage -Reason $script:LastFailureReason }
        return $ok
    } catch {
        Write-FailureMarker -Stage $Stage -Reason "예외: $($_.Exception.Message)"
        throw
    } finally {
        Exit-DispatchLock -Stage $Stage
    }
}

# ④ QA verdict 게이트: 이번 실행에서 새로 쓴 verdict가 pass일 때만 ⑤ 진행.
function Test-QaVerdict {
    $rel = $StageConfig['qa'].VerdictFile
    $vf = Resolve-RepoPath $rel
    if (-not (Test-Path $vf)) {
        Write-Log "⚠️ QA verdict 파일 없음($rel) — 안전상 ⑤ 중단" ERROR
        return $false
    }
    # 디스패치 이후에 쓰인 파일만 인정 — 이전 실행이 남긴 pass의 재사용을 막는다.
    if ($null -ne $script:QaDispatchedAt) {
        $written = (Get-Item $vf).LastWriteTime
        if ($written -lt $script:QaDispatchedAt) {
            Write-Log "⚠️ QA verdict가 이번 실행 이전 것($written < $($script:QaDispatchedAt)) — 이번 QA는 판정을 남기지 않았다. 안전상 ⑤ 중단" ERROR
            return $false
        }
    }
    try {
        $verdict = (Get-Content $vf -Raw -Encoding UTF8 | ConvertFrom-Json).verdict
    } catch {
        Write-Log "⚠️ QA verdict JSON 파싱 실패 — 안전상 ⑤ 중단" ERROR
        return $false
    }
    if ($verdict -eq 'pass') { Write-Log "✅ QA verdict=pass → ⑤ 진행" SUCCESS; return $true }
    Write-Log "❌ QA verdict=$verdict → ⑤ 진행 중단 (QA 보고: $($StageConfig['qa'].ReportFile))" ERROR
    return $false
}

function Invoke-DispatcherCleanup {
    if ($script:CleanupStarted) { return }
    $script:CleanupStarted = $true
    try {
        if ($script:ActiveChildProcessId) {
            if ($script:ActiveChildStage -eq 'integration') {
                Write-Log "⚠️ dispatcher interruption left integration PID $script:ActiveChildProcessId running; do not kill a commit/push stage automatically." WARN
            } else {
                Stop-ProcessTree $script:ActiveChildProcessId
                Write-Log "dispatcher interruption stopped child process tree PID $script:ActiveChildProcessId" WARN
            }
        }
    } finally {
        if ($script:ActiveLockStage) { Exit-DispatchLock -Stage $script:ActiveLockStage }
    }
}

# ── 메인 ─────────────────────────────────────────────────────────────────────
Validate-TaskId -Id $TaskId
if ($Chain -and $Stage) { Write-Log '-Chain and -Stage are mutually exclusive.' ERROR; exit 1 }
if ($Chain -and $Prompt) { Write-Log '-Prompt is ignored in -Chain mode; using each stage default prompt.' WARN }
if (-not $Chain -and $Stage -ne 'impl' -and $Model) { Write-Log "-Model is ignored for [$Stage]." WARN }
if ($script:Model) { Assert-ModelIdentifier -Value $script:Model -Source '-Model' }
foreach ($configuredStage in $StageConfig.Keys) {
    if ($StageConfig[$configuredStage].ModelFallback) {
        foreach ($configuredModel in $StageConfig[$configuredStage].ModelFallback) {
            Assert-ModelIdentifier -Value $configuredModel -Source "StageConfig.$configuredStage.ModelFallback"
        }
    }
}
$packetMatches = @(Get-ChildItem -Path (Join-Path $RepoRoot '.agents\briefs\packets') -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue)
$archiveMatches = @(Get-ChildItem -Path (Join-Path $RepoRoot '.agents\briefs\archive') -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue)
if ($packetMatches.Count -eq 0 -and $archiveMatches.Count -eq 0) {
    Write-Log "작업 패킷을 찾지 못했습니다: $TaskId (저장소별 패킷 경로가 다를 수 있어 경고만 남기고 진행)" WARN
}

trap {
    Invoke-DispatcherCleanup
    break
}

try {
    # Console.CancelKeyPress is raised on a native console thread. A PowerShell
    # scriptblock delegate attached with add_CancelKeyPress has no runspace on
    # that thread and silently fails to invoke cleanup. Register-ObjectEvent
    # marshals the callback onto PowerShell's event queue/runspace.
    $null = Register-ObjectEvent -InputObject ([Console]) -EventName CancelKeyPress -Action {
        $event.SourceEventArgs.Cancel = $true
        Invoke-DispatcherCleanup
    }
    $null = Register-EngineEvent -SourceIdentifier PowerShell.Exiting -Action { Invoke-DispatcherCleanup }
} catch {
    Write-Log "⚠️ 종료 이벤트 등록 실패: $($_.Exception.Message)" WARN
}

# 저장소 루트 검증 — $RepoRoot는 "이 스크립트가 <프로젝트>/scripts/ 에 있다"는 전제로 계산된다.
# 중앙 저장소(ai-agents-config/global/harness/)에서 직접 실행하면 $RepoRoot가 조용히 `global`이 되어
# 패킷도 없는 디렉터리에서 모델이 한 판 다 돌고 쓸모없는 로그만 남는다
# (2026-08-04 실측: AC006 impl이 global/.agents/briefs/logs/ 에 기록, handoff-log.md 0 matches).
# verify 게이트는 어차피 단계 종료 후 호출되므로(Dispatch-Stage), 없으면 여기서 먼저 끊는 게 맞다.
$verifyGate = Join-Path $RepoRoot "scripts\verify.ps1"
if (-not (Test-Path $verifyGate)) {
    Write-Log "저장소 루트로 판정된 경로에 scripts\verify.ps1 이 없습니다: $RepoRoot" ERROR
    Write-Log "각 프로젝트의 scripts\ 에 배포된 사본으로 실행하세요 — 중앙 저장소 harness\ 에서 직접 실행하면 루트가 어긋납니다." ERROR
    exit 1
}

$script:BashExe = Resolve-BashExe
if (-not $DryRun -and -not $script:BashExe) {
    Write-Log "bash를 찾을 수 없습니다 — Git Bash 설치/PATH를 확인하세요." ERROR
    exit 1
}

if ($Chain) {
    Write-Log "📋 자동 연쇄 모드 시작 (TaskId: $TaskId): ②③ → ④ → ⑤" INFO
    foreach ($stage in @('impl','qa','integration')) {
        if (-not (Invoke-StageWithLock -Stage $stage -PromptOverride '')) {
            Write-Log "❌ [$stage] 실패로 파이프라인 중단 (로그: $($StageConfig[$stage].LogFile))" ERROR
            exit 1
        }
        # QA 자체는 성공했어도 verdict가 ⑤를 막으면 파이프라인은 거기서 멈춘다 —
        # 사용자 눈에는 이것도 "중단"이므로 마커를 남긴다.
        if ($stage -eq 'qa' -and -not $DryRun -and -not (Test-QaVerdict)) {
            Write-FailureMarker -Stage 'qa' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
            exit 1
        }
        Start-Sleep -Seconds 2
    }
    Write-Log "🎉 파이프라인 완료 — impl/qa/integration 로그는 $LogDir 참조" SUCCESS
    exit 0
} else {
    if (-not $Stage) { Write-Log "오류: -Stage 또는 -Chain 옵션이 필요합니다." ERROR; exit 1 }
    if ($Stage -eq 'integration' -and -not $DryRun) {
        if ($SkipVerdictGate) {
            Write-Log 'WARNING: -SkipVerdictGate bypasses the standalone integration QA verdict gate.' WARN
        } elseif (-not (Test-QaVerdict)) {
            Write-FailureMarker -Stage 'integration' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
            exit 1
        }
    }
    $ok = Invoke-StageWithLock -Stage $Stage -PromptOverride $Prompt
    # -Chain has its existing verdict gate above. A standalone QA dispatch must enforce
    # the same fresh pass verdict before its process can exit successfully.
    if ($ok -and $Stage -eq 'qa' -and -not $DryRun) {
        $ok = Test-QaVerdict
        if (-not $ok) { Write-FailureMarker -Stage 'qa' -Reason 'QA verdict 미통과 — ⑤ 진행 중단' }
    }
    exit ([int](-not $ok))
}
