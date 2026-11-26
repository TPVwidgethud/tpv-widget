# Responsive block layout for the overlay. Compiled so that it costs nothing during a ride.
# Fills newspaper-style columns and picks the column count that gives the largest text for the window size.
Add-Type -ReferencedAssemblies ([Windows.Controls.Panel].Assembly.Location), ([Windows.UIElement].Assembly.Location), ([Windows.Threading.Dispatcher].Assembly.Location), 'System.Xaml' @'
using System;
using System.Collections.Generic;
using System.Linq;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

public sealed class TpvBlockPanel : Panel {
    const double Unit = 210, StackedWidth = 340, Gap = 6, MaxZoom = 2.5;
    const int MaxColumns = 6;

    sealed class Block {
        public string Key;
        public FrameworkElement Element;
        public int Span;
        public bool Full;
        public bool Beside;
        public double Natural;
        public Rect Slot;
        public double Scale = 1;
        // The block's own size, chosen in Edit layout: its content is drawn this much larger.
        public double Grow = 1;
        public ScaleTransform Transform;
    }

    // A horizontal slice of the layout: one full-width line, or a set of columns.
    sealed class Band {
        public bool Full;
        public List<List<List<Block>>> Columns;
        public double Height;
    }

    sealed class Plan {
        public List<Band> Bands;
        public int ColumnCount;
        public bool Paired;
        public double Width, Height;
    }

    readonly List<Block> blocks = new List<Block>();
    bool dirty = true, paired = true;
    Size solved;
    Block dragging, lastTarget;
    Point dragPoint;
    Vector grab;

    public double Zoom { get; private set; }
    public int Columns { get; private set; }

    const double BadgeWidth = 112, BadgeHeight = 28;
    readonly Border badge;
    readonly TextBlock badgeLabel;
    Block badgeBlock;

    public TpvBlockPanel() {
        Zoom = 1; Columns = 1;
        // Shown in Edit layout on the block under the mouse: - smaller, the size (click = 100 %), + larger.
        Grid inside = new Grid();
        for (int i = 0; i < 3; i++) inside.ColumnDefinitions.Add(new ColumnDefinition());
        string[] texts = { "\u2212", "100 %", "+" };
        for (int i = 0; i < 3; i++) {
            TextBlock text = new TextBlock { Text = texts[i], Foreground = Brushes.White, FontWeight = FontWeights.Bold, FontSize = i == 1 ? 12 : 18, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(text, i);
            inside.Children.Add(text);
        }
        badgeLabel = (TextBlock)inside.Children[1];
        badge = new Border {
            Child = inside, Background = new SolidColorBrush(Color.FromArgb(0xEE, 0x1D, 0x3A, 0x9E)), BorderBrush = Brushes.White,
            BorderThickness = new Thickness(1.5), CornerRadius = new CornerRadius(6), Visibility = Visibility.Collapsed, IsHitTestVisible = false
        };
        Panel.SetZIndex(badge, 5);
        Children.Add(badge);
    }

    public void ShowBadgeAt(Point p) {
        Block hit = dragging == null ? Visible().FirstOrDefault(b => b.Slot.Contains(p)) : null;
        if (hit == badgeBlock) return;
        badgeBlock = hit;
        UpdateBadge();
    }

    public void HideBadge() {
        if (badgeBlock == null) return;
        badgeBlock = null;
        UpdateBadge();
    }

    void UpdateBadge() {
        badge.Visibility = badgeBlock == null ? Visibility.Collapsed : Visibility.Visible;
        if (badgeBlock != null) badgeLabel.Text = Math.Round(badgeBlock.Grow * 100).ToString("0", System.Globalization.CultureInfo.InvariantCulture) + " %";
        InvalidateArrange();
    }

    Rect BadgeRect() {
        if (badgeBlock == null) return Rect.Empty;
        Rect slot = badgeBlock.Slot;
        return new Rect(Math.Max(slot.Left + 2, slot.Right - BadgeWidth - 4), slot.Top + 4, BadgeWidth, BadgeHeight);
    }

    // -1 on the minus, 1 on the plus, 9 on the size (back to 100 %), 0 outside the badge.
    public int HitBadge(Point p) {
        Rect r = BadgeRect();
        if (r.IsEmpty || !r.Contains(p)) return 0;
        double x = (p.X - r.Left) / r.Width;
        return x < 0.34 ? -1 : x > 0.66 ? 1 : 9;
    }

    public bool StepBadge(int direction) {
        if (badgeBlock == null || direction == 0) return false;
        badgeBlock.Grow = direction == 9 ? 1 : Math.Max(0.5, Math.Min(3, Math.Round((badgeBlock.Grow + 0.1 * direction) * 10) / 10));
        UpdateBadge();
        Refresh();
        return true;
    }

    public Rect SlotOf(string key) {
        Block b = Visible().FirstOrDefault(x => x.Key == key);
        return b == null ? Rect.Empty : b.Slot;
    }

    public string[] GetGrowList() {
        return blocks.Where(b => Math.Abs(b.Grow - 1) > 0.001).Select(b => b.Key + "=" + b.Grow.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture)).ToArray();
    }

