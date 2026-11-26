# The dials: W'bal, power, draft + braking, and wind. Compiled, and redrawn only when a displayed value changes.
# One layout for all: the largest dial for the block, the values made as large as the space left allows,
# and the whole group centered, so that a dial fills its block whatever its shape.
Add-Type -ReferencedAssemblies ([Windows.FrameworkElement].Assembly.Location), ([Windows.UIElement].Assembly.Location), ([Windows.Threading.Dispatcher].Assembly.Location), 'System.Xaml' @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Windows;
using System.Windows.Media;

// One line of text: its size relative to the block's text size, and an optional color swatch before it.
public sealed class TpvLine {
    public string Text; public double Rel; public Brush Brush; public Typeface Face; public Brush Swatch; public double SwatchRel;
    public TpvLine(string text, double rel, Brush brush, Typeface face) { Text = text ?? ""; Rel = rel; Brush = brush; Face = face; }
}

// A group of lines drawn together, such as a title and its value.
public sealed class TpvCell {
    public readonly List<TpvLine> Lines = new List<TpvLine>();
    public TpvCell Add(string text, double rel, Brush brush, Typeface face) { Lines.Add(new TpvLine(text, rel, brush, face)); return this; }
    public TpvCell AddSwatch(string text, double rel, Brush brush, Typeface face, Brush swatch, double swatchRel) {
        TpvLine line = new TpvLine(text, rel, brush, face); line.Swatch = swatch; line.SwatchRel = swatchRel; Lines.Add(line); return this;
    }
}

public sealed class TpvTextPlan { public double Size; public bool Row; public double Width, Height; }

public sealed class TpvDialPlace { public double R, Cx, Cy; public bool Beside; public Rect Text; public TpvTextPlan Plan; }

