# Charts for the overlay. Compiled and redrawn at most once per second, to leave the CPU and GPU to the game.
Add-Type -ReferencedAssemblies ([Windows.FrameworkElement].Assembly.Location), ([Windows.UIElement].Assembly.Location), ([Windows.Threading.Dispatcher].Assembly.Location), 'System.Xaml' @'
using System;
using System.Diagnostics;
using System.Windows;
using System.Windows.Media;

static class TpvChartPaint {
    public static SolidColorBrush Brush(string color) {
        SolidColorBrush brush = (SolidColorBrush)new BrushConverter().ConvertFromString(color);
        brush.Freeze();
        return brush;
    }
    public static Pen Pen(Brush brush, double thickness) {
        Pen pen = new Pen(brush, thickness);
        pen.StartLineCap = PenLineCap.Round;
        pen.EndLineCap = PenLineCap.Round;
        pen.LineJoin = PenLineJoin.Round;
        pen.Freeze();
        return pen;
    }
    public static SolidColorBrush Faded(SolidColorBrush brush, byte alpha) {
        Color c = brush.Color;
        SolidColorBrush faded = new SolidColorBrush(Color.FromArgb(alpha, c.R, c.G, c.B));
        faded.Freeze();
        return faded;
    }
    public static readonly Brush Track = Brush("#66060E30");
    public static readonly Pen Guide = Pen(Brush("#30FFFFFF"), 1);
    public static readonly Pen Marker = Pen(Brush("#FFFFFF"), 1.6);
    public static readonly Brush White = Brush("#FFFFFF");
    public static readonly Pen Dashed = CreateDashed();
    static Pen CreateDashed() {
        Pen pen = new Pen(Brush("#D0FFFFFF"), 1.2);
        pen.DashStyle = new DashStyle(new double[] { 4, 3 }, 0);
        pen.Freeze();
        return pen;
    }
}

// Rolling history, newest value on the right. One point per second.
public sealed class TpvTrendChart : FrameworkElement {
    static readonly string[] WbalColors = { "#EF8A52", "#E7C03F", "#68DF31" };
    static readonly string[] ZoneColors = { "#8A8F9A", "#2F6FD6", "#3DA62E", "#C8A400", "#D0620F", "#D42A20", "#9B55C4" };
    static readonly double[] ZoneLimits = { 0.55, 0.75, 0.90, 1.05, 1.20, 1.50 };

    readonly double[] data;
    readonly bool isPower, whole;
    readonly Pen[] lines;
    readonly Brush[] fills;
    readonly Stopwatch clock = Stopwatch.StartNew();
    int count, head, samples;
    double smooth = double.NaN, sum, last = -1, pendingLow = double.NaN;
    int pendingCount, bin = 1;

    public double Reference { get; set; }

    public double CoveredSeconds { get { return whole ? count * (double)bin + pendingCount : count; } }

    public double Latest { get { return count == 0 ? double.NaN : At(count - 1); } }

    public TpvTrendChart(int seconds, bool power) : this(seconds, power, false) { }

    // Whole-ride mode: the curve always fills the width, and merged seconds keep their lowest value.
    public TpvTrendChart(int seconds, bool power, bool wholeRide) {
        data = new double[seconds];
        isPower = power;
        whole = wholeRide;
        string[] colors = power ? ZoneColors : WbalColors;
        lines = new Pen[colors.Length];
        fills = new Brush[colors.Length];
        for (int i = 0; i < colors.Length; i++) {
            SolidColorBrush brush = TpvChartPaint.Brush(colors[i]);
            lines[i] = TpvChartPaint.Pen(brush, 1.8);
            fills[i] = TpvChartPaint.Faded(brush, 70);
        }
    }

    double At(int i) { return data[(head + i) % data.Length]; }

    static double Lower(double a, double b) {
        if (double.IsNaN(a)) return b;
        if (double.IsNaN(b)) return a;
        return Math.Min(a, b);
    }

    void StoreWhole(double value) {
        pendingLow = Lower(pendingLow, value);
        pendingCount++;
        if (pendingCount < bin) return;
        if (count == data.Length) {
            int half = count / 2;
            for (int i = 0; i < half; i++) data[i] = Lower(data[2 * i], data[2 * i + 1]);
            count = half;
            bin *= 2;
        }
        data[count++] = pendingLow;
        pendingLow = double.NaN;
        pendingCount = 0;
    }

    void Store(double value) {
        if (whole) { StoreWhole(value); return; }
        if (count < data.Length) {
            data[(head + count) % data.Length] = value;
            count++;
        } else {
            data[head] = value;
            head = (head + 1) % data.Length;
        }
    }

    public void Clear() {
        count = head = samples = pendingCount = 0;
        bin = 1;
        pendingLow = double.NaN;
        sum = 0;
        last = -1;
        smooth = double.NaN;
        if (IsVisible) InvalidateVisual();
    }

