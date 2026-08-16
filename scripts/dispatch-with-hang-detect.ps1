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
.PARAMETER BypassToolPermissions  사용자 승인 시에만 Antigravity CLI의 도구 권한 요청을 자동 승인한다.
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
    [Parameter(Mandatory=$false)][switch]$SkipVerdictGate,
    [Parameter(Mandatory=$false)][switch]$BypassToolPermissions
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = ".agents/briefs/logs"
$TaskLogPrefix = "$LogDir/$TaskId"
$ProfileModule = Join-Path $PSScriptRoot 'model-profile.ps1'
$ProfileConfigPath = Join-Path $PSScriptRoot 'model-profiles.json'

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

$script:WatcherLogAbs = $null
# CFG009: 종료 이벤트 핸들러는 인자를 받을 수 없어, 자식·락 상태를 스크립트 스코프에서 공유해야 한다.
$script:ActiveChildProcessId = $null
$script:ActiveChildStage = $null
$script:ActiveLockStage = $null
$script:CimFailureCount = 0
# CFG009: 종료 이벤트 핸들러는 인자를 받을 수 없어, 재진입 방지 상태를 스크립트 스코프에서 공유해야 한다.
$script:CleanupStarted = $false

# ── 단계별 설정 (모델·프롬프트는 CLAUDE.md verbatim) ─────────────────────────
# 개발1팀 기준 모델: openai/gpt-5.6-terra + reasoning medium(= opencode auth login으로 붙인 사용자
# OpenAI 구독 경로. 2026-08-06 gpt-5.5→terra 승급, 08-08 프로바이더 장애로 opencode/ 피신,
# 08-09 워크스페이스 크레딧 소진을 계기로 구독 경로 복귀 — 아래 ModelFallback 주석 참조).
# QA(④) 모델은 Build-ToolCommand의 -m gpt-5.6-terra — codex exec가 직접 OpenAI로 호출하므로
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
        ModelFallback = @('openai/gpt-5.6-terra', 'opencode-go/deepseek-v4-flash', 'opencode/big-pickle', 'opencode/deepseek-v4-flash-free')
        DefaultPrompt = "작업 $TaskId — [②구현] handoff 확인하고 패킷의 Done When과 Amendments를 충실히 따라 다음 단계 구현을 진행해. 구현 완료 후 [③자체리뷰] 제로베이스에서 개발 의도·계획 반영 여부와 로직·코드 품질을 점검하고 필요시 수정해. 이어서 scripts/verify.ps1 게이트를 통과시키고 Pipeline Status ②③을 갱신해"
        LogFile = "$TaskLogPrefix-impl.log"
        KillOnHang = $true
        Retry = $false
        HangSeconds = 600
    }
    'qa' = @{
        Command = ''
        DefaultPrompt = "작업 $TaskId — 개발팀의 1차 구현과 자체 리뷰가 완료되었어. Handoff 확인하고 제로베이스에서 구현 및 코드 품질에 대해 리뷰해. 발견한 결함은 직접 수정한 뒤 scripts/verify.ps1 게이트를 통과시키고 Pipeline Status ④를 갱신해. 마지막으로 QA 판정을 .agents/briefs/logs/$TaskId-qa-verdict.json 파일에 JSON으로 남겨 — ⑤ 진행 가능하면 verdict를 pass, 차단성 이슈로 ⑤ 진행 불가면 verdict를 blocked(사유는 reason)로 기록해"
        LogFile = "$TaskLogPrefix-qa.log"
        ReportFile = "$TaskLogPrefix-qa-last.md"
        VerdictFile = "$TaskLogPrefix-qa-verdict.json"
        KillOnHang = $true
        Retry = $true
        # QA retries after a false hang, so use the same conservative threshold as impl.
        HangSeconds = 600
    }
    'integration' = @{
        Command = ''
        DefaultPrompt = "작업 $TaskId — 현재 프로세스가 하네스가 시작한 유일한 Integration 본체다. 별도 Integration을 디스패치하거나 PID·락을 감시하거나 프로세스를 종료하지 마. 개발1팀의 구현과 QA팀의 리뷰가 완료되었어. 제로베이스에서 문제없는지 리뷰해. scripts/verify.ps1 게이트 통과 + 실동작 E2E 검증까지 마치고, 문제없으면 Integration을 로컬 완료 처리하고 Pipeline Status ⑤와 history.md를 갱신해. 패킷 Amendment에 이번 작업의 자동 commit/push 사용자 승인이 명시되어 있으면 관련 변경만 커밋·push하고, 없으면 별도 승인 전에는 수행하지 마."
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
# CFG017: 워처 로그는 사이클 간 증거 보존을 위해 truncate 하지 않고 append 한다 — 재디스패치가
# 이전 사이클의 관찰 이력을 덮어쓰지 않도록. 대시보드의 hang 판정은 LastWriteTime만 본다.
function Initialize-WatcherLog {
    param([string]$Stage)
    $script:WatcherLogAbs = Resolve-RepoPath "$LogDir/$TaskId-$Stage-watcher.log"
    $parent = Split-Path -Parent $script:WatcherLogAbs
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    if (Test-Path $script:WatcherLogAbs) {
        [System.IO.File]::AppendAllText($script:WatcherLogAbs, "`n===== $Stage 사이클 시작 $([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) =====`n", (New-Object System.Text.UTF8Encoding($false)))
    } else {
        [System.IO.File]::WriteAllText($script:WatcherLogAbs, '', (New-Object System.Text.UTF8Encoding($false)))
    }
}

# 저장소 상대 경로(bash·프롬프트가 쓰는 형태)를 PowerShell 쪽 절대 경로로 변환.
# 스크립트를 하위 디렉터리에서 실행해도 PS 쪽 파일 조작이 어긋나지 않게 한다.
function Resolve-RepoPath {
    param([string]$RelativePath)
    return (Join-Path $RepoRoot ($RelativePath -replace '/','\'))
}

function Write-StageState {
    param([string]$Stage, [int]$Cycle, [string]$State, [int]$ProcessId, [string[]]$EvidencePaths, [string]$Reason, [string]$Model)
    $path = Resolve-RepoPath "$LogDir/$TaskId-stage-state.json"
    $parent = Split-Path -Parent $path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $previous = $null
    try { if (Test-Path -LiteralPath $path) { $previous = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } } catch { }
    # 사이클은 단계마다 독립적으로 증가하므로 비교를 같은 단계로 한정한다. 같은 단계의 늦은
    # 과거 사이클 기록만 거부하고, 새 단계(impl→qa→integration)는 이전 단계 lease를 대체한다.
    # CFG020: impl cycle 5 완료 후 qa cycle 1이 이전 단계 cycle에 막혀 'starting'을 쓰지 못하면
    # 대시보드가 실제 진행 중인 qa를 이전 단계 상태로 계속 보여주는 오탐이 생긴다.
    $sameStage = $previous -and ([string]$previous.stage -eq $Stage)
    $previousCycle = 0
    if ($sameStage -and [int]::TryParse([string]$previous.cycle, [ref]$previousCycle) -and $previousCycle -gt $Cycle) { return }
    $sequence = if ($previous -and $previous.sequence) { [int]$previous.sequence + 1 } else { 1 }
    $now = [datetime]::UtcNow.ToString('o')
    $value = [ordered]@{ schemaVersion = 1; taskId = $TaskId; stage = $Stage; cycle = $Cycle; sequence = $sequence; state = $State; owner = 'dispatcher'; pid = $ProcessId; model = $Model; startedAt = $now; heartbeatAt = $now; eventAt = $now; evidencePaths = @($EvidencePaths); reason = $Reason }
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
}

function Get-SessionHealthRole {
    param([string]$Stage)
    switch ($Stage) {
        'impl' { return 'implementation' }
        'qa' { return 'qa' }
        'integration' { return 'integration' }
        default { return 'unknown' }
    }
}

function Invoke-SessionHealthCheck {
    param([string]$Stage)
    # Health warnings are advisory. A missing, damaged, or newly deployed helper must
    # never prevent the dispatcher from starting the requested stage.
    # AST fixture tests import this function without a script path. In production
    # PSScriptRoot is always the deployed scripts directory.
    $helperBase = if ($PSScriptRoot) { $PSScriptRoot } else { Join-Path $RepoRoot 'scripts' }
    $helper = Join-Path $helperBase 'session-health.ps1'
    if (-not (Test-Path -LiteralPath $helper)) {
        Write-Log "[$Stage] session-health helper missing; advisory check skipped" WARN
        return
    }
    try {
        $healthArgs = @('-WindowStyle', 'Hidden', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $helper, '-CheckAndRecord', '-ProjectRoot', $RepoRoot, '-TaskId', $TaskId, '-Stage', $Stage, '-Role', (Get-SessionHealthRole -Stage $Stage))
        if (-not [string]::IsNullOrWhiteSpace($env:ORCHESTRATION_DRIVER_CYCLE_ID)) {
            $healthArgs += @('-DriverCycleId', $env:ORCHESTRATION_DRIVER_CYCLE_ID)
        }
        $warnings = @(& powershell @healthArgs 2>&1)
        foreach ($warning in $warnings) {
            if (-not [string]::IsNullOrWhiteSpace([string]$warning)) { Write-Log "[$Stage] $warning" WARN }
        }
    } catch {
        Write-Log "[$Stage] session-health advisory check failed: $($_.Exception.Message)" WARN
    }
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
function Resolve-AntigravityProjectId {
    param([string]$RepositoryRoot)
    if (-not $env:USERPROFILE) { throw 'Antigravity project resolution requires USERPROFILE.' }
    $projectsDir = Join-Path $env:USERPROFILE '.gemini\config\projects'
    if (-not (Test-Path -LiteralPath $projectsDir)) { throw "Antigravity projects directory not found: $projectsDir" }
    $wanted = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd('\').Replace('\','/').ToLowerInvariant()
    foreach ($file in @(Get-ChildItem -LiteralPath $projectsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { $project = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        foreach ($resource in @($project.projectResources.resources)) {
            $uri = if ($resource.folderUri) { [string]$resource.folderUri } elseif ($resource.gitFolder.folderUri) { [string]$resource.gitFolder.folderUri } else { '' }
            if (-not $uri.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase)) { continue }
            $decoded = [Uri]::UnescapeDataString(($uri -replace '^file:/+', ''))
            $candidate = $decoded.TrimEnd('/').ToLowerInvariant()
            if ($candidate -eq $wanted) {
                $id = [string]$project.id
                if ($id -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,127}$') { throw "Invalid Antigravity project id in $($file.FullName)" }
                return $id
            }
        }
    }
    throw "No Antigravity project maps repository '$RepositoryRoot'. Run 'agy --new-project' from that repository root after explicit user approval."
}

# CFG017: Antigravity 어댑터 단계의 읽기 전용 preflight. PATH·버전·project mapping을 진단만 하고
# 외부 설정(설치·매핑 생성·환경 변수·config 변경)을 절대 수정하지 않는다. 실패는 재시도 불가능한
# config failure이며, 성공해도 Diagnostics(읽기 전용 확인 결과)만 반환한다.
function Test-AntigravityPreflight {
    param([string]$Stage)
    $result = @{ Ready = $true; Warnings = @(); Diagnostics = @(); Executable = $null }
    $config = $StageConfig[$Stage]
    if ($config.Adapter -ne 'antigravity') { return $result }

    # 1) 실행 파일: 명시 경로 → PATH → 알려진 설치 위치(CS-BL-019: LOCALAPPDATA\agy\bin\agy.exe).
    $exe = $null
    if ($script:ProfileConfig.antigravity -and $script:ProfileConfig.antigravity.executablePath) {
        $candidate = [string]$script:ProfileConfig.antigravity.executablePath
        if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
    }
    if (-not $exe) {
        $cmd = Get-Command 'agy' -ErrorAction SilentlyContinue
        if ($cmd -and $cmd.Source -and (Test-Path -LiteralPath $cmd.Source)) { $exe = $cmd.Source }
    }
    if (-not $exe -and $env:LOCALAPPDATA) {
        $candidate = Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe'
        if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
    }
    if (-not $exe) {
        $result.Ready = $false
        $result.Warnings += 'agy 실행 파일을 찾을 수 없습니다 — PATH·설치 경로를 확인하세요'
        return $result
    }

    $result.Executable = $exe

    # 2) 버전 — 읽기 전용 실행.
    $version = $null
    try { $version = (& $exe --version 2>&1 | Select-Object -First 1) } catch { $version = $null }
    if (-not $version -or "$version" -notmatch '\d+\.\d+') {
        $result.Ready = $false
        $result.Warnings += "agy 버전을 확인할 수 없습니다 ($exe)"
        return $result
    }

    # 3) project mapping — 읽기 전용(같은 디렉터리를 Resolve-AntigravityProjectId처럼 탐색하되 throw 하지 않는다).
    $projectsDir = Join-Path $env:USERPROFILE '.gemini\config\projects'
    $mapped = $false
    if (Test-Path -LiteralPath $projectsDir) {
        $wanted = [IO.Path]::GetFullPath($RepoRoot).TrimEnd('\').Replace('\','/').ToLowerInvariant()
        foreach ($file in @(Get-ChildItem -LiteralPath $projectsDir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
            try { $project = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
            foreach ($resource in @($project.projectResources.resources)) {
                $uri = if ($resource.folderUri) { [string]$resource.folderUri } elseif ($resource.gitFolder.folderUri) { [string]$resource.gitFolder.folderUri } else { '' }
                if ($uri.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase)) {
                    $decoded = [Uri]::UnescapeDataString(($uri -replace '^file:/+', '')).TrimEnd('/').ToLowerInvariant()
                    if ($decoded -eq $wanted) { $mapped = $true; break }
                }
            }
            if ($mapped) { break }
        }
    }
    if (-not $mapped) {
        $result.Ready = $false
        $result.Warnings += "저장소 '$RepoRoot'에 대한 Antigravity project mapping이 없습니다 — 승인 후 프로젝트 매핑을 만들어야 합니다(CS-BL-019)"
        return $result
    }

    $result.Diagnostics += "agy $version ($exe), project mapped"
    return $result
}

function Build-ToolCommand {
    param([hashtable]$Config, [string]$Stage, [string]$PromptOverride, [string]$Model, [switch]$BypassToolPermissions)
    $p = if ([string]::IsNullOrWhiteSpace($PromptOverride)) { $Config.DefaultPrompt } else { $PromptOverride }
    $q = ConvertTo-BashSingleQuoted $p
    $cmd = if ($Model) { $Config.Command -replace '\{MODEL\}', $Model } else { $Config.Command }
    $agyCommand = if ($Config.Executable) { ConvertTo-BashSingleQuoted ([string]$Config.Executable).Replace('\','/') } else { 'agy' }
    switch ($Stage) {
        'impl'        { return "$cmd $q" }
        'qa' {
            if ($Config.Adapter -eq 'gemini') { return "gemini --approval-mode yolo -m $Model $q" }
            if ($Config.Adapter -eq 'antigravity') { if (-not $Config.ProjectId) { throw 'Antigravity ProjectId is required.' }; $permissionFlag = if ($BypassToolPermissions) { ' --dangerously-skip-permissions' } else { '' }; $effortFlag = if ($Model -eq 'gemini-3.7-flash') { ' --effort medium' } else { '' }; return "$agyCommand --project $($Config.ProjectId) --model $Model$effortFlag --mode accept-edits$permissionFlag --output-format stream-json --print-timeout 25m --print $q" }
            if ($Config.Adapter -eq 'opencode') { return "opencode run --pure --auto -m $Model $q" }
            return "codex exec $q -m $Model -s danger-full-access -o $(ConvertTo-BashSingleQuoted $Config.ReportFile)"
        }
        'integration' {
            if ($Config.Adapter -eq 'codex') { return "codex exec $q -m $Model -s danger-full-access -o $(ConvertTo-BashSingleQuoted $Config.ReportFile)" }
            if ($Config.Adapter -eq 'gemini') { return "gemini --approval-mode yolo -m $Model $q" }
            if ($Config.Adapter -eq 'antigravity') { if (-not $Config.ProjectId) { throw 'Antigravity ProjectId is required.' }; $permissionFlag = if ($BypassToolPermissions) { ' --dangerously-skip-permissions' } else { '' }; return "$agyCommand --project $($Config.ProjectId) --model $Model --mode accept-edits$permissionFlag --output-format stream-json --print-timeout 25m --print $q" }
            if ($Config.Adapter -eq 'opencode') { return "opencode run --pure --auto -m $Model $q" }
            return "claude -p $q --model $Model --dangerously-skip-permissions --output-format stream-json --verbose"
        }
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

# CFG014: 반복 오류는 정상 장기 작업과 구분하기 어렵다. 관찰 자료가 쌓이기 전에는
# 하드 상한 연장 판단을 바꾸지 않고, 같은 오류가 한 관찰 구간에 3회 이상이면 경고만 남긴다.
function Get-RepeatedErrorObservation {
    param([string]$LogPath, [int]$MaxLines = 200, [int]$MinimumOccurrences = 3)

    $result = @{ Repeated = $false; Line = $null; Count = 0; SampledLines = 0 }
    if (-not (Test-Path -LiteralPath $LogPath)) { return $result }
    $lines = @(Get-Content -LiteralPath $LogPath -Tail $MaxLines -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and $_ -match '(?i)(error|exception|failed|fatal|오류|실패|예외)' })
    $result.SampledLines = $lines.Count
    if ($lines.Count -eq 0) { return $result }
    $mostFrequent = @($lines | Group-Object | Sort-Object Count -Descending | Select-Object -First 1)
    if ($mostFrequent.Count -eq 0) { return $result }
    $result.Line = $mostFrequent[0].Name
    $result.Count = $mostFrequent[0].Count
    $result.Repeated = $result.Count -ge $MinimumOccurrences
    return $result
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
        if ($LASTEXITCODE -ne 0) { throw 'git rev-parse failed' }
        # 로그 디렉터리는 제외한다 — 디스패치 자체가 로그를 쓰므로, 프로젝트가 이 경로를
        # gitignore 하지 않으면 "무엇도 바꾸지 않은 실행"이 항상 변경으로 보여 경고가 죽는다.
        $logPrefix = ($LogDir.Trim('/')) + '/'
        $dirty = (@(& git status --porcelain 2>$null |
            Where-Object { $_.Length -le 3 -or -not $_.Substring(3).Trim('"').StartsWith($logPrefix) }) -join "`n").Trim()
        if ($LASTEXITCODE -ne 0) { throw 'git status failed' }

        # status 문자열은 "이미 수정된 파일을 더 수정한 경우"에도 그대로다. noop 폴백이 실제 편집을
        # 무변경으로 오판하지 않도록 tracked diff와 untracked 파일 내용을 함께 지문화한다.
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $hashText = {
            param([string]$Text)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
            $sha.TransformBlock($bytes, 0, $bytes.Length, $bytes, 0) | Out-Null
        }
        # Stream git diff into SHA256 so a large binary diff cannot be duplicated in memory.
        # Git writes core.autocrlf conversion advice to stderr with exit code 0. Stderr is
        # intentionally excluded from this content stream; only a non-zero Git exit means
        # the fingerprint is invalid.
        & git diff --binary HEAD -- . 2>$null | ForEach-Object { & $hashText ($_ + "`n") }
        if ($LASTEXITCODE -ne 0) { throw 'git diff failed' }
        $untracked = @(& git ls-files --others --exclude-standard 2>$null |
            Where-Object { -not $_.Replace('\','/').StartsWith($logPrefix) } |
            Sort-Object)
        if ($LASTEXITCODE -ne 0) { throw 'git ls-files failed' }
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
        # 다만 조용히 넘기지 않는다(CFG-BL-014): 지문이 비면 뒤의 비교가 "$null -eq $null"로 성립해
        # 실제로는 판정에 실패한 실행을 "변경 없음"으로 단정한다. 실패는 실패로 남긴다.
        Write-Log "[$($MyInvocation.MyCommand.Name)] 작업트리 지문 계산 실패 — 변경 판정을 건너뜁니다: $($_.Exception.Message)" WARN
    } finally {
        Pop-Location
    }
    if ([string]::IsNullOrEmpty($head)) { return $null }
    # 지문이 비었으면 "동일"이 아니라 "판정 불가"다. 호출부가 구분할 수 있도록 명시한다.
    return @{ Head = $head; Dirty = $dirty; Fingerprint = $fingerprint
              FingerprintOk = (-not [string]::IsNullOrEmpty($fingerprint)) }
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
    # CFG017: 같은 TaskId의 다른 단계 마커나 다른 TaskId 마커는 절대 지우지 않는다 — 증거 보존.
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
    } elseif (-not $Before.FingerprintOk -or -not $after.FingerprintOk) {
        Write-Log "[$Stage] $Context — 작업트리 변경 여부 판정 불가(지문 계산 실패). 남은 변경을 직접 확인할 것" WARN
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
    param([string]$Stage, [hashtable]$Config, [string]$ToolCmd, [int]$Cycle, [ref]$ExitCode, [ref]$ElapsedSeconds, [string]$Model)

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
        # -WindowStyle Hidden과 -NoNewWindow는 Windows PowerShell 5.1에서 같은 Start-Process에
        # 함께 줄 수 없다. 별도 hidden child로 시작해야 콘솔도 노출하지 않고 parameter-set 예외도 피한다.
        $proc = Start-Process -FilePath $script:BashExe -WindowStyle Hidden -ArgumentList @($shPath) -PassThru
        $script:ActiveChildProcessId = $proc.Id; $script:ActiveChildStage = $Stage
        Write-StageState -Stage $Stage -Cycle $Cycle -State 'running' -ProcessId $proc.Id -EvidencePaths @($logRel) -Reason 'child process started' -Model $Model
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
            Write-StageState -Stage $Stage -Cycle $Cycle -State 'running' -ProcessId $proc.Id -EvidencePaths @($logRel) -Reason 'watcher heartbeat' -Model $Model
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
                    $repeatedError = Get-RepeatedErrorObservation -LogPath $logAbs
                    if ($repeatedError.Repeated) {
                        Write-Log "⚠️ 반복 오류 관찰 [$Stage] — 최근 $($repeatedError.SampledLines)개 오류 줄 중 같은 문구 $($repeatedError.Count)회: $($repeatedError.Line) (경고 전용; 하드 상한 연장·종료 정책은 유지)" WARN
                    }
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
    if ($config.ModelFallback) { $models = @($config.ModelFallback) } elseif ($config.Model) { $models = @($config.Model) } else { $models = @($null) }

    # -Model: 작업 성격에 맞는 1번 모델을 기획 단계에서 지정한다(예: 리팩토링 위주면 코딩 특화 모델).
    # 폴백 체인의 나머지는 '이 모델/프로바이더가 막혔을 때의 탈출 경로'라 성격과 무관하게 유지해야 하므로,
    # 지정 모델을 맨 앞에 놓고 나머지를 뒤에 붙인다(중복 제거 — 같은 모델을 두 번 부르지 않는다).
    # $script:Model은 최상위 param()의 $Model을 스크립트 스코프에서 읽는 것이다. 별도 대입은 없다.
    # $script: 로 명시하는 이유: 아래 루프가 로컬 $model에 대입하는데 PowerShell 변수명은
    # 대소문자를 구분하지 않아 그 뒤로는 스크립트 파라미터 $Model이 가려진다. 여기선 아직 가려지기
    # 전이지만, 루프 순서가 바뀌면 조용히 잘못된 값을 읽게 되므로 스코프를 못박아 둔다.
    if ($config.ModelFallback -and -not [string]::IsNullOrWhiteSpace($script:Model)) {
        $picked = $script:Model
        $rest = @($config.ModelFallback | Where-Object { $_ -ne $picked })
        $models = @($picked) + $rest
        Write-Log "[$Stage] 1번 모델 override: $picked (폴백: $($rest -join ' → '))" INFO
    }

    if ($Stage -eq 'impl' -and $script:ProviderHealthPath) {
        $health = Read-ProviderHealth -Path $script:ProviderHealthPath
        $go = $health.providers.'opencode-go'
        # A temporary provider outage is handled exactly like quota: skip only until its
        # bounded re-probe time, then restore the configured GO-first order automatically.
        # Authentication is deliberately excluded here: a sandbox credential denial is a
        # context problem, not evidence that the shared provider account was logged out.
        if ($go -and $go.reason -in @('quota', 'billing', 'unavailable') -and $go.nextProbeAt) {
            [datetime]$nextProbe = [datetime]::MinValue
            if (-not [datetime]::TryParse([string]$go.nextProbeAt, [ref]$nextProbe)) {
                Write-Log "provider health nextProbeAt is unreadable for opencode-go; ignoring the corrupt cooldown entry" WARN
            } elseif ($nextProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                $models = @($models | Where-Object { $_ -notmatch '^opencode-go/' })
                # The free emergency model is the first usable slot while GO is known unavailable.
                # Keep the remaining configured order so the normal reprobe contract is unchanged.
                $bigPickle = @($models | Where-Object { $_ -eq 'opencode/big-pickle' })
                $models = $bigPickle + @($models | Where-Object { $_ -ne 'opencode/big-pickle' })
                Write-Log "[$Stage] GO $($go.reason) cooldown until $($nextProbe.ToUniversalTime().ToString('o')); big-pickle fast-path로 시작" WARN
            }
        }
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

# CFG017: TaskId/단계별 사이클 상태 파일 — 재디스패치마다 단조 증가하는 durable cycle 번호를 보존한다.
# 승인 대기 뒤 fresh cycle이 새 번호를 받고, 과거 사이클의 attempt 로그는 이름에 cycle이 박혀 불변이다.
function Get-DispatchCycleStatePath {
    param([string]$Stage)
    return (Resolve-RepoPath "$LogDir/$TaskId-$Stage-cycles.json")
}

# 사이클 원자 할당(읽기-증가-쓰기, temp-file + Move-Item). 동일 단계는 Enter-DispatchLock 안에서만
# 호출되므로 같은 TaskId/Stage 사이클 번호가 동시에 두 프로세스에서 갈라지지 않는다.
# 상태 파일이 손상되면 로그 파일명에서 마지막 cycle을 재스캔해 복구한다(재사용 금지).
function New-DispatchCycle {
    param([string]$Stage)
    $path = Get-DispatchCycleStatePath $Stage
    $parent = Split-Path -Parent $path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

    $existing = @()
    $nextId = 1
    if (Test-Path -LiteralPath $path) {
        try {
            $state = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $state -and $null -ne $state.cycles) {
                $existing = @($state.cycles | Where-Object { $null -ne $_.id })
                $ids = @($existing | ForEach-Object { try { [int]$_.id } catch { 0 } })
                if ($ids.Count -gt 0) { $nextId = ([int]($ids | Measure-Object -Maximum).Maximum) + 1 }
            }
        } catch {
            # 손상 상태는 조용히 1로 되돌리지 않는다 — 재사용을 막기 위해 attempt 로그명에서 마지막 cycle을 찾는다.
            Write-Log "⚠️ 디스패치 사이클 상태 파일 손상($path) — 로그에서 마지막 cycle 재스캔으로 복구합니다" WARN
            $existing = @()
            $lastKnown = 0
            $logDirAbs = Resolve-RepoPath $LogDir
            if (Test-Path $logDirAbs) {
                foreach ($f in @(Get-ChildItem -LiteralPath $logDirAbs -File -Filter "$TaskId-$Stage.cycle*.attempt*" -ErrorAction SilentlyContinue)) {
                    $m = [regex]::Match($f.Name, '\.cycle(?<id>\d+)\.attempt')
                    if ($m.Success) {
                        $cid = 0
                        if ([int]::TryParse($m.Groups['id'].Value, [ref]$cid) -and $cid -gt $lastKnown) { $lastKnown = $cid }
                    }
                }
            }
            $nextId = $lastKnown + 1
        }
    }

    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        stage = $Stage
        cycles = @($existing) + @([ordered]@{ id = $nextId; token = ('cycle{0:D4}' -f $nextId); allocatedAt = [datetime]::UtcNow.ToString('o') })
    }
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
    return @{ Id = $nextId; Token = ('cycle{0:D4}' -f $nextId) }
}

# CFG017: attempt 로그명에 사이클을 박는다 — <base>.cycle0001.attempt01<ext>. 재디스패치가
# attempt 번호를 1로 되돌려도 이전 사이클 로그는 절대 덮어쓰지 않는다(불변 증거).
function Get-AttemptLogPath {
    param([string]$LogFile, [int]$CycleNumber, [int]$AttemptNumber)
    $extension = [System.IO.Path]::GetExtension($LogFile)
    $base = $LogFile.Substring(0, $LogFile.Length - $extension.Length)
    return ('{0}.cycle{1:D4}.attempt{2:D2}{3}' -f $base, $CycleNumber, $AttemptNumber, $extension)
}

function Update-LatestAttemptLog {
    param([string]$AttemptLog, [string]$LatestLog)
    $attemptAbs = Resolve-RepoPath $AttemptLog
    $latestAbs = Resolve-RepoPath $LatestLog
    if (-not (Test-Path $attemptAbs)) { return }
    [System.IO.File]::Copy($attemptAbs, $latestAbs, $true)
}

# CFG017: 승인 대기 기록 경로 — 실패 마커·차단 마커와 분리된 별도 레코드다. 대시보드는 이 파일을
# 읽어 APPROVAL REQUIRED를 띄우고, 감사는 이 JSON이 곧 정확 target·증거 링크의 정본이다.
function Get-ApprovalRecordPath {
    param([string]$Stage, [int]$CycleNumber)
    # 승인 요청 자체도 cycle의 불변 증거다. stage별 단일 파일이면 연속된 승인 요청이
    # 앞 기록을 덮어 감사 공백이 생기므로, 반드시 cycle을 경로에 포함한다.
    return (Resolve-RepoPath ('{0}/{1}-{2}-cycle{3:D4}-approval.json' -f $LogDir, $TaskId, $Stage, $CycleNumber))
}

# CFG018: 승인 판정은 모델이 인용한 문서가 아니라 Antigravity의 구조화 terminal event만 신뢰한다.
# command가 없으면 추측하지 않고 null+reason을 남겨, 사후 cli.log grep에 의존하지 않는다.
function Get-AntigravityTerminalEvidence {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    foreach ($line in @(Get-Content -LiteralPath $logAbs -Tail 80 -ErrorAction SilentlyContinue)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $eventName = [string](@($event.event, $event.type, $event.kind) | Where-Object { $_ } | Select-Object -First 1)
        $rawError = (@($event.error, $event.message, $event.detail, $event.result.error, $event.result.message) | Where-Object { $_ } | Select-Object -First 1)
        $approvalEventNames = @('error', 'result', 'terminal', 'permission', 'permission_denied', 'tool_confirmation')
        if ($approvalEventNames -notcontains $eventName.ToLowerInvariant() -or -not $rawError) { continue }
        $rawError = [string]$rawError
        if ($rawError -notmatch '(?i)(permission.+headless mode|requir[ea][sd]?\s+the\s+["``]?command["``]?\s+permission|auto-denied.+permission|user denied permission|permission check failed)') { continue }
        $target = (@($event.command, $event.input.command, $event.arguments.command, $event.tool_input.command) | Where-Object { $_ } | Select-Object -First 1)
        $conversationId = (@($event.conversation_id, $event.result.conversation_id) | Where-Object { $_ } | Select-Object -First 1)
        $stepId = (@($event.step_id, $event.step, $event.result.step_id) | Where-Object { $_ } | Select-Object -First 1)
        return [pscustomobject]@{
            Target = if ($target) { [string]$target } else { $null }
            TargetExtractionReason = if ($target) { $null } else { 'structured terminal approval event omitted command' }
            ConversationId = if ($conversationId) { [string]$conversationId } else { $null }
            StepId = if ($stepId) { [string]$stepId } else { $null }
            RawError = $rawError
        }
    }
    return $null
}

# Extract only the structured terminal target; ordinary attempt-log text is not evidence.
function Get-ApprovalTarget {
    param([string]$AttemptLog)
    $evidence = Get-AntigravityTerminalEvidence -AttemptLog $AttemptLog
    if ($evidence) { return $evidence.Target }
    return $null
}

# 원자적 JSON 승인 대기 기록. status='pending'으로 시작하며, 성공한 fresh cycle이 resolved로 바꾼다.
function Write-ApprovalRecord {
    param([string]$Stage, [int]$CycleNumber, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [object]$Evidence)
    $path = Get-ApprovalRecordPath -Stage $Stage -CycleNumber $CycleNumber
    $parent = Split-Path -Parent $path
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $adapter = if ($StageConfig[$Stage].Adapter) { $StageConfig[$Stage].Adapter } else { 'opencode' }
    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        stage = $Stage
        cycle = $CycleNumber
        attempt = $AttemptNumber
        adapter = $adapter
        model = $Model
        timestamp = [datetime]::UtcNow.ToString('o')
        approval_required = $true
        target = if ($Evidence) { $Evidence.Target } else { $null }
        targetExtractionReason = if ($Evidence) { $Evidence.TargetExtractionReason } else { 'no structured terminal approval evidence' }
        conversationId = if ($Evidence) { $Evidence.ConversationId } else { $null }
        stepId = if ($Evidence) { $Evidence.StepId } else { $null }
        rawError = if ($Evidence) { $Evidence.RawError } else { $null }
        evidencePaths = @($AttemptLog)
        decisionNeeded = 'Inspect the exact target, arrange approval outside the headless process, then start one explicit fresh stage dispatch (new cycle).'
        status = 'pending'
    }
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, ($value | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
    return $path
}

# fresh cycle의 성공(verify 통과, QA는 fresh verdict까지)만 승인 대기를 해소한다.
# 해소는 status만 'resolved'로 바꾸고 해소한 cycle을 남긴다 — 기록 자체는 삭제하지 않아 감사 이력이 보존된다.
function Resolve-ApprovalRecords {
    param([string]$Stage, [int]$ResolvingCycle)
    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path -LiteralPath $logDirAbs)) { return }
    # 같은 TaskId/stage의 모든 pending cycle을 해소한다. 파일은 수정만 하고 절대 삭제하지 않는다.
    foreach ($path in @(Get-ChildItem -LiteralPath $logDirAbs -Filter ("$TaskId-$Stage-cycle*-approval.json") -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })) {
      try {
        $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $record -or $record.taskId -ne $TaskId -or $record.stage -ne $Stage -or $record.status -ne 'pending') { continue }
        $record.status = 'resolved'
        $record | Add-Member -NotePropertyName resolvedCycle -NotePropertyValue $ResolvingCycle -Force
        $record | Add-Member -NotePropertyName resolvedAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
        $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($true)))
        Move-Item -LiteralPath $temporary -Destination $path -Force
        Write-Log "✅ [$TaskId/$Stage] 승인 대기(cycle $($record.cycle))를 fresh cycle $ResolvingCycle 성공으로 해소 — 감사 기록 보존" SUCCESS
      } catch {
        Write-Log "승인 기록 해소 중 실패(감사에 영향 없음): $($_.Exception.Message)" WARN
      }
    }
}

# CFG018: stream-json의 init/result event에 담긴 conversation_id만 재개 대상으로 쓴다.
# implicit most-recent continuation flag는 같은 project의 다른 stage 대화를 선택할 수 있으므로 절대 사용하지 않는다.
function Get-AntigravityConversationId {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    $ids = @()
    foreach ($line in @(Get-Content -LiteralPath $logAbs -ErrorAction SilentlyContinue)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $eventName = [string](@($event.event, $event.type, $event.kind) | Where-Object { $_ } | Select-Object -First 1)
        if (@('init', 'result') -notcontains $eventName.ToLowerInvariant()) { continue }
        $candidate = @($event.conversation_id, $event.result.conversation_id) | Where-Object { $_ } | Select-Object -First 1
        if ($candidate -and [string]$candidate -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
            $ids += ([string]$candidate).ToLowerInvariant()
        }
    }
    $ids = @($ids | Select-Object -Unique)
    if ($ids.Count -ne 1) { return $null }
    return $ids[0]
}

function Test-AntigravityPrintTimeout {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $false }
    $tail = (Get-Content -LiteralPath $logAbs -Tail 80 -ErrorAction SilentlyContinue) -join "`n"
    return $tail -match '(?i)(print mode:\s*timed out|timeout waiting for response|timed out after\s+\d+\s+polls)'
}

# Existing hard-timeout extension regards a stage as healthy when its recent log growth
# clears this same threshold. Antigravity stream-json emits activity into the attempt log,
# so reuse the rule after a provider-owned timeout rather than starting a fresh cycle.
function Test-AntigravityContinuationActivity {
    param([string]$AttemptLog, [Int64]$LogStartBytes = 0, [double]$RecentWindowMinutes = 10)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $false }
    $logItem = Get-Item -LiteralPath $logAbs
    $growth = [math]::Max(0, $logItem.Length - $LogStartBytes)
    # 실행 중인 프로세스의 유연 연장과 같은 창을 사용한다. 종료된 provider CLI에는
    # CPU/I/O를 다시 관찰할 수 없으므로, 마지막 stream-json 기록 시점이 이 창 안에
    # 있어야 한다. 초반 출력만 남기고 오래 멈춘 세션은 누적 바이트가 커도 재개하지 않는다.
    $recent = ([datetime]::UtcNow - $logItem.LastWriteTimeUtc).TotalMinutes -le $RecentWindowMinutes
    return $growth -ge $HardTimeoutProgressBytes -and $recent
}

function Get-ContinuationRecordPath {
    param([string]$Stage, [int]$CycleNumber)
    return (Resolve-RepoPath ('{0}/{1}-{2}-cycle{3:D4}-continuation.json' -f $LogDir, $TaskId, $Stage, $CycleNumber))
}

function Write-ContinuationRecord {
    param([string]$Stage, [int]$CycleNumber, [int]$AttemptNumber, [string]$AttemptLog, [string]$ConversationId, [bool]$Active, [bool]$Resumed, [string]$Reason)
    $path = Get-ContinuationRecordPath -Stage $Stage -CycleNumber $CycleNumber
    $record = $null
    if (Test-Path -LiteralPath $path) {
        try { $record = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $record = $null }
    }
    if ($null -eq $record) {
        $record = [ordered]@{ schemaVersion = 1; taskId = $TaskId; stage = $Stage; cycle = $CycleNumber; segments = @() }
    }
    $segment = [ordered]@{ attempt = $AttemptNumber; timestamp = [datetime]::UtcNow.ToString('o'); attemptLog = $AttemptLog; conversationId = $ConversationId; active = $Active; resumed = $Resumed; reason = $Reason }
    $record.segments = @($record.segments) + @($segment)
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $path -Force
    return $path
}

function Build-AntigravityContinuationCommand {
    param([hashtable]$Config, [string]$Model, [string]$ConversationId)
    if (-not $Config.ProjectId -or -not $ConversationId) { throw 'Antigravity continuation requires project and conversation IDs.' }
    $agyCommand = if ($Config.Executable) { ConvertTo-BashSingleQuoted ([string]$Config.Executable).Replace('\\','/') } else { 'agy' }
    $prompt = ConvertTo-BashSingleQuoted 'Continue the same assigned stage from the existing conversation. Do not restart discovery, do not create a fresh dispatch cycle, and preserve all existing safety restrictions.'
    return "$agyCommand --project $($Config.ProjectId) --model $Model --mode accept-edits --output-format stream-json --print-timeout 25m --conversation $ConversationId --print $prompt"
}

function Invoke-ModelAttempt {
    param([string]$Stage, [hashtable]$Config, [string]$ToolCmd, [string]$AttemptLog, [string]$LatestLog, [int]$Cycle, [string]$Model)

    $attemptConfig = @{}
    foreach ($key in $Config.Keys) { $attemptConfig[$key] = $Config[$key] }
    $attemptConfig.LogFile = $AttemptLog
    # 시도 시작 시점의 로그 크기를 기록한다. noop 판정이 절대 크기가 아니라 이 시도가 쓴 증가량을
    # 봐야 하므로, 시작 오프셋을 측정해 Classify-AttemptFailure에 넘겨야truncate/공유 로그로 바뀌어도
    # CFG-004의 무산출 안전망이 살아있다. 현재는 매 시도 새 파일이라 항상 0이지만, 계약을 이곳에서 확정한다.
    $attemptLogAbs = Resolve-RepoPath $AttemptLog
    $logStartBytes = if (Test-Path $attemptLogAbs) { (Get-Item $attemptLogAbs).Length } else { 0 }
    $exit = $null; $elapsedSeconds = 0
    $outcome = Invoke-StageProcess -Stage $Stage -Config $attemptConfig -ToolCmd $ToolCmd -Cycle $Cycle -ExitCode ([ref]$exit) -ElapsedSeconds ([ref]$elapsedSeconds) -Model $Model
    Update-LatestAttemptLog -AttemptLog $AttemptLog -LatestLog $LatestLog
    return @{ Outcome = $outcome; ExitCode = $exit; ElapsedSeconds = $elapsedSeconds; LogStartBytes = $logStartBytes; Adapter = $Config.Adapter }
}

function Classify-AttemptFailure {
    param([hashtable]$Attempt, [hashtable]$Before, [string]$AttemptLog)

    $outcome = $Attempt.Outcome
    if ($outcome -ne 'ok' -or $null -eq $Attempt.ExitCode) { return $outcome }
    $logAbs = Resolve-RepoPath $AttemptLog
    # CFG018: quoted handoff/test text is never terminal evidence. Only the adapter's parsed
    # stream-json event can put a stage into approval_required.
    $Attempt.ApprovalEvidence = if ($Attempt.Adapter -eq 'antigravity') { Get-AntigravityTerminalEvidence -AttemptLog $AttemptLog } else { $null }
    if ($Attempt.ApprovalEvidence) { return 'approval_required' }
    if ($Attempt.Adapter -eq 'antigravity' -and (Test-AntigravityPrintTimeout -AttemptLog $AttemptLog)) { return 'provider_timeout' }
    if ($Attempt.ExitCode -eq 0) { return $outcome }
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
        # See Invoke-StageProcess: keep the verify PowerShell invisible without mixing the
        # incompatible -WindowStyle Hidden and -NoNewWindow parameters on PS 5.1.
        $verify = Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $RepoRoot 'scripts\verify.ps1')) -PassThru -RedirectStandardOutput $verifyOut -RedirectStandardError $verifyErr
        $null = $verify.Handle
        if (-not $verify.WaitForExit($verifyMinutes * 60 * 1000)) {
            Stop-ProcessTree $verify.Id
            Write-Log "❌ [$Stage] verify 게이트가 ${verifyMinutes}분 안에 끝나지 않아 종료했습니다" ERROR
            return @{ Success = $false; FailureReason = 'verify 게이트 시간 초과' }
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
        Write-Log "마지막 30줄:" WARN
        $verifyOutput | Select-Object -Last 30 | ForEach-Object { Write-Host "    $_" }
        return @{ Success = $false; FailureReason = "verify 게이트 실패 ($verifyLogRel)" }
    }

    return @{ Success = $true; FailureReason = $null }
}

# 역할 판정은 Pipeline Status 섹션에만 한정한다. 다른 체크박스는 검증·인수인계 목록일 수 있다.
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

function Get-StagePipelineIndexes {
    param([string]$Stage)
    switch ($Stage) {
        'impl' { return @(2, 3) }
        'qa' { return @(4) }
        'integration' { return @(5) }
    }
}

function Get-EffectivePipelineStage {
    param([object]$PipelineStatus)
    if ($null -eq $PipelineStatus -or -not $PipelineStatus.HasPipelineStatus -or $null -eq $PipelineStatus.FirstUnchecked) { return $null }
    switch ([int]$PipelineStatus.FirstUnchecked.Index) {
        { $_ -in @(2, 3) } { return 'impl' }
        4 { return 'qa' }
        5 { return 'integration' }
        default { return $null }
    }
}

function Get-RuntimeRoleBinding {
    param([string]$PacketPath)
    $result = [ordered]@{ Present = $false; Valid = $false; Legacy = $true; PlanningProfile = $null; PlanningAdapter = $null; Error = $null }
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return [pscustomobject]$result }
    $text = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8
    $profileMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+Planning\s+Profile|actual\s+planning\s+profile)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $adapterMatch = [regex]::Match($text, '(?im)^-\s*(?:Actual\s+Planning\s+Adapter|actual\s+planning\s+adapter)\s*:\s*`?([^`\r\n]+)`?\s*$')
    $legacyMatch = [regex]::Match($text, '(?im)^-\s*legacy\s+packet\s*:\s*`?(true|false)`?\s*$')
    $result.Present = $profileMatch.Success -or $adapterMatch.Success -or $legacyMatch.Success
    if ($legacyMatch.Success) { $result.Legacy = $legacyMatch.Groups[1].Value -eq 'true' }
    if (-not ($profileMatch.Success -and $adapterMatch.Success)) {
        if ($result.Present -and -not $result.Legacy) { $result.Error = 'Runtime Role Binding must contain both actual planning profile and adapter.' }
        return [pscustomobject]$result
    }
    $result.PlanningProfile = $profileMatch.Groups[1].Value.Trim()
    $result.PlanningAdapter = $adapterMatch.Groups[1].Value.Trim()
    $result.Valid = $true
    return [pscustomobject]$result
}

