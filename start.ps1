# Starts TPV Widget from this folder. Nothing is installed: settings and learned data stay in this folder.
# Before starting, looks for a newer version published on GitHub (TPVwidgethud/tpv-widget) and offers to install it.
# To never be asked, create an empty file named no-update.txt in this folder.
$ErrorActionPreference = 'Stop'
$folder = $PSScriptRoot
$overlay = Join-Path $folder 'overlay.ps1'
$repository = 'TPVwidgethud/tpv-widget'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not (Test-Path -LiteralPath $overlay)) {
    [void][Windows.Forms.MessageBox]::Show("overlay.ps1 was not found in:`n$folder`n`nUnzip the whole TPVWidget folder before starting it.", 'TPV Widget', 'OK', 'Error')
    exit 1
}
# Files unzipped from a download are marked as coming from the internet; this folder is trusted from now on.
Get-ChildItem -LiteralPath $folder -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

# Asks before installing: a window of its own, on top and active, that shows what is new and returns $true only on "Install".
function Request-UpdateConsent([string]$Intro, [string]$News) {
    $form = New-Object Windows.Forms.Form
    $form.Text = 'TPV Widget update'
    $form.FormBorderStyle = 'FixedDialog'; $form.MaximizeBox = $false; $form.MinimizeBox = $false
    $form.StartPosition = 'CenterScreen'; $form.TopMost = $true; $form.ShowInTaskbar = $true
    $form.Font = New-Object Drawing.Font('Segoe UI', 10)
    $form.AutoSize = $true; $form.AutoSizeMode = 'GrowAndShrink'; $form.Padding = New-Object Windows.Forms.Padding(16)
    $layout = New-Object Windows.Forms.FlowLayoutPanel
    $layout.FlowDirection = 'TopDown'; $layout.AutoSize = $true; $layout.WrapContents = $false
    $layout.Location = New-Object Drawing.Point(18, 16)
    $label = New-Object Windows.Forms.Label
    $label.Text = $Intro; $label.AutoSize = $true; $label.MaximumSize = New-Object Drawing.Size(540, 0); $label.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 8)
    $label.Font = New-Object Drawing.Font('Segoe UI', 11, [Drawing.FontStyle]::Bold)
    $layout.Controls.Add($label)
    if ($News) {
        $title = New-Object Windows.Forms.Label
        $title.Text = "What's new"; $title.AutoSize = $true; $title.Margin = New-Object Windows.Forms.Padding(0, 4, 0, 4)
        $title.Font = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
        $box = New-Object Windows.Forms.TextBox
        $box.Multiline = $true; $box.ReadOnly = $true; $box.ScrollBars = 'Vertical'; $box.TabStop = $false
        $box.BackColor = [Drawing.SystemColors]::Window; $box.Size = New-Object Drawing.Size(540, 260)
        $box.Text = $News; $box.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
        $layout.Controls.AddRange(@($title, $box))
    }
    $question = New-Object Windows.Forms.Label
    $question.Text = "Install it now? Your settings are kept.`nNot now = start the version you have."
    $question.AutoSize = $true; $question.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 12)
    $buttons = New-Object Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'; $buttons.AutoSize = $true; $buttons.Anchor = 'Right'
    $install = New-Object Windows.Forms.Button
    $install.Text = 'Install'; $install.Name = 'InstallButton'; $install.AutoSize = $true; $install.DialogResult = 'Yes'
    $later = New-Object Windows.Forms.Button
    $later.Text = 'Not now'; $later.Name = 'LaterButton'; $later.AutoSize = $true; $later.DialogResult = 'No'
    $buttons.Controls.AddRange(@($later, $install))
    $layout.Controls.AddRange(@($question, $buttons))
    $form.Controls.Add($layout)
    $form.AcceptButton = $install; $form.CancelButton = $later
    $form.Add_Shown({ $form.Activate(); $form.BringToFront(); [void]$install.Focus() })
    try { return ($form.ShowDialog() -eq 'Yes') } finally { $form.Dispose() }
}

# Release notes as plain text: from the first "### ..." section (what is new), without install steps or Markdown marks.
function Format-ReleaseNotes([string]$Body) {
    $lines = ([string]$Body) -split "`r?`n"
    $first = 0
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^###\s') { $first = $i; break } }
    $out = New-Object Collections.Generic.List[string]
    for ($i = $first; $i -lt $lines.Count; $i++) {
        $line = $lines[$i].TrimEnd()
        # The install steps come after what is new.
        if ($line -match '^(\*\*)?(First installation|From \d|Already have|Notice in)') { break }
        if ($line -match '^#{1,2}\s') { continue }
        $line = $line -replace '^###\s*', '' -replace '\*\*', '' -replace '`', ''
        $line = $line -replace '^\s*[-*]\s+', ('  ' + [char]0x2022 + '  ')
        if ($line -eq '' -and ($out.Count -eq 0 -or $out[$out.Count - 1] -eq '')) { continue }
        $out.Add($line)
    }
    return (($out -join "`r`n").Trim())
}

# What is new in every published version after the one you have, newest first.
function Get-UpdateNews($Headers, [version]$Current, $Latest) {
    # PowerShell 5 returns the JSON list as one object: ForEach-Object spreads it.
    try { $all = @(Invoke-RestMethod -Uri "https://api.github.com/repos/$repository/releases?per_page=30" -Headers $Headers -TimeoutSec 6 | ForEach-Object { $_ }) } catch { $all = @($Latest) }
    $parts = @()
    foreach ($r in $all) {
        if ($r.draft -or $r.prerelease) { continue }
        try { $v = [version](([string]$r.tag_name).TrimStart('v', 'V')) } catch { continue }
        if ($v -le $Current) { continue }
        $text = Format-ReleaseNotes $r.body
        if ($text) { $parts += , [pscustomobject]@{ version = $v; text = $text } }
    }
    return (@($parts | Sort-Object version -Descending | ForEach-Object { $_.text }) -join "`r`n`r`n")
}
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
    # Offered, never forced: nothing is downloaded without a yes.
    $news = Get-UpdateNews $headers $current $release
    if (-not (Request-UpdateConsent "TPV Widget $latest is available (you have $current)." $news)) { Write-UpdateLog "version $latest offered, not installed"; return }
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
