# Starts TPV Widget from this folder. Nothing is installed: settings and learned data stay in this folder.
# Before starting, looks for a newer version published on GitHub (TPVwidgethud/tpv-widget) and installs it.
# To turn the update check off, create an empty file named no-update.txt in this folder.
$ErrorActionPreference = 'Stop'
$folder = $PSScriptRoot
$overlay = Join-Path $folder 'overlay.ps1'
$repository = 'TPVwidgethud/tpv-widget'
Add-Type -AssemblyName System.Windows.Forms

if (-not (Test-Path -LiteralPath $overlay)) {
    [void][Windows.Forms.MessageBox]::Show("overlay.ps1 was not found in:`n$folder`n`nUnzip the whole TPVWidget folder before starting it.", 'TPV Widget', 'OK', 'Error')
    exit 1
}
# Files unzipped from a download are marked as coming from the internet; this folder is trusted from now on.
Get-ChildItem -LiteralPath $folder -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

function Write-UpdateLog([string]$Text) {
    try { Add-Content -LiteralPath (Join-Path $folder 'update.log') -Value "$(Get-Date -Format s) $Text" -Encoding UTF8 } catch { }
}

function Get-LocalVersion {
    try { return [version]([IO.File]::ReadAllText((Join-Path $folder 'VERSION')).Trim()) } catch { return [version]'0.0' }
}

# Only ever from this repository's releases, over HTTPS, and only a zip whose SHA-256 matches the one published with it.
function Update-Widget {
    if (Test-Path -LiteralPath (Join-Path $folder 'no-update.txt')) { return }
    # A widget already running keeps its files: the update waits for the next start.
    $running = $false
    try { $mutex = [System.Threading.Mutex]::OpenExisting('Local\TpvOverlayWidget'); $mutex.Dispose(); $running = $true } catch { }
    if ($running) { return }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    $headers = @{ 'User-Agent' = 'TPVWidget-updater'; 'Accept' = 'application/vnd.github+json' }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases/latest" -Headers $headers -TimeoutSec 6
    $latest = [version](([string]$release.tag_name).TrimStart('v', 'V'))
    $current = Get-LocalVersion
    if ($latest -le $current) { return }
    $prefix = "https://github.com/$repository/releases/download/"
    $zipAsset = @($release.assets | Where-Object { $_.name -like 'TPVWidget-*.zip' })[0]
    $hashAsset = @($release.assets | Where-Object { $_.name -like 'TPVWidget-*.zip.sha256' })[0]
    if (-not $zipAsset -or -not $hashAsset) { Write-UpdateLog "version $latest has no zip or no checksum: not installed"; return }
    foreach ($asset in $zipAsset, $hashAsset) { if (-not ([string]$asset.browser_download_url).StartsWith($prefix)) { Write-UpdateLog 'unexpected download address: not installed'; return } }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('TPVWidget-update-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $zip = Join-Path $work 'update.zip'
        Invoke-WebRequest -Uri $zipAsset.browser_download_url -OutFile $zip -UseBasicParsing -Headers $headers -TimeoutSec 60
        $hashFile = Join-Path $work 'update.zip.sha256'
        Invoke-WebRequest -Uri $hashAsset.browser_download_url -OutFile $hashFile -UseBasicParsing -Headers $headers -TimeoutSec 20
        $expected = ([IO.File]::ReadAllText($hashFile).Trim() -split '\s+')[0].ToLowerInvariant()
        $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($expected -ne $actual) { Write-UpdateLog "version $latest checksum mismatch: not installed"; return }
        Expand-Archive -LiteralPath $zip -DestinationPath $work
        $source = Join-Path $work 'TPVWidget'
        foreach ($needed in 'overlay.ps1', 'start.ps1', 'VERSION') { if (-not (Test-Path -LiteralPath (Join-Path $source $needed))) { Write-UpdateLog "version $latest is incomplete: not installed"; return } }
        # Program files only: settings, learned corners and routes are never in the package and stay as they are.
        Get-ChildItem -LiteralPath $source -File | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $folder $_.Name) -Force }
        Get-ChildItem -LiteralPath $folder -File | Unblock-File -ErrorAction SilentlyContinue
        Write-UpdateLog "updated from $current to $latest"
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Any problem (no internet, GitHub unreachable, ...): the widget simply starts with the version it has.
try { Update-Widget } catch { Write-UpdateLog "update check skipped: $($_.Exception.Message)" }

$log = Join-Path $folder 'overlay.log'
$before = $(if (Test-Path -LiteralPath $log) { (Get-Item -LiteralPath $log).LastWriteTimeUtc } else { [datetime]::MinValue })
$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$widget = Start-Process $powershell -ArgumentList '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-ExecutionPolicy', 'Bypass', '-File', "`"$overlay`"" -WorkingDirectory $folder -PassThru
# A widget that stops within a few seconds failed to start (one already running just exits quietly).
Start-Sleep -Seconds 8
if ($widget.HasExited -and (Test-Path -LiteralPath $log) -and (Get-Item -LiteralPath $log).LastWriteTimeUtc -gt $before) {
    $text = Get-Content -LiteralPath $log -Raw
    $at = $text.IndexOf('error ')
    if ($at -ge 0) {
        [void][Windows.Forms.MessageBox]::Show("The widget stopped while starting.`n`n" + $text.Substring($at, [math]::Min(600, $text.Length - $at)), 'TPV Widget', 'OK', 'Error')
        exit 1
    }
}