    public void SetGrowList(string[] items) {
        foreach (Block b in blocks) b.Grow = 1;
        foreach (string item in items ?? new string[0]) {
            string[] pair = (item ?? "").Split('=');
            double value;
            if (pair.Length != 2 || !double.TryParse(pair[1], System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out value)) continue;
            Block b = blocks.FirstOrDefault(x => x.Key == pair[0]);
            if (b != null) b.Grow = Math.Max(0.5, Math.Min(3, value));
        }
        Refresh();
    }

    public void AddBlock(string key, FrameworkElement element, int span) {
        element.Margin = new Thickness(0);
        element.HorizontalAlignment = HorizontalAlignment.Stretch;
        element.VerticalAlignment = VerticalAlignment.Stretch;
        ScaleTransform transform = new ScaleTransform(1, 1);
        element.RenderTransform = transform;
        // A block taller than its content keeps the text centered instead of leaving it at the top.
        Border border = element as Border;
        if (border != null && !"fill".Equals(border.Tag) && border.Child is FrameworkElement) ((FrameworkElement)border.Child).VerticalAlignment = VerticalAlignment.Center;
        blocks.Add(new Block { Key = key, Element = element, Span = span, Transform = transform });
        Children.Add(element);
    }

    public int VisibleCount { get { return Visible().Count(); } }

    public void MoveBlockTo(string key, TpvBlockPanel target) {
        Block b = blocks.FirstOrDefault(x => x.Key == key);
        if (b == null || target == this) return;
        blocks.Remove(b);
        Children.Remove(b.Element);
        target.blocks.Add(b);
        target.Children.Add(b.Element);
        Refresh();
        target.Refresh();
    }

    public void MoveAllTo(TpvBlockPanel target) {
        foreach (string key in GetOrder()) MoveBlockTo(key, target);
    }

    // Continues a drag that started in another part of the widget.
    public void AdoptDrag(TpvBlockPanel source, Point p) {
        Block b = source.dragging;
        if (b == null || source == this) return;
        source.dragging = null;
        source.lastTarget = null;
        source.blocks.Remove(b);
        source.Children.Remove(b.Element);
        source.Refresh();
        blocks.Add(b);
        Children.Add(b.Element);
        dragging = b;
        lastTarget = null;
        dragPoint = p;
        Refresh();
    }

    public string[] GetOrder() { return blocks.Select(b => b.Key).ToArray(); }

    // Saved keys come first; blocks added in a later version keep their default place at the end.
    public void SetOrder(string[] keys) {
        List<Block> sorted = new List<Block>();
        foreach (string key in keys ?? new string[0]) {
            Block found = blocks.FirstOrDefault(b => b.Key == key);
            if (found != null && !sorted.Contains(found)) sorted.Add(found);
        }
        sorted.AddRange(blocks.Where(b => !sorted.Contains(b)));
        blocks.Clear();
        blocks.AddRange(sorted);
        Refresh();
    }

    public string[] GetFullKeys() { return blocks.Where(b => b.Full).Select(b => b.Key).ToArray(); }

