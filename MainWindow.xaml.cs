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

    private static readonly Thickness[] PanelMargin =
    {
        new(4,3,4,2), // CPU
        new(4,3,4,2), // MEM
        new(4,3,4,1), // DISK
        new(4,3,4,2), // NET
    };

    private readonly SystemMonitor   _monitor;
    private readonly DispatcherTimer _timer;
    private AppSettings _cfg = new();
    private bool        _savePending;
    private bool        _passThrough;
    private bool        _resizeActive;
    private bool        _loaded;
    private Viewbox?    _viewbox;
    private double      _labelColW = 30;

    [DllImport("user32.dll")] static extern int  GetWindowLong(IntPtr h, int n);
    [DllImport("user32.dll")] static extern int  SetWindowLong(IntPtr h, int n, int v);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    private const int  GWL_EXSTYLE       = -20;
    private const int  WS_EX_TRANSPARENT = 0x20;
    private static readonly IntPtr HWND_TOPMOST   = new(-1);
    private static readonly IntPtr HWND_NOTOPMOST = new(-2);
    private const uint SWP_NOMOVE     = 0x0002;
    private const uint SWP_NOSIZE     = 0x0001;
    private const uint SWP_NOACTIVATE = 0x0010;

    // WM_WINDOWPOSCHANGING 후킹 — Windows가 Z-order를 바꾸려 할 때 TOPMOST 강제 유지
    private const int WM_WINDOWPOSCHANGING = 0x0046;
    [StructLayout(LayoutKind.Sequential)]
    private struct WINDOWPOS { public IntPtr hwnd, hwndInsertAfter; public int x, y, cx, cy, flags; }

    // 작업표시줄 클릭 시 작업표시줄이 topmost 밴드 맨 위로 올라가는데, 이때 우리 창에는
    // 아무 메시지도 오지 않음 → 전역 포그라운드 전환 이벤트를 받아 즉시 TOPMOST 재주장
    [DllImport("user32.dll")] static extern IntPtr SetWinEventHook(uint evMin, uint evMax, IntPtr hmod, WinEventDelegate proc, uint pid, uint tid, uint flags);
    [DllImport("user32.dll")] static extern bool UnhookWinEvent(IntPtr hHook);
    private delegate void WinEventDelegate(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time);
    private const uint EVENT_SYSTEM_FOREGROUND = 0x0003;
    private WinEventDelegate? _fgHookProc; // GC 수거 방지용 참조
    private IntPtr _fgHook;

    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        HwndSource.FromHwnd(new WindowInteropHelper(this).Handle)?.AddHook(WndProc);

        _fgHookProc = OnForegroundChanged;
        _fgHook = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND,
            IntPtr.Zero, _fgHookProc, 0, 0, 0 /* WINEVENT_OUTOFCONTEXT */);
    }

    private void OnForegroundChanged(IntPtr hHook, uint ev, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (_cfg.AlwaysOnTop && hwnd != new WindowInteropHelper(this).Handle)
            AssertTopmost();
    }

    private void AssertTopmost()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero)
            SetWindowPos(hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == WM_WINDOWPOSCHANGING && _cfg.AlwaysOnTop)
        {
            var pos = Marshal.PtrToStructure<WINDOWPOS>(lParam);
            if (pos.hwndInsertAfter != HWND_TOPMOST)
            {
                pos.hwndInsertAfter = HWND_TOPMOST;
                Marshal.StructureToPtr(pos, lParam, false);
            }
        }
        return IntPtr.Zero;
    }

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

    // ── Always On Top (Win32 직접 호출 — 작업표시줄 위에서도 유지) ──────
    public void ApplyAlwaysOnTop(bool on)
    {
        Topmost = on;
        if (on) { AssertTopmost(); return; }
        var hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd != IntPtr.Zero)
            SetWindowPos(hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
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
        bool isCompact = _cfg.Arrange == Arrangement.Compact;
        bool isMini    = _cfg.Arrange == Arrangement.Mini;
        _labelColW = ComputeLabelColWidth();
        for (int i = 0; i < 4; i++)
        {
            if (isMini)         ConfigurePanelMini(i);
            else if (isCompact) ConfigurePanelCompact(i);
            else                ConfigurePanel(i);
        }
        ApplyArrangement();
        ApplyScale();
        ApplyMemDisplayMode();

        Opacity = Math.Clamp(_cfg.Opacity, 0.1, 1.0);
        ApplyAlwaysOnTop(_cfg.AlwaysOnTop);

        ApplyFontSizes();
        ApplyMinSize();
        ContextMenu = BuildContextMenu();
    }

    // 섹션별 실제 표시 형식을 반영한 최악 케이스 값 텍스트 (최소폭 계산용)
    private string RealisticValueSample(int i) => i switch
    {
        0 => "100%",
        1 => (_cfg.MemShowPercent, _cfg.MemShowUsage) switch
        {
            (true,  true)  => "100% 99.9/99G",
            (true,  false) => "100%",
            (false, true)  => "99.9/99G",
            _              => "",
        },
        2 => "W:999M",
        _ => "U:999K",
    };

    // 레이블/수치 텍스트가 표시될 때 잘리지 않도록 최소 창 크기 계산
    private void ApplyMinSize()
    {
        var vis = new System.Collections.Generic.List<int>();
        for (int i = 0; i < 4; i++) if (Secs[i].Visible) vis.Add(i);
        if (vis.Count == 0) { MinWidth = 50; MinHeight = 40; return; }

        double lfs = _cfg.LabelFontSize, vfs = _cfg.ValueFontSize;
        bool anyLabel = vis.Exists(i => Secs[i].ShowLabel);
        bool anyValue = vis.Exists(i => Secs[i].ShowValues);
        double textRowH = Math.Max(anyLabel ? lfs : 0, anyValue ? vfs : 0);
        double minPanelH = textRowH > 0 ? textRowH + 8 : 16;

        double maxTextW = 0;
        var typeface = new Typeface(new System.Windows.Media.FontFamily(FontFamily.ToString()),
            FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        var labelNames = new[] { "CPU", "MEM", "DISK", "NET" };
        foreach (int i in vis)
        {
            string sample = (Secs[i].ShowLabel ? labelNames[i] : "")
                + (Secs[i].ShowValues ? " " + RealisticValueSample(i) : "");
            if (string.IsNullOrEmpty(sample)) continue;
            var ft = new FormattedText(sample, System.Globalization.CultureInfo.CurrentCulture,
                System.Windows.FlowDirection.LeftToRight, typeface, Math.Max(lfs, vfs),
                System.Windows.Media.Brushes.Black, dpi);
            maxTextW = Math.Max(maxTextW, ft.Width);
        }
        double minPanelW = Math.Max(40, maxTextW + 12);

        switch (_cfg.Arrange)
        {
            case Arrangement.Horizontal:
                MinWidth  = vis.Count * minPanelW + (vis.Count - 1) + 4;
                MinHeight = minPanelH + 8;
                break;
            case Arrangement.Grid2x2:
                int cols = vis.Count >= 2 ? 2 : 1;
                int rows = (vis.Count + cols - 1) / cols;
                MinWidth  = cols * minPanelW + (cols - 1) + 4;
                MinHeight = rows * minPanelH + (rows - 1) + 4;
                break;
            case Arrangement.Compact:
                MinWidth  = minPanelW;
                MinHeight = minPanelH * 3 + 8;
                break;
            case Arrangement.Mini:
                MinWidth  = minPanelW;
                MinHeight = vis.Count * Math.Max(14, minPanelH * 0.6) + (vis.Count - 1) + 4;
                break;
            default: // Vertical
                MinWidth  = minPanelW;
                MinHeight = vis.Count * minPanelH + (vis.Count - 1) + 4;
                break;
        }

        MinWidth  = Math.Max(30, MinWidth);
        MinHeight = Math.Max(24, MinHeight);
    }

    // 모든 섹션(CPU/MEM/DISK/NET) 레이블 폭을 동일하게 고정 — 값 시작 X 위치 통일
    private double ComputeLabelColWidth()
    {
        var typeface = new Typeface(new System.Windows.Media.FontFamily(FontFamily.ToString()),
            FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
        double dpi = VisualTreeHelper.GetDpi(this).PixelsPerDip;
        double max = 0;
        foreach (var name in new[] { "CPU", "MEM", "DISK", "NET" })
        {
            var ft = new FormattedText(name, System.Globalization.CultureInfo.CurrentCulture,
                System.Windows.FlowDirection.LeftToRight, typeface, _cfg.LabelFontSize,
                System.Windows.Media.Brushes.Black, dpi);
            max = Math.Max(max, ft.Width);
        }
        return max;
    }

    // 레이블 표시 시 값은 공통 폭만큼 들여쓰기(좌측 정렬), 레이블 없으면 값은 좌측 끝에 밀착
    private void ApplyLabelValueAlignment(int i, bool showLabel)
    {
        Labels[i].MinWidth = showLabel ? _labelColW : 0;

        var vals = Vals[i];
        var m = vals.Margin;
        vals.HorizontalAlignment = HAlign.Left;
        vals.Margin = new Thickness(showLabel ? _labelColW + 4 : 0, m.Top, m.Right, m.Bottom);
    }

    private void ApplyMemDisplayMode()
    {
        vMem.Visibility   = _cfg.MemShowPercent ? Visibility.Visible : Visibility.Collapsed;
        vMemGB.Visibility = _cfg.MemShowUsage   ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ConfigurePanel(int i)
    {
        var s = Secs[i];
        RestoreIntoHeader(i);
        ApplyLabelValueAlignment(i, s.ShowLabel);

        Panels[i].Margin     = PanelMargin[i];
        Panels[i].Visibility = s.Visible    ? Visibility.Visible : Visibility.Collapsed;
        Labels[i].Visibility = s.ShowLabel  ? Visibility.Visible : Visibility.Collapsed;
        Vals[i].Visibility   = s.ShowValues ? Visibility.Visible : Visibility.Collapsed;

        var graph = Graphs[i];
        graph.Visibility = s.ShowGraph ? Visibility.Visible : Visibility.Collapsed;
        graph.BarMode    = s.Graph == GraphKind.Bar;

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

        SetTextBacking(Vals[i], s.Overlay && s.ShowGraph && s.ShowValues);
    }

    // ── 컴팩트 모드: CPU/MEM 막대+split, DISK/NET 꺽은선 ─────────────────
    private void ConfigurePanelCompact(int i)
    {
        var s = Secs[i];
        RestoreIntoHeader(i);
        ApplyLabelValueAlignment(i, true);

        Panels[i].Margin     = PanelMargin[i];
        Panels[i].Visibility = Visibility.Visible;
        Labels[i].Visibility = Visibility.Visible;
        Vals[i].Visibility   = Visibility.Visible;

        var graph = Graphs[i];
        graph.Visibility = s.ShowGraph ? Visibility.Visible : Visibility.Collapsed;
        bool overlay;
        if (i < 2)  // CPU, MEM → 막대그래프 + split
        {
            graph.BarMode = true;
            SplitPanel(Panels[i], Hdrs[i], graph);
            overlay = false;
        }
        else        // DISK, NET → 꺽은선 + 섹션 설정 따름
        {
            graph.BarMode = false;
            overlay = s.Overlay;
            if (overlay)
                RestorePanelOverlay(Panels[i], Hdrs[i], graph);
            else
                SplitPanel(Panels[i], Hdrs[i], graph);
        }

        SetTextBacking(Vals[i], overlay && s.ShowGraph);
    }

    // 레이블/수치를 hdr(겹침 컨테이너)로 되돌림 — 미니 모드에서 분리 배치했던 것을 복원
    private void RestoreIntoHeader(int i)
    {
        var hdr = (System.Windows.Controls.Panel)Hdrs[i];
        hdr.Visibility = Visibility.Visible;
        ReparentInto(Labels[i], hdr);
        ReparentInto(Vals[i],   hdr);
        Vals[i].HorizontalAlignment = HAlign.Right;
        Vals[i].Margin              = new Thickness(0);
        System.Windows.Controls.Panel.SetZIndex(Vals[i], 0);
    }

    private static void ReparentInto(FrameworkElement el, System.Windows.Controls.Panel newParent)
    {
        if (ReferenceEquals(el.Parent, newParent)) return;
        if (el.Parent is System.Windows.Controls.Panel old) old.Children.Remove(el);
        newParent.Children.Add(el);
    }

    // 그래프 위에 수치가 겹칠 때 가독성을 위한 반투명 배경
    private static void SetTextBacking(FrameworkElement el, bool on)
    {
        if (!on) { if (el is System.Windows.Controls.Panel p) p.Background = null; return; }
        var brush = new SolidColorBrush(WColor.FromArgb(140, 0, 0, 0));
        brush.Freeze();
        if (el is System.Windows.Controls.Panel panel) panel.Background = brush;
    }

    // ── 미니 모드: [레이블 | 그래프/수치] 수평 배치 ─────────────────────
    // 레이블 끄면 해당 칸 폭 0 → 그래프/수치가 전체 폭 사용
    // 그래프+수치 모두 켜지면 Overlay 설정에 따라 겹치기/좌우분리
    private void ConfigurePanelMini(int i)
    {
        var s     = Secs[i];
        var panel = Panels[i];
        var hdr   = (System.Windows.Controls.Panel)Hdrs[i];
        var graph = Graphs[i];
        var label = Labels[i];
        var vals  = Vals[i];

        bool isBar     = s.Graph == GraphKind.Bar;
        bool showGraph = s.ShowGraph;
        bool showVals  = s.ShowValues;
        bool showLabel = s.ShowLabel;
        bool both      = showGraph && showVals;

        panel.Margin     = new Thickness(2, 1, 2, 1);
        panel.Visibility = Visibility.Visible;
        hdr.Visibility   = Visibility.Collapsed; // 겹침 컨테이너 대신 레이블/수치를 패널에 직접 배치

        ReparentInto(label, panel);
        ReparentInto(vals,  panel);

        graph.Visibility          = showGraph ? Visibility.Visible : Visibility.Collapsed;
        graph.BarMode             = isBar;
        graph.Margin              = new Thickness(0);
        graph.VerticalAlignment   = VerticalAlignment.Stretch;
        graph.HorizontalAlignment = HAlign.Stretch;

        panel.RowDefinitions.Clear();
        panel.ColumnDefinitions.Clear();
        panel.ColumnDefinitions.Add(new ColumnDefinition { Width = showLabel ? new GridLength(_labelColW) : new GridLength(0) });

        label.Visibility          = showLabel ? Visibility.Visible : Visibility.Collapsed;
        label.VerticalAlignment   = VerticalAlignment.Center;
        label.HorizontalAlignment = HAlign.Left;
        label.Margin              = new Thickness(0, 0, showLabel ? 3 : 0, 0);
        Grid.SetColumn(label, 0);
        Grid.SetRow(label, 0);

        vals.Visibility          = showVals ? Visibility.Visible : Visibility.Collapsed;
        vals.VerticalAlignment   = VerticalAlignment.Center;
        System.Windows.Controls.Panel.SetZIndex(vals, 1);
        Grid.SetRow(vals, 0);
        Grid.SetRow(graph, 0);

        if (both && !s.Overlay)
        {
            // 좌우 분리: [레이블(고정폭)|수치(auto)|그래프(*)] — 수치가 그래프보다 좌측
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(vals, 1);
            vals.HorizontalAlignment = HAlign.Left;
            vals.Margin = new Thickness(0, 0, 4, 0);
            Grid.SetColumn(graph, 2);
        }
        else
        {
            // 겹치기(둘 다 켜짐+Overlay) 또는 단독 표시: 같은 칸(그래프 칸) 공유
            panel.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            Grid.SetColumn(vals, 1);
            Grid.SetColumn(graph, 1);
            vals.Margin = new Thickness(0);
            vals.HorizontalAlignment = showGraph ? HAlign.Right : HAlign.Left;
        }

        SetTextBacking(vals, both && s.Overlay);
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

    private RowDefinition    Row(double h) => new() { Height = _cfg.ScaleText ? GL(h * UNIT) : new GridLength(h, GridUnitType.Star) };
    private static ColumnDefinition Col(int w) => new() { Width = new GridLength(w, GridUnitType.Star) };

    private void ApplyArrangement()
    {
        MainGrid.RowDefinitions.Clear();
        MainGrid.ColumnDefinitions.Clear();
        foreach (var sep in new[] { Sep1, Sep2, Sep3, Sep4 }) sep.Visibility = Visibility.Collapsed;

        // 컴팩트/미니는 고정 4패널 레이아웃 — vis 필터 없이 바로 처리
        if (_cfg.Arrange == Arrangement.Compact) { ArrangeCompact(); return; }
        if (_cfg.Arrange == Arrangement.Mini)    { ArrangeMini();    return; }

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
            MainGrid.RowDefinitions.Add(Row(Secs[vis[k]].HeightRatio));
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
            MainGrid.ColumnDefinitions.Add(Col(Secs[vis[k]].WidthRatio));
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

        var cw = new int[cols];
        var rh = new int[rows];
        for (int k = 0; k < n; k++)
        {
            int r = k / cols, c = k % cols;
            cw[c] = Math.Max(cw[c], Secs[vis[k]].WidthRatio);
            rh[r] = Math.Max(rh[r], Secs[vis[k]].HeightRatio);
        }

        for (int c = 0; c < cols; c++)
        {
            MainGrid.ColumnDefinitions.Add(Col(cw[c]));
            if (c < cols - 1) MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GL(1) });
        }
        for (int r = 0; r < rows; r++)
        {
            MainGrid.RowDefinitions.Add(Row(rh[r]));
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

    // 컴팩트: CPU/MEM 전폭 반높이(막대) + DISK|NET 가로 분할(꺽은선)
    private void ArrangeCompact()
    {
        _designW = DESIGN_W;

        // 3열: [*, 1px, *]
        MainGrid.ColumnDefinitions.Add(Col(1));
        MainGrid.ColumnDefinitions.Add(new ColumnDefinition { Width = GL(1) });
        MainGrid.ColumnDefinitions.Add(Col(1));

        // 5행: CPU(1*) / sep / MEM(1*) / sep / DISK|NET(2*)
        MainGrid.RowDefinitions.Add(Row(1));
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1) });
        MainGrid.RowDefinitions.Add(Row(1));
        MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1) });
        MainGrid.RowDefinitions.Add(Row(2));

        Pos(PanelCpu,  0, 0, 1, 3);
        Pos(Sep1,      1, 0, 1, 3); Sep1.Visibility = Visibility.Visible;
        Pos(PanelMem,  2, 0, 1, 3);
        Pos(Sep2,      3, 0, 1, 3); Sep2.Visibility = Visibility.Visible;
        Pos(PanelDisk, 4, 0, 1, 1);
        Pos(Sep4,      4, 1, 1, 1); Sep4.Visibility = Visibility.Visible;
        Pos(PanelNet,  4, 2, 1, 1);
    }

    // 미니: 4행 동일 높이, 패널 내부 [레이블|막대] 수평 배치
    private void ArrangeMini()
    {
        _designW = DESIGN_W;
        MainGrid.ColumnDefinitions.Add(Col(1));

        var panels = new[] { PanelCpu, PanelMem, PanelDisk, PanelNet };
        var seps   = new[] { Sep1, Sep2, Sep3, Sep4 };
        int row = 0, sep = 0;
        for (int k = 0; k < 4; k++)
        {
            MainGrid.RowDefinitions.Add(Row(0.5));  // 일반 모드의 절반 높이
            Pos(panels[k], row, 0);
            row++;
            if (k < 3)
            {
                MainGrid.RowDefinitions.Add(new RowDefinition { Height = GL(1) });
                Pos(seps[sep], row, 0);
                seps[sep].Visibility = Visibility.Visible;
                sep++; row++;
            }
        }
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
        // 포그라운드 이벤트를 놓친 경우(작업표시줄 자동 상승 등) 대비 주기적 재주장
        if (_cfg.AlwaysOnTop && IsVisible) AssertTopmost();

        var d = _monitor.Collect();

        vCpu.Text   = $"{d.Cpu:F0}%";
        vTemp.Text  = d.CpuTemp.HasValue ? $"{d.CpuTemp:F0}°" : "";
        vMem.Text   = $"{d.MemPct:F0}%";
        vMemGB.Text = $"{d.MemUsedGB:F1}/{d.MemTotalGB:F0}G";
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
    public void OpenSettings(int tabIndex = 0)
    {
        var original = _cfg.Clone();
        var dlg = new SettingsWindow(_cfg.Clone(), tabIndex) { Owner = this };
        dlg.ApplyRequested = settings =>
        {
            _cfg = settings;
            _timer.Interval = TimeSpan.FromMilliseconds(Math.Clamp(_cfg.UpdateMs, 250, 5000));
            RenderAll();
            SettingsManager.Save(_cfg);
        };
        if (dlg.ShowDialog() == true)
        {
            _cfg = dlg.Result;
            _timer.Interval = TimeSpan.FromMilliseconds(Math.Clamp(_cfg.UpdateMs, 250, 5000));
            RenderAll();
            SettingsManager.Save(_cfg);
        }
        else
        {
            _cfg = original;
            _timer.Interval = TimeSpan.FromMilliseconds(Math.Clamp(_cfg.UpdateMs, 250, 5000));
            RenderAll();
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
        aot.Click += (_, _) => { _cfg.AlwaysOnTop = aot.IsChecked; ApplyAlwaysOnTop(aot.IsChecked); SettingsManager.Save(_cfg); };
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
            {
                ("세로 1열",    Arrangement.Vertical),
                ("2×2 그리드",  Arrangement.Grid2x2),
                ("가로 1줄",    Arrangement.Horizontal),
                ("컴팩트 모드", Arrangement.Compact),
                ("미니 모드",   Arrangement.Mini),
            })
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

        menu.Items.Add(new Separator());

        var info = new MenuItem { Header = "정보..." };
        info.Click += (_, _) => OpenSettings(5);
        menu.Items.Add(info);

        menu.Items.Add(new Separator());

        var restart = new MenuItem { Header = "재시작" };
        restart.Click += (_, _) => ((App)System.Windows.Application.Current).Restart();
        menu.Items.Add(restart);

        var exit = new MenuItem { Header = "종료" };
        exit.Click += (_, _) => ((App)System.Windows.Application.Current).FullExit();
        menu.Items.Add(exit);

        return menu;
    }

    private void ApplyFontSizes()
    {
        double lfs = _cfg.LabelFontSize;
        double vfs = _cfg.ValueFontSize;

        lblCpu.FontSize  = lfs;
        lblMem.FontSize  = lfs;
        lblDisk.FontSize = lfs;
        lblNet.FontSize  = lfs;

        SetChildFontSize(valsCpu,  vfs);
        SetChildFontSize(valsMem,  vfs);
        SetChildFontSize(valsDisk, vfs);
        SetChildFontSize(valsNet,  vfs);
    }

    private static void SetChildFontSize(FrameworkElement el, double size)
    {
        if (el is System.Windows.Controls.TextBlock tb) { tb.FontSize = size; return; }
        if (el is System.Windows.Controls.Panel p)
            foreach (UIElement c in p.Children)
                if (c is FrameworkElement fe) SetChildFontSize(fe, size);
    }

    public void SavePosition()
    {
        _cfg.SavedX = Left;
        _cfg.SavedY = Top;
        SettingsManager.Save(_cfg);
    }

    public void RestorePosition()
    {
        if (_cfg.SavedX.HasValue) Left = _cfg.SavedX.Value;
        if (_cfg.SavedY.HasValue) Top  = _cfg.SavedY.Value;
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        e.Cancel = true;
        Hide();
    }

    protected override void OnClosed(EventArgs e)
    {
        if (_fgHook != IntPtr.Zero) { UnhookWinEvent(_fgHook); _fgHook = IntPtr.Zero; }
        _timer.Stop();
        _monitor.Dispose();
        base.OnClosed(e);
    }
}
