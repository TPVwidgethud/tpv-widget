# Corner coach: detects corners from the rider's own path, remembers them by position,
# and refines both a global cornering model and a per-corner reference after every pass.
# It needs no route data, so it works on any circuit and shares what it learns between routes.

$script:CoachDefaultALat = 6.8      # m/s2, measured on flat braked corners; refined by replay and live data.
$script:CoachBrakeDecel = 3.0       # m/s2 used to estimate the distance needed to slow down.
$script:CoachReaction = 2.5         # seconds to react and stop pedaling.
$script:CoachHistory = 10           # passes kept per corner.
$script:CoachMinPasses = 3          # passes needed before a corner has a personal reference.
$script:CoachTurnDegrees = 30       # heading change over 30 m that marks a corner.

function New-CoachState([double]$Ftp) {
    return @{
        ftp = $Ftp
        limit = $Ftp * 0.33
        buffer = (New-Object 'System.Collections.Generic.List[object]')
        active = $null
        pending = (New-Object 'System.Collections.Generic.List[object]')
        distance = 0.0
        library = @{ aLat = $script:CoachDefaultALat; aSamples = (New-Object System.Collections.ArrayList); corners = @{}; approach = @{}; nextId = 1 }
        session = @{ missed = 0; over = 0; last = $null; corners = 0; bad = 0 }
        flag = @{ hardAt = $null; lastT = -1.0; fast = $false; hard = $false; until = -1.0; inBrake = $false; decided = $false; brakeStart = 0.0; lastBrake = 0.0 }
        mass = 87.4
        realBrakeSeen = $false
        dirty = $false
    }
}

function Reset-CoachSession($Coach) {
    $Coach.session.missed = 0
    $Coach.session.over = 0
    $Coach.session.last = $null
    $Coach.session.corners = 0
    $Coach.session.bad = 0
    $Coach.flag.hardAt = $null
}

function Clear-CoachTrack($Coach) {
    $Coach.buffer.Clear()
    $Coach.pending.Clear()
    $Coach.active = $null
}

function Get-CoachMedian($Values) {
    $a = [double[]]@($Values)
    if ($a.Length -eq 0) { return 0.0 }
    [Array]::Sort($a)
    $mid = [int][math]::Floor($a.Length / 2)
    if ($a.Length % 2) { return $a[$mid] }
    return ($a[$mid - 1] + $a[$mid]) / 2
}

function Get-CoachSpread($Values, [double]$Median) {
    # Robust standard deviation: one bad pass does not widen the tolerance.
    $deviations = foreach ($v in @($Values)) { [math]::Abs([double]$v - $Median) }
    return 1.4826 * (Get-CoachMedian $deviations)
}

function Get-CoachIndexAt($Buffer, [double]$Distance) {
    # Last sample at or before this path distance, or -1.
    $low = 0
    $high = $Buffer.Count - 1
    $found = -1
    while ($low -le $high) {
        $mid = [int][math]::Floor(($low + $high) / 2)
        if ([double]$Buffer[$mid].s -le $Distance) { $found = $mid; $low = $mid + 1 } else { $high = $mid - 1 }
    }
    return $found
}

function Get-CoachValueAt($Buffer, [double]$Distance, [string]$Field) {
    $i = Get-CoachIndexAt $Buffer $Distance
    if ($i -lt 0) { return [double]$Buffer[0][$Field] }
    if ($i -ge $Buffer.Count - 1) { return [double]$Buffer[$Buffer.Count - 1][$Field] }
    $a = $Buffer[$i]
    $b = $Buffer[$i + 1]
    $span = [double]$b.s - [double]$a.s
    if ($span -le 0) { return [double]$a[$Field] }
    return [double]$a[$Field] + ([double]$b[$Field] - [double]$a[$Field]) * ($Distance - [double]$a.s) / $span
}

