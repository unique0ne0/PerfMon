using System.Windows;
using System.Drawing;
using System.Windows.Forms;

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
            var log = System.IO.Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                "PerfMonCS", "crash.log");
            System.IO.File.AppendAllText(log, $"[{DateTime.Now}] {ex.Exception}\n\n");
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

        var menu = new ContextMenuStrip();
        menu.Items.Add("보이기 / 숨기기").Click += (_, _) => ToggleWindow();
        menu.Items.Add(new ToolStripSeparator());

        var passThru = new ToolStripMenuItem("클릭 무시 (Pass Through)") { CheckOnClick = true };
        passThru.CheckedChanged += (_, _) => _window?.SetPassThrough(passThru.Checked);
        menu.Opening += (_, _) => passThru.Checked = _window?.IsPassThrough ?? false;
        menu.Items.Add(passThru);
        menu.Items.Add(new ToolStripSeparator());

        var autoStart = new ToolStripMenuItem("시작프로그램 등록") { CheckOnClick = true, Checked = AutoStartHelper.IsEnabled() };
        autoStart.CheckedChanged += (_, _) => AutoStartHelper.Set(autoStart.Checked);
        menu.Items.Add(autoStart);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripSeparator());

        var savePos = new ToolStripMenuItem("현재 위치 저장");
        savePos.Click += (_, _) => _window?.SavePosition();
        menu.Items.Add(savePos);

        var restorePos = new ToolStripMenuItem("위치 복구");
        restorePos.Click += (_, _) => _window?.RestorePosition();
        menu.Items.Add(restorePos);

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("완전 종료").Click += (_, _) => FullExit();

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

        return Icon.FromHandle(bmp.GetHicon());
    }

    public void FullExit()
    {
        _tray?.Dispose();
        Shutdown();
    }

    public void Restart()
    {
        var exe = Environment.ProcessPath;
        if (exe != null) System.Diagnostics.Process.Start(exe);
        _tray?.Dispose();
        Shutdown();
    }

    private void ToggleWindow()
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
