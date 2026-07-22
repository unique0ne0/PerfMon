using System.Diagnostics;
using System.Net.NetworkInformation;
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
    private readonly PerformanceCounter? _cpu;
    private readonly PerformanceCounter? _memAvail;
    private readonly PerformanceCounter? _diskRead;
    private readonly PerformanceCounter? _diskWrite;
    private List<PerformanceCounter> _netDownList = new();
    private List<PerformanceCounter> _netUpList   = new();
    private readonly object _netLock = new();
    private bool _disposed;
    private readonly float _totalMemMB;
    private float _lastCpu;
    private float _lastMemAvail;
    private float _lastDiskRead;
    private float _lastDiskWrite;

    public SystemMonitor()
    {
        try { _cpu      = new PerformanceCounter("Processor",    "% Processor Time",      "_Total", true); _cpu.NextValue(); }
        catch { _cpu = null; }

        try { _memAvail = new PerformanceCounter("Memory",       "Available MBytes",       true); }
        catch { _memAvail = null; }

        try { _diskRead  = new PerformanceCounter("PhysicalDisk", "Disk Read Bytes/sec",  "_Total", true); _diskRead.NextValue(); }
        catch { _diskRead = null; }

        try { _diskWrite = new PerformanceCounter("PhysicalDisk", "Disk Write Bytes/sec", "_Total", true); _diskWrite.NextValue(); }
        catch { _diskWrite = null; }

        _totalMemMB = GetTotalMemMB();
        RebuildNetCounters();
        NetworkChange.NetworkAddressChanged += OnNetworkAddressChanged;
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
    private static (List<PerformanceCounter> Down, List<PerformanceCounter> Up) CreateNetCounters()
    {
        var down = new List<PerformanceCounter>();
        var up = new List<PerformanceCounter>();
        try
        {
            var cat = new PerformanceCounterCategory("Network Interface");
            var instances = cat.GetInstanceNames();

            // 루프백·터널·가상 어댑터 제외
            string[] skip = ["Loopback", "Teredo", "isatap", "6TO4", "Pseudo", "Virtual", "WFP", "Bluetooth"];
            foreach (var iface in instances.Where(n =>
                !skip.Any(s => n.Contains(s, StringComparison.OrdinalIgnoreCase))))
            {
                PerformanceCounter? dn = null;
                PerformanceCounter? upCounter = null;
                try
                {
                    dn = new PerformanceCounter("Network Interface", "Bytes Received/sec", iface, true);
                    upCounter = new PerformanceCounter("Network Interface", "Bytes Sent/sec",     iface, true);
                    dn.NextValue(); upCounter.NextValue(); // 기준값 수립
                    down.Add(dn);
                    up.Add(upCounter);
                    dn = null;
                    upCounter = null;
                }
                catch
                {
                    dn?.Dispose();
                    upCounter?.Dispose();
                }
            }
        }
        catch { }
        return (down, up);
    }

    private void RebuildNetCounters()
    {
        var (down, up) = CreateNetCounters();
        List<PerformanceCounter>? oldDown = null;
        List<PerformanceCounter>? oldUp = null;
        bool disposeNew;
        lock (_netLock)
        {
            disposeNew = _disposed;
            if (!disposeNew)
            {
                oldDown = _netDownList;
                oldUp = _netUpList;
                _netDownList = down;
                _netUpList = up;
            }
        }
        (disposeNew ? down : oldDown!).ForEach(c => c.Dispose());
        (disposeNew ? up : oldUp!).ForEach(c => c.Dispose());
    }

    private void OnNetworkAddressChanged(object? sender, EventArgs e)
    {
        try { RebuildNetCounters(); } catch { }
    }

    private static float SafeNext(PerformanceCounter? c, ref float last)
    {
        if (c is null) return 0f;
        try
        {
            last = c.NextValue();
            return last;
        }
        catch
        {
            return last;
        }
    }

    // ── 데이터 수집 ───────────────────────────────────────────────────────
    public PerfData Collect()
    {
        float cpu = SafeNext(_cpu, ref _lastCpu);
        float dr  = SafeNext(_diskRead, ref _lastDiskRead) / 1_048_576f;
        float dw  = SafeNext(_diskWrite, ref _lastDiskWrite) / 1_048_576f;

        float netDn;
        float netUp;
        lock (_netLock)
        {
            netDn = _netDownList.Sum(c => { try { return c.NextValue(); } catch { return 0f; } }) / 1_024f;
            netUp = _netUpList  .Sum(c => { try { return c.NextValue(); } catch { return 0f; } }) / 1_024f;
        }

        // GlobalMemoryStatusEx 로 정확한 물리 메모리 가용량 조회
        var ms = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf<MEMORYSTATUSEX>() };
        float totalMB, availMB;
        if (GlobalMemoryStatusEx(ref ms))
        {
            totalMB = ms.ullTotalPhys / 1_048_576f;
            availMB = ms.ullAvailPhys / 1_048_576f;
        }
        else
        {
            totalMB = _totalMemMB;
            availMB = SafeNext(_memAvail, ref _lastMemAvail);
        }

        float used   = Math.Max(0f, totalMB - availMB);
        float memPct = totalMB > 0 ? used / totalMB * 100f : 0f;

        return new PerfData(
            Cpu:          cpu,
            MemPct:       Math.Clamp(memPct, 0f, 100f),
            MemUsedGB:    used / 1024f,
            MemTotalGB:   totalMB / 1024f,
            DiskReadMBs:  Math.Max(0f, dr),
            DiskWriteMBs: Math.Max(0f, dw),
            NetDownKBs:   Math.Max(0f, netDn),
            NetUpKBs:     Math.Max(0f, netUp),
            CpuTemp:      null);
    }

    public void Dispose()
    {
        NetworkChange.NetworkAddressChanged -= OnNetworkAddressChanged;
        List<PerformanceCounter> down;
        List<PerformanceCounter> up;
        lock (_netLock)
        {
            if (_disposed) return;
            _disposed = true;
            down = _netDownList;
            up = _netUpList;
            _netDownList = new();
            _netUpList = new();
        }
        _cpu?.Dispose();
        _memAvail?.Dispose();
        _diskRead?.Dispose();
        _diskWrite?.Dispose();
        down.ForEach(c => c.Dispose());
        up.ForEach(c => c.Dispose());
    }
}
