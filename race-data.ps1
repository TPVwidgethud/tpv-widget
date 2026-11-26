# Race information for the overlay: gaps, next climb and key point.

function Read-SharedText([string]$Path) {
    $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite,Delete')
    try { return (New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $true)).ReadToEnd() }
    finally { $stream.Dispose() }
}

$script:activeRouteCache = @{ key = $null; route = $null }

function Get-ActiveRoute([string]$LogDirectory) {
    $log = Get-ChildItem -LiteralPath $LogDirectory -Filter 'playerlog*.txt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $log) { return $null }
    $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite,Delete')
    try {
        # The length from the open file is exact; the log is only read again when it has grown.
        $key = "$($log.FullName)|$($stream.Length)"
        if ($key -eq $script:activeRouteCache.key) { return $script:activeRouteCache.route }
        if ($stream.Length -gt 262144) { [void]$stream.Seek(-262144, 'End') }
        $text = (New-Object IO.StreamReader($stream)).ReadToEnd()
    } finally { $stream.Dispose() }
    $found = [regex]::Matches($text, 'Active route changed to: ([^\r\n]+)')
    $route = $(if ($found.Count -eq 0) { $null } else { $found[$found.Count - 1].Groups[1].Value.Trim() })
    $script:activeRouteCache = @{ key = $key; route = $route }
    return $route
}

# --- Gaps -----------------------------------------------------------------

function Get-NearestGaps($Riders, [string]$Focus) {
    # The list is ordered front to back; timeGap is the gap to the focused rider in ms, negative behind.
    $result = @{ ahead = $null; aheadRider = $null; hasAhead = $false; behind = $null; behindRider = $null; hasBehind = $false }
    $list = @($Riders)
    $index = -1
    for ($i = 0; $i -lt $list.Count; $i++) { if ($list[$i].name -eq $Focus) { $index = $i; break } }
    if ($index -lt 0) { return $result }
    for ($i = $index - 1; $i -ge 0; $i--) {
        if ($list[$i].isEliminated) { continue }
        $result.hasAhead = $true
        if ([double]$list[$i].timeGap -ge 1000) { $result.ahead = [double]$list[$i].timeGap; $result.aheadRider = [string]$list[$i].name; break }
    }
    for ($i = $index + 1; $i -lt $list.Count; $i++) {
        if ($list[$i].isEliminated) { continue }
        $result.hasBehind = $true
        if ([math]::Abs([double]$list[$i].timeGap) -ge 1000) { $result.behind = [math]::Abs([double]$list[$i].timeGap); $result.behindRider = [string]$list[$i].name; break }
    }
    return $result
}

function New-GapTrend {
    return @{ rider = $null; samples = (New-Object System.Collections.ArrayList) }
}

function Update-GapTrend($Trend, $Rider, $GapMs, [datetime]$Now) {
    # Returns the gap change in seconds per minute (negative = closing), or $null if too early.
    if ($null -eq $Rider -or $null -eq $GapMs) { $Trend.rider = $null; $Trend.samples.Clear(); return $null }
    if ($Trend.rider -ne $Rider) { $Trend.rider = $Rider; $Trend.samples.Clear() }
    [void]$Trend.samples.Add(@{ time = $Now; gap = [double]$GapMs })
    while ($Trend.samples.Count -gt 1 -and ($Now - $Trend.samples[0].time).TotalSeconds -gt 45) { $Trend.samples.RemoveAt(0) }
    $oldest = $Trend.samples[0]
    $dt = ($Now - $oldest.time).TotalSeconds
    if ($dt -lt 20) { return $null }
    return ([double]$GapMs - $oldest.gap) / 1000 / $dt * 60
}

function Format-GapLine($GapMs, $TrendValue, [bool]$HasRiders) {
    if ($null -eq $GapMs) { if ($HasRiders) { return 'In group' } return '--' }
    $total = [int][math]::Round([double]$GapMs / 1000)
    $text = '{0}:{1:00}' -f [math]::Floor($total / 60), ($total % 60)
    if ($null -eq $TrendValue) { return $text }
    $rate = [int][math]::Round([math]::Abs([double]$TrendValue))
    if ($rate -lt 1) { return "$text  stable" }
    if ($TrendValue -lt 0) { return "$text  closing $rate s/min" }
    return "$text  opening $rate s/min"
}

