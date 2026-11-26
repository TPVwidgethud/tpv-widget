# Race tactics from the game's broadcast: attacks nearby, gaps to the groups around you, time pulling at the
# front, teammates. nearest.json: timeGap in ms to the focused rider, positive ahead, negative behind; speed in mm/s.
# groups.json: front to back; timeGap1 = gap of the group to the race leader in ms, and for an entry that
# gathers several groups (groupNum2 > 0), timeGap2 = gap of its last group.

function New-TacticsState {
    return @{
        surge = @{}; flagged = @{}
        ahead = @{ key = ''; samples = (New-Object System.Collections.ArrayList) }
        behind = @{ key = ''; samples = (New-Object System.Collections.ArrayList) }
        pull = 0.0; shelteredFor = 0.0; sheltered = 0.0; moving = 0.0; lastAt = $null
    }
}

function Reset-Tactics($State) {
    $State.surge.Clear(); $State.flagged.Clear()
    $State.ahead.key = ''; $State.ahead.samples.Clear()
    $State.behind.key = ''; $State.behind.samples.Clear()
    $State.pull = 0.0; $State.shelteredFor = 0.0; $State.sheltered = 0.0; $State.moving = 0.0; $State.lastAt = $null
}

function Get-Median([double[]]$Values) {
    if (-not $Values.Count) { return [double]::NaN }
    $sorted = $Values | Sort-Object
    $m = [int][math]::Floor($sorted.Count / 2)
    if ($sorted.Count % 2) { return [double]$sorted[$m] }
    return ([double]$sorted[$m - 1] + [double]$sorted[$m]) / 2
}

# A rider close to you going clearly faster than the riders around him, two readings in a row (one per second).
function Find-Attack($State, $Riders, [string]$Me, [datetime]$Now) {
    $list = @($Riders | Where-Object { $_ -and -not $_.isEliminated -and $_.speed -is [ValueType] -and $_.timeGap -is [ValueType] })
    $best = $null
    foreach ($r in $list) {
        $name = [string]$r.name
        if ($name -eq $Me) { continue }
        $gap = [double]$r.timeGap / 1000
        if ($gap -gt 15 -or $gap -lt -8) { $State.surge[$name] = 0; continue }
        $around = @($list | Where-Object { $_.name -ne $name -and [math]::Abs([double]$_.timeGap / 1000 - $gap) -le 10 } | ForEach-Object { [double]$_.speed / 1000 })
        $reference = Get-Median $around
        $speed = [double]$r.speed / 1000
        if ([double]::IsNaN($reference) -or $reference -lt 4) { $State.surge[$name] = 0; continue }
        # 3 km/h, or 7 % on fast roads.
        $margin = [math]::Max(0.83, 0.07 * $reference)
        if ($speed - $reference -lt $margin) { $State.surge[$name] = 0; continue }
        $State.surge[$name] = [int]$State.surge[$name] + 1
        if ($State.surge[$name] -lt 2) { continue }
        # Once per rider and per half minute.
        if ($State.flagged.ContainsKey($name) -and ($Now - $State.flagged[$name]).TotalSeconds -lt 30) { continue }
        $kmh = ($speed - $reference) * 3.6
        if (-not $best -or $kmh -gt $best.kmh) { $best = @{ name = $name; team = [string]$r.teamCode; gap = $gap; kmh = $kmh } }
    }
    if ($best) { $State.flagged[$best.name] = $Now }
    return $best
}

function Format-Attack($Attack) {
    $where = $(if ($Attack.gap -ge 0.5) { "$([int][math]::Round($Attack.gap)) s ahead" } elseif ($Attack.gap -le -0.5) { "$([int][math]::Round(-$Attack.gap)) s behind" } else { 'next to you' })
    return "$($Attack.name) +$([int][math]::Round($Attack.kmh)) km/h, $where"
}

function Get-GroupName($Entry) {
    $size = [int]$Entry.size
    if ($Entry.isPeloton) { return "peloton, $size riders" }
    if ([int]$Entry.groupNum2 -gt 0) { return "$([int]$Entry.groupNum2 - [int]$Entry.groupNum1 + 1) groups, $size riders" }
    if ($size -le 1) { return [string]$Entry.leader }
    return "$($Entry.leader) +$($size - 1)"
}