    // Takes one raw reading; about one point per second reaches the chart.
    public void Feed(double value) {
        double now = clock.Elapsed.TotalSeconds;
        if (last < 0) last = now;
        sum += value;
        samples++;
        double elapsed = now - last;
        if (elapsed < 1) return;
        int steps = (int)Math.Floor(elapsed);
        // Time without data stays visible as a hole in the curve.
        for (int i = 1; i < Math.Min(steps, data.Length); i++) { Store(double.NaN); smooth = double.NaN; }
        Push(sum / samples);
        sum = 0;
        samples = 0;
        last += steps;
    }

    public void Push(double value) {
        if (double.IsNaN(value)) smooth = double.NaN;
        else if (!isPower || double.IsNaN(smooth)) smooth = value;
        else smooth += (value - smooth) / 3;
        Store(smooth);
        if (IsVisible) InvalidateVisual();
    }

    int ColorOf(double value) {
        if (!isPower) return value < 25 ? 0 : value < 50 ? 1 : 2;
        if (Reference <= 0) return 0;
        double share = value / Reference;
        for (int i = 0; i < ZoneLimits.Length; i++) if (share < ZoneLimits[i]) return i;
        return 6;
    }

    protected override void OnRender(DrawingContext dc) {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 1 || h <= 1) return;
        Rect area = new Rect(0, 0, w, h);
        dc.DrawRoundedRectangle(TpvChartPaint.Track, null, area, 4, 4);
        dc.PushClip(new RectangleGeometry(area, 4, 4));

        double top = 100;
        if (isPower) {
            double highest = 0;
            for (int i = 0; i < count; i++) { double v = At(i); if (!double.IsNaN(v) && v > highest) highest = v; }
            top = Math.Max(Math.Max(Reference * 1.6, highest * 1.1), 1);
            if (Reference > 0) {
                double y = h * (1 - Reference / top);
                dc.DrawLine(TpvChartPaint.Dashed, new Point(0, y), new Point(w, y));
            }
        } else {
            foreach (double level in new double[] { 25, 50, 75 }) {
                double y = h * (1 - level / 100);
                dc.DrawLine(TpvChartPaint.Guide, new Point(0, y), new Point(w, y));
            }
        }

        StreamGeometry[] lineShapes = new StreamGeometry[lines.Length], fillShapes = new StreamGeometry[lines.Length];
        StreamGeometryContext[] lineDraw = new StreamGeometryContext[lines.Length], fillDraw = new StreamGeometryContext[lines.Length];
        double step = whole ? w / Math.Max(1, count - 1) : w / (data.Length - 1);
        for (int i = 1; i < count; i++) {
            double a = At(i - 1), b = At(i);
            if (double.IsNaN(a) || double.IsNaN(b)) continue;
            int color = ColorOf((a + b) / 2);
            if (lineDraw[color] == null) {
                lineShapes[color] = new StreamGeometry();
                fillShapes[color] = new StreamGeometry();
                lineDraw[color] = lineShapes[color].Open();
                fillDraw[color] = fillShapes[color].Open();
            }
            double x1 = w - (count - i) * step, x2 = w - (count - 1 - i) * step;
            Point p1 = new Point(x1, h * (1 - Math.Min(a, top) / top)), p2 = new Point(x2, h * (1 - Math.Min(b, top) / top));
            lineDraw[color].BeginFigure(p1, false, false);
            lineDraw[color].LineTo(p2, true, false);
            fillDraw[color].BeginFigure(p1, true, true);
            fillDraw[color].LineTo(p2, false, false);
            fillDraw[color].LineTo(new Point(x2, h), false, false);
            fillDraw[color].LineTo(new Point(x1, h), false, false);
        }
        for (int c = 0; c < lines.Length; c++) {
            if (lineDraw[c] == null) continue;
            lineDraw[c].Close();
            fillDraw[c].Close();
            lineShapes[c].Freeze();
            fillShapes[c].Freeze();
            dc.DrawGeometry(fills[c], null, fillShapes[c]);
            dc.DrawGeometry(null, lines[c], lineShapes[c]);
        }
        dc.Pop();
    }
}

// Elevation of the road ahead, colored by gradient, with the rider's position.
public sealed class TpvRouteChart : FrameworkElement {
    double ahead = 5000;

    // Distance shown ahead of the rider, in meters; a tenth of it is kept behind.
    public double Ahead {
        get { return ahead; }
        set { ahead = Math.Max(200, value); if (IsVisible) InvalidateVisual(); }
    }
    double Past { get { return ahead * 0.1; } }
    static readonly string[] SlopeColors = { "#4F76F5", "#3DA62E", "#E7C03F", "#EF8A52", "#E0352B" };

    readonly Brush[] solid = new Brush[SlopeColors.Length], dim = new Brush[SlopeColors.Length];
    double[] slopes, elevation;
    double start, bucket, position;

    public double GainAhead { get; private set; }
    public bool HasProfile { get { return slopes != null; } }

    public TpvRouteChart() {
        for (int i = 0; i < SlopeColors.Length; i++) {
            SolidColorBrush brush = TpvChartPaint.Brush(SlopeColors[i]);
            solid[i] = brush;
            dim[i] = TpvChartPaint.Faded(brush, 70);
        }
    }

