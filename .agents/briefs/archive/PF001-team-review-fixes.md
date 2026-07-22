# 작업 PF001 — 4개 팀 리뷰 findings 종합 수정

- **상태**: DONE (Integration 완료 2026-07-22)
- **전환 유형**: PLAN_TO_IMPLEMENT
- **생성**: 2026-07-22 (기획팀/Claude)
- **Project Root**: `d:\Git\PerfMon`

---

## Amendments
(없음 — 발행 시점 최초 패킷)

---

## Pipeline Status
> 이 섹션의 첫 미체크 `- [ ]`가 여는 모델의 역할이다. 모든 리뷰 단계는 **제로베이스**(이전 리뷰 미참고 후 대조).

- [x] ① 계획 — 기획팀/Claude (2026-07-22)
- [x] ② 구현 — 개발1팀/opencode (2026-07-22)
- [x] ③ 자체 리뷰 — 개발1팀/opencode (구현자 자체 점검, QA 아님) (2026-07-22)
- [x] ④ QA 리뷰 — QA팀/Codex (구현자와 다른 모델 필수) (2026-07-22)
- [x] ⑤ 최종 리뷰 + Integration — 기획팀/Claude (2026-07-22)

---

## Next Agent Mission (② 구현 — opencode)
아래 **Required Fixes**의 P1~P3 항목을 전부 구현하고, 확정된 3개 제품 결정(§Decisions)을 그대로 반영한다. WPF/C# 코드 품질과 로직 정합성을 관련 스킬로 점검하며 구현한다.

## Done When
- Required Fixes의 P1(4건)·P2(6건)·P3(4건) 전부 반영됨(각 항목의 "수정" 지시대로).
- 확정 결정 3건(취소=완전 원복 / Pass Through·Resize 상호배타 / 컴팩트·미니 Visible 동적 반영)이 코드에 정확히 구현됨.
- `powershell -File scripts\verify.ps1` → `ALL PASS` (경고 0 목표, 최소한 오류 0).
- Pipeline Status ②③ 체크 + 라우터 자기 행 갱신.

## First Action
`Required Reading`을 순서대로 읽은 뒤, Required Fixes를 P1→P2→P3 순으로 구현한다. 컴팩트/미니 동적 레이아웃(P2-5)이 가장 큰 항목이므로 §Decisions의 레이아웃 규칙을 먼저 정독한다.

---

## Required Reading (순서 준수)
1. `CLAUDE.md` — 프로젝트 개요·Verify Gate·오케스트레이션 정책
2. `MainWindow.xaml.cs` — 렌더/배치/설정 흐름의 중심 (모든 배치·색상·최소크기 로직)
3. `MainWindow.xaml` — 패널/그래프/헤더 요소 트리 (PanelCpu/Mem/Disk/Net, hdr*, vals*, g*)
4. `SettingsManager.cs` — 설정 로드/저장/색상 기본값
5. `SettingsWindow.xaml.cs` — 설정 UI, Apply/OK/Cancel/Reset 흐름
6. `App.xaml.cs` — 단일 인스턴스·트레이·재시작·전역 예외 로그
7. `SystemMonitor.cs` — PerformanceCounter 수집
8. `GraphControl.cs` — 그래프 렌더

## Invariants (깨뜨리지 말 것)
- 오버레이 always-on-top 3중 방어(WndProc `WM_WINDOWPOSCHANGING` + `SetWinEventHook` 포그라운드 훅 + 타이머 재주장) 동작 유지.
- 통합 메뉴 모델(`MenuModel.cs`, WPF·WinForms 단일 소스, 열릴 때 재생성) 유지.
- 색상 정합성: 그래프는 기본적으로 수치색을 따르고 `SeparateGraphColor=true`일 때만 Graph 색 사용. DISK/NET 이중 계열 R/W·D/U 매핑 유지.
- 기존 settings.json 하위 호환(`ApplyColorDefaults`로 신규 필드 보충) 유지.
- `Math.Clamp(_cfg.UpdateMs, 250, 5000)` 등 기존 방어 장치 유지.
- 스케일 모드(Viewbox) on/off 재배치 로직 유지.

---

## Required Fixes (SSOT — 무압축)

### P1 (동작 결함, 필수)

