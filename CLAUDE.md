# PerfMon 지침

## 프로젝트 개요
Windows용 성능 모니터링 오버레이 앱 (.NET 8 / WPF, `PerfMonCS.csproj` 단일 프로젝트).
CPU/MEM/DISK/NET 실시간 그래프를 항상 위(always-on-top) 오버레이로 표시하며, 일반/미니 모드 전환, 트레이 아이콘, 설정 창(`SettingsWindow`)을 제공한다. 자동 테스트 프로젝트는 아직 없음(빌드 성공이 현재 검증 기준).

---

<!-- headless-dispatch:start -->
# Headless Dispatch — 단계별 표준 명령

ai-agents-config의 공용 하네스 설정을 사용합니다:
```powershell
powershell -ExecutionPolicy Bypass -File "D:\Git\ai-agents-config\global\harness\dispatch-with-hang-detect.ps1" -TaskId PMxxx -Chain
```

상세: `D:\Git\ai-agents-config\global\harness\orchestration-runbook.md` 참조.
작업 ID 접두: **PM** (예: PM001) — 다른 프로젝트 번호 체계와 구분.

<!-- headless-dispatch:end -->

<!-- verify-gate:start -->
# Verification Gate

PerfMon 검증 게이트: `scripts/verify.ps1` (표준 포맷은 전역 지침의 Verify Gate 프로토콜 참조, 여기서는 이 프로젝트 고유 내용만 기록).

```powershell
powershell -File scripts\verify.ps1
```

- 현재 단계: `dotnet build -c Release` 1개 스텝만 있음 (자동 테스트 없음).
- 자동 테스트가 추가되면 `scripts/verify.ps1`에 `Invoke-Step`으로 추가하고, 이 섹션에도 반영할 것.
- 파이프라인 단계(②구현·④QA·⑤최종리뷰/Integration) 모두 이 스크립트 통과를 요구한다.

<!-- verify-gate:end -->

<!-- orchestration:start -->
# 🤖 오케스트레이션 자동화 정책

ai-agents-config 공용 정책 상속 (`global/harness/orchestration-runbook.md` §1~3):
- 기획팀 승인 후 ②구현→③자체리뷰→④QA→⑤최종리뷰→Integration 자동 연쇄
- 각 단계: **제로베이스 검토** (이전 리뷰 미참고 후 대조)
- 라우팅: `.agents/briefs/handoff-log.md` 라우터 표 → 패킷 파일(`packets/PMxxx-<slug>.md`)의 Pipeline Status 첫 미체크 항목이 역할.

<!-- orchestration:end -->
