# 작업 PF002 — 패널 토글 시 창 비례 리사이즈

- **상태**: DONE (Integration 완료 2026-07-22)
- **전환 유형**: PLAN_TO_IMPLEMENT
- **생성**: 2026-07-22 (기획팀/Claude)
- **Project Root**: `d:\Git\PerfMon`
- **선행**: PF001(완료, origin/main 반영). 본 작업은 PF001의 컴팩트/미니 Visible 동적 레이아웃 위에 얹는다.

---

## Amendments
(없음)

---

## Pipeline Status
> 첫 미체크 `- [ ]`가 여는 모델의 역할. 모든 리뷰는 제로베이스(이전 리뷰 미참고 후 대조).

- [x] ① 계획 — 기획팀/Claude (2026-07-22)
- [x] ② 구현 — 개발1팀/opencode (2026-07-22)
- [x] ③ 자체 리뷰 — 개발1팀/opencode (구현자 자체 점검, QA 아님) (2026-07-22)
- [x] ④ QA 리뷰 — QA팀/Codex (구현자와 다른 모델 필수) (2026-07-22)
- [x] ⑤ 최종 리뷰 + Integration — 기획팀/Claude (2026-07-22)

---

## Next Agent Mission (② 구현 — opencode)
패널을 보이기/숨기기로 토글할 때, **창 자체가 보이는 패널 수(정확히는 레이아웃 축 단위 수)에 비례해 커지거나 줄어들도록** 만든다. 현재는 창 크기가 고정된 채 남은 패널이 늘어나 빈 공간을 채운다(사용자 불만). 목표는 "패널당 크기 보존" — 4개 중 1개를 숨기면 높이가 75%로 줄고, 다시 보이면 원복.

## Done When
- 세로1열·미니·컴팩트: 패널 토글 시 **창 높이**가 비례 조정(패널당 높이 유지).
- 가로1줄: 패널 토글 시 **창 폭**이 비례 조정(패널당 폭 유지).
- 2×2 그리드: **행/열 수 변화**에 맞춰 높이·폭 비례 조정(4→3은 2행2열 유지→변화 없음; 2→1은 1행1열→절반).
- 스케일 모드(ScaleText=true)·비스케일 모드 both에서 패널당 화면 크기가 토글 전후로 유지됨.
- 배치 **모드 전환**(예: 세로→가로) 시에는 비례 리사이즈를 적용하지 않는다(축 의미가 달라짐 — 트래커만 갱신).
- 최초 로드(저장된 W/H 복원) 시에는 리사이즈하지 않는다(저장 크기 존중).
- MinWidth/MinHeight 하한 준수. 보이는 패널 0개 등 경계에서 divide-by-zero·이상 크기 없음.
- `powershell -File scripts\verify.ps1` → `ALL PASS`(경고 0·오류 0). Pipeline Status ②③ + 라우터 자기 행 갱신.

## First Action
`Required Reading`을 순서대로 읽고, 아래 **Implementation Spec**대로 `MainWindow.xaml.cs`에 비례 리사이즈 로직을 추가한다.

---

## Required Reading (순서 준수)
1. `MainWindow.xaml.cs` — 특히 `RenderAll`, `ApplyArrangement`, `Arrange*`(Vertical/Horizontal/Grid/Compact/Mini), `ApplyScale`, `ApplyMinSize`, `Row`/`Col`, `OnStateChanged`
2. `MainWindow.xaml` — HostGrid/MainGrid/Viewbox 구조, 패널 트리
3. `SettingsManager.cs` — `SectionSettings.Visible/WidthRatio/HeightRatio`, 저장/로드
4. `.agents/briefs/archive/PF001-team-review-fixes.md` — PF001에서 컴팩트/미니를 Visible 동적으로 바꾼 방식(§P2-5)