static class TpvDialKit {
    public static readonly Brush Track = Paint("#3D4A6E"), White = Paint("#FFFFFF"), Label = Paint("#9DBBFF"), Soft = Paint("#C5D3F5"), Red = Paint("#FF3B30"), Separator = Paint("#0B1A52");
    public static readonly Typeface Regular = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.SemiBold, FontStretches.Normal);
    public static readonly Typeface Bold = new Typeface(new FontFamily("Segoe UI"), FontStyles.Normal, FontWeights.Bold, FontStretches.Normal);
    const double LineGap = 1.28, RowGap = 0.9, ColumnGap = 0.35, Spacing = 8, TitleBand = 14;

    public static Brush Paint(string color) {
        SolidColorBrush brush = (SolidColorBrush)new BrushConverter().ConvertFromString(color);
        brush.Freeze();
        return brush;
    }

    public static Brush Faded(Brush source, byte alpha) {
        Color c = ((SolidColorBrush)source).Color;
        SolidColorBrush brush = new SolidColorBrush(Color.FromArgb(alpha, c.R, c.G, c.B));
        brush.Freeze();
        return brush;
    }

    public static Brush Mix(Color a, Color b, double mix, byte alpha) {
        mix = Math.Max(0, Math.Min(1, mix));
        SolidColorBrush brush = new SolidColorBrush(Color.FromArgb(alpha, (byte)(a.R + (b.R - a.R) * mix), (byte)(a.G + (b.G - a.G) * mix), (byte)(a.B + (b.B - a.B) * mix)));
        brush.Freeze();
        return brush;
    }

    // Position on the half circle: 0 is bottom left, 1 is bottom right.
    public static Point At(double share, double cx, double cy, double r) {
        double angle = Math.PI * (1 - Math.Max(0, Math.Min(1, share)));
        return new Point(cx + r * Math.Cos(angle), cy - r * Math.Sin(angle));
    }

    public static Pen Stroke(Brush brush, double thickness, PenLineCap cap) {
        Pen pen = new Pen(brush, thickness);
        pen.StartLineCap = cap;
        pen.EndLineCap = cap;
        pen.Freeze();
        return pen;
    }

    public static void Arc(DrawingContext dc, Pen pen, double from, double to, double cx, double cy, double r) {
        if (to - from < 0.002) return;
        StreamGeometry shape = new StreamGeometry();
        using (StreamGeometryContext draw = shape.Open()) {
            draw.BeginFigure(At(from, cx, cy, r), false, false);
            draw.ArcTo(At(to, cx, cy, r), new Size(r, r), 0, false, SweepDirection.Clockwise, true, false);
        }
        shape.Freeze();
        dc.DrawGeometry(null, pen, shape);
    }

    static FormattedText Shape(Visual owner, string text, double size, Brush brush, Typeface face) {
        return new FormattedText(text, CultureInfo.InvariantCulture, FlowDirection.LeftToRight, face, Math.Max(1, size), brush, VisualTreeHelper.GetDpi(owner).PixelsPerDip);
    }

    public static void Text(Visual owner, DrawingContext dc, string text, double size, Brush brush, Typeface face, double x, double top, double align) {
        FormattedText shaped = Shape(owner, text, size, brush, face);
        dc.DrawText(shaped, new Point(x - shaped.Width * align, top));
    }

    public static double Thick(double r) { return Math.Max(9, r * 0.15); }
    public static double Grow(double r) { return Math.Max(1, Math.Min(1.6, r / 80)); }

    public static bool Same(double a, double b, double tolerance) {
        if (double.IsNaN(a) || double.IsNaN(b)) return double.IsNaN(a) && double.IsNaN(b);
        return Math.Abs(a - b) < tolerance;
    }

    // ---- text blocks ----
    static double LineWidth(Visual owner, TpvLine line, double size) {
        double w = line.Text.Length == 0 ? 0 : Shape(owner, line.Text, line.Rel * size, line.Brush, line.Face).Width;
        if (line.Swatch != null) w += line.Rel * size * 2.6;
        return w;
    }
    static double CellWidth(Visual owner, TpvCell cell, double size) { return cell.Lines.Count == 0 ? 0 : cell.Lines.Max(l => LineWidth(owner, l, size)); }
    static double CellHeight(TpvCell cell) { return cell.Lines.Sum(l => l.Rel * LineGap); }

    // The largest text size that fits: the cells side by side, or one under the other.
    public static TpvTextPlan FitText(Visual owner, List<TpvCell> cells, double width, double height, double cap, bool allowRow) {
        TpvTextPlan plan = new TpvTextPlan();
        int n = cells.Count;
        if (n == 0 || width <= 0 || height <= 0) return plan;
        const double probe = 20;
        double[] widths = cells.Select(c => CellWidth(owner, c, probe) / probe).ToArray();
        double[] heights = cells.Select(c => CellHeight(c)).ToArray();
        double row = allowRow ? Math.Min(widths.Min(x => (width / n) / (x + RowGap)), height / heights.Max()) : 0;
        double column = Math.Min(width / (widths.Max() + 0.2), height / (heights.Sum() + ColumnGap * (n - 1)));
        plan.Row = row > column;
        plan.Size = Math.Max(1, Math.Min(cap, Math.Max(row, column)));
        plan.Width = plan.Row ? width : (widths.Max() + 0.2) * plan.Size;
        plan.Height = (plan.Row ? heights.Max() : heights.Sum() + ColumnGap * (n - 1)) * plan.Size;
        return plan;
    }

    public static void DrawCells(Visual owner, DrawingContext dc, List<TpvCell> cells, TpvTextPlan plan, Rect area) {
        int n = cells.Count;
        if (n == 0 || plan.Size <= 1) return;
        double s = plan.Size, top = area.Top + (area.Height - plan.Height) / 2;
        for (int i = 0; i < n; i++) {
            double x = plan.Row ? area.Left + area.Width * (2 * i + 1) / (2 * n) : area.Left + area.Width / 2;
            double y = plan.Row ? top + (plan.Height - CellHeight(cells[i]) * s) / 2 : top;
            foreach (TpvLine line in cells[i].Lines) {
                double size = line.Rel * s, start = x - LineWidth(owner, line, s) / 2;
                if (line.Swatch != null) {
                    double thick = Math.Max(2, size * line.SwatchRel), middle = y + size * 0.68;
                    dc.DrawRoundedRectangle(line.Swatch, null, new Rect(start, middle - thick / 2, size * 2, thick), thick / 2, thick / 2);
                    start += size * 2.6;
                }
                if (line.Text.Length > 0) Text(owner, dc, line.Text, size, line.Brush, line.Face, start, y, 0);
                y += size * LineGap;
            }
            if (!plan.Row) top += (CellHeight(cells[i]) + ColumnGap) * s;
        }
    }

    // Smallest room the text needs at its minimum size: as a row or a column under the dial, or a column beside it.
    static double NeededHeight(Visual owner, List<TpvCell> cells, double width, double minSize) {
        if (cells.Count == 0) return 0;
        const double probe = 20;
        double[] widths = cells.Select(c => CellWidth(owner, c, probe) / probe).ToArray();
        double[] heights = cells.Select(c => CellHeight(c)).ToArray();
        double best = double.PositiveInfinity;
        if (widths.All(x => (x + RowGap) * minSize <= width / cells.Count)) best = heights.Max() * minSize;
        if ((widths.Max() + 0.2) * minSize <= width) best = Math.Min(best, (heights.Sum() + ColumnGap * (cells.Count - 1)) * minSize);
        return best;
    }

    static double ColumnWidth(Visual owner, List<TpvCell> cells, double minSize) {
        if (cells.Count == 0) return 0;
        return cells.Max(c => CellWidth(owner, c, 20) / 20 + 0.2) * minSize;
    }

    static double ColumnHeight(List<TpvCell> cells, double minSize) {
        return (cells.Sum(c => CellHeight(c)) + ColumnGap * Math.Max(0, cells.Count - 1)) * minSize;
    }

    static double Largest(Func<double, bool> fits) {
        double low = 0, high = 4000;
        if (!fits(8)) return 8;
        low = 8;
        for (int i = 0; i < 40 && high - low > 0.25; i++) {
            double middle = (low + high) / 2;
            if (fits(middle)) low = middle; else high = middle;
        }
        return low;
    }

    // Places a dial of radius r (half width, extent above and below its center) and its text in a w x h block.
    public static TpvDialPlace Place(Visual owner, double w, double h, Func<double, double> halfWidth, Func<double, double> above, Func<double, double> below,
                                     List<TpvCell> cells, double minSize, Func<double, double> cap) {
        double room = h - TitleBand;
        double stackedR = Largest(r => 2 * halfWidth(r) <= w && above(r) + below(r) + (cells.Count > 0 ? Spacing + NeededHeight(owner, cells, w, minSize) : 0) <= room);
        double besideR = cells.Count == 0 ? 0 : Largest(r => 2 * halfWidth(r) + Spacing + ColumnWidth(owner, cells, minSize) <= w && above(r) + below(r) <= room && ColumnHeight(cells, minSize) <= room);
        TpvDialPlace place = new TpvDialPlace();
        place.Beside = besideR > stackedR * 1.05;
        double rr = place.Beside ? besideR : stackedR;
        place.R = rr;
        double dialW = 2 * halfWidth(rr), dialH = above(rr) + below(rr);
        if (place.Beside) {
            place.Plan = FitText(owner, cells, w - dialW - Spacing, room, cap(rr), false);
            double total = dialW + Spacing + place.Plan.Width, left = Math.Max(0, (w - total) / 2);
            place.Cx = left + dialW / 2;
            place.Cy = TitleBand + (room - dialH) / 2 + above(rr);
            place.Text = new Rect(left + dialW + Spacing, TitleBand, place.Plan.Width, room);
        } else {
            place.Plan = FitText(owner, cells, w, Math.Max(1, room - dialH - Spacing), cap(rr), true);
            double total = dialH + (cells.Count > 0 ? Spacing + place.Plan.Height : 0), top = TitleBand + Math.Max(0, (room - total) / 2);
            place.Cx = w / 2;
            place.Cy = top + above(rr);
            place.Text = new Rect(0, top + dialH + Spacing, w, place.Plan.Height);
        }
        return place;
    }

    // The half dials: the scale numbers around the arc, and what is written under the center.
    public static TpvDialPlace PlaceHalf(Visual owner, double w, double h, List<TpvCell> cells, Func<double, double> underCenter) {
        return PlaceHalf(owner, w, h, cells, underCenter, 15, r => Math.Max(15, Math.Min(34, r * 0.24)));
    }

    public static TpvDialPlace PlaceHalf(Visual owner, double w, double h, List<TpvCell> cells, Func<double, double> underCenter, double minSize, Func<double, double> cap) {
        return Place(owner, w, h,
            r => r + Thick(r) / 2 + 27,
            r => r + Thick(r) / 2 + 26,
            r => Math.Max(12, underCenter(r)),
            cells, minSize, cap);
    }

    public static void Scale(Visual owner, DrawingContext dc, double[] marks, double max, double cx, double cy, double r, double thickness, double strong) {
        foreach (double mark in marks) {
            double at = mark / max;
            bool key = mark == strong;
            if (mark > 0 && mark < max) dc.DrawLine(Stroke(Separator, key ? 3 : 2, PenLineCap.Flat), At(at, cx, cy, r - thickness / 2), At(at, cx, cy, r + thickness / 2));
            dc.DrawLine(Stroke(key ? White : Label, key ? 2.5 : 2, PenLineCap.Flat), At(at, cx, cy, r + thickness / 2 + 1), At(at, cx, cy, r + thickness / 2 + 8));
            Point place = At(at, cx, cy, r + thickness / 2 + 17);
            Text(owner, dc, mark.ToString("0", CultureInfo.InvariantCulture), 12.5, Label, Regular, place.X, place.Y - 9, 0.5);
        }
    }

    public static TpvCell Stat(string title, string value) {
        return new TpvCell().Add(title, 0.66, Label, Bold).Add(value, 1, White, Bold);
    }
}

