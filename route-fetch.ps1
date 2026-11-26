# Fetches the route of a TPVirtual event from the public pages of tpvirtualhub.com, in the game's route file format.
# Runs in its own hidden process so that the widget never waits for the network.
# Only the event and route names are used: nothing about the rider is sent.
param([Parameter(Mandatory)][string]$RequestFile)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$request = [IO.File]::ReadAllText($RequestFile) | ConvertFrom-Json
$outDirectory = [string]$request.outDirectory
$statusFile = Join-Path $outDirectory 'fetch-status.txt'
$site = 'https://tpvirtualhub.com'

function Write-Status([string]$Text) {
    try { Add-Content -LiteralPath $statusFile -Value "$(Get-Date -Format s) $Text" -Encoding UTF8 } catch { }
}

function Get-NormalizedName([string]$Name) { return ($Name.ToLowerInvariant() -replace '[^a-z0-9]', '') }

# The game names an organizer's GPX route "Custom Route - X" where the site says "X".
function Test-SameRoute([string]$A, [string]$B) {
    $x = (Get-NormalizedName $A) -replace '^customroute', ''
    $y = (Get-NormalizedName $B) -replace '^customroute', ''
    if (-not $x -or -not $y) { return $false }
    if ($x -eq $y) { return $true }
    return ($x.Length -ge 5 -and $y.Length -ge 5 -and ($x.Contains($y) -or $y.Contains($x)))
}

# The page data is serialized as one flat array in which numbers inside objects and arrays point to other entries.
function Get-PageData([string]$Url) {
    $page = Invoke-WebRequest -Uri $Url -UseBasicParsing -UserAgent 'TPVWidget/1.0 (route profile)' -TimeoutSec 25
    $match = [regex]::Match($page.Content, '<script[^>]*id="__NUXT_DATA__"[^>]*>(.*?)</script>', 'Singleline')
    if (-not $match.Success) { return $null }
    # Assigned first: in PowerShell 5 a JSON array piped out of ConvertFrom-Json stays one object.
    $parsed = $match.Groups[1].Value | ConvertFrom-Json
    return ,$parsed
}

$wrappers = 'Reactive', 'ShallowReactive', 'Ref', 'ShallowRef', 'EmptyRef', 'EmptyShallowRef'
function Resolve-Entry($Data, [int]$Index, [int]$Depth = 0) {
    if ($Index -lt 0 -or $Index -ge $Data.Count -or $Depth -gt 40) { return $null }
    $value = $Data[$Index]
    if ($value -is [array]) {
        if ($value.Count -eq 2 -and $value[0] -is [string] -and $wrappers -contains $value[0]) { return Resolve-Entry $Data ([int]$value[1]) ($Depth + 1) }
        return ,@(foreach ($item in $value) { Resolve-Entry $Data ([int]$item) ($Depth + 1) })
    }
    if ($value -is [pscustomobject]) {
        $result = [ordered]@{}
        foreach ($property in $value.PSObject.Properties) { $result[$property.Name] = Resolve-Entry $Data ([int]$property.Value) ($Depth + 1) }
        return $result
    }
    return $value
}

# The route of an event page, in the same layout as the game's own route files.
function Get-EventRoute([string]$Id) {
    $data = Get-PageData "$site/$Id"
    if (-not $data) { return $null }
    for ($i = 0; $i -lt $data.Count; $i++) {
        $entry = $data[$i]
        if ($entry -isnot [pscustomobject]) { continue }
        $names = $entry.PSObject.Properties.Name
        if ($names -notcontains 'latMid' -or $names -notcontains 'roads') { continue }
        return Resolve-Entry $data $i
    }
    return $null
}

# Event ids: the public calendar (coming events) and results (started or finished ones), by name and closest
# start time, then those named in the readable game logs.
function Get-CandidateIds {
    $ids = New-Object System.Collections.Generic.List[string]
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $found = @()
    foreach ($listing in 'calendar', 'results') {
    try {
        $calendar = Get-PageData "$site/$listing"
        for ($i = 0; $i -lt $calendar.Count; $i++) {
            $entry = $calendar[$i]
            if ($entry -isnot [pscustomobject]) { continue }
            $names = $entry.PSObject.Properties.Name
            if ($names -notcontains 'scheduleKey' -or $names -notcontains 'name') { continue }
            # Each stage of a series can use another route: the route name decides, the event name only helps.
            $name = [string](Resolve-Entry $calendar ([int]$entry.name))
            $routeName = ''
            if ($names -contains 'route') {
                $routeInfo = Resolve-Entry $calendar ([int]$entry.route)
                if ($routeInfo -and $routeInfo['route']) { $routeName = [string]$routeInfo['route']['name'] }
            }
            $sameRoute = Test-SameRoute $routeName $request.routeName
            $sameEvent = (Get-NormalizedName $name) -eq (Get-NormalizedName $request.eventName)
            if (-not $sameRoute -and -not $sameEvent) { continue }
            # The calendar gives milliseconds, the results page an ISO date.
            $start = Resolve-Entry $calendar ([int]$entry.startTime)
            $start = $(if ($start -is [string]) { [DateTimeOffset]::Parse($start, [Globalization.CultureInfo]::InvariantCulture).ToUnixTimeMilliseconds() } else { [double]$start })
            # The same event on the same route first, then the same event, then the same route elsewhere.
            $rank = $(if ($sameRoute -and $sameEvent) { 0 } elseif ($sameEvent) { 1 } else { 2 })
            $found += [pscustomobject]@{ id = [string](Resolve-Entry $calendar ([int]$entry.scheduleKey)); rank = $rank; gap = [math]::Abs([double]$start - $now) }
        }
    } catch { Write-Status "$listing unavailable: $($_.Exception.Message)" }
    }
    foreach ($item in ($found | Sort-Object rank, gap)) { if (-not $ids.Contains($item.id)) { $ids.Add($item.id) } }
    foreach ($id in @($request.ids)) { if ($id -and -not $ids.Contains([string]$id)) { $ids.Add([string]$id) } }
    return $ids
}

try {
    New-Item -ItemType Directory -Force $outDirectory | Out-Null
    $target = Get-NormalizedName $request.routeName
    $ids = Get-CandidateIds
    Write-Status "looking for '$($request.routeName)' in events $($ids -join ', ')"
    foreach ($id in ($ids | Select-Object -First 6)) {
        try {
            $route = Get-EventRoute $id
            if (-not $route) { continue }
            if (-not (Test-SameRoute ([string]$route.name) $request.routeName)) { continue }
            $path = Join-Path $outDirectory "$target.json"
            $json = $route | ConvertTo-Json -Depth 8 -Compress
            [IO.File]::WriteAllText("$path.tmp", $json, (New-Object Text.UTF8Encoding($false)))
            Move-Item -LiteralPath "$path.tmp" -Destination $path -Force
            Write-Status "saved from event $id"
            exit 0
        } catch { Write-Status "event $id unavailable: $($_.Exception.Message)" }
    }
    Write-Status 'route not found'
    exit 1
} catch {
    Write-Status "failed: $($_.Exception.Message)"
    exit 1
}
