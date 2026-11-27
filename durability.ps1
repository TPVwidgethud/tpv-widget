# Durability: CP and W' fall as the ride's work (kJ) builds up, and W' refills less after each deep effort.
# The rate is learned from your own rides: your best 1 and 5 min powers, sorted by the work already done
# when each effort started, show how much you really lose. Only your rider is ever recorded.

$script:DurabilityDefault = 0.03      # 3 % of CP and W' per 1000 kJ after the first 1000 kJ, until learned
$script:DurabilityPrior = 3           # the default weighs as much as 3 learned rides
$script:DurabilityDurations = 60, 300   # short all-out efforts: longer ones in a race are mostly steady riding
$script:DurabilityBuckets = 4         # 0-1000, 1000-2000, 2000-3000, 3000+ kJ

function Get-FatigueFactor([double]$WorkJoules, [double]$Rate) {
    $over = [math]::Max([double]0, ($WorkJoules - 1000000) / 1000000)
    return [math]::Max([double]0.7, 1 - $Rate * $over)
}

# Each effort that took half of W' or more slows the next refills a little.
function Get-RecoveryFactor([int]$DeepEfforts) {
    return [math]::Max([double]0.7, 1 - 0.04 * $DeepEfforts)
}

function New-DurabilityRide {
    $best = @()
    $at = @()
    foreach ($d in $script:DurabilityDurations) { $best += , (New-Object double[] $script:DurabilityBuckets); $at += , (New-Object double[] $script:DurabilityBuckets) }
    return @{ id = (Get-Date).ToString('yyyyMMddHHmmss'); best = $best; at = $at; cum = (New-Object Collections.Generic.List[double]); start = (New-Object Collections.Generic.List[double]); seconds = 0.0; pushed = 0; work = 0.0; changed = $false }
}

# Called once per data update for your rider. Power is integrated into 1 s steps; the bucket of an effort
# is the ride's work when it started (from the game, so it survives a restart of the widget).
function Add-DurabilitySample($Ride, [double]$Power, [double]$Dt, [double]$RideWork) {
    if ($Dt -le 0 -or $Dt -gt 2) { return }
    $Ride.work += [math]::Max([double]0, $Power) * $Dt
    $Ride.seconds += $Dt
    # Counted apart from the buffer, which only keeps the last 5 min.
    while ($Ride.pushed -lt [math]::Floor($Ride.seconds)) {
        $Ride.pushed++
        $Ride.cum.Add($Ride.work)
        $Ride.start.Add($RideWork)
        if ($Ride.cum.Count -gt 302) { $Ride.cum.RemoveAt(0); $Ride.start.RemoveAt(0) }
        $n = $Ride.cum.Count
        for ($i = 0; $i -lt $script:DurabilityDurations.Count; $i++) {
            $d = $script:DurabilityDurations[$i]
            if ($n -le $d) { continue }
            $mean = ($Ride.cum[$n - 1] - $Ride.cum[$n - 1 - $d]) / $d
            $bucket = [int][math]::Min($script:DurabilityBuckets - 1, [math]::Floor($Ride.start[$n - 1 - $d] / 1000000))
            if ($mean -gt $Ride.best[$i][$bucket] + 0.5) { $Ride.best[$i][$bucket] = $mean; $Ride.at[$i][$bucket] = $Ride.start[$n - 1 - $d]; $Ride.changed = $true }
        }
    }
}

function Read-DurabilityProfile([string]$Path) {
    $result = @{ rides = @(); adjust = 0.0 }
    try {
        if (Test-Path -LiteralPath $Path) {
            $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
            if ($null -ne $saved.adjust) { $result.adjust = [double]$saved.adjust }
            foreach ($r in @($saved.rides)) {
                if (-not $r.id -or -not $r.best) { continue }
                $best = @()
                foreach ($row in @($r.best)) { $best += , [double[]]@($row) }
                # Work (kJ) when each best effort started.
                $at = @()
                foreach ($row in @($r.at)) { $at += , [double[]]@(foreach ($v in @($row)) { 1000 * [double]$v }) }
                if ($at.Count -ne $best.Count) { continue }
                $result.rides += , @{ id = [string]$r.id; best = $best; at = $at }
            }
        }
    } catch { }
    return $result
}