// W'bal: every W'bal value in one block.
public sealed class TpvWbalGauge : FrameworkElement {
    static readonly Brush Orange = TpvDialKit.Paint("#EF8A52"), Green = TpvDialKit.Paint("#68DF31"), Burn = TpvDialKit.Paint("#70FFFFFF");
    static readonly Color[] LevelColors = {
        Color.FromRgb(0xE0, 0x35, 0x2B), Color.FromRgb(0xEF, 0x8A, 0x52), Color.FromRgb(0xE7, 0xC0, 0x3F),
        Color.FromRgb(0xB4, 0xDC, 0x38), Color.FromRgb(0x68, 0xDF, 0x31)
    };

    double percent = double.NaN, kilojoules, lowest = double.NaN, drop, maxDrop, effortStart = double.NaN;
    string status = "", message = "--";

    // Red when empty, through orange and yellow, to green when full.
    static Brush LevelBrush(double pct) {
        double position = Math.Max(0, Math.Min(100, pct)) / 25;
        int low = Math.Min(3, (int)Math.Floor(position));
        return TpvDialKit.Mix(LevelColors[low], LevelColors[low + 1], position - low, 255);
    }

    public void SetValues(double pct, double kj, double low, double dropKj, double maxDropKj, double startPct, string state) {
        bool same = TpvDialKit.Same(percent, pct, 0.1) && TpvDialKit.Same(kilojoules, kj, 0.05) && TpvDialKit.Same(lowest, low, 0.1) && TpvDialKit.Same(drop, dropKj, 0.05)
            && TpvDialKit.Same(maxDrop, maxDropKj, 0.05) && TpvDialKit.Same(effortStart, startPct, 0.1) && status == state;
        if (same) return;
        percent = pct; kilojoules = kj; lowest = low; drop = dropKj; maxDrop = maxDropKj; effortStart = startPct; status = state;
        if (IsVisible) InvalidateVisual();
    }