## Invariants (깨뜨리지 말 것)
- PF001의 컴팩트/미니 Visible 동적 레이아웃(숨긴 채널 제외 적층/전폭) 유지.
- 세로/가로/그리드 기존 배치 로직, always-on-top, 색상, 스케일 모드 재배치 유지.
- 창 위치 저장 디바운스(`OnStateChanged`→`_saveDebounce`) 유지 — 리사이즈로 인한 저장은 이 경로로 자연히 처리됨.
- `ApplyMinSize`가 산출하는 MinWidth/MinHeight를 하한으로 존중.

---

## Implementation Spec (SSOT — 무압축)

### 핵심 개념: "레이아웃 축 단위 수(unit)" 비례
토글 전후로 각 축(폭/높이)의 **단위 수** 비율만큼 실제 창 Width/Height를 곱해 조정한다. 이렇게 하면 스케일/비스케일 모드 모두에서 패널당 화면 크기가 보존된다(스케일 모드는 Viewbox 배율 H/D가 일정하게 유지, 비스케일 모드는 star 분모가 비율만큼 바뀜).

### 축 단위 수 정의 (현재 `_cfg`와 배치로부터 계산)
보이는 섹션 집합을 vis라 할 때:
- **Vertical**: `colUnits = 1`, `rowUnits = Σ(vis의 HeightRatio)`.
- **Horizontal**: `colUnits = Σ(vis의 WidthRatio)`, `rowUnits = 1`.
- **Grid2x2**: 기존 `ArrangeGrid`의 cols/rows 계산을 그대로 사용 — `cols = n>=2?2:1`, `rows = ceil(n/cols)`, `cw[c]=max(해당 열 셀들의 WidthRatio)`, `rh[r]=max(해당 행 셀들의 HeightRatio)`. `colUnits = Σ cw`, `rowUnits = Σ rh`.
- **Compact**: `topCount = (CPU.Visible?1:0)+(MEM.Visible?1:0)`, `bottomCount = (DISK.Visible?1:0)+(NET.Visible?1:0)`. `rowUnits = topCount*1 + (bottomCount>0 ? 2 : 0)`. **`colUnits`는 항상 1로 둔다(폭은 조정하지 않음)** — 컴팩트 폭은 상단 전폭 패널과 얽혀 있어 하단 좌우분할 붕괴로 창 폭을 바꾸면 CPU/MEM까지 좁아지는 부작용이 있으므로 높이만 비례 조정한다.
- **Mini**: `colUnits = 1`, `rowUnits = vis.Count`(미니는 모든 행이 동일 높이 Row(0.5)).

> 참고: 구분선 1px·테두리·마진 등 고정 요소는 비례 대상이 아니지만, 근사로 충분하다(단위 비율만 곱한다). 정밀 보정은 하지 않는다.

### 트래커 필드 (MainWindow에 추가)
```csharp
private Arrangement? _lastResizeArrange;   // 직전 렌더의 배치 모드
private double _lastColUnits;              // 직전 렌더의 폭 단위 수
private double _lastRowUnits;              // 직전 렌더의 높이 단위 수
private bool _sizeInitialized;             // 최초 로드 후 첫 렌더 완료 여부
```

### RenderAll 말미에 삽입할 로직 (ApplyMinSize 이후)
`RenderAll()`의 마지막(색상·최소크기 적용 뒤)에 `ApplyProportionalResize();` 호출을 추가하고 아래를 구현:
```csharp
private void ApplyProportionalResize()
{
    var (colUnits, rowUnits) = ComputeAxisUnits();

    // 최초 로드(저장 크기 복원) 또는 배치 모드 변경 시엔 리사이즈하지 않고 트래커만 갱신
    bool sameMode = _sizeInitialized && _lastResizeArrange == _cfg.Arrange;
    if (sameMode)
    {
        if (_lastColUnits > 0 && colUnits > 0 && Math.Abs(colUnits - _lastColUnits) > 1e-9)
            Width  = Math.Max(MinWidth,  Width  * (colUnits / _lastColUnits));
        if (_lastRowUnits > 0 && rowUnits > 0 && Math.Abs(rowUnits - _lastRowUnits) > 1e-9)
            Height = Math.Max(MinHeight, Height * (rowUnits / _lastRowUnits));
    }

    _lastResizeArrange = _cfg.Arrange;
    _lastColUnits = colUnits;
    _lastRowUnits = rowUnits;
    _sizeInitialized = true;
}
```
- `ComputeAxisUnits()`는 위 "축 단위 수 정의"를 그대로 코드화(현재 `_cfg.Sections`의 Visible/WidthRatio/HeightRatio 기반). Grid의 cw/rh 계산은 `ArrangeGrid`의 것과 동일 로직을 재사용(중복이면 작은 private 헬퍼로 추출해 양쪽에서 호출).
- 보이는 패널이 0개면 colUnits/rowUnits가 0이 되어 위 가드로 리사이즈를 건너뛴다(안전).