function Get-CoachAngle([double]$Ax, [double]$Ay, [double]$Bx, [double]$By) {
    return [math]::Atan2($Ax * $By - $Ay * $Bx, $Ax * $Bx + $Ay * $By)
}

function Get-CoachHeadingKey($Sample) {
    $sector = [int][math]::Floor(([double]$Sample.h + [math]::PI) / ([math]::PI / 4)) % 8
    return @([int][math]::Floor([double]$Sample.x / 10), [int][math]::Floor([double]$Sample.y / 10), $sector)
}

function Find-CoachCorner($Coach, [double]$X, [double]$Y, [double]$Heading, [int]$Sign) {
    $best = $null
    $bestDistance = 18.0
    foreach ($corner in $Coach.library.corners.Values) {
        if ([int]$corner.sign -ne $Sign) { continue }
        $dx = [double]$corner.x - $X
        if ([math]::Abs($dx) -gt 18) { continue }
        $dy = [double]$corner.y - $Y
        if ([math]::Abs($dy) -gt 18) { continue }
        $d = [math]::Sqrt($dx * $dx + $dy * $dy)
        if ($d -ge $bestDistance) { continue }
        $turn = [math]::Abs([math]::Atan2([math]::Sin($Heading - [double]$corner.h), [math]::Cos($Heading - [double]$corner.h)))
        if ($turn -gt 1.05) { continue }
        $best = $corner
        $bestDistance = $d
    }
    return $best
}

function Add-CoachReference($Corner, [string]$Field, [double]$Value) {
    [void]$Corner[$Field].Add($Value)
    while ($Corner[$Field].Count -gt $script:CoachHistory) { $Corner[$Field].RemoveAt(0) }
}

function Get-CoachTarget($Coach, $Corner) {
    # Personal speed once the corner is known, otherwise the curvature model.
    if ($Corner.apex.Count -ge $script:CoachMinPasses) { return (Get-CoachMedian $Corner.apex) }
    return [math]::Sqrt([double]$Coach.library.aLat * (Get-CoachMedian $Corner.radius))
}

