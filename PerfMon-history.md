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