    public void SetFullKeys(string[] keys) {
        foreach (Block b in blocks) {
            b.Full = keys != null && keys.Contains(b.Key);
            if (!b.Full) b.Beside = false;
        }
        Refresh();
    }

    // Two tiles sharing a line change together, so that they stay side by side.
    public bool ToggleFullAt(Point p) {
        Block hit = Visible().FirstOrDefault(b => b.Slot.Contains(p));
        if (hit == null) return false;
        bool value = !hit.Full;
        foreach (Block b in BuildLines(true).First(l => l.Contains(hit))) {
            b.Full = value;
            if (!value) b.Beside = false;
        }
        Refresh();
        return true;
    }

    public string[] GetBesideKeys() { return blocks.Where(b => b.Beside).Select(b => b.Key).ToArray(); }

    public void SetBesideKeys(string[] keys) {
        foreach (Block b in blocks) b.Beside = b.Full && IsGraph(b) && keys != null && keys.Contains(b.Key);
        Refresh();
    }

    // Gauges and graphs are the blocks that draw themselves and fill their slot.
    static bool IsGraph(Block b) {
        Border border = b.Element as Border;
        return b.Span == 2 && border != null && "fill".Equals(border.Tag);
    }

    static bool SameKind(string a, string b) { return a.EndsWith("chart") == b.EndsWith("chart"); }

    // Puts a graph on one line with the nearest other graph, or separates the two.
    public string GraphKeyAt(Point p) {
        Block hit = Visible().FirstOrDefault(b => b.Slot.Contains(p));
        return hit != null && IsGraph(hit) ? hit.Key : null;
    }

    // A free block of the same kind as this one: a gauge for a gauge, a graph for a graph.
    public string FreeGraphKey(string like) {
        Block free = Visible().FirstOrDefault(b => IsGraph(b) && !b.Beside && b.Key != like && SameKind(b.Key, like));
        return free == null ? null : free.Key;
    }

    public bool ToggleBeside(string key, bool sameKindOnly) {
        Block hit = Visible().FirstOrDefault(b => b.Key == key);
        if (hit == null || !IsGraph(hit)) return false;
        if (hit.Beside) {
            foreach (Block b in BuildLines(true).First(l => l.Contains(hit))) { b.Beside = false; b.Full = false; }
            Refresh();
            return true;
        }
        List<Block> free = Visible().Where(b => b != hit && IsGraph(b) && !b.Beside && (!sameKindOnly || SameKind(b.Key, hit.Key))).ToList();
        int at = blocks.IndexOf(hit);
        Block partner = free.FirstOrDefault(b => blocks.IndexOf(b) > at) ?? free.LastOrDefault();
        if (partner == null) return false;
        Block first = blocks.IndexOf(partner) < at ? partner : hit, second = first == hit ? partner : hit;
        blocks.Remove(second);
        blocks.Insert(blocks.IndexOf(first) + 1, second);
        hit.Beside = partner.Beside = hit.Full = partner.Full = true;
        Refresh();
        return true;
    }

    public void Refresh() { dirty = true; InvalidateMeasure(); InvalidateArrange(); }

    IEnumerable<Block> Visible() { return blocks.Where(b => b.Element.Visibility != Visibility.Collapsed); }

    void MeasureNatural() {
        foreach (Block b in Visible()) {
            b.Element.Measure(new Size((b.Span * Unit - Gap) / b.Grow, double.PositiveInfinity));
            b.Natural = b.Element.DesiredSize.Height * b.Grow;
        }
    }

    // Two small tiles share a line when paired; a wide block always has its own line.
    // Full-width tiles always pair with each other, whatever the column count.
    List<List<Block>> BuildLines(bool pair) {
        List<List<Block>> lines = new List<List<Block>>();
        List<Block> open = null;
        foreach (Block b in Visible()) {
            bool pairs = b.Beside || ((pair || b.Full) && b.Span == 1);
            if (pairs && open != null && open[0].Full == b.Full && open[0].Beside == b.Beside) {
                open.Add(b);
                open = null;
                continue;
            }
            List<Block> line = new List<Block> { b };
            lines.Add(line);
            open = pairs ? line : null;
        }
        return lines;
    }

