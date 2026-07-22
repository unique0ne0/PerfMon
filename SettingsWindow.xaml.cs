using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using WColor = System.Windows.Media.Color;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using HAlign = System.Windows.HorizontalAlignment;
using TextBox = System.Windows.Controls.TextBox;
using Button = System.Windows.Controls.Button;
using Orientation = System.Windows.Controls.Orientation;
using FontFamily = System.Windows.Media.FontFamily;
using ColorConverter = System.Windows.Media.ColorConverter;

namespace PerfMonCS;

public partial class SettingsWindow : Window
{
    private AppSettings _cfg;

    public AppSettings Result => _cfg;
    public Action<AppSettings>? ApplyRequested;

    public SettingsWindow(AppSettings working, int initialTab = 0)
    {
        InitializeComponent();
        _cfg = working;
        BuildTabs();
        if (initialTab > 0 && initialTab < Tabs.Items.Count)
            Tabs.SelectedIndex = initialTab;
    }

    private void BuildTabs()
    {
        Tabs.Items.Clear();
        Tabs.Items.Add(GeneralTab());
        Tabs.Items.Add(SectionTab("CPU",     _cfg.Cpu,  null));
        Tabs.Items.Add(SectionTab("Memory",  _cfg.Mem,  null));
        Tabs.Items.Add(SectionTab("Disk",    _cfg.Disk, ("R", "W")));
        Tabs.Items.Add(SectionTab("Network", _cfg.Net,  ("D", "U")));
        Tabs.Items.Add(InfoTab());
    }

    // 섹션 탭만 다시 빌드 (일반·정보 탭 유지)
    private void RefreshSectionTabs()
    {
        while (Tabs.Items.Count > 2) Tabs.Items.RemoveAt(1);
        Tabs.Items.Insert(1, SectionTab("CPU",     _cfg.Cpu,  null));
        Tabs.Items.Insert(2, SectionTab("Memory",  _cfg.Mem,  null));
        Tabs.Items.Insert(3, SectionTab("Disk",    _cfg.Disk, ("R", "W")));
        Tabs.Items.Insert(4, SectionTab("Network", _cfg.Net,  ("D", "U")));
    }

    // ── 일반 탭 ──────────────────────────────────────────────────────────
    private TabItem GeneralTab()
    {
        var sp = new StackPanel { Margin = new Thickness(12) };

        sp.Children.Add(new TextBlock { Text = "배치" });
        sp.Children.Add(Combo(new[] { "세로 1열", "2×2 그리드", "가로 1줄", "컴팩트", "미니" }, (int)_cfg.Arrange,
            i => _cfg.Arrange = (Arrangement)i));

        sp.Children.Add(new TextBlock { Text = "표시할 패널", Margin = new Thickness(0, 12, 0, 2) });
        var panelGrid = new UniformGrid { Columns = 2, HorizontalAlignment = HAlign.Left };
        var names = new[] { "CPU", "메모리", "디스크", "네트워크" };
        for (int i = 0; i < 4; i++)
        {
            var s = _cfg.Sections[i];
            panelGrid.Children.Add(Chk(names[i], s.Visible, v => s.Visible = v, marginTop: 2));
        }
        sp.Children.Add(panelGrid);

        // 전체 패널 공통 마스터 체크박스
        var chkMaster = new CheckBox
        {
            Content = "전체 패널 공통",
            IsChecked = _cfg.UseCommonDisplay,
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 12, 0, 4),
        };

        var subPanel = new StackPanel { Margin = new Thickness(18, 0, 0, 0) };
        var chkLabel   = Chk("레이블 표시",         _cfg.Sections.All(s => s.ShowLabel),  v => { foreach (var s in _cfg.Sections) s.ShowLabel  = v; });
        var chkValues  = Chk("수치 표시",            _cfg.Sections.All(s => s.ShowValues), v => { foreach (var s in _cfg.Sections) s.ShowValues = v; }, marginTop: 4);
        var chkGraph   = Chk("그래프 표시",          _cfg.Sections.All(s => s.ShowGraph),  v => { foreach (var s in _cfg.Sections) s.ShowGraph  = v; }, marginTop: 4);
        var chkOverlay = Chk("텍스트 그래프 겹치기", _cfg.Sections.All(s => s.Overlay),    v => { foreach (var s in _cfg.Sections) s.Overlay    = v; }, marginTop: 4);
        subPanel.Children.Add(chkLabel);
        subPanel.Children.Add(chkValues);
        subPanel.Children.Add(chkGraph);
        subPanel.Children.Add(chkOverlay);