function Complete-CoachCorner($Coach, $Pending) {
    $b = $Coach.buffer
    $a = [double]$Pending.s
    if ([double]$b[0].s -gt $a - 65) { return $null }

    $x0 = Get-CoachValueAt $b ($a - 12) 'x'; $y0 = Get-CoachValueAt $b ($a - 12) 'y'
    $x1 = Get-CoachValueAt $b ($a - 4) 'x'; $y1 = Get-CoachValueAt $b ($a - 4) 'y'
    $x2 = Get-CoachValueAt $b ($a + 4) 'x'; $y2 = Get-CoachValueAt $b ($a + 4) 'y'
    $x3 = Get-CoachValueAt $b ($a + 12) 'x'; $y3 = Get-CoachValueAt $b ($a + 12) 'y'
    $delta = [math]::Abs((Get-CoachAngle ($x1 - $x0) ($y1 - $y0) ($x3 - $x2) ($y3 - $y2)))
    if ($delta -lt 0.15) { return $null }
    $radius = [math]::Max([double]4, [math]::Min([double]80, 16 / $delta))

    $from = [math]::Max(0, (Get-CoachIndexAt $b ($a - 75)))
    $vApex = [double]::MaxValue
    $powerSum = 0.0; $powerCount = 0; $braked = $false; $slopeSum = 0.0; $slopeCount = 0
    $brakePower = 0.0; $brakeCount = 0
    for ($i = $from; $i -lt $b.Count; $i++) {
        $q = $b[$i]
        $rel = [double]$q.s - $a
        if ($rel -gt 60) { break }
        if ($rel -ge -16 -and $rel -le 16 -and [double]$q.v -lt $vApex) { $vApex = [double]$q.v }
        if ($rel -ge -60 -and $rel -le -5) { $powerSum += [double]$q.p; $powerCount++ }
        if ($rel -ge -60 -and $rel -le 5 -and [double]$q.brake -gt 0) {
            $braked = $true
            $brakePower += [double]$q.p
            $brakeCount++
        }
        if ($rel -ge -20 -and $rel -le 20) { $slopeSum += [double]$q.slope; $slopeCount++ }
    }
    if ($vApex -eq [double]::MaxValue -or $powerCount -eq 0 -or $vApex -lt 3) { return $null }
    $pEntry = $powerSum / $powerCount
    $slope = $(if ($slopeCount) { $slopeSum / $slopeCount } else { 0.0 })
    $vEntry = Get-CoachValueAt $b ($a - 40) 'v'
    $vExit = Get-CoachValueAt $b ($a + 40) 'v'
    $section = (Get-CoachValueAt $b ($a + 60) 't') - (Get-CoachValueAt $b ($a - 60) 't')
    $apexX = Get-CoachValueAt $b $a 'x'
    $apexY = Get-CoachValueAt $b $a 'y'
    $heading = [math]::Atan2($y2 - $y1, $x2 - $x1)
    $sign = $(if ($Pending.turn -ge 0) { 1 } else { -1 })

    $corner = Find-CoachCorner $Coach $apexX $apexY $heading $sign
    if (-not $corner) {
        $id = [int]$Coach.library.nextId
        $Coach.library.nextId = $id + 1
        $corner = @{
            id = $id; x = $apexX; y = $apexY; h = $heading; sign = $sign
            radius = (New-Object System.Collections.ArrayList); apex = (New-Object System.Collections.ArrayList)
            entry = (New-Object System.Collections.ArrayList); exit = (New-Object System.Collections.ArrayList)
            power = (New-Object System.Collections.ArrayList); time = (New-Object System.Collections.ArrayList)
        }
        $Coach.library.corners[[string]$id] = $corner
    }

    $type = 'clean'
    $lost = 0.0; $exitDelta = 0.0; $entryHigh = $false; $powerHigh = $false
    $compared = $corner.time.Count -ge $script:CoachMinPasses
    if ($corner.time.Count -ge $script:CoachMinPasses) {
        $mEntry = Get-CoachMedian $corner.entry; $mExit = Get-CoachMedian $corner.exit
        $mPower = Get-CoachMedian $corner.power; $mTime = Get-CoachMedian $corner.time
        $lost = $section - $mTime
        $exitDelta = ($vExit - $mExit) * 3.6
        $entryHigh = ($vEntry - $mEntry) -ge [math]::Max([double](1.5 / 3.6), 1.5 * (Get-CoachSpread $corner.entry $mEntry))
        $powerHigh = ($pEntry - $mPower) -ge [math]::Max([double](0.2 * $Coach.ftp), 1.5 * (Get-CoachSpread $corner.power $mPower))
        $timeLost = $lost -ge [math]::Max([double]0.5, 1.5 * (Get-CoachSpread $corner.time $mTime))
        if ($braked -and $timeLost -and ($entryHigh -or $powerHigh)) { $type = 'missed' }
    } elseif ($brakeCount -ge 2 -and ($brakePower / $brakeCount) -gt $Coach.limit) {
        # No reference yet: only pedaling through a sustained braking phase is reported.
        $type = 'over'
    }

    if ($type -eq 'missed') { $Coach.session.missed++ }
    elseif ($type -eq 'over') { $Coach.session.over++ }

    # Score: braked corners without TOO HARD or MISSED. One TOO HARD counts for one corner only.
    $hardAt = $Coach.flag.hardAt
    $wasHard = $null -ne $hardAt -and ([double]$Pending.t - [double]$hardAt) -le 8 -and ([double]$Pending.t - [double]$hardAt) -ge -2
    if ($braked -or $wasHard -or $type -eq 'missed') {
        $Coach.session.corners++
        if ($wasHard -or $type -eq 'missed') { $Coach.session.bad++ }
    }
    if ($wasHard) { $Coach.flag.hardAt = $null }
    if ($type -ne 'clean') {
        $Coach.session.last = @{ type = $type; lost = $lost; exitDelta = $exitDelta; corner = $corner.id; t = [double]$Pending.t; power = $pEntry; fast = $entryHigh; hard = $powerHigh }
    }

    # A missed pass stays out of the reference, otherwise mistakes would become the new normal.
    if ($type -ne 'missed') {
        Add-CoachReference $corner 'radius' $radius
        Add-CoachReference $corner 'apex' $vApex
        Add-CoachReference $corner 'entry' $vEntry
        Add-CoachReference $corner 'exit' $vExit
        Add-CoachReference $corner 'power' $pEntry
        Add-CoachReference $corner 'time' $section
        if ($braked -and [math]::Abs($slope) -le 3 -and $radius -le 30) {
            $sampleA = $vApex * $vApex / $radius
            if ($sampleA -ge 3 -and $sampleA -le 10) {
                [void]$Coach.library.aSamples.Add($sampleA)
                while ($Coach.library.aSamples.Count -gt 200) { $Coach.library.aSamples.RemoveAt(0) }
                if ($Coach.library.aSamples.Count -ge 5) { $Coach.library.aLat = Get-CoachMedian $Coach.library.aSamples }
            }
        }
    }

    # Remember the approach so that the corner can be announced on the next pass.
    $key = [string]$corner.id
    for ($i = [math]::Max(0, (Get-CoachIndexAt $b ($a - 200))); $i -lt $b.Count; $i++) {
        $q = $b[$i]
        $ahead = $a - [double]$q.s
        if ($ahead -lt 5) { break }
        if ($ahead -gt 200) { continue }
        $k = Get-CoachHeadingKey $q
        $cell = "$($k[0]):$($k[1]):$($k[2])"
        $current = $Coach.library.approach[$cell]
        if (-not $current -or [double]$current[1] -ge $ahead) { $Coach.library.approach[$cell] = @($key, [math]::Round($ahead)) }
    }
    $Coach.dirty = $true
    return @{ type = $type; id = $corner.id; lost = $lost; exitDelta = $exitDelta; apex = $vApex; radius = $radius; power = $pEntry; t = [double]$Pending.t; entry = $vEntry; passes = $corner.time.Count; compared = $compared; fast = $entryHigh; hard = $powerHigh }
}