### 주의/엣지
- **모드 전환**: `_lastResizeArrange != _cfg.Arrange`면 `sameMode=false` → 리사이즈 없이 트래커만 갱신. 다음 토글부터 새 모드 기준으로 비례.
- **최초 로드**: `LoadSettings`→`RenderAll`의 첫 호출에서 `_sizeInitialized=false`라 리사이즈 스킵(저장 W/H 존중). 이후부터 동작.
- **설정창 적용/취소로 인한 RenderAll**: Visible이 바뀌면 그에 맞춰 리사이즈되는 게 맞다(일관). 단 폰트·색상만 바뀐 RenderAll은 units 불변이라 리사이즈 안 됨(정상).
- **리사이즈 저장**: Width/Height 변경 → SizeChanged → `OnStateChanged` → 디바운스 저장으로 자연 반영(별도 처리 불필요).
- **MinWidth/MinHeight**: `ApplyProportionalResize`는 `ApplyMinSize` 이후 호출되므로 최신 하한을 사용. 하한으로 clamp.
- **컴팩트 폭 불변**: 위 정의대로 compact의 colUnits=1 고정 → 컴팩트에서 폭은 절대 자동 변경되지 않는다(높이만).

### 검증 시나리오 (④QA·⑤최종리뷰가 확인)
- 세로1열/미니: 4개 표시 상태에서 1개 숨김 → 창 높이 ≈ 75%로 감소, 각 패널 화면 높이 유지. 다시 표시 → 원복(133%). 스케일·비스케일 both.
- 가로1줄: 1개 숨김 → 창 폭 ≈ 축소, 패널 폭 유지.
- 그리드: 4→3(2×2 유지) 크기 변화 없음; 4→2(2×1 또는 1×2) 한 축 절반; 2→1 양축 절반.
- 컴팩트: 상단 CPU 또는 MEM 숨김 → 높이 감소; 하단 DISK/NET 중 하나 숨김 → 높이 유지(하단 블록 존속)·나머지 전폭, 폭 불변.
- HeightRatio/WidthRatio가 1이 아닌 패널을 숨길 때 그 비중만큼 축소(단순 개수 아님)되는지.
- 모드 전환 직후 토글에서 이전 모드 units로 잘못 스케일되지 않는지.
- 최초 실행(저장된 크기)에서 즉시 리사이즈되지 않는지.

---

## Access Readiness
- Project Root 쓰기: `d:\Git\PerfMon` 소스 수정 필요(주로 `MainWindow.xaml.cs`) — 재확인 대상.
- 빌드: `scripts\verify.ps1`(dotnet build Release). **주의: 앱 실행 중이면 exe 잠금으로 빌드 실패** → 빌드 전 `PerfMonCS.exe` 프로세스 종료 확인.
- 외부 CLI/네트워크/브라우저: 불필요.
- Known Blockers: 없음.