    public void ShowMessage(string text) {
        if (double.IsNaN(percent) && message == text) return;
        percent = double.NaN;
        message = text;
        if (IsVisible) InvalidateVisual();
    }

    protected override Size MeasureOverride(Size available) { return new Size(0, 168); }

    protected override void OnRender(DrawingContext dc) {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 40 || h <= 60) return;
        CultureInfo inv = CultureInfo.InvariantCulture;
        bool known = !double.IsNaN(percent);
        string low = double.IsNaN(lowest) ? "--" : Math.Round(lowest).ToString("0", inv) + " %";
        List<TpvCell> cells = known ? new List<TpvCell> {
            TpvDialKit.Stat("DROP", drop.ToString("0.0", inv) + " kJ"),
            TpvDialKit.Stat("MAX DROP", maxDrop.ToString("0.0", inv) + " kJ"),
            TpvDialKit.Stat("LOWEST", low)
        } : new List<TpvCell>();
        TpvDialPlace p = TpvDialKit.PlaceHalf(this, w, h, cells, r => 3 + 13 * TpvDialKit.Grow(r) * 1.35);
        double r0 = p.R, cx = p.Cx, cy = p.Cy, thickness = TpvDialKit.Thick(r0), grow = TpvDialKit.Grow(r0);
        TpvDialKit.Text(this, dc, "W'BAL", 11, TpvDialKit.Label, TpvDialKit.Bold, 0, 0, 0);
        TpvDialKit.Arc(dc, TpvDialKit.Stroke(TpvDialKit.Track, thickness, PenLineCap.Round), 0, 1, cx, cy, r0);
        double[] marks = { 0, 25, 50, 75, 100 };
        if (!known) {
            TpvDialKit.Scale(this, dc, marks, 100, cx, cy, r0, thickness, -1);
            TpvDialKit.Text(this, dc, message, 15 * grow, TpvDialKit.Soft, TpvDialKit.Bold, cx, cy - 18 * grow, 0.5);
            return;
        }
        TpvDialKit.Arc(dc, TpvDialKit.Stroke(LevelBrush(percent), thickness, PenLineCap.Round), 0, percent / 100, cx, cy, r0);
        // What the current effort has burned, from its start down to now.
        if (!double.IsNaN(effortStart)) TpvDialKit.Arc(dc, TpvDialKit.Stroke(Burn, thickness, PenLineCap.Flat), percent / 100, effortStart / 100, cx, cy, r0);
        TpvDialKit.Scale(this, dc, marks, 100, cx, cy, r0, thickness, -1);
        // Lowest point of the ride.
        if (!double.IsNaN(lowest) && lowest < 99.5) {
            dc.DrawLine(TpvDialKit.Stroke(TpvDialKit.White, 2.5, PenLineCap.Round), TpvDialKit.At(lowest / 100, cx, cy, r0 - thickness / 2 - 2), TpvDialKit.At(lowest / 100, cx, cy, r0 + thickness / 2 + 3));
        }
        double big = Math.Max(22, Math.Min(90, r0 * 0.42));
        TpvDialKit.Text(this, dc, Math.Round(percent).ToString("0", inv) + " %", big, TpvDialKit.White, TpvDialKit.Bold, cx, cy - big * 1.75, 0.5);
        TpvDialKit.Text(this, dc, kilojoules.ToString("0.0", inv) + " kJ", 13 * grow, TpvDialKit.Soft, TpvDialKit.Regular, cx, cy - big * 0.42, 0.5);
        TpvDialKit.Text(this, dc, status, 13 * grow, status.StartsWith("EMPTY") ? Orange : Green, TpvDialKit.Bold, cx, cy + 3, 0.5);
        TpvDialKit.DrawCells(this, dc, cells, p.Plan, p.Text);
    }
}

// Power as a share of FTP, on the game's zones, from 0 to 200 %.
public sealed class TpvPowerDial : FrameworkElement {
    const double ScaleMax = 2.0;
    static readonly double[] Limits = { 0, 0.55, 0.75, 0.90, 1.05, 1.20, 1.50, ScaleMax };
    static readonly Brush[] Zones = {
        TpvDialKit.Paint("#8A8F9A"), TpvDialKit.Paint("#2F6FD6"), TpvDialKit.Paint("#3DA62E"), TpvDialKit.Paint("#C8A400"),
        TpvDialKit.Paint("#D0620F"), TpvDialKit.Paint("#D42A20"), TpvDialKit.Paint("#9B55C4")
    };

