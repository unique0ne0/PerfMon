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
    [Parameter(Mandatory=$false)][string]$TaskId,
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
# CFG055 회귀 핫픽스: model-profile.ps1은 여기 top-level에서 한 번 로드해야 한다. Resolve-DispatchPlan
# 내부에서만 dot-source하면 PowerShell 함수 스코프상 그 함수 호출이 끝나는 즉시 사라져,
# 이후 Invoke-DispatchChain -> Dispatch-Stage -> Build-ToolCommand/Test-AntigravityPreflight가
# ConvertTo-BashSingleQuoted/Resolve-AntigravityProjectId를 찾지 못하고 실패한다(실측: CFG056 디스패치).
if (Test-Path -LiteralPath $ProfileModule) {
    . $ProfileModule
}
# CFG075: 책임 경계별 분할 모듈 — harness-lock.ps1(락/Admission/마커), harness-ledger.ps1(상태 원장), harness-verdict.ps1(QA 판정).
# 로드 순서: contracts → io → lock → ledger → verdict → model-profile. lock/ledger/verdict는 메인 파일의 헬퍼(Resolve-RepoPath, Write-Log 등)와 io의 원자적 쓰기에 의존한다.
$LockModule = Join-Path $PSScriptRoot 'harness-lock.ps1'
if (-not (Test-Path -LiteralPath $LockModule)) {
    throw "Required harness lock module not found: $LockModule"
}
. $LockModule
$LedgerModule = Join-Path $PSScriptRoot 'harness-ledger.ps1'
if (-not (Test-Path -LiteralPath $LedgerModule)) {
    throw "Required harness ledger module not found: $LedgerModule"
}
. $LedgerModule
$VerdictModule = Join-Path $PSScriptRoot 'harness-verdict.ps1'
if (-not (Test-Path -LiteralPath $VerdictModule)) {
    throw "Required harness verdict module not found: $VerdictModule"
}
. $VerdictModule
$StageEngineModule = Join-Path $PSScriptRoot 'harness-stage-engine.ps1'
if (-not (Test-Path -LiteralPath $StageEngineModule)) {
    throw "Required harness stage engine module not found: $StageEngineModule"
}
. $StageEngineModule
$ModelChainModule = Join-Path $PSScriptRoot 'harness-model-chain.ps1'
if (-not (Test-Path -LiteralPath $ModelChainModule)) {
    throw "Required harness model chain module not found: $ModelChainModule"
}
. $ModelChainModule
$SessionContinuationModule = Join-Path $PSScriptRoot 'harness-session-continuation.ps1'
if (-not (Test-Path -LiteralPath $SessionContinuationModule)) {
    throw "Required harness session/continuation module not found: $SessionContinuationModule"
}
. $SessionContinuationModule
$DispatchCoreModule = Join-Path $PSScriptRoot 'harness-dispatch-core.ps1'
if (-not (Test-Path -LiteralPath $DispatchCoreModule)) {
    throw "Required harness dispatch core module not found: $DispatchCoreModule"
}
. $DispatchCoreModule

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
        DefaultPrompt = "작업 $TaskId — 개발팀의 1차 구현과 자체 리뷰가 완료되었어. Handoff 확인하고 제로베이스에서 구현 및 코드 품질에 대해 리뷰해. 리뷰 시작 전 패킷의 Done When 항목을 전부 나열하고, 각 항목마다 실제 diff·코드 근거와 diff 밖이라도 이 변경이 영향을 주는 호출부·계약·회귀 테스트를 함께 확인해 개별 충족 여부를 검증해 — 근거 없이 통째로 '완료'로 넘기지 마. Done When 항목 하나가 여러 지점·형제 분기·유사 파일 등 다수 인스턴스를 포괄하면 대표 1건 확인으로 전체를 만족시켰다고 판단하지 말고 그 개수만큼 각각 실제 근거를 남겨. 근거는 패킷의 구현 노트·자체 리뷰 서술을 그대로 인정하지 말고 반드시 현재 작업 트리의 실제 코드·파일을 직접 열어 대조한 결과여야 해 — 서술과 실제 코드가 다를 수 있다는 전제로 검증해. 발견한 결함은 직접 수정한 뒤, 당신이 수정하거나 기록(메모·로그 추가 포함)을 남긴 모든 파일은 git diff로 스스로 재검토해 history.md·backlog.md 같은 누적 기록 파일을 실수로 통째로 덮어쓰거나 삭제하지 않았는지 확인하고, scripts/verify.ps1 게이트를 통과시키고 Pipeline Status ④를 갱신해. 마지막으로 QA 판정을 .agents/briefs/logs/$TaskId-qa-verdict.json 파일에 JSON으로 남겨 — schemaVersion은 3으로, stage는 `"qa`"로, cycle은 현재 사이클 번호로, findings 배열에는 당신이 발견한 결함을 각각 {id, severity, confidenceTier, doneWhenItem, description, fixedInQa, evidence} 형태로 개별 기록해(fixedInQa:true는 당신이 직접 수정했음을 뜻하며, 수정했더라도 findings에서 빠지면 안 된다). confidenceTier는 'RESOLVED'(코드 정적 대조 확정), 'OBSERVED'(테스트/실행 관측), 'CANDIDATE'(미실행 잠재 추론) 중 하나여야 하며, CANDIDATE 단독 지적은 verdict를 blocked로 만들지 않는다(RESOLVED/OBSERVED만 확정 결함으로 blocked 사유가 됨). doneWhen 배열에 각 항목을 {item, satisfied, evidence} 형태로 개별 기록하고, 하나라도 satisfied가 false면 verdict는 반드시 blocked여야 해. 빈 findings 배열은 '결함을 하나도 발견하지 못했다'는 적극적 진술이며, 결함을 고쳐 놓고 findings를 비워 두는 것은 기록 위반으로 간주된다. ⑤ 진행 가능하면 verdict를 pass, 차단성 이슈로 ⑤ 진행 불가면 verdict를 blocked(사유는 reason)로 기록해"
        LogFile = "$TaskLogPrefix-qa.log"
        ReportFile = "$TaskLogPrefix-qa-last.md"
        VerdictFile = "$TaskLogPrefix-qa-verdict.json"
        KillOnHang = $true
        Retry = $true
        # QA는 오탐 hang 후 재시도한다 — 임계는 stage-thresholds.json이 정본이다(impl와 동일하게 보수적).
    }
    'integration' = @{
        Command = ''
        DefaultPrompt = "작업 $TaskId — 현재 프로세스가 하네스가 시작한 유일한 Integration 본체다. 별도 Integration을 디스패치하거나 PID·락을 감시하거나 프로세스를 종료하지 마. 개발1팀의 구현과 QA팀의 리뷰가 완료되었어. 제로베이스에서 문제없는지 리뷰해. scripts/verify.ps1 게이트 통과 + 실동작 E2E 검증까지 마치고, 문제없으면 Integration을 로컬 완료 처리하고 Pipeline Status ⑤와 history.md를 갱신한 뒤, 관련 변경을 커밋하고 원격에 push까지 자동으로 수행해(추가 승인 대기 없음; 정본 하네스를 수정했으면 sync-configs.ps1 -Action Push -CommitTargets -PushTargets 까지 수행해야 배포와 하류 사본 커밋이 완료된다). 패킷 Amendment에 자동 commit/push를 명시적으로 금지하는 지시가 있으면 그 지시를 따르고 사유를 남겨. 만약 QA가 pass를 줬지만 이 Integration 단계에서 새 결함(탈출 결함)을 발견하면, .agents/briefs/logs/$TaskId-integration-findings.json 파일에 schemaVersion 3으로 {taskId, stage:'integration', findings:[{id, severity, confidenceTier, doneWhenItem, description, fixedInQa, evidence}]} 형태로 기록해. confidenceTier는 'RESOLVED'(코드 정적 대조 확정), 'OBSERVED'(테스트/실행 관측), 'CANDIDATE'(미실행 잠재 추론) 중 하나여야 하며, CANDIDATE 단독 지적은 verdict를 blocked로 만들지 않는다(RESOLVED/OBSERVED만 확정 결함으로 blocked 사유가 됨). 빈 findings 배열은 '탈출 결함을 발견하지 못했다'는 적극적 진술이며, 결함을 고쳐 놓고 findings를 비워 두는 것은 기록 위반으로 간주된다."
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
    param([string]$Stage, [int]$Cycle, [string]$State, [int]$ProcessId, [string[]]$EvidencePaths, [string]$Reason, [string]$Model, [switch]$ManualIntervention)
    $path = Resolve-RepoPath "$LogDir/$TaskId-stage-state.json"
    Write-HarnessStageState -Path $path -TaskId $TaskId -Stage $Stage -Cycle $Cycle -State $State -ProcessId $ProcessId -EvidencePaths $EvidencePaths -Reason $Reason -Model $Model -Owner 'dispatcher' -ManualIntervention:$ManualIntervention
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
            if (-not [string]::IsNullOrWhiteSpace([string]$warning)) {
                Write-Log "[$Stage] $warning" WARN
                Write-Warning "[$Stage] $warning"
            }
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



# 루트 bash와 그 자식들의 누적 CPU 시간을 합산한다. 실제 에이전트/도구는 bash의
# 자식으로 실행되므로 루트 PID만 보면 조용히 계산 중인 작업을 hang으로 오판한다.


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



function Get-ChangedFileSnapshot {
    $snapshot = @{ Head = $null; Files = @{} }
    try {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $snapshot.Head = (git -C (Resolve-RepoPath '.') rev-parse HEAD 2>$null | Out-String).Trim()
            $files = @(
                git -C (Resolve-RepoPath '.') diff --name-only HEAD 2>$null
                git -C (Resolve-RepoPath '.') ls-files --others --exclude-standard 2>$null
            ) | Where-Object { $_ }
        } finally {
            $ErrorActionPreference = $prevEap
        }
        foreach ($file in ($files | Sort-Object -Unique)) {
            $path = Join-Path (Resolve-RepoPath '.') $file
            $snapshot.Files[$file -replace '\\', '/'] = if (Test-Path -LiteralPath $path -PathType Leaf) { (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash } else { $null }
        }
    } catch { }
    return $snapshot
}

function Get-ScopeDriftWarnings {
    param([string]$PacketPath, [hashtable]$BeforeSnapshot)
    if (-not $PacketPath) { return @() }
    $scopePaths = Get-PacketScopePaths -PacketPath $PacketPath
    if ($null -eq $scopePaths -or $scopePaths.Count -eq 0) { return @() }
    $changedFiles = @()
    try {
        $afterSnapshot = Get-ChangedFileSnapshot
        if ($BeforeSnapshot) {
            $candidateFiles = @($BeforeSnapshot.Files.Keys + $afterSnapshot.Files.Keys | Sort-Object -Unique)
            foreach ($file in $candidateFiles) {
                $beforeHash = if ($BeforeSnapshot.Files.ContainsKey($file)) { $BeforeSnapshot.Files[$file] } else { $null }
                $afterHash = if ($afterSnapshot.Files.ContainsKey($file)) { $afterSnapshot.Files[$file] } else { $null }
                if ($beforeHash -ne $afterHash) { $changedFiles += $file }
            }
            if ($BeforeSnapshot.Head -and $afterSnapshot.Head -and $BeforeSnapshot.Head -ne $afterSnapshot.Head) {
                $changedFiles += @(git -C (Resolve-RepoPath '.') diff --name-only $BeforeSnapshot.Head $afterSnapshot.Head 2>$null)
            }
        } else {
            $changedFiles = @($afterSnapshot.Files.Keys)
        }
    } catch { $changedFiles = @() }
    if ($changedFiles.Count -eq 0) { return @() }
    $drift = @()
    foreach ($f in $changedFiles) {
        $normalized = $f -replace '\\', '/'
        $inScope = $false
        foreach ($sp in $scopePaths) {
            $spNorm = $sp -replace '\\', '/'
            if ($normalized -eq $spNorm -or $normalized.StartsWith("$spNorm/") -or $spNorm.StartsWith("$normalized/")) {
                $inScope = $true
                break
            }
        }
        if (-not $inScope) { $drift += $normalized }
    }
    return $drift
}

function Find-PacketByTaskId {
    param([string]$SearchTaskId, [string]$ProjectPath)
    if (-not $SearchTaskId) { return $null }
    foreach ($dir in @('packets', 'archive')) {
        $fullDir = Join-Path $ProjectPath ".agents\briefs\$dir"
        if (-not (Test-Path -LiteralPath $fullDir)) { continue }
        $matched = @(Get-ChildItem -Path $fullDir -Filter "$SearchTaskId-*.md" -File -ErrorAction SilentlyContinue)
        if ($matched.Count -gt 0) { return $matched[0].FullName }
    }
    return $null
}

#region hang 감시·시간 예산·스테이지 실행

# 강제 종료(hang·하드 상한)가 트리에 무엇을 남겼는지 보고한다.
# 재시도는 이 더러운 트리 위에서 그대로 다시 시작하므로, 반쪽 편집 위에 편집이 쌓일 수 있다.
# 스크립트는 이미 직전 상태($before)를 쥐고 있었는데 무변경 경고에만 쓰고 있었다.













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


#endregion 디스패치 본체



# ── 메인 진입점 ─────────────────────────────────────────────────────────────
if ($MyInvocation.InvocationName -ne '.' -and ($MyInvocation.Line -notmatch '^\s*\.\s' -or $MyInvocation.Line -eq $null)) {
    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        throw 'TaskId is required when executing dispatch-with-hang-detect.ps1 directly.'
    }
    $dispatchPlan = Resolve-DispatchPlan -TaskId $TaskId -Stage $Stage -Prompt $Prompt -Model $Model `
        -Chain:$Chain -DryRun:$DryRun -SkipVerdictGate:$SkipVerdictGate -ForceFreeModel:$ForceFreeModel `
        -ResetStageLedger:$ResetStageLedger -ResetReason $ResetReason `
        -ManualComplete:$ManualComplete -ManualAbort:$ManualAbort -Reason $Reason `
        -StageConfig $StageConfig -RepoRoot $RepoRoot -ProfileModule $ProfileModule -ProfileConfigPath $ProfileConfigPath

    if ($dispatchPlan.EarlyExit) {
        if ($dispatchPlan.Action) {
            exit (Invoke-DispatchChain -Plan $dispatchPlan)
        }
        exit $dispatchPlan.ExitCode
    }

    # 후속 Dispatch-Stage 및 내부 함수들이 전역 $StageConfig 및 스크립트 스코프 상태를 참조하므로 동기화
    $script:ProfileConfig = $dispatchPlan.ProfileConfig
    $script:RuntimeRoleBinding = $dispatchPlan.RuntimeRoleBinding
    $script:PipelineRouting = $dispatchPlan.PipelineRouting
    $script:ProviderHealthPath = $dispatchPlan.ProviderHealthPath
    $StageConfig = $dispatchPlan.ResolvedStageConfig

    $exitCode = Invoke-DispatchChain -Plan $dispatchPlan
    exit $exitCode
}