function Save-DurabilityProfile($Profile, $Ride, [string]$Path) {
    if ($Ride) {
        # Only rides with at least one full minute recorded.
        $any = $false; foreach ($row in $Ride.best) { foreach ($v in $row) { if ($v -gt 0) { $any = $true } } }
        if ($any) {
            $kept = @($Profile.rides | Where-Object { $_.id -ne $Ride.id })
            $kept += , @{ id = $Ride.id; best = $Ride.best; at = $Ride.at }
            $Profile.rides = @($kept | Select-Object -Last 40)
        }
        $Ride.changed = $false
    }
    try {
        $rides = @(foreach ($r in $Profile.rides) { [ordered]@{ id = $r.id; best = @(foreach ($row in $r.best) { , @(foreach ($v in $row) { [math]::Round([double]$v, 1) }) }); at = @(foreach ($row in $r.at) { , @(foreach ($v in $row) { [math]::Round([double]$v / 1000) }) }) } })
        $json = [ordered]@{ version = 1; adjust = [math]::Round([double]$Profile.adjust, 4); rides = $rides } | ConvertTo-Json -Depth 6
        [IO.File]::WriteAllText($Path, $json, (New-Object Text.UTF8Encoding($false)))
    } catch { }
}

# Learned rate: for each duration, the best fatigued power against the best fresh power across your rides;
# the 1 and 5 min results are averaged.
function Get-DurabilityEstimate($Profile, $Ride = $null) {
    $all = @($Profile.rides)
    if ($Ride) { $all = @($all | Where-Object { $_.id -ne $Ride.id }) + , @{ id = $Ride.id; best = $Ride.best; at = $Ride.at } }
    $learned = $null
    $perDuration = @()
    $rideCount = 0
    foreach ($r in $all) {
        $late = $false
        for ($i = 0; $i -lt $script:DurabilityDurations.Count; $i++) { for ($k = 1; $k -lt $script:DurabilityBuckets; $k++) { if ($r.best[$i][$k] -gt 0) { $late = $true } } }
        if ($late) { $rideCount++ }
    }
    for ($i = 0; $i -lt $script:DurabilityDurations.Count; $i++) {
        $top = New-Object double[] $script:DurabilityBuckets
        $topAt = New-Object double[] $script:DurabilityBuckets
        foreach ($r in $all) { for ($k = 0; $k -lt $script:DurabilityBuckets; $k++) { if ([double]$r.best[$i][$k] -gt $top[$k]) { $top[$k] = [double]$r.best[$i][$k]; $topAt[$k] = [double]$r.at[$i][$k] } } }
        if ($top[0] -le 0) { continue }
        $rates = @()
        for ($k = 1; $k -lt $script:DurabilityBuckets; $k++) {
            # The exact work when that effort started; too close to the first 1000 kJ says too little.
            $over = ($topAt[$k] - 1000000) / 1000000
            if ($top[$k] -gt 0 -and $over -ge 0.25) { $rates += [math]::Max([double]0, (1 - $top[$k] / $top[0]) / $over) }
        }
        if ($rates.Count) {
            $rate = ($rates | Measure-Object -Average).Average
            $perDuration += $rate
        }
    }
    if ($perDuration.Count) { $learned = ($perDuration | Measure-Object -Average).Average } else { $rideCount = 0; $learned = $script:DurabilityDefault }
    $learned = [math]::Min([double]0.10, $learned)
    $rate = ($script:DurabilityDefault * $script:DurabilityPrior + $learned * $rideCount) / ($script:DurabilityPrior + $rideCount) + [double]$Profile.adjust
    return @{ rate = [math]::Max([double]0, [math]::Min([double]0.10, $rate)); rides = $rideCount; learned = $learned }
}

# W'bal went well below zero while you kept going: the fatigue made the model too pessimistic.
function Add-DurabilityCorrection($Profile) {
    $Profile.adjust = [math]::Max([double]-0.05, [double]$Profile.adjust - 0.003)
}