    double power = double.NaN, ftp, power30 = double.NaN, wkg = double.NaN;

    public void SetValues(double watts, double ftpWatts, double average30, double wattsPerKg) {
        if (TpvDialKit.Same(power, watts, 0.5) && TpvDialKit.Same(ftp, ftpWatts, 0.5) && TpvDialKit.Same(power30, average30, 0.5) && TpvDialKit.Same(wkg, wattsPerKg, 0.01)) return;
        power = watts; ftp = ftpWatts; power30 = average30; wkg = wattsPerKg;
        if (IsVisible) InvalidateVisual();
    }

    protected override Size MeasureOverride(Size available) { return new Size(0, 168); }

    protected override void OnRender(DrawingContext dc) {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 40 || h <= 60) return;
        CultureInfo inv = CultureInfo.InvariantCulture;
        bool known = !double.IsNaN(power) && ftp > 0;
        double share = known ? power / ftp : 0;
        int zone = 0;
        for (int i = 0; i < Zones.Length; i++) if (known && share >= Limits[i]) zone = i;
        List<TpvCell> cells = known ? new List<TpvCell> {
            TpvDialKit.Stat("W/KG 30S", double.IsNaN(wkg) ? "--" : wkg.ToString("0.00", inv)),
            TpvDialKit.Stat("POWER 30S", double.IsNaN(power30) ? "--" : Math.Round(power30).ToString("0", inv) + " W"),
            TpvDialKit.Stat("ZONE", "Z" + (zone + 1).ToString(inv))
        } : new List<TpvCell>();
        TpvDialPlace p = TpvDialKit.PlaceHalf(this, w, h, cells, r => 12);
        double r0 = p.R, cx = p.Cx, cy = p.Cy, thickness = TpvDialKit.Thick(r0), grow = TpvDialKit.Grow(r0);
        TpvDialKit.Text(this, dc, "POWER", 11, TpvDialKit.Label, TpvDialKit.Bold, 0, 0, 0);
        for (int i = 0; i < Zones.Length; i++) {
            double from = Limits[i] / ScaleMax, to = Limits[i + 1] / ScaleMax;
            TpvDialKit.Arc(dc, TpvDialKit.Stroke(TpvDialKit.Faded(Zones[i], 75), thickness, PenLineCap.Flat), from, to, cx, cy, r0);
            if (known) TpvDialKit.Arc(dc, TpvDialKit.Stroke(Zones[i], thickness, PenLineCap.Flat), from, Math.Min(to, share / ScaleMax), cx, cy, r0);
        }
        TpvDialKit.Scale(this, dc, new double[] { 0, 50, 100, 150, 200 }, 200, cx, cy, r0, thickness, 100);
        if (!known) {
            TpvDialKit.Text(this, dc, "--", 18 * grow, TpvDialKit.Soft, TpvDialKit.Bold, cx, cy - 22 * grow, 0.5);
            return;
        }
        // White tick: average of the last 30 seconds.
        if (!double.IsNaN(power30)) {
            double at = Math.Min(1, power30 / ftp / ScaleMax);
            dc.DrawLine(TpvDialKit.Stroke(TpvDialKit.White, 2.5, PenLineCap.Round), TpvDialKit.At(at, cx, cy, r0 - thickness / 2 - 2), TpvDialKit.At(at, cx, cy, r0 + thickness / 2 + 3));
        }
        double big = Math.Max(22, Math.Min(90, r0 * 0.42));
        TpvDialKit.Text(this, dc, Math.Round(power).ToString("0", inv) + " W", big, TpvDialKit.White, TpvDialKit.Bold, cx, cy - big * 1.75, 0.5);
        TpvDialKit.Text(this, dc, Math.Round(share * 100).ToString("0", inv) + " % FTP", 13 * grow, TpvDialKit.Soft, TpvDialKit.Regular, cx, cy - big * 0.42, 0.5);
        TpvDialKit.DrawCells(this, dc, cells, p.Plan, p.Text);
    }
}

// Two rings like the W'bal dial: draft outside, from orange to green; braking inside, from orange to red.
public sealed class TpvDraftBrakeDial : FrameworkElement {
    // Orange with no shelter, yellow at 25 %, lime at 50 %, full green from 75 %.
    static readonly Color[] DraftColors = { Color.FromRgb(0xEF, 0x8A, 0x52), Color.FromRgb(0xE7, 0xC0, 0x3F), Color.FromRgb(0xB4, 0xDC, 0x38), Color.FromRgb(0x68, 0xDF, 0x31) };
    static readonly double[] DraftStops = { 0, 0.25, 0.5, 0.75 };
    static readonly Color BrakeLow = Color.FromRgb(0xEF, 0x8A, 0x52), BrakeHigh = Color.FromRgb(0xFF, 0x3B, 0x30);
    static readonly Brush InnerTrack = TpvDialKit.Paint("#2E3A5C");