        void UpdateSub(bool on)
        {
            chkLabel.IsEnabled = chkValues.IsEnabled = chkGraph.IsEnabled = chkOverlay.IsEnabled = on;
        }
        UpdateSub(_cfg.UseCommonDisplay);

        chkMaster.Checked   += (_, _) => { _cfg.UseCommonDisplay = true;  UpdateSub(true);  RefreshSectionTabs(); };
        chkMaster.Unchecked += (_, _) => { _cfg.UseCommonDisplay = false; UpdateSub(false); RefreshSectionTabs(); };

        sp.Children.Add(chkMaster);
        sp.Children.Add(subPanel);

        sp.Children.Add(Chk("항상 위 표시", _cfg.AlwaysOnTop, v => _cfg.AlwaysOnTop = v, marginTop: 12));
        sp.Children.Add(Chk("글자도 창 크기에 맞춰 스케일", _cfg.ScaleText, v => _cfg.ScaleText = v));

        sp.Children.Add(SliderRow("투명도", 0.1, 1.0, _cfg.Opacity, 0.05,
            v => $"{v * 100:0}%", v => _cfg.Opacity = v));
        sp.Children.Add(SliderRow("레이블 폰트 크기", 7, 20, _cfg.LabelFontSize, 1,
            v => $"{v:0}px", v => _cfg.LabelFontSize = v));
        sp.Children.Add(SliderRow("수치 폰트 크기", 7, 20, _cfg.ValueFontSize, 1,
            v => $"{v:0}px", v => _cfg.ValueFontSize = v));

        sp.Children.Add(new TextBlock { Text = "업데이트 주기", Margin = new Thickness(0, 10, 0, 2) });
        var ms = new[] { 500, 1000, 2000 };
        int sel = _cfg.UpdateMs <= 500 ? 0 : _cfg.UpdateMs >= 2000 ? 2 : 1;
        sp.Children.Add(Combo(new[] { "빠름 (0.5초)", "보통 (1초)", "느림 (2초)" }, sel,
            i => _cfg.UpdateMs = ms[i]));

