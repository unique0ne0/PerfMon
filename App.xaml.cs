using System.Windows;
using System.Drawing;
using System.Windows.Forms;
using System.Runtime.InteropServices;

namespace PerfMonCS;

public partial class App : System.Windows.Application
{
    private MainWindow? _window;
    private NotifyIcon?  _tray;
    private Mutex?       _mutex;

    private bool _ownsMutex;

    protected override void OnStartup(StartupEventArgs e)
    {
        // 미처리 예외를 로그 파일에 기록
        DispatcherUnhandledException += (_, ex) =>
        {
            try
            {
                var log = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "PerfMonCS", "crash.log");
                System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(log)!);
                System.IO.File.AppendAllText(log, $"[{DateTime.Now}] {ex.Exception}\n\n");
            }
            catch { }
            ex.Handled = true;
        };

        _mutex = new Mutex(true, "PerfMonCS_SingleInstance", out bool isNew);
        _ownsMutex = isNew;
        if (!isNew) { _mutex.Dispose(); Shutdown(); return; }

        base.OnStartup(e);

        _window = new MainWindow();
        _window.Show();

        InitTray();
    }

    private void InitTray()
    {
        var icon = CreatePulseIcon();

        // 트레이 메뉴 = 오버레이와 동일한 통합 모델. 열릴 때마다 최신 체크 상태로 재구성.
        var menu = new ContextMenuStrip();
        menu.Opening += (_, _) =>
        {
            if (_window != null) MenuRenderer.FillForms(menu, _window.BuildMenuModel());
        };

        _tray = new NotifyIcon { Icon = icon, Text = "PerfMon Overlay", Visible = true, ContextMenuStrip = menu };
        _tray.DoubleClick += (_, _) => ToggleWindow();
    }

    private static Icon CreatePulseIcon()
    {
        // 32×32로 그려서 GetHicon → 시스템이 16×16으로 스케일 다운 (더 선명)
        using var bmp = new Bitmap(32, 32, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g   = Graphics.FromImage(bmp);
        g.Clear(System.Drawing.Color.Transparent);
        g.SmoothingMode    = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.PixelOffsetMode  = System.Drawing.Drawing2D.PixelOffsetMode.HighQuality;

        // ECG 펄스: 왼쪽 flat → 급격한 스파이크 → 오른쪽 flat
        var pts = new System.Drawing.PointF[]
        {
            new(0,  16),   // 왼쪽 베이스라인 시작
            new(8,  16),   // flat
            new(11, 10),   // 작은 선행 상승
            new(13,  4),   // 스파이크 정점
            new(15, 26),   // 하강 (베이스라인 아래)
            new(17, 16),   // 복귀
            new(32, 16),   // 오른쪽 flat 끝
        };

        using var pen = new System.Drawing.Pen(
            System.Drawing.Color.FromArgb(0, 210, 255), 2.5f);
        pen.LineJoin = System.Drawing.Drawing2D.LineJoin.Round;
        g.DrawLines(pen, pts);

        // 스파이크 정점에 밝은 점으로 강조
        using var dotBrush = new SolidBrush(System.Drawing.Color.FromArgb(180, 255, 255));
        g.FillEllipse(dotBrush, 11f, 2f, 4f, 4f);

        IntPtr hicon = bmp.GetHicon();
        try
        {
            using var tmp = Icon.FromHandle(hicon);
            return (Icon)tmp.Clone();
        }
        finally
        {
            DestroyIcon(hicon);
        }
    }

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr hIcon);

    public void FullExit()
    {
        _tray?.Dispose();
        Shutdown();
    }

    public void Restart()
    {
        var exe = Environment.ProcessPath;
        if (_ownsMutex)
        {
            try { _mutex?.ReleaseMutex(); } catch { }
            _mutex?.Dispose();
            _mutex = null;
            _ownsMutex = false;
        }
        if (exe != null) System.Diagnostics.Process.Start(exe);
        _tray?.Dispose();
        Shutdown();
    }

    public void ToggleWindow()
    {
        if (_window == null) return;
        if (_window.IsVisible) _window.Hide();
        else { _window.Show(); _window.Activate(); }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _tray?.Dispose();
        if (_ownsMutex) try { _mutex?.ReleaseMutex(); } catch { }
        _mutex?.Dispose();
        base.OnExit(e);
    }
}