## Agent Handoff Brief — ② 구현 (opencode)
**Files to edit(예상):** `MainWindow.xaml.cs` 단일(트래커 필드 + `ComputeAxisUnits` + `ApplyProportionalResize` + `RenderAll` 말미 호출; Grid cw/rh 계산 헬퍼 추출 시 `ArrangeGrid`도 소폭 리팩터).
**Risk level:** LOW~MEDIUM — 창 Width/Height를 프로그램적으로 바꾸므로 SizeChanged/디바운스 저장·MinSize와의 상호작용 주의. 무한 리사이즈 루프 없어야 함(RenderAll이 SizeChanged로 다시 트리거되지 않음 — RenderAll은 이벤트 핸들러가 아니며 SizeChanged는 저장만 예약).
**Do NOT touch:** PF001 컴팩트/미니 동적 레이아웃 골격, 색상·메뉴·always-on-top.
**Special instructions:** 빌드 전 앱 종료. `scripts\verify.ps1` ALL PASS. 확정 결정(현재 창 크기 비례 / 그리드 행·열 수 기준) 그대로. 컴팩트 폭 불변 규칙 준수.

---

## Task Handoff Summary — 작업 PF002 ②③ 완료 (opencode, 2026-07-22)

- `MainWindow.xaml.cs`에 직전 렌더의 배치 모드와 축 단위 수를 추적하는 필드(`_lastResizeArrange`, `_lastColUnits`, `_lastRowUnits`, `_sizeInitialized`)를 추가했다.
- `RenderAll()` 말미의 `ApplyMinSize()` 이후 `ApplyProportionalResize()`를 호출해 최신 MinWidth/MinHeight 하한을 먼저 계산한 뒤 창 Width/Height를 조정하도록 했다.
- `ComputeAxisUnits()`가 현재 visible 섹션과 배치 모드 기준으로 축 단위를 산출한다: Vertical은 HeightRatio 합, Horizontal은 WidthRatio 합, Grid2x2는 기존 `ArrangeGrid`의 cols/rows 및 열/행 최대 ratio 규칙, Compact는 폭 1 고정·높이 `topCount + bottomBlock(2)`, Mini는 visible count.
- 최초 로드와 배치 모드 전환 직후에는 리사이즈하지 않고 트래커만 갱신하도록 했다. 같은 배치 모드에서 축 단위가 바뀔 때만 현재 창 크기에 단위 비율을 곱하고 MinWidth/MinHeight로 clamp한다.
- 보이는 패널이 0개이거나 이전/현재 축 단위가 0인 경우 리사이즈를 건너뛰어 divide-by-zero와 이상 크기를 방지한다.

## Self Review Notes — 작업 PF002 ③ 자체 리뷰 (opencode, 2026-07-22)

- 제로베이스로 변경분을 검토했다. PF001의 컴팩트/미니 visible 동적 배치, 색상, always-on-top, 저장 디바운스 경로는 수정하지 않았다.
- 패킷 Done When 대조 결과: 세로/미니/컴팩트는 높이 단위, 가로는 폭 단위, 그리드는 기존 행/열 단위 변화에 따라 조정된다. Compact의 colUnits는 1 고정이라 폭 자동 변경이 없다.
- 최초 로드(`_sizeInitialized=false`)와 모드 전환(`_lastResizeArrange != _cfg.Arrange`)은 리사이즈를 스킵한다. 설정창 Apply/OK/Cancel 등 같은 모드에서 visible이 바뀌는 RenderAll은 단위 차이에 따라 비례 리사이즈된다.
- 잔여 리스크: WPF 실제 화면에서 패널당 픽셀 크기 보존 정도는 구분선 1px, 테두리, 마진 때문에 근사값이다. 패킷 스펙도 정밀 보정이 아닌 단위 비율 근사를 요구한다.
- SNS/마케팅 스킬은 이 WPF 런타임 레이아웃 변경에 직접 산출물로 적용할 지점이 없었다. UI/UX·프런트엔드·접근성 관점은 빈 공간 축소, 패널당 시각 크기 보존, MinSize 하한, 모드별 레이아웃 의미 보존에 반영했다. 백엔드 관점은 저장/렌더 side effect 경계와 divide-by-zero 방어 검토에 적용했다.

## Verification — 작업 PF002 ②③ 완료