    static double LineHeight(List<Block> line) { return line.Max(b => b.Natural); }

    static double ColumnHeight(List<List<Block>> column) {
        return column.Sum(l => LineHeight(l)) + Gap * Math.Max(0, column.Count - 1);
    }

    static List<List<List<Block>>> Split(List<List<Block>> lines, double limit) {
        List<List<List<Block>>> columns = new List<List<List<Block>>>();
        List<List<Block>> current = new List<List<Block>>();
        double used = 0;
        foreach (List<Block> line in lines) {
            double h = LineHeight(line);
            double next = current.Count == 0 ? h : used + Gap + h;
            if (current.Count > 0 && next > limit) {
                columns.Add(current);
                current = new List<List<Block>>();
                next = h;
            }
            current.Add(line);
            used = next;
        }
        if (current.Count > 0) columns.Add(current);
        return columns;
    }

    // Keeps the reading order and finds the smallest column height that fits in this many columns.
    static List<List<List<Block>>> Balance(List<List<Block>> lines, int count) {
        double low = lines.Max(l => LineHeight(l));
        double high = lines.Sum(l => LineHeight(l)) + Gap * Math.Max(0, lines.Count - 1);
        for (int i = 0; i < 32 && high - low > 0.25; i++) {
            double middle = (low + high) / 2;
            if (Split(lines, middle).Count <= count) high = middle; else low = middle;
        }
        return Split(lines, high);
    }

    Plan MakePlan(int count, bool pair) {
        List<Band> bands = new List<Band>();
        List<List<Block>> run = new List<List<Block>>();
        Action flush = () => {
            if (run.Count == 0) return;
            bands.Add(new Band { Columns = Balance(run, count) });
            run = new List<List<Block>>();
        };
        foreach (List<Block> line in BuildLines(pair)) {
            if (!line[0].Full) { run.Add(line); continue; }
            flush();
            bands.Add(new Band { Full = true, Columns = new List<List<List<Block>>> { new List<List<Block>> { line } } });
        }
        flush();
        foreach (Band band in bands) band.Height = band.Columns.Max(c => ColumnHeight(c));
        int columns = bands.Where(b => !b.Full).Select(b => b.Columns.Count).DefaultIfEmpty(1).Max();
        double lineWidth = pair ? 2 * Unit : StackedWidth;
        double width = columns * lineWidth + Gap * Math.Max(0, columns - 1);
        if (bands.Any(b => b.Full && b.Columns[0][0].Count > 1)) width = Math.Max(width, 2 * Unit);
        return new Plan {
            Bands = bands,
            ColumnCount = columns,
            Paired = pair,
            Width = width,
            Height = bands.Sum(b => b.Height) + Gap * Math.Max(0, bands.Count - 1)
        };
    }

    static double ZoomFor(Plan plan, Size size) {
        double byHeight = plan.Height > 0 ? size.Height / plan.Height : MaxZoom;
        return Math.Min(MaxZoom, Math.Min(size.Width / plan.Width, byHeight));
    }

    void Solve(Size size) {
        solved = size;
        dirty = false;
        MeasureNatural();
        if (!Visible().Any() || size.Width <= 0 || size.Height <= 0) return;
        Plan best = MakePlan(1, false);
        double bestZoom = ZoomFor(best, size);
        for (int k = 1; k <= MaxColumns; k++) {
            Plan plan = MakePlan(k, true);
            double zoom = ZoomFor(plan, size);
            if (zoom > bestZoom + 0.001) { best = plan; bestZoom = zoom; }
        }
        Zoom = bestZoom;
        Columns = best.ColumnCount;
        paired = best.Paired;
        double layoutWidth = size.Width / bestZoom, layoutHeight = size.Height / bestZoom;
        double spare = Math.Max(0, layoutHeight - best.Height), natural = best.Bands.Sum(b => b.Height), top = 0;
        foreach (Band band in best.Bands) {
            double bandHeight = band.Height + (natural > 0 ? spare * band.Height / natural : 0);
            int count = band.Columns.Count;
            double columnWidth = (layoutWidth - Gap * (count - 1)) / count;
            for (int c = 0; c < count; c++) {
                List<List<Block>> column = band.Columns[c];
                double left = c * (columnWidth + Gap), y = top;
                double extra = Math.Max(0, bandHeight - ColumnHeight(column)) / column.Count;
                foreach (List<Block> line in column) {
                    double lineHeight = LineHeight(line) + extra;
                    // A larger block also takes more of the width it shares.
                    double spans = line.Sum(b => b.Span * b.Grow);
                    double free = columnWidth - Gap * (line.Count - 1), x = left;
                    foreach (Block b in line) {
                        double w = free * b.Span * b.Grow / spans;
                        b.Scale = bestZoom;
                        b.Slot = new Rect(x * bestZoom, y * bestZoom, w * bestZoom, lineHeight * bestZoom);
                        x += w + Gap;
                    }
                    y += lineHeight + Gap;
                }
            }
            top += bandHeight + Gap;
        }
    }

