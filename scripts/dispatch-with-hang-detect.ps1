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
.PARAMETER BypassToolPermissions  claude 등 다른 어댑터의 도구 권한 요청을 자동 승인한다. Antigravity(agy)는
    권한 프롬프트로 단계가 멈추는 일이 잦아 사용자 지시(2026-08-31)에 따라 이 스위치와 무관하게 항상 승인된다.
.PARAMETER ForceFreeModel     impl 폴백 체인에서 유료(opencode-go) 슬롯을 건너뛰고 무료 슬롯으로 바로 시작한다.
                              사용자가 유료 쿼터 소진을 이미 확인했을 때만 지정 — 자동 판단 없음.
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
    [Parameter(Mandatory=$false)][switch]$BypassToolPermissions,
    # CFG027: 원장(ledger) 시도 카운트를 구조적 수정 완료 후 감사 가능한 방식으로 초기화한다.
    # 기존에는 CFG025-qa-ledger.json 등을 Write 툴로 직접 덮어써야 했다 — 반복되는 수동 개입.
    [Parameter(Mandatory=$false)][switch]$ResetStageLedger,
    [Parameter(Mandatory=$false)][string]$ResetReason,
    # CFG038 핫픽스(2026-08-27): opencode-go 쿼터 소진이 명확할 때 유료 슬롯을 전부 태우며
    # hang 대기를 반복하지 않도록, 사용자가 이번 실행만 무료 슬롯으로 직행시킬 수 있게 한다.
    [Parameter(Mandatory=$false)][switch]$ForceFreeModel,
    # CFG043: 사용자 권한 수동 완료/중단 — 실행(디스패치) 대신 단계 lease를 원자적으로 종결한다.
    # 실행 프로세스·락·승인 대기를 건드리지 않고, task/stage/cycle/evidence/reason을 보존한
    # terminal lease('completed' 또는 'failed')를 기록해 대시보드가 '정지 감지'로 오인하지 않게 한다.
    # 종결된 이전 단계 뒤 첫 미완료 단계부터 안전하게 자동 재개(-Chain)할 수 있게 한다.
    [Parameter(Mandatory=$false)][switch]$ManualComplete,
    [Parameter(Mandatory=$false)][switch]$ManualAbort,
    [Parameter(Mandatory=$false)][string]$Reason
)

$ErrorActionPreference = "Stop"
$WarningPreference = "SilentlyContinue"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = ".agents/briefs/logs"
$TaskLogPrefix = "$LogDir/$TaskId"
$ProfileModule = Join-Path $PSScriptRoot 'model-profile.ps1'
$ProfileConfigPath = Join-Path $PSScriptRoot 'model-profiles.json'
$ContractsModule = Join-Path $PSScriptRoot 'harness-contracts.ps1'
if (-not (Test-Path -LiteralPath $ContractsModule)) {
    throw "Required harness contracts module not found: $ContractsModule"
}
. $ContractsModule
$HarnessIoModule = Join-Path $PSScriptRoot 'harness-io.ps1'
if (-not (Test-Path -LiteralPath $HarnessIoModule)) {
    throw "Required harness I/O module not found: $HarnessIoModule"
}
. $HarnessIoModule

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
# model-profiles.json의 modelCatalog + routes가 체인의 정본이다.
# 아래 ModelFallback은 JSON 로드 실패 시의 비상 기본값으로만 쓰인다.
# 새 5슬롯 체인: opencode-go/mimo-v2.5-pro → deepseek-v4-flash → mimo-v2.5 → deepseek-v4-flash-free → big-pickle
$StageConfig = @{
    'impl' = @{
        Command = 'opencode run --pure --auto -m {MODEL} --variant medium'
        ModelFallback = @('opencode-go/mimo-v2.5-pro', 'opencode-go/deepseek-v4-flash', 'opencode-go/mimo-v2.5', 'opencode/deepseek-v4-flash-free', 'opencode/big-pickle')
        DefaultPrompt = "작업 $TaskId — [②구현] handoff 확인하고 패킷의 Done When과 Amendments를 충실히 따라 다음 단계 구현을 진행해. 구현 완료 후 [③자체리뷰] 제로베이스에서 개발 의도·계획 반영 여부와 로직·코드 품질을 점검하고 필요시 수정해. 이어서 scripts/verify.ps1 게이트를 통과시키고 Pipeline Status ②③을 갱신해"
        LogFile = "$TaskLogPrefix-impl.log"
        # codex 어댑터가 구현 슬롯에 배정될 때 `codex exec -o`가 쓸 보고서 경로다(다른 어댑터는 무시).
        ReportFile = "$TaskLogPrefix-impl-last.md"
        KillOnHang = $true
        Retry = $false
        # 단계별 hang 임계(HangSeconds)는 stage-thresholds.json이 정본이다 — 아래에서 로드해 덮어쓴다.
    }
    'qa' = @{
        Command = ''
        DefaultPrompt = "작업 $TaskId — 개발팀의 1차 구현과 자체 리뷰가 완료되었어. Handoff 확인하고 제로베이스에서 구현 및 코드 품질에 대해 리뷰해. 리뷰 시작 전 패킷의 Done When 항목을 전부 나열하고, 각 항목마다 실제 diff·코드 근거와 diff 밖이라도 이 변경이 영향을 주는 호출부·계약·회귀 테스트를 함께 확인해 개별 충족 여부를 검증해 — 근거 없이 통째로 '완료'로 넘기지 마. 발견한 결함은 직접 수정한 뒤 scripts/verify.ps1 게이트를 통과시키고 Pipeline Status ④를 갱신해. 마지막으로 QA 판정을 .agents/briefs/logs/$TaskId-qa-verdict.json 파일에 JSON으로 남겨 — schemaVersion은 2로, findings 배열에는 당신이 발견한 결함을 각각 {id, severity, doneWhenItem, description, fixedInQa, evidence} 형태로 개별 기록해(fixedInQa:true는 당신이 직접 수정했음을 뜻하며, 수정했더라도 findings에서 빠지면 안 된다). doneWhen 배열에 각 항목을 {item, satisfied, evidence} 형태로 개별 기록하고, 하나라도 satisfied가 false면 verdict는 반드시 blocked여야 해. 빈 findings 배열은 '결함을 하나도 발견하지 못했다'는 적극적 진술이며, 결함을 고쳐 놓고 findings를 비워 두는 것은 기록 위반으로 간주된다. ⑤ 진행 가능하면 verdict를 pass, 차단성 이슈로 ⑤ 진행 불가면 verdict를 blocked(사유는 reason)로 기록해"
        LogFile = "$TaskLogPrefix-qa.log"
        ReportFile = "$TaskLogPrefix-qa-last.md"
        VerdictFile = "$TaskLogPrefix-qa-verdict.json"
        KillOnHang = $true
        Retry = $true
        # QA는 오탐 hang 후 재시도한다 — 임계는 stage-thresholds.json이 정본이다(impl와 동일하게 보수적).
    }
    'integration' = @{
        Command = ''
        DefaultPrompt = "작업 $TaskId — 현재 프로세스가 하네스가 시작한 유일한 Integration 본체다. 별도 Integration을 디스패치하거나 PID·락을 감시하거나 프로세스를 종료하지 마. 개발1팀의 구현과 QA팀의 리뷰가 완료되었어. 제로베이스에서 문제없는지 리뷰해. scripts/verify.ps1 게이트 통과 + 실동작 E2E 검증까지 마치고, 문제없으면 Integration을 로컬 완료 처리하고 Pipeline Status ⑤와 history.md를 갱신한 뒤, 관련 변경을 커밋하고 원격에 push까지 자동으로 수행해(추가 승인 대기 없음; 정본 하네스를 수정했으면 sync-configs.ps1 -Action Push -CommitTargets -PushTargets 까지 수행해야 배포와 하류 사본 커밋이 완료된다). 패킷 Amendment에 자동 commit/push를 명시적으로 금지하는 지시가 있으면 그 지시를 따르고 사유를 남겨. 만약 QA가 pass를 줬지만 이 Integration 단계에서 새 결함(탈출 결함)을 발견하면, .agents/briefs/logs/$TaskId-integration-findings.json 파일에 schemaVersion 2로 {taskId, stage:'integration', findings:[{id, severity, doneWhenItem, description, fixedInQa, evidence}]} 형태로 기록해. 빈 findings 배열은 '탈출 결함을 발견하지 못했다'는 적극적 진술이며, 결함을 고쳐 놓고 findings를 비워 두는 것은 기록 위반으로 간주된다."
        LogFile = "$TaskLogPrefix-integration.log"
        FindingsFile = "$TaskLogPrefix-integration-findings.json"
        KillOnHang = $false
        Retry = $false
        # Integration은 git 진행 중 kill을 허용하는 3분법 경로를 쓰므로 임계가 길다 — stage-thresholds.json 정본.
    }
}

# ── 단계별 임계 정본 로드 (stage-thresholds.json) ────────────────────────────
# CFG039: HangSeconds 같은 단계별 임계값은 dispatcher와 dashboard가 공유하는 파일에서 읽는다.
# 어느 쪽도 숫자를 하드코딩하지 않는다. 로드 실패는 비상 기본값(위 $StageConfig에는 없음)보다
# 안전 정지를 우선하지 않고 경고만 남긴다 — 단, 파일이 존재할 때만 덮어쓴다.
$StageThresholdsPath = Join-Path $PSScriptRoot 'stage-thresholds.json'
try {
    if (Test-Path -LiteralPath $StageThresholdsPath) {
        $stageThresholds = Get-Content -LiteralPath $StageThresholdsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($st in @('impl', 'qa', 'integration')) {
            $t = $null
            try { $t = $stageThresholds.stages.$st } catch { $t = $null }
            if ($t -and $t.hangSeconds) { $StageConfig[$st].HangSeconds = [int]$t.hangSeconds }
        }
    }
} catch {
    Write-Log "stage-thresholds.json 로드 실패 — 단계별 임계를 파일 없이 진행합니다: $($_.Exception.Message)" WARN
}

#region 로깅·경로·사전진단
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
    $sameCycle = $sameStage -and ($previous -and [string]$previous.cycle -eq [string]$Cycle)
    $wasRunning = $previous -and ([string]$previous.state -match '^(starting|running)$')
    $startedAt = if ($sameCycle -and $wasRunning -and $previous.startedAt) { [string]$previous.startedAt } else { $now }
    $value = [ordered]@{ schemaVersion = 1; taskId = $TaskId; stage = $Stage; cycle = $Cycle; sequence = $sequence; state = $State; owner = 'dispatcher'; pid = $ProcessId; model = $Model; startedAt = $startedAt; heartbeatAt = $now; eventAt = $now; evidencePaths = @($EvidencePaths); reason = $Reason }
    Write-AtomicJson -Path $path -Value $value -Depth 6
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

    # 3) project mapping — 읽기 전용(Resolve-AntigravityProjectId 호출로 진단; 중복 경고 공유).
    $projectId = $null
    try {
        $projectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot
    } catch {
        $result.Ready = $false
        $result.Warnings += "저장소 '$RepoRoot'에 대한 Antigravity project mapping이 없습니다 ($($_.Exception.Message)) — 승인 후 프로젝트 매핑을 만들어야 합니다(CS-BL-019)"
        return $result
    }

    $result.Diagnostics += "agy $version ($exe), project mapped ($projectId)"
    return $result
}

# 라우트 슬롯 식별자(`provider/model`)를 그 어댑터가 실제로 받는 모델 문자열로 바꾼다.
# opencode 슬롯은 식별자 자체가 모델명이라 매핑이 없고, antigravity 처럼 provider 접두어를
# 쓰지 않는 어댑터만 modelCatalog의 invokeModel로 치환된다.
function Resolve-InvocationModel {
    param([hashtable]$Config, [string]$Model)
    if ([string]::IsNullOrWhiteSpace($Model)) { return $Model }
    if ($Config.ModelMap -and $Config.ModelMap.ContainsKey($Model)) { return [string]$Config.ModelMap[$Model] }
    return $Model
}

function Render-BashInvocationCommand {
    param([string[]]$Argv, [string]$Executable, [string]$Prompt)
    $quotedPrompt = ConvertTo-BashSingleQuoted $Prompt
    $tailTokens = @()
    for ($i = 0; $i -lt $Argv.Count; $i++) {
        $tok = $Argv[$i]
        if ($tok -eq '<PROMPT>') {
            $tailTokens += $quotedPrompt
        } elseif ($i -gt 0 -and $Argv[$i - 1] -eq '-o') {
            $tailTokens += ConvertTo-BashSingleQuoted $tok
        } else {
            $tailTokens += $tok
        }
    }
    $joined = $tailTokens -join ' '
    return "$Executable $joined"
}

function Build-ToolCommand {
    param([hashtable]$Config, [string]$Stage, [string]$PromptOverride, [string]$Model, [switch]$BypassToolPermissions)
    $Model = Resolve-InvocationModel -Config $Config -Model $Model
    $p = if ([string]::IsNullOrWhiteSpace($PromptOverride)) { $Config.DefaultPrompt } else { $PromptOverride }
    $q = ConvertTo-BashSingleQuoted $p
    $cmd = if ($Model) { $Config.Command -replace '\{MODEL\}', $Model } else { $Config.Command }
    # CFG046 R11 / CFG054: 어댑터 커맨드는 model-profile.ps1 의 Get-AdapterInvocationArgv 공용 플래그 테이블을 따른다.
    # 스테이지별 기본 어댑터(qa: codex, integration: claude)와 impl Command 템플릿(--variant 제거)은 그대로 유지한다.
    $targetAdapter = $null
    switch ($Stage) {
        'impl' {
            if ($Config.Adapter -and $Config.Adapter -ne 'opencode') {
                $targetAdapter = $Config.Adapter
            } else {
                if ($Model -and $Model -match '(?i)(big-pickle|free|flash)' -and $cmd -match ' --variant \S+') {
                    $cmd = $cmd -replace ' --variant \S+', ''
                }
                return "$cmd $q"
            }
        }
        'qa' {
            $targetAdapter = if ($Config.Adapter) { $Config.Adapter } else { 'codex' }
        }
        'integration' {
            $targetAdapter = if ($Config.Adapter) { $Config.Adapter } else { 'claude' }
        }
    }

    if ($targetAdapter -eq 'antigravity') {
        return Build-AntigravityCommand -Model $Model -Prompt $p -ProjectId $Config.ProjectId -Executable $Config.Executable
    }
    # model-profile.ps1 is dot-sourced before any Dispatch-Stage invocation (below), so all
    # adapter flags and executable names always come from its shared argv contract.
    $argv = Get-AdapterInvocationArgv -Adapter $targetAdapter -Model $Model -ReportFile $Config.ReportFile -ProjectId $Config.ProjectId
    $exe = Get-AdapterExecutable -Adapter $targetAdapter
    return Render-BashInvocationCommand -Argv $argv -Executable $exe -Prompt $p
}
#endregion 로깅·경로·사전진단
#region hang 탐지·프로세스 트리·작업트리

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

    $cpu = [TimeSpan]::Zero; [Int64]$io = 0; [Int64]$workingSet = 0; [int]$handleCount = 0
    $pids = @()
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
        $pids += $processId

        $procObj = $null
        try {
            $procObj = Get-Process -Id $processId -ErrorAction Stop
            $cpu += $procObj.TotalProcessorTime
            $workingSet += [Int64]$procObj.WorkingSet64
            $handleCount += [int]$procObj.HandleCount
        } catch { }
        if ($byId.ContainsKey($processId)) {
            $current = $byId[$processId]
            $read = if ($null -eq $current.ReadTransferCount) { 0 } else { [Int64]$current.ReadTransferCount }
            $write = if ($null -eq $current.WriteTransferCount) { 0 } else { [Int64]$current.WriteTransferCount }
            $io += $read + $write
            if (-not $procObj) {
                if ($current.WorkingSetSize) { $workingSet += [Int64]$current.WorkingSetSize }
                if ($current.HandleCount) { $handleCount += [int]$current.HandleCount }
            }
        }
        if ($children.ContainsKey($processId)) {
            foreach ($child in $children[$processId]) {
                $pending.Enqueue([int]$child.ProcessId)
            }
        }
    }
    return @{
        Cpu = $cpu
        Io = $io
        WorkingSet = $workingSet
        HandleCount = $handleCount
        ProcessIds = @($pids)
        ChildProcessIds = @($pids | Where-Object { $_ -ne $RootProcessId })
        QueryMs = $queryStopwatch.ElapsedMilliseconds
        CimFailures = $script:CimFailureCount
    }
}

# hang 후보 시점에 git 작업(커밋/머지/체크아웃 등)이 진행 중인지 판정한다.
# (a) $RepoRoot\.git\index.lock 존재 여부, (b) 이미 수집한 자식 PID 중 프로세스명 'git' 존재 여부.
# 새 git 프로세스를 spawn하지 않는다 — hang 후보 자체가 "멈춰 있을 수 있는" 시점이므로
# 판정 로직이 추가 지연/행 리스크를 만들지 않아야 한다(CFG031).
function Test-GitOperationInFlight {
    param([string]$RepoRoot, [int[]]$ChildProcessIds)
    $indexLock = Join-Path $RepoRoot '.git\index.lock'
    if (Test-Path -LiteralPath $indexLock -PathType Leaf) { return $true }
    if ($ChildProcessIds -and $ChildProcessIds.Count -gt 0) {
        foreach ($childPid in $ChildProcessIds) {
            try {
                $childProc = Get-Process -Id $childPid -ErrorAction Stop
                if ($childProc.ProcessName -eq 'git') { return $true }
            } catch { }
        }
    }
    return $false
}

