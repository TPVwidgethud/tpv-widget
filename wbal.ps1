# W'bal using the differential model (Froncioni / Skiba):
# above CP: W' drains by (P - CP) * dt; below CP: it recovers by (CP - P) * (W' - Wbal) / W' * dt.

function Get-WPrimeProfile([string]$LogDirectory, [double]$MinConfidence = 0.5) {
    # Newest log first; the game keeps its logs open, so read them shared.
    $pattern = "Estimated CP:\s*(\d+)\s*W\s*\r?\n[^\r\n]*Estimated W':\s*(\d+)\s*J\s*\(confidence\s*([\d.,]+)\)"
    $logs = Get-ChildItem -LiteralPath $LogDirectory -Filter 'playerlog*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($log in $logs) {
        try {
            $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
            $found = [regex]::Matches($text, $pattern)
            for ($i = $found.Count - 1; $i -ge 0; $i--) {
                $confidence = [double]::Parse($found[$i].Groups[3].Value.Replace(',', '.'), [Globalization.CultureInfo]::InvariantCulture)
                if ($confidence -ge $MinConfidence) {
                    return @{ cp = [double]$found[$i].Groups[1].Value; wPrime = [double]$found[$i].Groups[2].Value; confidence = $confidence }
                }
            }
        } catch { }
    }
    return $null
}

function New-WBal([double]$WPrime) {
    return @{ wPrime = $WPrime; value = $WPrime; last = $null; gameTime = $null; effortStart = $null; belowCp = 0.0; drop = 0.0; maxDrop = 0.0; lowest = $WPrime }
}

function Reset-WBal($State) {
    $State.value = $State.wPrime
    $State.last = $null
    $State.gameTime = $null
    $State.effortStart = $null
    $State.belowCp = 0.0
    $State.drop = 0.0
    $State.maxDrop = 0.0
    $State.lowest = $State.wPrime
}

function Format-WDrop($State) {
    # Current effort, or the last one once it has ended, then the largest of the ride.
    $inv = [Globalization.CultureInfo]::InvariantCulture
    return (([double]$State.drop / 1000).ToString('0.0', $inv) + ' kJ  max ' + ([double]$State.maxDrop / 1000).ToString('0.0', $inv))
}

function Update-WBal($State, [double]$Power, [double]$Cp, [datetime]$Now) {
    if ($null -ne $State.last) {
        $dt = ($Now - $State.last).TotalSeconds
        # A long gap means the data stopped: do not invent effort or recovery.
        if ($dt -gt 0 -and $dt -le 2) {
            $before = [double]$State.value
            if ($Power -gt $Cp) {
                $State.value -= ($Power - $Cp) * $dt
            } else {
                $State.value += ($Cp - $Power) * ($State.wPrime - $State.value) / $State.wPrime * $dt
            }
            # Explicit double: with an integer 0, PowerShell picks the Int32 overload and rounds.
            $State.value = [math]::Max([double]0, [math]::Min([double]$State.wPrime, [double]$State.value))
            $State.lowest = [math]::Min([double]$State.lowest, [double]$State.value)
            # An effort starts above CP and ends after 10 s below it, so a short easing does not split it.
            if ($Power -gt $Cp) {
                if ($null -eq $State.effortStart) { $State.effortStart = $before }
                $State.belowCp = 0.0
            } elseif ($null -ne $State.effortStart) {
                $State.belowCp += $dt
                if ($State.belowCp -ge 10) { $State.effortStart = $null }
            }
            if ($null -ne $State.effortStart) {
                $State.drop = [math]::Max([double]0, [double]$State.effortStart - [double]$State.value)
                $State.maxDrop = [math]::Max([double]$State.maxDrop, [double]$State.drop)
            }
        }
    }
    $State.last = $Now
}