    double draft = double.NaN, brake;
    bool estimated;

    public void SetValues(double draftPercent, double brakePercent, bool brakeEstimated) {
        if (TpvDialKit.Same(draft, draftPercent, 0.5) && TpvDialKit.Same(brake, brakePercent, 0.5) && estimated == brakeEstimated) return;
        draft = draftPercent; brake = brakePercent; estimated = brakeEstimated;
        if (IsVisible) InvalidateVisual();
    }

    static Brush DraftBrush(double share) {
        int low = 0;
        while (low < DraftStops.Length - 2 && share >= DraftStops[low + 1]) low++;
        return TpvDialKit.Mix(DraftColors[low], DraftColors[low + 1], (share - DraftStops[low]) / (DraftStops[low + 1] - DraftStops[low]), 255);
    }

    protected override Size MeasureOverride(Size available) { return new Size(0, 168); }

    protected override void OnRender(DrawingContext dc) {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 40 || h <= 60) return;
        CultureInfo inv = CultureInfo.InvariantCulture;
        // Legend: a thick stroke for the draft ring, a thin one for the braking ring.
        List<TpvCell> cells = new List<TpvCell> {
            new TpvCell().AddSwatch("DRAFT", 1, DraftBrush(1), TpvDialKit.Bold, DraftBrush(1), 0.8),
            new TpvCell().AddSwatch("BRAKE", 1, TpvDialKit.Red, TpvDialKit.Bold, TpvDialKit.Red, 0.4)
        };
        // The legend stays small: it only names the rings, the dial gets the room.
        TpvDialPlace p = TpvDialKit.PlaceHalf(this, w, h, cells, r => 4 + 14 * TpvDialKit.Grow(r) * 1.35, 10, r => Math.Max(11, Math.Min(14, r * 0.1)));
        double r0 = p.R, cx = p.Cx, cy = p.Cy, thickness = TpvDialKit.Thick(r0), grow = TpvDialKit.Grow(r0), inner = Math.Max(7, thickness * 0.8);
        double r2 = r0 - thickness / 2 - 5 - inner / 2;
        TpvDialKit.Text(this, dc, "DRAFT / BRAKE", 11, TpvDialKit.Label, TpvDialKit.Bold, 0, 0, 0);

        // Outer ring: draft.
        double draftShare = double.IsNaN(draft) ? 0 : Math.Max(0, Math.Min(100, draft)) / 100;
        TpvDialKit.Arc(dc, TpvDialKit.Stroke(TpvDialKit.Track, thickness, PenLineCap.Round), 0, 1, cx, cy, r0);
        if (draftShare > 0.005) TpvDialKit.Arc(dc, TpvDialKit.Stroke(DraftBrush(draftShare), thickness, PenLineCap.Round), 0, draftShare, cx, cy, r0);
        // Inner ring: braking.
        double brakeShare = Math.Max(0, Math.Min(100, brake)) / 100;
        TpvDialKit.Arc(dc, TpvDialKit.Stroke(InnerTrack, inner, PenLineCap.Round), 0, 1, cx, cy, r2);
        Brush brakeColor = estimated ? TpvDialKit.Red : TpvDialKit.Mix(BrakeLow, BrakeHigh, brakeShare * 1.5, 255);
        if (brakeShare > 0.005) TpvDialKit.Arc(dc, TpvDialKit.Stroke(brakeColor, inner, PenLineCap.Round), 0, brakeShare, cx, cy, r2);

        // Graduations every 25 %, on both rings, with the values outside.
        TpvDialKit.Scale(this, dc, new double[] { 0, 25, 50, 75, 100 }, 100, cx, cy, r0, thickness, -1);
        foreach (double mark in new double[] { 25, 50, 75 }) {
            dc.DrawLine(TpvDialKit.Stroke(TpvDialKit.Separator, 2, PenLineCap.Flat), TpvDialKit.At(mark / 100, cx, cy, r2 - inner / 2), TpvDialKit.At(mark / 100, cx, cy, r2 + inner / 2));
        }

        // Center: draft value and braking state, each in the color of its ring.
        double big = Math.Max(20, Math.Min(84, r2 * 0.5));
        string value = double.IsNaN(draft) ? "--" : Math.Round(draft).ToString("0", inv) + " %";
        Brush draftColor = DraftBrush(draftShare);
        TpvDialKit.Text(this, dc, value, big, double.IsNaN(draft) ? TpvDialKit.Soft : draftColor, TpvDialKit.Bold, cx, cy - big * 1.6, 0.5);
        TpvDialKit.Text(this, dc, "DRAFT", 11 * grow, draftColor, TpvDialKit.Bold, cx, cy - big * 0.3, 0.5);
        bool braking = brake > 0;
        string state = braking ? (estimated ? "BRAKE ON" : "BRAKE " + Math.Round(brake).ToString("0", inv) + " %") : "BRAKE OFF";
        TpvDialKit.Text(this, dc, state, 14 * grow, braking ? TpvDialKit.Red : TpvDialKit.Soft, TpvDialKit.Bold, cx, cy + 4, 0.5);
        TpvDialKit.DrawCells(this, dc, cells, p.Plan, p.Text);
    }
}