function Set-CompletedStageApprovalsSuperseded {
    param([object]$PipelineStatus, [string]$Evidence)
    if ($null -eq $PipelineStatus -or -not $PipelineStatus.HasPipelineStatus) { return @() }
    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path -LiteralPath $logDirAbs)) { return @() }
    $updated = @()
    foreach ($recordFile in @(Get-ChildItem -LiteralPath $logDirAbs -Filter "$TaskId-*-cycle*-approval.json" -File -ErrorAction SilentlyContinue)) {
        try {
            $record = Get-Content -LiteralPath $recordFile.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($record.status -ne 'pending') { continue }
            $indexes = Get-StagePipelineIndexes -Stage ([string]$record.stage)
            if ($indexes.Count -eq 0) { continue }
            $stageItems = @($PipelineStatus.Items | Where-Object { $indexes -contains $_.Index })
            if ($stageItems.Count -eq 0 -or @($stageItems | Where-Object { -not $_.Checked }).Count -gt 0) { continue }
            # QA completion has an independent durable gate. A mistakenly checked packet alone
            # must never suppress a genuine approval request.
            if ($record.stage -eq 'qa' -and -not (Test-QaVerdict -QaDispatchedAt $null)) { continue }
            $record.status = 'superseded'
            $record | Add-Member -NotePropertyName supersededAt -NotePropertyValue ([datetime]::UtcNow.ToString('o')) -Force
            $record | Add-Member -NotePropertyName supersededReason -NotePropertyValue 'packet stage completed; durable pipeline state outranks the pending runtime artifact' -Force
            $record | Add-Member -NotePropertyName supersededByEvidence -NotePropertyValue $Evidence -Force
            $temporary = "$($recordFile.FullName).$([guid]::NewGuid().ToString('N')).tmp"
            [System.IO.File]::WriteAllText($temporary, ($record | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
            Move-Item -LiteralPath $temporary -Destination $recordFile.FullName -Force
            $updated += $recordFile.FullName
            Write-Log "✅ [$TaskId/$($record.stage)] 완료된 패킷 단계의 pending 승인 기록을 superseded 처리: $($recordFile.Name)" SUCCESS
        } catch {
            Write-Log "승인 기록 supersede 실패($($recordFile.FullName)): $($_.Exception.Message)" WARN
        }
    }
    return $updated
}

function Test-RequestedPipelineStage {
    param([string]$Stage, [string]$PacketPath)
    $status = Get-PacketPipelineStatus -PacketPath $PacketPath
    if (-not $status.HasPipelineStatus -or $status.Items.Count -eq 0) { return }
    $expected = Get-StagePipelineIndexes -Stage $Stage
    if ($null -eq $status.FirstUnchecked) {
        Write-Log "⚠️ [$Stage] 패킷 상태 경고 — 이미 완료된 단계를 재실행합니다" WARN
        return
    }
    if ($expected -contains $status.FirstUnchecked.Index) { return }
    $requested = @($status.Items | Where-Object { $expected -contains $_.Index } | Select-Object -First 1)
    if ($requested.Count -gt 0 -and $requested[0].Checked) {
        Write-Log "⚠️ [$Stage] 패킷 상태 경고 — 이미 완료된 단계를 재실행합니다: $($requested[0].Label)" WARN
    } else {
        Write-Log "⚠️ [$Stage] 패킷 상태 경고 — 선행 단계 $($status.FirstUnchecked.Index) 미완료: $($status.FirstUnchecked.Label)" WARN
    }
}

function Test-PipelineStageUpdated {
    param([string]$Stage, [string]$PacketPath)
    $status = Get-PacketPipelineStatus -PacketPath $PacketPath
    if (-not $status.HasPipelineStatus -or $status.Items.Count -eq 0) { return }
    $expected = Get-StagePipelineIndexes -Stage $Stage
    $unchecked = @($status.Items | Where-Object { $expected -contains $_.Index -and -not $_.Checked } | Select-Object -First 1)
    if ($unchecked.Count -gt 0) { Write-Log "⚠️ [$Stage] 성공했지만 패킷 Pipeline Status가 갱신되지 않았습니다: $($unchecked[0].Label)" WARN }
}

# 한 단계 디스패치 + hang 감지 + 판정. 성공(종료 코드 정상 + verify 통과) 시 $true.
# ModelFallback이 있는 단계(impl)는 모델을 바꿔가며 순서대로 시도한다 — 같은 모델을 두 번 부르지 않는다.
function Dispatch-Stage {
    param([string]$Stage, [string]$PromptOverride)
    $config = $StageConfig[$Stage]
    $logRel = $config.LogFile
    $models = Resolve-ModelChain -Config $config -Stage $Stage
    $qaDispatchedAt = $null

    if ($models.Count -eq 0) {
        $failureReason = '모델 체인이 비어 있음 — 단계 구성 오류'
        Write-Log "❌ [$Stage] $failureReason" ERROR
        return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $null }
    }

    if ($DryRun) {
        # 임시 파일을 남기지 않고 실제로 실행될 .sh 본문을 그대로 보여준다(체인 1번째 모델 기준).
        $toolCmd = Build-ToolCommand -Config $config -Stage $Stage -PromptOverride $PromptOverride -Model $models[0] -BypassToolPermissions:$BypassToolPermissions
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
        return @{ Success = $true; FailureReason = $null; QaDispatchedAt = $null }
    }

    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path $logDirAbs)) { New-Item -ItemType Directory -Path $logDirAbs -Force | Out-Null }
    Initialize-WatcherLog -Stage $Stage

    # CFG017: fresh direct 디스패치마다 durable 사이클을 할당한다. 같은 TaskId/단계의 재디스패치는
    # 단조 증가하는 새 사이클 번호를 받고, 과거 사이클의 attempt 로그는 이름에 cycle이 박혀 불변으로 남는다.
    $cycle = New-DispatchCycle -Stage $Stage
    Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'starting' -ProcessId $PID -EvidencePaths @($logRel) -Reason 'dispatcher accepted stage' -Model $null
    Write-Log "디스패치 사이클: $($cycle.Token) (id $($cycle.Id))" INFO

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
        $qaDispatchedAt = Get-Date
    }

    Invoke-SessionHealthCheck -Stage $Stage

    # CFG017: Antigravity 어댑터 단계는 실행 전 읽기 전용 preflight로 PATH·버전·project mapping을
    # 진단한다. 이 진단은 외부 설정(설치·매핑·환경 변수)을 절대 변경하지 않는다 — 문제는 재시도 불가능한
    # config failure로 즉시 돌린다(모델 체인 폴백·자동 재시도 없음).
    $preflight = Test-AntigravityPreflight -Stage $Stage
    if (-not $preflight.Ready) {
        $reason = "Antigravity preflight 실패: $($preflight.Warnings -join '; ')"
        Write-Log "❌ [$Stage] $reason" ERROR
        Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($logRel) -Reason $reason -Model $null
        return @{ Success = $false; FailureReason = $reason; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
    }
    if ($config.Adapter -eq 'antigravity' -and $preflight.Executable) { $config.Executable = $preflight.Executable }
    if ($preflight.Diagnostics.Count -gt 0) { Write-Log "[$Stage] preflight: $($preflight.Diagnostics -join ' | ')" INFO }

    $before = Get-TreeState
    # CFG018: provider print timeout can be resumed, but only inside one logical run.
    # The existing hard-timeout absolute maximum remains the total budget across segments.
    $logicalStartedAt = Get-Date
    $logicalHardLimit = if ($config.HardTimeoutMinutes) { $config.HardTimeoutMinutes } else { $HardTimeoutMinutes }
    $logicalAbsoluteDeadline = $logicalStartedAt.AddMinutes($logicalHardLimit * 3)
    $continuationCount = 0

    $exit = $null
    $outcome = $null
    $attemptFailures = @()
    $modelIndex = 0
    $attemptNumber = 0
    while ($modelIndex -lt $models.Count) {
        $model = $models[$modelIndex]
        $toolCmd = Build-ToolCommand -Config $config -Stage $Stage -PromptOverride $PromptOverride -Model $model -BypassToolPermissions:$BypassToolPermissions
        $modelTag = if ($model) { " (모델 $($modelIndex + 1)/$($models.Count): $model)" } else { "" }
        Write-Log "작업 $TaskId [$Stage] 디스패치$modelTag" INFO
        Write-Log "명령: $toolCmd" INFO
        Write-Log "로그: $logRel" INFO

        $attempt = 1
        while ($true) {
            $attemptNumber++
            $attemptLog = Get-AttemptLogPath -LogFile $logRel -CycleNumber $cycle.Id -AttemptNumber $attemptNumber
            Write-Log "시도 로그: $attemptLog (latest: $logRel)" INFO
            $attemptResult = Invoke-ModelAttempt -Stage $Stage -Config $config -ToolCmd $toolCmd -AttemptLog $attemptLog -LatestLog $logRel -Cycle $cycle.Id -Model $model
            $exit = $attemptResult.ExitCode
            $outcome = Classify-AttemptFailure -Attempt $attemptResult -Before $before -AttemptLog $attemptLog
            if ($Stage -eq 'impl' -and (Get-Command Update-ProviderHealth -ErrorAction SilentlyContinue)) { Update-ProviderHealth -Model $model -Outcome $outcome -AttemptLog $attemptLog }
            if ($outcome -eq 'approval_required') {
                # CFG017: headless 권한 요청은 재시도 불가능한 종결 상태다 — 모델 체인 전환·자동 재시도를
                # 절대 하지 않는다. 정확 target을 추출해 승인 대기 기록을 남기고 즉시 돌아간다.
                $evidence = $attemptResult.ApprovalEvidence
                $target = if ($evidence) { $evidence.Target } else { $null }
                $targetLabel = if ($target) { $target } elseif ($evidence) { "null ($($evidence.TargetExtractionReason))" } else { 'null (structured terminal evidence missing)' }
                $approvalPath = Write-ApprovalRecord -Stage $Stage -CycleNumber $cycle.Id -AttemptNumber $attemptNumber -Model $model -AttemptLog $attemptLog -Evidence $evidence
                Write-Log "❌ [$Stage] Antigravity headless 권한 요청 → 승인 대기 (approval_required)" ERROR
                Write-Log "대상 명령: $targetLabel" WARN
                Write-Log "승인 기록: $approvalPath" INFO
                Write-Log "동작: 대상 확인 후 headless 프로세스 밖에서 승인을 마치고, 명시적으로 새 사이클의 fresh 디스패치를 시작하세요." WARN
                Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'approval_required' -ProcessId $PID -EvidencePaths @($logRel) -Reason $targetLabel -Model $model
                return @{ Success = $false; Outcome = 'approval_required'; ApprovalPath = $approvalPath; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
            }
            if ($outcome -eq 'provider_timeout') {
                $conversationId = Get-AntigravityConversationId -AttemptLog $attemptLog
                $activityWindowMinutes = [Math]::Max(1, [Math]::Round($logicalHardLimit / 3.0, 2))
                $active = Test-AntigravityContinuationActivity -AttemptLog $attemptLog -LogStartBytes $attemptResult.LogStartBytes -RecentWindowMinutes $activityWindowMinutes
                $withinBudget = (Get-Date) -lt $logicalAbsoluteDeadline
                $canContinue = $config.Adapter -eq 'antigravity' -and $active -and $conversationId -and $continuationCount -lt 2 -and $withinBudget
                if (-not $conversationId) { $continuationReason = 'exact conversation ID missing or ambiguous' }
                elseif (-not $active) { $continuationReason = 'no healthy stream-json activity' }
                elseif (-not $withinBudget) { $continuationReason = 'logical absolute deadline reached' }
                elseif ($continuationCount -ge 2) { $continuationReason = 'automatic continuation limit reached' }
                else { $continuationReason = 'healthy provider timeout; resume same conversation' }
                $continuationPath = Write-ContinuationRecord -Stage $Stage -CycleNumber $cycle.Id -AttemptNumber $attemptNumber -AttemptLog $attemptLog -ConversationId $conversationId -Active $active -Resumed $canContinue -Reason $continuationReason
                if ($canContinue) {
                    $continuationCount++
                    $toolCmd = Build-AntigravityContinuationCommand -Config $config -Model $model -ConversationId $conversationId
                    Write-Log "⏳ [$Stage] provider print timeout 뒤 건강한 동일 대화 자동 재개 $continuationCount/2 (cycle $($cycle.Token), 기록: $continuationPath)" WARN
                    continue
                }
                Write-Log "⛔ [$Stage] provider print timeout 재개 불가: $continuationReason (cycle $($cycle.Token), 기록: $continuationPath)" ERROR
            }
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
        elseif ($outcome -eq 'provider_timeout') { $reason = 'provider print timeout (자동 재개 한도 또는 건강도 미충족)' }
        elseif ($outcome -eq 'quota') { $reason = '잔액·쿼터 부족' }
        elseif ($outcome -eq 'billing') { $reason = '잔액·쿼터 부족' }
        elseif ($outcome -eq 'authentication') { $reason = '인증 실패' }
        elseif ($outcome -eq 'unavailable') { $reason = '모델·프로바이더 사용 불가' }
        elseif ($outcome -eq 'noop') { $reason = '무산출 조기 실패' }
        else { $reason = '알 수 없는 실행 실패' }
        $attemptFailures += "${model}: $reason"
        # provider timeout은 새로운 모델/새 대화로 우회하지 않는다. 위의 동일 대화
        # continuation만 허용하고, 그 조건을 만족하지 못하면 현재 논리 실행을 끝낸다.
        # 원인이 분류되지 않은 Exit 1은 폴백 근거가 아니다. 다음 모델을 태우지 않고
        # 현재 cycle을 끝내야 반쯤 수정된 작업트리·토큰 낭비를 막을 수 있다.
        if ($outcome -in @('provider_timeout', 'unknown')) { $modelIndex = $models.Count; continue }
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
        provider_timeout = @{ Reason = 'provider print timeout'; KilledContext = $null; ShowLogTail = $true }
        quota = @{ Reason = '잔액·쿼터 부족'; KilledContext = $null; ShowLogTail = $true }
        billing = @{ Reason = '잔액·쿼터 부족'; KilledContext = $null; ShowLogTail = $true }
        authentication = @{ Reason = '인증 실패'; KilledContext = $null; ShowLogTail = $true }
        unavailable = @{ Reason = '모델·프로바이더 사용 불가'; KilledContext = $null; ShowLogTail = $false }
        noop = @{ Reason = '무산출 조기 실패'; KilledContext = $null; ShowLogTail = $false }
    }
    if ($failureOutcomes.ContainsKey($outcome)) {
        $failure = $failureOutcomes[$outcome]
        $failureMessage = "$($failure.Reason) — 모델 체인 전부 소진, 중단"
        if ($outcome -in @('quota', 'billing')) { $failureMessage += '. 프로바이더 결제 상태를 확인하세요.' }
        Write-Log "❌ [$Stage] $failureMessage$attemptSummary" ERROR
        $failureReason = "$($failure.Reason) — 모델 체인 전부 소진$attemptSummary"
        if ($failure.KilledContext) {
            Write-KilledLeftover -Before $before -Stage $Stage -Context $failure.KilledContext
        }
        if ($failure.ShowLogTail) {
            $logAbs = Resolve-RepoPath $logRel
            if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
        }
        Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($logRel) -Reason $failureReason -Model $model
        return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $qaDispatchedAt }
    }

    $exitLabel = if ($null -eq $exit) { '<unknown>' } else { $exit }
    Write-Log "프로세스 종료 (Exit Code: $exitLabel)" INFO
    if ($null -eq $exit) {
        Write-Log "⚠️ [$Stage] 종료 코드를 읽지 못함 — 검증 게이트 결과로 판정" WARN
    } elseif ($exit -ne 0) {
        Write-Log "⚠️ [$Stage] 실패 (Exit $exit) — 로그 끝부분:" WARN
        $failureReason = "종료 코드 $exit"
        $logAbs = Resolve-RepoPath $logRel
        if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
        Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($logRel) -Reason $failureReason -Model $model
        return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $qaDispatchedAt }
    }

    $verifyResult = Invoke-VerifyGate -Stage $Stage
    if (-not $verifyResult.Success) {
        Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($logRel) -Reason $verifyResult.FailureReason -Model $model
        return @{ Success = $false; FailureReason = $verifyResult.FailureReason; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
    }

    # CFG017: 이전에 승인 대기 상태였던 단계가 fresh cycle에서 성공하면 승인 기록을 resolved로 해소한다.
    # (qa는 이곳이 아니라 fresh verdict 통과를 확인한 뒤 해소한다 — Dispatch-Stage는 verdict를 모른다.)
    if ($Stage -ne 'qa') { Resolve-ApprovalRecords -Stage $Stage -ResolvingCycle $cycle.Id }

    # 작업트리 변경 유무 — 경고만 한다(차단하지 않음).
    # 게이트는 손대지 않은 트리에서도 통과하므로, "성공했지만 아무것도 안 한" 단계를 게이트만으로는 걸러낼 수 없다.
    # 실제 수행 여부 판단은 다음 리뷰 단계(④ QA · ⑤ 최종리뷰)의 몫이다.
    # 지문이 없으면 "동일"이 아니라 "판정 불가"다(CFG-BL-014). Dirty 문자열은 이미 수정 상태인 파일을
    # 더 수정해도 변하지 않으므로, 지문이 죽은 채 비교하면 실제 작업을 무변경으로 단정하게 된다.
    $after = Get-TreeState
    if ($null -ne $before -and $null -ne $after) {
        if (-not $before.FingerprintOk -or -not $after.FingerprintOk) {
            Write-Log "[$Stage] 작업트리 변경 여부 판정 불가 (지문 계산 실패) — 무변경 경고를 생략합니다" WARN
        } elseif ($before.Head -eq $after.Head -and $before.Dirty -eq $after.Dirty -and
                  $before.Fingerprint -eq $after.Fingerprint) {
            Write-Log "⚠️ [$Stage] 작업트리 변경 없음 (HEAD·미커밋 파일 모두 동일) — 이 단계가 실제로 무엇을 했는지 다음 리뷰 단계에서 확인할 것" WARN
        }
    }

    Write-Log "✅ [$Stage] 성공 + 검증 통과" SUCCESS
    Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'completed' -ProcessId $PID -EvidencePaths @($logRel) -Reason 'stage succeeded and verify passed' -Model $model
    return @{ Success = $true; FailureReason = $null; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
}

function Read-ProviderHealth {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ schemaVersion = 1; providers = [pscustomobject]@{} } }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.schemaVersion -ne 1 -or $null -eq $state.providers) { throw 'invalid schema' }
        return $state
    } catch {
        Write-Log "provider health state corrupt; ignoring it until the next classified result: $($_.Exception.Message)" WARN
        return [pscustomobject]@{ schemaVersion = 1; providers = [pscustomobject]@{} }
    }
}