# 작업트리 스냅샷 — 단계가 실제로 무언가를 바꿨는지 판정하는 근거.
# 로그 디렉터리는 gitignore 대상이므로 이 스냅샷을 오염시키지 않는다.
function Get-TreeState {
    $head = $null; $dirty = $null; $fingerprint = $null
    Push-Location $RepoRoot
    # PS 5.1 + 전역 $ErrorActionPreference='Stop' 조합에서 native 명령의 stderr 한 줄이
    # NativeCommandError로 승격되어 스크립트가 죽는다(CFG-BL-019). Invoke-VerifyGate와 동일하게
    # 이 호출 구간만 Continue로 낮춘다.
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
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
        $ErrorActionPreference = $prevEap
        Pop-Location
    }
    if ([string]::IsNullOrEmpty($head)) { return $null }
    # 지문이 비었으면 "동일"이 아니라 "판정 불가"다. 호출부가 구분할 수 있도록 명시한다.
    return @{ Head = $head; Dirty = $dirty; Fingerprint = $fingerprint
              FingerprintOk = (-not [string]::IsNullOrEmpty($fingerprint)) }
}

#endregion hang 탐지·프로세스 트리·작업트리
#region 락·디스패치 게이트 마커
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
    $lock = Read-HarnessLockFile -Path $p
    if (-not $lock -or [string]::IsNullOrWhiteSpace($lock.Raw)) { return $null }
    return @{
        Path = $lock.Path
        Raw = $lock.Raw
        ProcId = $lock.ProcessId
        TaskId = $lock.TaskId
        StartedAt = [string]$lock.StartedAt
        ProcessStartedAt = $lock.ProcessStartedAt
        Alive = $lock.Alive
    }
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
#endregion 락·디스패치 게이트 마커
#region hang 감시·시간 예산·스테이지 실행

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

# =====================================================================
# [hang 탐지 · 프로세스 트리] Invoke-StageProcess 분해 도우미(CFG040) —
# 감시 한도·기준선·hang/하드 상한 판정을 순수 함수 경계로 분리한다.
# =====================================================================
# 스테이지 한도(hang/하드)와 감시 간격을 한 객체로 파생한다.
# 하드 상한 유연화(2026-08-09 CS-024): 로그가 꾸준히 늘어나는 프로세스를 고정 상한에서 죽이면
# 멀쩡히 일하던 구현이 통째로 날아간다(실측: 5분당 +3.9KB를 내던 모델이 30분에 강제 종료).
# 상한에 닿았을 때 진행 중이면 $extendStep 만큼 연장하고, 절대 상한에서는 무조건 끊는다.
# 노브를 늘리지 않으려고 연장 폭·절대 상한을 기본 상한에서 파생시킨다 —
# -HardTimeoutMinutes 하나만 줄이면 셋 다 비례해 줄어 짧은 시간에 E2E 검증이 가능하다.
function Resolve-StageLimits {
    param([hashtable]$Config)

    $hangLimit = if ($Config.HangSeconds) { $Config.HangSeconds } else { $HangWaitSeconds }
    $hardLimit = if ($Config.HardTimeoutMinutes) { $Config.HardTimeoutMinutes } else { $HardTimeoutMinutes }
    $hardMax = $hardLimit * 3
    $extendStep = [Math]::Max(1, [Math]::Round($hardLimit / 3.0, 2))
    # 로그 무변화(hang)/하드 상한 감시 간격: 요청한 임계값보다 늦게 감지하지 않도록 제한한다.
    # 로그 파일이 아직 만들어지지 않은 경우도 무출력 상태이므로 0바이트로 취급한다.
    $interval = [Math]::Min(10, [Math]::Max(1, $hangLimit))
    return @{ HangLimit = $hangLimit; HardLimit = $hardLimit; HardMax = $hardMax; ExtendStep = $extendStep; Interval = $interval }
}

# 감시 루프의 기준선(하드/절대 상한, 무변화 추적, 연장 창, 하트비트, 기준 CPU)을 한 객체로 만든다.
function New-StageMonitorBaseline {
    param($Proc, [datetime]$StartedAt, [hashtable]$Limits)

    $deadline = $StartedAt.AddMinutes($Limits.HardLimit)
    $absoluteDeadline = $StartedAt.AddMinutes($Limits.HardMax)
    $lastSize = 0; $lastLogChangedAt = $StartedAt; $hangReported = $false
    # 연장 판정용 롤링 창 — $extendStep 마다 그 구간의 로그 증가량을 확정한다.
    $windowStartAt = $StartedAt; $windowStartSize = 0; $lastWindowGrowth = 0
    $idleStartedMetrics = Get-ProcessTreeMetrics -RootProcessId $Proc.Id
    $lastHeartbeatAt = $StartedAt; $lastHeartbeatSize = 0; $lastHeartbeatCpu = $idleStartedMetrics.Cpu
    return @{
        Deadline = $deadline; AbsoluteDeadline = $absoluteDeadline
        LastSize = $lastSize; LastLogChangedAt = $lastLogChangedAt; HangReported = $hangReported
        WindowStartAt = $windowStartAt; WindowStartSize = $windowStartSize; LastWindowGrowth = $lastWindowGrowth
        IdleStartedMetrics = $idleStartedMetrics
        LastHeartbeatAt = $lastHeartbeatAt; LastHeartbeatSize = $lastHeartbeatSize; LastHeartbeatCpu = $lastHeartbeatCpu
    }
}

# 연장 판정용 롤링 창 확정 — 창 길이를 연장 폭과 맞춰 "최근 한 연장분 동안 진행이 있었나"를 본다.
function Advance-StageWindow {
    param([hashtable]$Monitor, [long]$LogSize, [double]$ExtendStep)

    if (((Get-Date) - $Monitor.WindowStartAt).TotalMinutes -ge $ExtendStep) {
        $Monitor.LastWindowGrowth = [math]::Max(0, $LogSize - $Monitor.WindowStartSize)
        $Monitor.WindowStartAt = Get-Date; $Monitor.WindowStartSize = $LogSize
    }
}

# 300초마다 진행 상황을 한 줄로 남긴다. 재시도는 같은 단계 로그를 `>`로 다시 열어 크기가 줄
# 수 있으므로 하트비트 증가량은 truncate 구간을 0으로 clamp하고, 종료된 자식이 다음 트리
# 샘플에서 빠질 때의 음수 CPU 증분도 0으로 표시한다.
function Write-StageHeartbeat {
    param([string]$Stage, [datetime]$StartedAt, [hashtable]$Monitor, [long]$LogSize, $CpuNow, $metricsNow)

    if (((Get-Date) - $Monitor.LastHeartbeatAt).TotalSeconds -lt 300) { return }
    $elapsed = [math]::Floor(((Get-Date) - $StartedAt).TotalMinutes)
    $logDelta = [math]::Max(0, $LogSize - $Monitor.LastHeartbeatSize)
    $cpuDelta = [math]::Max(0, [math]::Round(($CpuNow - $Monitor.LastHeartbeatCpu).TotalSeconds, 2))
    Write-Log "진행중 [$Stage] 경과 ${elapsed}분 · 로그 +${logDelta}B · 트리 CPU +${cpuDelta}s · CIM $($metricsNow.QueryMs)ms · CIM 실패 $($metricsNow.CimFailures)회" INFO
    $Monitor.LastHeartbeatAt = Get-Date; $Monitor.LastHeartbeatSize = $LogSize; $Monitor.LastHeartbeatCpu = $CpuNow
}

# hang 판정 — CPU '증가 여부'가 아니라 '증가율'로 판정한다(2026-08-09 CS-024).
# 정지한 프로세스도 폴링·타이머로 초당 수십 ms는 태우므로, 조금이라도 늘면 살려주던 기존 가드
# (CS-022)는 사실상 hang을 영원히 잡지 못했다 — 실측에서 로그 +0B가 15분 이어지는 동안 코어
# 1.5%만 태우던 프로세스가 하드 상한까지 20분을 그냥 버렸다. 판정 분기와 로그는 그대로 두고,
# 강제 종료(Stop-ProcessTree + $policyKilled)만 호출자가 수행한다.
# 반환 Action: wait=계속 대기 · kill-hang=KillOnHang 즉시 종료 · kill-git=git 부재 확인 즉시 종료.
function Test-StageHangProgress {
    param([string]$Stage, [hashtable]$Monitor, $metricsNow, [double]$noChange, [double]$noChangeText, [hashtable]$Config)

    $idleCpuDelta = [math]::Max(0, [math]::Round(($metricsNow.Cpu - $Monitor.IdleStartedMetrics.Cpu).TotalSeconds, 2))
    $idleIoDelta = [math]::Max(0, $metricsNow.Io - $Monitor.IdleStartedMetrics.Io)
    $ratePct = [math]::Round(($idleCpuDelta / $noChange) * 100, 1)
    $ioRate = [math]::Round($idleIoDelta / $noChange, 0)
    $thresholdPct = [math]::Round($BusyCpuRate * 100, 1)
    $decision = @{ Action = 'wait' }
    if (($idleCpuDelta / $noChange) -ge $BusyCpuRate) {
        # CS-022의 의도(조용히 계산 중인 에이전트를 죽이지 않는다)는 여기서 그대로 유지된다.
        Write-Log "[$Stage] 로그 무변화 ${noChangeText}초지만 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}%) — 계산 중으로 보고 계속 대기" INFO
        $Monitor.LastLogChangedAt = Get-Date; $Monitor.IdleStartedMetrics = $metricsNow; $Monitor.HangReported = $false
    } elseif (($idleIoDelta / $noChange) -ge $BusyIoBytesPerSec) {
        Write-Log "[$Stage] 로그 무변화 ${noChangeText}초지만 트리 I/O +${idleIoDelta}B(${ioRate}B/s) — I/O 작업 중으로 보고 계속 대기" INFO
        $Monitor.LastLogChangedAt = Get-Date; $Monitor.IdleStartedMetrics = $metricsNow; $Monitor.HangReported = $false
    } elseif ($Config.KillOnHang) {
        Write-Log "⚠️ hang 감지 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 프로세스 트리 종료" WARN
        $decision = @{ Action = 'kill-hang' }
    } elseif (-not $Monitor.HangReported) {
        # CFG031 3분법: KillOnHang=$false 스테이지에서 git 진행 중이면 대기, 아니면 즉시 종료.
        # 특정 스테이지 이름을 하드코딩하지 않는다 — $Config.KillOnHang=$false인 모든 스테이지에 일반 적용.
        $gitInFlight = Test-GitOperationInFlight -RepoRoot $RepoRoot -ChildProcessIds $metricsNow.ChildProcessIds
        $wsMb = [math]::Round($metricsNow.WorkingSet / 1MB, 1)
        $handles = $metricsNow.HandleCount
        $childPids = if ($metricsNow.ChildProcessIds -and $metricsNow.ChildProcessIds.Count -gt 0) {
            $metricsNow.ChildProcessIds -join ', '
        } else {
            '없음'
        }
        if ($gitInFlight) {
            Write-Log "⚠️ hang 후보 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 점유 자원: WS ${wsMb}MB, 핸들 ${handles}개, 자식 PID: [$childPids]; git 작업 중이라 하드 상한까지 대기" WARN
            $Monitor.HangReported = $true
        } else {
            Write-Log "⚠️ hang 감지 [$Stage] — 로그 무변화 ${noChangeText}초, 그 구간 트리 CPU +${idleCpuDelta}s(코어 ${ratePct}% < 임계 ${thresholdPct}%); 진행 중인 git 커밋/푸시 없음(index.lock 없음, git 자식 프로세스 없음) — 프로세스 트리 종료" WARN
            $decision = @{ Action = 'kill-git' }
        }
    }
    return $decision
}

# 하드 상한 판정 — 확정된 직전 창과 진행 중인 창 중 큰 증가량으로 정체를 판정하고,
# 진행 중이면 연장해 돌아온다. 절대/고정 상한 초과일 때만 'die'를 반환하고
# 강제 종료(Stop-ProcessTree + $policyKilled)는 호출자가 수행한다.
function Test-StageDeadlineElapsed {
    param([string]$Stage, [hashtable]$Monitor, [long]$LogSize, [hashtable]$Limits, [string]$logAbs, [datetime]$StartedAt, $CpuNow)

    if ((Get-Date) -le $Monitor.Deadline) { return @{ Action = 'continue' } }
    # 창 경계 직후에 상한이 걸려 진행 중인 프로세스가 "이번 창은 아직 0B"라는 이유로 죽는 일을 막는다.
    $growth = [math]::Max($Monitor.LastWindowGrowth, [math]::Max(0, $LogSize - $Monitor.WindowStartSize))
    if ($growth -ge $HardTimeoutProgressBytes -and $Monitor.Deadline -lt $Monitor.AbsoluteDeadline) {
        $repeatedError = Get-RepeatedErrorObservation -LogPath $logAbs
        if ($repeatedError.Repeated) {
            Write-Log "⚠️ 반복 오류 관찰 [$Stage] — 최근 $($repeatedError.SampledLines)개 오류 줄 중 같은 문구 $($repeatedError.Count)회: $($repeatedError.Line) (경고 전용; 하드 상한 연장·종료 정책은 유지)" WARN
        }
        $Monitor.Deadline = $Monitor.Deadline.AddMinutes($Limits.ExtendStep)
        if ($Monitor.Deadline -gt $Monitor.AbsoluteDeadline) { $Monitor.Deadline = $Monitor.AbsoluteDeadline }
        $remain = [math]::Round(($Monitor.AbsoluteDeadline - (Get-Date)).TotalMinutes, 1)
        Write-Log "⏳ 하드 상한 연장 [$Stage] — 최근 $($Limits.ExtendStep)분 로그 +${growth}B(진행 중), 절대 상한($($Limits.HardMax)분)까지 ${remain}분 남음" WARN
        return @{ Action = 'continue' }
    }
    if ($Monitor.Deadline -ge $Monitor.AbsoluteDeadline) { $why = "절대 상한 $($Limits.HardMax)분 도달" }
    else { $why = "최근 $($Limits.ExtendStep)분 로그 +${growth}B < ${HardTimeoutProgressBytes}B(정체)" }
    $spent = [math]::Round(((Get-Date) - $StartedAt).TotalMinutes, 1)
    return @{ Action = 'die'; Message = "⛔ 하드 상한 초과 [$Stage] — $why; 경과 ${spent}분, 로그 ${LogSize} B, 트리 CPU +$([math]::Round($CpuNow.TotalSeconds, 2))s; 프로세스 트리 종료" }
}