// Wind relative to the rider, seen from above. The rider points up; the arrows blow from where the wind comes from.
// The game gives windAngle = where the wind comes from, clockwise from straight ahead (0 head, 90 right, 180 tail).
public sealed class TpvWindDial : FrameworkElement {
    static readonly Color HeadColor = Color.FromRgb(0xFF, 0x3B, 0x30), CrossColor = Color.FromRgb(0xE7, 0xC0, 0x3F), TailColor = Color.FromRgb(0x68, 0xDF, 0x31);
    static readonly Brush RiderBrush = TpvDialKit.Paint("#FFFFFF"), BikeBrush = TpvDialKit.Paint("#9DBBFF"), Calm = TpvDialKit.Paint("#C5D3F5");
    const double CalmBelow = 0.5, Reach = 1.2;

    double angle = double.NaN, speed;

    public void SetValues(double fromDegrees, double metersPerSecond) {
        if (TpvDialKit.Same(angle, fromDegrees, 2) && TpvDialKit.Same(speed, metersPerSecond, 0.1)) return;
        angle = fromDegrees; speed = metersPerSecond;
        if (IsVisible) InvalidateVisual();
    }

    public void Clear() {
        if (double.IsNaN(angle)) return;
        angle = double.NaN; speed = 0;
        if (IsVisible) InvalidateVisual();
    }

    // Red against you, yellow across, green pushing you.
    static Brush WindBrush(double degrees, byte alpha) {
        double head = Math.Cos(degrees * Math.PI / 180);
        return head >= 0 ? TpvDialKit.Mix(CrossColor, HeadColor, head, alpha) : TpvDialKit.Mix(CrossColor, TailColor, -head, alpha);
    }

    static string Kind(double degrees, out string where) {
        double n = ((degrees % 360) + 360) % 360;
        double off = n <= 180 ? n : 360 - n;
        string side = n < 180 ? "FROM THE RIGHT" : "FROM THE LEFT";
        if (off <= 25) { where = "FROM THE FRONT"; return "HEADWIND"; }
        if (off < 65) { where = side; return "HEAD-CROSSWIND"; }
        if (off <= 115) { where = side; return "CROSSWIND"; }
        if (off < 155) { where = side; return "TAIL-CROSSWIND"; }
        where = "FROM BEHIND";
        return "TAILWIND";
    }

    static Point Polar(double cx, double cy, double degrees, double radius) {
        double a = degrees * Math.PI / 180;
        return new Point(cx + radius * Math.Sin(a), cy - radius * Math.Cos(a));
    }

    static void Sector(DrawingContext dc, Brush brush, double thickness, double cx, double cy, double r, double from, double to) {
        StreamGeometry shape = new StreamGeometry();
        using (StreamGeometryContext draw = shape.Open()) {
            draw.BeginFigure(Polar(cx, cy, from, r), false, false);
            draw.ArcTo(Polar(cx, cy, to, r), new Size(r, r), 0, to - from > 180, SweepDirection.Clockwise, true, false);
        }
        shape.Freeze();
        dc.DrawGeometry(null, TpvDialKit.Stroke(brush, thickness, PenLineCap.Flat), shape);
    }

    static void Arrow(DrawingContext dc, Brush brush, Point from, Point to, double thickness) {
        double dx = to.X - from.X, dy = to.Y - from.Y, length = Math.Sqrt(dx * dx + dy * dy);
        if (length < 1) return;
        dx /= length; dy /= length;
        double head = Math.Min(length * 0.55, thickness * 3.2);
        Point neck = new Point(to.X - dx * head * 0.8, to.Y - dy * head * 0.8);
        dc.DrawLine(TpvDialKit.Stroke(brush, thickness, PenLineCap.Round), from, neck);
        StreamGeometry tip = new StreamGeometry();
        using (StreamGeometryContext draw = tip.Open()) {
            Point back = new Point(to.X - dx * head, to.Y - dy * head);
            draw.BeginFigure(to, true, true);
            draw.LineTo(new Point(back.X - dy * head * 0.62, back.Y + dx * head * 0.62), true, true);
            draw.LineTo(new Point(back.X + dy * head * 0.62, back.Y - dx * head * 0.62), true, true);
        }
        tip.Freeze();
        dc.DrawGeometry(brush, null, tip);
    }

    protected override Size MeasureOverride(Size available) { return new Size(0, 168); }