function Write-ProviderHealth {
    param([string]$Path, [object]$Value)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($temporary, ($Value | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}

function Update-ProviderHealth {
    param([string]$Model, [string]$Outcome, [string]$AttemptLog)
    if (-not $script:ProviderHealthPath -or $Model -notmatch '^([^/]+)/') { return }
    $provider = $Matches[1]
    if ($provider -ne 'opencode-go') { return }
    $state = Read-ProviderHealth -Path $script:ProviderHealthPath
    if ($null -eq $state.providers) { $state | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force }
    if ($Outcome -eq 'ok') {
        $state.providers.psobject.Properties.Remove($provider)
        Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
        return
    }
    if ($Outcome -notin @('quota', 'billing', 'unavailable')) { return }
    $prior = $state.providers.$provider
    $count = if ($prior) { [int]$prior.consecutiveFailures + 1 } else { 1 }
    $hours = if ($count -gt 1) { [int]$script:ProfileConfig.providerCooldown.repeatedQuotaHours } elseif ($Outcome -eq 'unavailable') { 1 } else { [int]$script:ProfileConfig.providerCooldown.quotaDefaultHours }
    $nextProbe = [datetime]::UtcNow.AddHours($hours)
    if ($AttemptLog) {
        $logPath = Resolve-RepoPath $AttemptLog
        if (Test-Path -LiteralPath $logPath) {
            $retry = [regex]::Match((Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue), '(?im)retry-after\s*[:=]\s*(\d+)')
            if ($retry.Success) { $nextProbe = [datetime]::UtcNow.AddSeconds([int]$retry.Groups[1].Value) }
        }
    }
    $entry = [pscustomobject]@{ reason = $Outcome; consecutiveFailures = $count; observedAt = [datetime]::UtcNow.ToString('o'); nextProbeAt = $nextProbe.ToString('o') }
    $state.providers | Add-Member -NotePropertyName $provider -NotePropertyValue $entry -Force
    Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
}

function Write-ChainSummary {
    param(
        [ValidateSet('completed','blocked','failed','approval_required','judgment_required')][string]$State,
        [object[]]$Stages,
        [string[]]$Warnings,
        [datetime]$StartedAt,
        [object]$PipelineBefore,
        [object]$PipelineAfter,
        [object]$TreeBefore,
        [object]$TreeAfter,
        [object]$QaVerdict
    )
    $summaryPath = Resolve-RepoPath "$LogDir/$TaskId-chain-summary.json"
    $parent = Split-Path -Parent $summaryPath
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    $value = [ordered]@{
        schemaVersion = 1
        taskId = $TaskId
        driverCycleId = $env:ORCHESTRATION_DRIVER_CYCLE_ID
        state = $State
        startedAt = $StartedAt.ToUniversalTime().ToString('o')
        completedAt = [datetime]::UtcNow.ToString('o')
        elapsedSeconds = [math]::Round(((Get-Date) - $StartedAt).TotalSeconds, 1)
        stages = @($Stages)
        qaVerdict = $QaVerdict
        pipelineStatus = @{ before = $PipelineBefore; after = $PipelineAfter }
        tree = @{ before = $TreeBefore; after = $TreeAfter; changedFileCount = if ($TreeAfter -and $TreeAfter.Dirty) { @(($TreeAfter.Dirty -split "`r?`n") | Where-Object { $_ }).Count } else { 0 }; fingerprintComparable = [bool]($TreeBefore -and $TreeAfter -and $TreeBefore.FingerprintOk -and $TreeAfter.FingerprintOk) }
        warnings = @($Warnings)
        logDirectory = $LogDir
    }
    $tempPath = "$summaryPath.$([guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::WriteAllText($tempPath, ($value | ConvertTo-Json -Depth 8), (New-Object System.Text.UTF8Encoding($true)))
    Move-Item -LiteralPath $tempPath -Destination $summaryPath -Force
    return $summaryPath
}

# 락을 잡고 한 단계를 실행한다. 락 획득 실패 시 디스패치 자체를 하지 않는다 —
# Dispatch-Stage 안에서 잡으면 QA의 "이전 verdict 삭제"가 먼저 돌아, 차단된 실행이
# 정상 실행 중인 QA의 판정 파일을 지워버린다.
function Invoke-StageWithLock {
    param([string]$Stage, [string]$PromptOverride, [bool]$CheckPipelineBefore, [string]$CheckPipelinePacket)
    if ($DryRun) { return (Dispatch-Stage -Stage $Stage -PromptOverride $PromptOverride) }
    # 락 획득 실패는 이 작업의 실패가 아니라 "지금은 때가 아님"이므로 마커를 남기지 않는다.
    if (-not (Enter-DispatchLock -Stage $Stage)) { return $false }
    try {
        if ($CheckPipelineBefore) { Test-RequestedPipelineStage -Stage $Stage -PacketPath $CheckPipelinePacket }
        # 성공/실패 어느 쪽이든 마커 상태를 확정한다 — 실패는 다음 실행까지 눈에 남고, 성공은 즉시 지운다.
        $result = Dispatch-Stage -Stage $Stage -PromptOverride $PromptOverride
        if ($result.Success) { Test-PipelineStageUpdated -Stage $Stage -PacketPath $CheckPipelinePacket }
        if ($result.Success) { Clear-FailureMarker -Stage $Stage }
        elseif ($result.Outcome -eq 'approval_required') {
            # CFG017: 승인 대기는 failure 마커를 남기지 않는다 — 승인 기록 파일 자체가 상태·감사 증거다.
            # 자동 재시도 계기가 될 만한 "실패" 흔적을 남기지 않기 위함이다.
            Write-Log "[$Stage] 승인 대기 — failure 마커 대신 승인 기록이 상태를 나타냅니다 ($($result.ApprovalPath))" INFO
        }
        else { Write-FailureMarker -Stage $Stage -Reason $result.FailureReason }
        return $result
    } catch {
        Write-FailureMarker -Stage $Stage -Reason "예외: $($_.Exception.Message)"
        throw
    } finally {
        Exit-DispatchLock -Stage $Stage
    }
}

# ④ QA verdict 게이트: 이번 실행에서 새로 쓴 verdict가 pass일 때만 ⑤ 진행.
function Test-QaVerdict {
    param([object]$QaDispatchedAt)
    $rel = $StageConfig['qa'].VerdictFile
    $vf = Resolve-RepoPath $rel
    if (-not (Test-Path $vf)) {
        Write-Log "⚠️ QA verdict 파일 없음($rel) — 안전상 ⑤ 중단" ERROR
        return $false
    }
    # 디스패치 이후에 쓰인 파일만 인정 — 이전 실행이 남긴 pass의 재사용을 막는다.
    if ($null -ne $QaDispatchedAt) {
        $written = (Get-Item $vf).LastWriteTime
        if ($written -lt $QaDispatchedAt) {
            Write-Log "⚠️ QA verdict가 이번 실행 이전 것($written < $QaDispatchedAt) — 이번 QA는 판정을 남기지 않았다. 안전상 ⑤ 중단" ERROR
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
$checkPipelinePacket = if ($packetMatches.Count -eq 1) { $packetMatches[0].FullName } else { $null }

. $ProfileModule
$script:ProfileConfig = Read-ModelProfileConfig -CentralPath $ProfileConfigPath -LocalPath (Join-Path $RepoRoot 'model-profiles.local.json')
$configuredPlanning = Resolve-RoleProfile -Role planning -Config $script:ProfileConfig
$planningProfile = $configuredPlanning.Name
$planningAdapter = $configuredPlanning.Adapter
if ($checkPipelinePacket) {
    $runtimeBinding = Get-RuntimeRoleBinding -PacketPath $checkPipelinePacket
    if ($runtimeBinding.Valid) {
        $planningProfile = $runtimeBinding.PlanningProfile
        $planningAdapter = $runtimeBinding.PlanningAdapter
    } elseif ($runtimeBinding.Error) {
        throw $runtimeBinding.Error
    } else {
        Write-Log 'Runtime Role Binding missing; using configured planning profile for legacy packet.' WARN
    }
}
$script:PipelineRouting = Resolve-PipelineRouting -Config $script:ProfileConfig -PlanningProfile $planningProfile -PlanningAdapter $planningAdapter
$StageConfig.impl.ModelFallback = @($script:PipelineRouting.ImplementationModels)
$StageConfig.qa.Adapter = $script:PipelineRouting.QaProfile.Adapter
$StageConfig.qa.Model = $script:PipelineRouting.QaProfile.Model
if ($StageConfig.qa.Adapter -eq 'antigravity') { $StageConfig.qa.ProjectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot }
$StageConfig.integration.Adapter = $script:PipelineRouting.IntegrationProfile.Adapter
$StageConfig.integration.Model = $script:PipelineRouting.IntegrationProfile.Model
$StageConfig.integration.ReportFile = "$TaskLogPrefix-integration-last.md"
$stateRoot = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.agents\harness\state' } else { Join-Path ([IO.Path]::GetTempPath()) 'agents-harness-state' }
$script:ProviderHealthPath = Join-Path $stateRoot 'provider-health.json'
Write-Log "planner=$planningProfile/$planningAdapter impl-route=$($script:PipelineRouting.ImplementationRoute) qa=$($StageConfig.qa.Adapter)/$($StageConfig.qa.Model) project=$($StageConfig.qa.ProjectId) integration=$($StageConfig.integration.Adapter)/$($StageConfig.integration.Model)" INFO

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
    Write-Log "📋 자동 연쇄 모드 시작 (TaskId: $TaskId): 패킷 첫 미완료 단계부터 수렴" INFO
    $chainStartedAt = Get-Date
    $chainPipelineBefore = Get-PacketPipelineStatus -PacketPath $checkPipelinePacket
    Set-CompletedStageApprovalsSuperseded -PipelineStatus $chainPipelineBefore -Evidence $checkPipelinePacket | Out-Null
    $chainTreeBefore = Get-TreeState
    $chainQaVerdict = @{ verdict = $null; fresh = $false }
    $chainStages = @()
    $effectiveStage = Get-EffectivePipelineStage -PipelineStatus $chainPipelineBefore
    $allStages = @('impl','qa','integration')
    $effectiveIndex = [array]::IndexOf($allStages, $effectiveStage)
    if ($effectiveIndex -lt 0) {
        Write-ChainSummary -State 'completed' -Stages @() -Warnings @('packet has no incomplete executable stage') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter $chainPipelineBefore -TreeBefore $chainTreeBefore -TreeAfter $chainTreeBefore -QaVerdict $chainQaVerdict | Out-Null
        Write-Log '✅ 패킷에 미완료 실행 단계가 없습니다 — 재디스패치 없이 종료' SUCCESS
        exit 0
    }
    $stagesToRun = @($allStages[$effectiveIndex..($allStages.Count - 1)])
    Write-Log "유효 시작 단계: $effectiveStage (완료 단계 재디스패치 금지)" INFO
    foreach ($stage in $stagesToRun) {
        if ($stage -eq 'integration' -and -not $DryRun -and -not (Test-QaVerdict -QaDispatchedAt $null)) {
            Write-FailureMarker -Stage 'integration' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
            Write-ChainSummary -State 'blocked' -Stages $chainStages -Warnings @('QA verdict 미통과 — ⑤ 진행 중단') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
            exit 1
        }
        $result = Invoke-StageWithLock -Stage $stage -PromptOverride '' -CheckPipelineBefore ($stage -eq 'impl') -CheckPipelinePacket $checkPipelinePacket
        $chainStages += [ordered]@{ stage = $stage; success = [bool]$result.Success; failureReason = $result.FailureReason; verifyPassed = [bool]$result.Success; logPath = $StageConfig[$stage].LogFile }
        if (-not $result.Success) {
            # CFG017: 승인 대기는 'failed'가 아니라 'approval_required'로 연쇄를 중단한다 — 오케스트레이터가
            # 이 상태를 보고 재시도하지 않고 judgment_required로 멈춘다.
            $chainState = if ($result.Outcome -eq 'approval_required') { 'approval_required' } else { 'failed' }
            $chainWarnings = if ($result.Outcome -eq 'approval_required') { @("승인 대기 — 기록: $($result.ApprovalPath)") } else { @($result.FailureReason) }
            Write-ChainSummary -State $chainState -Stages $chainStages -Warnings $chainWarnings -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
            Write-Log "❌ [$stage] 파이프라인 중단 (상태: $chainState, 로그: $($StageConfig[$stage].LogFile))" ERROR
            exit 1
        }
        # QA 자체는 성공했어도 verdict가 ⑤를 막으면 파이프라인은 거기서 멈춘다 —
        # 사용자 눈에는 이것도 "중단"이므로 마커를 남긴다.
        if ($stage -eq 'qa' -and -not $DryRun -and -not (Test-QaVerdict -QaDispatchedAt $result.QaDispatchedAt)) {
            Write-FailureMarker -Stage 'qa' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
            Write-ChainSummary -State 'blocked' -Stages $chainStages -Warnings @('QA verdict 미통과 — ⑤ 진행 중단') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
            exit 1
        }
        if ($stage -eq 'qa') { $chainQaVerdict = @{ verdict = 'pass'; fresh = $true } }
        # CFG017: QA 승인 대기는 fresh verdict pass를 확인한 뒤에만 해소한다 — Dispatch-Stage 안에서
        # 해소하면 "실행 성공이지만 verdict 미통과" 케이스에 승인 기록이 조기 해소된다.
        if ($stage -eq 'qa' -and -not $DryRun -and $result.CycleId) { Resolve-ApprovalRecords -Stage 'qa' -ResolvingCycle $result.CycleId }
        Start-Sleep -Seconds 2
    }
    Write-ChainSummary -State 'completed' -Stages $chainStages -Warnings @() -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
    Write-Log "🎉 파이프라인 완료 — impl/qa/integration 로그는 $LogDir 참조" SUCCESS
    exit 0
} else {
    if (-not $Stage) { Write-Log "오류: -Stage 또는 -Chain 옵션이 필요합니다." ERROR; exit 1 }
    $standalonePipeline = Get-PacketPipelineStatus -PacketPath $checkPipelinePacket
    Set-CompletedStageApprovalsSuperseded -PipelineStatus $standalonePipeline -Evidence $checkPipelinePacket | Out-Null
    $effectiveStage = Get-EffectivePipelineStage -PipelineStatus $standalonePipeline
    if ($effectiveStage -and $effectiveStage -ne $Stage) {
        $requestedIndexes = Get-StagePipelineIndexes -Stage $Stage
        $requestedItems = @($standalonePipeline.Items | Where-Object { $requestedIndexes -contains $_.Index })
        if ($requestedItems.Count -gt 0 -and @($requestedItems | Where-Object { -not $_.Checked }).Count -eq 0) {
            Write-Log "✅ [$Stage] 이미 완료됨 — 재디스패치하지 않고 첫 미완료 단계 [$effectiveStage]로 수렴" SUCCESS
            $Stage = $effectiveStage
        }
    }
    if ($Stage -eq 'integration' -and -not $DryRun) {
        if ($SkipVerdictGate) {
            Write-Log 'WARNING: -SkipVerdictGate bypasses the standalone integration QA verdict gate.' WARN
        } elseif (-not (Test-QaVerdict -QaDispatchedAt $null)) {
            Write-FailureMarker -Stage 'integration' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
            exit 1
        }
    }
    $result = Invoke-StageWithLock -Stage $Stage -PromptOverride $Prompt -CheckPipelineBefore $true -CheckPipelinePacket $checkPipelinePacket
    $ok = $result.Success
    # -Chain has its existing verdict gate above. A standalone QA dispatch must enforce
    # the same fresh pass verdict before its process can exit successfully.
    if ($ok -and $Stage -eq 'qa' -and -not $DryRun) {
        $ok = Test-QaVerdict -QaDispatchedAt $result.QaDispatchedAt
        if (-not $ok) { Write-FailureMarker -Stage 'qa' -Reason 'QA verdict 미통과 — ⑤ 진행 중단' }
        # CFG017: fresh verdict pass 확인 후에만 QA 승인 대기를 해소한다.
        if ($ok -and $result.CycleId) { Resolve-ApprovalRecords -Stage 'qa' -ResolvingCycle $result.CycleId }
    }
    exit ([int](-not $ok))
}
