# Learns roads from the rider's own GPS path, so the route profile works without an event or a route name.
# The road is a chain of points every 50 m. Riding a known road follows the chain; a new road extends it.
Add-Type @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;

public sealed class TpvRoadMemory {
    public const double Step = 50;
    const double MatchRadius = 25, CellSize = 40, MaxJump = 80, MaxHeading = 1.05;
    const int MaxNodes = 80000, PastKept = 12, CountCap = 50;

    sealed class Node {
        public double X, Y, H, Slope = double.NaN;
        public int Count, Next = -1;
    }

    List<Node> nodes = new List<Node>();
    Dictionary<long, List<int>> grid = new Dictionary<long, List<int>>();
    readonly List<int> recent = new List<int>();
    readonly Stopwatch clock = Stopwatch.StartNew();
    int current = -1, slopeCount;
    double lastX, lastY, lastT, slopeSum;
    bool hasLast;

    public int Version { get; private set; }
    public bool Dirty { get; private set; }
    public double Traveled { get; private set; }
    public int NodeCount { get { return nodes.Count; } }
    public bool HasPosition { get { return current >= 0; } }

    static double Distance(double ax, double ay, double bx, double by) {
        double dx = ax - bx, dy = ay - by;
        return Math.Sqrt(dx * dx + dy * dy);
    }

    static long CellKey(int cx, int cy) { return ((long)cx << 32) ^ (uint)cy; }

    static void AddToGrid(Dictionary<long, List<int>> target, Node n, int index) {
        long key = CellKey((int)Math.Floor(n.X / CellSize), (int)Math.Floor(n.Y / CellSize));
        List<int> cell;
        if (!target.TryGetValue(key, out cell)) { cell = new List<int>(); target[key] = cell; }
        cell.Add(index);
    }

    static bool SameDirection(double a, double b) {
        return Math.Abs(Math.Atan2(Math.Sin(a - b), Math.Cos(a - b))) <= MaxHeading;
    }

    bool Fits(int index, double x, double y, double heading) {
        Node n = nodes[index];
        return Distance(x, y, n.X, n.Y) <= MatchRadius && SameDirection(heading, n.H);
    }

    int Find(double x, double y, double heading, int exclude) {
        // The expected next point wins, so that a parallel road cannot capture the rider.
        if (current >= 0) {
            int expected = nodes[current].Next;
            if (expected >= 0 && expected != exclude && Fits(expected, x, y, heading)) return expected;
        }
        int cx = (int)Math.Floor(x / CellSize), cy = (int)Math.Floor(y / CellSize), best = -1;
        double bestDistance = double.MaxValue;
        for (int i = cx - 1; i <= cx + 1; i++) {
            for (int j = cy - 1; j <= cy + 1; j++) {
                List<int> cell;
                if (!grid.TryGetValue(CellKey(i, j), out cell)) continue;
                foreach (int index in cell) {
                    if (index == exclude || !Fits(index, x, y, heading)) continue;
                    double d = Distance(x, y, nodes[index].X, nodes[index].Y);
                    if (d < bestDistance) { bestDistance = d; best = index; }
                }
            }
        }
        return best;
    }

    int AddNode(double x, double y, double heading) {
        if (nodes.Count >= MaxNodes) return -1;
        Node n = new Node { X = x, Y = y, H = heading };
        nodes.Add(n);
        AddToGrid(grid, n, nodes.Count - 1);
        Dirty = true;
        return nodes.Count - 1;
    }

    // Stops following the road, after a teleport, a data gap or a change of displayed rider.
    public void Lose() {
        if (!hasLast && current < 0) return;
        hasLast = false;
        current = -1;
        slopeSum = 0;
        slopeCount = 0;
        Traveled = 0;
        recent.Clear();
        Version++;
    }

    // Coordinates are FIT semicircles. Returns true when the rider reached a new point of the road.
    public bool Feed(double latitude, double longitude, double slope) {
        double latDeg = latitude * 180 / 2147483648.0, lonDeg = longitude * 180 / 2147483648.0;
        double y = latDeg * 111320, x = lonDeg * 111320 * Math.Cos(Math.Round(latDeg, 1) * Math.PI / 180);
        double now = clock.Elapsed.TotalSeconds;
        if (hasLast && (now - lastT > 3 || Distance(x, y, lastX, lastY) > MaxJump)) Lose();
        if (!hasLast) {
            hasLast = true;
            lastX = x; lastY = y; lastT = now;
            return false;
        }
        lastT = now;
        if (Distance(x, y, lastX, lastY) < 1.5) return false;
        double heading = Math.Atan2(y - lastY, x - lastX);
        lastX = x; lastY = y;
        slopeSum += slope;
        slopeCount++;
        if (current < 0) {
            int found = Find(x, y, heading, -1);
            current = found >= 0 ? found : AddNode(x, y, heading);
            slopeSum = 0;
            slopeCount = 0;
            Traveled = 0;
            Version++;
            return current >= 0;
        }
        Node c = nodes[current];
        double run = Distance(x, y, c.X, c.Y);
        Traveled = Math.Min(run, Step);
        if (run < Step) return false;
        double direction = Math.Atan2(y - c.Y, x - c.X);
        double average = slopeSum / Math.Max(1, slopeCount);
        // A point holds the gradient of the stretch that starts there.
        if (c.Count == 0) c.Slope = average;
        else c.Slope = (c.Slope * c.Count + average) / (c.Count + 1);
        c.Count = Math.Min(c.Count + 1, CountCap);
        Dirty = true;
        int next = Find(x, y, direction, current);
        if (next < 0) next = AddNode(x, y, direction);
        if (next >= 0) c.Next = next;
        recent.Add(current);
        if (recent.Count > PastKept) recent.RemoveAt(0);
        current = next;
        slopeSum = 0;
        slopeCount = 0;
        Traveled = 0;
        Version++;
        return current >= 0;
    }

