# PerfMon History

## 2026-07-22

### PF001 QA review and fix

- Completed an independent QA review of the PF001 implementation.
- Fixed a `SystemMonitor` shutdown race: a `NetworkAddressChanged` callback can no longer reattach network counters after disposal.
- Verified with `scripts/verify.ps1`: Release build passed with zero warnings and errors.

### PF001 final review + Integration

- Zero-base reviewed the full PF001 diff (8 files): all P1–P3 fixes and the 3 confirmed product decisions (Cancel = full disk revert, Pass-Through/Resize mutual exclusion, Compact/Mini dynamic Visible) are correctly implemented; no new defects.
- Verify gate `scripts/verify.ps1` → `ALL PASS` (0 warnings, 0 errors).
- Ran the real app end-to-end via the settings.json persistence surface and captured each layout:
  - Compact combos — all 4 visible (CPU/MEM stacked + DISK|NET split), MEM hidden (row removed, height shrinks), NET hidden (DISK spans full width), both top hidden (bottom split only), CPU+DISK only (single top + full-width bottom) — all render without overlap/blank/misplaced separators.
  - Mini with DISK hidden — only the 3 visible channels stack.
  - Live CPU/MEM/DISK/NET values keep updating (no `Collect()` stall from the new SafeNext/net-lock path).
  - Off-screen coords (X/Y = 999999) fall back to the top-right on-screen position instead of vanishing.
  - Atomic save leaves no `.tmp`, settings.json stays valid JSON, no error.log on a clean run.
- Menu/dialog-only fixes (Restart mutex, Cancel disk revert, toggle mutual exclusion, icon handle) verified by code review (not headlessly drivable).
- Integration completed; PF001 pipeline closed.

### PF002 UI/UX proportional resize

- 작업 PF002: 패널 표시 토글 시 남은 패널이 빈 공간을 늘려 차지하지 않도록, 같은 배치 모드 안에서는 창 Width/Height를 보이는 패널의 레이아웃 축 단위 변화에 비례해 자동 조정하도록 했다.
- `MainWindow.xaml.cs`: Vertical/Mini/Compact는 높이 단위, Horizontal은 폭 단위, Grid2x2는 기존 행/열 계산 단위에 따라 조정한다. Compact는 패킷 결정대로 폭을 자동 변경하지 않는다.
- 최초 로드와 배치 모드 전환에서는 저장된 크기와 사용자의 모드 전환 의도를 존중해 리사이즈하지 않고 트래커만 갱신한다.
- visible 패널 0개 또는 축 단위 0 경계에서는 리사이즈를 건너뛰어 divide-by-zero와 이상 크기를 방지한다.
- `powershell -ExecutionPolicy Bypass -File scripts\verify.ps1` 통과: `ALL PASS`, 경고 0개, 오류 0개.

### PF002 QA review

- Completed an independent zero-base QA review of the proportional-resize implementation.
- Confirmed the rendered row/column unit model is consistent across Vertical, Horizontal, Grid2x2, Compact, and Mini layouts, including first-load, mode-switch, and empty-layout guards.
- No defects found and no QA code changes required. `scripts/verify.ps1` passed with zero warnings/errors; PF002 is ready for final review and integration.
