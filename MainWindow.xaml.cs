using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using WColor = System.Windows.Media.Color;
using HAlign = System.Windows.HorizontalAlignment;

namespace PerfMonCS;

public partial class MainWindow : Window
{
    private const double UNIT       = 38;  // 스케일 모드에서 SizeRatio 1.0 당 디자인 px
    private const double DESIGN_W   = 110; // 스케일 모드 디자인 폭(세로/2×2)
    private const double DESIGN_ROW = 60;  // 스케일 모드 가로배치 행 높이
    private double _designW = DESIGN_W;     // 현재 배치의 스케일 디자인 폭

    private readonly SystemMonitor   _monitor;
    private readonly DispatcherTimer _timer;
    private AppSettings _cfg = new();
    private bool        _savePending;
    private bool        _passThrough;
    private bool        _resizeActive;
    private bool        _loaded;
    private Viewbox?    _viewbox;

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

        Loaded += (_, _) => { LoadSettings(); _loaded = true; };
    }

    // 섹션 인덱스 0=CPU 1=MEM 2=DISK 3=NET 로 매핑되는 UI 요소
    private SectionSettings[]  Secs   => _cfg.Sections;
    private Grid[]             Panels => new[] { PanelCpu, PanelMem, PanelDisk, PanelNet };
    private FrameworkElement[] Hdrs   => new FrameworkElement[] { hdrCpu, hdrMem, hdrDisk, hdrNet };
    private FrameworkElement[] Labels => new FrameworkElement[] { lblCpu, lblMem, lblDisk, lblNet };
    private FrameworkElement[] Vals   => new FrameworkElement[] { valsCpu, valsMem, valsDisk, valsNet };
    private GraphControl[]     Graphs => new[] { gCpu, gMem, gDisk, gNet };

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

    // ── 전체 렌더 ────────────────────────────────────────────────────────
    public void RenderAll()
    {
        for (int i = 0; i < 4; i++) ConfigurePanel(i);
        ApplyArrangement();
        ApplyScale();

        Opacity = Math.Clamp(_cfg.Opacity, 0.1, 1.0);
        Topmost = _cfg.AlwaysOnTop;

        ContextMenu = BuildContextMenu();
    }

    private void ConfigurePanel(int i)
    {
        var s = Secs[i];
        Panels[i].Visibility = s.Visible    ? Visibility.Visible : Visibility.Collapsed;
        Labels[i].Visibility = s.ShowLabel  ? Visibility.Visible : Visibility.Collapsed;
        Vals[i].Visibility   = s.ShowValues ? Visibility.Visible : Visibility.Collapsed;

        var graph = Graphs[i];
        graph.BarMode = s.Graph == GraphKind.Bar;

        if (s.Overlay)
        {
            RestorePanelOverlay(Panels[i], Hdrs[i], graph);
            if (s.Graph == GraphKind.Bar)
            {
                Hdrs[i].VerticalAlignment = VerticalAlignment.Center;
                graph.Margin = new Thickness(0, 3, 0, 3);
            }
        }
        else
        {
            SplitPanel(Panels[i], Hdrs[i], graph);
        }
    }

    // 패널 내부 = 단일 셀(그래프 위에 헤더 겹침)
    private static void RestorePanelOverlay(Grid panel, FrameworkElement hdr, FrameworkElement graph)
    {
        panel.RowDefinitions.Clear();
        panel.ColumnDefinitions.Clear();
        Grid.SetRow(hdr, 0);   Grid.SetColumn(hdr, 0);
        Grid.SetRow(graph, 0); Grid.SetColumn(graph, 0);
        hdr.VerticalAlignment   = VerticalAlignment.Top;
        hdr.HorizontalAlignment = HAlign.Stretch;
        hdr.Margin = new Thickness(0, 0, 0, 2);
        graph.Margin = new Thickness(0);
    }

    // 패널 내부 = 텍스트(위) + 그래프(아래) 분리
    private static void SplitPanel(Grid panel, FrameworkElement hdr, FrameworkElement graph)
    {
        panel.RowDefinitions.Clear();
        panel.ColumnDefinitions.Clear();
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        Grid.SetRow(hdr, 0);   Grid.SetColumn(hdr, 0);
        Grid.SetRow(graph, 1); Grid.SetColumn(graph, 0);
        hdr.VerticalAlignment   = VerticalAlignment.Top;
        hdr.HorizontalAlignment = HAlign.Stretch;
        hdr.Margin = new Thickness(0);
        graph.Margin = new Thickness(0);
    }

    private static void Pos(UIElement e, int row, int col, int rSpan = 1, int cSpan = 1)
    {
        Grid.SetRow(e, row); Grid.SetColumn(e, col);
        Grid.SetRowSpan(e, rSpan); Grid.SetColumnSpan(e, cSpan);
    }

    private static GridLength GL(double px) => new(px);
    private static GridLength Star          => new(1, GridUnitType.Star);

    private RowDefinition    Row(double w) => new() { Height = _cfg.ScaleText ? GL(w * UNIT) : new GridLength(w, GridUnitType.Star) };
    private static ColumnDefinition Col(double w) => new() { Width = new GridLength(w, GridUnitType.Star) };

    private void ApplyArrangement()
    {
        MainGrid.RowDefinitions.Clear();
        MainGrid.ColumnDefinitions.Clear();
        foreach (var sep in new[] { Sep1, Sep2, Sep3, Sep4 }) sep.Visibility = Visibility.Collapsed;

        var vis = new System.Collections.Generic.List<int>();
        for (int i = 0; i < 4; i++) if (Secs[i].Visible) vis.Add(i);
        if (vis.Count == 0) return;

        switch (_cfg.Arrange)
        {
            case Arrangement.Horizontal: ArrangeHorizontal(vis); break;
            case Arrangement.Grid2x2:    ArrangeGrid(vis);       break;
            default:                     ArrangeVertical(vis);   break;
        }
    }

    private void ArrangeVertical(System.Collections.Generic.List<int> vis)
    {
        _designW = DESIGN_W;
        MainGrid.ColumnDefinitions.Add(Col(1));
        var seps = new[] { Sep1, Sep2, Sep3, Sep4 };
        int row = 0, sep = 0;
        for (int k = 0; k < vis.Count; k++)
        {
            MainGrid.RowDefinitions.Add(Row(Secs[vis[k]].SizeRatio));
            Pos(Panels[vis[k]], row, 0);
            row++;
            if (k < vis.Count - 1)
            {
                MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1) });
                Pos(seps[sep], row, 0);
                seps[sep].Visibility = Visibility.Visible;
                sep++; row++;
            }
        }
    }

    private void ArrangeHorizontal(System.Collections.Generic.List<int> vis)
    {
        _designW = 60 * vis.Count;
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = _cfg.ScaleText ? GL(DESIGN_ROW) : Star });
        var seps = new[] { Sep1, Sep2, Sep3, Sep4 };
        int col = 0, sep = 0;
        for (int k = 0; k < vis.Count; k++)
        {
            MainGrid.ColumnDefinitions.Add(Col(Secs[vis[k]].SizeRatio));
            Pos(Panels[vis[k]], 0, col);
            col++;
            if (k < vis.Count - 1)
            {
                MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GL(1) });
                Pos(seps[sep], 0, col);
                seps[sep].Visibility = Visibility.Visible;
                sep++; col++;
            }
        }
    }

    private void ArrangeGrid(System.Collections.Generic.List<int> vis)
    {
        _designW = DESIGN_W;
        int n = vis.Count;
        int cols = n >= 2 ? 2 : 1;
        int rows = (n + cols - 1) / cols;

        var cw = new double[cols];
        var rw = new double[rows];
        for (int k = 0; k < n; k++)
        {
            int r = k / cols, c = k % cols;
            double ratio = Secs[vis[k]].SizeRatio;
            cw[c] = Math.Max(cw[c], ratio);
            rw[r] = Math.Max(rw[r], ratio);
        }

        for (int c = 0; c < cols; c++)
        {
            MainGrid.ColumnDefinitions.Add(Col(cw[c]));
            if (c < cols - 1) MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GL(1) });
        }
        for (int r = 0; r < rows; r++)
        {
            MainGrid.RowDefinitions.Add(Row(rw[r]));
            if (r < rows - 1) MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1) });
        }

        for (int k = 0; k < n; k++)
        {
            int r = k / cols, c = k % cols;
            Pos(Panels[vis[k]], r * 2, c * 2);
        }

        if (cols == 2) { Pos(Sep4, 0, 1, rows * 2 - 1, 1); Sep4.Visibility = Visibility.Visible; }
        if (rows == 2) { Pos(Sep1, 1, 0, 1, cols * 2 - 1); Sep1.Visibility = Visibility.Visible; }
    }

    // 글자 스케일(Viewbox) on/off 에 따라 MainGrid 재배치
    private void ApplyScale()
    {
        DetachMainGrid();
        HostGrid.Children.Clear();

        if (_cfg.ScaleText)
        {
            MainGrid.Width  = _designW;
            MainGrid.Height = double.NaN;
            _viewbox = new Viewbox { Stretch = Stretch.Fill, Child = MainGrid };
            HostGrid.Children.Add(_viewbox);
        }
        else
        {
            _viewbox = null;
            MainGrid.Width  = double.NaN;
            MainGrid.Height = double.NaN;
            MainGrid.HorizontalAlignment = HAlign.Stretch;
            MainGrid.VerticalAlignment   = VerticalAlignment.Stretch;
            HostGrid.Children.Add(MainGrid);
        }
    }

    private void DetachMainGrid()
    {
        switch (MainGrid.Parent)
        {
            case Viewbox vb:  vb.Child = null;                            break;
            case System.Windows.Controls.Panel p: p.Children.Remove(MainGrid); break;
            case Decorator d: d.Child = null;                             break;
        }
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
        if (!_loaded || _savePending) return;
        _savePending = true;
        Dispatcher.InvokeAsync(() =>
        {
            _cfg.X = Left; _cfg.Y = Top; _cfg.W = Width; _cfg.H = Height;
            SettingsManager.Save(_cfg);
            _savePending = false;
        }, DispatcherPriority.Background);
    }

    // ── 설정 로드 ────────────────────────────────────────────────────────
    private void LoadSettings()
    {
        _cfg = SettingsManager.Load();

        double x = _cfg.X ?? (SystemParameters.WorkArea.Right - Width - 10);
        double y = _cfg.Y ?? 10;
        if (x >= SystemParameters.VirtualScreenLeft &&
            x < SystemParameters.VirtualScreenLeft + SystemParameters.VirtualScreenWidth)
            Left = x;
        if (y >= SystemParameters.VirtualScreenTop &&
            y < SystemParameters.VirtualScreenTop + SystemParameters.VirtualScreenHeight)
            Top = y;

        if (_cfg.W.HasValue) Width  = Math.Max(MinWidth,  _cfg.W.Value);
        if (_cfg.H.HasValue) Height = Math.Max(MinHeight, _cfg.H.Value);

        _timer.Interval = TimeSpan.FromMilliseconds(Math.Clamp(_cfg.UpdateMs, 250, 5000));

        RenderAll();
    }

    // ── 설정 창 열기 ─────────────────────────────────────────────────────
    private void OpenSettings()
    {
        var dlg = new SettingsWindow(_cfg.Clone()) { Owner = this };
        if (dlg.ShowDialog() == true)
        {
            _cfg = dlg.Result;
            _timer.Interval = TimeSpan.FromMilliseconds(Math.Clamp(_cfg.UpdateMs, 250, 5000));
            RenderAll();
            SettingsManager.Save(_cfg);
        }
    }

    private void QuickApply()
    {
        RenderAll();
        SettingsManager.Save(_cfg);
    }

    // ── 컨텍스트 메뉴 (빠른 토글 + 설정창) ───────────────────────────────
    public ContextMenu BuildContextMenu()
    {
        var menu = new ContextMenu();

        var settings = new MenuItem { Header = "설정..." };
        settings.Click += (_, _) => OpenSettings();
        menu.Items.Add(settings);

        menu.Items.Add(new Separator());

        var opHeader = new MenuItem { Header = "투명도", IsEnabled = false };
        menu.Items.Add(opHeader);
        foreach (var (label, val) in new (string, double)[]
            { ("30%", 0.3), ("50%", 0.5), ("70%", 0.7), ("85%", 0.85), ("100%", 1.0) })
        {
            double v = val;
            var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = Math.Abs(_cfg.Opacity - v) < 0.001 };
            item.Click += (_, _) => { _cfg.Opacity = v; Opacity = v; SettingsManager.Save(_cfg); };
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());

        var aot = new MenuItem { Header = "항상 위 표시", IsCheckable = true, IsChecked = _cfg.AlwaysOnTop };
        aot.Click += (_, _) => { _cfg.AlwaysOnTop = aot.IsChecked; Topmost = aot.IsChecked; SettingsManager.Save(_cfg); };
        menu.Items.Add(aot);

        var passItem = new MenuItem { Header = "클릭 무시 (Pass Through)", IsCheckable = true, IsChecked = _passThrough };
        passItem.Click += (_, _) => SetPassThrough(passItem.IsChecked);
        menu.Items.Add(passItem);

        var resizeItem = new MenuItem { Header = "사이즈 조절 모드", IsCheckable = true, IsChecked = _resizeActive };
        resizeItem.Click += (_, _) => SetResizeActive(resizeItem.IsChecked);
        menu.Items.Add(resizeItem);

        menu.Items.Add(new Separator());

        var arrHeader = new MenuItem { Header = "배치", IsEnabled = false };
        menu.Items.Add(arrHeader);
        foreach (var (label, mode) in new (string, Arrangement)[]
            { ("세로 1열", Arrangement.Vertical), ("2×2 그리드", Arrangement.Grid2x2), ("가로 1줄", Arrangement.Horizontal) })
        {
            var m = mode;
            var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = _cfg.Arrange == mode };
            item.Click += (_, _) => { _cfg.Arrange = m; QuickApply(); };
            menu.Items.Add(item);
        }

        menu.Items.Add(new Separator());

        var panelHeader = new MenuItem { Header = "패널 표시", IsEnabled = false };
        menu.Items.Add(panelHeader);
        foreach (var (label, idx) in new (string, int)[]
            { ("CPU", 0), ("메모리", 1), ("디스크", 2), ("네트워크", 3) })
        {
            int i = idx;
            var item = new MenuItem { Header = label, IsCheckable = true, IsChecked = Secs[i].Visible };
            item.Click += (_, _) => { Secs[i].Visible = item.IsChecked; QuickApply(); };
            menu.Items.Add(item);
        }

        bool allVals = _cfg.Sections.All(s => s.ShowValues);
        var valuesItem = new MenuItem { Header = "수치 보기", IsCheckable = true, IsChecked = allVals };
        valuesItem.Click += (_, _) =>
        {
            bool on = valuesItem.IsChecked;
            foreach (var s in _cfg.Sections) s.ShowValues = on;
            QuickApply();
        };
        menu.Items.Add(valuesItem);

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
