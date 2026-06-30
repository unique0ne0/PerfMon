using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using WColor = System.Windows.Media.Color;

namespace PerfMonCS;

public enum LayoutMode { Vertical = 0, Grid2x2 = 1, Compact = 2 }

public partial class MainWindow : Window
{
    private readonly SystemMonitor   _monitor;
    private readonly DispatcherTimer _timer;
    private bool        _savePending;
    private bool        _passThrough;
    private bool        _resizeActive;
    private LayoutMode  _layoutMode = LayoutMode.Vertical;
    private MenuItem[]? _layoutMenuItems;

    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr h, int n);
    [DllImport("user32.dll")] static extern int SetWindowLong(IntPtr h, int n, int v);
    private const int GWL_EXSTYLE       = -20;
    private const int WS_EX_TRANSPARENT = 0x20;

    public MainWindow()
    {
        InitializeComponent();

        _monitor = new SystemMonitor();

        _timer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
        _timer.Tick += OnTick;
        _timer.Start();

        Loaded += (_, _) => { LoadSettings(); ContextMenu = BuildContextMenu(); };
    }

    // ── Pass Through ─────────────────────────────────────────────────────
    public bool IsPassThrough => _passThrough;

    public void SetPassThrough(bool on)
    {
        _passThrough = on;
        var hwnd = new WindowInteropHelper(this).Handle;
        int style = GetWindowLong(hwnd, GWL_EXSTYLE);
        SetWindowLong(hwnd, GWL_EXSTYLE, on ? (style | WS_EX_TRANSPARENT) : (style & ~WS_EX_TRANSPARENT));
        UpdateBorderHint();
    }

    // ── Resize Mode ──────────────────────────────────────────────────────
    public void SetResizeActive(bool on)
    {
        _resizeActive = on;
        ResizeMode = on ? ResizeMode.CanResizeWithGrip : ResizeMode.NoResize;
        UpdateBorderHint();
    }

    private void UpdateBorderHint()
    {
        RootBorder.BorderBrush = (_resizeActive, _passThrough) switch
        {
            (true,  _)     => new SolidColorBrush(WColor.FromArgb(0x70, 0x00, 0xFF, 0xFF)),
            (false, true)  => new SolidColorBrush(WColor.FromArgb(0x55, 0xFF, 0x90, 0x00)),
            _              => new SolidColorBrush(WColor.FromArgb(0x12, 0xFF, 0xFF, 0xFF)),
        };
    }

    // ── 레이아웃 전환 ────────────────────────────────────────────────────
    public void SetLayout(LayoutMode mode, bool resetSize = true)
    {
        _layoutMode = mode;

        PanelCpu.Visibility = PanelMem.Visibility =
        PanelDisk.Visibility = PanelNet.Visibility = Visibility.Visible;

        MainGrid.RowDefinitions.Clear();
        MainGrid.ColumnDefinitions.Clear();

        switch (mode)
        {
            case LayoutMode.Vertical: ApplyVerticalLayout(resetSize);  break;
            case LayoutMode.Grid2x2:  ApplyGrid2x2Layout(resetSize);   break;
            case LayoutMode.Compact:  ApplyCompactLayout(resetSize);   break;
        }

        if (_layoutMenuItems != null)
            for (int i = 0; i < _layoutMenuItems.Length; i++)
                _layoutMenuItems[i].IsChecked = (LayoutMode)i == mode;
    }

    // 패널 내부를 단일 셀(겹침) 구조로 복원 — Vertical/2x2 용
    private static void RestorePanelOverlay(Grid panel, FrameworkElement hdr, UIElement graph)
    {
        panel.RowDefinitions.Clear();
        Grid.SetRow(hdr, 0);
        Grid.SetRow(graph, 0);
        hdr.VerticalAlignment = VerticalAlignment.Top;
    }

    // 패널 내부를 텍스트(Auto) + 그래프(*) 2행으로 분리 — Compact 용
    private static void SplitPanel(Grid panel, FrameworkElement hdr, UIElement graph)
    {
        panel.RowDefinitions.Clear();
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(hdr, 0);
        Grid.SetRow(graph, 1);
        hdr.VerticalAlignment = VerticalAlignment.Top;
    }

    private static void Pos(UIElement e, int row, int col, int rSpan = 1, int cSpan = 1)
    {
        Grid.SetRow(e, row); Grid.SetColumn(e, col);
        Grid.SetRowSpan(e, rSpan); Grid.SetColumnSpan(e, cSpan);
    }

    private static GridLength GL(double px) => new(px);
    private static GridLength Star           => new(1, GridUnitType.Star);

    private void ApplyVerticalLayout(bool resetSize)
    {
        // 패널 내부 오버레이 구조 복원
        RestorePanelOverlay(PanelCpu,  hdrCpu,  gCpu);
        RestorePanelOverlay(PanelMem,  hdrMem,  gMem);
        RestorePanelOverlay(PanelDisk, hdrDisk, gDisk);
        RestorePanelOverlay(PanelNet,  hdrNet,  gNet);
        hdrCpu.Margin = new Thickness(0, 0, 0, 2);
        hdrMem.Margin = new Thickness(0, 0, 0, 2);

        // 7 rows: *, 1, *, 1, *, 1, *
        for (int i = 0; i < 4; i++)
        {
            MainGrid.RowDefinitions.Add(new RowDefinition { Height = Star });
            if (i < 3) MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1) });
        }

        Pos(Sep1, 1, 0); Pos(Sep2, 3, 0); Pos(Sep3, 5, 0);
        Sep1.Visibility = Sep2.Visibility = Sep3.Visibility = Visibility.Visible;
        Sep4.Visibility = Visibility.Collapsed;

        Pos(PanelCpu, 0, 0); Pos(PanelMem, 2, 0);
        Pos(PanelDisk, 4, 0); Pos(PanelNet, 6, 0);

        gCpu.BarMode = false; gMem.BarMode = false;
        MinWidth = 62; MinHeight = 120;
        if (resetSize) { Width = Math.Max(MinWidth, Width); Height = Math.Max(240, Height); }
    }

    private void ApplyGrid2x2Layout(bool resetSize)
    {
        RestorePanelOverlay(PanelCpu,  hdrCpu,  gCpu);
        RestorePanelOverlay(PanelMem,  hdrMem,  gMem);
        RestorePanelOverlay(PanelDisk, hdrDisk, gDisk);
        RestorePanelOverlay(PanelNet,  hdrNet,  gNet);
        hdrCpu.Margin = new Thickness(0, 0, 0, 2);
        hdrMem.Margin = new Thickness(0, 0, 0, 2);

        // 3 rows: *, 1, *  |  3 cols: *, 1, *
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = Star });
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1) });
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = Star });
        MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star });
        MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GL(1) });
        MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star });

        Pos(Sep1, 1, 0, 1, 3); Sep1.Visibility = Visibility.Visible;
        Pos(Sep4, 0, 1, 3, 1); Sep4.Visibility = Visibility.Visible;
        Sep2.Visibility = Sep3.Visibility = Visibility.Collapsed;

        Pos(PanelCpu,  0, 0); Pos(PanelMem,  0, 2);
        Pos(PanelDisk, 2, 0); Pos(PanelNet,  2, 2);

        gCpu.BarMode = false; gMem.BarMode = false;
        MinWidth = 80; MinHeight = 80;
        if (resetSize) { Width = Math.Max(MinWidth, Width); Height = 130; }
    }

    private void ApplyCompactLayout(bool resetSize)
    {
        // CPU/MEM: 텍스트 위 + 막대 아래 (비겹침)
        SplitPanel(PanelCpu,  hdrCpu,  gCpu);
        SplitPanel(PanelMem,  hdrMem,  gMem);
        // DISK/NET: 텍스트 위 + 그래프 아래 (비겹침)
        SplitPanel(PanelDisk, hdrDisk, gDisk);
        SplitPanel(PanelNet,  hdrNet,  gNet);
        hdrCpu.Margin = new Thickness(0);
        hdrMem.Margin = new Thickness(0);

        // 5 rows: 26, 1, 26, 1, *  |  3 cols: *, 1, *
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(26) }); // CPU (텍스트+바)
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1)  });
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(26) }); // MEM (텍스트+바)
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1)  });
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = Star   }); // DISK + NET
        MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star });
        MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GL(1) });
        MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = Star });

        Pos(Sep1, 1, 0, 1, 3); Sep1.Visibility = Visibility.Visible;
        Pos(Sep2, 3, 0, 1, 3); Sep2.Visibility = Visibility.Visible;
        Pos(Sep4, 4, 1, 1, 1); Sep4.Visibility = Visibility.Visible;
        Sep3.Visibility = Visibility.Collapsed;

        Pos(PanelCpu,  0, 0, 1, 3);
        Pos(PanelMem,  2, 0, 1, 3);
        Pos(PanelDisk, 4, 0);
        Pos(PanelNet,  4, 2);

        gCpu.BarMode = true; gMem.BarMode = true;
        MinWidth = 80; MinHeight = 80;
        if (resetSize) { Width = Math.Max(MinWidth, Width); Height = 140; }
    }

    // ── 데이터 수집 ──────────────────────────────────────────────────────
    private void OnTick(object? sender, EventArgs e)
    {
        var d = _monitor.Collect();

        vCpu.Text   = $"{d.Cpu:F0}%";
        vTemp.Text  = d.CpuTemp.HasValue ? $"{d.CpuTemp:F0}°" : "";
        vMem.Text   = $"{d.MemPct:F0}%";
        vMemGB.Text = $"{d.MemUsedGB:F1}G";
        vDR.Text    = FmtMB(d.DiskReadMBs);
        vDW.Text    = FmtMB(d.DiskWriteMBs);
        vNDn.Text   = FmtKB(d.NetDownKBs);
        vNUp.Text   = FmtKB(d.NetUpKBs);

        gCpu.Push(d.Cpu);
        gMem.Push(d.MemPct);
        gDisk.Push(d.DiskReadMBs, d.DiskWriteMBs);
        gNet.Push(d.NetDownKBs,   d.NetUpKBs);
    }

    private static string FmtMB(float v)
    {
        if (v >= 1000) return $"{v / 1024:F1}G";
        if (v >= 100)  return $"{v:F0}M";
        if (v >= 1)    return $"{v:F1}M";
        return $"{v * 1024:F0}K";
    }

    private static string FmtKB(float v)
    {
        if (v >= 1024) return $"{v / 1024:F1}M";
        return $"{v:F0}K";
    }

    // ── 창 드래그 / 상태 저장 ───────────────────────────────────────────
    private void OnDrag(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed) DragMove();
    }

    private void OnStateChanged(object? sender, EventArgs e)
    {
        if (_savePending) return;
        _savePending = true;
        Dispatcher.InvokeAsync(() => { SettingsManager.Save(BuildSettings()); _savePending = false; },
            DispatcherPriority.Background);
    }

    // ── 설정 로드/저장 ──────────────────────────────────────────────────
    private void LoadSettings()
    {
        var s = SettingsManager.Load();

        if (s.Layout.HasValue)
            SetLayout((LayoutMode)Math.Clamp(s.Layout.Value, 0, 2), resetSize: false);

        double x = s.X ?? (SystemParameters.WorkArea.Right - Width - 10);
        double y = s.Y ?? 10;
        if (x >= SystemParameters.VirtualScreenLeft &&
            x < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth)
            Left = x;
        if (y >= SystemParameters.VirtualScreenTop &&
            y < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight)
            Top = y;

        if (s.W.HasValue) Width  = Math.Max(MinWidth,  s.W.Value);
        if (s.H.HasValue) Height = Math.Max(MinHeight, s.H.Value);
        if (s.Opacity.HasValue) Opacity = Math.Clamp(s.Opacity.Value, 0.1, 1.0);
    }

    private AppSettings BuildSettings() =>
        new(Left, Top, Width, Height, Opacity, (int)_layoutMode);

    // ── 패널 행 전체 토글 ───────────────────────────────────────────────
    private void TogglePanel(UIElement panel, bool show, int panelRow, int sepRow)
    {
        panel.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
        if (_layoutMode == LayoutMode.Vertical)
        {
            MainGrid.RowDefinitions[panelRow].Height =
                show ? new GridLength(1, GridUnitType.Star) : new GridLength(0);
            if (sepRow >= 0)
                MainGrid.RowDefinitions[sepRow].Height =
                    show ? new GridLength(1) : new GridLength(0);
        }
    }

    // ── 컨텍스트 메뉴 ────────────────────────────────────────────────────
    public ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();

        var opHeader = new MenuItem { Header = "투명도", IsEnabled = false };
        menu.Items.Add(opHeader);
        foreach (var (label, val) in new (string, double)[]
            { ("30%", 0.3), ("50%", 0.5), ("70%", 0.7), ("85%", 0.85), ("100%", 1.0) })
        {
            double v = val;
            var item = new MenuItem { Header = label };
            item.Click += (_, _) => { Opacity = v; SettingsManager.Save(BuildSettings()); };
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());

        var aot = new MenuItem { Header = "항상 위 표시", IsCheckable = true, IsChecked = true };
        aot.Click += (_, _) => Topmost = aot.IsChecked;
        menu.Items.Add(aot);

        var passItem = new MenuItem { Header = "클릭 무시 (Pass Through)", IsCheckable = true };
        passItem.Click += (_, _) => SetPassThrough(passItem.IsChecked);
        menu.Items.Add(passItem);

        var resizeItem = new MenuItem { Header = "사이즈 조절 모드", IsCheckable = true };
        resizeItem.Click += (_, _) => SetResizeActive(resizeItem.IsChecked);
        menu.Items.Add(resizeItem);

        menu.Items.Add(new Separator());

        var layoutHeader = new MenuItem { Header = "레이아웃", IsEnabled = false };
        menu.Items.Add(layoutHeader);
        var layoutDefs = new (string Label, LayoutMode Mode)[]
        {
            ("세로 1열",    LayoutMode.Vertical),
            ("2×2 그리드",  LayoutMode.Grid2x2),
            ("컴팩트",      LayoutMode.Compact),
        };
        _layoutMenuItems = new MenuItem[layoutDefs.Length];
        for (int i = 0; i < layoutDefs.Length; i++)
        {
            var (label, mode) = layoutDefs[i];
            var m = mode; int idx = i;
            var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = _layoutMode == mode };
            item.Click += (_, _) => { SetLayout(m); SettingsManager.Save(BuildSettings()); };
            _layoutMenuItems[idx] = item;
            menu.Items.Add(item);
        }

        menu.Items.Add(new Separator());

        foreach (var (label, panel, pRow, sRow) in new (string, UIElement, int, int)[]
        {
            ("CPU 패널",      PanelCpu,  0,  1),
            ("메모리 패널",   PanelMem,  2,  3),
            ("디스크 패널",   PanelDisk, 4,  5),
            ("네트워크 패널", PanelNet,  6, -1),
        })
        {
            var el = panel; var pr = pRow; var sr = sRow;
            var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = true };
            item.Click += (_, _) => TogglePanel(el, item.IsChecked, pr, sr);
            menu.Items.Add(item);
        }

        menu.Items.Add(new Separator());

        var hide = new MenuItem { Header = "숨기기" };
        hide.Click += (_, _) => Hide();
        menu.Items.Add(hide);

        return menu;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }

    protected override void OnClosed(EventArgs e)
    {
        _timer.Stop();
        _monitor.Dispose();
        base.OnClosed(e);
    }
}
