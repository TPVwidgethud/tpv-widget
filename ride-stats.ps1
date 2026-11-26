# Ride statistics for the overlay: intensity, work above FTP, best efforts, laps and climbs.
# Requires New-PowerWindow and Update-PowerWindow from race-data.ps1.

function New-RideStats {
    $stats = @{ w60 = (New-PowerWindow 60); w300 = (New-PowerWindow 300) }
    Reset-RideStats $stats
    return $stats
}

function Reset-RideStats($Stats) {
    $Stats.rider = $null
    $Stats.last = $null
    $Stats.gameTime = $null
    $Stats.kjAbove = 0.0
    $Stats.wbalMin = $null
    $Stats.best60 = $null
    $Stats.best300 = $null
    $Stats.lap = $null
    $Stats.lastLap = $null
    $Stats.climb = $null
    $Stats.lastClimb = $null
    $Stats.seconds = 0.0
    $Stats.coast = 0.0
    $Stats.zones = New-Object 'double[]' 7
    Reset-PowerWindow $Stats.w60
    Reset-PowerWindow $Stats.w300
}

function Get-RideClimbTotals($Climb, $Part) {
    $gain = $(if ($null -ne $Part.altitude -and $null -ne $Climb.startAltitude) { $Part.altitude - $Climb.startAltitude } else { $Part.gain })
    if ($Part.seconds -le 0 -or $Part.distance -le 0) { return $null }
    return @{
        seconds = $Part.seconds; power = $Part.energy / $Part.seconds; gain = $gain
        vam = $gain / $Part.seconds * 3600; grade = 100 * $gain / $Part.distance
    }
}

function Update-RideClimb($Stats, [double]$Dt, [double]$Power, [double]$Slope, [double]$Speed, $AltitudeMeters) {
    # Starts at 3 %, and ends after 10 s below 1.5 % so that a short flat does not split a climb.
    if (-not $Stats.climb) {
        if ($Slope -lt 3) { return }
        $Stats.climb = @{
            startAltitude = $AltitudeMeters; low = 0.0
            now = @{ seconds = 0.0; energy = 0.0; gain = 0.0; distance = 0.0; altitude = $AltitudeMeters }
            kept = @{ seconds = 0.0; energy = 0.0; gain = 0.0; distance = 0.0; altitude = $AltitudeMeters }
        }
    }
    $climb = $Stats.climb
    $climb.now.seconds += $Dt
    $climb.now.energy += $Power * $Dt
    $climb.now.distance += $Speed * $Dt
    $climb.now.gain += $Speed * [math]::Sin([math]::Atan($Slope / 100)) * $Dt
    $climb.now.altitude = $AltitudeMeters
    if ($Slope -ge 1.5) {
        $climb.low = 0.0
        $climb.kept = $climb.now.Clone()
        return
    }
    $climb.low += $Dt
    if ($climb.low -lt 10) { return }
    $done = Get-RideClimbTotals $climb $climb.kept
    if ($done -and $done.seconds -ge 30 -and $done.gain -ge 10) { $Stats.lastClimb = $done }
    $Stats.climb = $null
}

function Update-RideLap($Stats, [double]$Dt, [double]$Power, $GameTime, $LapsDone, $LapsTotal) {
    if ($LapsDone -isnot [ValueType] -or $LapsTotal -isnot [ValueType] -or [int]$LapsTotal -le 1 -or [int]$LapsDone -lt 0) {
        $Stats.lap = $null
        return
    }
    $done = [int]$LapsDone
    if (-not $Stats.lap) {
        # Joining mid-lap gives a partial lap, which must not be compared.
        $fromStart = ($done -eq 0 -and $GameTime -is [ValueType] -and [double]$GameTime -le 15)
        $Stats.lap = @{ done = $done; seconds = 0.0; energy = 0.0; complete = $fromStart }
    }
    if ($done -ne $Stats.lap.done) {
        if ($done -eq $Stats.lap.done + 1 -and $Stats.lap.complete -and $Stats.lap.seconds -gt 0) {
            $delta = $(if ($Stats.lastLap) { $Stats.lap.seconds - $Stats.lastLap.seconds } else { $null })
            $Stats.lastLap = @{ number = $done; seconds = $Stats.lap.seconds; power = $Stats.lap.energy / $Stats.lap.seconds; delta = $delta }
        }
        $Stats.lap = @{ done = $done; seconds = 0.0; energy = 0.0; complete = ($done -eq $Stats.lap.done + 1) }
    }
    $Stats.lap.seconds += $Dt
    $Stats.lap.energy += $Power * $Dt
}