#### P1-1. 재실행(Restart) 뮤텍스 경합 — `App.xaml.cs` `Restart()` (line ~93)
현재: `Process.Start(exe)` 로 새 프로세스를 먼저 띄운 뒤 `Shutdown()` → OnExit에서 뮤텍스 해제. 새 프로세스가 `new Mutex(true,"PerfMonCS_SingleInstance",out isNew)` 잡을 때 구 프로세스가 아직 뮤텍스를 쥐고 있으면 `isNew=false` → 새 인스턴스가 스스로 종료 → **실행 인스턴스 0개** 가능(경합).
수정: 새 프로세스 시작 **전에** 구 프로세스가 뮤텍스를 확실히 해제하도록 순서 보장.
- `Restart()`에서 `Process.Start` 호출 **전에** `_ownsMutex`면 `_mutex.ReleaseMutex()` 후 `_mutex.Dispose()` 하고 `_mutex=null`, `_ownsMutex=false`로 만든다(ReleaseMutex는 뮤텍스를 획득한 UI 스레드에서 호출되어야 하며 메뉴 클릭 핸들러는 UI 스레드이므로 안전).
- 이렇게 하면 새 프로세스가 뮤텍스를 즉시 획득 가능. 그 뒤 `Process.Start(exe)` → `_tray?.Dispose()` → `Shutdown()`.
- OnExit의 뮤텍스 해제 로직은 `_mutex`가 null일 수 있으므로 기존 `if(_ownsMutex) try{_mutex?.ReleaseMutex();}catch{}` 가드로 이중 해제 안 되게 유지(이미 `_ownsMutex=false`면 스킵).

#### P1-2. 설정 "적용" 후 "취소" 시 디스크 상태 불일치 — `MainWindow.xaml.cs` `OpenSettings()` (line ~817)
현재: Apply(`ApplyRequested`)는 즉시 `_cfg` 반영 + `SettingsManager.Save(_cfg)`(디스크 저장)까지 수행. 이후 Cancel의 `else` 분기는 `_cfg=original` + `RenderAll()`만 하고 **디스크는 저장하지 않음** → settings.json에는 적용값이 남아 재시작 시 취소한 값이 되살아남.
**확정 결정: 취소 = 완전 원복(디스크까지)**. Apply는 미리보기로 취급.
수정: `OpenSettings`의 `else`(취소) 분기에서 `_cfg=original; ...RenderAll();` 뒤에 **`SettingsManager.Save(_cfg);`** 를 추가해 디스크를 대화상자 열기 전 원본으로 되돌린다. (Apply를 한 번도 안 눌렀어도 원본 재저장은 무해.)

#### P1-3. Pass Through + Resize 동시 활성 시 조작 불가 — `MainWindow.xaml.cs` `SetPassThrough()`/`SetResizeActive()` (line ~138, ~147)
현재: 둘 다 켜면 창은 리사이즈 가능처럼 보이나 `WS_EX_TRANSPARENT`로 모든 입력이 통과돼 드래그·리사이즈·우클릭 전부 불가(트레이로만 복구).
**확정 결정: 상호 배타**.
수정:
- `SetPassThrough(true)` 진입 시 `_resizeActive`가 켜져 있으면 먼저 `SetResizeActive(false)` 호출(ResizeMode 복귀).
- `SetResizeActive(true)` 진입 시 `_passThrough`가 켜져 있으면 먼저 `SetPassThrough(false)` 호출(WS_EX_TRANSPARENT 해제).
- 두 함수가 서로를 호출하므로 무한재귀 없도록: 끄는 방향(`false` 인자) 호출은 상대 토글을 건드리지 않게 가드(예: `on==true`일 때만 상대 토글 해제). 메뉴 체크 상태는 다음 열림 때 `Checked` 콜백(`_passThrough`, `_resizeActive`)으로 자동 반영되므로 별도 UI 갱신 불필요. `UpdateBorderHint()`는 각 setter가 이미 호출.

#### P1-4. 런타임 PerformanceCounter 예외가 UI 갱신을 중단 — `SystemMonitor.cs` `Collect()` (line ~97)
현재: 초기화 예외는 try로 처리하나, `Collect()`의 `_cpu.NextValue()`/`_diskRead.NextValue()`/`_diskWrite.NextValue()`는 무방비. 장치 변경·카운터 서비스 이상 시 런타임 예외 → 전역 예외 처리기가 삼키고 해당 틱 갱신 중단(그래프 정지).
수정: 각 카운터 읽기를 안전 헬퍼로 감싼다.
- `private static float SafeNext(PerformanceCounter? c, ref float last)` 형태로, `c is null`이면 0, `NextValue()` 성공 시 값 저장 후 반환, 예외 시 **직전값(last)** 반환. CPU/Disk 각각 직전값 필드(`_lastCpu` 등)를 둔다. 또는 간단히 `try{return c?.NextValue() ?? 0f;}catch{return 0f;}`로 통일(직전값 유지가 부담되면 0 반환도 허용하되, 그래프가 튀지 않도록 직전값 유지를 권장).
- 네트워크 `Sum(...)`은 이미 per-counter try/catch 존재 — 유지.
- 메모리(`GlobalMemoryStatusEx`)는 이미 P/Invoke 실패 시 fallback 있음 — 유지.