function Add-CoachSample($Coach, [double]$Time, [double]$Latitude, [double]$Longitude, [double]$SpeedMs, [double]$Power, [double]$Brake, [double]$Slope) {
    # Coordinates are FIT semicircles. Returns the corners completed by this sample.
    $done = New-Object System.Collections.ArrayList
    $latDeg = $Latitude * 180 / 2147483648
    $lonDeg = $Longitude * 180 / 2147483648
    $y = $latDeg * 111320
    $x = $lonDeg * 111320 * [math]::Cos([math]::Round($latDeg, 1) * [math]::PI / 180)
    $b = $Coach.buffer
    $heading = 0.0
    if ($b.Count -gt 0) {
        $last = $b[$b.Count - 1]
        $dx = $x - [double]$last.x
        $dy = $y - [double]$last.y
        $step = [math]::Sqrt($dx * $dx + $dy * $dy)
        $dt = $Time - [double]$last.t
        if ($step -lt 0.5) { return ,$done }
        if ($dt -gt 3 -or $dt -le 0 -or $step -gt 80) {
            Clear-CoachTrack $Coach
            $b = $Coach.buffer
        } else {
            $Coach.distance += $step
            $heading = [math]::Atan2($dy, $dx)
        }
    }
    $b.Add(@{ t = $Time; x = $x; y = $y; v = $SpeedMs; p = $Power; brake = $Brake; slope = $Slope; s = [double]$Coach.distance; h = $heading })
    $headIndex = $b.Count - 1
    $headS = [double]$Coach.distance
    while ($b.Count -gt 2 -and [double]$b[0].s -lt $headS - 340) { $b.RemoveAt(0); $headIndex-- }

    if ([double]$b[0].s -le $headS - 30) {
        $sMid = $headS - 15
        $midX = Get-CoachValueAt $b $sMid 'x'; $midY = Get-CoachValueAt $b $sMid 'y'
        $backX = Get-CoachValueAt $b ($headS - 30) 'x'; $backY = Get-CoachValueAt $b ($headS - 30) 'y'
        $turn = (Get-CoachAngle ($midX - $backX) ($midY - $backY) ($x - $midX) ($y - $midY)) * 180 / [math]::PI
        $absTurn = [math]::Abs($turn)
        $sign = $(if ($turn -ge 0) { 1 } else { -1 })
        $active = $Coach.active
        if ($absTurn -ge $script:CoachTurnDegrees) {
            if ($active -and [int]$active.sign -eq $sign) {
                if ($absTurn -gt [double]$active.peak) { $active.peak = $absTurn; $active.s = $sMid; $active.t = Get-CoachValueAt $b $sMid 't' }
            } else {
                if ($active) { $Coach.pending.Add(@{ s = $active.s; turn = $active.sign * $active.peak; t = $active.t }) }
                $Coach.active = @{ sign = $sign; peak = $absTurn; s = $sMid; t = (Get-CoachValueAt $b $sMid 't') }
            }
        } elseif ($active) {
            $Coach.pending.Add(@{ s = $active.s; turn = $active.sign * $active.peak; t = $active.t })
            $Coach.active = $null
        }
    }
    while ($Coach.pending.Count -gt 0 -and $headS -ge [double]$Coach.pending[0].s + 60) {
        $p = $Coach.pending[0]
        $Coach.pending.RemoveAt(0)
        $result = Complete-CoachCorner $Coach $p
        if ($result) { [void]$done.Add($result) }
    }
    return ,$done
}