# --- Route profiles -------------------------------------------------------

function Get-NormalizedName([string]$Name) {
    return ($Name.ToLowerInvariant() -replace '[^a-z0-9]', '')
}

function New-RouteProfile([string]$Route, [string]$Source = 'learned') {
    return @{ route = $Route; source = $Source; bucket = 50; slopes = @{}; counts = @{}; dirty = $false }
}

function Add-RouteSample($RouteData, [double]$Position, [double]$Slope) {
    if ($RouteData.source -ne 'learned' -or $Position -le 0) { return }
    $k = [int][math]::Floor($Position / $RouteData.bucket)
    if ($RouteData.slopes.ContainsKey($k)) {
        $n = [int]$RouteData.counts[$k]
        $RouteData.slopes[$k] = ([double]$RouteData.slopes[$k] * $n + $Slope) / ($n + 1)
        # Cap the weight so that a corrected value can still move the average.
        $RouteData.counts[$k] = [math]::Min($n + 1, 50)
    } else {
        $RouteData.slopes[$k] = $Slope
        $RouteData.counts[$k] = 1
    }
    $RouteData.dirty = $true
}

function Get-RouteProfilePath([string]$Directory, [string]$Route) {
    return Join-Path $Directory (($Route -replace '[^A-Za-z0-9._-]', '_') + '.json')
}

function Save-RouteProfile($RouteData, [string]$Directory) {
    if (-not $RouteData -or $RouteData.source -ne 'learned' -or -not $RouteData.dirty) { return }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $parts = foreach ($k in ($RouteData.slopes.Keys | Sort-Object)) {
        '{0}:{1}:{2}' -f $k, ([double]$RouteData.slopes[$k]).ToString('0.00', $inv), $RouteData.counts[$k]
    }
    if (-not (Test-Path -LiteralPath $Directory)) { [void](New-Item -ItemType Directory -Path $Directory) }
    $json = @{ route = $RouteData.route; bucket = $RouteData.bucket; points = ($parts -join ',') } | ConvertTo-Json
    $path = Get-RouteProfilePath $Directory $RouteData.route
    $temp = "$path.tmp"
    [IO.File]::WriteAllText($temp, $json)
    Move-Item -LiteralPath $temp -Destination $path -Force
    $RouteData.dirty = $false
}

function Read-LearnedRoute([string]$Directory, [string]$Route) {
    $routeData = New-RouteProfile $Route
    $path = Get-RouteProfilePath $Directory $Route
    if (-not (Test-Path -LiteralPath $path)) { return $routeData }
    try {
        $j = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        $inv = [Globalization.CultureInfo]::InvariantCulture
        foreach ($p in ([string]$j.points).Split(',')) {
            $f = $p.Split(':')
            if ($f.Count -eq 3) {
                $k = [int]$f[0]
                $routeData.slopes[$k] = [double]::Parse($f[1], $inv)
                $routeData.counts[$k] = [int]$f[2]
            }
        }
    } catch { }
    return $routeData
}

function Find-GameRouteFile([string]$Directory, [string]$Route) {
    # These files describe one direction only, so a reversed route must not match them.
    if ($Route -match '(?i)reverse') { return $null }
    $target = Get-NormalizedName $Route
    foreach ($file in (Get-ChildItem -LiteralPath $Directory -Filter '*.json' -ErrorAction SilentlyContinue)) {
        $base = Get-NormalizedName $file.BaseName
        if ($base.Length -ge 5 -and $target.Contains($base)) { return $file.FullName }
    }
    return $null
}

