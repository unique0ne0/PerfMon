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
            System.IO.File.AppendAllText(@"d:\Git\PerfMonCS\crash.log",
                $"[{DateTime.Now}] {ex.Exception}\n\n");
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
        // 16x16 파란 원 아이콘 생성
        using var bmp = new Bitmap(16, 16);
        using (var g = Graphics.FromImage(bmp))
        {
            g.Clear(System.Drawing.Color.Transparent);
            g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
            g.FillEllipse(new SolidBrush(System.Drawing.Color.FromArgb(0, 195, 255)), 1, 1, 14, 14);
        }
        var icon = Icon.FromHandle(bmp.GetHicon());

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
        menu.Items.Add("완전 종료").Click += (_, _) => { _tray?.Dispose(); Shutdown(); };

        _tray = new NotifyIcon { Icon = icon, Text = "PerfMon Overlay", Visible = true, ContextMenuStrip = menu };
        _tray.DoubleClick += (_, _) => ToggleWindow();
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