    // Gradients around the rider: "past" stretches behind, then the road ahead. Unknown road is NaN.
    public double[] Gradients(int past, int total) {
        double[] result = new double[total];
        for (int i = 0; i < total; i++) result[i] = double.NaN;
        for (int i = 1; i <= past; i++) {
            int index = recent.Count - i;
            if (index < 0) break;
            result[past - i] = nodes[recent[index]].Slope;
        }
        int n = current;
        for (int i = past; i < total && n >= 0; i++) {
            result[i] = nodes[n].Slope;
            n = nodes[n].Next;
        }
        return result;
    }

    // Known gradients from the rider onward, stopping at the first unknown stretch.
    public double[] AheadSlopes(int total) {
        double[] result = new double[total];
        for (int i = 0; i < total; i++) result[i] = double.NaN;
        int n = current;
        for (int i = 0; i < total && n >= 0; i++) {
            if (double.IsNaN(nodes[n].Slope)) break;
            result[i] = nodes[n].Slope;
            n = nodes[n].Next;
        }
        return result;
    }

    public int KnownAhead {
        get {
            int known = 0, n = current;
            while (n >= 0 && known < 100 && !double.IsNaN(nodes[n].Slope)) { known++; n = nodes[n].Next; }
            return known;
        }
    }

    public void Save(string path) {
        CultureInfo inv = CultureInfo.InvariantCulture;
        StringBuilder text = new StringBuilder("tpvroads1\n");
        foreach (Node n in nodes) {
            text.Append(n.X.ToString("F1", inv)).Append(',').Append(n.Y.ToString("F1", inv)).Append(',')
                .Append(n.H.ToString("F3", inv)).Append(',').Append((n.Count == 0 ? 0 : n.Slope).ToString("F2", inv)).Append(',')
                .Append(n.Count).Append(',').Append(n.Next).Append('\n');
        }
        string temp = path + ".tmp";
        File.WriteAllText(temp, text.ToString());
        if (File.Exists(path)) File.Replace(temp, path, path + ".bak"); else File.Move(temp, path);
        Dirty = false;
    }

    bool TryLoad(string path) {
        try {
            CultureInfo inv = CultureInfo.InvariantCulture;
            string[] lines = File.ReadAllLines(path);
            if (lines.Length == 0 || lines[0] != "tpvroads1") return false;
            List<Node> loaded = new List<Node>(lines.Length);
            for (int i = 1; i < lines.Length; i++) {
                if (lines[i].Length == 0) continue;
                string[] f = lines[i].Split(',');
                if (f.Length != 6) return false;
                Node n = new Node { X = double.Parse(f[0], inv), Y = double.Parse(f[1], inv), H = double.Parse(f[2], inv), Count = int.Parse(f[4], inv), Next = int.Parse(f[5], inv) };
                n.Slope = n.Count > 0 ? double.Parse(f[3], inv) : double.NaN;
                loaded.Add(n);
            }
            Dictionary<long, List<int>> index = new Dictionary<long, List<int>>();
            for (int i = 0; i < loaded.Count; i++) {
                if (loaded[i].Next >= loaded.Count || loaded[i].Next < -1) return false;
                AddToGrid(index, loaded[i], i);
            }
            nodes = loaded;
            grid = index;
            return true;
        } catch (FormatException) { return false; }
        catch (OverflowException) { return false; }
        catch (IOException) { return false; }
    }

    // A damaged file is kept aside and the previous good version is used.
    public bool Load(string path) {
        if (File.Exists(path)) {
            if (TryLoad(path)) return true;
            try { File.Copy(path, path + ".damaged", true); } catch (IOException) { }
        }
        string backup = path + ".bak";
        if (File.Exists(backup) && TryLoad(backup)) { Dirty = true; return true; }
        return false;
    }
}
'@