function Get-CoachRiderMass([string]$LogDirectory, [double]$BikeKg = 8) {
    # Rider weight from the newest log that states it, plus the bike.
    $logs = Get-ChildItem -LiteralPath $LogDirectory -Filter 'playerlog*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($log in $logs) {
        try {
            $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
            $found = [regex]::Matches($text, 'Weight:\s*([\d.,]+)\s*kg')
            if ($found.Count -gt 0) {
                $kg = [double]::Parse($found[$found.Count - 1].Groups[1].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
                if ($kg -ge 30 -and $kg -le 200) { return $kg + $BikeKg }
            }
        } catch { }
    }
    return 87.4
}

function Get-CoachBrakeSignal($Coach, [double]$Time, [double]$SpeedMs, [double]$Power, [double]$SlopePercent, [double]$RealBrake) {
    # The game's own value wins as soon as it has been seen. Until then, braking is deduced:
    # the rider slows down more than slope, rolling resistance, air and power can explain.
    if ($RealBrake -gt 0) { $Coach.realBrakeSeen = $true }
    if ($Coach.realBrakeSeen) { return $RealBrake }
    $b = $Coach.buffer
    if ($b.Count -eq 0) { return 0.0 }
    # A hard brake shows in a single interval: it is reported without waiting for the longer window.
    $latest = $b[$b.Count - 1]
    $quickDt = $Time - [double]$latest.t
    if ($quickDt -ge 0.15 -and $quickDt -le 0.6) {
        $quickAcceleration = ($SpeedMs - [double]$latest.v) / $quickDt
        $quickDrive = $Power / [math]::Max([double]2, $SpeedMs) / [double]$Coach.mass
        $quickResist = 9.81 * ($SlopePercent / 100 + 0.004) + 0.5 * 1.2 * 0.32 * 0.7 * $SpeedMs * $SpeedMs / [double]$Coach.mass
        if ($quickDrive - $quickResist - $quickAcceleration -gt 1.5) { return 1.0 }
    }
    $previous = $null
    for ($i = $b.Count - 1; $i -ge 0; $i--) {
        if ($Time - [double]$b[$i].t -ge 0.45) { $previous = $b[$i]; break }
    }
    if (-not $previous) { return 0.0 }
    $dt = $Time - [double]$previous.t
    if ($dt -le 0 -or $dt -gt 3) { return 0.0 }
    $acceleration = ($SpeedMs - [double]$previous.v) / $dt
    $mass = [double]$Coach.mass
    $drive = $Power / [math]::Max([double]2, $SpeedMs) / $mass
    $resist = 9.81 * ($SlopePercent / 100 + 0.004) + 0.5 * 1.2 * 0.32 * 0.7 * $SpeedMs * $SpeedMs / $mass
    $unexplained = $drive - $resist - $acceleration
    if ($unexplained -gt 0.6) { return 1.0 }
    return 0.0
}