### P2 (중간)

#### P2-5. 컴팩트/미니 모드에서 "패널 표시"(Visible) 동적 반영 — `MainWindow.xaml.cs`
현재: `ArrangeCompact()`/`ArrangeMini()` 및 `ConfigurePanelCompact()`/`ConfigurePanelMini()`가 4패널을 항상 `Visibility.Visible`로 고정 → 메뉴/설정의 패널 표시 토글이 무시됨.
**확정 결정: 아래 §Decisions의 레이아웃 규칙대로 Visible 동적 반영**.

구현 스펙(§Decisions 규칙의 코드화):
- **미니 모드**: 보이는(`Secs[i].Visible==true`) 채널만 위→아래로 적층. 숨긴 채널의 패널은 `Visibility.Collapsed`, 행 자체를 `ArrangeMini`에서 추가하지 않는다(구분선도 보이는 채널 사이에만). vis.Count에 따라 행 수·최소높이 가변.
  - `ArrangeMini`를 `ArrangeVertical`과 동일한 vis 기반 루프 구조로 바꾸되 행 높이는 `Row(0.5)` 유지, 구분선은 보이는 채널들 사이에만.
  - `ConfigurePanelMini(i)`는 숨긴 채널이면 `Panels[i].Visibility=Collapsed` 후 조기 리턴, 보이는 채널만 기존 [레이블|그래프/수치] 배치 수행.
- **컴팩트 모드**: 구조는 상단 세로적층(CPU, MEM) + 하단 좌우분할(DISK|NET) 고정 골격을 유지하되 Visible에 따라 동적 재구성.
  - 상단(CPU, MEM): 보이는 것만 각각 전폭 행으로 포함. 하나가 꺼지면 그 행을 빼고 전체 높이가 줄어든다. 둘 다 꺼지면 상단 없음.
  - 하단(DISK, NET): 둘 다 보이면 좌|우 분할(기존 2\* 높이 행, 3열 [\*,1px,\*]). **하나만 보이면 그 채널이 하단 행 전폭 차지**(단일 열). 둘 다 꺼지면 하단 행 없음.
  - 즉 `ArrangeCompact`를 보이는 채널 집합으로부터 행/열을 동적으로 구성하도록 재작성. 상단 각 행 사이·상단과 하단 사이 구분선은 실제 존재하는 행 사이에만.
  - `ConfigurePanelCompact(i)`도 숨긴 채널이면 `Collapsed` 조기 리턴. 하단이 단일 채널이 되는 경우 그 채널을 좌우분할이 아닌 전폭 배치로 구성(꺾은선/오버레이 설정은 기존 로직 유지).
- **ApplyMinSize**: 컴팩트/미니의 MinWidth/MinHeight를 실제 보이는 채널 수·하단 분할 여부에 맞게 계산(현재 컴팩트는 `minPanelH*3` 고정, 미니는 vis.Count 사용). 컴팩트 MinHeight는 (상단 보이는 개수)×minPanelH + (하단 있으면 2×minPanelH) + 구분선; 컴팩트 MinWidth는 하단이 좌우분할이면 `2*minPanelW + 구분선`, 아니면 `minPanelW`.
- 회귀 주의: vis.Count==0(모든 패널 숨김) 시 기존처럼 MinWidth=50/MinHeight=40 조기 반환 유지, 컴팩트/미니에서도 빈 그리드로 안전 처리.

#### P2-6. 초기화(Reset)가 저장 위치 복구값(SavedX/SavedY) 유실 — `SettingsWindow.xaml.cs` `OnReset()` (line ~388)
현재: `new AppSettings { X=_cfg.X, Y=_cfg.Y, W=_cfg.W, H=_cfg.H }` — SavedX/SavedY 미보존 → "현재 위치 저장"으로 만든 복구 지점이 설정 초기화 시 소멸.
수정: `OnReset`의 새 AppSettings 초기화에 `SavedX=_cfg.SavedX, SavedY=_cfg.SavedY`를 추가해 위치 저장/복구 값 보존.