- 빌드 전 `Get-Process -Name PerfMonCS -ErrorAction SilentlyContinue` 확인: 실행 중인 `PerfMonCS.exe` 없음.
- `powershell -ExecutionPolicy Bypass -File scripts\verify.ps1` → PASS, `ALL PASS`, 경고 0개, 오류 0개.

## Final Decisions & User Feedback Rationale — 작업 PF002 ②③ 완료

- 패킷의 확정 의도인 "패널당 크기 보존"을 그대로 적용했다. 자동 리사이즈는 visible 토글처럼 같은 배치 모드 안에서 축 단위 수가 바뀌는 경우에만 수행하고, 배치 모드 전환 및 최초 저장 크기 복원은 사용자의 현재/저장 크기 의도를 존중해 스킵한다.
- Grid2x2와 Compact의 특수 규칙은 패킷 Implementation Spec을 우선했다. 특히 Compact 폭은 자동 조정하지 않는다.

## Task Handoff Summary — PF002 QA review complete (Codex, 2026-07-22)

- Performed an independent zero-base review of the proportional-resize change and its WPF layout call path.
- Confirmed the axis-unit calculations match the rendered layout: Vertical/Mini/Compact use row units, Horizontal uses column units, and Grid2x2 uses the same per-row/per-column maxima as `ArrangeGrid`.
- Confirmed first render and arrangement changes only refresh resize baselines; zero visible sections and zero unit values cannot divide by zero.
- No code defects were found, so QA made no implementation changes.
- `powershell -ExecutionPolicy Bypass -File scripts\\verify.ps1` passed: Release build has 0 warnings, 0 errors, and `ALL PASS`.

## Final Decisions & User Feedback Rationale — QA

- The implementation preserves the specified proportional-resize behavior without changing the existing Compact/Mini visibility layout, settings persistence, or always-on-top behavior.
- QA verdict: pass; PF002 may proceed to final review and integration.

## Permission Handoff — 다음: ⑤ 최종 리뷰 + Integration (기획팀/Claude)

- Must Revalidate: 프로젝트 루트 `d:\Git\PerfMon` 읽기, `powershell -ExecutionPolicy Bypass -File scripts\verify.ps1` 실행 가능 여부, 앱 실행 중 exe 잠금 여부.
- Known Blockers: 없음.
- Known QA result: pass. Final review must re-run `scripts\\verify.ps1`.

작업 PF002 QA 리뷰 완료 — 다음: 최종 리뷰 + Integration(기획팀/Claude)

---

## Task Handoff Summary — 작업 PF002 ⑤ 최종 리뷰 + Integration 완료 (기획팀/Claude, 2026-07-22)

- 제로베이스로 `MainWindow.xaml.cs` 변경분(+65줄) 전수 검토. 스펙과 정확히 일치 확인:
  - 트래커 4필드 + `ApplyProportionalResize`(RenderAll 말미·ApplyMinSize 이후) + `ComputeAxisUnits`/`ComputeGridAxisUnits`/`ComputeCompactRowUnits`.
  - 무한 리사이즈 루프 없음(SizeChanged→디바운스 저장만, RenderAll 재트리거 안 함), 최초 로드·모드 전환 시 리사이즈 스킵, Min 하한 clamp, HeightRatio/WidthRatio≠1도 비중대로 축소, 컴팩트 폭 불변, 설정 취소 시 크기도 원복.
  - 그리드: 4→3(2×2 유지)=변화 없음, 4→2=한 축 절반, 2→1=한 축 절반 — 확정 결정(행/열 수 기준 비례)과 일치.
- `scripts\verify.ps1` 재실행 → `ALL PASS`(경고 0·오류 0). 실동작 스모크 테스트(기동·크래시 없음) 통과.
- 회귀 없음. QA verdict(pass)와 대조 결과 일치.

## Permission Handoff — 파이프라인 종료

- Must Revalidate: 없음(작업 완료).
- Known Blockers: 없음.
- 커밋: 로컬 커밋 수행. 푸시는 공개 원격이라 사용자 확인 후 진행(대기 중인 PF001 정정 커밋 `7279a35` 포함 여부 함께 확인).