    public void ClearProfile() {
        if (slopes == null) return;
        slopes = null;
        elevation = null;
        GainAhead = 0;
        if (IsVisible) InvalidateVisual();
    }

    // Unknown stretches are NaN: they are left blank instead of being drawn as flat road.
    public void SetProfile(double[] gradients, double startMeters, double size) {
        slopes = gradients;
        start = startMeters;
        bucket = size;
        elevation = new double[gradients.Length + 1];
        for (int i = 0; i < gradients.Length; i++) {
            elevation[i + 1] = elevation[i] + (double.IsNaN(gradients[i]) ? 0 : gradients[i] / 100 * size);
        }
    }

    public void SetPosition(double meters) {
        position = meters;
        double gain = 0;
        if (slopes != null) {
            for (int i = 0; i < slopes.Length; i++) {
                if (double.IsNaN(slopes[i]) || slopes[i] <= 0) continue;
                double from = Math.Max(start + i * bucket, position), to = Math.Min(start + (i + 1) * bucket, position + Ahead);
                if (to > from) gain += (to - from) * slopes[i] / 100;
            }
        }
        GainAhead = gain;
        if (IsVisible) InvalidateVisual();
    }

    double ElevationAt(double meters) {
        double index = Math.Max(0, Math.Min(slopes.Length - 0.001, (meters - start) / bucket));
        int i = (int)Math.Floor(index);
        return elevation[i] + (index - i) * (elevation[i + 1] - elevation[i]);
    }

    static int ColorOf(double slope) { return slope < 0 ? 0 : slope < 3 ? 1 : slope < 6 ? 2 : slope < 9 ? 3 : 4; }

    protected override void OnRender(DrawingContext dc) {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 1 || h <= 1) return;
        Rect area = new Rect(0, 0, w, h);
        dc.DrawRoundedRectangle(TpvChartPaint.Track, null, area, 4, 4);
        if (slopes == null) return;
        dc.PushClip(new RectangleGeometry(area, 4, 4));

        double left = position - Past, right = position + Ahead, low = double.MaxValue, high = double.MinValue;
        for (int i = 0; i < slopes.Length; i++) {
            double a = Math.Max(start + i * bucket, left), b = Math.Min(start + (i + 1) * bucket, right);
            if (b <= a || double.IsNaN(slopes[i])) continue;
            foreach (double m in new[] { a, b }) {
                double e = ElevationAt(m);
                if (e < low) low = e;
                if (e > high) high = e;
            }
        }
        double scale = w / (Past + Ahead);
        // A guide line at a round distance, at most six of them.
        double step = 100;
        foreach (double candidate in new double[] { 100, 200, 250, 500, 1000, 2000, 2500, 5000 }) { step = candidate; if (Ahead / candidate <= 6) break; }
        for (double mark = step; mark <= Ahead + 0.5; mark += step) {
            double x = (Past + mark) * scale;
            dc.DrawLine(TpvChartPaint.Guide, new Point(x, 0), new Point(x, h));
        }
        if (high >= low) {
            // At least 30 m of height, so that a flat road does not look like a wall.
            double range = Math.Max(30, high - low), floor = low - (range - (high - low)) / 2, usable = h - 12;
            Func<double, double> toY = e => h - 3 - (e - floor) / range * usable;
            StreamGeometry[] shapes = new StreamGeometry[solid.Length * 2];
            StreamGeometryContext[] draw = new StreamGeometryContext[solid.Length * 2];
            Action<double, double, int> piece = (a, b, slot) => {
                if (b <= a) return;
                if (draw[slot] == null) { shapes[slot] = new StreamGeometry(); draw[slot] = shapes[slot].Open(); }
                double x1 = (a - left) * scale, x2 = (b - left) * scale;
                draw[slot].BeginFigure(new Point(x1, toY(ElevationAt(a))), true, true);
                draw[slot].LineTo(new Point(x2, toY(ElevationAt(b))), false, false);
                draw[slot].LineTo(new Point(x2, h), false, false);
                draw[slot].LineTo(new Point(x1, h), false, false);
            };
            for (int i = 0; i < slopes.Length; i++) {
                if (double.IsNaN(slopes[i])) continue;
                double a = Math.Max(start + i * bucket, left), b = Math.Min(start + (i + 1) * bucket, right);
                int color = ColorOf(slopes[i]);
                piece(a, Math.Min(b, position), color + solid.Length);
                piece(Math.Max(a, position), b, color);
            }
            for (int s = 0; s < shapes.Length; s++) {
                if (draw[s] == null) continue;
                draw[s].Close();
                shapes[s].Freeze();
                dc.DrawGeometry(s < solid.Length ? solid[s] : dim[s - solid.Length], null, shapes[s]);
            }
            double markerX = Past * scale, markerY = toY(ElevationAt(position));
            dc.DrawLine(TpvChartPaint.Marker, new Point(markerX, 0), new Point(markerX, h));
            dc.DrawEllipse(TpvChartPaint.White, null, new Point(markerX, markerY), 3.5, 3.5);
        }
        dc.Pop();
    }
}
'@