function Update-CoachFlag($Coach, $Advice, [double]$Time, [double]$Brake = 0) {
    # Each braking phase gets one diagnosis, based on speed and power just before it began:
    # once the rider is braking, speed has already dropped and hides the real cause.
    $f = $Coach.flag
    $b = $Coach.buffer
    if ($b.Count -gt 0 -and [double]$b[$b.Count - 1].t -ne $f.lastT) {
        $sampleTime = [double]$b[$b.Count - 1].t
        $f.lastT = $sampleTime
        if ($Brake -gt 0) {
            if (-not $f.inBrake) { $f.inBrake = $true; $f.decided = $false; $f.brakeStart = $sampleTime }
            $f.lastBrake = $sampleTime
        } elseif ($f.inBrake -and $sampleTime - $f.lastBrake -gt 1.0) {
            $f.inBrake = $false
        }
        if ($f.inBrake -and -not $f.decided) {
            $useAdvice = $Advice.status -ne 'none' -and [double]$Advice.distance -le 80
            # Corner never seen before: the bend being ridden right now gives its radius.
            $liveTurn = (-not $useAdvice) -and $null -ne $Coach.active
            if ($useAdvice -or $liveTurn) {
                $f.decided = $true
                # A deduced brake is confirmed about a second late; the game's own value is not.
                $lag = $(if ($Coach.realBrakeSeen) { 0.2 } else { 1.0 })
                $to = [double]$f.brakeStart - $lag
                $from = $to - 2.0
                $vPre = 0.0; $powerSum = 0.0; $count = 0
                for ($i = $b.Count - 1; $i -ge 0; $i--) {
                    $q = $b[$i]
                    if ([double]$q.t -lt $from) { break }
                    if ([double]$q.t -gt $to) { continue }
                    if ([double]$q.v -gt $vPre) { $vPre = [double]$q.v }
                    $powerSum += [double]$q.p
                    $count++
                }
                if ($count -gt 0) {
                    $pPre = $powerSum / $count
                    if ($useAdvice -and $Advice.known) {
                        $fast = ($vPre - [double]$Advice.usualEntry) -ge (1.5 / 3.6) -and ($vPre - [double]$Advice.targetMs) -ge (3 / 3.6)
                        $hard = ($pPre - [double]$Advice.usualPower) -ge (0.2 * $Coach.ftp) -and $pPre -gt $Coach.limit
                    } else {
                        if ($useAdvice) {
                            $targetMs = [double]$Advice.targetMs
                        } else {
                            $liveRadius = [math]::Max([double]4, [math]::Min([double]80, 30 / ([double]$Coach.active.peak * [math]::PI / 180)))
                            $targetMs = [math]::Sqrt([double]$Coach.library.aLat * $liveRadius)
                        }
                        # Without a personal reference, normal riders still pedal up to the corner.
                        $fast = ($vPre - $targetMs) -ge (5 / 3.6)
                        $hard = $pPre -gt (0.85 * $Coach.ftp)
                    }
                    if ($fast -or $hard) {
                        if ($Time -gt $f.until) { $f.fast = $false; $f.hard = $false }
                        if ($fast) { $f.fast = $true }
                        if ($hard) { $f.hard = $true; $f.hardAt = $sampleTime }
                        $f.until = $Time + 2.5
                    }
                }
            } elseif ($sampleTime - [double]$f.brakeStart -gt 2.5) {
                $f.decided = $true
            }
        }
    }
    if ($Time -gt $f.until) { $f.fast = $false; $f.hard = $false }
    return $f
}