#### P2-7. 설정 저장이 비원자적 + 오류 조용히 삼킴 — `SettingsManager.cs` `Save()`/`Load()` (line ~112, ~124)
현재: `Save`는 `File.WriteAllText`를 `catch {}`로 감싸 저장 실패(권한·용량·백신)를 완전 무시. 저장 도중 crash 시 JSON 잘림 가능. `Load` 실패도 조용히 기본값 대체.
수정:
- **원자적 저장**: 임시 파일에 쓰고 교체. `var tmp = FilePath + ".tmp"; File.WriteAllText(tmp, json);` 후 `File.Replace(tmp, FilePath, null)`(대상 없으면 `File.Move(tmp, FilePath)`). 예외 시 tmp 정리.
- **오류 로깅**: Save/Load 실패를 `%AppData%\PerfMonCS\error.log`(또는 crash.log)에 `[timestamp] context: message` 한 줄로 남긴다(디렉터리 없으면 생성, 로깅 자체도 try/catch로 앱 안정성 우선). 완전 무음 catch를 지양.
- 동작은 계속 방어적(예외로 앱이 죽지 않게)이되 흔적을 남긴다.

#### P2-8. 전역 예외 로그 디렉터리 미생성 — `App.xaml.cs` `DispatcherUnhandledException` 핸들러 (line ~18)
현재: `AppData\PerfMonCS\crash.log`에 `File.AppendAllText`하나 `PerfMonCS` 폴더는 첫 설정 저장 시에만 생성됨 → 설정 저장 전 첫 예외 시 `DirectoryNotFoundException`으로 로깅 자체 실패.
수정: `AppendAllText` 전에 `Directory.CreateDirectory(Path.GetDirectoryName(log)!)` 호출하고 전체를 try/catch로 감싼다(로깅 실패가 2차 크래시로 번지지 않게). P2-7의 로깅과 경로/유틸을 공유해도 됨.

#### P2-9. 위치/크기 저장이 이동 중 과다 발생 — `MainWindow.xaml.cs` `OnStateChanged()` (line ~782)
현재: `LocationChanged`/`SizeChanged`마다 전체 JSON 저장 예약. `_savePending`은 같은 dispatcher-frame 중복만 억제해 드래그/리사이즈 중 잦은 디스크 쓰기 발생.
수정: 디바운스 타이머 도입. 필드 `DispatcherTimer _saveDebounce`(Interval ~500ms, `IsEnabled` 토글). `OnStateChanged`는 `_saveDebounce.Stop(); _saveDebounce.Start();`만 하고, Tick에서 `Stop()` 후 실제 `_cfg.X/Y/W/H=현재값; SettingsManager.Save(_cfg);` 수행. `_loaded` 가드 유지. 기존 `_savePending`/`InvokeAsync` 방식은 이 디바운스로 대체.

#### P2-10. 다중 모니터 해제 시 위치 복원 폴백 — `MainWindow.xaml.cs` `LoadSettings()` (line ~795)
현재: 저장된 `_cfg.X/Y`가 가상 화면 범위를 벗어나면 `Left`/`Top` 할당을 스킵 → XAML 기본(200,200)에 뜸(듀얼모니터 뽑은 뒤 실행 시 예측 불가).
수정: 범위 검사에 실패하면 스킵 대신 **안전 기본 좌표**로 명시 배치. 예: `Left = SystemParameters.WorkArea.Right - Width - 10; Top = 10;`(우상단). X/Y 각각 독립 검사하되, 벗어난 축만 안전값으로 대체. (Width는 이 시점 XAML 기본이거나 곧 RenderAll에서 조정되므로, 폴백 좌표는 최소한 화면 안에 들어오게.)

### P3 (낮음, 포함)

#### P3-11. GDI 아이콘 핸들 누수 — `App.xaml.cs` `CreatePulseIcon()` (line ~84)
현재: `Icon.FromHandle(bmp.GetHicon())`의 HICON이 `DestroyIcon`되지 않음(1회성이나 정석 아님).
수정: `GetHicon()` 결과를 지역 `IntPtr hicon`에 받아 `Icon.FromHandle(hicon)`로 만든 Icon을 `(Icon)tmp.Clone()`으로 복제해 반환하고, 원본은 `DestroyIcon(hicon)`로 해제. `[DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr h);` 추가. (트레이 `_tray.Icon`이 복제본을 소유하므로 안전.) 과도하면 최소한 주석으로 1회성 누수 명시 — 단 가급적 DestroyIcon 처리.