function Import-GameRoute([string]$Path, [string]$Route) {
    $j = [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) | ConvertFrom-Json
    # Single-road files keep their points at the top level.
    $roads = @(if ($null -ne $j.pointsx10) { [pscustomobject]@{ pointsx10 = $j.pointsx10 } } else { $j.roads })
    $points = New-Object System.Collections.ArrayList
    # Some route files have no explicit road order: their roads are then ridden in file order.
    $roadOrder = if ($null -ne $j.route) { @($j.route) } else { 1..$roads.Count }
    foreach ($entry in $roadOrder) {
        $index = [math]::Abs([int]$entry) - 1
        if ($index -lt 0 -or $index -ge $roads.Count) { continue }
        $raw = @($roads[$index].pointsx10)
        $count = [int][math]::Floor($raw.Count / 3)
        $order = if ([int]$entry -lt 0) { ($count - 1)..0 } else { 0..($count - 1) }
        foreach ($i in $order) {
            # Parentheses matter: in PowerShell the comma binds tighter than the division.
            $px = [double]$raw[3 * $i] / 10
            $py = [double]$raw[3 * $i + 1] / 10
            $pz = [double]$raw[3 * $i + 2] / 10
            [void]$points.Add([double[]]@($px, $py, $pz))
        }
    }
    if ([int]$j.outAndBack -eq 1) {
        for ($i = $points.Count - 2; $i -ge 0; $i--) { [void]$points.Add($points[$i]) }
    }
    $routeData = New-RouteProfile $Route 'game'
    $size = [double]$routeData.bucket
    $weight = @{}
    $sum = @{}
    $cum = 0.0
    $gain = 0.0
    for ($i = 1; $i -lt $points.Count; $i++) {
        $a = $points[$i - 1]; $b = $points[$i]
        $dx = $b[0] - $a[0]; $dy = $b[1] - $a[1]; $dz = $b[2] - $a[2]
        $h = [math]::Sqrt($dx * $dx + $dz * $dz)
        if ($h -le 0) { continue }
        $slope = 100 * $dy / $h
        if ($dy -gt 0) { $gain += $dy }
        $first = [int][math]::Floor($cum / $size)
        $last = [int][math]::Floor(($cum + $h - 0.001) / $size)
        for ($k = $first; $k -le $last; $k++) {
            $overlap = [math]::Min($cum + $h, ($k + 1) * $size) - [math]::Max($cum, $k * $size)
            if ($overlap -le 0) { continue }
            $weight[$k] = [double]$weight[$k] + $overlap
            $sum[$k] = [double]$sum[$k] + $slope * $overlap
        }
        $cum += $h
    }
    # Some files hold more road than the route really uses: positions would not line up.
    $expected = [double]$j.metrics.totalDistance
    if ($expected -gt 0 -and [math]::Abs($cum - $expected) / $expected -gt 0.05) { return $null }
    foreach ($k in $weight.Keys) {
        $routeData.slopes[$k] = $sum[$k] / $weight[$k]
        $routeData.counts[$k] = 1
    }
    $routeData.length = $cum
    $routeData.gain = $gain
    return $routeData
}

function Get-NextClimb($RouteData, [double]$Position, [double]$MinLength = 200, [double]$MinAverage = 3, [double]$Horizon = 20000) {
    $size = [double]$RouteData.bucket
    $slopes = $RouteData.slopes
    $start = [int][math]::Floor($Position / $size)
    $end = $start + [int][math]::Ceiling($Horizon / $size)
    $k = $start
    while ($k -le $end) {
        if (-not $slopes.ContainsKey($k)) {
            # A game route simply ends; a learned route may not have been ridden this far yet.
            if ($RouteData.source -eq 'game') { return @{ status = 'end' } }
            return @{ status = 'unknown' }
        }
        if ([double]$slopes[$k] -lt $MinAverage) { $k++; continue }
        # Follow the climb through short flatter sections (up to two buckets).
        $lastUp = $k
        $j = $k + 1
        while ($j -le $end -and $slopes.ContainsKey($j)) {
            if ([double]$slopes[$j] -ge 1.5) { $lastUp = $j }
            elseif ($j - $lastUp -gt 2) { break }
            $j++
        }
        $total = 0.0
        for ($m = $k; $m -le $lastUp; $m++) { if ($slopes.ContainsKey($m)) { $total += [double]$slopes[$m] } }
        $buckets = $lastUp - $k + 1
        $length = $buckets * $size
        $average = $total / $buckets
        if ($length -ge $MinLength -and $average -ge $MinAverage) {
            $inClimb = ($k -eq $start)
            if ($inClimb) { $length = [math]::Max($size, ($lastUp + 1) * $size - $Position) }
            return @{
                status = 'found'
                inClimb = $inClimb
                distance = $(if ($inClimb) { 0.0 } else { [math]::Max(0.0, $k * $size - $Position) })
                length = $length
                average = $average
                gain = $length * $average / 100
            }
        }
        $k = $lastUp + 1
    }
    return @{ status = 'none' }
}