function Format-CoachFlag($Flag) {
    if ($Flag.fast -and $Flag.hard) { return 'TOO FAST + TOO HARD' }
    if ($Flag.fast) { return 'TOO FAST' }
    if ($Flag.hard) { return 'TOO HARD' }
    return ''
}

function Format-CoachBanner($Flag) {
    # Too fast alone rarely cost time in replays, so only causes involving power get the big banner.
    if ($Flag.hard) { return (Format-CoachFlag $Flag) }
    return ''
}

function Get-CoachAdvice($Coach, [double]$SpeedMs, [double]$Power, [double]$Brake = 0) {
    $b = $Coach.buffer
    if ($b.Count -eq 0) { return @{ status = 'none' } }
    $k = Get-CoachHeadingKey $b[$b.Count - 1]
    $best = $null
    foreach ($dx in -1, 0, 1) {
        foreach ($dy in -1, 0, 1) {
            foreach ($ds in -1, 0, 1) {
                $cell = "$($k[0] + $dx):$($k[1] + $dy):$((([int]$k[2] + $ds) + 8) % 8)"
                $entry = $Coach.library.approach[$cell]
                if ($entry -and (-not $best -or [double]$entry[1] -lt [double]$best[1])) { $best = $entry }
            }
        }
    }
    if (-not $best) { return @{ status = 'none' } }
    $corner = $Coach.library.corners[[string]$best[0]]
    if (-not $corner) { return @{ status = 'none' } }
    $distance = [double]$best[1]
    $target = Get-CoachTarget $Coach $corner
    $need = ($SpeedMs * $SpeedMs - $target * $target) / (2 * $script:CoachBrakeDecel) + $SpeedMs * $script:CoachReaction
    $known = $corner.power.Count -ge $script:CoachMinPasses
    $ease = $false
    # Closer than 15 m the warning would come too late to be acted on.
    if ($distance -ge 15) {
        if ($known) {
            # Known corner: warn only when both speed and power are above this rider's usual approach.
            $usualEntry = Get-CoachMedian $corner.entry
            $usualPower = Get-CoachMedian $corner.power
            $ease = $distance -ge 20 -and $distance -le 60 -and
                ($SpeedMs - $target) -ge (3 / 3.6) -and
                ($SpeedMs - $usualEntry) -ge (1.5 / 3.6) -and
                ($Power - $usualPower) -ge (0.2 * $Coach.ftp) -and
                $Power -gt $Coach.limit
        } else {
            # New corner: the curvature model is less certain, so it needs a clear speed excess.
            $ease = $distance -le $need -and ($SpeedMs - $target) -ge (5 / 3.6) -and $Power -gt $Coach.limit
        }
    }
    $status = $(if ($ease) { 'ease' } else { 'info' })
    $usualEntry = $(if ($known) { Get-CoachMedian $corner.entry } else { 0.0 })
    $usualPower = $(if ($known) { Get-CoachMedian $corner.power } else { 0.0 })
    return @{ status = $status; distance = $distance; target = $target * 3.6; targetMs = $target; known = $known; id = $corner.id; usualEntry = $usualEntry; usualPower = $usualPower }
}

function Format-CoachAdvice($Advice) {
    switch ($Advice.status) {
        'none' { return 'Learning' }
        'ease' { return "EASE OFF  $([int]$Advice.distance) m  >  $([int][math]::Round($Advice.target)) km/h" }
        default { return "$([int]$Advice.distance) m  >  $([int][math]::Round($Advice.target)) km/h" }
    }
}