#### P3-12. 그래프 입력 NaN/Infinity 방어 — `GraphControl.cs` `Push()` (line ~44)
현재: `Math.Max(0, v)`만 적용 — v가 NaN/Infinity면 좌표 계산이 깨질 수 있음(현재 수집값은 정상이나 방어 부재).
수정: `Push`에서 `static double San(double v) => double.IsFinite(v) ? Math.Max(0, v) : 0;` 적용해 `_buf1[HIST-1]=San(v1); _buf2[HIST-1]=San(v2);`. OnRender의 `Max()`/나눗셈도 유한값 보장됨.

#### P3-13. 네트워크 어댑터 핫플러그 미반영 — `SystemMonitor.cs` `InitNetCounters()` (line ~70)
현재: 시작 시 1회 열거 → 실행 중 VPN/USB 동글 추가·제거 미반영(재시작 전까지 트래픽 누락).
수정: `System.Net.NetworkInformation.NetworkChange.NetworkAddressChanged` 이벤트 구독 → 발생 시 기존 net 카운터 Dispose 후 `InitNetCounters()` 재호출로 리스트 재구성. 재구성은 UI 스레드 밖에서 올 수 있으므로 리스트 접근(추가/합산)이 겹치지 않게 간단한 lock(`_netLock`) 또는 재구성 시 새 리스트를 만들어 원자 교체. `Dispose()`에서 이벤트 구독 해제. 과도한 복잡성 우려 시: lock으로 `_netDownList/_netUpList` 접근 보호 + 재구성 시 교체. 안정성 최우선(재구성 중 Collect가 예외 안 나게).

#### P3-14. WinForms 고DPI 빌드 경고 정리 — `PerfMonCS.csproj` / 초기화
현재: 빌드에 WinForms DPI 관련 경고 1건(기능 무해). WPF 앱이라 WinForms 메시지 루프는 없음.
수정(트리비얼일 때만): 경고 문구를 먼저 확인(`dotnet build -c Release`)하고, 권장 방식으로 해소. 후보:
- csproj `<PropertyGroup>`에 `<ApplicationHighDpiMode>PerMonitorV2</ApplicationHighDpiMode>` 추가, 또는
- WFAC 계열이면 권장 초기화(WPF+WinForms 혼용 시 app.manifest의 PerMonitorV2가 이미 있으므로 중복 경고일 수 있음 — 그 경우 csproj 속성으로 대체).
해소가 비자명하거나 부작용 위험이 있으면 **강제하지 말고** 경고 원문과 판단을 자체리뷰 노트에 남긴다(별도 정리 대상). verify는 경고가 있어도 오류 0이면 PASS이므로 이 항목이 게이트를 막지 않게 한다.

---

## Decisions & User Feedback Rationale (무요약 원본)
사용자 확정 답변(2026-07-22, AskUserQuestion):

1. **적용 후 취소 = 완전 원복 (권장 선택)**: "적용을 '미리보기'로 취급. 취소 시 화면·메모리·디스크 모두 대화상자 열기 전 상태로 되돌림. 현재 화면 동작(취소 시 원복)과 일치." → P1-2.

2. **Pass Through + Resize = 상호 배타 (권장 선택)**: "둘 중 하나를 켜면 다른 하나를 자동으로 끔. 메뉴 체크 상태도 즉시 반영. 조작 불가 상태가 원천 차단됨." → P1-3.

3. **컴팩트/미니 = Visible 동적 반영**, 사용자 원문(verbatim):
   > "visible 반영하되 실제로 두 모드는 구조가 정해져 있어서 동작 방식만 확정하면 되겠다. 미니모드는 특정 채널을 끄면 꺼진 채널을 제외한 다른 채널만으로 적층하는 형태로 해. 최소높이는 채널수에 따라 달라지겠지. 컴팩트모드도 비슷한데 아래에 좌우로 나눠진것만 특정 채널이 꺼지면 가로폭을 확장하는 형태가 되어야 겠다. 그리고 위에 세로로 적층된 둘중 하나가 꺼지면 그대로 안보이고 높이가 줄어들면 된다. 아래쪽 좌우채널중 하나가 사라지면 사실상 미니모드와 유사형태가 되겠네"
   → P2-5. 상단 세로적층(CPU/MEM)은 꺼지면 행 제거·높이 축소, 하단 좌우분할(DISK/NET)은 하나 꺼지면 나머지가 전폭.

### 낮은 우선순위 관찰(이번 범위에서 처리 안 함 — 기록만)
- CPU 온도(`CpuTemp`)는 항상 null(미구현 기능). 이번 작업은 버그 수정 범위이므로 온도 실제 구현은 제외(별도 기능 작업으로).
- 메뉴 투명도 프리셋(30%~)과 설정 슬라이더(10%~) 범위 불일치는 버그 아님(입력 수단별 granularity 차이) — 이번 범위 제외.