function Format-Distance([double]$Meters) {
    $inv = [Globalization.CultureInfo]::InvariantCulture
    if ($Meters -lt 1000) { return ([int]([math]::Round($Meters / 10) * 10)).ToString($inv) + ' m' }
    return ($Meters / 1000).ToString('0.0', $inv) + ' km'
}

function Format-Climb($Climb) {
    if (-not $Climb) { return '--' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    switch ($Climb.status) {
        'unknown' { return 'Learning this route' }
        'none' { return 'None in next 20 km' }
        'end' { return 'None before route end' }
    }
    $avg = ([double]$Climb.average).ToString('0.0', $inv)
    if ($Climb.inClimb) { return "NOW  $(Format-Distance $Climb.length) left at $avg %" }
    return "$(Format-Distance $Climb.distance)  |  $(Format-Distance $Climb.length) at $avg %  |  +$([int][math]::Round($Climb.gain)) m"
}

# --- Rolling power --------------------------------------------------------

function New-PowerWindow([double]$Seconds = 30) {
    return @{
        size = $Seconds; rider = $null; last = $null; energy = 0.0; total = 0.0
        segments = (New-Object System.Collections.Generic.Queue[object])
    }
}

function Reset-PowerWindow($Window) {
    $Window.last = $null
    $Window.energy = 0.0
    $Window.total = 0.0
    $Window.segments.Clear()
}

function Update-PowerWindow($Window, [string]$Rider, [double]$Power, [datetime]$Now) {
    # Time-weighted average, so repeated reads of the same file value do not skew it.
    if ($Window.rider -ne $Rider) { Reset-PowerWindow $Window; $Window.rider = $Rider }
    if ($null -ne $Window.last) {
        $dt = ($Now - $Window.last).TotalSeconds
        if ($dt -gt 3) {
            # The data stopped: an average across the gap would be meaningless.
            Reset-PowerWindow $Window
        } elseif ($dt -gt 0) {
            $Window.segments.Enqueue(@{ dt = $dt; power = $Power })
            $Window.energy += $dt * $Power
            $Window.total += $dt
            while ($Window.total -gt $Window.size -and $Window.segments.Count -gt 0) {
                $oldest = $Window.segments.Peek()
                $excess = $Window.total - $Window.size
                if ($oldest.dt -le $excess) {
                    [void]$Window.segments.Dequeue()
                    $Window.energy -= $oldest.dt * $oldest.power
                    $Window.total -= $oldest.dt
                } else {
                    $oldest.dt -= $excess
                    $Window.energy -= $excess * $oldest.power
                    $Window.total -= $excess
                }
            }
        }
    }
    $Window.last = $Now
    if ($Window.total -le 0) { return $null }
    return @{ average = $Window.energy / $Window.total; seconds = $Window.total }
}

function Format-PowerWindow($Result, [double]$Size = 30) {
    if (-not $Result) { return '--' }
    $watts = [int][math]::Round([double]$Result.average)
    if ([double]$Result.seconds -ge $Size - 0.5) { return "$watts W" }
    return "$watts W  ($([int][math]::Floor([double]$Result.seconds)) s)"
}

# --- VAM ------------------------------------------------------------------

function New-VamWindow([double]$Seconds = 30) {
    return @{
        size = $Seconds; rider = $null; last = $null; gain = 0.0; unit = $null; vote = $null
        refAltitude = $null; refGain = 0.0
        samples = (New-Object System.Collections.Generic.List[object])
    }
}

function Reset-VamWindow($Window) {
    $Window.last = $null
    $Window.gain = 0.0
    $Window.refAltitude = $null
    $Window.refGain = 0.0
    $Window.vote = $null
    $Window.samples.Clear()
}

function Update-VamUnit($Window, [double]$Altitude) {
    # The feed does not state its altitude unit: compare it with the climb implied by speed and slope.
    if ($null -ne $Window.unit) { return }
    if ($null -eq $Window.refAltitude) { $Window.refAltitude = $Altitude; $Window.refGain = $Window.gain; return }
    $expected = $Window.gain - $Window.refGain
    if ([math]::Abs($expected) -lt 5) { return }
    $ratio = ($Altitude - $Window.refAltitude) / $expected
    $Window.refAltitude = $Altitude
    $Window.refGain = $Window.gain
    $candidate = $null
    if ($ratio -gt 0) {
        $power = [math]::Round([math]::Log10($ratio))
        if ($power -ge 0 -and $power -le 3 -and [math]::Abs([math]::Log10($ratio) - $power) -lt 0.12) { $candidate = [math]::Pow(10, $power) }
    }
    if ($null -ne $candidate -and $candidate -eq $Window.vote) { $Window.unit = $candidate }
    $Window.vote = $candidate
}

function Update-VamWindow($Window, [string]$Rider, [double]$Altitude, [double]$Speed, [double]$Slope, [datetime]$Now) {
    if ($Window.rider -ne $Rider) { Reset-VamWindow $Window; $Window.rider = $Rider }
    if ($null -ne $Window.last) {
        $dt = ($Now - $Window.last).TotalSeconds
        $previous = $(if ($Window.samples.Count) { $Window.samples[$Window.samples.Count - 1] } else { $null })
        $jump = ($null -ne $Window.unit -and $previous -and [math]::Abs($Altitude - $previous.altitude) / $Window.unit -gt 15 * [math]::Max([double]1, $dt))
        if ($dt -gt 3 -or $dt -lt 0 -or $jump) {
            # Data gap or teleport: a climb rate across it would be meaningless.
            Reset-VamWindow $Window
        } else {
            $Window.gain += $Speed * [math]::Sin([math]::Atan($Slope / 100)) * $dt
        }
    }
    $Window.last = $Now
    Update-VamUnit $Window $Altitude
    $Window.samples.Add(@{ t = $Now; altitude = $Altitude; gain = $Window.gain })
    while ($Window.samples.Count -gt 2 -and ($Now - $Window.samples[1].t).TotalSeconds -ge $Window.size) { $Window.samples.RemoveAt(0) }
    $first = $Window.samples[0]
    $span = ($Now - $first.t).TotalSeconds
    if ($span -lt 10) { return $null }
    $estimated = ($null -eq $Window.unit)
    $meters = $(if ($estimated) { $Window.gain - $first.gain } else { ($Altitude - $first.altitude) / $Window.unit })
    return @{ vam = $meters / $span * 3600; seconds = $span; estimated = $estimated }
}

function Format-Vam($Result, [double]$Size = 30) {
    # Flat and downhill sections have no meaningful VAM.
    if (-not $Result -or [double]$Result.vam -lt 50) { return '--' }
    $prefix = $(if ($Result.estimated) { '~' } else { '' })
    $text = "$prefix$([int][math]::Round([double]$Result.vam)) m/h"
    if ([double]$Result.seconds -ge $Size - 0.5) { return $text }
    return "$text  ($([int][math]::Floor([double]$Result.seconds)) s)"
}

function Get-KeyPoint($Focus) {
    $next = [double]$Focus.eventDistanceToNextLocation
    $total = [double]$Focus.eventDistanceTotal
    $done = [double]$Focus.eventDistanceDone
    if ($next -gt 0) { return @{ label = 'NEXT POINT'; meters = $next } }
    if ($total -gt 0) { return @{ label = 'FINISH'; meters = [math]::Max([double]0, $total - $done) } }
    return $null
}