        return new TabItem { Header = "일반", Content = new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = sp,
        }};
    }

    // ── 섹션 탭 ──────────────────────────────────────────────────────────
    private TabItem SectionTab(string header, SectionSettings s, (string, string)? series)
    {
        var tab = new TabItem { Header = header };
        tab.Content = SectionContent(header, s, series, tab);
        return tab;
    }

    private ScrollViewer SectionContent(string header, SectionSettings s, (string, string)? series, TabItem tab)
    {
        var sp = new StackPanel { Margin = new Thickness(12) };

        sp.Children.Add(new TextBlock
        {
            Text = "표시 설정",
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 0, 0, 8),
        });

        var chkLabel   = Chk("레이블 표시",                  s.ShowLabel,  v => s.ShowLabel  = v);
        var chkValues  = Chk("수치 표시",                    s.ShowValues, v => s.ShowValues = v, marginTop: 4);
        var chkGraph   = Chk("그래프 표시",                  s.ShowGraph,  v => s.ShowGraph  = v, marginTop: 4);
        var chkOverlay = Chk("텍스트를 그래프 위에 겹치기",  s.Overlay,    v => s.Overlay    = v, marginTop: 4);

        // 전체 공통 모드면 개별 패널 표시 설정 비활성화
        if (_cfg.UseCommonDisplay)
            chkLabel.IsEnabled = chkValues.IsEnabled = chkGraph.IsEnabled = chkOverlay.IsEnabled = false;

        sp.Children.Add(chkLabel);
        sp.Children.Add(chkValues);
        sp.Children.Add(chkGraph);
        sp.Children.Add(chkOverlay);

        if (header == "Memory")
        {
            sp.Children.Add(new TextBlock { Text = "수치 표시 항목", Margin = new Thickness(0, 12, 0, 2) });
            sp.Children.Add(Chk("퍼센트(%) 표시",  _cfg.MemShowPercent, v => _cfg.MemShowPercent = v));
            sp.Children.Add(Chk("사용량(GB) 표시", _cfg.MemShowUsage,  v => _cfg.MemShowUsage  = v, marginTop: 4));
        }

        sp.Children.Add(new TextBlock { Text = "그래프 종류", Margin = new Thickness(0, 12, 0, 2) });
        sp.Children.Add(Combo(new[] { "꺾은선", "막대" }, (int)s.Graph, i => s.Graph = (GraphKind)i));

        sp.Children.Add(RatioRow(s));

        // ── 색상 ──
        sp.Children.Add(new TextBlock
        {
            Text = "색상",
            FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(0, 16, 0, 6),
        });

        bool dual = series is not null;
        string sfx1 = dual ? $" {series!.Value.Item1}" : "";
        string sfx2 = dual ? $" {series!.Value.Item2}" : "";

        sp.Children.Add(ColorRow("레이블", s.LabelColor!, v => s.LabelColor = v));
        sp.Children.Add(ColorRow($"수치{sfx1}", s.Value1Color!, v => s.Value1Color = v));
        if (dual)
            sp.Children.Add(ColorRow($"수치{sfx2}", s.Value2Color!, v => s.Value2Color = v));

        // 기본은 수치=그래프 한 쌍. 별도 지정 체크 시에만 그래프 색 행 노출.
        sp.Children.Add(Chk("그래프 색 따로 지정", s.SeparateGraphColor, v =>
        {
            s.SeparateGraphColor = v;
            if (v)   // 켜는 순간 현재 수치 색으로 시작
            {
                s.Graph1Color = s.Value1Color;
                s.Graph2Color = s.Value2Color;
            }
            tab.Content = SectionContent(header, s, series, tab);   // 행 추가/제거 반영
        }, marginTop: 6));

        if (s.SeparateGraphColor)
        {
            sp.Children.Add(ColorRow($"그래프{sfx1}", s.Graph1Color!, v => s.Graph1Color = v));
            if (dual)
                sp.Children.Add(ColorRow($"그래프{sfx2}", s.Graph2Color!, v => s.Graph2Color = v));
        }

        return new ScrollViewer
        {
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = sp,
        };
    }

    // ── 색상 선택 (프리셋 팔레트 + HEX 직접입력) ──────────────────────────
    private static readonly string[] Palette =
    {
        "#FFFFFFFF", "#FFB0B0B0", "#FF64748B", "#FF00C3FF", "#FF38BDF8", "#FF22D3EE",
        "#FF4ADE80", "#FFFDE047", "#FFF97316", "#FFEF4444", "#FFEC4899", "#FFA855F7",
    };

    private static FrameworkElement ColorRow(string label, string current, Action<string> set)
    {
        var outer = new StackPanel { Margin = new Thickness(0, 0, 0, 8) };

        var preview = new Border
        {
            Width = 22, Height = 22,
            BorderBrush = new SolidColorBrush(WColor.FromRgb(0x88, 0x88, 0x88)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(3),
            Margin = new Thickness(0, 0, 6, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        var hex = new TextBox
        {
            Width = 96,
            Text = current,
            VerticalContentAlignment = VerticalAlignment.Center,
            FontFamily = new FontFamily("Consolas"),
        };

        void Apply(string val)
        {
            try
            {
                var c = (WColor)ColorConverter.ConvertFromString(val);
                preview.Background = new SolidColorBrush(c);
                set($"#{c.A:X2}{c.R:X2}{c.G:X2}{c.B:X2}");
            }
            catch { /* 유효하지 않은 입력은 무시 (미리보기·값 유지) */ }
        }

        var top = new StackPanel { Orientation = Orientation.Horizontal };
        top.Children.Add(new TextBlock
        {
            Text = label, Width = 60,
            VerticalAlignment = VerticalAlignment.Center,
        });
        top.Children.Add(preview);
        top.Children.Add(hex);

        var swatches = new WrapPanel { Margin = new Thickness(66, 5, 0, 0), Width = 300 };
        foreach (var p in Palette)
        {
            var col = (WColor)ColorConverter.ConvertFromString(p);
            var btn = new Button
            {
                Width = 20, Height = 20,
                Margin = new Thickness(0, 0, 4, 4),
                Background = new SolidColorBrush(col),
                BorderBrush = new SolidColorBrush(WColor.FromRgb(0x55, 0x55, 0x55)),
                BorderThickness = new Thickness(0.5),
                ToolTip = p,
            };
            btn.Click += (_, _) => hex.Text = p;   // TextChanged → Apply
            swatches.Children.Add(btn);
        }

        hex.TextChanged += (_, _) => Apply(hex.Text);
        Apply(current);   // 초기 미리보기

        outer.Children.Add(top);
        outer.Children.Add(swatches);
        return outer;
    }

    // ── 정보 탭 ──────────────────────────────────────────────────────────
    private static TabItem InfoTab()
    {
        var sp = new StackPanel { Margin = new Thickness(24), HorizontalAlignment = HAlign.Left };

        sp.Children.Add(new TextBlock
        {
            Text = "Performance Monitor",
            FontSize = 15,
            FontWeight = FontWeights.Bold,
        });
        sp.Children.Add(new TextBlock
        {
            Text = "v0.8.6",
            FontSize = 12,
            Foreground = new SolidColorBrush(WColor.FromRgb(0x88, 0x88, 0x88)),
            Margin = new Thickness(0, 2, 0, 20),
        });
        sp.Children.Add(new TextBlock { Text = "Author", FontWeight = FontWeights.SemiBold });
        sp.Children.Add(new TextBlock { Text = "멋진독특", Margin = new Thickness(0, 6, 0, 2) });
        sp.Children.Add(new TextBlock
        {
            Text = "blu2tem@gmail.com",
            Foreground = new SolidColorBrush(WColor.FromRgb(0x00, 0x78, 0xD7)),
        });

        return new TabItem { Header = "정보", Content = sp };
    }

    // ── 공통 컨트롤 헬퍼 ─────────────────────────────────────────────────
    private static CheckBox Chk(string text, bool val, Action<bool> set, double marginTop = 0)
    {
        var c = new CheckBox { Content = text, IsChecked = val, Margin = new Thickness(0, marginTop, 12, 0) };
        c.Checked   += (_, _) => set(true);
        c.Unchecked += (_, _) => set(false);
        return c;
    }

    private static Grid RatioRow(SectionSettings s)
    {
        var g = new Grid { Margin = new Thickness(0, 12, 0, 0) };
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(16) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });

        var lblW = new TextBlock { Text = "가로 비율:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        var cmbW = MiniCombo(new[] { "1", "2", "3" }, s.WidthRatio - 1, i => s.WidthRatio = i + 1);
        var lblH = new TextBlock { Text = "세로 비율:", VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
        var cmbH = MiniCombo(new[] { "1", "2", "3" }, s.HeightRatio - 1, i => s.HeightRatio = i + 1);

        Grid.SetColumn(lblW, 0); Grid.SetColumn(cmbW, 1);
        Grid.SetColumn(lblH, 3); Grid.SetColumn(cmbH, 4);
        g.Children.Add(lblW); g.Children.Add(cmbW);
        g.Children.Add(lblH); g.Children.Add(cmbH);
        return g;
    }

    private static ComboBox MiniCombo(string[] items, int sel, Action<int> set)
    {
        var cb = new ComboBox { Width = 64, HorizontalAlignment = HAlign.Left };
        foreach (var it in items) cb.Items.Add(it);
        cb.SelectedIndex = Math.Clamp(sel, 0, items.Length - 1);
        cb.SelectionChanged += (_, _) => { if (cb.SelectedIndex >= 0) set(cb.SelectedIndex); };
        return cb;
    }

    private static ComboBox Combo(string[] items, int sel, Action<int> set)
    {
        var cb = new ComboBox { Width = 170, HorizontalAlignment = HAlign.Left, Margin = new Thickness(0, 2, 0, 0) };
        foreach (var it in items) cb.Items.Add(it);
        cb.SelectedIndex = Math.Clamp(sel, 0, items.Length - 1);
        cb.SelectionChanged += (_, _) => { if (cb.SelectedIndex >= 0) set(cb.SelectedIndex); };
        return cb;
    }

    private static StackPanel SliderRow(string label, double min, double max, double val,
        double tick, Func<double, string> fmt, Action<double> set)
    {
        var sp = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };
        var head = new TextBlock { Text = $"{label}: {fmt(val)}" };
        var sl = new Slider
        {
            Minimum = min, Maximum = max, Value = val,
            TickFrequency = tick, IsSnapToTickEnabled = true,
            Width = 220, HorizontalAlignment = HAlign.Left,
            Margin = new Thickness(0, 2, 0, 0),
        };
        sl.ValueChanged += (_, e) => { head.Text = $"{label}: {fmt(e.NewValue)}"; set(e.NewValue); };
        sp.Children.Add(head);
        sp.Children.Add(sl);
        return sp;
    }

    // ── 버튼 ─────────────────────────────────────────────────────────────
    private void OnOk(object sender, RoutedEventArgs e)     { DialogResult = true;  Close(); }
    private void OnApply(object sender, RoutedEventArgs e)  { ApplyRequested?.Invoke(_cfg.Clone()); }
    private void OnCancel(object sender, RoutedEventArgs e) { DialogResult = false; Close(); }

    private void OnReset(object sender, RoutedEventArgs e)
    {
        var def = new AppSettings { X = _cfg.X, Y = _cfg.Y, W = _cfg.W, H = _cfg.H, SavedX = _cfg.SavedX, SavedY = _cfg.SavedY };
        _cfg = def;
        BuildTabs();
    }
}
