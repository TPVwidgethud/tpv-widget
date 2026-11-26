# Braking score: share of braking time spent at or below the power limit.

function Get-ConfiguredFtp([string]$LogDirectory) {
    # Newest log first; the game keeps its logs open, so read them shared.
    $logs = Get-ChildItem -LiteralPath $LogDirectory -Filter 'playerlog*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($log in $logs) {
        try {
            $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
            $found = [regex]::Matches($text, 'Configured FTP:\s*(\d+)')
            if ($found.Count -gt 0) {
                $ftp = [double]$found[$found.Count - 1].Groups[1].Value
                if ($ftp -gt 0) { return $ftp }
            }
        } catch { }
    }
    return $null
}

# The account logged into the game, as written in its log.
function Get-OwnRiderName([string]$LogDirectory) {
    $logs = Get-ChildItem -LiteralPath $LogDirectory -Filter 'playerlog*.txt' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
    foreach ($log in $logs) {
        try {
            $stream = [IO.File]::Open($log.FullName, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object IO.StreamReader($stream)).ReadToEnd() } finally { $stream.Dispose() }
            $found = [regex]::Matches($text, '-- Name:\s*([^\r\n]+)')
            if ($found.Count -gt 0) {
                $name = $found[$found.Count - 1].Groups[1].Value.Trim()
                if ($name) { return $name }
            }
        } catch { }
    }
    return $null
}

function Get-EstimatedFtp([double]$Tss, [double]$NormalizedPower, [double]$Seconds) {
    # From TSS = 100 * t * NP^2 / (3600 * FTP^2). TSS is exported as an integer,
    # so require enough of it for the rounding error to stay small.
    if ($Tss -lt 10 -or $Seconds -lt 600 -or $NormalizedPower -le 0) { return $null }
    $ftp = $NormalizedPower * [math]::Sqrt(100 * $Seconds / (3600 * $Tss))
    if ($ftp -lt 80 -or $ftp -gt 700) { return $null }
    return $ftp
}

function New-BrakeScore {
    return @{ rider = $null; braking = 0.0; tooHard = 0.0; last = $null }
}

function Reset-BrakeScore($Score) {
    $Score.braking = 0.0
    $Score.tooHard = 0.0
    $Score.last = $null
}

function Update-BrakeScore($Score, [string]$Rider, [double]$Brake, [double]$Power, [datetime]$Now, [double]$PowerLimit) {
    if ($Score.rider -ne $Rider) {
        Reset-BrakeScore $Score
        $Score.rider = $Rider
    }
    if ($null -ne $Score.last) {
        $dt = ($Now - $Score.last).TotalSeconds
        # A long gap means the data stopped: do not count it as braking time.
        if ($dt -gt 0 -and $dt -le 1 -and $Brake -gt 0) {
            $Score.braking += $dt
            if ($Power -gt $PowerLimit) { $Score.tooHard += $dt }
        }
    }
    $Score.last = $Now
}

function Get-BrakeScorePercent($Score) {
    if ($Score.braking -le 0) { return $null }
    return [int][math]::Round(100 * (1 - $Score.tooHard / $Score.braking))
}

function Format-BrakeTime([double]$Seconds) {
    $total = [int][math]::Round($Seconds)
    return '{0}:{1:00}' -f [math]::Floor($total / 60), ($total % 60)
}
