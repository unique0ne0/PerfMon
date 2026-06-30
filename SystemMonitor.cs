using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PerfMonCS;

public record PerfData(
    float Cpu,
    float MemPct,
    float MemUsedGB,
    float MemTotalGB,
    float DiskReadMBs,
    float DiskWriteMBs,
    float NetDownKBs,
    float NetUpKBs,
    float? CpuTemp);

public sealed class SystemMonitor : IDisposable
{
    private readonly PerformanceCounter _cpu;
    private readonly PerformanceCounter _memAvail;
    private readonly PerformanceCounter _diskRead;
    private readonly PerformanceCounter _diskWrite;
    private readonly List<PerformanceCounter> _netDownList = new();
    private readonly List<PerformanceCounter> _netUpList   = new();
    private readonly float _totalMemMB;

    public SystemMonitor()
    {
        try { _cpu      = new PerformanceCounter("Processor",    "% Processor Time",      "_Total", true); _cpu.NextValue(); }
        catch { _cpu = null!; }

        try { _memAvail = new PerformanceCounter("Memory",       "Available MBytes",       true); }
        catch { _memAvail = null!; }

        try { _diskRead  = new PerformanceCounter("PhysicalDisk", "Disk Read Bytes/sec",  "_Total", true); _diskRead.NextValue(); }
        catch { _diskRead = null!; }

        try { _diskWrite = new PerformanceCounter("PhysicalDisk", "Disk Write Bytes/sec", "_Total", true); _diskWrite.NextValue(); }
        catch { _diskWrite = null!; }

        _totalMemMB = GetTotalMemMB();
        InitNetCounters();
    }

    // ── 전체 메모리 (P/Invoke) ─────────────────────────────────────────────
    [StructLayout(LayoutKind.Sequential)]
    private struct MEMORYSTATUSEX
    {
        public uint  dwLength;
        public uint  dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);

    private static float GetTotalMemMB()
    {
        var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        return GlobalMemoryStatusEx(ref m) ? m.ullTotalPhys / 1_048_576f : 0f;
    }

    // ── 네트워크 카운터 초기화 (모든 물리 인터페이스 합산) ──────────────────
    private void InitNetCounters()
    {
        try
        {
            var cat = new PerformanceCounterCategory("Network Interface");
            var instances = cat.GetInstanceNames();

            // 루프백·터널·가상 어댑터 제외
            string[] skip = ["Loopback", "Teredo", "isatap", "6TO4", "Pseudo", "Virtual", "WFP", "Bluetooth"];
            foreach (var iface in instances.Where(n =>
                !skip.Any(s => n.Contains(s, StringComparison.OrdinalIgnoreCase))))
            {
                try
                {
                    var dn = new PerformanceCounter("Network Interface", "Bytes Received/sec", iface, true);
                    var up = new PerformanceCounter("Network Interface", "Bytes Sent/sec",     iface, true);
                    dn.NextValue(); up.NextValue(); // 기준값 수립
                    _netDownList.Add(dn);
                    _netUpList.Add(up);
                }
                catch { }
            }
        }
        catch { }
    }

    // ── 데이터 수집 ───────────────────────────────────────────────────────
    public PerfData Collect()
    {
        float cpu    = _cpu      is null ? 0f : _cpu.NextValue();
        float avail  = _memAvail is null ? 0f : _memAvail.NextValue();
        float dr     = _diskRead  is null ? 0f : _diskRead.NextValue()  / 1_048_576f;
        float dw     = _diskWrite is null ? 0f : _diskWrite.NextValue() / 1_048_576f;

        float netDn = _netDownList.Sum(c => { try { return c.NextValue(); } catch { return 0f; } }) / 1_024f;
        float netUp = _netUpList  .Sum(c => { try { return c.NextValue(); } catch { return 0f; } }) / 1_024f;

        float used   = _totalMemMB - avail;
        float memPct = _totalMemMB > 0 ? used / _totalMemMB * 100f : 0f;

        return new PerfData(
            Cpu:          cpu,
            MemPct:       Math.Clamp(memPct, 0f, 100f),
            MemUsedGB:    used / 1024f,
            MemTotalGB:   _totalMemMB / 1024f,
            DiskReadMBs:  Math.Max(0f, dr),
            DiskWriteMBs: Math.Max(0f, dw),
            NetDownKBs:   Math.Max(0f, netDn),
            NetUpKBs:     Math.Max(0f, netUp),
            CpuTemp:      null);
    }

    public void Dispose()
    {
        _cpu?.Dispose();
        _memAvail?.Dispose();
        _diskRead?.Dispose();
        _diskWrite?.Dispose();
        _netDownList.ForEach(c => c.Dispose());
        _netUpList.ForEach(c => c.Dispose());
    }
}