function Format-Seconds([double]$Seconds) {
    $total = [int][math]::Round([math]::Abs($Seconds))
    if ($total -lt 60) { return "$total s" }
    return '{0}:{1:00}' -f [math]::Floor($total / 60), ($total % 60)
}

# Your gap to the race leader, from any group leader among the riders near you; then the groups around you.
function Get-GroupGaps($Groups, $Riders, [string]$Me) {
    $list = @($Groups | Where-Object { $_ -and $_.timeGap1 -is [ValueType] })
    if (-not $list.Count) { return $null }
    $mine = $null
    foreach ($g in $list) {
        if ([int]$g.groupNum2 -gt 0 -or -not $g.leader) { continue }
        if ([string]$g.leader -eq $Me) { $mine = [double]$g.timeGap1; break }
        $near = @($Riders) | Where-Object { $_ -and $_.name -eq $g.leader } | Select-Object -First 1
        if ($near -and $near.timeGap -is [ValueType]) { $mine = [double]$g.timeGap1 + [double]$near.timeGap; break }
    }
    if ($null -eq $mine) { return $null }
    $index = 0
    for ($i = 0; $i -lt $list.Count; $i++) { if ([double]$list[$i].timeGap1 -le $mine + 500) { $index = $i } }
    $result = @{ size = [int]$list[$index].size; ahead = $null; behind = $null; mine = $mine }
    if ($index -gt 0) {
        $g = $list[$index - 1]
        $last = $(if ([int]$g.groupNum2 -gt 0) { [double]$g.timeGap2 } else { [double]$g.timeGap1 })
        $result.ahead = @{ key = $(if ([int]$g.groupNum2 -gt 0) { 'several' } else { [string]$g.leader }); name = Get-GroupName $g; gap = [math]::Max(0, ($mine - $last) / 1000) }
    }
    if ($index -lt $list.Count - 1) {
        $g = $list[$index + 1]
        $result.behind = @{ key = $(if ([int]$g.groupNum2 -gt 0) { 'several' } else { [string]$g.leader }); name = Get-GroupName $g; gap = [math]::Max(0, ([double]$g.timeGap1 - $mine) / 1000) }
    }
    return $result
}

# Gap change in seconds per minute over the last 90 s (least squares), or $null while too early.
function Update-GroupTrend($Trend, $Group, [datetime]$Now) {
    if (-not $Group) { $Trend.key = ''; $Trend.samples.Clear(); return $null }
    $last = $(if ($Trend.samples.Count) { $Trend.samples[$Trend.samples.Count - 1] } else { $null })
    # Another group, or a jump (groups merging or splitting): start again.
    if ($Trend.key -ne $Group.key -or ($last -and [math]::Abs($last.gap - $Group.gap) -gt 8)) { $Trend.key = $Group.key; $Trend.samples.Clear() }
    [void]$Trend.samples.Add(@{ time = $Now; gap = [double]$Group.gap })
    while ($Trend.samples.Count -gt 1 -and ($Now - $Trend.samples[0].time).TotalSeconds -gt 90) { $Trend.samples.RemoveAt(0) }
    $span = ($Now - $Trend.samples[0].time).TotalSeconds
    if ($span -lt 20 -or $Trend.samples.Count -lt 8) { return $null }
    $n = $Trend.samples.Count; $sx = 0.0; $sy = 0.0; $sxx = 0.0; $sxy = 0.0
    foreach ($p in $Trend.samples) { $x = ($p.time - $Trend.samples[0].time).TotalSeconds; $sx += $x; $sy += $p.gap; $sxx += $x * $x; $sxy += $x * $p.gap }
    $den = $n * $sxx - $sx * $sx
    if ($den -le 0) { return $null }
    return ($n * $sxy - $sx * $sy) / $den * 60
}

function Format-GroupLine($Group, $Rate, [bool]$Ahead, [double]$Speed) {
    if (-not $Group) { return $(if ($Ahead) { 'You lead the race' } else { 'Nobody behind' }) }
    $text = "$(Format-Seconds $Group.gap)  ($($Group.name))"
    if ($null -eq $Rate) { return $text }
    if ([math]::Abs($Rate) -lt 0.5) { return "$text  stable" }
    $r = [math]::Abs($Rate).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)
    if ($Ahead) {
        if ($Rate -gt 0) { return "$text  pulling away $r s/min" }
        $minutes = $Group.gap / -$Rate
        $catch = $(if ($minutes -le 60) { $km = $minutes * 60 * $Speed / 1000; "  catch ~$([int][math]::Ceiling($minutes)) min" + $(if ($Speed -gt 3) { " / $($km.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture)) km" } else { '' }) } else { '' })
        return "$text  closing $r s/min$catch"
    }
    if ($Rate -lt 0) {
        $minutes = $Group.gap / -$Rate
        return "$text  gaining $r s/min" + $(if ($minutes -le 60) { "  here in ~$([int][math]::Ceiling($minutes)) min" } else { '' })
    }
    return "$text  dropping $r s/min"
}

