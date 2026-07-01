using System.Windows;
using System.Windows.Media;
using Color  = System.Windows.Media.Color;
using Colors = System.Windows.Media.Colors;
using Pen    = System.Windows.Media.Pen;
using Point  = System.Windows.Point;

namespace PerfMonCS;

public sealed class GraphControl : FrameworkElement
{
    private const int HIST = 80;

    public static readonly DependencyProperty Color1Property =
        DependencyProperty.Register(nameof(Color1), typeof(Color), typeof(GraphControl),
            new FrameworkPropertyMetadata(Colors.White, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty Color2Property =
        DependencyProperty.Register(nameof(Color2), typeof(Color), typeof(GraphControl),
            new FrameworkPropertyMetadata(Colors.Gray, FrameworkPropertyMetadataOptions.AffectsRender));

    public static readonly DependencyProperty IsDualProperty =
        DependencyProperty.Register(nameof(IsDual), typeof(bool), typeof(GraphControl),
            new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));

    // 하위 호환성 유지용 (미사용)
    public static readonly DependencyProperty HeaderHeightProperty =
        DependencyProperty.Register(nameof(HeaderHeight), typeof(double), typeof(GraphControl),
            new FrameworkPropertyMetadata(0.0));

    public static readonly DependencyProperty BarModeProperty =
        DependencyProperty.Register(nameof(BarMode), typeof(bool), typeof(GraphControl),
            new FrameworkPropertyMetadata(false, FrameworkPropertyMetadataOptions.AffectsRender));

    public Color  Color1       { get => (Color)GetValue(Color1Property);        set => SetValue(Color1Property, value); }
    public Color  Color2       { get => (Color)GetValue(Color2Property);        set => SetValue(Color2Property, value); }
    public bool   IsDual       { get => (bool)GetValue(IsDualProperty);         set => SetValue(IsDualProperty, value); }
    public double HeaderHeight { get => (double)GetValue(HeaderHeightProperty); set => SetValue(HeaderHeightProperty, value); }
    public bool   BarMode      { get => (bool)GetValue(BarModeProperty);        set => SetValue(BarModeProperty, value); }

    private readonly double[] _buf1 = new double[HIST];
    private readonly double[] _buf2 = new double[HIST];

    public void Push(double v1, double v2 = 0)
    {
        Array.Copy(_buf1, 1, _buf1, 0, HIST - 1); _buf1[HIST - 1] = Math.Max(0, v1);
        Array.Copy(_buf2, 1, _buf2, 0, HIST - 1); _buf2[HIST - 1] = Math.Max(0, v2);
        InvalidateVisual();
    }

    protected override void OnRender(DrawingContext dc)
    {
        double w = ActualWidth, h = ActualHeight;
        if (w < 2 || h < 2) return;

        if (BarMode)
        {
            if (IsDual)
            {
                double max = Math.Max(0.001, Math.Max(_buf1.Max(), _buf2.Max()) * 1.2);
                DrawBarDual(dc, _buf1, _buf2, max, w, h, Color1, Color2);
            }
            else
            {
                DrawBar(dc, _buf1, 100.0, w, h, Color1);
            }
            return;
        }

        DrawGrid(dc, w, h);

        if (IsDual)
        {
            double max = Math.Max(0.001, Math.Max(_buf1.Max(), _buf2.Max()) * 1.2);
            DrawSeries(dc, _buf2, max, w, h, Color2, 0.45);
            DrawSeries(dc, _buf1, max, w, h, Color1, 0.75);
        }
        else
        {
            DrawSeries(dc, _buf1, 100.0, w, h, Color1, 0.8);
        }
    }

    private static void DrawGrid(DrawingContext dc, double w, double h)
    {
        var pen = new Pen(new SolidColorBrush(Color.FromArgb(10, 255, 255, 255)), 0.5);
        pen.Freeze();
        foreach (double r in new[] { 0.25, 0.5, 0.75 })
        {
            double y = Math.Round(h * r) + 0.5;
            dc.DrawLine(pen, new Point(0, y), new Point(w, y));
        }
    }

    private static void DrawSeries(DrawingContext dc, double[] buf, double max,
        double w, double h, Color color, double alpha)
    {
        var pts = new Point[HIST];
        for (int i = 0; i < HIST; i++)
            pts[i] = new Point(
                i / (double)(HIST - 1) * w,
                h - Math.Clamp(buf[i] / max, 0.0, 1.0) * h);

        // 채우기 (아래에서 위로 그라데이션)
        var fillGeo = new StreamGeometry();
        using (var ctx = fillGeo.Open())
        {
            ctx.BeginFigure(new Point(pts[0].X, h), isFilled: true, isClosed: true);
            foreach (var p in pts) ctx.LineTo(p, isStroked: false, isSmoothJoin: false);
            ctx.LineTo(new Point(pts[HIST - 1].X, h), isStroked: false, isSmoothJoin: false);
        }
        fillGeo.Freeze();

        byte fa = (byte)(alpha * 0.55 * 255);
        var fill = new LinearGradientBrush(
            Color.FromArgb(fa, color.R, color.G, color.B),
            Color.FromArgb(0,  color.R, color.G, color.B),
            new Point(0, 0), new Point(0, 1));
        fill.Freeze();
        dc.DrawGeometry(fill, null, fillGeo);

        // 선
        var lineGeo = new StreamGeometry();
        using (var ctx = lineGeo.Open())
        {
            ctx.BeginFigure(pts[0], isFilled: false, isClosed: false);
            for (int i = 1; i < HIST; i++)
                ctx.LineTo(pts[i], isStroked: true, isSmoothJoin: true);
        }
        lineGeo.Freeze();

        byte la = (byte)(alpha * 255);
        var pen = new Pen(new SolidColorBrush(Color.FromArgb(la, color.R, color.G, color.B)), 1.1)
        {
            LineJoin = PenLineJoin.Round
        };
        pen.Freeze();
        dc.DrawGeometry(null, pen, lineGeo);
    }

    private static void DrawBar(DrawingContext dc, double[] buf, double max,
        double w, double h, Color color)
    {
        double frac = Math.Clamp(buf[HIST - 1] / max, 0, 1);
        double barW = w * frac;
        if (barW < 0.5) return;

        double barH = Math.Max(2.0, h * 0.4);
        double y    = (h - barH) / 2.0;

        var brush = new LinearGradientBrush(
            Color.FromArgb(200, color.R, color.G, color.B),
            Color.FromArgb(100, color.R, color.G, color.B),
            new Point(0, 0), new Point(1, 0));
        brush.Freeze();
        dc.DrawRectangle(brush, null, new Rect(0, y, barW, barH));

        var edgePen = new Pen(new SolidColorBrush(Color.FromArgb(230, color.R, color.G, color.B)), 1.0);
        edgePen.Freeze();
        dc.DrawLine(edgePen, new Point(barW, y), new Point(barW, y + barH));
    }

    // 두 개의 가로 막대를 위/아래로 쌓아 그림 (DISK R/W, NET D/U) — 미니 레이아웃용
    private static void DrawBarDual(DrawingContext dc, double[] buf1, double[] buf2,
        double max, double w, double h, Color c1, Color c2)
    {
        double totalH = Math.Max(2.0, h * 0.4);
        double barH   = totalH / 2.0;
        double startY = (h - totalH) / 2.0;
        DrawBarRow(dc, startY,        barH, buf1[HIST - 1] / max, w, c1);
        DrawBarRow(dc, startY + barH, barH, buf2[HIST - 1] / max, w, c2);
    }

    private static void DrawBarRow(DrawingContext dc, double y, double slotH,
        double frac, double w, Color color)
    {
        double barH   = Math.Max(1.0, slotH);
        double offset = y;

        var track = new SolidColorBrush(Color.FromArgb(28, color.R, color.G, color.B));
        track.Freeze();
        dc.DrawRectangle(track, null, new Rect(0, offset, w, barH));

        double barW = Math.Clamp(frac, 0, 1) * w;
        if (barW < 0.5) return;

        var brush = new LinearGradientBrush(
            Color.FromArgb(200, color.R, color.G, color.B),
            Color.FromArgb(100, color.R, color.G, color.B),
            new Point(0, 0), new Point(1, 0));
        brush.Freeze();
        dc.DrawRectangle(brush, null, new Rect(0, offset, barW, barH));
    }
}