    protected override Size MeasureOverride(Size available) {
        double w = double.IsInfinity(available.Width) ? 2 * Unit : available.Width;
        double h = double.IsInfinity(available.Height) ? FitHeight(w) : available.Height;
        Size size = new Size(w, h);
        if (dirty || size != solved) Solve(size);
        foreach (Block b in Visible()) b.Element.Measure(new Size(b.Slot.Width / (b.Scale * b.Grow), b.Slot.Height / (b.Scale * b.Grow)));
        badge.Measure(new Size(BadgeWidth, BadgeHeight));
        return size;
    }

    protected override Size ArrangeOverride(Size final) {
        if (dirty || final != solved) {
            Solve(final);
            foreach (Block b in Visible()) b.Element.Measure(new Size(b.Slot.Width / (b.Scale * b.Grow), b.Slot.Height / (b.Scale * b.Grow)));
        }
        foreach (Block b in Visible()) {
            b.Transform.ScaleX = b.Scale * b.Grow;
            b.Transform.ScaleY = b.Scale * b.Grow;
            Point at = b == dragging ? dragPoint - grab : b.Slot.TopLeft;
            b.Element.Arrange(new Rect(at, new Size(b.Slot.Width / (b.Scale * b.Grow), b.Slot.Height / (b.Scale * b.Grow))));
        }
        Rect badgeRect = BadgeRect();
        badge.Arrange(badgeRect.IsEmpty ? new Rect(0, 0, 0, 0) : badgeRect);
        return final;
    }

    // Height that shows every block without empty space, at this width and column count.
    public double FitHeight(double width) {
        MeasureNatural();
        if (!Visible().Any()) return 0;
        Plan plan = MakePlan(Math.Max(1, Columns), paired);
        double zoom = Math.Min(MaxZoom, width / plan.Width);
        return Math.Ceiling(plan.Height * zoom);
    }

    public bool BeginDrag(Point p) {
        dragging = Visible().FirstOrDefault(b => b.Slot.Contains(p));
        if (dragging == null) return false;
        HideBadge();
        grab = p - dragging.Slot.TopLeft;
        dragPoint = p;
        lastTarget = null;
        Panel.SetZIndex(dragging.Element, 1);
        dragging.Element.Opacity = 0.8;
        return true;
    }

    public void DragTo(Point p) {
        if (dragging == null) return;
        dragPoint = p;
        // Only the middle of a block triggers a swap, so that the layout does not flicker at its edges.
        Block target = Visible().FirstOrDefault(b => {
            if (b == dragging) return false;
            Rect r = b.Slot;
            r.Inflate(-r.Width * 0.2, -r.Height * 0.2);
            return r.Contains(p);
        });
        if (target != lastTarget) {
            lastTarget = target;
            if (target != null) {
                int to = blocks.IndexOf(target);
                blocks.Remove(dragging);
                blocks.Insert(to, dragging);
                dirty = true;
                InvalidateMeasure();
            }
        }
        InvalidateArrange();
    }

    public void EndDrag() {
        if (dragging == null) return;
        Panel.SetZIndex(dragging.Element, 0);
        dragging.Element.Opacity = 1;
        dragging = null;
        lastTarget = null;
        InvalidateArrange();
    }
}
'@