function Update-RideStats($Stats, [string]$Rider, [double]$Power, [double]$Ftp, $WbalPercent, $GameTime, $LapsDone, $LapsTotal, [double]$Slope, [double]$Speed, $AltitudeMeters, [datetime]$Now) {
    $newRide = ($GameTime -is [ValueType] -and $null -ne $Stats.gameTime -and [double]$GameTime -lt [double]$Stats.gameTime)
    if ($Stats.rider -ne $Rider -or $newRide) {
        Reset-RideStats $Stats
        $Stats.rider = $Rider
    }
    if ($GameTime -is [ValueType]) { $Stats.gameTime = [double]$GameTime }
    if ($null -ne $WbalPercent -and ($null -eq $Stats.wbalMin -or [double]$WbalPercent -lt $Stats.wbalMin)) { $Stats.wbalMin = [double]$WbalPercent }

    foreach ($item in @(@('w60', 'best60', 60), @('w300', 'best300', 300))) {
        $result = Update-PowerWindow $Stats[$item[0]] $Rider $Power $Now
        if ($result -and [double]$result.seconds -ge $item[2] - 0.5 -and ($null -eq $Stats[$item[1]] -or [double]$result.average -gt $Stats[$item[1]])) {
            $Stats[$item[1]] = [double]$result.average
        }
    }

    if ($null -ne $Stats.last) {
        $dt = ($Now - $Stats.last).TotalSeconds
        if ($dt -gt 3) {
            # Data gap: an open climb can no longer be measured.
            $Stats.climb = $null
        } elseif ($dt -gt 0) {
            if ($Ftp -gt 0 -and $Power -gt $Ftp) { $Stats.kjAbove += ($Power - $Ftp) * $dt / 1000 }
            $Stats.seconds += $dt
            if ($Power -le 0) { $Stats.coast += $dt }
            if ($Ftp -gt 0) { $Stats.zones[(Get-RideZone $Power $Ftp)] += $dt }
            Update-RideLap $Stats $dt $Power $GameTime $LapsDone $LapsTotal
            Update-RideClimb $Stats $dt $Power $Slope $Speed $AltitudeMeters
        }
    }
    $Stats.last = $Now
}

function Get-RideZone([double]$Power, [double]$Ftp) {
    # Seven power zones, as a share of FTP. Returns the zone index from 0 to 6.
    $share = $Power / $Ftp
    $limits = 0.55, 0.75, 0.90, 1.05, 1.20, 1.50
    for ($i = 0; $i -lt $limits.Count; $i++) { if ($share -lt $limits[$i]) { return $i } }
    return 6
}

function Format-RideVi($NormalizedPower, $AveragePower) {
    if ($NormalizedPower -isnot [ValueType] -or $AveragePower -isnot [ValueType] -or [double]$AveragePower -le 0 -or [double]$NormalizedPower -le 0) { return '--' }
    return ([double]$NormalizedPower / [double]$AveragePower).ToString('0.00', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-RideCoast($Stats) {
    if ($Stats.seconds -le 0) { return '--' }
    return "$(Format-RideClock $Stats.coast)  |  $([int][math]::Round(100 * $Stats.coast / $Stats.seconds)) %"
}

function Format-RideZones($Stats, [double]$Power, [double]$Ftp) {
    if ($Ftp -le 0 -or $Stats.seconds -le 0) { return '--' }
    $top = 0
    for ($i = 1; $i -lt 7; $i++) { if ($Stats.zones[$i] -gt $Stats.zones[$top]) { $top = $i } }
    return "now Z$((Get-RideZone $Power $Ftp) + 1)  |  most Z$($top + 1) $([int][math]::Round(100 * $Stats.zones[$top] / $Stats.seconds)) %"
}

function Format-RideClock([double]$Seconds) {
    $total = [int][math]::Round($Seconds)
    return '{0}:{1:00}' -f [int][math]::Floor($total / 60), ($total % 60)
}

function Format-RideIntensity($NormalizedPower, [double]$Ftp) {
    if ($NormalizedPower -isnot [ValueType] -or [double]$NormalizedPower -le 0 -or $Ftp -le 0) { return '--' }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    return 'IF ' + ([double]$NormalizedPower / $Ftp).ToString('0.00', $inv) + '  |  NP ' + [int][math]::Round([double]$NormalizedPower) + ' W'
}

function Format-RideWkg($PowerResult, $RiderKg) {
    if (-not $PowerResult -or $null -eq $RiderKg -or [double]$RiderKg -le 0) { return '--' }
    return ([double]$PowerResult.average / [double]$RiderKg).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' W/kg'
}

function Format-RideKj($Stats) { return "$([int][math]::Round($Stats.kjAbove)) kJ" }

function Format-RideWbalMin($Stats) {
    if ($null -eq $Stats.wbalMin) { return '--' }
    return "$([int][math]::Round($Stats.wbalMin)) %"
}

function Format-RideBests($Stats) {
    $one = $(if ($null -ne $Stats.best60) { "$([int][math]::Round($Stats.best60)) W" } else { '--' })
    $five = $(if ($null -ne $Stats.best300) { "$([int][math]::Round($Stats.best300)) W" } else { '--' })
    return "1 min $one  |  5 min $five"
}

function Format-RideClimb($Totals, [string]$Prefix) {
    return "$Prefix $(Format-RideClock $Totals.seconds)  |  $([int][math]::Round($Totals.power)) W  |  $([int][math]::Round($Totals.vam)) m/h  |  " + ([double]$Totals.grade).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture) + ' %'
}

function Get-RideSegment($Stats) {
    # A climb in progress comes first, then the last lap, then the last climb.
    if ($Stats.climb -and $Stats.climb.now.seconds -ge 15) {
        $live = Get-RideClimbTotals $Stats.climb $Stats.climb.now
        if ($live) { return @{ label = 'CLIMB'; text = (Format-RideClimb $live 'Now') } }
    }
    if ($Stats.lastLap) {
        $lap = $Stats.lastLap
        $text = "Lap $($lap.number): $(Format-RideClock $lap.seconds)  |  $([int][math]::Round($lap.power)) W"
        if ($null -ne $lap.delta) { $text += '  |  ' + ([double]$lap.delta).ToString('+0;-0;0', [Globalization.CultureInfo]::InvariantCulture) + ' s' }
        return @{ label = 'LAP'; text = $text }
    }
    if ($Stats.lastClimb) { return @{ label = 'CLIMB'; text = (Format-RideClimb $Stats.lastClimb 'Last') } }
    return @{ label = 'LAP / CLIMB'; text = '--' }
}
