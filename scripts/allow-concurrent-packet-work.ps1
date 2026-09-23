# allow-concurrent-packet-work.ps1 — CFG084
# impl(②) 단계 실행 창 동안 기획팀(또는 다른 동시 세션)이 후속 패킷을 준비하거나 무관한 작업의
# 라우터 행을 갱신할 때, 그 변경을 구현자의 "프로토콜 위반(권한 초과)"으로 오귀속하지 않도록
# 만료 시간부 화이트리스트 예외를 사전 등록한다. 등록되지 않은 변경은 기존과 동일하게 오염으로 탐지된다.
#
# 사용 예 (기획팀이 impl 단계 실행 중 후속 패킷을 미리 준비할 때):
#   powershell -File scripts\allow-concurrent-packet-work.ps1 -PacketFile CFG090-foo.md `
#       -Reason "기획팀 후속 패킷 사전 준비" -TtlMinutes 240
#   powershell -File scripts\allow-concurrent-packet-work.ps1 -RouterTaskId CFG090 `
#       -Reason "무관한 작업 라우터 행 갱신" -TtlMinutes 120
#
# -PacketFile 과 -RouterTaskId 중 정확히 하나만 지정한다. -Reason 은 필수다.
param(
    [string]$PacketFile,
    [string]$RouterTaskId,
    [Parameter(Mandatory = $true)][string]$Reason,
    [int]$TtlMinutes = 240
)

$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$LogDir = '.agents/briefs/logs'

function Write-Log {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'SUCCESS')]$Level = 'INFO')
    Write-Host "[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] [$Level] $Message"
}

# dispatch-with-hang-detect.ps1 이 정의하는 헬퍼를 최소 복제한다(이 스크립트는 디스패치 본체를
# 로드하지 않는다). Resolve-RepoPath 는 $RepoRoot 기준 상대경로를 절대경로로 변환한다.
function Resolve-RepoPath {
    param([string]$RelativePath)
    return (Join-Path $RepoRoot ($RelativePath -replace '/', '\'))
}

foreach ($moduleName in @('harness-contracts.ps1', 'harness-io.ps1', 'harness-dispatch-core.ps1')) {
    $modulePath = Join-Path $PSScriptRoot $moduleName
    if (-not (Test-Path -LiteralPath $modulePath)) { throw "Required harness module not found: $modulePath" }
    . $modulePath
}

$hasPacket = -not [string]::IsNullOrWhiteSpace($PacketFile)
$hasRouter = -not [string]::IsNullOrWhiteSpace($RouterTaskId)
if ($hasPacket -eq $hasRouter) {
    Write-Host '오류: -PacketFile 또는 -RouterTaskId 중 정확히 하나만 지정해야 합니다.' -ForegroundColor Red
    exit 1
}

$kind = if ($hasPacket) { 'packet' } else { 'router' }
$key = if ($hasPacket) { $PacketFile.Trim() } else { $RouterTaskId.Trim() }
$record = Register-ProtocolPollutionException -Kind $kind -Key $key -Reason $Reason -TtlMinutes $TtlMinutes
if ($null -eq $record) {
    Write-Host '오류: 화이트리스트 등록에 실패했습니다(사유·키 확인).' -ForegroundColor Red
    exit 1
}
Write-Host "등록 완료: kind=$($record.kind) key=$($record.key) expiresAt=$($record.expiresAt)" -ForegroundColor Green
exit 0