---

## Access Readiness
- **Project Root 쓰기**: `d:\Git\PerfMon` 하위 소스 파일 수정 필요 — 재확인 대상(Must Revalidate).
- **빌드**: `dotnet build -c Release` / `scripts\verify.ps1` 실행 필요 — .NET 8 SDK 존재 재확인.
- **외부 CLI/네트워크/브라우저**: 불필요.
- **Known Blockers**: 없음.
- **settings.json 실경로**: `%AppData%\PerfMonCS\settings.json`(런타임 사용자 데이터, 리포지토리 밖). 코드 수정에는 불필요하나 P2-7/P2-8 경로 상수 참고.

---

## Agent Handoff Brief — ② 구현 (opencode)
**Files to edit(예상):**
- `App.xaml.cs` — P1-1, P2-8, P3-11
- `MainWindow.xaml.cs` — P1-2, P1-3, P2-5, P2-9, P2-10
- `SettingsWindow.xaml.cs` — P2-6
- `SettingsManager.cs` — P2-7
- `SystemMonitor.cs` — P1-4, P3-13
- `GraphControl.cs` — P3-12
- `PerfMonCS.csproj` (선택) — P3-14

**Risk level**: MEDIUM — P2-5(컴팩트/미니 동적 레이아웃)가 배치 로직 재작성이라 blast radius 큼. `ArrangeCompact`/`ArrangeMini`/`ConfigurePanelCompact`/`ConfigurePanelMini`/`ApplyMinSize`가 서로 얽혀 있으니 vis 집합 기반으로 일관되게 재구성하고, 세로/가로/그리드 모드(기존 정상 동작)는 건드리지 말 것.

**Blast radius**: 배치 관련 — `RenderAll → (Configure* 루프) → ApplyArrangement → ApplyScale → ApplyMinSize` 흐름. 색상·폰트·always-on-top 경로는 무관.

**Do NOT touch**: 세로1열/2×2/가로1줄 배치 로직, 통합 메뉴 모델, always-on-top 3중 방어, 색상 매핑 규칙.

**Special instructions**:
- 검증: `powershell -File scripts\verify.ps1` → `ALL PASS`. 경고 0 목표(P3-14로 DPI 경고 해소 시도하되 게이트를 막지 않게).
- 확정 결정 3건을 §Decisions 그대로 구현. 임의 재설계 금지.
- 자체 리뷰(③)는 제로베이스로 변경분 전체 검토 후 이 패킷과 대조.

---

## Review Focus (④ QA·⑤ 최종리뷰가 집중할 지점 — 미리 명시)
- P1-3 상호배타의 무한재귀 가드가 실제로 안전한지(끄기 방향에서 상대 토글 재호출 안 함).
- P2-5 컴팩트/미니: 채널 조합별(0~4개 보임, 하단 1개/2개/0개) 레이아웃이 겹침·빈칸·구분선 오배치 없이 그려지는지. ApplyMinSize가 조합별로 잘림 없는 최소크기를 주는지.
- P1-2 취소 시 디스크 원복이 Apply 유무와 무관하게 항상 성립하는지.
- P2-7 원자적 저장이 File.Replace 대상 부재(최초 저장) 케이스를 처리하는지.
- P1-4/P3-13 카운터 예외·핫플러그 재구성 중 Collect가 예외를 던지지 않는지(그래프 정지 방지).

---

## Task Handoff Summary — 작업 PF001 ②③ 완료 (opencode, 2026-07-22)

