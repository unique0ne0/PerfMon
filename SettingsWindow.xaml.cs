using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using CheckBox = System.Windows.Controls.CheckBox;
using ComboBox = System.Windows.Controls.ComboBox;
using HAlign = System.Windows.HorizontalAlignment;

namespace PerfMonCS;

public partial class SettingsWindow : Window
{
    private AppSettings _cfg;

    public AppSettings Result => _cfg;
    public Action<AppSettings>? ApplyRequested;

    public SettingsWindow(AppSettings working)
    {
        InitializeComponent();
        _cfg = working;
        BuildTabs();
    }

    private void BuildTabs()
    {
        Tabs.Items.Clear();
        Tabs.Items.Add(GeneralTab());
        Tabs.Items.Add(SectionTab("CPU",        _cfg.Cpu));
        Tabs.Items.Add(SectionTab("Memory",     _cfg.Mem));
        Tabs.Items.Add(SectionTab("Disk",       _cfg.Disk));
        Tabs.Items.Add(SectionTab("Network",    _cfg.Net));
    }

    // ── 일반 탭 ──────────────────────────────────────────────────────────
    private TabItem GeneralTab()
    {
        var sp = new StackPanel { Margin = new Thickness(12) };

        sp.Children.Add(new TextBlock { Text = "배치" });
        sp.Children.Add(Combo(new[] { "세로 1열", "2×2 그리드", "가로 1줄", "컴팩트", "미니" }, (int)_cfg.Arrange,
            i => _cfg.Arrange = (Arrangement)i));

        sp.Children.Add(new TextBlock { Text = "표시할 패널", Margin = new Thickness(0, 12, 0, 2) });
        var grid = new UniformGrid { Columns = 2, HorizontalAlignment = HAlign.Left };
        var names = new[] { "CPU", "메모리", "디스크", "네트워크" };
        for (int i = 0; i < 4; i++)
        {
            var s = _cfg.Sections[i];
            grid.Children.Add(Chk(names[i], s.Visible, v => s.Visible = v, marginTop: 2));
        }
        sp.Children.Add(grid);

        sp.Children.Add(new TextBlock { Text = "전체 패널 공통", Margin = new Thickness(0, 12, 0, 4),
            FontWeight = FontWeights.SemiBold });
        sp.Children.Add(Chk("레이블 표시",
            _cfg.Sections.All(s => s.ShowLabel),
            v => { foreach (var s in _cfg.Sections) s.ShowLabel = v; }));
        sp.Children.Add(Chk("수치 표시",
            _cfg.Sections.All(s => s.ShowValues),
            v => { foreach (var s in _cfg.Sections) s.ShowValues = v; }, marginTop: 4));
        sp.Children.Add(Chk("텍스트 그래프 겹치기",
            _cfg.Sections.All(s => s.Overlay),
            v => { foreach (var s in _cfg.Sections) s.Overlay = v; }, marginTop: 4));

        sp.Children.Add(Chk("항상 위 표시", _cfg.AlwaysOnTop, v => _cfg.AlwaysOnTop = v, marginTop: 12));
        sp.Children.Add(Chk("글자도 창 크기에 맞춰 스케일", _cfg.ScaleText, v => _cfg.ScaleText = v));

        sp.Children.Add(SliderRow("투명도", 0.1, 1.0, _cfg.Opacity, 0.05,
            v => $"{v * 100:0}%", v => _cfg.Opacity = v));

        sp.Children.Add(new TextBlock { Text = "업데이트 주기", Margin = new Thickness(0, 10, 0, 2) });
        var ms = new[] { 500, 1000, 2000 };
        int sel = _cfg.UpdateMs <= 500 ? 0 : _cfg.UpdateMs >= 2000 ? 2 : 1;
        sp.Children.Add(Combo(new[] { "빠름 (0.5초)", "보통 (1초)", "느림 (2초)" }, sel,
            i => _cfg.UpdateMs = ms[i]));

        return new TabItem { Header = "일반", Content = sp };
    }

    // ── 섹션 탭 ──────────────────────────────────────────────────────────
    private static TabItem SectionTab(string header, SectionSettings s)
    {
        var sp = new StackPanel { Margin = new Thickness(12) };

        sp.Children.Add(Chk("레이블 표시", s.ShowLabel, v => s.ShowLabel = v));
        sp.Children.Add(Chk("수치 표시", s.ShowValues, v => s.ShowValues = v, marginTop: 4));
        sp.Children.Add(Chk("텍스트를 그래프 위에 겹치기", s.Overlay, v => s.Overlay = v, marginTop: 4));

        sp.Children.Add(new TextBlock { Text = "그래프 종류", Margin = new Thickness(0, 12, 0, 2) });
        sp.Children.Add(Combo(new[] { "꺾은선", "막대" }, (int)s.Graph, i => s.Graph = (GraphKind)i));

        var ratioPanel = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        ratioPanel.Children.Add(new TextBlock { Text = "가로 비율:", VerticalAlignment = VerticalAlignment.Center, Width = 70 });
        ratioPanel.Children.Add(Combo(new[] { "1", "2", "3" }, s.WidthRatio - 1, i => s.WidthRatio = i + 1));
        ratioPanel.Children.Add(new TextBlock { Text = "  세로 비율:", VerticalAlignment = VerticalAlignment.Center, Width = 70 });
        ratioPanel.Children.Add(Combo(new[] { "1", "2", "3" }, s.HeightRatio - 1, i => s.HeightRatio = i + 1));
        sp.Children.Add(ratioPanel);

        return new TabItem { Header = header, Content = sp };
    }

    // ── 공통 컨트롤 헬퍼 ─────────────────────────────────────────────────
    private static CheckBox Chk(string text, bool val, Action<bool> set, double marginTop = 0)
    {
        var c = new CheckBox { Content = text, IsChecked = val, Margin = new Thickness(0, marginTop, 12, 0) };
        c.Checked   += (_, _) => set(true);
        c.Unchecked += (_, _) => set(false);
        return c;
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
        var def = new AppSettings { X = _cfg.X, Y = _cfg.Y, W = _cfg.W, H = _cfg.H };
        _cfg = def;
        BuildTabs();
    }
}