    protected override void OnRender(DrawingContext dc) {
        double w = ActualWidth, h = ActualHeight;
        if (w <= 40 || h <= 60) return;
        CultureInfo inv = CultureInfo.InvariantCulture;
        bool known = !double.IsNaN(angle);
        bool calm = known && speed < CalmBelow;
        Brush color = known && !calm ? WindBrush(angle, 255) : Calm;
        string kind = "--", where = "", amount = "", parts = "";
        if (known && calm) {
            kind = "NO WIND";
            amount = Math.Round(speed * 3.6).ToString("0", inv) + " km/h";
        } else if (known) {
            kind = Kind(angle, out where);
            amount = Math.Round(speed * 3.6).ToString("0", inv) + " km/h";
            double headPart = speed * 3.6 * Math.Cos(angle * Math.PI / 180), across = Math.Abs(speed * 3.6 * Math.Sin(angle * Math.PI / 180));
            parts = (headPart >= 0 ? "HEAD " : "TAIL ") + Math.Round(Math.Abs(headPart)).ToString("0", inv) + "  SIDE " + Math.Round(across).ToString("0", inv) + " km/h";
        }
        TpvCell text = new TpvCell().Add(kind, 0.7, color, TpvDialKit.Bold);
        if (where != "") text.Add(where, 0.52, color, TpvDialKit.Bold);
        if (amount != "") text.Add(amount, 1, TpvDialKit.White, TpvDialKit.Bold);
        if (parts != "") text.Add(parts, 0.52, TpvDialKit.Soft, TpvDialKit.Regular);
        List<TpvCell> cells = new List<TpvCell> { text };
        TpvDialPlace p = TpvDialKit.Place(this, w, h, r => r * Reach, r => r * Reach, r => r * Reach, cells, 22, r => Math.Max(22, Math.Min(52, r * 0.42)));
        double r0 = p.R, cx = p.Cx, cy = p.Cy;
        TpvDialKit.Text(this, dc, "WIND", 11, TpvDialKit.Label, TpvDialKit.Bold, 0, 0, 0);

        // Ring around the rider: what the wind does from each side.
        double ring = Math.Max(5, r0 * 0.09);
        Sector(dc, WindBrush(0, 120), ring, cx, cy, r0, -45, 45);
        Sector(dc, WindBrush(90, 120), ring, cx, cy, r0, 45, 135);
        Sector(dc, WindBrush(180, 120), ring, cx, cy, r0, 135, 225);
        Sector(dc, WindBrush(270, 120), ring, cx, cy, r0, 225, 315);
        foreach (double mark in new double[] { 45, 135, 225, 315 }) {
            dc.DrawLine(TpvDialKit.Stroke(TpvDialKit.Separator, 2, PenLineCap.Flat), Polar(cx, cy, mark, r0 - ring / 2 - 1), Polar(cx, cy, mark, r0 + ring / 2 + 1));
        }

        // The rider from above, heading up.
        double s = r0 * 0.40;
        dc.DrawLine(TpvDialKit.Stroke(BikeBrush, Math.Max(2.5, s * 0.13), PenLineCap.Round), new Point(cx, cy - s), new Point(cx, cy + s));
        dc.DrawLine(TpvDialKit.Stroke(BikeBrush, Math.Max(2, s * 0.10), PenLineCap.Round), new Point(cx - s * 0.36, cy - s * 0.58), new Point(cx + s * 0.36, cy - s * 0.58));
        dc.DrawEllipse(RiderBrush, null, new Point(cx, cy - s * 0.02), s * 0.27, s * 0.40);
        dc.DrawEllipse(BikeBrush, TpvDialKit.Stroke(RiderBrush, Math.Max(1.5, s * 0.06), PenLineCap.Flat), new Point(cx, cy - s * 0.42), s * 0.17, s * 0.17);
        StreamGeometry ahead = new StreamGeometry();
        using (StreamGeometryContext draw = ahead.Open()) {
            draw.BeginFigure(new Point(cx, cy - s * 1.42), true, true);
            draw.LineTo(new Point(cx - s * 0.2, cy - s * 1.15), true, true);
            draw.LineTo(new Point(cx + s * 0.2, cy - s * 1.15), true, true);
        }
        ahead.Freeze();
        dc.DrawGeometry(RiderBrush, null, ahead);

        if (known && !calm) {
            // Three streams blowing at the rider from where the wind comes from; thicker when stronger.
            double strength = Math.Min(1, speed / 8);
            double thick = Math.Max(4, r0 * (0.065 + 0.06 * strength));
            double a = angle * Math.PI / 180, px = Math.Cos(a), py = Math.Sin(a);
            double[] offsets = { 0, -0.3, 0.3 };
            for (int i = 0; i < 3; i++) {
                double o = offsets[i] * r0;
                double outer = i == 0 ? r0 * 1.12 : r0 * 0.98, innerEnd = i == 0 ? r0 * 0.52 : r0 * 0.50;
                Point start = Polar(cx, cy, angle, outer), end = Polar(cx, cy, angle, innerEnd);
                start.Offset(px * o, py * o);
                end.Offset(px * o, py * o);
                Arrow(dc, i == 0 ? color : WindBrush(angle, 170), start, end, i == 0 ? thick : thick * 0.65);
            }
        }
        TpvDialKit.DrawCells(this, dc, cells, p.Plan, p.Text);
    }
}
'@