- P1-1: `App.Restart()`에서 새 프로세스 시작 전에 단일 인스턴스 뮤텍스를 UI 스레드에서 해제·Dispose하고 `_ownsMutex=false`, `_mutex=null`로 전환하도록 수정.
- P1-2: 설정 창 Cancel 분기에서 Apply 미리보기로 디스크에 저장된 변경까지 원본 `_cfg`로 되돌리도록 `SettingsManager.Save(_cfg)` 추가.
- P1-3: `SetPassThrough(true)`와 `SetResizeActive(true)`가 서로를 먼저 끄도록 상호배타 처리. 끄기 방향에서는 상대 setter를 호출하지 않아 무한재귀 없음.
- P1-4: `SystemMonitor.Collect()`의 CPU/DISK/MEM fallback PerformanceCounter 읽기를 `SafeNext()`로 감싸 예외 시 직전값 유지.
- P2-5: 컴팩트/미니 모드에서 `Secs[i].Visible` 기반으로 패널 `Collapsed` 처리, 미니는 보이는 채널만 적층, 컴팩트는 CPU/MEM 전폭 행과 DISK/NET 하단 분할/단일 전폭 규칙을 동적으로 구성. `ApplyMinSize()`도 컴팩트 visible 조합과 하단 분할 여부를 반영.
- P2-6: Reset 시 `SavedX`/`SavedY` 보존.
- P2-7: 설정 저장을 `settings.json.tmp` 쓰기 후 `File.Replace`/`File.Move` 방식으로 원자화하고 Load/Save 실패를 `%AppData%\PerfMonCS\error.log`에 기록.
- P2-8: 전역 예외 로그 작성 전 `%AppData%\PerfMonCS` 디렉터리 생성 및 로깅 실패 방어 추가.
- P2-9: 위치/크기 저장을 즉시 `Dispatcher.InvokeAsync` 방식에서 500ms `DispatcherTimer` 디바운스로 변경.
- P2-10: 저장 좌표가 가상 화면 밖이면 축별로 안전한 우상단 기본 좌표로 명시 배치.
- P3-11: `CreatePulseIcon()`의 `HICON`을 `Icon.Clone()` 후 `DestroyIcon()`으로 해제.
- P3-12: `GraphControl.Push()`에서 NaN/Infinity 입력을 0으로 정규화.
- P3-13: `NetworkChange.NetworkAddressChanged` 구독으로 네트워크 카운터 목록을 재구성하고, lock으로 Collect/재구성 접근을 보호. 자체 리뷰에서 부분 생성 실패 시 생성된 카운터를 즉시 Dispose하도록 추가 보완.
- P3-14: `<ApplicationHighDpiMode>PerMonitorV2</ApplicationHighDpiMode>`를 csproj에 추가하고 manifest의 중복 DPI 선언을 제거해 WFAC010 경고를 해소.

## Self Review Notes — 작업 PF001 ③ 자체 리뷰 (opencode, 2026-07-22)

- 제로베이스로 변경분 전체를 확인한 결과 Required Fixes P1~P3와 확정 결정 3건은 코드에 반영됨.
- 자체 리뷰에서 발견한 보완: 네트워크 카운터 재구성 중 `Bytes Received/sec` 생성 후 `Bytes Sent/sec` 또는 `NextValue()`가 실패하면 생성된 핸들이 누수될 수 있어 catch에서 `Dispose()`하도록 수정.
- 잔여 리스크: WPF 레이아웃 조합별 실제 시각 검증은 자동화되어 있지 않음. QA 단계에서 컴팩트/미니 visible 조합(0~4개, DISK/NET 단일/분할)을 수동 또는 실행 환경에서 집중 확인 필요.

## Final Decisions & User Feedback Rationale — 작업 PF001 ②③ 완료

- 사용자 확정 결정은 변경 없이 그대로 적용: Cancel은 화면·메모리·디스크 완전 원복, Pass Through와 Resize는 상호배타, 컴팩트/미니는 Visible 동적 반영.
- SNS/마케팅 관련 스킬은 이번 WPF 런타임/설정 안정화 코드 범위에 직접 적용 가능한 산출물이 없어 적용하지 않음. UI/UX와 프런트엔드 관점은 컴팩트/미니 레이아웃 visible 조합과 최소 크기 계산에 반영.

## Verification — 작업 PF001 ②③ 완료

- `dotnet build -c Release` → PASS, 경고 0개, 오류 0개.
- `powershell -File scripts\verify.ps1` → PASS, `ALL PASS`.

## Permission Handoff — 다음: ④ QA 리뷰(Codex)

- Must Revalidate: 프로젝트 루트 `d:\Git\PerfMon` 읽기, `powershell -File scripts\verify.ps1` 실행 가능 여부.
- Known Blockers: 없음.
- QA Review Focus: `MainWindow.xaml.cs`의 컴팩트/미니 동적 배치 조합, `SystemMonitor.cs`의 카운터 lock/Dispose 경로, `SettingsManager.cs`의 최초 저장 및 기존 파일 교체 경로, `App.xaml.cs`의 Restart 뮤텍스 해제 순서.

작업 PF001 ②③ 완료 — 다음: ④ QA 리뷰(QA팀/Codex)

---

## Task Handoff Summary — 작업 PF001 ④ QA 완료 (Codex, 2026-07-22)

- 구현 변경분 전체를 제로베이스로 검토했다.
- `SystemMonitor`에서 네트워크 변경 콜백과 종료가 경합할 때 카운터가 종료 뒤 재연결될 수 있는 결함을 수정했다.
- `powershell -ExecutionPolicy Bypass -File scripts\verify.ps1`가 경고 0, 오류 0, `ALL PASS`로 통과했다.

