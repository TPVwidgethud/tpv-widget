# Places the rider on a game route file from the GPS position, without the game's route name or distance.
# The route files hold road points in meters east (x) and north (z) of their latMid / lonMid reference.
Add-Type @'
using System;
using System.Collections.Generic;

public sealed class TpvRouteLocator {
    const double MetersPerDegree = 6371000 * Math.PI / 180;
    const double MaxOffRoad = 35;

    readonly double latMid, lonMid, cosMid;
    readonly double[] xs, zs, cum;
    double lastAlong = double.NaN, direction;
    bool reversed;
    DateTime lastSeen = DateTime.MinValue;

    public string Name { get; private set; }
    public bool Loop { get; private set; }
    public double Length { get; private set; }
    public double OffRoad { get; private set; }
    // Negative when the rider goes against the order of the file.
    // After a U-turn the new direction is taken once about 30 m have been ridden that way.
    public bool Reversed { get { return reversed; } }

    public TpvRouteLocator(string name, double referenceLat, double referenceLon, double[] x, double[] z, bool loop) {
        Name = name; Loop = loop;
        latMid = referenceLat; lonMid = referenceLon; cosMid = Math.Cos(referenceLat * Math.PI / 180);
        xs = x; zs = z;
        cum = new double[x.Length];
        for (int i = 1; i < x.Length; i++) cum[i] = cum[i - 1] + Math.Sqrt((x[i] - x[i - 1]) * (x[i] - x[i - 1]) + (z[i] - z[i - 1]) * (z[i] - z[i - 1]));
        Length = x.Length > 0 ? cum[x.Length - 1] : 0;
    }

    double Wrapped(double delta) {
        if (!Loop || Length <= 0) return delta;
        delta %= Length;
        if (delta > Length / 2) delta -= Length;
        if (delta < -Length / 2) delta += Length;
        return delta;
    }

    // Distance along the file's points, or NaN when the rider is not on this route.
    public double Locate(double latitude, double longitude) {
        double px = (longitude - lonMid) * MetersPerDegree * cosMid, pz = (latitude - latMid) * MetersPerDegree;
        bool recent = !double.IsNaN(lastAlong) && (DateTime.UtcNow - lastSeen).TotalSeconds < 10;
        double best = double.MaxValue, bestAlong = double.NaN, bestOff = double.MaxValue;
        for (int i = 0; i + 1 < xs.Length; i++) {
            double dx = xs[i + 1] - xs[i], dz = zs[i + 1] - zs[i], len2 = dx * dx + dz * dz;
            double t = len2 > 0 ? Math.Max(0, Math.Min(1, ((px - xs[i]) * dx + (pz - zs[i]) * dz) / len2)) : 0;
            double qx = xs[i] + t * dx, qz = zs[i] + t * dz;
            double off = Math.Sqrt((px - qx) * (px - qx) + (pz - qz) * (pz - qz));
            if (off > MaxOffRoad) continue;
            double along = cum[i] + t * (cum[i + 1] - cum[i]);
            // Where roads cross or run side by side, the stretch that follows the last position wins.
            double score = off + (recent ? 0.25 * Math.Abs(Wrapped(along - lastAlong)) : 0);
            if (score < best) { best = score; bestAlong = along; bestOff = off; }
        }
        if (double.IsNaN(bestAlong)) { OffRoad = double.NaN; return double.NaN; }
        if (recent) {
            double moved = Wrapped(bestAlong - lastAlong);
            if (Math.Abs(moved) > 1) direction = Math.Max(-60, Math.Min(60, direction + Math.Sign(moved) * Math.Min(Math.Abs(moved), 30)));
            if (direction < -30) reversed = true;
            else if (direction > 30) reversed = false;
        } else {
            direction = 0;
        }
        lastAlong = bestAlong;
        lastSeen = DateTime.UtcNow;
        OffRoad = bestOff;
        return bestAlong;
    }

    public void Forget() { lastAlong = double.NaN; direction = 0; }
}
'@

# Road points of a game route file, in the order the route rides them: @(x, height, z) per point.
function Get-GameRoutePoints($Json) {
    $roads = @(if ($null -ne $Json.pointsx10) { [pscustomobject]@{ pointsx10 = $Json.pointsx10 } } else { $Json.roads })
    $points = New-Object System.Collections.ArrayList
    $roadOrder = if ($null -ne $Json.route) { @($Json.route) } else { 1..$roads.Count }
    foreach ($entry in $roadOrder) {
        $index = [math]::Abs([int]$entry) - 1
        if ($index -lt 0 -or $index -ge $roads.Count) { continue }
        $raw = @($roads[$index].pointsx10)
        $count = [int][math]::Floor($raw.Count / 3)
        $order = if ([int]$entry -lt 0) { ($count - 1)..0 } else { 0..($count - 1) }
        foreach ($i in $order) { [void]$points.Add([double[]]@(([double]$raw[3 * $i] / 10), ([double]$raw[3 * $i + 1] / 10), ([double]$raw[3 * $i + 2] / 10))) }
    }
    if ([int]$Json.outAndBack -eq 1) { for ($i = $points.Count - 2; $i -ge 0; $i--) { [void]$points.Add($points[$i]) } }
    return ,$points
}