# Time at the front of a group: draft under 10 % while moving with others. Back in the wheels (25 % or more
# for 3 s) resets it. Also the share of the ride spent sheltered.
function Update-Pull($State, [double]$Draft, [double]$Speed, [int]$GroupSize, [datetime]$Now) {
    $dt = 0.0
    if ($State.lastAt) { $dt = [math]::Min(2.0, ($Now - $State.lastAt).TotalSeconds) }
    $State.lastAt = $Now
    if ($Speed -lt 4) { return }
    $State.moving += $dt
    if ($Draft -ge 25) {
        $State.sheltered += $dt
        $State.shelteredFor += $dt
        if ($State.shelteredFor -ge 3) { $State.pull = 0.0 }
    } else {
        $State.shelteredFor = 0.0
        if ($Draft -lt 10 -and $GroupSize -ge 2) { $State.pull += $dt }
    }
}

function Format-Pull($State, [int]$GroupSize) {
    $share = $(if ($State.moving -ge 30) { "  |  wheels $([int][math]::Round(100 * $State.sheltered / $State.moving)) %" } else { '' })
    if ($GroupSize -le 1) { return "Solo$share" }
    $p = [int]$State.pull
    if ($p -lt 3) { return "In the wheels$share" }
    $time = '{0}:{1:00}' -f [math]::Floor($p / 60), ($p % 60)
    if ($p -ge 60) { return "PULL $time  ROTATE!$share" }
    return "PULL $time$share"
}

# Teammates: their gap when they ride near you, or the group they lead.
function Get-Teammates($Riders, $Groups, $Entries, [string]$Me, [string]$Team, $MyGapMs) {
    if (-not $Team) { return @() }
    $out = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($r in @($Riders)) {
        if (-not $r -or $r.name -eq $Me -or [string]$r.teamCode -ne $Team) { continue }
        $gap = [double]$r.timeGap / 1000
        $where = $(if ([math]::Abs($gap) -lt 1) { 'with you' } elseif ($gap -gt 0) { "+$(Format-Seconds $gap)" } else { "-$(Format-Seconds $gap)" })
        if ($r.isEliminated) { $where = 'out' }
        [void]$out.Add(@{ name = [string]$r.name; where = $where; order = -$gap }); $seen[[string]$r.name] = $true
    }
    $myGap = $MyGapMs
    foreach ($e in @($Entries)) {
        if (-not $e -or $e.name -eq $Me -or [string]$e.teamCode -ne $Team -or $seen[[string]$e.name]) { continue }
        $lead = @($Groups) | Where-Object { $_ -and [string]$_.leader -eq $e.name } | Select-Object -First 1
        if ($lead -and $null -ne $myGap) {
            $gap = ($myGap - [double]$lead.timeGap1) / 1000
            [void]$out.Add(@{ name = [string]$e.name; where = $(if ($gap -ge 0) { "+$(Format-Seconds $gap)" } else { "-$(Format-Seconds $gap)" }); order = -$gap })
        } elseif ($lead) {
            [void]$out.Add(@{ name = [string]$e.name; where = 'leads a group'; order = 0 })
        } else {
            [void]$out.Add(@{ name = [string]$e.name; where = 'not near'; order = 1e9 })
        }
        $seen[[string]$e.name] = $true
    }
    return @($out | Sort-Object { $_.order })
}

function Format-Teammates($Mates) {
    if (-not @($Mates).Count) { return 'No teammate in this race' }
    $parts = foreach ($m in @($Mates) | Select-Object -First 3) { $first = ([string]$m.name -split ' ')[0]; "$first $($m.where)" }
    $more = @($Mates).Count - 3
    return ($parts -join '  |  ') + $(if ($more -gt 0) { "  +$more" } else { '' })
}