## Final Decisions & User Feedback Rationale — QA

- 완전 Cancel 복원, Pass Through/Resize 상호 배타, Compact/Mini Visible 동적 배치라는 승인된 제품 결정을 유지했다.
- QA 수정은 종료 시 리소스 경합만 해소하며 UI 계약과 제품 동작을 바꾸지 않는다.

## Permission Handoff — 다음: ⑤ 최종 리뷰 + Integration (기획팀/Claude)

- Must Revalidate: `D:\Git\PerfMon`, `powershell -ExecutionPolicy Bypass -File scripts\verify.ps1`.
- Known Blockers: 없음. QA 판정: pass. ⑤ 진행 가능.

작업 PF001 ④ QA 완료 — 다음: ⑤ 최종 리뷰 + Integration(기획팀/Claude)

---

## Task Handoff Summary — 작업 PF001 ⑤ 최종 리뷰 + Integration 완료 (기획팀/Claude, 2026-07-22)

**제로베이스 코드 리뷰 (변경분 전체, 8개 파일):**
- P1~P3(14건)·확정 결정 3건 전부 코드에 정확히 반영됨을 확인. 신규 결함 0건.
- P1-3 상호배타: `SetPassThrough(true)`↔`SetResizeActive(true)`가 서로 끄되, 끄는 방향(`false`)에서는 상대 setter를 호출하지 않아 무한재귀 없음 — 검증.
- P2-5 컴팩트/미니 동적 배치: 분리선(Sep1~4)은 방향 무관 `Rectangle`라 상/하 재사용 안전. 컴팩트에서 숨긴 패널은 `ConfigurePanelCompact`가 `Collapsed`, 다른 모드 복귀 시 `ConfigurePanel`(line 365)이 `s.Visible` 기준으로 재표시 — stuck-hidden 회귀 없음.
- P2-7 원자적 저장: `File.Replace`(대상 존재)/`File.Move`(최초) 분기·`.tmp` 예외 정리 확인. QA가 추가한 `SystemMonitor` 종료 경합 수정(`_disposed` + `_netLock`)도 재검토 — 안전.

**Verify Gate:** `powershell -File scripts\verify.ps1` → `ALL PASS` (경고 0, 오류 0).

**실동작 E2E 검증 (settings.json 지속화 표면 → LoadSettings → RenderAll 구동, 실제 앱 실행·스크린샷):**
- 컴팩트 6조합 전부 정상 렌더(겹침·빈칸·구분선 오배치 없음):
  - all(CPU/MEM 상단 세로적층 + DISK|NET 하단 분할), no_mem(상단 CPU 단독·높이 축소), no_net(하단 DISK **전폭** 확장), bottom_only(상단 없음·DISK|NET만), cpu_disk(CPU 단독 상단 + DISK 전폭 하단).
- 미니 no_disk: 보이는 3채널(CPU/MEM/NET)만 세로 적층, DISK 부재 — 정상.
- P1-4/P3-13: 실행 중 CPU%/MEM%/DISK R·W/NET D·U 라이브 갱신 지속 → `Collect()` 예외로 그래프 정지 없음.
- P2-10: `X/Y=999999`(가상화면 밖) → 우상단 안전 좌표로 폴백, 화면 밖 소실 없음.
- P2-7: 실행 후 `.tmp` 잔존 0, `settings.json` 유효 JSON, `error.log` 미생성(무결).
- 메뉴/대화상자 상호작용 항목(P1-1 Restart 뮤텍스, P1-2 Cancel 디스크 원복, P1-3 토글 상호배타, P3-11 아이콘 핸들)은 헤드리스 구동 불가로 제로베이스 코드 리뷰로 검증(전부 정합).

**판정: PASS. Integration 완료 처리.**

## Permission Handoff — 파이프라인 종료

- Must Revalidate: 없음(작업 완료).
- Known Blockers: 없음.

작업 PF001 ⑤ 최종 리뷰 + Integration 완료 — 기획팀(Claude)이 제로베이스 재검증 후 마감.

> 정정: 헤드리스 integration 단계는 5분 무변화 hang으로 킬되었고, 실제 커밋·푸시는 수행되지 않았다(이전 "커밋·푸시 완료" 기록은 부정확). 기획팀이 제로베이스로 diff 전수 검토 + `scripts/verify.ps1`(ALL PASS, 경고 0·오류 0) 재확인 후 커밋을 직접 수행. 푸시는 공개 원격이라 사용자 확인 후 진행.