# The reference point of every game route file, read once.
function Read-GameRouteIndex([string]$Directory) {
    $index = @()
    foreach ($file in (Get-ChildItem -LiteralPath $Directory -Filter '*.json' -ErrorAction SilentlyContinue)) {
        try {
            $j = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if ($null -eq $j.latMid -or $null -eq $j.lonMid) { continue }
            $index += @{ path = $file.FullName; name = [string]$j.name; lat = [double]$j.latMid; lon = [double]$j.lonMid }
        } catch { }
    }
    return $index
}

# Slopes laid out for the way the rider goes: reversed when riding against the file, repeated for laps of a loop.
function New-LocatedProfile($GameProfile, [bool]$Loop, [bool]$Reverse) {
    $count = 0
    foreach ($k in $GameProfile.slopes.Keys) { if ([int]$k + 1 -gt $count) { $count = [int]$k + 1 } }
    $laps = $(if ($Loop) { 3 } else { 1 })
    $locatedProfile = New-RouteProfile "$($GameProfile.route)$(if ($Reverse) { ' reverse' })" 'game'
    for ($k = 0; $k -lt $count * $laps; $k++) {
        $source = $k % $count
        if ($Reverse) { $source = $count - 1 - $source }
        if (-not $GameProfile.slopes.ContainsKey($source)) { continue }
        $value = [double]$GameProfile.slopes[$source]
        $locatedProfile.slopes[$k] = $(if ($Reverse) { -$value } else { $value })
        $locatedProfile.counts[$k] = 1
    }
    $locatedProfile.length = $count * [double]$GameProfile.bucket * $laps
    return $locatedProfile
}

# ---------- Event routes ----------

# The route file saved for a route name by route-fetch.ps1.
function Find-CachedRoute([string]$Directory, [string]$Route) {
    if (-not $Route) { return $null }
    $path = Join-Path $Directory ((Get-NormalizedName $Route) + '.json')
    if (Test-Path -LiteralPath $path) { return $path }
    return $null
}

# Event ids the game wrote in its readable logs, newest first. The log of the running session is locked.
function Get-LoggedEventIds([string]$LogDirectory) {
    $ids = New-Object System.Collections.Generic.List[string]
    $logs = Get-ChildItem -LiteralPath $LogDirectory -Filter 'playerlog*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($log in $logs) {
        try {
            $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
        } catch { continue }
        $next = [regex]::Matches($text, 'Next event is (\d+)/')
        for ($i = $next.Count - 1; $i -ge 0; $i--) { if (-not $ids.Contains($next[$i].Groups[1].Value)) { $ids.Add($next[$i].Groups[1].Value) } }
        $signed = [regex]::Matches($text, 'signed up to the following events:([^\r\n]*)')
        for ($i = $signed.Count - 1; $i -ge 0; $i--) {
            foreach ($m in [regex]::Matches($signed[$i].Groups[1].Value, '(\d+)/\d+')) { if (-not $ids.Contains($m.Groups[1].Value)) { $ids.Add($m.Groups[1].Value) } }
        }
        if ($ids.Count -ge 6) { break }
    }
    return @($ids)
}

# A lap profile repeated over the whole event distance, lap after lap without drift.
function Expand-RouteLaps($GameProfile, [double]$EventDistance) {
    $length = [double]$GameProfile.length
    # An event a little longer than its route (lead-in, rounding) is one lap, not two.
    if ($length -le 0 -or $EventDistance -le $length * 1.2) { return $GameProfile }
    $laps = [int][math]::Ceiling($EventDistance / $length)
    $size = [double]$GameProfile.bucket
    $expanded = New-RouteProfile $GameProfile.route 'game'
    $total = [int][math]::Ceiling($length * $laps / $size)
    for ($k = 0; $k -lt $total; $k++) {
        $source = [int][math]::Floor(((($k + 0.5) * $size) % $length) / $size)
        if (-not $GameProfile.slopes.ContainsKey($source)) { continue }
        $expanded.slopes[$k] = $GameProfile.slopes[$source]
        $expanded.counts[$k] = 1
    }
    $expanded.length = $length * $laps
    $expanded.gain = [double]$GameProfile.gain * $laps
    return $expanded
}

# The game names an organizer's GPX route "Custom Route - X" where the route file says "X".
function Test-SameRouteName([string]$A, [string]$B) {
    $x = (Get-NormalizedName $A) -replace '^customroute', ''
    $y = (Get-NormalizedName $B) -replace '^customroute', ''
    if (-not $x -or -not $y) { return $false }
    if ($x -eq $y) { return $true }
    return ($x.Length -ge 5 -and $y.Length -ge 5 -and ($x.Contains($y) -or $y.Contains($x)))
}