function Format-CoachMissed($Coach) {
    $s = $Coach.session
    $text = "$($s.missed)"
    if ($s.over -gt 0) { $text += "  +$($s.over) over" }
    if ($s.last -and $s.last.type -eq 'missed') {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $cause = $(if ($s.last.fast -and $s.last.hard) { 'fast+hard' } elseif ($s.last.fast) { 'too fast' } else { 'too hard' })
        $text += "  |  $cause +$(([double]$s.last.lost).ToString('0.0', $inv)) s"
    }
    return $text
}

function Save-CoachLibrary($Coach, [string]$Path) {
    if (-not $Coach.dirty) { return }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    $format = { param($list) (@($list) | ForEach-Object { ([double]$_).ToString('0.###', $inv) }) -join ',' }
    $corners = foreach ($c in $Coach.library.corners.Values) {
        [ordered]@{
            id = $c.id; x = [math]::Round($c.x, 2); y = [math]::Round($c.y, 2); h = [math]::Round($c.h, 4); sign = $c.sign
            radius = (& $format $c.radius); apex = (& $format $c.apex); entry = (& $format $c.entry)
            exit = (& $format $c.exit); power = (& $format $c.power); time = (& $format $c.time)
        }
    }
    $approach = foreach ($k in $Coach.library.approach.Keys) { "$k=$($Coach.library.approach[$k][0])/$($Coach.library.approach[$k][1])" }
    $json = [ordered]@{
        version = 1; aLat = [math]::Round([double]$Coach.library.aLat, 3); aSamples = (& $format $Coach.library.aSamples)
        nextId = $Coach.library.nextId; corners = @($corners); approach = ($approach -join ';')
    } | ConvertTo-Json -Depth 4 -Compress
    $temp = "$Path.tmp"
    [IO.File]::WriteAllText($temp, $json)
    Move-Item -LiteralPath $temp -Destination $Path -Force
    $Coach.dirty = $false
}

function Read-CoachLibrary($Coach, [string]$Path) {
    # A good library is copied at each start; a damaged one is kept aside and never overwritten.
    $backup = "$Path.bak"
    if (Test-Path -LiteralPath $Path) {
        if (Import-CoachLibrary $Coach $Path) {
            try { Copy-Item -LiteralPath $Path -Destination $backup -Force } catch { }
            return
        }
        try { Copy-Item -LiteralPath $Path -Destination "$Path.damaged" -Force } catch { }
    }
    if (Test-Path -LiteralPath $backup) {
        if (Import-CoachLibrary $Coach $backup) { $Coach.dirty = $true }
    }
}

function Import-CoachLibrary($Coach, [string]$Path) {
    try {
        $j = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $parse = {
            param($text)
            $list = New-Object System.Collections.ArrayList
            if ($text) { foreach ($part in ([string]$text).Split(',')) { [void]$list.Add([double]::Parse($part, $inv)) } }
            ,$list
        }
        $library = @{ aLat = [double]$j.aLat; aSamples = (& $parse $j.aSamples); corners = @{}; approach = @{}; nextId = [int]$j.nextId }
        foreach ($c in @($j.corners)) {
            $library.corners[[string]$c.id] = @{
                id = [int]$c.id; x = [double]$c.x; y = [double]$c.y; h = [double]$c.h; sign = [int]$c.sign
                radius = (& $parse $c.radius); apex = (& $parse $c.apex); entry = (& $parse $c.entry)
                exit = (& $parse $c.exit); power = (& $parse $c.power); time = (& $parse $c.time)
            }
        }
        if ($j.approach) {
            foreach ($pair in ([string]$j.approach).Split(';')) {
                $kv = $pair.Split('=')
                $v = $kv[1].Split('/')
                $library.approach[$kv[0]] = @($v[0], [double]$v[1])
            }
        }
        $Coach.library = $library
        return $true
    } catch { return $false }
}