# 프로세스 1회 실행 + hang/하드타임아웃 감시.
# 반환: 'ok'(정상 종료) · 'hang'(무변화로 강제 종료) · 'timeout'(하드 상한 초과로 강제 종료)
# 정상 종료 시 [ref]$ExitCode 에 종료 코드를 담는다($null이면 읽기 실패).
function Invoke-StageProcess {
    param([string]$Stage, [hashtable]$Config, [string]$ToolCmd, [int]$Cycle, [ref]$ExitCode, [ref]$ElapsedSeconds, [string]$Model)

    $logRel = $Config.LogFile
    $logAbs = Resolve-RepoPath $logRel
    $limits = Resolve-StageLimits -Config $Config
    $hangLimit = $limits.HangLimit

    # 자식 셸 스크립트를 만든 뒤 숨김 창으로 기동한다. -WindowStyle Hidden과 -NoNewWindow는
    # Windows PowerShell 5.1에서 같은 Start-Process에 함께 줄 수 없으므로, 별도 hidden child로
    # 시작해야 콘솔도 노출하지 않고 parameter-set 예외도 피한다.
    $shPath = New-DispatchScript -ToolCmd $ToolCmd -LogFile $logRel -Suffix ([guid]::NewGuid().ToString("N"))
    $startedAt = $null
    # hang·하드 상한으로 "정책상" 끊은 경우를 표시한다. taskkill은 종료를 요청만 하므로 직후
    # $proc.HasExited가 아직 $false일 수 있어, 생존 여부로 중단을 판정하면 정상 종료 경로에서
    # 중단 로그가 뜨고 이미 죽은(재활용됐을 수도 있는) PID를 한 번 더 죽이게 된다.
    $policyKilled = $false
    $proc = $null
    try {
        $startedAt = Get-Date
        $proc = Start-Process -FilePath $script:BashExe -WindowStyle Hidden -ArgumentList @($shPath) -PassThru
        $script:ActiveChildProcessId = $proc.Id; $script:ActiveChildStage = $Stage
        Write-StageState -Stage $Stage -Cycle $Cycle -State 'running' -ProcessId $proc.Id -EvidencePaths @($logRel) -Reason 'child process started' -Model $Model
        # Windows PowerShell 5.1은 Start-Process -PassThru의 Process 핸들을 미리 캐시하지 않으면
        # 종료 뒤 ExitCode가 $null로 남을 수 있다. 여기서 Handle을 한 번 읽어 캐시한다.
        $null = $proc.Handle
        Write-Log "진행 시작 [$Stage] (PID: $($proc.Id), 명령: $ToolCmd) — 실시간: Get-Content $logRel -Wait" INFO

        # 로그 무변화(hang) 감지 + 하드 상한 + 프로세스 종료 대기: 단일 루프로 전 구간 감시.
        $monitor = New-StageMonitorBaseline -Proc $proc -StartedAt $startedAt -Limits $limits
        while (-not $proc.HasExited) {
            Start-Sleep -Seconds $limits.Interval
            # 대기 중 정상 종료된 무출력 프로세스를 hang 임계 도달로 오판하지 않는다.
            # 특히 종료 시점이 임계 직전이면 이 재확인 없이 아래 noChange가 임계에 닿아
            # 이미 끝난 정상 프로세스를 'hang'으로 반환할 수 있다.
            $proc.Refresh()
            if ($proc.HasExited) { break }
            Write-StageState -Stage $Stage -Cycle $Cycle -State 'running' -ProcessId $proc.Id -EvidencePaths @($logRel) -Reason 'watcher heartbeat' -Model $Model
            $sz = if (Test-Path $logAbs) { (Get-Item $logAbs).Length } else { 0 }
            $logChanged = $sz -ne $monitor.LastSize
            if ($logChanged) { $monitor.LastLogChangedAt = Get-Date; $monitor.LastSize = $sz; $monitor.HangReported = $false }
            $noChange = [math]::Max(0, ((Get-Date) - $monitor.LastLogChangedAt).TotalSeconds)
            # 아래에서 $noChange를 증가율의 '분모'로 그대로 쓰므로 값 자체를 반올림하지 않는다.
            # 사람이 읽는 로그 문구에만 반올림한 별도 변수를 쓴다.
            $noChangeText = [math]::Round($noChange)

            # 자식 에이전트/도구를 포함한 트리 CPU. 무변화 구간의 '증가율'로 hang을 판정하므로,
            # 기준점(IdleStartedMetrics)은 로그가 변한 시점에만 리셋한다 — CPU 변화로도 리셋하면
            # 아래 계산이 늘 직전 한 틱만 보게 되어 판정이 무의미해진다.
            $metricsNow = Get-ProcessTreeMetrics -RootProcessId $proc.Id
            if ($logChanged) { $monitor.IdleStartedMetrics = $metricsNow }

            Advance-StageWindow -Monitor $monitor -LogSize $sz -ExtendStep $limits.ExtendStep
            Write-StageHeartbeat -Stage $Stage -StartedAt $startedAt -Monitor $monitor -LogSize $sz -CpuNow $metricsNow.Cpu -metricsNow $metricsNow

            if ($noChange -ge $hangLimit) {
                $hangDecision = Test-StageHangProgress -Stage $Stage -Monitor $monitor -metricsNow $metricsNow -noChange $noChange -noChangeText $noChangeText -Config $Config
                if ($hangDecision.Action -eq 'kill-hang') {
                    Stop-ProcessTree $proc.Id
                    $policyKilled = $true
                    Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" WARN
                    return 'hang'
                }
                if ($hangDecision.Action -eq 'kill-git') {
                    Stop-ProcessTree $proc.Id
                    $policyKilled = $true
                    Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" WARN
                    return 'hang'
                }
            }

            $deadlineDecision = Test-StageDeadlineElapsed -Stage $Stage -Monitor $monitor -LogSize $sz -Limits $limits -logAbs $logAbs -StartedAt $startedAt -CpuNow $metricsNow.Cpu
            if ($deadlineDecision.Action -eq 'die') {
                Write-Log $deadlineDecision.Message ERROR
                Stop-ProcessTree $proc.Id
                $policyKilled = $true
                Write-Log "강제 종료 [$Stage] (PID: $($proc.Id), 경과 $([math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1))초)" ERROR
                return 'timeout'
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

#endregion hang 감시·시간 예산·스테이지 실행
#region 모델 체인·사이클 원장·attempt 로그
function Resolve-ModelChain {
    param([hashtable]$Config, [string]$Stage)

    # PS 5.1 주의: `$models = if (...) {...} else { @($null) }` 형태로 쓰면 @($null)이
    # 단일 원소 언랩으로 $models 자체가 $null이 되어버린다(2026-08-08 CFG-001 QA 무동작 실측 —
    # while ($modelIndex -lt $models.Count)가 0 -lt 0으로 죽어 프로세스가 아예 안 뜸). 분기 안에서
    # 직접 대입해야 배열이 보존된다.
    # CFG024: qa·integration은 modelCatalog(어댑터 고정, opencode-go/big-pickle식 slash 식별자)가
    # 아니라 profiles(어댑터가 슬롯마다 달라질 수 있는 model-profile 체인)에서 해석되므로 별도 필드로
    # 구분한다 — ModelFallback의 slash-format Assert-ModelIdentifier 검증을 우회하지 않기 위함이다.
    # ContainsKey로 판정하는 이유: 후보가 전부 family 충돌로 걸러지면 @() 빈 배열을 명시적으로 넣어
    # "슬롯 없음"을 뒤 elseif(.Model)로 조용히 새지 않게 만든다(§Done When 4 — 사람 개입 필요 실패).
    if ($config.ContainsKey('ModelChain')) { $models = @($config.ModelChain) } elseif ($config.ModelFallback) { $models = @($config.ModelFallback) } elseif ($config.Model) { $models = @($config.Model) } else { $models = @($null) }

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
        $filtered = @()
        foreach ($m in $models) {
            $mKey = "model:$m"
            $mEntry = $health.providers.$mKey
            if ($mEntry -and $mEntry.nextProbeAt) {
                [datetime]$nextProbe = [datetime]::MinValue
                if (-not [datetime]::TryParse([string]$mEntry.nextProbeAt, [ref]$nextProbe)) {
                    Write-Log "provider health nextProbeAt is unreadable for $m; ignoring the corrupt cooldown entry" WARN
                } elseif ($nextProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                    Write-Log "[$Stage] preflight skip: $m (cooldown until $($nextProbe.ToUniversalTime().ToString('o')))" INFO
                    continue
                }
            }
            $mCatalog = $null
            if ($script:ProfileConfig.modelCatalog) { $mCatalog = $script:ProfileConfig.modelCatalog.$m }
            if ($mCatalog) {
                $principal = [string]$mCatalog.principal
                $pKey = "principal:$principal"
                $pEntry = $health.providers.$pKey
                if ($pEntry -and $pEntry.nextProbeAt) {
                    [datetime]$pProbe = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$pEntry.nextProbeAt, [ref]$pProbe) -and $pProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                        Write-Log "[$Stage] preflight skip: $m (principal $principal cooldown until $($pProbe.ToUniversalTime().ToString('o')))" INFO
                        continue
                    }
                }
                $rateCap = $null
                if ($script:ProfileConfig.rateLimit -and $script:ProfileConfig.rateLimit.$principal) { $rateCap = $script:ProfileConfig.rateLimit.$principal.maxCallsPerHour }
                if ($rateCap) {
                    $rateCount = Get-CallRateCount -State $health -Principal $principal -WindowMinutes 60
                    if ($rateCount -ge [int]$rateCap) {
                        Write-Log "[$Stage] preflight skip: $m (principal $principal rate limit: $rateCount/$rateCap calls in last 60m)" INFO
                        continue
                    }
                }
            }
            $filtered += $m
        }
        if ($filtered.Count -eq 0) {
            $blockedPrincipals = @()
            foreach ($prop in @($health.providers.psobject.Properties | Where-Object { $_.Name -like 'principal:*' })) {
                $pEntry = $health.providers.($prop.Name)
                if ($pEntry.nextProbeAt) {
                    [datetime]$pProbe = [datetime]::MinValue
                    if ([datetime]::TryParse([string]$pEntry.nextProbeAt, [ref]$pProbe) -and $pProbe.ToUniversalTime() -gt [datetime]::UtcNow) {
                        $blockedPrincipals += "$($prop.Name -replace 'principal:','') (until $($pProbe.ToUniversalTime().ToString('o')))"
                    }
                }
            }
            if ($script:ProfileConfig.rateLimit) {
                foreach ($prop in @($script:ProfileConfig.rateLimit.psobject.Properties)) {
                    $rateCap = $prop.Value.maxCallsPerHour
                    if (-not $rateCap) { continue }
                    $rateCount = Get-CallRateCount -State $health -Principal $prop.Name -WindowMinutes 60
                    if ($rateCount -ge [int]$rateCap) {
                        $blockedPrincipals += "$($prop.Name) (rate limit: $rateCount/$rateCap calls in last 60m)"
                    }
                }
            }
            Write-Log "[$Stage] 모든 슬롯이 쿼터/health cooldown 중 — 모델을 띄우지 않고 즉시 실패. Blocked: $($blockedPrincipals -join '; ')" ERROR
            $models = @()
        } else {
            $models = $filtered
            Write-Log "[$Stage] preflight 결과: $($models.Count)개 슬롯 가용 ($($models -join ' → '))" INFO
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

# CFG024: Resolve-ProfileChain이 반환한 프로필 이름 목록을 (Adapter, Model) 슬롯으로 해석한다.
# -ImplementerFamilies가 주어지면(§Done When 4 — QA 폴백 후보에만 적용) 구현자와 family가 겹치는
# 후보를 건너뛴다. 후보가 전부 걸러지면 빈 배열을 반환한다 — 자동 대체하지 않고 사람이 봐야 하는 실패다.
function Resolve-StageProfileSlots {
    param([string[]]$ProfileNames, [object]$Config, [string[]]$ImplementerFamilies = @(), [string]$Stage)
    $slots = @()
    foreach ($name in $ProfileNames) {
        $p = $Config.profiles.$name
        if ($null -eq $p) { Write-Log "[$Stage] 알 수 없는 프로필 건너뜀: $name" WARN; continue }
        $family = [string]$p.family
        if ($family -and $family -ne 'unknown' -and $ImplementerFamilies -contains $family) {
            Write-Log "[$Stage] 후보 건너뜀: $name (family=$family, 구현자와 동일 — must 위반)" WARN
            continue
        }
        $slots += [pscustomobject]@{ Name = $name; Adapter = [string]$p.adapter; Model = [string]$p.model }
    }
    return ,$slots
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
    Write-AtomicJson -Path $path -Value $value -Depth 6
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

#endregion 모델 체인·사이클 원장·attempt 로그
#region 승인·continuation·시도 판정·스테이지 원장
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
    Write-AtomicJson -Path $path -Value $value -Depth 6
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
        Write-AtomicJson -Path $path -Value $record -Depth 6
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

# CFG029: opencode 로그에서 세션 ID 추출 — JSON 형식의 sessionID 필드에서 파싱
function Get-OpencodeSessionId {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    $sessionIds = @()
    foreach ($line in @(Get-Content -LiteralPath $logAbs -ErrorAction SilentlyContinue)) {
        try { $event = $line | ConvertFrom-Json -ErrorAction Stop } catch { continue }
        $sid = [string]$event.sessionID
        if ($sid -and $sid -match '^ses_[A-Za-z0-9]+$') {
            $sessionIds += $sid
        }
    }
    $sessionIds = @($sessionIds | Select-Object -Unique)
    if ($sessionIds.Count -ne 1) { return $null }
    return $sessionIds[0]
}

# CFG029: codex 로그에서 세션 ID 추출 — "session id:" 라인에서 파싱
function Get-CodexSessionId {
    param([string]$AttemptLog)
    $logAbs = Resolve-RepoPath $AttemptLog
    if (-not (Test-Path -LiteralPath $logAbs)) { return $null }
    $sessionIds = @()
    foreach ($line in @(Get-Content -LiteralPath $logAbs -ErrorAction SilentlyContinue)) {
        if ($line -match 'session id:\s*([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})') {
            $sessionIds += $Matches[1].ToLowerInvariant()
        }
    }
    $sessionIds = @($sessionIds | Select-Object -Unique)
    if ($sessionIds.Count -ne 1) { return $null }
    return $sessionIds[0]
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
    Write-AtomicJson -Path $path -Value $record -Depth 8
    return $path
}

function Build-AntigravityContinuationCommand {
    param([hashtable]$Config, [string]$Model, [string]$ConversationId)
    if (-not $Config.ProjectId -or -not $ConversationId) { throw 'Antigravity continuation requires project and conversation IDs.' }
    $agyCommand = if ($Config.Executable) { ConvertTo-BashSingleQuoted ([string]$Config.Executable).Replace('\\','/') } else { 'agy' }
    $prompt = ConvertTo-BashSingleQuoted 'Continue the same assigned stage from the existing conversation. Do not restart discovery, do not create a fresh dispatch cycle, and preserve all existing safety restrictions.'
    return "$agyCommand --project $($Config.ProjectId) --model $Model --mode accept-edits --output-format stream-json --print-timeout 25m --conversation $ConversationId --print $prompt"
}

# CFG029: opencode continuation 명령 생성 — 세션 ID로 기존 세션 이어받기
function Build-OpencodeContinuationCommand {
    param([hashtable]$Config, [string]$Model, [string]$SessionId)
    if (-not $SessionId) { throw 'Opencode continuation requires session ID.' }
    $prompt = ConvertTo-BashSingleQuoted 'Continue the same assigned stage from the existing session. Do not restart discovery, do not create a fresh dispatch cycle, and preserve all existing safety restrictions.'
    return "opencode run --pure --auto -m $Model -s $SessionId $prompt"
}

# CFG029: codex continuation 명령 생성 — resume 서브커맨드로 기존 세션 이어받기
function Build-CodexContinuationCommand {
    param([hashtable]$Config, [string]$Model, [string]$SessionId)
    if (-not $SessionId) { throw 'Codex continuation requires session ID.' }
    $prompt = ConvertTo-BashSingleQuoted 'Continue the same assigned stage from the existing session. Do not restart discovery, do not create a fresh dispatch cycle, and preserve all existing safety restrictions.'
    return "codex exec resume $SessionId -m $Model --dangerously-bypass-approvals-and-sandbox -o $(ConvertTo-BashSingleQuoted $Config.ReportFile) $prompt"
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
    if (-not (Update-CallRate -Model $Model)) {
        return @{ Outcome = 'rate_limited'; ExitCode = $null; ElapsedSeconds = 0; LogStartBytes = $logStartBytes; Adapter = $Config.Adapter }
    }
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

function Get-FailureClass {
    param([string]$Outcome)
    if ($Outcome -in @('quota', 'billing', 'authentication', 'pollution', 'approval_required', 'config', 'rate_limited')) {
        return 'deterministic'
    }
    return 'transient'
}

function Get-FailureSignature {
    param([string]$FailureClass, [string]$Adapter, [string]$Reason)
    $cleanReason = if ($Reason) { $Reason } else { 'unknown' }
    $cleanReason = $cleanReason -replace '\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?Z?', ''
    $cleanReason = $cleanReason -replace '[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}', ''
    $cleanReason = $cleanReason -replace '\b(?:PID|pid)\s*[:=]?\s*\d+\b', ''
    $cleanReason = $cleanReason -replace '[A-Za-z]:\\[^\s"'']+', ''
    $cleanReason = ($cleanReason -replace '\s+', ' ').Trim()
    if ($cleanReason.Length -gt 60) { $cleanReason = $cleanReason.Substring(0, 60) }
    $safeAdapter = if ($Adapter) { $Adapter } else { 'default' }
    return "${FailureClass}:${safeAdapter}:${cleanReason}"
}

function Get-StageLedgerPath {
    param([string]$Stage)
    return (Resolve-RepoPath "$LogDir/$TaskId-$Stage-ledger.json")
}

function Read-StageLedger {
    param([string]$Stage)
    $path = Get-StageLedgerPath $Stage
    if (-not (Test-Path -LiteralPath $path)) { return [pscustomobject]@{ schemaVersion = 1; attempts = [pscustomobject]@{} } }
    try {
        $json = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -eq $json.attempts) { $json | Add-Member -NotePropertyName attempts -NotePropertyValue ([pscustomobject]@{}) -Force }
        return $json
    } catch {
        return [pscustomobject]@{ schemaVersion = 1; attempts = [pscustomobject]@{} }
    }
}

function Write-StageLedger {
    param([string]$Stage, [object]$Ledger)
    $path = Get-StageLedgerPath $Stage
    Write-AtomicJson -Path $path -Value $Ledger -Depth 6
}

function Record-StageAttempt {
    param([string]$Stage, [string]$Signature, [string]$FailureClass)
    $ledger = Read-StageLedger -Stage $Stage
    $prior = $ledger.attempts.$Signature
    $count = if ($prior) { [int]$prior.count + 1 } else { 1 }
    $entry = [pscustomobject]@{ count = $count; failureClass = $FailureClass; lastObservedAt = [datetime]::UtcNow.ToString('o') }
    $ledger.attempts | Add-Member -NotePropertyName $Signature -NotePropertyValue $entry -Force
    Write-StageLedger -Stage $Stage -Ledger $ledger

    $maxAllowed = if ($FailureClass -eq 'deterministic') { 1 } else { 3 }
    if ($count -ge $maxAllowed) {
        Write-BlockedMarker -Stage $Stage -Reason "시도 한도 도달 (${Signature}: ${count}회 / 상한 ${maxAllowed}회)" -OwnerTaskId $TaskId -OwnerProcessId $PID
        return @{ Blocked = $true; Count = $count; MaxAllowed = $maxAllowed }
    }
    return @{ Blocked = $false; Count = $count; MaxAllowed = $maxAllowed }
}

#endregion 승인·continuation·시도 판정·스테이지 원장
#region 원장 게이트·패킷·라우터 파싱·관측
# CFG037: QA 단계가 완료된 후 qa-verdict.json이 없으면 하네스가 직접 기록한다.
# QA 모델이 프롬프트 지시를 따르지 않거나 크래시·hang으로 파일 작성 전에 종료되면
# "verdict=fail"이 영원히 기록되지 않아 대시보드가 실제 QA 실패를 숨기는 결함이 있었다
# (실측: 34개 qa-verdict.json 전부 pass, fail 0건).
function Write-SyntheticQaVerdict {
    param([string]$Stage, [object]$Result, [int]$CycleNumber)
    if ($Stage -ne 'qa') { return }
    $verdictRel = $StageConfig['qa'].VerdictFile
    $verdictAbs = Resolve-RepoPath $verdictRel
    if (Test-Path -LiteralPath $verdictAbs) { return }
    $verdictValue = 'blocked'
    $reasonText = 'QA stage completed but no verdict file was written by the model'
    if ($Result.Success) {
        $verdictValue = 'pass'
        $reasonText = 'QA stage succeeded (verify passed) but model did not write verdict file — synthetic pass recorded by harness'
    } elseif ($Result.FailureReason) {
        $reasonText = [string]$Result.FailureReason
    }
    $value = [ordered]@{
        schemaVersion = 2
        taskId = $TaskId
        stage = 'qa'
        cycle = $CycleNumber
        verdict = $verdictValue
        reason = $reasonText
        doneWhen = @()
        findings = @()
        # CFG038: 합성 pass는 findings:[] 로 "무결함"으로 오독될 수 있으므로, 집계기가
        # "결함 없음"과 "모델이 기록하지 않음"을 구분하도록 측정 불가 플래그를 남긴다.
        findingsUnmeasured = $true
        synthetic = $true
        syntheticReason = 'model did not write qa-verdict.json; harness recorded outcome'
        observedAt = [datetime]::UtcNow.ToString('o')
    }
    Write-AtomicJson -Path $verdictAbs -Value $value -Depth 6
    Write-Log "⚠️ [qa] 합성 qa-verdict 기록: verdict=$verdictValue ($reasonText)" WARN
}

# CFG037: 모든 QA 라운드에서 qa-ledger.json이 작성되도록 한다.
# 기존 Record-StageAttempt는 실패만 기록하므로, 성공 라운드에서는 ledger가 작성되지 않았다
# (실측: 589개 로그 중 qa-ledger.json 2개뿐). 이 함수가 성공·실패 모두에서 ledger를 보장한다.
function Ensure-QaLedger {
    param([string]$Stage, [object]$Result)
    if ($Stage -ne 'qa') { return }
    $ledger = Read-StageLedger -Stage 'qa'
    $hasEntries = @($ledger.attempts.psobject.Properties).Count -gt 0
    if (-not $hasEntries) {
        $outcome = if ($Result.Success) { 'ok' } else { 'qa_failed' }
        $sig = "success:qa:$outcome"
        $rec = Record-StageAttempt -Stage 'qa' -Signature $sig -FailureClass 'transient'
    }
}

# CFG027: 구조적 원인 수정을 확인한 뒤 원장을 감사 가능하게 초기화하는 유일한 공식 경로.
# 이전에는 CFG025 QA 원장을 Write 툴로 직접 덮어쓰는 수동 워크어라운드가 두 번 반복됐다 —
# 사유 없는 초기화를 막기 위해 -ResetReason을 필수로 요구하고 초기화 이력을 별도 로그에 남긴다.
function Reset-StageLedger {
    param([string]$Stage, [string]$Reason)
    $prior = Read-StageLedger -Stage $Stage
    $priorCount = @($prior.attempts.psobject.Properties).Count
    $empty = [pscustomobject]@{ schemaVersion = 1; attempts = [pscustomobject]@{} }
    Write-StageLedger -Stage $Stage -Ledger $empty
    Clear-BlockedMarker -Stage $Stage
    $auditPath = Resolve-RepoPath "$LogDir/$TaskId-$Stage-ledger-resets.log"
    $safeReason = ($Reason -replace '\|', '/').Trim()
    $line = "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] cleared $priorCount attempt(s), blocked marker 해제 — $safeReason"
    try {
        [System.IO.File]::AppendAllText($auditPath, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } catch {
        # 감사 로그 기록 실패가 초기화 자체를 막지 않는다 — 초기화는 이미 완료됐다.
    }
    Write-Log "🔄 [$Stage] 원장 초기화 완료 (기존 $priorCount건 삭제, 차단 마커 해제) — $safeReason" SUCCESS
}

function Test-StageDispatchAllowed {
    param([string]$Stage)
    $blockedMarker = Get-BlockedMarkerPath $Stage
    if (Test-Path -LiteralPath $blockedMarker) {
        $markerText = Get-Content -LiteralPath $blockedMarker -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        return @{ Allowed = $false; Reason = "차단 마커 존재 ($markerText)" }
    }
    $ledger = Read-StageLedger -Stage $Stage
    foreach ($prop in @($ledger.attempts.psobject.Properties)) {
        $sig = $prop.Name
        $entry = $prop.Value
        $fClass = [string]$entry.failureClass
        $cnt = [int]$entry.count
        $max = if ($fClass -eq 'deterministic') { 1 } else { 3 }
        if ($cnt -ge $max) {
            Write-BlockedMarker -Stage $Stage -Reason "시도 한도 도달 (${sig}: ${cnt}회 / 상한 ${max}회)" -OwnerTaskId $TaskId -OwnerProcessId $PID
            return @{ Allowed = $false; Reason = "원장 시도 한도 도달 (${sig}: ${cnt} / ${max})" }
        }
    }
    return @{ Allowed = $true }
}


# CFG024: 프로토콜 오염 감지 — 구현(②) 단계 전후 스냅숏을 비교해 신규 패킷 생성 및 타 작업 라우터 행 변조를 기계적으로 차단한다.
# 특정 모델을 겨냥한 것이 아니며 파이프라인 전체의 fail-closed 구조적 안전장치다.
function Get-PacketFileSnapshot {
    $packetDir = Resolve-RepoPath '.agents/briefs/packets'
    if (-not (Test-Path -LiteralPath $packetDir)) { return @() }
    return @(Get-ChildItem -LiteralPath $packetDir -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
}

function Get-RouterTableSnapshot {
    $routerPath = Resolve-RepoPath '.agents/briefs/handoff-log.md'
    if (-not (Test-Path -LiteralPath $routerPath)) { return @{} }
    $rows = @{}
    $lines = Get-Content -LiteralPath $routerPath -Encoding UTF8 -ErrorAction SilentlyContinue
    foreach ($line in $lines) {
        if ($line -match '^\s*\|\s*([^|]+)\s*\|') {
            $tId = $Matches[1].Trim()
            if ($tId -and $tId -notmatch '^-+$' -and $tId -ne '작업 ID' -and $tId -ne 'Task ID') {
                $rows[$tId] = $line.Trim()
            }
        }
    }
    return $rows
}

function Test-ProtocolPollution {
    param(
        [string]$Stage,
        [string[]]$PacketsBefore,
        [hashtable]$RouterBefore
    )
    if ($Stage -ne 'impl') { return @{ Polluted = $false } }
    $packetsAfter = Get-PacketFileSnapshot
    $newPackets = @($packetsAfter | Where-Object { $_ -notin $PacketsBefore })
    if ($newPackets.Count -gt 0) {
        $msg = "신규 패킷 파일 생성 감지 ($($newPackets -join ', ')) — 구현 단계 권한 초과"
        Write-Log "❌ [$Stage] $msg" ERROR
        return @{ Polluted = $true; Reason = $msg }
    }
    $routerAfter = Get-RouterTableSnapshot
    foreach ($k in $RouterBefore.Keys) {
        if ($k -eq $TaskId -or $k -eq (Get-NormalizedTaskId $TaskId)) { continue }
        if ($routerAfter.ContainsKey($k) -and $routerAfter[$k] -ne $RouterBefore[$k]) {
            $msg = "타 작업($k) 라우터 행 임의 변경 감지 — 구현 단계 권한 초과"
            Write-Log "❌ [$Stage] $msg" ERROR
            return @{ Polluted = $true; Reason = $msg }
        }
    }
    return @{ Polluted = $false }
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

# 경량 등급 선언 여부만 읽는다 — Pipeline Status ④ 체크와 별개 신호로, 둘 다 있어야 QA 스킵이 성립한다.
function Get-PacketGateTier {
    param([string]$PacketPath)
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return 'full' }
    $text = Get-Content -LiteralPath $PacketPath -Raw -Encoding UTF8
    if ($text -match '(?im)^-\s*게이트\s*등급\s*[:：]\s*경량\b') { return 'light' }
    return 'full'
}

# CFG041: 신규 패킷의 `Planning Challenge Review` 블록 상태를 파싱한다. 기존 ①~⑤ Pipeline Status에는
# 편입하지 않고, 미해소(`requested`)·결손·오류 Decision을 파서 수준에서 fail-closed로 판정한다.
# 레거시(블록 없음) 패킷은 호환성을 위해 항상 Ready=true로 통과시킨다.

function Assert-PlanningChallengeReviewReady {
    param([string]$PacketPath)
    $status = Get-PlanningChallengeReviewStatus -PacketPath $PacketPath
    if (-not $status.Ready) {
        throw "Planning Challenge Review blocks implementation: $($status.Reason) (Decision=$($status.Decision))"
    }
    return $status
}

# 역할 판정은 Pipeline Status 섹션에만 한정한다. 다른 체크박스는 검증·인수인계 목록일 수 있다.

# CFG027: opencode 등 구현 에이전트가 자체 리뷰 후 Pipeline Status 체크박스 갱신을 누락하는
# 사례가 반복돼(CFG025 ③ 소급 체크 필요) 기획팀이 git diff로 실구현을 확인한 뒤 손으로 체크했다.
# 하네스는 이미 "단계 성공(=verify.ps1 통과)"이라는 근거를 갖고 있으므로, 그 근거로 대신 체크한다.
function Set-PacketCheckboxes {
    param([string]$PacketPath, [int[]]$Indexes, [string]$Annotation)
    if (-not $PacketPath -or -not (Test-Path -LiteralPath $PacketPath)) { return $false }
    $lines = @(Get-Content -LiteralPath $PacketPath -Encoding UTF8)
    $inSection = $false
    $changed = $false
    $circles = '①②③④⑤'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -match '^##\s+Pipeline Status\s*$') { $inSection = $true; continue }
        if ($inSection -and $line -match '^##\s+') { break }
        if (-not $inSection -or $line -notmatch '^\s*-\s*\[([ xX])\]') { continue }
        if ($line -match '^\s*-\s*\[[xX]\]') { continue }
        $stageMatch = [regex]::Match($line, '[①②③④⑤]')
        if (-not $stageMatch.Success) { continue }
        $idx = $circles.IndexOf($stageMatch.Value) + 1
        if ($Indexes -notcontains $idx) { continue }
        $newLine = $line -replace '^(\s*-\s*)\[ \]', '$1[x]'
        if ($Annotation) { $newLine = "$newLine $Annotation" }
        $lines[$i] = $newLine
        $changed = $true
    }
    if ($changed) {
        [System.IO.File]::WriteAllLines($PacketPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
    }
    return $changed
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


function Resolve-ForceFreeModelChain {
    param(
        [string[]]$ModelFallback,
        [object]$ProfileConfig,
        [bool]$ForceFreeModel
    )
    $shouldForceFree = $ForceFreeModel -or ($ProfileConfig.preferCost -and [string]$ProfileConfig.preferCost -eq 'free')
    if (-not $shouldForceFree) { return @($ModelFallback) }
    $freeModels = @($ModelFallback | Where-Object {
        $ProfileConfig.modelCatalog.$_ -and [string]$ProfileConfig.modelCatalog.$_.cost -eq 'free'
    })
    $sourceLabel = if ($ForceFreeModel) { '-ForceFreeModel' } else { 'preferCost: free' }
    if ($freeModels.Count -eq 0) {
        Write-Log ("⛔ {0} 지정됐지만 modelCatalog에 cost=free 슬롯이 없음 — 원래 체인 유지" -f $sourceLabel) ERROR
        return @($ModelFallback)
    }
    Write-Log ("[impl] {0}: 유료 슬롯 건너뛰고 무료로 직행 ({1})" -f $sourceLabel, ($freeModels -join ' → ')) INFO
    return @($freeModels)
}

function Test-PipelineRoleContention {
    param(
        [string]$ImplPrincipal,
        [string]$QaPrincipal,
        [string]$IntegrationPrincipal
    )
    $stages = [ordered]@{
        impl = $ImplPrincipal
        qa = $QaPrincipal
        integration = $IntegrationPrincipal
    }
    $seen = @{}
    $contentions = @()
    foreach ($stageName in $stages.Keys) {
        $p = $stages[$stageName]
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        if ($seen.ContainsKey($p)) {
            $otherStage = $seen[$p]
            $contentions += "$otherStage & $stageName share principal '$p'"
        } else {
            $seen[$p] = $stageName
        }
    }
    if ($contentions.Count -gt 0) {
        return [pscustomobject]@{ Contention = $true; Details = ($contentions -join '; ') }
    }
    return [pscustomobject]@{ Contention = $false; Details = $null }
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
            Write-AtomicJson -Path $recordFile.FullName -Value $record -Depth 8
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
    $unchecked = @($status.Items | Where-Object { $expected -contains $_.Index -and -not $_.Checked })
    if ($unchecked.Count -eq 0) { return }
    $labels = ($unchecked | ForEach-Object { $_.Label }) -join '; '
    Write-Log "⚠️ [$Stage] 성공했지만 패킷 Pipeline Status가 갱신되지 않았습니다 — 하네스가 대신 체크합니다: $labels" WARN
    # CFG027: 구현 에이전트가 체크박스 갱신을 누락해도 파이프라인이 실구현 상태와 어긋나지 않도록,
    # 하네스가 이미 확보한 "단계 성공(verify.ps1 통과)" 근거로 대신 체크한다 — WARN만 남기고 방치하지 않는다.
    $indexes = @($unchecked | ForEach-Object { [int]$_.Index })
    $updated = Set-PacketCheckboxes -PacketPath $PacketPath -Indexes $indexes -Annotation "(자동 갱신 — 하네스가 $Stage 단계 성공 확인 후 대신 체크, 구현 에이전트 누락분)"
    # CFG038: ④(QA)를 하네스가 대신 체크했으면 'QA 판단 없음'을 verdict에 남긴다 — QA가 아무
    # 판단도 쓰지 않아도 pass와 구분되도록(실측 CFG028·CFG032·CFG035).
    if ($Stage -eq 'qa') { Set-QaVerdictStageHarnessFlag -CheckedIndexes $indexes }
    if ($updated) { Write-Log "✅ [$Stage] Pipeline Status 자동 갱신 완료" SUCCESS }
}

# CFG038: 하네스가 ④(QA) 체크박스를 대신 체크한 경우, verdict에 stageCheckedByHarness=true 를 남긴다.
# verdict가 있으면 그 안에, 없으면 별도 상태 파일(.agents/briefs/logs/$TaskId-qa-stage-checked.json)에 기록한다.
function Set-QaVerdictStageHarnessFlag {
    param([int[]]$CheckedIndexes)
    if (4 -notin $CheckedIndexes) { return }
    $verdictRel = $StageConfig['qa'].VerdictFile
    $verdictAbs = Resolve-RepoPath $verdictRel
    if (Test-Path -LiteralPath $verdictAbs) {
        try {
            $obj = Get-Content -LiteralPath $verdictAbs -Raw -Encoding UTF8 | ConvertFrom-Json
            $obj | Add-Member -NotePropertyName stageCheckedByHarness -NotePropertyValue $true -Force
            Write-AtomicJson -Path $verdictAbs -Value $obj -Depth 8
            Write-Log "⚠️ [qa] verdict에 stageCheckedByHarness=true 기록 — 하네스가 ④를 대신 체크했습니다" WARN
        } catch {
            Write-Log "[qa] stageCheckedByHarness 기록 실패($verdictAbs): $($_.Exception.Message)" WARN
        }
    } else {
        $stateAbs = Resolve-RepoPath "$LogDir/$TaskId-qa-stage-checked.json"
        $state = [ordered]@{ schemaVersion = 1; taskId = $TaskId; stage = 'qa'; stageCheckedByHarness = $true; checkedAt = [datetime]::UtcNow.ToString('o') }
        Write-AtomicJson -Path $stateAbs -Value $state -Depth 4
        Write-Log "⚠️ [qa] verdict 부재 — 별도 상태 파일에 stageCheckedByHarness=true 기록" WARN
    }
}

# CFG026: 착수 컨텍스트 바이트 수 측정. 모델이 실제로 로드하는 문서(전역 CLAUDE.md, 프로젝트
# CLAUDE.md, 라우터, 패킷 전문, Required Reading)와 DefaultPrompt의 합산 바이트를 잰다.
# 측정 자체가 컨텍스트를 늘리지 않도록, 이미 존재하는 파일의 크기만 읽는다.
function Measure-ContextBytes {
    param([string]$Stage)

    $globalClaude = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.claude\CLAUDE.md' } else { $null }
    $projectClaude = Join-Path $RepoRoot 'CLAUDE.md'
    $routerPath = Resolve-RepoPath '.agents/briefs/handoff-log.md'

    $totalBytes = 0
    $parts = @{}

    # 전역 CLAUDE.md
    $b = 0
    if ($globalClaude -and (Test-Path -LiteralPath $globalClaude)) { $b = (Get-Item -LiteralPath $globalClaude).Length }
    $parts['global_claude_md'] = $b; $totalBytes += $b

    # 프로젝트 CLAUDE.md
    $b = 0
    if (Test-Path -LiteralPath $projectClaude) { $b = (Get-Item -LiteralPath $projectClaude).Length }
    $parts['project_claude_md'] = $b; $totalBytes += $b

    # 라우터
    $b = 0
    if (Test-Path -LiteralPath $routerPath) { $b = (Get-Item -LiteralPath $routerPath).Length }
    $parts['router'] = $b; $totalBytes += $b

    # 패킷 전문 + Required Reading
    $packetBytes = 0; $requiredReadingBytes = 0
    $packetDir = Resolve-RepoPath '.agents/briefs/packets'
    $archiveDir = Resolve-RepoPath '.agents/briefs/archive'
    $packetPath = $null
    foreach ($dir in @($packetDir, $archiveDir)) {
        $match = Get-ChildItem -Path $dir -Filter "$TaskId-*.md" -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($match) { $packetPath = $match.FullName; break }
    }
    if ($packetPath -and (Test-Path -LiteralPath $packetPath)) {
        $packetBytes = (Get-Item -LiteralPath $packetPath).Length
        $packetText = Get-Content -LiteralPath $packetPath -Raw -Encoding UTF8
        $rrMatch = [regex]::Match($packetText, '(?s)##\s*Required Reading\s*\n(.+?)(?=\n##\s|\z)')
        if ($rrMatch.Success) {
            # Required Reading의 백틱 안에는 파일 경로만 있는 것이 아니다 — `agy models`, `model:<name>`,
            # `@('claude','codex')` 처럼 설명용 토큰이 섞인다. 이런 문자열을 경로 API에 그대로 넘기면
            # IsPathRooted가 "Illegal characters in path"로 throw하고, 측정 코드가 디스패치 전체를
            # 죽인다(2026-08-31 CFG046 impl 실측). 경로가 아닌 토큰은 조용히 건너뛴다.
            $invalidPathChars = [System.IO.Path]::GetInvalidPathChars()
            foreach ($m in [regex]::Matches($rrMatch.Groups[1].Value, '`([^`]+)`')) {
                $relPath = $m.Groups[1].Value.Trim().TrimEnd('.')
                if ([string]::IsNullOrWhiteSpace($relPath)) { continue }
                if ($relPath.IndexOfAny($invalidPathChars) -ge 0) { continue }
                # 드라이브 문자를 뺀 콜론은 경로가 아니다(`model:<name>`, `principal:opencode-go`).
                $colonIndex = $relPath.IndexOf(':')
                if ($colonIndex -ge 0 -and $colonIndex -ne 1) { continue }
                $absPath = if ($relPath.StartsWith('~')) {
                    if ($env:USERPROFILE) {
                        Join-Path $env:USERPROFILE ($relPath.Substring(1).TrimStart('/\') -replace '/','\')
                    } else { $null }
                } elseif ([System.IO.Path]::IsPathRooted($relPath)) {
                    $relPath
                } else {
                    Join-Path $RepoRoot ($relPath -replace '/','\')
                }
                if ($absPath -and (Test-Path -LiteralPath $absPath)) { $requiredReadingBytes += (Get-Item -LiteralPath $absPath).Length }
            }
        }
    }
    $parts['packet'] = $packetBytes; $totalBytes += $packetBytes
    $parts['required_reading'] = $requiredReadingBytes; $totalBytes += $requiredReadingBytes

    # DefaultPrompt
    $promptBytes = 0
    $p = $StageConfig[$Stage].DefaultPrompt
    if ($p) { $promptBytes = [System.Text.Encoding]::UTF8.GetByteCount($p) }
    $parts['default_prompt'] = $promptBytes; $totalBytes += $promptBytes

    Write-Log "[context-size] stage=$Stage bytes=$totalBytes (global_claude=$($parts.global_claude_md) project_claude=$($parts.project_claude_md) router=$($parts.router) packet=$($parts.packet) required_reading=$($parts.required_reading) prompt=$($parts.default_prompt))" INFO
}

# 한 단계 디스패치 + hang 감지 + 판정. 성공(종료 코드 정상 + verify 통과) 시 $true.
# ModelFallback이 있는 단계(impl)는 모델을 바꿔가며 순서대로 시도한다 — 같은 모델을 두 번 부르지 않는다.
#endregion 원장 게이트·패킷·라우터 파싱·관측
#region 디스패치 본체 — ②③④⑤ 단계 기동·감시·판정 오케스트레이션 (CFG040 분해)
# =====================================================================
# [디스패치 본체] Dispatch-Stage 분해 도우미(CFG040) — 단계 디스패치의
# 준비·슬롯 해석·종결을 책임 단위로 분리한다. 결정 로직만 도우미에 두고,
# continue/break 흐름 제어는 의미상 호출자인 Dispatch-Stage가 수행한다.
# =====================================================================
# -DryRun: 임시 파일을 남기지 않고 실제로 실행될 .sh 본문을 그대로 보여준다(체인 1번째 모델 기준).
function Show-StageDryRun {
    param([string]$Stage, [hashtable]$Config, [string]$LogRel, [string]$PromptOverride, [string]$Model, [bool]$BypassToolPermissions)

    $toolCmd = Build-ToolCommand -Config $Config -Stage $Stage -PromptOverride $PromptOverride -Model $Model -BypassToolPermissions:$BypassToolPermissions
    Write-Log "작업 $TaskId [$Stage] 디스패치" INFO
    Write-Log "명령: $toolCmd" INFO
    Write-Log "로그: $LogRel" INFO
    $shPath = New-DispatchScript -ToolCmd $toolCmd -LogFile $LogRel -Suffix "dryrun-$TaskId-$Stage"
    try {
        Write-Log "[DryRun] 실행 생략 — 생성될 bash 스크립트:" WARN
        Write-Host ([System.IO.File]::ReadAllText($shPath, [System.Text.UTF8Encoding]::new($false)))
    } finally {
        Remove-Item $shPath -ErrorAction SilentlyContinue
    }
    return @{ Success = $true; FailureReason = $null; QaDispatchedAt = $null }
}

# 디스패치 준비 전반 a: 로그 디렉터리·와처 로그·durable 사이클 할당·starting 상태 원장.
# CFG017: fresh direct 디스패치마다 durable 사이클을 할당한다. 같은 TaskId/단계의 재디스패치는
# 단조 증가하는 새 사이클 번호를 받고, 과거 사이클의 attempt 로그는 이름에 cycle이 박혀 불변으로 남는다.
function Initialize-StageDispatch {
    param([string]$Stage, [hashtable]$Config, [string]$LogRel)

    $logDirAbs = Resolve-RepoPath $LogDir
    if (-not (Test-Path $logDirAbs)) { New-Item -ItemType Directory -Path $logDirAbs -Force | Out-Null }
    Initialize-WatcherLog -Stage $Stage
    $cycle = New-DispatchCycle -Stage $Stage
    Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'starting' -ProcessId $PID -EvidencePaths @($LogRel) -Reason 'dispatcher accepted stage' -Model $null
    Write-Log "디스패치 사이클: $($cycle.Token) (id $($cycle.Id))" INFO
    return $cycle
}

# 디스패치 준비 전반 b: ④ QA 이전 실행 verdict·보고서 정리.
# 이번 실행이 verdict를 쓰지 못하고 끝났을 때 직전 실행의 pass를 재사용해 ⑤로 넘어가는 오탐을 막는다.
function Clear-QaArtifacts {
    param([string]$Stage, [hashtable]$Config)

    if ($Stage -ne 'qa') { return $null }
    foreach ($rel in @($Config.VerdictFile, $Config.ReportFile)) {
        $abs = Resolve-RepoPath $rel
        if (Test-Path $abs) {
            Remove-Item $abs -Force
            Write-Log "이전 실행 산출물 삭제: $rel" INFO
        }
    }
    return (Get-Date)
}

# 읽기 전용 preflight 게이트 — PATH·버전·project mapping 진단(외부 설정 무변경).
# CFG017: Antigravity 어댑터 단계는 실행 전 읽기 전용 preflight로 PATH·버전·project mapping을
# 진단한다. 이 진단은 외부 설정(설치·매핑·환경 변수)을 절대 변경하지 않는다.
# CFG028: AdapterChain이 존재하면 슬롯 0 실패 시에도 후속 슬롯(opencode 등) 시도를 위해 즉시 실패시키지 않고 경고 후 계속 진행.
function Invoke-StagePreflightGate {
    param([string]$Stage, [hashtable]$config, $Cycle, [string]$LogRel, $qaDispatchedAt)

    $preflight = Test-AntigravityPreflight -Stage $Stage
    if (-not $preflight.Ready) {
        $reason = "Antigravity preflight 실패: $($preflight.Warnings -join '; ')"
        if (($config.AdapterChain -and $config.AdapterChain.Count -gt 0) -or ($config.AdapterMap -and $config.AdapterMap.Count -gt 1)) {
            Write-Log "⚠️ [$Stage] $reason (AdapterChain 설정됨 — 슬롯별 폴백을 위해 모델 루프 계속 진행)" WARN
        } else {
            Write-Log "❌ [$Stage] $reason" ERROR
            Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $reason -Model $null
            return @{ Abort = $true; Reason = $reason }
        }
    }
    if ($config.Adapter -eq 'antigravity' -and $preflight.Executable) { $config.Executable = $preflight.Executable }
    if ($preflight.Diagnostics.Count -gt 0) { Write-Log "[$Stage] preflight: $($preflight.Diagnostics -join ' | ')" INFO }
    return @{ Abort = $false }
}

# 슬롯별 어댑터 해석 — qa·integration 폴백 체인은 슬롯마다 어댑터가 달라질 수 있다(예: gemini-qa는
# antigravity → opencode). AdapterChain이 있으면 이번 슬롯의 어댑터로 $config를 갱신하고,
# antigravity면 ProjectId·Executable도 그 슬롯 기준으로 다시 확인한다.
# CFG028: antigravity 매핑 실패 시 unhandled exception 방지 -> WARN + 다음 슬롯 모델로 전환.
function Resolve-SlotAdapter {
    param([hashtable]$config, [string]$Stage, [int]$ModelIndex, [string]$Model, [string]$RepoRoot)

    # impl 체인은 preflight cooldown 필터로 슬롯이 걸러지므로 인덱스 기반 AdapterChain은 필터 후
    # 어긋난다. AdapterMap(모델 식별자 → 어댑터)이 있으면 그쪽을 우선한다.
    if ($config.AdapterMap -and $Model -and $config.AdapterMap.ContainsKey($Model)) {
        $config.Adapter = [string]$config.AdapterMap[$Model]
    } elseif ($config.AdapterChain -and $ModelIndex -lt $config.AdapterChain.Count) {
        $config.Adapter = $config.AdapterChain[$ModelIndex]
    } else {
        return @{ Next = $false; Failure = $null }
    }
    if ($config.Adapter -ne 'antigravity') { return @{ Next = $false; Failure = $null } }
    try {
        $config.ProjectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot
        $slotPreflight = Test-AntigravityPreflight -Stage $Stage
        if ($slotPreflight.Executable) { $config.Executable = $slotPreflight.Executable }
        return @{ Next = $false; Failure = $null }
    } catch {
        $slotReason = "슬롯 $($ModelIndex + 1) antigravity 매핑/preflight 실패: $($_.Exception.Message)"
        Write-Log "⚠️ [$Stage] $slotReason — 다음 슬롯 모델로 전환합니다" WARN
        return @{ Next = $true; Failure = "model $($ModelIndex + 1) ($Model): $slotReason" }
    }
}

# 승인 대기 종결 — headless 권한 요청은 재시도 불가능한 종결 상태다. 모델 체인 전환·자동 재시도를
# 절대 하지 않는다. 정확 target을 추출해 승인 대기 기록을 남기고 즉시 돌아간다(CFG017).
function Complete-StageApprovalRequired {
    param([string]$Stage, [hashtable]$config, $Cycle, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [string]$LogRel, $qaDispatchedAt, $Evidence)

    $target = if ($Evidence) { $Evidence.Target } else { $null }
    $targetLabel = if ($target) { $target } elseif ($Evidence) { "null ($($Evidence.TargetExtractionReason))" } else { 'null (structured terminal evidence missing)' }
    $approvalPath = Write-ApprovalRecord -Stage $Stage -CycleNumber $Cycle.Id -AttemptNumber $AttemptNumber -Model $Model -AttemptLog $AttemptLog -Evidence $Evidence
    Write-Log "❌ [$Stage] Antigravity headless 권한 요청 → 승인 대기 (approval_required)" ERROR
    Write-Log "대상 명령: $targetLabel" WARN
    Write-Log "승인 기록: $approvalPath" INFO
    Write-Log "동작: 대상 확인 후 headless 프로세스 밖에서 승인을 마치고, 명시적으로 새 사이클의 fresh 디스패치를 시작하세요." WARN
    Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'approval_required' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $targetLabel -Model $Model
    $null = Record-StageAttempt -Stage $Stage -Signature "deterministic:$($config.Adapter):approval_required" -FailureClass 'deterministic'
    return @{ Success = $false; Outcome = 'approval_required'; ApprovalPath = $approvalPath; QaDispatchedAt = $qaDispatchedAt; CycleId = $Cycle.Id }
}

# provider print timeout 재개 결정 — opencode/codex 어댑터에도 continuation 지원(CFG029).
# stream-json의 정확 대화/세션 ID + 기존 로그 성장 건강도가 맞을 때만 동일 사이클에서 재개한다.
function Resume-ProviderTimeout {
    param([string]$Stage, [hashtable]$config, $Cycle, $Attempt, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [int]$ContinuationCount, [double]$LogicalHardLimit, [datetime]$LogicalAbsoluteDeadline)

    $conversationId = $null
    $sessionId = $null
    $active = $false
    $withinBudget = (Get-Date) -lt $LogicalAbsoluteDeadline
    $activityWindowMinutes = [Math]::Max(1, [Math]::Round($LogicalHardLimit / 3.0, 2))

    if ($config.Adapter -eq 'antigravity') {
        $conversationId = Get-AntigravityConversationId -AttemptLog $AttemptLog
        $active = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $activityWindowMinutes
    } elseif ($config.Adapter -eq 'opencode') {
        $sessionId = Get-OpencodeSessionId -AttemptLog $AttemptLog
        $active = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $activityWindowMinutes
    } elseif ($config.Adapter -eq 'codex') {
        $sessionId = Get-CodexSessionId -AttemptLog $AttemptLog
        $active = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $activityWindowMinutes
    }

    $canContinue = $false
    $continuationReason = ''
    if ($config.Adapter -eq 'antigravity') {
        $canContinue = $active -and $conversationId -and $ContinuationCount -lt 2 -and $withinBudget
        if (-not $conversationId) { $continuationReason = 'exact conversation ID missing or ambiguous' }
        elseif (-not $active) { $continuationReason = 'no healthy stream-json activity' }
        elseif (-not $withinBudget) { $continuationReason = 'logical absolute deadline reached' }
        elseif ($ContinuationCount -ge 2) { $continuationReason = 'automatic continuation limit reached' }
        else { $continuationReason = 'healthy provider timeout; resume same conversation' }
    } elseif ($config.Adapter -eq 'opencode') {
        $canContinue = $active -and $sessionId -and $ContinuationCount -lt 2 -and $withinBudget
        if (-not $sessionId) { $continuationReason = 'opencode session ID missing or ambiguous' }
        elseif (-not $active) { $continuationReason = 'no healthy log activity' }
        elseif (-not $withinBudget) { $continuationReason = 'logical absolute deadline reached' }
        elseif ($ContinuationCount -ge 2) { $continuationReason = 'automatic continuation limit reached' }
        else { $continuationReason = 'healthy provider timeout; resume same session' }
    } elseif ($config.Adapter -eq 'codex') {
        $canContinue = $active -and $sessionId -and $ContinuationCount -lt 2 -and $withinBudget
        if (-not $sessionId) { $continuationReason = 'codex session ID missing or ambiguous' }
        elseif (-not $active) { $continuationReason = 'no healthy log activity' }
        elseif (-not $withinBudget) { $continuationReason = 'logical absolute deadline reached' }
        elseif ($ContinuationCount -ge 2) { $continuationReason = 'automatic continuation limit reached' }
        else { $continuationReason = 'healthy provider timeout; resume same session' }
    }

    # CFG029 Integration 수정: PowerShell -or는 불리언 $true/$false를 반환하므로 문자열
    # 세션 ID가 그대로 전달되지 않고 "True"/"False"로 뭉개진다. 실제 값을 보존하려면 값 자체를 골라야 한다.
    $recordConversationId = if ($conversationId) { $conversationId } elseif ($sessionId) { $sessionId } else { $null }
    $continuationPath = Write-ContinuationRecord -Stage $Stage -CycleNumber $Cycle.Id -AttemptNumber $AttemptNumber -AttemptLog $AttemptLog -ConversationId $recordConversationId -Active $active -Resumed $canContinue -Reason $continuationReason
    if (-not $canContinue) {
        Write-Log "⛔ [$Stage] provider print timeout 재개 불가: $continuationReason (cycle $($Cycle.Token), 기록: $continuationPath)" ERROR
        return @{ Continue = $false; ContinuationCount = $ContinuationCount; ToolCmd = $null }
    }
    $nextCount = $ContinuationCount + 1
    $toolCmd = if ($config.Adapter -eq 'antigravity') {
        Build-AntigravityContinuationCommand -Config $config -Model $Model -ConversationId $conversationId
    } elseif ($config.Adapter -eq 'opencode') {
        Build-OpencodeContinuationCommand -Config $config -Model $Model -SessionId $sessionId
    } elseif ($config.Adapter -eq 'codex') {
        Build-CodexContinuationCommand -Config $config -Model $Model -SessionId $sessionId
    }
    Write-Log "⏳ [$Stage] provider print timeout 뒤 건강한 동일 세션 자동 재개 $nextCount/2 (cycle $($Cycle.Token), 기록: $continuationPath)" WARN
    return @{ Continue = $true; ContinuationCount = $nextCount; ToolCmd = $toolCmd }
}

# hang 재시도 결정 — 최대 1회(CFG024 hang-detect-agent Iron Law). 강제 종료 직전 로그에 세션 ID가
# 남아 있고 최근까지 건강한 활동이 있었다면 처음부터 다시 읽히지 않고 그 세션을 이어받는다(CFG029),
# 못 찾으면 기존과 동일하게 콜드 재시작으로 안전 폴백한다(스테이지를 실패시키지 않는다).
function Prepare-HangRetry {
    param([string]$Stage, [hashtable]$config, $Cycle, $Attempt, [int]$AttemptNumber, [string]$Model, [string]$AttemptLog, [double]$LogicalHardLimit, $Before)

    Write-KilledLeftover -Before $Before -Stage $Stage -Context "1차 시도 강제 종료"
    $hangSessionId = $null
    $hangActive = $false
    if ($config.Adapter -eq 'opencode') {
        $hangSessionId = Get-OpencodeSessionId -AttemptLog $AttemptLog
    } elseif ($config.Adapter -eq 'codex') {
        $hangSessionId = Get-CodexSessionId -AttemptLog $AttemptLog
    }
    $toolCmd = $null
    if ($hangSessionId) {
        $hangActivityWindowMinutes = [Math]::Max(1, [Math]::Round($LogicalHardLimit / 3.0, 2))
        $hangActive = Test-AntigravityContinuationActivity -AttemptLog $AttemptLog -LogStartBytes $Attempt.LogStartBytes -RecentWindowMinutes $hangActivityWindowMinutes
    }
    if ($hangSessionId -and $hangActive) {
        $continuationPath = Write-ContinuationRecord -Stage $Stage -CycleNumber $Cycle.Id -AttemptNumber $AttemptNumber -AttemptLog $AttemptLog -ConversationId $hangSessionId -Active $hangActive -Resumed $true -Reason 'hang retry; resume same session'
        if ($config.Adapter -eq 'opencode') {
            $toolCmd = Build-OpencodeContinuationCommand -Config $config -Model $Model -SessionId $hangSessionId
        } else {
            $toolCmd = Build-CodexContinuationCommand -Config $config -Model $Model -SessionId $hangSessionId
        }
        Write-Log "⚠️ HANG [1/2] $Stage — 강제 종료 전 세션($hangSessionId) 이어받아 1회 재디스패치 (기록: $continuationPath)" WARN
    } else {
        Write-Log "⚠️ HANG [1/2] $Stage — 동일 명령으로 1회 재디스패치" WARN
    }
    return @{ ShouldRetry = $true; ToolCmd = $toolCmd }
}

# outcome → 사람이 읽는 사유 문구 매핑. 모델 체인 전용 사유 문자열 계약은 그대로 유지한다.
function Resolve-OutcomeReason {
    param([string]$Outcome)

    if ($Outcome -eq 'hang') { return 'hang' }
    elseif ($Outcome -eq 'timeout') { return '하드 상한 초과' }
    elseif ($Outcome -eq 'provider_timeout') { return 'provider print timeout (자동 재개 한도 또는 건강도 미충족)' }
    elseif ($Outcome -eq 'quota') { return '잔액·쿼터 부족' }
    elseif ($Outcome -eq 'billing') { return '잔액·쿼터 부족' }
    elseif ($Outcome -eq 'rate_limited') { return '사전 시간당 호출 상한 도달' }
    elseif ($Outcome -eq 'authentication') { return '인증 실패' }
    elseif ($Outcome -eq 'unavailable') { return '모델·프로바이더 사용 불가' }
    elseif ($Outcome -eq 'noop') { return '무산출 조기 실패' }
    elseif ($Outcome -eq 'pollution') { return '프로토콜 오염 감지' }
    return '알 수 없는 실행 실패'
}

# 슬롯 전진 전 이전 자식 프로세스 트리가 죽었음을 확인한다(CFG024 §7-1). 좀비가 남으면 전진을 거부한다.
function Ensure-PreviousSlotCleared {
    param([string]$Stage)

    if (-not $script:ActiveChildProcessId) { return $true }
    try {
        $orphanProc = Get-Process -Id $script:ActiveChildProcessId -ErrorAction SilentlyContinue
        if ($orphanProc -and -not $orphanProc.HasExited) {
            Write-Log "⚠️ [$Stage] 이전 슬롯 프로세스(PID $($script:ActiveChildProcessId)) 정리 및 종료 확인" INFO
            Stop-ProcessTree -ProcessId $script:ActiveChildProcessId
            Start-Sleep -Milliseconds 500
            $checkProc = Get-Process -Id $script:ActiveChildProcessId -ErrorAction SilentlyContinue
            if ($checkProc -and -not $checkProc.HasExited) {
                Write-Log "❌ [$Stage] 프로세스 트리(PID $($script:ActiveChildProcessId)) 종료 확인 실패 — 좀비 방지를 위해 전진하지 않고 중단" ERROR
                return $false
            }
        }
    } catch { }
    $script:ActiveChildProcessId = $null
    return $true
}

# 단계 전체 실패 종결 — 표 형태로 outcome별 사유·정리·로그 꼬리를 매핑해 일관된 종결을 보장한다.
# CFG007: "모델 체인 전부 소진, 중단" 문구와 시도별 사유 요약은 하네스가 문자열 계약으로 검증한다.
function Complete-StageFailure {
    param([string]$Stage, $Cycle, [string]$Outcome, $AttemptFailures, $Before, [string]$Model, [string]$LogRel, $qaDispatchedAt)

    $attemptSummary = if ($AttemptFailures.Count -gt 0) { " (시도별 사유: $($AttemptFailures -join '; '))" } else { '' }
    $failureOutcomes = @{
        hang = @{ Reason = 'hang'; KilledContext = '강제 종료'; ShowLogTail = $false }
        timeout = @{ Reason = '하드 상한 초과'; KilledContext = '하드 상한 초과로 강제 종료'; ShowLogTail = $false }
        provider_timeout = @{ Reason = 'provider print timeout'; KilledContext = $null; ShowLogTail = $true }
        quota = @{ Reason = '잔액·쿼터 부족'; KilledContext = $null; ShowLogTail = $true }
        billing = @{ Reason = '잔액·쿼터 부족'; KilledContext = $null; ShowLogTail = $true }
        authentication = @{ Reason = '인증 실패'; KilledContext = $null; ShowLogTail = $true }
        unavailable = @{ Reason = '모델·프로바이더 사용 불가'; KilledContext = $null; ShowLogTail = $false }
        noop = @{ Reason = '무산출 조기 실패'; KilledContext = $null; ShowLogTail = $false }
        pollution = @{ Reason = 'impl 폴루션 감지'; KilledContext = $null; ShowLogTail = $true }
    }
    if (-not $failureOutcomes.ContainsKey($Outcome)) { return $null }
    $failure = $failureOutcomes[$Outcome]
    $failureMessage = "$($failure.Reason) — 모델 체인 전부 소진, 중단"
    if ($Outcome -in @('quota', 'billing')) { $failureMessage += '. 프로바이더 결제 상태를 확인하세요.' }
    Write-Log "❌ [$Stage] $failureMessage$attemptSummary" ERROR
    $failureReason = "$($failure.Reason) — 모델 체인 전부 소진$attemptSummary"
    if ($failure.KilledContext) {
        Write-KilledLeftover -Before $Before -Stage $Stage -Context $failure.KilledContext
    }
    if ($failure.ShowLogTail) {
        $logAbs = Resolve-RepoPath $LogRel
        if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
    }
    Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $failureReason -Model $Model
    return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $qaDispatchedAt }
}

# 종료 코드 판정 — exit를 읽지 못했거나 0이 아니면 실패 종결, 0이면 계속(성공 후보).
function Complete-StageExitFailure {
    param([string]$Stage, $Cycle, $Exit, [string]$LogRel, [string]$Model, $qaDispatchedAt)

    $exitLabel = if ($null -eq $Exit) { '<unknown>' } else { $Exit }
    Write-Log "프로세스 종료 (Exit Code: $exitLabel)" INFO
    if ($null -eq $Exit) {
        Write-Log "⚠️ [$Stage] 종료 코드를 읽지 못함 — 검증 게이트 결과로 판정" WARN
        return $null
    }
    if ($Exit -eq 0) { return $null }
    Write-Log "⚠️ [$Stage] 실패 (Exit $Exit) — 로그 끝부분:" WARN
    $failureReason = "종료 코드 $Exit"
    $logAbs = Resolve-RepoPath $LogRel
    if (Test-Path $logAbs) { Get-Content $logAbs -Tail 15 | ForEach-Object { Write-Host "    $_" } }
    Write-StageState -Stage $Stage -Cycle $Cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($LogRel) -Reason $failureReason -Model $Model
    return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $qaDispatchedAt }
}

# 작업트리 변경 유무 경고 — 차단하지 않는다(CFG-BL-014: 지문 실패는 '동일'이 아닌 '판정 불가'다).
function Warn-UnchangedTree {
    param([string]$Stage, $Before)

    $after = Get-TreeState
    if ($null -eq $Before -or $null -eq $after) { return }
    if (-not $Before.FingerprintOk -or -not $after.FingerprintOk) {
        Write-Log "[$Stage] 작업트리 변경 여부 판정 불가 (지문 계산 실패) — 무변경 경고를 생략합니다" WARN
    } elseif ($Before.Head -eq $after.Head -and $Before.Dirty -eq $after.Dirty -and
              $Before.Fingerprint -eq $after.Fingerprint) {
        Write-Log "⚠️ [$Stage] 작업트리 변경 없음 (HEAD·미커밋 파일 모두 동일) — 이 단계가 실제로 무엇을 했는지 다음 리뷰 단계에서 확인할 것" WARN
    }
}

# 한 단계 디스패치 + hang 감지 + 판정. 성공(종료 코드 정상 + verify 통과) 시 $true.
# ModelFallback이 있는 단계(impl)는 모델을 바꿔가며 순서대로 시도한다 — 같은 모델을 두 번 부르지 않는다.
# 한 단계 디스패치 + hang 감지 + 판정. 성공(종료 코드 정상 + verify 통과) 시 $true.
# ModelFallback이 있는 단계(impl)는 모델을 바꿔가며 순서대로 시도한다 — 같은 모델을 두 번 부르지 않는다.
# 한 단계 디스패치 + hang 감지 + 판정. 성공(종료 코드 정상 + verify 통과) 시 $true.
# ModelFallback이 있는 단계(impl)는 모델을 바꿔가며 순서대로 시도한다 — 같은 모델을 두 번 부르지 않는다.
function Dispatch-Stage {
    param([string]$Stage, [string]$PromptOverride)
    $config = $StageConfig[$Stage]
    $logRel = $config.LogFile

    # 컨텍스트 측정은 순수 관측이다 — 여기서 난 예외로 파이프라인이 멈춰서는 안 된다.
    try { Measure-ContextBytes -Stage $Stage } catch { Write-Log "[context-size] 측정 실패(무시하고 진행): $($_.Exception.Message)" WARN }

    # CFG025: 헤드리스 antigravity는 모든 run_command를 승인 대기로 거부한다. QA는 이미 직접 수정
    # 권한을 가진 신뢰 단계이므로 사용자 승인(2026-08-19)에 따라 항상 --dangerously-skip-permissions를 부여한다.
    if ($Stage -eq 'qa') { $BypassToolPermissions = $true }
    # CFG024: 디스패치 전 원장/차단 마커 검사 — 상한 도달 시 모델을 띄우기 전에 즉시 거부한다.
    $allowed = Test-StageDispatchAllowed -Stage $Stage
    if (-not $allowed.Allowed) {
        $failureReason = "디스패치 거부: $($allowed.Reason)"
        Write-Log "❌ [$Stage] $failureReason" ERROR
        return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $null }
    }

    $models = Resolve-ModelChain -Config $config -Stage $Stage
    if ($models.Count -eq 0) {
        $failureReason = '모델 체인이 비어 있음 — 단계 구성 오류'
        Write-Log "❌ [$Stage] $failureReason" ERROR
        return @{ Success = $false; FailureReason = $failureReason; QaDispatchedAt = $null }
    }

    if ($DryRun) {
        return (Show-StageDryRun -Stage $Stage -Config $config -LogRel $logRel -PromptOverride $PromptOverride -Model $models[0] -BypassToolPermissions $BypassToolPermissions)
    }
    $cycle = Initialize-StageDispatch -Stage $Stage -Config $config -LogRel $logRel
    $qaDispatchedAt = Clear-QaArtifacts -Stage $Stage -Config $config
    Invoke-SessionHealthCheck -Stage $Stage
    $preflight = Invoke-StagePreflightGate -Stage $Stage -config $config -Cycle $cycle -LogRel $logRel -qaDispatchedAt $qaDispatchedAt
    if ($preflight.Abort) {
        return @{ Success = $false; FailureReason = $preflight.Reason; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
    }

    # CFG024: 구현(②) 단계 전 스냅숏 확보 (프로토콜 오염 감지용)
    $packetsBefore = if ($Stage -eq 'impl') { Get-PacketFileSnapshot } else { @() }
    $routerBefore = if ($Stage -eq 'impl') { Get-RouterTableSnapshot } else { @{} }
    $before = Get-TreeState
    $logicalStartedAt = Get-Date
    $logicalHardLimit = if ($config.HardTimeoutMinutes) { $config.HardTimeoutMinutes } else { $HardTimeoutMinutes }
    $logicalAbsoluteDeadline = $logicalStartedAt.AddMinutes($logicalHardLimit * 3)
    $continuationCount = 0
    $exit = $null; $outcome = $null; $attemptFailures = @()
    $modelIndex = 0; $attemptNumber = 0; $lastDeterministicSig = $null; $consecutiveDeterministicCount = 0

    while ($modelIndex -lt $models.Count) {
        $model = $models[$modelIndex]
        $slot = Resolve-SlotAdapter -config $config -Stage $Stage -ModelIndex $modelIndex -Model $model -RepoRoot $RepoRoot
        if ($slot.Next) {
            $attemptFailures += $slot.Failure
            $modelIndex++
            continue
        }
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

            # CFG024: 정상 종료 직전 프로토콜 오염 감지
            if ($outcome -eq 'ok') {
                $pollutionResult = Test-ProtocolPollution -Stage $Stage -PacketsBefore $packetsBefore -RouterBefore $routerBefore
                if ($pollutionResult.Polluted) {
                    $outcome = 'pollution'
                    Write-Log "❌ [$Stage] 프로토콜 오염 감지: $($pollutionResult.Reason) → 실패 처리" ERROR
                }
            }
            if ($outcome -eq 'approval_required') {
                return (Complete-StageApprovalRequired -Stage $Stage -config $config -Cycle $cycle -AttemptNumber $attemptNumber -Model $model -AttemptLog $attemptLog -LogRel $logRel -qaDispatchedAt $qaDispatchedAt -Evidence $attemptResult.ApprovalEvidence)
            }
            if ($outcome -eq 'provider_timeout') {
                $resume = Resume-ProviderTimeout -Stage $Stage -config $config -Cycle $cycle -Attempt $attemptResult -AttemptNumber $attemptNumber -Model $model -AttemptLog $attemptLog -ContinuationCount $continuationCount -LogicalHardLimit $logicalHardLimit -LogicalAbsoluteDeadline $logicalAbsoluteDeadline
                if ($resume.Continue) { $continuationCount = $resume.ContinuationCount; $toolCmd = $resume.ToolCmd; continue }
            }
            $fClass = Get-FailureClass -Outcome $outcome
            if ($outcome -eq 'hang' -and $config.Retry -and $attempt -eq 1 -and $fClass -ne 'deterministic') {
                $retry = Prepare-HangRetry -Stage $Stage -config $config -Cycle $cycle -Attempt $attemptResult -AttemptNumber $attemptNumber -Model $model -AttemptLog $attemptLog -LogicalHardLimit $logicalHardLimit -Before $before
                if ($retry.ShouldRetry) {
                    $attempt = 2
                    if ($retry.ToolCmd) { $toolCmd = $retry.ToolCmd }
                    Write-Log "⚠️ 재시도는 위 상태를 정리하지 않고 그대로 이어서 실행합니다." WARN
                    continue
                }
            }
            break
        }
        if ($outcome -eq 'ok') { break }
        $reason = Resolve-OutcomeReason -Outcome $outcome
        $attemptFailures += "${model}: $reason"
        $fClass = Get-FailureClass -Outcome $outcome
        $sig = Get-FailureSignature -FailureClass $fClass -Adapter $config.Adapter -Reason $reason
        $rec = Record-StageAttempt -Stage $Stage -Signature $sig -FailureClass $fClass

        # CFG024 §6-4: 동일 결정적 실패 서명 2회 연속 시 전역 실패 판정(체인 중단). 로컬 상태 3개를
        # 함께 돌려줘야 해서 인라인 유지(CFG040 결정) — 루프 제어를 도우미로 옮기면 분산 위험이 크다.
        if ($fClass -eq 'deterministic' -and $sig -eq $lastDeterministicSig) {
            $consecutiveDeterministicCount++
            if ($consecutiveDeterministicCount -ge 2) {
                Write-Log "⚠️ [$Stage] 동일 결정적 실패 서명($sig) 연속 2회 발생 — 전역 실패로 판정하고 체인 즉시 중단" WARN
                $modelIndex = $models.Count
                continue
            }
        } elseif ($fClass -eq 'deterministic') {
            $lastDeterministicSig = $sig
            $consecutiveDeterministicCount = 1
        }

        # provider timeout / pollution / unknown 은 모델 폴백 없이 현재 cycle 종료
        if ($outcome -in @('provider_timeout', 'unknown', 'pollution')) { $modelIndex = $models.Count; continue }
        $modelIndex++
        if ($modelIndex -lt $models.Count) {
            if (-not (Ensure-PreviousSlotCleared -Stage $Stage)) { $modelIndex = $models.Count; continue }
            Write-Log "⚠️ [$Stage] $model 에서 $reason — 다음 모델로 전환: $($models[$modelIndex])" WARN
            Write-KilledLeftover -Before $before -Stage $Stage -Context "$reason — 모델 전환"
        }
    }

    $failure = Complete-StageFailure -Stage $Stage -Cycle $cycle -Outcome $outcome -AttemptFailures $attemptFailures -Before $before -Model $model -LogRel $logRel -qaDispatchedAt $qaDispatchedAt
    if ($null -ne $failure) { return $failure }
    $exitFailure = Complete-StageExitFailure -Stage $Stage -Cycle $cycle -Exit $exit -LogRel $logRel -Model $model -qaDispatchedAt $qaDispatchedAt
    if ($null -ne $exitFailure) { return $exitFailure }

    $verifyResult = Invoke-VerifyGate -Stage $Stage
    if (-not $verifyResult.Success) {
        # CFG042 완료 정리 경계 ①: Integration이 검증 게이트를 통과하지 못하면 파이프라인 완료 정리
        # (⑤ 체크·router DONE·아카이브 이동·완료 커밋 메시지)를 금지한다. 패킷은 미완료 상태로 남아
        # 오케스트레이터가 실패를 전제로 재진행해야 한다 — 이 경계 이전에 완료를 주장하는 정리는 없어야 한다.
        if ($Stage -eq 'integration') {
            Write-Log '⛔ [integration] 검증 실패 — 완료 정리 금지 (⑤ 체크·router DONE·아카이브·완료 커밋 불가, 패킷 미완료 유지)' ERROR
        }
        Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'failed' -ProcessId $PID -EvidencePaths @($logRel) -Reason $verifyResult.FailureReason -Model $model
        return @{ Success = $false; FailureReason = $verifyResult.FailureReason; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
    }

    # CFG017: 이전 승인 대기 상태가 fresh cycle 성공 시 resolved로 해소된다 (qa는 verdict 통과 후 별도 해소).
    if ($Stage -ne 'qa') { Resolve-ApprovalRecords -Stage $Stage -ResolvingCycle $cycle.Id }
    Warn-UnchangedTree -Stage $Stage -Before $before

    Write-Log "✅ [$Stage] 성공 + 검증 통과" SUCCESS
    # CFG042 완료 정리 경계 ②: Integration이 검증 게이트를 통과한 이 지점에 이르러서야 완료 정리
    # (⑤ 체크·router DONE·아카이브 이동·완료 커밋·push)가 허용된다. 이 경계 앞에서는 할 수 없다.
    if ($Stage -eq 'integration') {
        Write-Log '✅ [integration] 검증 성공 — 완료 정리 허용 (⑤ 체크·router DONE·아카이브·완료 커밋 가능)' INFO
    }
    Write-StageState -Stage $Stage -Cycle $cycle.Id -State 'completed' -ProcessId $PID -EvidencePaths @($logRel) -Reason 'stage succeeded and verify passed' -Model $model
    return @{ Success = $true; FailureReason = $null; QaDispatchedAt = $qaDispatchedAt; CycleId = $cycle.Id }
}
#endregion 디스패치 본체
#region 관측·집계·감독·정리

function Read-ProviderHealth {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ schemaVersion = 1; providers = [pscustomobject]@{}; callRate = [pscustomobject]@{} } }
    try {
        $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($state.schemaVersion -ne 1 -or $null -eq $state.providers) { throw 'invalid schema' }
        # callRate는 구 상태 파일(rate-limit 도입 이전)에는 없을 수 있다 — 없으면 빈 객체로 채워
        # 하위호환을 유지한다(opencode 시간당 호출 상한).
        if ($null -eq $state.callRate) { $state | Add-Member -NotePropertyName callRate -NotePropertyValue ([pscustomobject]@{}) -Force }
        return $state
    } catch {
        Write-Log "provider health state corrupt; ignoring it until the next classified result: $($_.Exception.Message)" WARN
        return [pscustomobject]@{ schemaVersion = 1; providers = [pscustomobject]@{}; callRate = [pscustomobject]@{} }
    }
}

function Write-ProviderHealth {
    param([string]$Path, [object]$Value)
    Write-AtomicJson -Path $Path -Value $Value -Depth 5
}

function Invoke-WithProviderHealthLock {
    param([scriptblock]$Action)
    $mutex = $null
    $locked = $false
    try {
        $mutex = New-Object System.Threading.Mutex($false, 'ai-agents-harness-provider-health-v1')
        $locked = $mutex.WaitOne(10000)
        if (-not $locked) { throw 'provider health state lock timeout' }
        return (& $Action)
    } finally {
        if ($locked) { $mutex.ReleaseMutex() }
        if ($mutex) { $mutex.Dispose() }
    }
}

function Update-ProviderHealth {
    param([string]$Model, [string]$Outcome, [string]$AttemptLog)
    if (-not $script:ProviderHealthPath -or $Model -notmatch '^([^/]+)/') { return }
    Invoke-WithProviderHealthLock -Action {
        $provider = $Matches[1]
        $state = Read-ProviderHealth -Path $script:ProviderHealthPath
        if ($null -eq $state.providers) { $state | Add-Member -NotePropertyName providers -NotePropertyValue ([pscustomobject]@{}) -Force }
        if ($Outcome -eq 'ok') {
            $modelKey = "model:$Model"
            $state.providers.psobject.Properties.Remove($modelKey)
            $principal = if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$Model) { [string]$script:ProfileConfig.modelCatalog.$Model.principal } else { '' }
            if ($principal) {
                $principalKey = "principal:$principal"
                $principalModels = @($state.providers.psobject.Properties | Where-Object { $_.Name -like "model:*" -and [string]$_.Value.principal -eq $principal })
                if ($principalModels.Count -eq 0) { $state.providers.psobject.Properties.Remove($principalKey) }
            }
            Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
            return
        }
        if ($Outcome -notin @('quota', 'billing', 'unavailable')) { return }
        $modelKey = "model:$Model"
        $prior = $state.providers.$modelKey
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
        $state.providers | Add-Member -NotePropertyName $modelKey -NotePropertyValue $entry -Force
        $principal = if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$Model) { [string]$script:ProfileConfig.modelCatalog.$Model.principal } else { '' }
        if ($principal) {
            $principalKey = "principal:$principal"
            $principalModels = @($state.providers.psobject.Properties | Where-Object { $_.Name -like "model:*" -and [string]($state.providers.($_.Name)).reason -in @('quota', 'billing', 'unavailable') })
            if ($principalModels.Count -ge 2) {
                $longestHours = $hours
                foreach ($pm in $principalModels) {
                    $pmEntry = $state.providers.($pm.Name)
                    if ($pmEntry.nextProbeAt) {
                        try {
                            $pmProbe = ([datetime]$pmEntry.nextProbeAt).ToUniversalTime()
                            $diff = ($pmProbe - [datetime]::UtcNow).TotalHours
                            if ($diff -gt $longestHours) { $longestHours = [math]::Ceiling($diff) }
                        } catch { }
                    }
                }
                $principalEntry = [pscustomobject]@{ reason = $Outcome; consecutiveFailures = $count; observedAt = [datetime]::UtcNow.ToString('o'); nextProbeAt = [datetime]::UtcNow.AddHours($longestHours).ToString('o') }
                $state.providers | Add-Member -NotePropertyName $principalKey -NotePropertyValue $principalEntry -Force
            }
        }
        Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
    }
}

function Get-CallRateCount {
    param([object]$State, [string]$Principal, [int]$WindowMinutes = 60)
    if ($null -eq $State.callRate) { return 0 }
    $entry = $State.callRate."principal:$Principal"
    if (-not $entry) { return 0 }
    $cutoff = [datetime]::UtcNow.AddMinutes(-$WindowMinutes)
    $count = 0
    foreach ($ts in @($entry)) {
        [datetime]$parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$ts, [ref]$parsed) -and $parsed.ToUniversalTime() -gt $cutoff) { $count++ }
    }
    return $count
}

function Update-CallRate {
    param([string]$Model)
    if (-not $script:ProviderHealthPath -or $Model -notmatch '^([^/]+)/') { return $true }
    $principal = if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$Model) { [string]$script:ProfileConfig.modelCatalog.$Model.principal } else { '' }
    # rateLimit 설정이 없는 principal은 기록하지 않는다 — 상한 검사에 쓰이지 않을 타임스탬프로
    # 공유 상태 파일(provider-health.json)이 모든 어댑터 호출마다 무한정 커지는 것을 막기 위함이다.
    if (-not $principal -or -not ($script:ProfileConfig.rateLimit -and $script:ProfileConfig.rateLimit.$principal)) { return $true }
    return (Invoke-WithProviderHealthLock -Action {
        $state = Read-ProviderHealth -Path $script:ProviderHealthPath
        $key = "principal:$principal"
        $cutoff = [datetime]::UtcNow.AddMinutes(-60)
        $existing = @($state.callRate.$key) | Where-Object {
            [datetime]$parsed = [datetime]::MinValue
            [datetime]::TryParse([string]$_, [ref]$parsed) -and $parsed.ToUniversalTime() -gt $cutoff
        }
        $rateCap = [int]$script:ProfileConfig.rateLimit.$principal.maxCallsPerHour
        if ($existing.Count -ge $rateCap) {
            Write-Log "[impl] execution skip: $Model (principal $principal rate limit: $($existing.Count)/$rateCap calls in last 60m)" INFO
            return $false
        }
        $updated = @($existing) + @([datetime]::UtcNow.ToString('o'))
        $state.callRate | Add-Member -NotePropertyName $key -NotePropertyValue $updated -Force
        Write-ProviderHealth -Path $script:ProviderHealthPath -Value $state
        return $true
    })
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
        runtimeRoleBinding = $script:RuntimeRoleBinding
        logDirectory = $LogDir
    }
    Write-AtomicJson -Path $summaryPath -Value $value -Depth 8
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
        $cycleId = if ($result.CycleId) { [int]$result.CycleId } else { 0 }
        Write-SyntheticQaVerdict -Stage $Stage -Result $result -CycleNumber $cycleId
        Ensure-QaLedger -Stage $Stage -Result $result
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

# ── CFG043: 수동 완료·안전 재개 ─────────────────────────────────────────────
# 실행 중('running'/'starting') lease가 아직 만료되지 않았거나 살아 있는 락이 있는지 판정한다.
# 자동 재개(-Chain)가 이들을 "건드리지 않고" 멈추기 위한 가드다. stale(만료) lease나 종결
# lease는 재개를 막지 않는다 — 그게 재개가 진행해야 할 대상이기 때문이다.
function Test-LiveStageActivity {
    param([string]$TargetTaskId = $TaskId)
    $target = if ([string]::IsNullOrWhiteSpace($TargetTaskId)) { $TaskId } else { $TargetTaskId }
    $live = @()
    foreach ($s in @('impl','qa','integration')) {
        $lock = Read-DispatchLock $s
        if ($lock -and $lock.Alive) { $live += "[$s] 살아있는 락 PID $($lock.ProcId)" }
        $leasePath = Resolve-RepoPath "$LogDir/$target-stage-state.json"
        if (Test-Path -LiteralPath $leasePath) {
            try {
                $lease = Get-Content -LiteralPath $leasePath -Raw -Encoding UTF8 | ConvertFrom-Json
            } catch { $lease = $null }
            if ($lease -and [string]$lease.stage -eq $s -and [string]$lease.state -match '^(starting|running)$') {
                try {
                    $heartbeat = ([datetime]$lease.heartbeatAt).ToUniversalTime()
                    $fresh = (([datetime]::UtcNow) - $heartbeat).TotalSeconds -lt 600
                } catch { $fresh = $false }
                if ($fresh) { $live += "[$s] 살아있는 running lease cycle $($lease.cycle) PID $($lease.pid)" }
            }
        }
    }
    if ($live.Count -eq 0) { return $null }
    return ($live -join ', ')
}

# CFG043: 사용자 권한 수동 완료/중단 — 실행 대신 단계 lease를 terminal 상태로 원자적으로 종결한다.
# 실행 프로세스·락·승인 대기를 건드리지 않고 task/stage/cycle/evidence/reason을 보존한다.
# 완료는 'completed', 중단은 'failed'로 기록한다(보존: task/stage/cycle/evidence/reason).
function Invoke-ManualStageTermination {
    param([string]$Stage, [switch]$Complete, [string]$ReasonText)
    if (-not $Stage -or @('impl','qa','integration') -notcontains $Stage) {
        Write-Log '오류: 수동 완료/중단은 -Stage impl|qa|integration 과 함께 사용하세요.' ERROR
        return 1
    }
    # 살아 있는 실행이 있으면 종결하지 않는다 — 사용자 개입이라도 실제 진행 중 lease를 덮어쓰지 않는다.
    $live = Test-LiveStageActivity
    if ($live) {
        Write-Log "⛔ [수동종결] 살아 있는 실행이 있어 lease를 종결하지 않습니다: $live" ERROR
        Write-Log '수동 완료/중단은 실행이 종료된 뒤(또는 만료된 lease)에만 사용 가능합니다. 실행이 끝나기를 기다리거나 해당 세션을 정리하세요.' ERROR
        return 1
    }
    $statePath = Resolve-RepoPath "$LogDir/$TaskId-stage-state.json"
    $cycle = 1
    $evidence = @()
    try {
        if (Test-Path -LiteralPath $statePath) {
            $prev = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ([string]$prev.stage -eq $Stage) {
                $c = 0
                if ([int]::TryParse([string]$prev.cycle, [ref]$c)) { $cycle = $c }
                foreach ($e in @($prev.evidencePaths)) { if (-not [string]::IsNullOrWhiteSpace([string]$e)) { $evidence += [string]$e } }
            }
        }
    } catch { }
    $target = if ($Complete) { 'completed' } else { 'failed' }
    $detail = if ([string]::IsNullOrWhiteSpace($ReasonText)) { '' } else { " — $ReasonText" }
    $reason = if ($Complete) { "수동 완료 — 사용자 권한으로 단계 실행 종결$detail" } else { "수동 중단 — 사용자 권한으로 실행 중단$detail" }
    Write-StageState -Stage $Stage -Cycle $cycle -State $target -ProcessId $PID -EvidencePaths $evidence -Reason $reason -Model $null
    $mark = if ($Complete) { '✅' } else { '❌' }
    Write-Log "$mark [$Stage] 수동 $(if ($Complete) { '완료' } else { '중단' }) — terminal lease '$target' 기록 (cycle $cycle, reason: $reason)" SUCCESS
    return 0
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

#endregion 관측·집계·감독·정리
# ── 메인 ─────────────────────────────────────────────────────────────────────
Validate-TaskId -Id $TaskId

if ($ResetStageLedger) {
    if (-not $Stage) { Write-Log '오류: -ResetStageLedger는 -Stage와 함께 사용하세요 (예: -Stage qa).' ERROR; exit 1 }
    if ([string]::IsNullOrWhiteSpace($ResetReason)) {
        Write-Log '오류: -ResetStageLedger는 -ResetReason으로 초기화 사유를 반드시 남기세요 (예: "구조적 원인 수정 완료 — BypassToolPermissions 적용").' ERROR
        exit 1
    }
    Reset-StageLedger -Stage $Stage -Reason $ResetReason
    exit 0
}

# ── CFG043: 수동 완료/중단 (실행 대신 lease 종결) ──
if ($ManualComplete -and $ManualAbort) {
    Write-Log '-ManualComplete와 -ManualAbort는 동시에 사용할 수 없습니다.' ERROR; exit 1
}
if ($ManualComplete) { exit (Invoke-ManualStageTermination -Stage $Stage -Complete -ReasonText $Reason) }
if ($ManualAbort) { exit (Invoke-ManualStageTermination -Stage $Stage -Complete:$false -ReasonText $Reason) }

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

# CFG041: 패킷 해석 직후·모델 프로필 로드 전에 조건부 기획 챌린지 리뷰 게이트를 검사한다.
# 이 위치는 -Chain과 -Stage impl 단일 경로를 모두 덮는다. 미해소(requested)·결손·잘못된 Decision은
# 모델 호출 전에 fail-closed로 차단하고, 레거시·not-required·completed는 그대로 통과시킨다.
if ($checkPipelinePacket) {
    try {
        Assert-PlanningChallengeReviewReady -PacketPath $checkPipelinePacket | Out-Null
    } catch {
        Write-Log $_.Exception.Message ERROR
        exit 1
    }
}

. $ProfileModule
$script:ProfileConfig = Read-ModelProfileConfig -CentralPath $ProfileConfigPath -LocalPath (Join-Path $RepoRoot 'model-profiles.local.json')
$configuredPlanning = Resolve-RoleProfile -Role planning -Config $script:ProfileConfig
$planningProfile = $configuredPlanning.Name
$planningAdapter = $configuredPlanning.Adapter
$script:RuntimeRoleBinding = [pscustomobject]@{
    source = 'config'
    legacy = $false
    planningProfile = $planningProfile
    planningAdapter = $planningAdapter
}
$packetQaProfile = $null
$packetQaAdapter = $null
$packetIntegrationProfile = $null
$packetIntegrationAdapter = $null
$packetImplRoute = $null
$packetRoleContentionAck = $null

if ($checkPipelinePacket) {
    $runtimeBinding = Get-RuntimeRoleBinding -PacketPath $checkPipelinePacket
    if ($runtimeBinding.Valid) {
        $planningProfile = $runtimeBinding.PlanningProfile
        $planningAdapter = $runtimeBinding.PlanningAdapter
        $packetQaProfile = $runtimeBinding.QaProfile
        $packetQaAdapter = $runtimeBinding.QaAdapter
        $packetIntegrationProfile = $runtimeBinding.IntegrationProfile
        $packetIntegrationAdapter = $runtimeBinding.IntegrationAdapter
        $packetImplRoute = $runtimeBinding.ImplementationRoute
        $packetRoleContentionAck = $runtimeBinding.RoleContentionAck

        $script:RuntimeRoleBinding = [pscustomobject]@{
            source = 'packet'
            legacy = $false
            planningProfile = $planningProfile
            planningAdapter = $planningAdapter
            qaProfile = $packetQaProfile
            qaAdapter = $packetQaAdapter
            integrationProfile = $packetIntegrationProfile
            integrationAdapter = $packetIntegrationAdapter
            implementationRoute = $packetImplRoute
            roleContentionAck = $packetRoleContentionAck
        }
    } elseif ($runtimeBinding.Error) {
        throw $runtimeBinding.Error
    } else {
        $script:RuntimeRoleBinding = [pscustomobject]@{
            source = 'config'
            legacy = $true
            planningProfile = $planningProfile
            planningAdapter = $planningAdapter
        }
        Write-Log 'Runtime Role Binding missing; using configured planning profile for legacy packet.' WARN
    }
}
$script:PipelineRouting = Resolve-PipelineRouting -Config $script:ProfileConfig -PlanningProfile $planningProfile -PlanningAdapter $planningAdapter -QaProfile $packetQaProfile -QaAdapter $packetQaAdapter -IntegrationProfile $packetIntegrationProfile -IntegrationAdapter $packetIntegrationAdapter -ImplementationRoute $packetImplRoute
$StageConfig.impl.ModelFallback = @($script:PipelineRouting.ImplementationModels)
$StageConfig.impl.ModelFallback = @(Resolve-ForceFreeModelChain -ModelFallback $StageConfig.impl.ModelFallback -ProfileConfig $script:ProfileConfig -ForceFreeModel $ForceFreeModel)

# 구현(②③) 슬롯의 어댑터를 modelCatalog에서 해석한다. 개발1팀 역할이 opencode에 고정되어 있으면
# 다른 팀이 구현을 대체 수행할 수 없어(지시 6·11) 프로바이더 장애가 곧 파이프라인 정지가 된다.
# adapter/invokeModel이 없는 기존 슬롯은 종전과 동일하게 opencode + 식별자 그대로 동작한다.
$implAdapterMap = @{}
$implModelMap = @{}
foreach ($implSlot in @($StageConfig.impl.ModelFallback)) {
    $implMeta = $null
    if ($script:ProfileConfig.modelCatalog) { $implMeta = $script:ProfileConfig.modelCatalog.$implSlot }
    $implAdapterMap[$implSlot] = if ($implMeta -and $implMeta.adapter) { [string]$implMeta.adapter } else { 'opencode' }
    if ($implMeta -and $implMeta.invokeModel) { $implModelMap[$implSlot] = [string]$implMeta.invokeModel }
}
$StageConfig.impl.AdapterMap = $implAdapterMap
$StageConfig.impl.ModelMap = $implModelMap
$implFirstSlot = @($StageConfig.impl.ModelFallback)[0]
if ($implFirstSlot -and $implAdapterMap.ContainsKey($implFirstSlot)) { $StageConfig.impl.Adapter = $implAdapterMap[$implFirstSlot] }
if ($StageConfig.impl.Adapter -eq 'antigravity') { $StageConfig.impl.ProjectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot }

# CFG024 §Done When 4: QA·Integration에 실제로 동작하는 폴백 체인을 배선한다.
# ModelChain/AdapterChain이 Resolve-ModelChain에서 소비되며, Dispatch-Stage 루프가 슬롯마다
# AdapterChain을 따라 $config.Adapter를 갱신한다(위 Dispatch-Stage 본문 참조).
$implFamilies = @($script:PipelineRouting.ImplementationModels | ForEach-Object {
    if ($script:ProfileConfig.modelCatalog.$_) { [string]$script:ProfileConfig.modelCatalog.$_.family }
} | Where-Object { $_ -and $_ -ne 'unknown' } | Select-Object -Unique)

$qaChainNames = Resolve-ProfileChain -ProfileName $script:PipelineRouting.QaProfile.Name -Config $script:ProfileConfig
# QA 폴백 후보도 must 불변조건(구현자와 family 겹치면 안 됨)을 통과해야 한다 — 겹치는 후보는 건너뛴다.
$qaSlots = Resolve-StageProfileSlots -ProfileNames $qaChainNames -Config $script:ProfileConfig -ImplementerFamilies $implFamilies -Stage 'qa'
if ($qaSlots.Count -eq 0) {
    $StageConfig.qa.ModelChain = @()
    Write-Log "❌ [qa] 구현자와 family가 겹치지 않는 QA 후보가 없음 — 사람 개입 필요 (구현 family: $($implFamilies -join ', '))" ERROR
} else {
    $StageConfig.qa.ModelChain = @($qaSlots | ForEach-Object { $_.Model })
    $StageConfig.qa.AdapterChain = @($qaSlots | ForEach-Object { $_.Adapter })
    $StageConfig.qa.Adapter = $qaSlots[0].Adapter
    $StageConfig.qa.Model = $qaSlots[0].Model
}
if ($StageConfig.qa.Adapter -eq 'antigravity') { $StageConfig.qa.ProjectId = Resolve-AntigravityProjectId -RepositoryRoot $RepoRoot }

$integrationChainNames = Resolve-ProfileChain -ProfileName $script:PipelineRouting.IntegrationProfile.Name -Config $script:ProfileConfig
$integrationSlots = Resolve-StageProfileSlots -ProfileNames $integrationChainNames -Config $script:ProfileConfig -Stage 'integration'
if ($integrationSlots.Count -eq 0) {
    $StageConfig.integration.ModelChain = @()
    Write-Log "❌ [integration] Integration 후보를 하나도 해석하지 못함 — 사람 개입 필요" ERROR
} else {
    $StageConfig.integration.ModelChain = @($integrationSlots | ForEach-Object { $_.Model })
    $StageConfig.integration.AdapterChain = @($integrationSlots | ForEach-Object { $_.Adapter })
    $StageConfig.integration.Adapter = $integrationSlots[0].Adapter
    $StageConfig.integration.Model = $integrationSlots[0].Model
}
$StageConfig.integration.ReportFile = "$TaskLogPrefix-integration-last.md"
# 상태 저장소는 반드시 `~/.agents/harness` **밖**에 둔다. 그 폴더는 sync-configs.ps1이
# robocopy /MIR로 미러링하는 배포 대상이라, 저장소에 없는 하위 폴더는 Push 한 번에 purge된다.
# 종전 경로(`.agents\harness\state`)는 그 안에 있었고, 다음 Push에서 provider health cooldown이
# 통째로 삭제될 상태였다(2026-08-30 발견 · 이관). 여기를 다시 harness 아래로 옮기지 말 것 —
# scripts/verify.ps1의 회귀 검사가 막는다.
$stateRoot = if ($env:USERPROFILE) { Join-Path $env:USERPROFILE '.agents\harness-state' } else { Join-Path ([IO.Path]::GetTempPath()) 'agents-harness-state' }
$script:ProviderHealthPath = Join-Path $stateRoot 'provider-health.json'
# CFG048 Done When 7: 팀 경합 탐지 및 보고 (②구현·④QA·⑤Integration 간 principal 충돌 검사)
$implPrincipal = if ($implFirstSlot -and $script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$implFirstSlot) {
    if ($script:ProfileConfig.modelCatalog.$implFirstSlot.principal) { [string]$script:ProfileConfig.modelCatalog.$implFirstSlot.principal } else { [string]$StageConfig.impl.Adapter }
} else { [string]$StageConfig.impl.Adapter }

$qaPrincipal = if ($script:PipelineRouting.QaProfile) {
    $qaModel = $script:PipelineRouting.QaProfile.Model
    if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$qaModel -and $script:ProfileConfig.modelCatalog.$qaModel.principal) {
        [string]$script:ProfileConfig.modelCatalog.$qaModel.principal
    } else {
        [string]$script:PipelineRouting.QaProfile.Adapter
    }
} else { $null }

$integrationPrincipal = if ($script:PipelineRouting.IntegrationProfile) {
    $intModel = $script:PipelineRouting.IntegrationProfile.Model
    if ($script:ProfileConfig.modelCatalog -and $script:ProfileConfig.modelCatalog.$intModel -and $script:ProfileConfig.modelCatalog.$intModel.principal) {
        [string]$script:ProfileConfig.modelCatalog.$intModel.principal
    } else {
        [string]$script:PipelineRouting.IntegrationProfile.Adapter
    }
} else { $null }

$contentionCheck = Test-PipelineRoleContention -ImplPrincipal $implPrincipal -QaPrincipal $qaPrincipal -IntegrationPrincipal $integrationPrincipal
if ($contentionCheck.Contention) {
    if ([string]::IsNullOrWhiteSpace($packetRoleContentionAck)) {
        Write-Log "⛔ [role-contention] 파이프라인 단계 간 principal 경합 감지: $($contentionCheck.Details)" ERROR
        Write-Log "동일 principal(계정/어댑터)이 복수 단계를 수행하면 쿼터 경합 또는 독립성 훼손이 발생할 수 있습니다. 패킷에 '- Role Contention Ack: <사유>'를 명시하거나 역할을 분리하세요." ERROR
        exit 1
    } else {
        Write-Log "⚠️ [role-contention] 파이프라인 단계 간 principal 경합 ($($contentionCheck.Details)) — Role Contention Ack 확인됨: $packetRoleContentionAck" WARN
    }
}

Write-Log "planner=$planningProfile/$planningAdapter impl-route=$($script:PipelineRouting.ImplementationRoute) impl=$implFirstSlot(adapter=$($StageConfig.impl.Adapter)) qa=$($StageConfig.qa.Adapter)/$($StageConfig.qa.Model) project=$($StageConfig.qa.ProjectId) integration=$($StageConfig.integration.Adapter)/$($StageConfig.integration.Model)" INFO

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
    # CFG043: 안전 재개 가드 — 살아 있는 lease·락이 있으면 자동 연쇄/재개가 그것을 건드리지 않고
    # 중단한다(Done When 3). 완료 재개는 종결된 이전 단계 뒤 첫 미완료 단계부터라야 하므로,
    # 만료(stale) lease는 가드하지 않는다 — 그것이 재개 대상이다.
    $liveActivity = Test-LiveStageActivity
    if ($liveActivity) {
        Write-Log "⛔ 자동 연쇄/재개 중단 — 살아 있는 단계 실행이 있어 재개하지 않습니다: $liveActivity" ERROR
        Write-Log '살아 있는 lease·락·승인 대기를 보존한 채 종료합니다. 실행이 끝난 뒤 다시 재개하세요.' ERROR
        $holdingPipeline = Get-PacketPipelineStatus -PacketPath $checkPipelinePacket
        Write-ChainSummary -State 'blocked' -Stages @() -Warnings @("살아 있는 실행으로 인한 재개 보류 — $liveActivity") -StartedAt (Get-Date) -PipelineBefore $holdingPipeline -PipelineAfter $holdingPipeline -TreeBefore (Get-TreeState) -TreeAfter (Get-TreeState) -QaVerdict @{ verdict = $null; fresh = $false } | Out-Null
        exit 1
    }
    $chainStartedAt = Get-Date
    $chainPipelineBefore = Get-PacketPipelineStatus -PacketPath $checkPipelinePacket
    Set-CompletedStageApprovalsSuperseded -PipelineStatus $chainPipelineBefore -Evidence $checkPipelinePacket | Out-Null
    $chainTreeBefore = Get-TreeState
    $gateTier = Get-PacketGateTier -PacketPath $checkPipelinePacket
    $chainQaVerdict = @{ verdict = if ($gateTier -eq 'light') { 'skipped_light_tier' } else { $null }; fresh = $false }
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
        if ($stage -eq 'integration' -and -not $DryRun -and $gateTier -eq 'light') {
            Write-Log 'ℹ️ 경량 게이트 등급(패킷 선언) — QA verdict 게이트 생략, ⑤ 그대로 진행' INFO
        } elseif ($stage -eq 'integration' -and -not $DryRun -and -not (Test-QaVerdict -QaDispatchedAt $null)) {
            Write-FailureMarker -Stage 'integration' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
            Write-ChainSummary -State 'blocked' -Stages $chainStages -Warnings @('QA verdict 미통과 — ⑤ 진행 중단') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
            exit 1
        }
        # CFG042 QA pass→Integration 자동 연쇄 경계: 여기까지 도달하면 verdict 게이트(경량 등급 또는
        # fresh pass)를 통과했다는 뜻이므로 ⑤ Integration을 자동 기동한다. 완료 정리(⑤ 체크·router DONE·
        # 아카이브 이동·완료 커밋)는 Dispatch-Stage 안에서 Integration 검증 게이트를 통과한 뒤에만 허용된다.
        if ($stage -eq 'integration' -and -not $DryRun) {
            Write-Log '📌 [integration] QA verdict pass — 자동 연쇄 진행. 완료 정리는 검증 통과 후에만 허용' INFO
        }
        $result = Invoke-StageWithLock -Stage $stage -PromptOverride '' -CheckPipelineBefore ($stage -eq 'impl') -CheckPipelinePacket $checkPipelinePacket
        $chainStages += [ordered]@{ stage = $stage; success = [bool]$result.Success; failureReason = $result.FailureReason; verifyPassed = [bool]$result.Success; logPath = $StageConfig[$stage].LogFile }
        if (-not $result.Success) {
            # CFG017: 승인 대기는 'failed'가 아니라 'approval_required'로 연쇄를 중단한다 — 오케스트레이터가
            # 이 상태를 보고 재시도하지 않고 judgment_required로 멈춘다.
            $chainState = if ($result.Outcome -eq 'approval_required') { 'approval_required' } else { 'failed' }
            $chainWarnings = if ($result.Outcome -eq 'approval_required') { @("승인 대기 — 기록: $($result.ApprovalPath)") } else { @($result.FailureReason) }
            if ($stage -eq 'qa') {
                try {
                    $vfPath = Resolve-RepoPath ($StageConfig['qa'].VerdictFile)
                    if (Test-Path -LiteralPath $vfPath) {
                        $vfJson = Get-Content -LiteralPath $vfPath -Raw -Encoding UTF8 | ConvertFrom-Json
                        $chainQaVerdict = @{ verdict = [string]$vfJson.verdict; reason = [string]$vfJson.reason; fresh = $true; synthetic = [bool]$vfJson.synthetic }
                    }
                } catch { }
            }
            Write-ChainSummary -State $chainState -Stages $chainStages -Warnings $chainWarnings -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
            Write-Log "❌ [$stage] 파이프라인 중단 (상태: $chainState, 로그: $($StageConfig[$stage].LogFile))" ERROR
            exit 1
        }
        # QA 자체는 성공했어도 verdict가 ⑤를 막으면 파이프라인은 거기서 멈춘다 —
        # 사용자 눈에는 이것도 "중단"이므로 마커를 남긴다.
        if ($stage -eq 'qa' -and -not $DryRun -and -not (Test-QaVerdict -QaDispatchedAt $result.QaDispatchedAt)) {
            $actualQaVerdict = $null
            try {
                $vfPath = Resolve-RepoPath ($StageConfig['qa'].VerdictFile)
                if (Test-Path -LiteralPath $vfPath) {
                    $vfJson = Get-Content -LiteralPath $vfPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $actualQaVerdict = @{ verdict = [string]$vfJson.verdict; reason = [string]$vfJson.reason; fresh = $true; synthetic = [bool]$vfJson.synthetic }
                }
            } catch { }
            if ($actualQaVerdict) { $chainQaVerdict = $actualQaVerdict }
            Write-FailureMarker -Stage 'qa' -Reason 'QA verdict 미통과 — ⑤ 진행 중단'
            Write-ChainSummary -State 'blocked' -Stages $chainStages -Warnings @('QA verdict 미통과 — ⑤ 진행 중단') -StartedAt $chainStartedAt -PipelineBefore $chainPipelineBefore -PipelineAfter (Get-PacketPipelineStatus $checkPipelinePacket) -TreeBefore $chainTreeBefore -TreeAfter (Get-TreeState) -QaVerdict $chainQaVerdict | Out-Null
            exit 1
        }
        if ($stage -eq 'qa') {
            $actualQaVerdict = $null
            try {
                $vfPath = Resolve-RepoPath ($StageConfig['qa'].VerdictFile)
                if (Test-Path -LiteralPath $vfPath) {
                    $vfJson = Get-Content -LiteralPath $vfPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    $actualQaVerdict = @{ verdict = [string]$vfJson.verdict; fresh = $true; synthetic = [bool]$vfJson.synthetic }
                }
            } catch { }
            $chainQaVerdict = if ($actualQaVerdict) { $actualQaVerdict } else { @{ verdict = 'pass'; fresh = $true } }
        }
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
        } elseif ((Get-PacketGateTier -PacketPath $checkPipelinePacket) -eq 'light') {
            Write-Log 'ℹ️ 경량 게이트 등급(패킷 선언) — QA verdict 게이트 생략, ⑤ 그대로 진행' INFO
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
