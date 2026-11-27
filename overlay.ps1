# Always-on-top, click-through overlay for TrainingPeaks Virtual.
# Ctrl+Alt+F1 / F2 / F3: previous track / play-pause / next track | Ctrl+Alt+F7: reset braking score | Ctrl+Alt+F8: edit layout | Ctrl+Alt+F9: show/hide | Ctrl+Alt+F10: quit
param(
    [string]$FocusFile = "$([Environment]::GetFolderPath('MyDocuments'))\TPVirtual\Broadcast\focus.json",
    # Power above this share of FTP while the game brakes counts as pedaling too hard.
    [double]$FtpPercent = 33,
    # Leave at 0 to read the FTP configured in TPVirtual.
    [double]$FtpWatts = 0,
    # CP and W' are only known for this rider, so W'bal is only computed for them.
    # Empty: the account logged into TPVirtual, read from its log.
    [string]$MyRiderName = '',
    # Leave empty to follow the route named in the TPVirtual log.
    [string]$RouteOverride = ''
)

$ErrorActionPreference = 'Stop'
$logPath = Join-Path $PSScriptRoot 'overlay.log'
$posPath = Join-Path $PSScriptRoot 'overlay-position.json'
$settingsPath = Join-Path $PSScriptRoot 'overlay-settings.json'

$mutex = New-Object System.Threading.Mutex($false, 'Local\TpvOverlayWidget')
if (-not $mutex.WaitOne(0)) { exit 0 }

try {
    # The game always comes first when both need the CPU.
    [Diagnostics.Process]::GetCurrentProcess().PriorityClass = [Diagnostics.ProcessPriorityClass]::BelowNormal
    . (Join-Path $PSScriptRoot 'brake-score.ps1')
    . (Join-Path $PSScriptRoot 'wbal.ps1')
    . (Join-Path $PSScriptRoot 'race-data.ps1')
    . (Join-Path $PSScriptRoot 'tactics.ps1')
    . (Join-Path $PSScriptRoot 'ride-stats.ps1')
    . (Join-Path $PSScriptRoot 'corner-coach.ps1')
    $coachPath = Join-Path $PSScriptRoot 'coach-library.json'
    $coachEpoch = Get-Date
    $logDirectory = "$([Environment]::GetFolderPath('MyDocuments'))\TPVirtual\LogFiles"
    $gameRouteDirectory = "$env:USERPROFILE\AppData\LocalLow\indieVelo Ltd\TPVirtual\cdn\route"
    $learnedRouteDirectory = Join-Path $PSScriptRoot 'routes'
    # Event routes fetched from tpvirtualhub.com when the event opens. Nothing is kept: the temporary
    # folder is emptied at start and whenever the route changes.
    $eventRouteDirectory = Join-Path ([IO.Path]::GetTempPath()) 'TPVWidget-event-route'
    try { if (Test-Path -LiteralPath $eventRouteDirectory) { Remove-Item -LiteralPath $eventRouteDirectory -Recurse -Force -Confirm:$false -ErrorAction Stop } } catch { }
    $wProfile = Get-WPrimeProfile "$([Environment]::GetFolderPath('MyDocuments'))\TPVirtual\LogFiles"
    if ($FtpWatts -le 0) {
        $FtpWatts = Get-ConfiguredFtp "$([Environment]::GetFolderPath('MyDocuments'))\TPVirtual\LogFiles"
        if (-not $FtpWatts) { $FtpWatts = 250 }
    }
    if (-not $MyRiderName) {
        $found = Get-OwnRiderName $logDirectory
        if ($found) { $MyRiderName = $found }
    }
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TpvNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] public static extern IntPtr GetWindowLongPtr(IntPtr h, int i);
    [DllImport("user32.dll", EntryPoint="SetWindowLongPtrW")] public static extern IntPtr SetWindowLongPtr(IntPtr h, int i, IntPtr v);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int key);
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
}
'@

    [xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Widget TPVirtual" Width="440" Height="640"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        FontFamily="Segoe UI" Foreground="#FFFFFF">
  <Window.Resources>
    <Style x:Key="Tile" TargetType="Border">
      <Setter Property="Background" Value="#A60A1440"/>
      <Setter Property="CornerRadius" Value="7"/>
      <Setter Property="Padding" Value="9,5,9,7"/>
      <Setter Property="Margin" Value="3,0"/>
    </Style>
    <Style x:Key="TileLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="#9DBBFF"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>
    <Style x:Key="TileValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="GapValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="20"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="BarValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="18"/>
      <Setter Property="FontWeight" Value="Bold"/>
    </Style>
    <Style x:Key="RowValue" TargetType="TextBlock">
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
      <Setter Property="TextAlignment" Value="Right"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <Style x:Key="Track" TargetType="Border">
      <Setter Property="Height" Value="12"/>
      <Setter Property="CornerRadius" Value="6"/>
      <Setter Property="Background" Value="#3D4A6E"/>
      <Setter Property="ClipToBounds" Value="True"/>
    </Style>
    <LinearGradientBrush x:Key="BarBrush" StartPoint="0,0" EndPoint="1,0">
      <GradientStop Color="#EF8A52" Offset="0"/>
      <GradientStop Color="#E7C03F" Offset="0.42"/>
      <GradientStop Color="#DEE034" Offset="0.67"/>
      <GradientStop Color="#68DF31" Offset="1"/>
    </LinearGradientBrush>
  </Window.Resources>
  <Border x:Name="Panel" CornerRadius="10" BorderThickness="1.5" BorderBrush="#804F76F5">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#E0122A78" Offset="0"/>
        <GradientStop Color="#E00B1A52" Offset="0.55"/>
        <GradientStop Color="#E03A2358" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="30"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <Border Background="#D91C3490" CornerRadius="8.5,8.5,0,0" Height="30" Padding="12,0">
        <TextBlock x:Name="RiderText" Text="Waiting for rider" FontSize="13" FontWeight="Bold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </Border>
      <Grid x:Name="BlockHost" Grid.Row="1" Margin="7,5,7,5">
        <Border x:Name="WbalSection" Style="{StaticResource Tile}" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel x:Name="WbalHeader" Margin="0,0,0,4">
              <TextBlock x:Name="WbalText" DockPanel.Dock="Right" Text="--" Style="{StaticResource BarValue}"/>
              <TextBlock Text="W'BAL" Style="{StaticResource TileLabel}"/>
              <TextBlock x:Name="WbalHint" Text="" FontSize="14" Foreground="#FFB27A" FontWeight="Bold" Margin="10,0,0,0" VerticalAlignment="Center"/>
            </DockPanel>
            <Border x:Name="WbalBar" Style="{StaticResource Track}">
              <Border x:Name="WbalFill" Background="#68DF31" CornerRadius="6" RenderTransformOrigin="0,0.5">
                <Border.RenderTransform><ScaleTransform ScaleX="0"/></Border.RenderTransform>
              </Border>
            </Border>
          </StackPanel>
        </Border>
          <Border x:Name="Power30Tile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="POWER 30S" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="Power30Text" Text="--" Style="{StaticResource TileValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="VamTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="VAM 30S" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="VamText" Text="--" Style="{StaticResource TileValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="IntensityTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="INTENSITY" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="IntensityText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="WkgTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="W/KG 30S" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="WkgText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="KjTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="WORK ABOVE FTP" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="KjText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="WbalMinTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="W'BAL MIN" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="WbalMinText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="WdropTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="W'BAL DROP" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="WdropText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="ViTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="VARIABILITY (VI)" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="ViText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="CoastTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="COASTING" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="CoastText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
        <Border x:Name="ZonesSection" Style="{StaticResource Tile}" Margin="0,0,0,6">
          <StackPanel>
            <DockPanel Margin="0,0,0,4">
              <TextBlock x:Name="ZonesText" DockPanel.Dock="Right" Text="--" FontSize="16" FontWeight="Bold"/>
              <TextBlock Text="TIME IN ZONES" Style="{StaticResource TileLabel}"/>
            </DockPanel>
            <Border Style="{StaticResource Track}">
              <Grid><Grid.ColumnDefinitions><ColumnDefinition x:Name="Zone1" Width="0*"/><ColumnDefinition x:Name="Zone2" Width="0*"/><ColumnDefinition x:Name="Zone3" Width="0*"/><ColumnDefinition x:Name="Zone4" Width="0*"/><ColumnDefinition x:Name="Zone5" Width="0*"/><ColumnDefinition x:Name="Zone6" Width="0*"/><ColumnDefinition x:Name="Zone7" Width="0*"/></Grid.ColumnDefinitions><Border Grid.Column="0" Background="#6B6F78"/><Border Grid.Column="1" Background="#2F6FD6"/><Border Grid.Column="2" Background="#3DA62E"/><Border Grid.Column="3" Background="#C8A400"/><Border Grid.Column="4" Background="#D0620F"/><Border Grid.Column="5" Background="#A81D16"/><Border Grid.Column="6" Background="#7B3FA0"/></Grid>
            </Border>
          </StackPanel>
        </Border>
          <Border x:Name="DraftTile" Style="{StaticResource Tile}">
            <StackPanel>
              <DockPanel Margin="0,0,0,4">
                <TextBlock x:Name="DraftText" DockPanel.Dock="Right" Text="--" Style="{StaticResource BarValue}"/>
                <TextBlock Text="DRAFT" Style="{StaticResource TileLabel}"/>
              </DockPanel>
              <Border Style="{StaticResource Track}">
                <Border x:Name="DraftFill" Background="{StaticResource BarBrush}" CornerRadius="6" RenderTransformOrigin="0,0.5">
                  <Border.RenderTransform><ScaleTransform ScaleX="0"/></Border.RenderTransform>
                </Border>
              </Border>
            </StackPanel>
          </Border>
          <Border x:Name="BrakeTile" Style="{StaticResource Tile}">
            <StackPanel>
              <DockPanel Margin="0,0,0,4">
                <TextBlock x:Name="BrakeText" DockPanel.Dock="Right" Text="--" Style="{StaticResource BarValue}"/>
                <TextBlock Text="BRAKE" Style="{StaticResource TileLabel}"/>
              </DockPanel>
              <Border Style="{StaticResource Track}">
                <Border x:Name="BrakeFill" Background="{StaticResource BarBrush}" CornerRadius="6" RenderTransformOrigin="0,0.5">
                  <Border.RenderTransform><ScaleTransform ScaleX="0"/></Border.RenderTransform>
                </Border>
              </Border>
            </StackPanel>
          </Border>
          <Border x:Name="AheadTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="AHEAD" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="AheadText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
          <Border x:Name="BehindTile" Style="{StaticResource Tile}">
            <StackPanel>
              <TextBlock Text="BEHIND" Style="{StaticResource TileLabel}"/>
              <Viewbox StretchDirection="DownOnly" HorizontalAlignment="Left"><TextBlock x:Name="BehindText" Text="--" Style="{StaticResource GapValue}"/></Viewbox>
            </StackPanel>
          </Border>
            <Border x:Name="SegmentBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid x:Name="SegmentRow" Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="SegmentLabel" Text="LAP / CLIMB" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="SegmentText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="BestsBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid x:Name="BestsRow" Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="BEST EFFORTS" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="BestsText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="ClimbBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid x:Name="ClimbRow" Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="NEXT CLIMB" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="ClimbText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="KeyBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid x:Name="KeyRow" Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock x:Name="KeyLabel" Text="FINISH" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="KeyText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="CoachBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid x:Name="CoachRow" Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="CORNER" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="CoachText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="MissedBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid x:Name="MissedRow" Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="MISSED" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="MissedText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="AttackBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="ATTACK" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="AttackText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="GroupsBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid>
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="28"/></Grid.RowDefinitions>
              <TextBlock Text="GROUP AHEAD" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="GroupAheadText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
              <TextBlock Grid.Row="1" Text="GROUP BEHIND" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Row="1" Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="GroupBehindText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="PullBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="AT THE FRONT" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="PullText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="TeamBlock" Style="{StaticResource Tile}" Padding="9,3"><Grid Height="28">
              <Grid.ColumnDefinitions><ColumnDefinition Width="96"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
              <TextBlock Text="TEAM" Style="{StaticResource TileLabel}"/>
              <Viewbox Grid.Column="1" StretchDirection="DownOnly" HorizontalAlignment="Right"><TextBlock x:Name="TeamText" Text="--" Style="{StaticResource RowValue}"/></Viewbox>
            </Grid></Border>
            <Border x:Name="MusicBlock" Style="{StaticResource Tile}" Padding="9,3">
              <Border.Resources>
                <Style x:Key="MusicButton" TargetType="Button">
                  <Setter Property="Foreground" Value="#FFFFFF"/>
                  <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
                  <Setter Property="FontSize" Value="13"/>
                  <Setter Property="Width" Value="32"/>
                  <Setter Property="Height" Value="24"/>
                  <Setter Property="Margin" Value="4,0,0,0"/>
                  <Setter Property="Focusable" Value="False"/>
                  <Setter Property="Template">
                    <Setter.Value>
                      <ControlTemplate TargetType="Button">
                        <Border x:Name="Face" Background="#334F76F5" BorderBrush="#664F76F5" BorderThickness="1" CornerRadius="5">
                          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Face" Property="Background" Value="#884F76F5"/></Trigger>
                          <Trigger Property="IsPressed" Value="True"><Setter TargetName="Face" Property="Background" Value="#CC4F76F5"/></Trigger>
                        </ControlTemplate.Triggers>
                      </ControlTemplate>
                    </Setter.Value>
                  </Setter>
                </Style>
              </Border.Resources>
              <Grid x:Name="MusicRow" Height="28">
                <Grid.ColumnDefinitions><ColumnDefinition Width="58"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Text="MUSIC" Style="{StaticResource TileLabel}"/>
                <TextBlock x:Name="MusicText" Grid.Column="1" Text="--" Style="{StaticResource RowValue}" FontSize="14" TextAlignment="Left" Margin="0,0,4,0"/>
                <StackPanel x:Name="MusicButtons" Grid.Column="2" Orientation="Horizontal" VerticalAlignment="Center">
                  <Button x:Name="MusicPrev" AutomationProperties.Name="Previous track" ToolTip="Previous (Ctrl+Alt+F1)" Content="&#xE892;" Style="{StaticResource MusicButton}"/>
                  <Button x:Name="MusicPlay" AutomationProperties.Name="Play or pause" ToolTip="Play / pause (Ctrl+Alt+F2)" Content="&#xE768;" Style="{StaticResource MusicButton}"/>
                  <Button x:Name="MusicNext" AutomationProperties.Name="Next track" ToolTip="Next (Ctrl+Alt+F3)" Content="&#xE893;" Style="{StaticResource MusicButton}"/>
                </StackPanel>
              </Grid>
            </Border>
        <Border x:Name="ScoreSection" Style="{StaticResource Tile}" Margin="0">
          <StackPanel>
            <DockPanel>
              <TextBlock x:Name="ScoreText" DockPanel.Dock="Right" Text="--" Style="{StaticResource BarValue}"/>
              <TextBlock Text="BRAKING SCORE" Style="{StaticResource TileLabel}"/>
            </DockPanel>
            <TextBlock x:Name="ScoreDetail" Text="No braking" FontSize="13" Foreground="#C5D3F5" TextTrimming="CharacterEllipsis"/>
          </StackPanel>
        </Border>
        <Border x:Name="WbalGaugeBlock" Tag="fill" Style="{StaticResource Tile}"><Border x:Name="WbalGaugeHost"/></Border>
        <Border x:Name="PowerDialBlock" Tag="fill" Style="{StaticResource Tile}"><Border x:Name="PowerDialHost"/></Border>
        <Border x:Name="DraftDialBlock" Tag="fill" Style="{StaticResource Tile}"><Border x:Name="DraftDialHost"/></Border>
        <Border x:Name="WindDialBlock" Tag="fill" Style="{StaticResource Tile}"><Border x:Name="WindDialHost"/></Border>
        <Border x:Name="WbalChartBlock" Tag="fill" Style="{StaticResource Tile}">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,4">
              <TextBlock x:Name="WbalChartText" DockPanel.Dock="Right" Text="--" Style="{StaticResource BarValue}"/>
              <TextBlock Text="W'BAL  RACE" TextTrimming="CharacterEllipsis" Style="{StaticResource TileLabel}"/>
            </DockPanel>
            <Border x:Name="WbalChartHost" Grid.Row="1" MinHeight="92"/>
          </Grid>
        </Border>
        <Border x:Name="PowerChartBlock" Tag="fill" Style="{StaticResource Tile}">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,4">
              <TextBlock x:Name="PowerChartText" DockPanel.Dock="Right" Text="--" Style="{StaticResource BarValue}"/>
              <TextBlock Text="POWER  5 MIN" TextTrimming="CharacterEllipsis" Style="{StaticResource TileLabel}"/>
            </DockPanel>
            <Border x:Name="PowerChartHost" Grid.Row="1" MinHeight="92"/>
          </Grid>
        </Border>
        <Border x:Name="RouteChartBlock" Tag="fill" Style="{StaticResource Tile}">
          <Grid>
            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <DockPanel Margin="0,0,0,4">
              <TextBlock x:Name="RouteChartText" DockPanel.Dock="Right" Text="--" Style="{StaticResource BarValue}"/>
              <TextBlock x:Name="RouteChartTitle" Text="ROUTE  5000 M" TextTrimming="CharacterEllipsis" Style="{StaticResource TileLabel}"/>
            </DockPanel>
            <Border x:Name="RouteChartHost" Grid.Row="1" MinHeight="92"/>
          </Grid>
        </Border>
      </Grid>
    </Grid>
  </Border>
</Window>
'@

    # A message loop instead of ShowDialog: hiding a modal window would end it,
    # and a modal window would disable the menu button.
    $app = New-Object Windows.Application
    $app.ShutdownMode = 'OnExplicitShutdown'
    $window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $ui = @{}
    foreach ($n in 'Panel','WbalChartBlock','PowerChartBlock','RouteChartBlock','WbalChartText','PowerChartText','RouteChartText','RouteChartTitle','WbalChartHost','PowerChartHost','RouteChartHost','BlockHost','SegmentBlock','BestsBlock','ClimbBlock','KeyBlock','CoachBlock','MissedBlock','RiderText','BrakeText','BrakeFill','DraftText','DraftFill','ScoreText','ScoreDetail','WbalText','WbalHint','WbalFill','AheadText','BehindText','ClimbText','KeyLabel','KeyText','WbalSection','ScoreSection','IntensityTile','WkgTile','KjTile','WbalMinTile','IntensityText','WkgText','KjText','WbalMinText','WdropTile','WdropText','WbalGaugeBlock','WbalGaugeHost','PowerDialBlock','PowerDialHost','DraftDialBlock','DraftDialHost','WindDialBlock','WindDialHost','SegmentRow','SegmentLabel','SegmentText','BestsRow','BestsText','ViTile','CoastTile','ViText','CoastText','ZonesSection','ZonesText','Zone1','Zone2','Zone3','Zone4','Zone5','Zone6','Zone7','Power30Tile','VamTile','DraftTile','BrakeTile','AheadTile','BehindTile','Power30Text','VamText','ClimbRow','KeyRow','CoachRow','MissedRow','CoachText','MissedText','AttackBlock','AttackText','GroupsBlock','GroupAheadText','GroupBehindText','PullBlock','PullText','TeamBlock','TeamText','MusicBlock','MusicText','MusicButtons','MusicPrev','MusicPlay','MusicNext') { $ui[$n] = $window.FindName($n) }
    $brakeScale = $ui.BrakeFill.RenderTransform
    $draftScale = $ui.DraftFill.RenderTransform
    $wbalScale = $ui.WbalFill.RenderTransform

    # Compiled so that per-frame work never runs through the PowerShell interpreter.
    Add-Type -ReferencedAssemblies ([Windows.Media.ScaleTransform].Assembly.Location), ([Windows.Threading.Dispatcher].Assembly.Location), 'System.Xaml' @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Windows.Media;
using System.Windows.Threading;
public sealed class TpvGauge {
    static readonly List<TpvGauge> All = new List<TpvGauge>();
    static readonly Stopwatch Clock = new Stopwatch();
    // A fixed 30 fps instead of following the display, to leave the CPU and GPU to the game.
    static readonly DispatcherTimer Frames = CreateFrames();
    static bool running;
    static DispatcherTimer CreateFrames() {
        DispatcherTimer timer = new DispatcherTimer(DispatcherPriority.Normal);
        timer.Interval = TimeSpan.FromMilliseconds(33);
        timer.Tick += OnFrame;
        return timer;
    }
    readonly ScaleTransform transform;
    readonly double smoothTime;
    double value, velocity, target;
    public bool InstantRise { get; set; }
    public TpvGauge(ScaleTransform transform, double smoothTime) {
        this.transform = transform;
        this.smoothTime = smoothTime;
        All.Add(this);
    }
    public void SetTarget(double next) {
        target = Math.Max(0, Math.Min(1, next));
        if (InstantRise && target > value) {
            value = target;
            velocity = 0;
            transform.ScaleX = value;
            return;
        }
        if (!running && Math.Abs(target - value) > 0.0005) {
            running = true;
            Clock.Restart();
            Frames.Start();
        }
    }
    // Critically damped spring: speed stays continuous when a new value arrives mid-motion.
    bool Step(double dt) {
        double omega = 2 / smoothTime, x = omega * dt;
        double decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
        double change = value - target, temp = (velocity + omega * change) * dt;
        velocity = (velocity - omega * temp) * decay;
        value = target + (change + temp) * decay;
        bool settled = Math.Abs(value - target) < 0.0005 && Math.Abs(velocity) < 0.002;
        if (settled) { value = target; velocity = 0; }
        transform.ScaleX = Math.Max(0, Math.Min(1, value));
        return settled;
    }
    static void OnFrame(object sender, EventArgs e) {
        double dt = Math.Min(0.1, Clock.Elapsed.TotalSeconds);
        Clock.Restart();
        if (dt <= 0) return;
        bool settled = true;
        foreach (TpvGauge gauge in All) settled &= gauge.Step(dt);
        if (settled) {
            // No work at all while nothing moves.
            Frames.Stop();
            running = false;
        }
    }
}
'@
    . (Join-Path $PSScriptRoot 'block-panel.ps1')
    $blocks = New-Object TpvBlockPanel
    . (Join-Path $PSScriptRoot 'trend-chart.ps1')
    . (Join-Path $PSScriptRoot 'road-memory.ps1')
    . (Join-Path $PSScriptRoot 'route-locator.ps1')
    . (Join-Path $PSScriptRoot 'wbal-gauge.ps1')
    . (Join-Path $PSScriptRoot 'dial-gauges.ps1')
    $powerDial = New-Object TpvPowerDial
    $draftDial = New-Object TpvDraftBrakeDial
    $windDial = New-Object TpvWindDial
    $wbalDial = New-Object TpvWbalGauge
    $roads = New-Object TpvRoadMemory
    $roadPath = Join-Path $PSScriptRoot 'road-memory.csv'
    [void]$roads.Load($roadPath)
    $wbalChart = [TpvTrendChart]::new(1200, $false, $true)
    $powerChart = [TpvTrendChart]::new(300, $true)
    $routeChart = New-Object TpvRouteChart
    $ui.WbalChartHost.Child = $wbalChart
    $ui.PowerChartHost.Child = $powerChart
    $ui.RouteChartHost.Child = $routeChart
    $ui.WbalGaugeHost.Child = $wbalDial
    $ui.PowerDialHost.Child = $powerDial
    $ui.DraftDialHost.Child = $draftDial
    $ui.WindDialHost.Child = $windDial
    # Key, element, width in columns. The list order is the default layout.
    $blockItems = @(
        @('wbalgauge', 'WbalGaugeBlock', 2), @('powerdial', 'PowerDialBlock', 2), @('draftdial', 'DraftDialBlock', 2), @('winddial', 'WindDialBlock', 2), @('wbal', 'WbalSection', 2), @('power30', 'Power30Tile', 1), @('vam', 'VamTile', 1),
        @('intensity', 'IntensityTile', 1), @('wkg', 'WkgTile', 1), @('kjftp', 'KjTile', 1), @('wbalmin', 'WbalMinTile', 1), @('wdrop', 'WdropTile', 1),
        @('vi', 'ViTile', 1), @('coast', 'CoastTile', 1), @('zones', 'ZonesSection', 2),
        @('draft', 'DraftTile', 1), @('brake', 'BrakeTile', 1), @('ahead', 'AheadTile', 1), @('behind', 'BehindTile', 1),
        @('segment', 'SegmentBlock', 2), @('bests', 'BestsBlock', 2), @('climb', 'ClimbBlock', 2), @('key', 'KeyBlock', 2),
        @('coach', 'CoachBlock', 2), @('missed', 'MissedBlock', 2), @('score', 'ScoreSection', 2),
        @('wbalchart', 'WbalChartBlock', 2), @('powerchart', 'PowerChartBlock', 2), @('routechart', 'RouteChartBlock', 2),
        @('attack', 'AttackBlock', 2), @('groups', 'GroupsBlock', 2), @('pull', 'PullBlock', 2), @('team', 'TeamBlock', 2),
        @('music', 'MusicBlock', 2)
    )
    $defaultOrder = [string[]]@($blockItems | ForEach-Object { $_[0] })
    $ui.BlockHost.Children.Clear()
    foreach ($item in $blockItems) { $blocks.AddBlock($item[0], $ui[$item[1]], $item[2]) }
    [void]$ui.BlockHost.Children.Add($blocks)

    # Braking appears at once and fades briefly; draft follows the game directly; W'bal can glide.
    $brakeGauge = [TpvGauge]::new($brakeScale, 0.09)
    $brakeGauge.InstantRise = $true
    $draftGauge = [TpvGauge]::new($draftScale, 0.02)
    $wbalGauge = [TpvGauge]::new($wbalScale, 0.30)
    $wbalGreen = [Windows.Media.BrushConverter]::new().ConvertFromString('#68DF31')
    $wbalYellow = [Windows.Media.BrushConverter]::new().ConvertFromString('#E7C03F')
    $wbalOrange = [Windows.Media.BrushConverter]::new().ConvertFromString('#EF8A52')
    $moveBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFFFFF')
    $panelBorder = $ui.Panel.BorderBrush
    $st = @{ hwnd=[IntPtr]::Zero; move=$false; target=0.0; draftTarget=0.0; score=(New-BrakeScore); wbal=$(if ($wProfile) { New-WBal $wProfile.wPrime } else { $null }); wbalTarget=0.0; ftpRider=$null; ftpTss=$null; ftpEstimate=$null; limit=($FtpWatts * $FtpPercent / 100); gapAhead=(New-GapTrend); gapBehind=(New-GapTrend); routeName=$null; routeChecked=[datetime]::MinValue; profile=$null; profileSaved=(Get-Date); lastFocus=$null; power5=(New-PowerWindow 5); power30=(New-PowerWindow 30); vam=(New-VamWindow 30); ride=(New-RideStats); coach=(New-CoachState $FtpWatts); coachSaved=(Get-Date); alertHwnd=[IntPtr]::Zero; alertText=''; display=@{}; preset=$null; hidden=$false; scale=1.0; partCount=1; zonesAt=[datetime]::MinValue; roadVersion=-1; dataState=''; focusStamp=[int64]0; gameHwnd=[IntPtr]::Zero; gameChecked=[datetime]::MinValue; editSeen=(Get-Date); escDown=$false; confirm=$null; errorCount=0; chartRider=$null; chartTime=$null; routeKey=$null; chartsAdded=$false; dpi=1.0; edit=$null; keepMenu=$false; drag=$null; handleHwnd=[IntPtr]::Zero; menuHwnd=[IntPtr]::Zero; tick=0; keys=@{} }
    $inv = [Globalization.CultureInfo]::InvariantCulture

    # One failing event is logged and the widget keeps running.
    $app.add_DispatcherUnhandledException({
        $args[1].Handled = $true
        if ($st.errorCount -ge 20) { return }
        $st.errorCount++
        try { "recovered error $(Get-Date -Format s): $($args[1].Exception.Message)" | Out-File -LiteralPath $logPath -Append -Encoding utf8 } catch { }
    })

    function Write-FileSafely([string]$Path, [string]$Text) {
        # The previous version stays as .bak, and a crash cannot leave a half-written file.
        $temp = "$Path.tmp"
        [IO.File]::WriteAllText($temp, $Text)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($temp, $Path, "$Path.bak") } else { [IO.File]::Move($temp, $Path) }
    }

    function Read-JsonSafely([string]$Path) {
        foreach ($candidate in $Path, "$Path.bak") {
            if (-not (Test-Path -LiteralPath $candidate)) { continue }
            try {
                $value = [IO.File]::ReadAllText($candidate) | ConvertFrom-Json
                if ($null -ne $value) { return $value }
            } catch { }
        }
        return $null
    }

    Read-CoachLibrary $st.coach $coachPath
    $st.coach.mass = Get-CoachRiderMass $logDirectory
    $coachDefaultBrush = $ui.CoachText.Foreground
    $alertFastBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#EF8A52')
    $alertHardBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FF3B30')

    function Set-ClickThrough([bool]$enabled, [IntPtr]$Hwnd = $st.hwnd) {
        $WS_EX_TRANSPARENT = 0x20; $WS_EX_TOOLWINDOW = 0x80; $WS_EX_LAYERED = 0x80000; $WS_EX_NOACTIVATE = 0x8000000
        $style = $WS_EX_TOOLWINDOW -bor $WS_EX_LAYERED -bor $WS_EX_NOACTIVATE -bor [int64][TpvNative]::GetWindowLongPtr($Hwnd, -20)
        if ($enabled) { $style = $style -bor $WS_EX_TRANSPARENT } else { $style = $style -band (-bnot [int64]$WS_EX_TRANSPARENT) }
        [void][TpvNative]::SetWindowLongPtr($Hwnd, -20, [IntPtr]$style)
    }

    function Get-StartPosition {
        $p = Read-JsonSafely $posPath
        if ($p -and $null -ne $p.x -and $null -ne $p.y) { return @([int]$p.x, [int]$p.y) }
        $game = Get-Process | Where-Object { $_.ProcessName -match 'TPVirtual|TrainingPeaks' -and $_.ProcessName -notmatch 'Launcher' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($game) {
            $r = New-Object TpvNative+RECT
            if ([TpvNative]::GetWindowRect($game.MainWindowHandle, [ref]$r)) {
                return @([int](($r.Left + $r.Right) / 2 - 220), [int]($r.Bottom - 420))
            }
        }
        return @(100, 100)
    }

    function Test-Hotkey([int]$vk) {
        $down = (([TpvNative]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0) -and (([TpvNative]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0) -and (([TpvNative]::GetAsyncKeyState($vk) -band 0x8000) -ne 0)
        $was = [bool]$st.keys[$vk]
        $st.keys[$vk] = $down
        return ($down -and -not $was)
    }

    # The event the game is showing, as long as it keeps writing its file.
    function Get-LiveEvent {
        try {
            $path = Join-Path (Split-Path -Parent $FocusFile) 'event.json'
            $info = New-Object IO.FileInfo $path
            if (-not $info.Exists -or ([datetime]::UtcNow - $info.LastWriteTimeUtc).TotalSeconds -gt 20) { return $null }
            $parsed = (Read-SharedText $path) | ConvertFrom-Json
            $entry = @($parsed)[0]
            if (-not $entry -or -not $entry.route) { return $null }
            return @{ name = [string]$entry.name; route = [string]$entry.route; distance = [double]$entry.distance }
        } catch { return $null }
    }

    function Clear-EventRoute {
        try { Get-ChildItem -LiteralPath $eventRouteDirectory -File -ErrorAction Stop | Remove-Item -Force -Confirm:$false -ErrorAction Stop } catch { }
        $st.routeIndex = $null
    }

    # In its own hidden process: the widget never waits for the network.
    function Start-RouteFetch($LiveEvent, [string]$Route) {
        try {
            New-Item -ItemType Directory -Force $eventRouteDirectory | Out-Null
            $request = Join-Path $eventRouteDirectory 'request.json'
            $json = @{ eventName = $LiveEvent.name; routeName = $Route; ids = @(Get-LoggedEventIds $logDirectory); outDirectory = $eventRouteDirectory } | ConvertTo-Json
            [IO.File]::WriteAllText($request, $json)
            $fetcher = Join-Path $PSScriptRoot 'route-fetch.ps1'
            Start-Process powershell.exe -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$fetcher`"", '-RequestFile', "`"$request`""
        } catch { }
    }

    function Update-RouteProfile {
        $now = Get-Date
        if (($now - $st.routeChecked).TotalSeconds -lt 5) { return }
        $st.routeChecked = $now
        # The event names its route from the start; the game log is only readable outside a session.
        $liveEvent = Get-LiveEvent
        $route = $(if ($RouteOverride) { $RouteOverride } elseif ($liveEvent) { $liveEvent.route } else { Get-ActiveRoute $logDirectory })
        if ($route -ne $st.routeName) {
            Save-RouteProfile $st.profile $learnedRouteDirectory
            $st.routeName = $route
            $st.profile = $null
            $st.routeFetchCount = 0
            $st.routeFetchAt = $null
            Clear-EventRoute
            Reset-Tactics $st.tactics
        }
        if (-not $route -or $route -match '(?i)^free ride$') { return }
        # A route file is final; a learned profile only waits for one.
        if ($st.profile -and $st.profile.source -eq 'game') { return }
        $routeFile = Find-GameRouteFile $gameRouteDirectory $route
        if (-not $routeFile) { $routeFile = Find-CachedRoute $eventRouteDirectory $route }
        if ($routeFile) {
            $game = $null
            try { $game = Import-GameRoute $routeFile $route } catch { }
            if ($game) {
                Save-RouteProfile $st.profile $learnedRouteDirectory
                $st.profile = Expand-RouteLaps $game $(if ($liveEvent) { $liveEvent.distance } else { 0 })
                $st.routeKey = $null
                $st.routeIndex = $null
                return
            }
        }
        if (-not $st.profile) { $st.profile = Read-LearnedRoute $learnedRouteDirectory $route }
        # Tried again every minute, five times at most, while the event is open.
        if ($liveEvent -and [int]$st.routeFetchCount -lt 5 -and ($null -eq $st.routeFetchAt -or ((Get-Date) - $st.routeFetchAt).TotalSeconds -ge 60)) {
            $st.routeFetchCount = [int]$st.routeFetchCount + 1
            $st.routeFetchAt = Get-Date
            Start-RouteFetch $liveEvent $route
        }
    }

    function Set-AlertText([string]$Text) {
        if ($st.move) { return }
        if ($st.hidden -or -not $st.display['alerts']) { $Text = '' }
        if ($Text -eq $st.alertText -or $st.alertHwnd -eq [IntPtr]::Zero) { return }
        $st.alertText = $Text
        if (-not $Text) { $alertLabel.Text = ''; $alertReason.Text = ''; return }
        $joke = $Text
        if ($st.display['jokes'] -and $alertJokes.ContainsKey($Text)) {
            $choices = @($alertJokes[$Text] | Where-Object { $_ -ne $st.lastJoke })
            if ($choices.Count) { $joke = $choices[(Get-Random -Maximum $choices.Count)] }
        }
        $st.lastJoke = $joke
        $alertLabel.Text = $joke
        $alertReason.Text = $(if ($joke -ne $Text) { $Text } else { '' })
        $brush = $(if ($Text -eq 'TOO FAST') { $alertFastBrush } else { $alertHardBrush })
        $alertLabel.Foreground = $brush
        $alertReason.Foreground = $brush
        Set-AlertFontSizes ($joke -ne $Text)
        Set-AlertPlacement
    }

    function Set-AlertFontSizes([bool]$WithReason) {
        $alertLabel.FontSize = $(if ($WithReason) { 56 } else { 64 }) * [double]$st.alertScale
        $alertReason.FontSize = 24 * [double]$st.alertScale
    }

    # The chosen spot is kept relative to the game window, so it follows the game when it moves.
    function Set-AlertPlacement {
        if ($st.alertHwnd -eq [IntPtr]::Zero) { return }
        $alert.UpdateLayout()
        $area = Get-PlacementArea
        $r = Get-WindowBounds $st.alertHwnd
        $width = $r.Right - $r.Left
        $height = $r.Bottom - $r.Top
        $x = [int]($area.Left + [double]$st.alertX * $area.Width - $width / 2)
        $y = [int]($area.Top + [double]$st.alertY * $area.Height - $height / 2)
        # Only kept fully on its screen: near the edge of the game window, or outside it, is allowed.
        $screen = [Windows.Forms.Screen]::FromPoint((New-Object Drawing.Point ([int]($x + $width / 2)), ([int]($y + $height / 2)))).WorkingArea
        $x = [math]::Max($screen.Left, [math]::Min($x, $screen.Right - $width))
        $y = [math]::Max($screen.Top, [math]::Min($y, $screen.Bottom - $height))
        [void][TpvNative]::SetWindowPos($st.alertHwnd, [IntPtr](-1), $x, $y, 0, 0, 0x0011)
    }

    function Save-AlertPlacement {
        $area = Get-PlacementArea
        $r = Get-WindowBounds $st.alertHwnd
        if ($area.Width -le 0 -or $area.Height -le 0) { return }
        $st.alertX = [math]::Max(-1.0, [math]::Min(2.0, (($r.Left + $r.Right) / 2 - $area.Left) / $area.Width))
        $st.alertY = [math]::Max(-1.0, [math]::Min(2.0, (($r.Top + $r.Bottom) / 2 - $area.Top) / $area.Height))
        Save-WidgetSettings
    }

    function Set-AlertScale([double]$Scale) {
        $st.alertScale = [math]::Round([math]::Max(0.4, [math]::Min(3.0, $Scale)), 1)
        $bannerLabel.Text = "$([int](100 * $st.alertScale)) %"
        if ($alertLabel.Text) {
            # The size changes around the spot where the banner is now.
            $area = Get-PlacementArea
            $r = Get-WindowBounds $st.alertHwnd
            if ($area.Width -gt 0 -and $area.Height -gt 0) {
                $st.alertX = (($r.Left + $r.Right) / 2 - $area.Left) / $area.Width
                $st.alertY = (($r.Top + $r.Bottom) / 2 - $area.Top) / $area.Height
            }
            Set-AlertFontSizes ([bool]$alertReason.Text)
            Set-AlertPlacement
        }
    }

    # In Edit layout a sample banner can be dragged and resized with the mouse wheel.
    function Show-AlertPreview([bool]$On) {
        if ($st.alertHwnd -eq [IntPtr]::Zero) { return }
        if ($On) {
            $alertLabel.Text = 'BRAKES ARE ALLOWED'
            $alertReason.Text = 'TOO HARD  |  drag to move'
            $alertSizeButtons.Visibility = 'Visible'
            $alertLabel.Foreground = $alertHardBrush
            $alertReason.Foreground = $alertHardBrush
            $alertFrame.Background = $alertEditBackground
            $alertFrame.BorderBrush = $moveBrush
            Set-ClickThrough $false $st.alertHwnd
            Set-AlertFontSizes $true
            Set-AlertPlacement
            $st.alertText = '#preview'
        } else {
            $alertFrame.Background = [Windows.Media.Brushes]::Transparent
            $alertSizeButtons.Visibility = 'Collapsed'
            $alertFrame.BorderBrush = [Windows.Media.Brushes]::Transparent
            Set-ClickThrough $true $st.alertHwnd
            $alertLabel.Text = ''
            $alertReason.Text = ''
            $st.alertText = ''
        }
    }

    function Update-CoachDisplay($d, [bool]$IsMe) {
        try {
            if (-not $IsMe -or $d.latitude -isnot [ValueType] -or $d.longitude -isnot [ValueType]) {
                # Only the rider's own passes may teach the coach.
                Clear-CoachTrack $st.coach
                $ui.CoachText.Text = '--'
                $ui.CoachText.Foreground = $coachDefaultBrush
                $ui.MissedText.Text = '--'
                Set-AlertText ''
                return
            }
            $time = ((Get-Date) - $coachEpoch).TotalSeconds
            $speed = [double]$d.speed / 1000
            $power = [double]$d.power
            $brake = [double]$st.brakeUsed
            $slope = $(if ($d.slope -is [ValueType]) { [double]$d.slope } else { 0.0 })
            [void](Add-CoachSample $st.coach $time ([double]$d.latitude) ([double]$d.longitude) $speed $power $brake $slope)
            $advice = Get-CoachAdvice $st.coach $speed $power $brake
            $ui.CoachText.Text = Format-CoachAdvice $advice
            $ui.CoachText.Foreground = $(if ($advice.status -eq 'ease') { $alertFastBrush } else { $coachDefaultBrush })
            $ui.MissedText.Text = Format-CoachMissed $st.coach
            $flag = Update-CoachFlag $st.coach $advice $time $brake
            if ($flag.fast -and -not $flag.hard) {
                $ui.CoachText.Text = 'too fast  |  ' + $ui.CoachText.Text
                $ui.CoachText.Foreground = $alertFastBrush
            }
            Set-AlertText (Format-CoachBanner $flag)
            if (((Get-Date) - $st.coachSaved).TotalSeconds -ge 60) {
                Save-CoachLibrary $st.coach $coachPath
                $st.coachSaved = Get-Date
            }
        } catch { <# Keep the widget running if one data point is unusable. #> }
    }

    function Update-RouteChart([double]$Position, $Profile = $st.profile) {
        $size = [double]$Profile.bucket
        $k = [int][math]::Floor($Position / $size)
        $key = "$($Profile.route)|$k"
        # Rebuilt only when the rider enters a new stretch of road.
        if ($st.routeKey -ne $key) {
            $st.routeKey = $key
            $first = $k - [int][math]::Ceiling($routeChart.Ahead * 0.1 / $size)
            $count = [int][math]::Ceiling($routeChart.Ahead * 1.1 / $size) + 2
            $gradients = New-Object 'double[]' $count
            for ($i = 0; $i -lt $count; $i++) {
                $bucketKey = $first + $i
                $gradients[$i] = $(if ($Profile.slopes.ContainsKey($bucketKey)) { [double]$Profile.slopes[$bucketKey] } else { [double]::NaN })
            }
            $routeChart.SetProfile($gradients, $first * $size, $size)
        }
        $routeChart.SetPosition($Position)
        $ui.RouteChartText.Text = "+$([int][math]::Round($routeChart.GainAhead)) m"
    }

    function Format-ChartSpan([double]$Seconds) {
        $minutes = [int][math]::Floor($Seconds / 60)
        if ($minutes -lt 60) { return "$minutes min" }
        return '{0} h {1:00}' -f [math]::Floor($minutes / 60), ($minutes % 60)
    }

    function Update-RoadDisplay {
        # Rebuilt only when the rider reaches a new 50 m stretch.
        if ($roads.Version -ne $st.roadVersion) {
            $st.roadVersion = $roads.Version
            $st.routeKey = $null
            $st.roadPast = [int][math]::Ceiling($routeChart.Ahead * 0.1 / 50) + 1
            if ($st.display['routechart']) { $routeChart.SetProfile($roads.Gradients($st.roadPast, $st.roadPast + [int][math]::Ceiling($routeChart.Ahead / 50) + 2), 0, 50) }
            if ($st.display['climb']) {
                $ahead = $roads.AheadSlopes(401)
                $known = @{}
                for ($i = 0; $i -lt $ahead.Length; $i++) {
                    if ([double]::IsNaN($ahead[$i])) { break }
                    $known[$i] = $ahead[$i]
                }
                $ui.ClimbText.Text = $(if ($known.Count -lt 2) { 'Learning this road' } else { Format-Climb (Get-NextClimb @{ bucket = 50; slopes = $known; source = 'learned' } $roads.Traveled) })
            }
        }
        $routeChart.SetPosition(50 * [int]$st.roadPast + $roads.Traveled)
        $ui.RouteChartText.Text = $(if ($roads.KnownAhead -lt 2) { 'Learning this road' } else { "+$([int][math]::Round($routeChart.GainAhead)) m" })
    }

    function Clear-RouteChart([string]$Message = 'No route data') {
        $st.roadVersion = -1
        $st.routeKey = $null
        $routeChart.ClearProfile()
        $ui.RouteChartText.Text = $Message
    }

    # Outside events, or when the game log cannot be read, the GPS position is matched to the game's route files.
    function Get-LocatedRoute($d) {
        if ($d.latitude -isnot [ValueType] -or $d.longitude -isnot [ValueType]) { return $null }
        $lat = [double]$d.latitude * 180 / 2147483648
        $lon = [double]$d.longitude * 180 / 2147483648
        if ($st.locator) {
            $along = $st.locator.Locate($lat, $lon)
            if (-not [double]::IsNaN($along)) {
                $st.locateMiss = 0
                $reverse = $st.locator.Reversed
                $locatedProfile = $(if ($reverse) { $st.locatedReverse } else { $st.locatedForward })
                $unit = [double]$locatedProfile.length / $(if ($st.locator.Loop) { 3 } else { 1 })
                return @{ profile = $locatedProfile; position = [math]::Max(0.0, $(if ($reverse) { $unit - $along } else { $along })) }
            }
            # Off this route for 30 s: another route may be ridden now.
            $st.locateMiss = [int]$st.locateMiss + 1
            if ($st.locateMiss -lt 30) { return $null }
            $st.locator = $null
        }
        if ($null -ne $st.locateTried -and ((Get-Date) - $st.locateTried).TotalSeconds -lt 10) { return $null }
        $st.locateTried = Get-Date
        if ($null -eq $st.routeIndex) { $st.routeIndex = @(Read-GameRouteIndex $gameRouteDirectory) + @(Read-GameRouteIndex $eventRouteDirectory) }
        foreach ($entry in $st.routeIndex) {
            if ([math]::Abs($entry.lat - $lat) -gt 0.3 -or [math]::Abs($entry.lon - $lon) -gt 0.4) { continue }
            try {
                $j = [IO.File]::ReadAllText($entry.path, [Text.Encoding]::UTF8) | ConvertFrom-Json
                $points = Get-GameRoutePoints $j
                $xs = [double[]]@($points | ForEach-Object { $_[0] })
                $zs = [double[]]@($points | ForEach-Object { $_[2] })
                $locator = [TpvRouteLocator]::new($entry.name, [double]$j.latMid, [double]$j.lonMid, $xs, $zs, [bool](-not $j.metrics.isPointToPoint))
                if ([double]::IsNaN($locator.Locate($lat, $lon))) { continue }
                $game = Import-GameRoute $entry.path $entry.name
                if (-not $game) { continue }
                $st.locatedForward = New-LocatedProfile $game $locator.Loop $false
                $st.locatedReverse = New-LocatedProfile $game $locator.Loop $true
                $st.locator = $locator
                $st.locateMiss = 0
                return $null
            } catch { }
        }
        return $null
    }

    $st.tactics = New-TacticsState
    $st.lastAttack = $null
    $st.entries = $null
    $st.entriesAt = [datetime]::MinValue

    function Update-Tactics($d, [datetime]$Now) {
        $dir = Split-Path -Parent $FocusFile
        $me = [string]$d.name
        $near = $null; $groups = $null
        try { $near = (Read-SharedText (Join-Path $dir 'nearest.json')) | ConvertFrom-Json } catch { }
        try { $groups = (Read-SharedText (Join-Path $dir 'groups.json')) | ConvertFrom-Json } catch { }
        $speed = $(if ($d.speed -is [ValueType]) { [double]$d.speed / 1000 } else { 0.0 })
        $gaps = $null
        if ($groups -and $near) { $gaps = Get-GroupGaps $groups $near $me }
        # Without groups (free ride): the riders within 2 s of you.
        $size = $(if ($gaps) { [int]$gaps.size } elseif ($near) { @($near | Where-Object { $_ -and $_.timeGap -is [ValueType] -and [math]::Abs([double]$_.timeGap) -le 2000 }).Count } else { 1 })

        if ($d.draft -is [ValueType]) { Update-Pull $st.tactics ([double]$d.draft) $speed $size $Now }
        if ($st.display['pull']) {
            $ui.PullText.Text = Format-Pull $st.tactics $size
            $ui.PullText.Foreground = $(if ($size -ge 2 -and $st.tactics.pull -ge 60) { $alertHardBrush } elseif ($size -ge 2 -and $st.tactics.pull -ge 30) { $wbalOrange } else { $valueWhite })
        }

        # Attacks are only shown in their own block.
        if ($near -and $st.display['attack']) {
            $attack = Find-Attack $st.tactics $near $me $Now
            if ($attack) { $st.lastAttack = @{ text = Format-Attack $attack; at = $Now } }
        }
        if ($st.display['attack']) {
            $fresh = $st.lastAttack -and ($Now - $st.lastAttack.at).TotalSeconds -lt 15
            $ui.AttackText.Text = $(if ($fresh) { $st.lastAttack.text } elseif ($near) { 'Quiet' } else { '--' })
            $ui.AttackText.Foreground = $(if ($fresh) { $alertHardBrush } else { $valueWhite })
        }

        if ($st.display['groups']) {
            if ($gaps) {
                $aheadRate = Update-GroupTrend $st.tactics.ahead $gaps.ahead $Now
                $behindRate = Update-GroupTrend $st.tactics.behind $gaps.behind $Now
                $ui.GroupAheadText.Text = Format-GroupLine $gaps.ahead $aheadRate $true $speed
                $ui.GroupBehindText.Text = Format-GroupLine $gaps.behind $behindRate $false $speed
                # Green when it goes your way, orange when it does not.
                $ui.GroupAheadText.Foreground = $(if ($null -eq $aheadRate -or [math]::Abs($aheadRate) -lt 0.5) { $valueWhite } elseif ($aheadRate -lt 0) { $wbalGreen } else { $wbalOrange })
                $ui.GroupBehindText.Foreground = $(if ($null -eq $behindRate -or [math]::Abs($behindRate) -lt 0.5) { $valueWhite } elseif ($behindRate -gt 0) { $wbalGreen } else { $wbalOrange })
            } else {
                $ui.GroupAheadText.Text = '--'; $ui.GroupBehindText.Text = '--'
                $ui.GroupAheadText.Foreground = $valueWhite; $ui.GroupBehindText.Foreground = $valueWhite
            }
        }

        if ($st.display['team']) {
            if (-not $st.entries -or ($Now - $st.entriesAt).TotalSeconds -ge 30) {
                try { $st.entries = (Read-SharedText (Join-Path $dir 'entries.json')) | ConvertFrom-Json; $st.entriesAt = $Now } catch { }
            }
            $team = [string]$d.teamCode
            $ui.TeamText.Text = $(if (-not $team) { 'No team' } else { Format-Teammates (Get-Teammates $near $groups $st.entries $me $team $(if ($gaps) { $gaps.mine } else { $null })) })
        }
    }

    function Update-RaceInfo($d) {
        $now = Get-Date
        # The list of nearby riders is only read when a gap is displayed.
        if ($st.display['ahead'] -or $st.display['behind']) {
            try {
                $parsed = (Read-SharedText (Join-Path (Split-Path -Parent $FocusFile) 'nearest.json')) | ConvertFrom-Json
                $gaps = Get-NearestGaps $parsed ([string]$d.name)
                $aheadTrend = Update-GapTrend $st.gapAhead $gaps.aheadRider $gaps.ahead $now
                $behindTrend = Update-GapTrend $st.gapBehind $gaps.behindRider $gaps.behind $now
                $ui.AheadText.Text = Format-GapLine $gaps.ahead $aheadTrend $gaps.hasAhead
                $ui.BehindText.Text = Format-GapLine $gaps.behind $behindTrend $gaps.hasBehind
            } catch { <# File is being rewritten: keep the previous values. #> }
        }
        if ($st.display['attack'] -or $st.display['groups'] -or $st.display['pull'] -or $st.display['team']) {
            try { Update-Tactics $d $now } catch { }
        }
        try {
            # The game locks its log during a ride: the last known route stays in use.
            try { Update-RouteProfile } catch { }
            if ($st.profile -and $d.eventDistanceDone -is [ValueType] -and ([double]$d.eventDistanceDone -gt 0 -or ($st.profile.source -eq 'game' -and [double]$d.eventDistanceTotal -gt 0))) {
                if ($d.slope -is [ValueType]) { Add-RouteSample $st.profile ([double]$d.eventDistanceDone) ([double]$d.slope) }
                $routeDone = [double]$d.eventDistanceDone
                # The game's distance drifts ahead of the road (about 1 %): the GPS position on the same route corrects it.
                if ($routeDone -gt 0 -and $st.profile.source -eq 'game') {
                    [void](Get-LocatedRoute $d)
                    if ($st.locator -and (Test-SameRouteName $st.locator.Name $st.routeName) -and $d.latitude -is [ValueType]) {
                        $along = $st.locator.Locate([double]$d.latitude * 180 / 2147483648, [double]$d.longitude * 180 / 2147483648)
                        $lap = [double]$st.locator.Length
                        if (-not [double]::IsNaN($along) -and $lap -gt 0) {
                            $laps = [math]::Max(0, [math]::Round(($routeDone - $along) / $lap))
                            $routeDone = $laps * $lap + $along
                        }
                    }
                }
                $st.lastRouteDone = $routeDone
                $ui.ClimbText.Text = Format-Climb (Get-NextClimb $st.profile ([math]::Max(0.0, $routeDone)))
                if ($st.profile.ContainsKey('length') -and $routeDone -ge [double]$st.profile['length']) {
                    Clear-RouteChart 'Route ended'
                } elseif ($st.display['routechart']) {
                    Update-RouteChart $routeDone
                }
            } elseif ($located = Get-LocatedRoute $d) {
                $st.roadVersion = -1
                $ui.ClimbText.Text = Format-Climb (Get-NextClimb $located.profile $located.position)
                if ($st.display['routechart']) { Update-RouteChart $located.position $located.profile }
            } elseif ($roads.HasPosition) {
                # Outside an event the game gives no route position: use the learned roads.
                Update-RoadDisplay
            } else {
                $ui.ClimbText.Text = '--'
                Clear-RouteChart 'No position'
            }
            $key = Get-KeyPoint $d
            if ($key) {
                $ui.KeyLabel.Text = $key.label
                $ui.KeyText.Text = Format-Distance $key.meters
            } else {
                $ui.KeyLabel.Text = 'FINISH'
                $ui.KeyText.Text = '--'
            }
            if (($now - $st.profileSaved).TotalSeconds -ge 30) {
                Save-RouteProfile $st.profile $learnedRouteDirectory
                if ($roads.Dirty) { $roads.Save($roadPath) }
                $st.profileSaved = $now
            }
        } catch { }
    }

    function Show-BrakeScore {
        $who = $st.score.rider
        $ftpLabel = $(if (Test-OwnRider) {
                if ($st.ftpForced -gt 0) { "FTP $([int]$st.ftpForced) (set)" } elseif ($st.ownFtpEstimate) { "FTP ~$([int][math]::Round($st.ownFtpEstimate))" } else { "FTP $([int]$FtpWatts)" }
            } elseif ($st.ftpEstimate) { "FTP ~$([int][math]::Round($st.ftpEstimate))" } else { "FTP ? (yours until known)" })
        if (-not $st.move) { $ui.RiderText.Text = $(if ($st.dataState -ne 'live') { 'Waiting for game data' } elseif ($who) { "$who  |  $ftpLabel" } else { 'Waiting for rider' }) }
        $session = $st.coach.session
        if ($who -and $who -ne $MyRiderName) {
            $ui.ScoreText.Text = '--'
            $ui.ScoreDetail.Text = 'Your rider only'
        } elseif ($session.corners -le 0) {
            $ui.ScoreText.Text = '--'
            $ui.ScoreDetail.Text = 'No braked corner yet'
        } else {
            $clean = $session.corners - $session.bad
            $ui.ScoreText.Text = "$([int][math]::Round(100 * $clean / $session.corners)) %"
            $ui.ScoreDetail.Text = "$clean clean / $($session.corners) corners"
        }
    }

    # Window and tile backgrounds keep their colors; only how much of the game shows through changes.
    function Set-BackgroundOpacity([int]$Percent) {
        $st.bgOpacity = [math]::Max(30, [math]::Min(100, $Percent))
        $level = $st.bgOpacity / 100
        foreach ($part in $parts) {
            if (-not $part.rootBase) {
                $base = $part.root.Background.CloneCurrentValue()
                foreach ($stop in $base.GradientStops) { $stop.Color = [Windows.Media.Color]::FromArgb(255, $stop.Color.R, $stop.Color.G, $stop.Color.B) }
                $part.rootBase = $base
            }
            $rootBrush = $part.rootBase.Clone()
            $rootBrush.Opacity = $level
            $rootBrush.Freeze()
            $part.root.Background = $rootBrush
        }
        $tileBrush = New-Object Windows.Media.SolidColorBrush ([Windows.Media.Color]::FromRgb(0x0A, 0x14, 0x40))
        $tileBrush.Opacity = [math]::Min(1.0, 0.74 * $level)
        $tileBrush.Freeze()
        $tileStyle = $window.FindResource('Tile')
        foreach ($part in $parts) {
            foreach ($child in $part.panel.Children) { if ($child -is [Windows.Controls.Border] -and [object]::ReferenceEquals($child.Style, $tileStyle)) { $child.Background = $tileBrush } }
        }
        $bgLabel.Text = "$($st.bgOpacity) %"
    }

    # ---------- 2. values colored by state ----------
    function New-FrozenBrush([string]$Color) { $b = [Windows.Media.BrushConverter]::new().ConvertFromString($Color); $b.Freeze(); return $b }
    $valueWhite = New-FrozenBrush '#FFFFFF'
    $valueGrey = New-FrozenBrush '#8C9AC0'
    $valueGreen = New-FrozenBrush '#68DF31'
    $valueAmber = New-FrozenBrush '#FFB23F'
    $valueRed = New-FrozenBrush '#FF5A4F'
    # Game zone colors, brightened so that they read on the dark tiles. Zone 1 stays white.
    $zoneBrushes = @($valueWhite, (New-FrozenBrush '#5AA0FF'), (New-FrozenBrush '#4FD13E'), (New-FrozenBrush '#F2CC2E'), (New-FrozenBrush '#FF8A3D'), (New-FrozenBrush '#FF5A4F'), (New-FrozenBrush '#C98BFF'))
    function Get-ZoneBrush([double]$Watts, [double]$Ftp) {
        if ($Ftp -le 0 -or [double]::IsNaN($Watts)) { return $valueWhite }
        $ratio = $Watts / $Ftp
        $zone = 0
        foreach ($limit in 0.55, 0.75, 0.90, 1.05, 1.20, 1.50) { if ($ratio -ge $limit) { $zone++ } }
        return $zoneBrushes[$zone]
    }
    function Get-WbalBrush([double]$Percent) { if ($Percent -lt 25) { return $valueRed } elseif ($Percent -lt 50) { return $valueAmber } else { return $valueWhite } }

    function Update-DataOpacity {
        $opacity = $(if ($st.move -or $st.dataState -eq 'live') { 1.0 } else { 0.45 })
        foreach ($part in $parts) { $part.root.Opacity = $opacity }
    }

    function Set-DataState([string]$State) {
        if ($State -eq $st.dataState) { return }
        $st.dataState = $State
        Update-DataOpacity
        if ($State -ne 'live' -and -not $st.move) { $ui.RiderText.Text = 'Waiting for game data' }
    }

    function Update-Data {
        try {
            $info = New-Object IO.FileInfo $FocusFile
            if (-not $info.Exists) {
                $st.lastFocus = $null
                $st.target = 0
                Set-AlertText ''
                Set-DataState 'waiting'
                return
            }
            $age = ([datetime]::UtcNow - $info.LastWriteTimeUtc).TotalSeconds
            if ($age -gt 2) {
                # Old data must never leave a braking alert on screen.
                $st.lastFocus = $null
                $st.target = 0
                Set-AlertText ''
            }
            Set-DataState $(if ($age -gt 5) { 'waiting' } else { 'live' })
            # Nothing new in the file: no parsing.
            if ($info.LastWriteTimeUtc.Ticks -eq $st.focusStamp) { return }
            $s = [IO.File]::Open($FocusFile, 'Open', 'Read', 'ReadWrite,Delete')
            try { $text = (New-Object IO.StreamReader($s, [Text.Encoding]::UTF8, $true)).ReadToEnd() } finally { $s.Dispose() }
            if (-not $text.Trim()) { return }
            $d = @($text | ConvertFrom-Json)[0]
            $st.focusStamp = $info.LastWriteTimeUtc.Ticks
            if ($age -le 2) { $st.lastFocus = $d }
            # Assumption to confirm on a real ride: brakeStrength ranges from 0 to 100.
            if ($d.brakeStrength -is [ValueType]) {
                $pct = [math]::Max(0, [math]::Min(100, [double]$d.brakeStrength))
                $st.target = $(if ($age -le 2) { $pct / 100 } else { 0 })
                $ui.BrakeText.Text = ([math]::Round($pct)).ToString($inv) + ' %'
            }
            # Live samples plateau at 100, so the bar uses a 0-100 scale.
            if ($d.draft -is [ValueType]) {
                $draftPct = [math]::Max(0, [math]::Min(100, [double]$d.draft))
                $st.draftTarget = $draftPct / 100
                $ui.DraftText.Text = ([math]::Round([double]$d.draft)).ToString($inv) + ' %'
                $ui.DraftText.Foreground = $(if ($draftPct -lt 5) { $valueGrey } elseif ($draftPct -lt 40) { $valueWhite } else { $valueGreen })
            }
            if ($age -le 2 -and $d.brakeStrength -is [ValueType] -and $d.power -is [ValueType]) {
                $rider = [string]$d.name
                if (-not $script:MyRiderName -and $rider) { $script:MyRiderName = $rider }
                if ($st.ftpRider -ne $rider) {
                    $st.ftpRider = $rider
                    $st.ftpTss = $null
                    $st.ftpEstimate = $null
                }
                # Refresh only when the integer TSS changes, so the threshold does not flicker.
                if ($d.tss -is [ValueType] -and $d.nrmPower -is [ValueType] -and $d.time -is [ValueType] -and $st.ftpTss -ne $d.tss) {
                    $previousTss = $st.ftpTss
                    $st.ftpTss = $d.tss
                    # The game rounds TSS down: when it steps up by one, the real TSS is exactly the new whole
                    # number, which gives the rider's FTP from the first minutes of the ride.
                    $estimate = $null
                    if ($null -ne $previousTss -and [int]$d.tss -eq [int]$previousTss + 1) { $estimate = Get-FtpAtTssStep ([double]$d.tss) ([double]$d.nrmPower) ([double]$d.time) }
                    # Otherwise (rider just selected): the real TSS lies between the shown value and the next one.
                    if (-not $estimate -and $null -eq $st.ftpEstimate) { $estimate = Get-EstimatedFtp ([double]$d.tss + 0.5) ([double]$d.nrmPower) ([double]$d.time) }
                    if ($estimate) {
                        $st.ftpEstimate = $estimate
                        if ([string]$rider -eq [string]$script:MyRiderName) { $st.ownFtpEstimate = $estimate }
                    }
                }
                $ftpUsed = Get-FtpUsed
                $st.limit = $ftpUsed * $FtpPercent / 100
                $st.brakeUsed = [double]$d.brakeStrength
                if ($rider -eq $MyRiderName -and $d.speed -is [ValueType]) {
                    $brakeSlope = $(if ($d.slope -is [ValueType]) { [double]$d.slope } else { 0.0 })
                    $st.brakeUsed = Get-CoachBrakeSignal $st.coach ((Get-Date) - $coachEpoch).TotalSeconds ([double]$d.speed / 1000) ([double]$d.power) $brakeSlope ([double]$d.brakeStrength)
                    if (-not $st.coach.realBrakeSeen) {
                        $ui.BrakeText.Text = $(if ($st.brakeUsed -gt 0) { 'ON (est.)' } else { 'off (est.)' })
                        $st.target = $(if ($st.brakeUsed -gt 0) { 1.0 } else { 0.0 })
                    }
                }
                Update-BrakeScore $st.score $rider ([double]$st.brakeUsed) ([double]$d.power) (Get-Date) $st.limit
                $power30Result = Update-PowerWindow $st.power30 $rider ([double]$d.power) (Get-Date)
                $power5Result = Update-PowerWindow $st.power5 $rider ([double]$d.power) (Get-Date)
                $wbalPower = $(if ($power5Result) { [double]$power5Result.average } else { [double]$d.power })
                $ui.Power30Text.Text = Format-PowerWindow $power30Result 30
                $power30Brush = $(if ($power30Result) { Get-ZoneBrush ([double]$power30Result.average) ([double]$ftpUsed) } else { $valueWhite })
                $ui.Power30Text.Foreground = $power30Brush
                if ($d.altitude -is [ValueType] -and $d.speed -is [ValueType] -and $d.slope -is [ValueType]) {
                    # The value is always computed; only the moment it is shown depends on the setting.
                    $vamResult = Update-VamWindow $st.vam $rider ([double]$d.altitude) ([double]$d.speed / 1000) ([double]$d.slope) (Get-Date)
                    if ($null -eq $st.vamShownAt -or $st.vamShownRider -ne $rider -or ((Get-Date) - $st.vamShownAt).TotalSeconds -ge [double]$st.vamRefresh - 0.1) {
                        $ui.VamText.Text = Format-Vam $vamResult 30
                        $st.vamShownAt = Get-Date
                        $st.vamShownRider = $rider
                    }
                } else {
                    $ui.VamText.Text = '--'
                    $st.vamShownAt = $null
                }
                if ($st.wbal -and $rider -eq $MyRiderName) {
                    # The ride clock going backwards means a new ride: start with a full W'.
                    if ($d.time -is [ValueType] -and $null -ne $st.wbal.gameTime -and $d.time -lt $st.wbal.gameTime) { Reset-WBal $st.wbal; $wbalChart.Clear() }
                    if ($d.time -is [ValueType]) { $st.wbal.gameTime = $d.time }
                    Update-WBal $st.wbal ([double]$d.power) (Get-CpUsed) (Get-Date)
                    $wPct = 100 * $st.wbal.value / $st.wbal.wPrime
                    $st.wbalTarget = $wPct / 100
                    $ui.WbalText.Text = ([math]::Round($wPct)).ToString($inv) + ' %  ' + ($st.wbal.value / 1000).ToString('0.0', $inv) + ' kJ'
                    $ui.WbalText.Foreground = Get-WbalBrush $wPct
                    $ui.WbalChartText.Foreground = Get-WbalBrush $wPct
                    $ui.WdropText.Text = Format-WDrop $st.wbal
                    $gaugeStart = $(if ($null -ne $st.wbal.effortStart) { 100 * [double]$st.wbal.effortStart / $st.wbal.wPrime } else { [double]::NaN })
                    # The time left follows the 5 s average power and changes at most once per second, so that it can be read.
                    if ($wbalPower -gt (Get-CpUsed)) {
                        if ($null -eq $st.emptyAt -or ((Get-Date) - $st.emptyAt).TotalSeconds -ge [double]$st.emptyRefresh - 0.05) {
                            $left = $st.wbal.value / ($wbalPower - (Get-CpUsed))
                            if ($left -ge 60) { $left = 5 * [math]::Round($left / 5) }
                            $st.emptyText = Format-BrakeTime $left
                            $st.emptyWatts = [int](5 * [math]::Round($wbalPower / 5))
                            $st.emptyAt = Get-Date
                        }
                    } else {
                        $st.emptyAt = $null
                    }
                    $st.phraseWanted = Get-WbalPhrase $wPct
                    $gaugeStatus = $(if ($null -ne $st.emptyAt) { "EMPTY IN $($st.emptyText) at $($st.emptyWatts) W" } elseif ($wPct -lt 99.5) { 'RECOVERING' } else { 'FULL' })
                    $wbalDial.SetValues([double]$wPct, [double]($st.wbal.value / 1000), [double](100 * $st.wbal.lowest / $st.wbal.wPrime), [double]($st.wbal.drop / 1000), [double]($st.wbal.maxDrop / 1000), [double]$gaugeStart, [string]$gaugeStatus)
                    $ui.WbalFill.Background = $(if ($wPct -lt 25) { $wbalOrange } elseif ($wPct -lt 50) { $wbalYellow } else { $wbalGreen })
                    $ui.WbalHint.Text = $(if ($null -ne $st.emptyAt) { "empty in $($st.emptyText)" } else { '' })
                } else {
                    if ($st.wbal) { $st.wbal.last = $null }
                    $st.wbalTarget = 0
                    $ui.WbalText.Text = '--'
                    $ui.WbalText.Foreground = $valueWhite
                    $ui.WbalChartText.Foreground = $valueWhite
                    $ui.WdropText.Text = '--'
                    $wbalDial.ShowMessage('Your rider only')
                    $st.phraseWanted = ''
                    $ui.WbalHint.Text = ''
                }
                try {
                    $isMe = ($rider -eq $MyRiderName)
                    $rideWbal = $(if ($isMe -and $st.wbal) { 100 * $st.wbal.value / $st.wbal.wPrime } else { $null })
                    $rideSlope = $(if ($d.slope -is [ValueType]) { [double]$d.slope } else { 0.0 })
                    $rideSpeed = $(if ($d.speed -is [ValueType]) { [double]$d.speed / 1000 } else { 0.0 })
                    $rideAltitude = $(if ($null -ne $st.vam.unit -and $d.altitude -is [ValueType]) { [double]$d.altitude / $st.vam.unit } else { $null })
                    Update-RideStats $st.ride $rider ([double]$d.power) $ftpUsed $rideWbal $d.time $d.eventLapsDone $d.eventLapsTotal $rideSlope $rideSpeed $rideAltitude (Get-Date)
                    # The weight in the log is the user's, so W/kg is only shown for them.
                    $riderKg = $(if ($isMe) { $st.coach.mass - 8 } else { $null })
                    $ui.IntensityText.Text = Format-RideIntensity $d.nrmPower $ftpUsed
                    $ui.WkgText.Text = Format-RideWkg $power30Result $riderKg
                    $ui.WkgText.Foreground = $(if ($null -ne $riderKg) { $power30Brush } else { $valueWhite })
                    if ($st.display['powerdial']) {
                        $dialAverage = $(if ($power30Result) { [double]$power30Result.average } else { [double]::NaN })
                        $dialWkg = $(if ($null -ne $riderKg -and $riderKg -gt 0 -and -not [double]::IsNaN($dialAverage)) { $dialAverage / $riderKg } else { [double]::NaN })
                        $powerDial.SetValues([double]$d.power, [double]$ftpUsed, [double]$dialAverage, [double]$dialWkg)
                    }
                    $ui.KjText.Text = Format-RideKj $st.ride
                    $ui.WbalMinText.Text = Format-RideWbalMin $st.ride
                    $ui.BestsText.Text = Format-RideBests $st.ride
                    $ui.ViText.Text = Format-RideVi $d.nrmPower $d.avgPower
                    $ui.CoastText.Text = Format-RideCoast $st.ride
                    $ui.ZonesText.Text = Format-RideZones $st.ride ([double]$d.power) $ftpUsed
                    # Resizing seven columns costs a layout pass, so the bar refreshes every 2 s.
                    if ($st.display['zones'] -and ((Get-Date) - $st.zonesAt).TotalSeconds -ge 2) {
                        $st.zonesAt = Get-Date
                        for ($z = 0; $z -lt 7; $z++) { $ui["Zone$($z + 1)"].Width = [Windows.GridLength]::new($st.ride.zones[$z], [Windows.GridUnitType]::Star) }
                    }
                    $segment = Get-RideSegment $st.ride
                    $ui.SegmentLabel.Text = $segment.label
                    $ui.SegmentText.Text = $segment.text
                    # A new rider or a ride clock going backwards starts new curves.
                    if ($st.chartRider -ne $rider -or ($d.time -is [ValueType] -and $null -ne $st.chartTime -and [double]$d.time -lt $st.chartTime)) {
                        $st.chartRider = $rider
                        $powerChart.Clear()
                    }
                    if ($d.time -is [ValueType]) { $st.chartTime = [double]$d.time }
                    $powerChart.Reference = $ftpUsed
                    $powerChart.Feed([double]$d.power)
                    $ui.PowerChartText.Text = "$([int][math]::Round([double]$d.power)) W"
                    if ($null -ne $rideWbal) {
                        $wbalChart.Feed([double]$rideWbal)
                        $ui.WbalChartText.Text = "$([int][math]::Round([double]$rideWbal)) %  |  $(Format-ChartSpan $wbalChart.CoveredSeconds)"
                    } else {
                        $ui.WbalChartText.Text = 'Your rider only'
                    }
                } catch { <# One unusable data point must not stop the other displays. #> }
                if ($rider -eq $MyRiderName -and $d.latitude -is [ValueType] -and $d.longitude -is [ValueType] -and $d.slope -is [ValueType]) {
                    [void]$roads.Feed([double]$d.latitude, [double]$d.longitude, [double]$d.slope)
                } else {
                    $roads.Lose()
                }
                Update-CoachDisplay $d ($rider -eq $MyRiderName)
                Show-BrakeScore
            }
        } catch { <# File is being rewritten: keep the previous values. #> }
    }

    $window.add_SourceInitialized({
        $st.hwnd = (New-Object Windows.Interop.WindowInteropHelper($window)).Handle
        Set-ClickThrough $true
        $pos = Get-StartPosition
        [void][TpvNative]::SetWindowPos($st.hwnd, [IntPtr](-1), $pos[0], $pos[1], 0, 0, 0x0011)
        $r = New-Object TpvNative+RECT
        [void][TpvNative]::GetWindowRect($st.hwnd, [ref]$r)
        # The log of the previous session stays available after a problem.
        if (Test-Path -LiteralPath $logPath) { try { Copy-Item -LiteralPath $logPath -Destination (Join-Path $PSScriptRoot 'overlay.previous.log') -Force } catch { } }
        "started $(Get-Date -Format s) rect=$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)" | Out-File -LiteralPath $logPath -Encoding utf8
    })

    [xml]$handleXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Widget handle" AutomationProperties.Name="Widget handle" Width="24" Height="24"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize">
  <Button x:Name="HandleButton" AutomationProperties.Name="Widget menu" ToolTip="Click: menu | Drag: move"
          Content="&#x2630;" FontFamily="Segoe UI Symbol" FontSize="13" Foreground="#F4F6FB" Cursor="SizeAll">
    <Button.Template>
      <ControlTemplate TargetType="Button">
        <Border x:Name="Bg" Background="#E63F66F5" CornerRadius="5">
          <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <ControlTemplate.Triggers>
          <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="#5C80FF"/></Trigger>
        </ControlTemplate.Triggers>
      </ControlTemplate>
    </Button.Template>
  </Button>
</Window>
'@

    [xml]$menuXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Widget menu panel" AutomationProperties.Name="Widget menu panel" Width="262" SizeToContent="Height"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        FontFamily="Segoe UI" Foreground="#F4F6FB">
  <Window.Resources>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#F4F6FB"/>
      <Setter Property="FontSize" Value="11.5"/>
      <Setter Property="Margin" Value="2,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="RepeatButton">
      <Setter Property="Foreground" Value="#F4F6FB"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="Delay" Value="350"/>
      <Setter Property="Interval" Value="110"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RepeatButton">
            <Border x:Name="Bg" Background="#24408F" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="#5C80FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="Button">
      <Setter Property="Foreground" Value="#F4F6FB"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Margin" Value="2"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bg" Background="#24408F" CornerRadius="5">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bg" Property="Background" Value="#5C80FF"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="ValueBox" TargetType="TextBox">
      <Setter Property="Foreground" Value="#F4F6FB"/>
      <Setter Property="Background" Value="#1A2E6E"/>
      <Setter Property="BorderBrush" Value="#4F76F5"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="CaretBrush" Value="#FFFFFF"/>
      <Setter Property="SelectionBrush" Value="#5C80FF"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="TextAlignment" Value="Center"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Margin" Value="3,2"/>
      <Setter Property="Cursor" Value="IBeam"/>
    </Style>
  </Window.Resources>
  <Border Background="#F50B1A52" BorderBrush="#4F76F5" BorderThickness="1.5" CornerRadius="10" Padding="10">
    <DockPanel>
    <!-- Stays visible while the menu scrolls. -->
    <Grid DockPanel.Dock="Top" Margin="0,0,0,6">
      <TextBlock Text="SETTINGS" FontSize="13" FontWeight="Bold" VerticalAlignment="Center" Margin="2,0,0,0"/>
      <Button x:Name="CloseMenuButton" AutomationProperties.Name="Close settings" ToolTip="Close" Content="&#x2715;" FontFamily="Segoe UI Symbol" FontSize="14" Width="34" Height="28" HorizontalAlignment="Right"/>
    </Grid>
    <UniformGrid x:Name="TabGrid" DockPanel.Dock="Top" Rows="1" Columns="4" Height="30" Margin="0,0,0,8">
      <Button Tag="display" AutomationProperties.Name="Tab display" Content="DISPLAY" FontSize="10.5"/>
      <Button Tag="layout" AutomationProperties.Name="Tab layout" Content="LAYOUT" FontSize="10.5"/>
      <Button Tag="rider" AutomationProperties.Name="Tab rider" Content="RIDER" FontSize="10.5"/>
      <Button Tag="other" AutomationProperties.Name="Tab other" Content="OTHER" FontSize="10.5"/>
    </UniformGrid>
    <ScrollViewer VerticalScrollBarVisibility="Auto" Focusable="False">
    <StackPanel>
      <StackPanel x:Name="TabDisplay">
      <DockPanel Margin="2,0,0,4">
        <TextBlock Text="PROFILE" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
      </DockPanel>
      <UniformGrid x:Name="ProfileGrid" Rows="2" Columns="3" Height="58" Margin="0,0,0,4" ToolTip="Each profile keeps its own displayed items, layout, parts, block sizes, position and background. Changes are saved in the selected profile.">
        <Button Tag="Race" AutomationProperties.Name="Profile Race" Content="Race" FontSize="11"/>
        <Button Tag="Climb" AutomationProperties.Name="Profile Climb" Content="Climb" FontSize="11"/>
        <Button Tag="Training" AutomationProperties.Name="Profile Training" Content="Training" FontSize="11"/>
        <Button Tag="Stream" AutomationProperties.Name="Profile Stream" Content="Stream" FontSize="11"/>
        <Button Tag="Minimal" AutomationProperties.Name="Profile Minimal" Content="Minimal" FontSize="11"/>
        <Button Tag="" AutomationProperties.Name="No profile" Content="Off" FontSize="11"/>
      </UniformGrid>
      <TextBlock x:Name="ProfileHint" Text="" FontSize="10" Foreground="#9DBBFF" TextWrapping="Wrap" Margin="2,0,0,8"/>
      <TextBlock Text="DISPLAY" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <StackPanel x:Name="DisplayList" Margin="0,0,0,8"/>
      </StackPanel>
      <StackPanel x:Name="TabLayout" Visibility="Collapsed">
      <TextBlock Text="POSITION" FontSize="12" FontWeight="Bold" Margin="2,0,0,5"/>
      <UniformGrid x:Name="PresetGrid" Rows="3" Columns="3" Height="114" Margin="0,0,0,7">
        <Button Tag="TL" AutomationProperties.Name="Top left" Content="&#x2196;" FontFamily="Segoe UI Symbol" FontSize="16"/>
        <Button Tag="TC" AutomationProperties.Name="Top center" Content="&#x2191;" FontFamily="Segoe UI Symbol" FontSize="16"/>
        <Button Tag="TR" AutomationProperties.Name="Top right" Content="&#x2197;" FontFamily="Segoe UI Symbol" FontSize="16"/>
        <Button Tag="ML" AutomationProperties.Name="Middle left" Content="&#x2190;" FontFamily="Segoe UI Symbol" FontSize="16"/>
        <Button Tag="MC" AutomationProperties.Name="Center" Content="&#x25CF;" FontFamily="Segoe UI Symbol" FontSize="12"/>
        <Button Tag="MR" AutomationProperties.Name="Middle right" Content="&#x2192;" FontFamily="Segoe UI Symbol" FontSize="16"/>
        <Button Tag="BL" AutomationProperties.Name="Bottom left" Content="&#x2199;" FontFamily="Segoe UI Symbol" FontSize="16"/>
        <Button Tag="BC" AutomationProperties.Name="Bottom center" Content="&#x2193;" FontFamily="Segoe UI Symbol" FontSize="16"/>
        <Button Tag="BR" AutomationProperties.Name="Bottom right" Content="&#x2198;" FontFamily="Segoe UI Symbol" FontSize="16"/>
      </UniformGrid>
      <TextBlock Text="SIZE" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <Grid Height="30" Margin="0,0,0,8">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/><ColumnDefinition Width="58"/></Grid.ColumnDefinitions>
        <Button x:Name="SmallerButton" AutomationProperties.Name="Smaller" Content="&#x2212;" FontSize="16"/>
        <TextBlock x:Name="ScaleLabel" Grid.Column="1" Text="" FontSize="11" FontWeight="SemiBold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <Button x:Name="LargerButton" Grid.Column="2" AutomationProperties.Name="Larger" Content="+" FontSize="16"/>
        <Button x:Name="ResetSizeButton" Grid.Column="3" AutomationProperties.Name="Fit height" Content="Fit" FontSize="11"/>
      </Grid>
      <TextBlock Text="PARTS" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <UniformGrid x:Name="PartsGrid" Rows="1" Columns="3" Height="30" Margin="0,0,0,8">
        <Button Tag="1" AutomationProperties.Name="One part" Content="1"/>
        <Button Tag="2" AutomationProperties.Name="Two parts" Content="2"/>
        <Button Tag="3" AutomationProperties.Name="Three parts" Content="3"/>
      </UniformGrid>
      <TextBlock Text="BACKGROUND" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <Grid x:Name="BgRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="Click or hold">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="BgLessButton" AutomationProperties.Name="More transparent" Content="&#x2212;"/>
        <TextBlock x:Name="BgLabel" Grid.Column="1" Text="90 %" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <RepeatButton x:Name="BgMoreButton" Grid.Column="2" AutomationProperties.Name="More opaque" Content="+"/>
      </Grid>
      <Button x:Name="EditButton" AutomationProperties.Name="Edit layout" Content="Edit layout" Height="27"/>
      <Button x:Name="ResetLayoutButton" AutomationProperties.Name="Reset layout" Content="Reset layout" Height="27"/>
      <TextBlock Text="Edit layout: drag blocks between parts, double-click a block for a full row, right-click a gauge or graph to put two on one line, drag the braking banner to place it (- / + on it = size), edges resize, title bars move and snap. Esc = done." FontSize="10" Foreground="#9DBBFF" TextWrapping="Wrap" Margin="2,6,0,0"/>
      </StackPanel>
      <StackPanel x:Name="TabRider" Visibility="Collapsed">
      <DockPanel Margin="2,0,0,4">
        <Button x:Name="FtpAutoButton" DockPanel.Dock="Right" Height="22" Padding="10,0" AutomationProperties.Name="FTP from TPV" ToolTip="Back to the value from TPV" Content="AUTO" FontSize="11"/>
        <TextBlock Text="FTP" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
      </DockPanel>
      <Grid x:Name="FtpRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="AUTO = the FTP TPV uses. - / + forces a value (1 W steps). Type a value in the middle, or click or hold - / +">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="FtpLessButton" AutomationProperties.Name="Lower FTP" Content="&#x2212;"/>
        <TextBox x:Name="FtpLabel" Grid.Column="1" Text="AUTO" Style="{StaticResource ValueBox}" ToolTip="Click and type a value, Enter to keep it, Esc to cancel"/>
        <RepeatButton x:Name="FtpMoreButton" Grid.Column="2" AutomationProperties.Name="Raise FTP" Content="+"/>
      </Grid>
      <DockPanel Margin="2,0,0,4">
        <Button x:Name="WPrimeAutoButton" DockPanel.Dock="Right" Height="22" Padding="10,0" AutomationProperties.Name="W' from TPV" ToolTip="Back to the value from TPV" Content="AUTO" FontSize="11"/>
        <TextBlock Text="W' (kJ)" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
      </DockPanel>
      <Grid x:Name="WPrimeRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="AUTO = the W' TPV estimated. - / + forces a value (0.1 kJ steps). Type a value in the middle, or click or hold - / +">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="WPrimeLessButton" AutomationProperties.Name="Lower W'" Content="&#x2212;"/>
        <TextBox x:Name="WPrimeLabel" Grid.Column="1" Text="AUTO" Style="{StaticResource ValueBox}" ToolTip="Click and type a value, Enter to keep it, Esc to cancel"/>
        <RepeatButton x:Name="WPrimeMoreButton" Grid.Column="2" AutomationProperties.Name="Raise W'" Content="+"/>
      </Grid>
      <DockPanel Margin="2,0,0,4">
        <Button x:Name="CpAutoButton" DockPanel.Dock="Right" Height="22" Padding="10,0" AutomationProperties.Name="CP from TPV" ToolTip="Back to the value from TPV" Content="AUTO" FontSize="11"/>
        <TextBlock Text="CP (W'BAL)" FontSize="12" FontWeight="Bold" VerticalAlignment="Center"/>
      </DockPanel>
      <Grid x:Name="CpRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="AUTO = the CP TPV estimated, used for W'bal. - / + forces a value (1 W steps). Type a value in the middle, or click or hold - / +">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="CpLessButton" AutomationProperties.Name="Lower CP" Content="&#x2212;"/>
        <TextBox x:Name="CpLabel" Grid.Column="1" Text="AUTO" Style="{StaticResource ValueBox}" ToolTip="Click and type a value, Enter to keep it, Esc to cancel"/>
        <RepeatButton x:Name="CpMoreButton" Grid.Column="2" AutomationProperties.Name="Raise CP" Content="+"/>
      </Grid>
      <Button x:Name="AllAutoButton" AutomationProperties.Name="All values from TPV" Content="All AUTO (values from TPV)" Height="27" Margin="2,0,2,10"/>
      <TextBlock Text="Click a value to type it (Enter = keep, Esc = cancel). The game loses the keyboard while you type: click back in the game afterwards." FontSize="10" Foreground="#9DBBFF" TextWrapping="Wrap" Margin="2,0,0,8"/>
      <TextBlock Text="W'BAL TIME REFRESH" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <Grid x:Name="EmptyRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="How often the time left on W'bal changes. Click or hold">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="EmptyLessButton" AutomationProperties.Name="Refresh time left faster" Content="&#x2212;"/>
        <TextBlock x:Name="EmptyLabel" Grid.Column="1" Text="1 s" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <RepeatButton x:Name="EmptyMoreButton" Grid.Column="2" AutomationProperties.Name="Refresh time left slower" Content="+"/>
      </Grid>
      </StackPanel>
      <StackPanel x:Name="TabOther" Visibility="Collapsed">
      <TextBlock Text="BANNER SIZE" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <Grid x:Name="BannerRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="Edit layout: drag the banner to place it">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="BannerLessButton" AutomationProperties.Name="Smaller banner" Content="&#x2212;"/>
        <TextBlock x:Name="BannerLabel" Grid.Column="1" Text="100 %" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <RepeatButton x:Name="BannerMoreButton" Grid.Column="2" AutomationProperties.Name="Larger banner" Content="+"/>
      </Grid>
      <TextBlock Text="ROUTE AHEAD" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <Grid x:Name="SpanRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="Click or hold">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="SpanLessButton" AutomationProperties.Name="Shorter route view" Content="&#x2212;"/>
        <TextBlock x:Name="SpanLabel" Grid.Column="1" Text="5000 m" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <RepeatButton x:Name="SpanMoreButton" Grid.Column="2" AutomationProperties.Name="Longer route view" Content="+"/>
      </Grid>
      <TextBlock Text="VAM REFRESH" FontSize="12" FontWeight="Bold" Margin="2,0,0,4"/>
      <UniformGrid x:Name="VamRefreshGrid" Rows="1" Columns="5" Height="30" Margin="0,0,0,2">
        <Button Tag="0" AutomationProperties.Name="VAM refresh live" Content="Live" FontSize="11"/>
        <Button Tag="1" AutomationProperties.Name="VAM refresh 1 second" Content="1 s" FontSize="11"/>
        <Button Tag="2" AutomationProperties.Name="VAM refresh 2 seconds" Content="2 s" FontSize="11"/>
        <Button Tag="5" AutomationProperties.Name="VAM refresh 5 seconds" Content="5 s" FontSize="11"/>
        <Button Tag="10" AutomationProperties.Name="VAM refresh 10 seconds" Content="10 s" FontSize="11"/>
      </UniformGrid>
      <Grid x:Name="VamFreeRow" Height="30" Margin="0,0,0,8" Background="Transparent" ToolTip="Click or hold">
        <Grid.ColumnDefinitions><ColumnDefinition Width="44"/><ColumnDefinition Width="*"/><ColumnDefinition Width="44"/></Grid.ColumnDefinitions>
        <RepeatButton x:Name="VamSlowerButton" AutomationProperties.Name="VAM refresh faster" Content="&#x2212;"/>
        <TextBlock x:Name="VamRefreshLabel" Grid.Column="1" Text="Live" FontSize="12" FontWeight="Bold" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        <RepeatButton x:Name="VamFasterButton" Grid.Column="2" AutomationProperties.Name="VAM refresh slower" Content="+"/>
      </Grid>
      <Button x:Name="ToggleButton" AutomationProperties.Name="Toggle widget" Content="Hide widget" Height="27"/>
      <Button x:Name="ResetButton" AutomationProperties.Name="Reset score" Content="Reset score + W'bal" Height="27"/>
      <Button x:Name="QuitButton" AutomationProperties.Name="Close widget" Content="Close widget" Height="27"/>
      </StackPanel>
    </StackPanel>
    </ScrollViewer>
    </DockPanel>
  </Border>
</Window>
'@

    [xml]$alertXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Widget alert" AutomationProperties.Name="Widget alert" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" FontFamily="Segoe UI">
  <Border x:Name="AlertFrame" CornerRadius="10" BorderThickness="2" BorderBrush="Transparent" Background="Transparent">
  <StackPanel Margin="24,8">
    <StackPanel.Effect><DropShadowEffect Color="#000000" BlurRadius="14" ShadowDepth="0" Opacity="1"/></StackPanel.Effect>
    <TextBlock x:Name="AlertLabel" Text="" FontSize="56" FontWeight="Black" HorizontalAlignment="Center"/>
    <TextBlock x:Name="AlertReason" Text="" FontSize="24" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,-4,0,0"/>
    <StackPanel x:Name="AlertSizeButtons" Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,6,0,0" Visibility="Collapsed">
      <Button x:Name="AlertSmaller" Content="&#x2212;" Width="54" Height="34" Margin="4,0" FontSize="20" FontWeight="Bold" Foreground="#FFFFFF" Background="#CC24408F" BorderBrush="#FFFFFF" Cursor="Hand"/>
      <Button x:Name="AlertLarger" Content="+" Width="54" Height="34" Margin="4,0" FontSize="20" FontWeight="Bold" Foreground="#FFFFFF" Background="#CC24408F" BorderBrush="#FFFFFF" Cursor="Hand"/>
    </StackPanel>
  </StackPanel>
  </Border>
</Window>
'@
    $alert = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $alertXaml))
    $alertLabel = $alert.FindName('AlertLabel')
    $alertReason = $alert.FindName('AlertReason')
    $alertFrame = $alert.FindName('AlertFrame')
    $alertSizeButtons = $alert.FindName('AlertSizeButtons')
    # Where the banner goes, as shares of the game window: its center. Size: 1 = default.
    $st.alertX = 0.5
    $st.alertY = 0.28
    $st.alertScale = 1.0
    $alertEditBackground = [Windows.Media.BrushConverter]::new().ConvertFromString('#80101830')
    $alert.add_SourceInitialized({
        $st.alertHwnd = (New-Object Windows.Interop.WindowInteropHelper($alert)).Handle
        # Tool window, layered, no-activate and click-through: it never interferes with the game.
        $style = 0x20 -bor 0x80 -bor 0x80000 -bor 0x8000000 -bor [int64][TpvNative]::GetWindowLongPtr($st.alertHwnd, -20)
        [void][TpvNative]::SetWindowLongPtr($st.alertHwnd, -20, [IntPtr]$style)
    })
    # Friendly enough for any video platform; a different one each time.
    $alertJokes = @{
        'TOO FAST' = @('BRAKES ARE ALLOWED', 'THIS CORNER IS REAL', 'EASY THERE, ROCKET', 'THE GRASS IS WAITING', 'NOT A STRAIGHT LINE!')
        'TOO HARD' = @('EASE OFF, HERO', 'GENTLE ON THE LEVERS', 'SMOOTH IS FAST', 'NOT AN EMERGENCY STOP', "SQUEEZE, DON'T GRAB")
    }
    $st.lastJoke = ''

    # ---------- W'bal phrase, in big under the part of the widget that shows W'bal ----------
    [xml]$phraseXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Widget phrase" AutomationProperties.Name="Widget phrase" SizeToContent="WidthAndHeight"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize" FontFamily="Segoe UI">
  <TextBlock Name="PhraseLabel" Text="" FontSize="30" FontWeight="Black" Margin="12,2">
    <TextBlock.Effect><DropShadowEffect Color="#000000" BlurRadius="12" ShadowDepth="0" Opacity="1"/></TextBlock.Effect>
  </TextBlock>
</Window>
"@
    $phrase = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $phraseXaml))
    $phraseLabel = $phrase.FindName('PhraseLabel')
    $st.phraseHwnd = [IntPtr]::Zero
    $st.phraseWanted = ''
    $st.phraseShown = ''
    $phrase.add_SourceInitialized({
        $st.phraseHwnd = (New-Object Windows.Interop.WindowInteropHelper($phrase)).Handle
        $style = 0x20 -bor 0x80 -bor 0x80000 -bor 0x8000000 -bor [int64][TpvNative]::GetWindowLongPtr($st.phraseHwnd, -20)
        [void][TpvNative]::SetWindowLongPtr($st.phraseHwnd, -20, [IntPtr]$style)
    })
    $phraseLevels = @(
        @{ from = 80; text = 'FRESH LEGS'; brush = (New-FrozenBrush '#68DF31') },
        @{ from = 60; text = 'ALL GOOD... FOR NOW'; brush = (New-FrozenBrush '#B4DC38') },
        @{ from = 40; text = 'STARTING TO STING'; brush = (New-FrozenBrush '#E7C03F') },
        @{ from = 20; text = 'WILL YOU SURVIVE?'; brush = (New-FrozenBrush '#EF8A52') },
        @{ from = -1; text = 'RUNNING ON FUMES'; brush = (New-FrozenBrush '#FF3B30') }
    )
    function Get-WbalPhrase([double]$Percent) {
        foreach ($level in $phraseLevels) { if ($Percent -ge $level.from) { return $level } }
        return $phraseLevels[-1]
    }

    # Shown, hidden and placed once per second, and at once when the level changes.
    function Sync-WbalPhrase {
        if ($st.phraseHwnd -eq [IntPtr]::Zero) { return }
        $wanted = $(if ($st.hidden -or -not $st.display['wbaltalk'] -or $st.dataState -ne 'live') { $null } else { $st.phraseWanted })
        $text = $(if ($wanted) { $wanted.text } else { '' })
        if ($text -ne $st.phraseShown) {
            $st.phraseShown = $text
            $phraseLabel.Text = $text
            if ($wanted) { $phraseLabel.Foreground = $wanted.brush }
        }
        if (-not $text) { return }
        $phraseHost = $parts[0]
        foreach ($key in 'wbalgauge', 'wbal', 'wbalchart') {
            if (-not $st.display[$key]) { continue }
            $found = $parts | Where-Object { $_.active -and @($_.panel.GetOrder()) -contains $key } | Select-Object -First 1
            if ($found) { $phraseHost = $found; break }
        }
        $hostHwnd = $(if ($phraseHost.id -eq 0) { $st.hwnd } else { $phraseHost.hwnd })
        $phraseLabel.FontSize = 30 * [math]::Max([double]0.7, [math]::Min([double]2, $phraseHost.panel.Zoom))
        $phrase.UpdateLayout()
        $box = Get-WindowBounds $hostHwnd
        $own = Get-WindowBounds $st.phraseHwnd
        $x = [int]($box.Left + (($box.Right - $box.Left) - ($own.Right - $own.Left)) / 2)
        $y = [int]$box.Bottom + 2
        if ($x -ne $own.Left -or $y -ne $own.Top) { [void][TpvNative]::SetWindowPos($st.phraseHwnd, [IntPtr](-1), $x, $y, 0, 0, 0x0011) }
    }

    $handle = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $handleXaml))
    $handleButton = $handle.FindName('HandleButton')
    $menu = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $menuXaml))
    $toggleButton = $menu.FindName('ToggleButton')

    function Set-ToolWindow([IntPtr]$Hwnd) {
        # Tool window + no-activate: clicking the menu never takes focus from the game.
        $style = 0x80 -bor 0x8000000 -bor [int64][TpvNative]::GetWindowLongPtr($Hwnd, -20)
        [void][TpvNative]::SetWindowLongPtr($Hwnd, -20, [IntPtr]$style)
    }

    function Get-WindowBounds([IntPtr]$Hwnd) {
        $r = New-Object TpvNative+RECT
        [void][TpvNative]::GetWindowRect($Hwnd, [ref]$r)
        return $r
    }

    function Set-MenuPosition {
        if ($st.menuHwnd -eq [IntPtr]::Zero) { return }
        $h = Get-WindowBounds $st.handleHwnd
        $m = Get-WindowBounds $st.menuHwnd
        $mw = $m.Right - $m.Left
        $mh = $m.Bottom - $m.Top
        $area = [Windows.Forms.Screen]::FromHandle($st.handleHwnd).WorkingArea
        $x = [math]::Max([int]$area.Left, [int]($h.Right - $mw))
        $y = $h.Bottom + 4
        if ($y + $mh -gt $area.Bottom) { $y = $h.Top - $mh - 4 }
        if ($y -lt $area.Top) { $y = [int]$area.Top }
        [void][TpvNative]::SetWindowPos($st.menuHwnd, [IntPtr](-1), $x, $y, 0, 0, 0x0011)
    }

    function Set-AttachedPosition {
        $r = Get-WindowBounds $st.hwnd
        [void][TpvNative]::SetWindowPos($st.handleHwnd, [IntPtr](-1), ($r.Right - 27), ($r.Top + 3), 0, 0, 0x0011)
        if ($menu.Visibility -eq 'Visible') {
            if ($st.keepMenu) {
                # Moving the widget raised it: put the menu back on top without moving it.
                [void][TpvNative]::SetWindowPos($st.menuHwnd, [IntPtr](-1), 0, 0, 0, 0, 0x0013)
            } else {
                Set-MenuPosition
            }
        }
    }

    function Set-WidgetPosition([int]$X, [int]$Y) {
        [void][TpvNative]::SetWindowPos($st.hwnd, [IntPtr](-1), $X, $Y, 0, 0, 0x0011)
        Set-AttachedPosition
    }

    function Save-WidgetPosition {
        $r = Get-WindowBounds $st.hwnd
        Write-FileSafely $posPath (@{ x = $r.Left; y = $r.Top } | ConvertTo-Json)
    }

    function Get-GameWindow {
        if ($st.gameHwnd -ne [IntPtr]::Zero -and [TpvNative]::IsWindow($st.gameHwnd)) { return $st.gameHwnd }
        $st.gameHwnd = [IntPtr]::Zero
        $now = Get-Date
        if (($now - $st.gameChecked).TotalSeconds -lt 15) { return [IntPtr]::Zero }
        $st.gameChecked = $now
        $game = Get-Process | Where-Object { $_.ProcessName -match 'TPVirtual|TrainingPeaks' -and $_.ProcessName -notmatch 'Launcher' -and $_.MainWindowHandle -ne 0 } | Select-Object -First 1
        if ($game) { $st.gameHwnd = $game.MainWindowHandle }
        return $st.gameHwnd
    }

    function Get-PlacementArea {
        $gameHwnd = Get-GameWindow
        if ($gameHwnd -ne [IntPtr]::Zero) {
            $g = Get-WindowBounds $gameHwnd
            $rect = New-Object Drawing.Rectangle $g.Left, $g.Top, ($g.Right - $g.Left), ($g.Bottom - $g.Top)
            $area = [Drawing.Rectangle]::Intersect($rect, [Windows.Forms.Screen]::FromHandle($gameHwnd).WorkingArea)
            if (-not $area.IsEmpty) { return $area }
        }
        return [Windows.Forms.Screen]::FromHandle($st.hwnd).WorkingArea
    }

    function Move-WidgetToPreset([string]$Preset) {
        $st.preset = $Preset
        $window.UpdateLayout()
        $area = Get-PlacementArea
        $r = Get-WindowBounds $st.hwnd
        $w = $r.Right - $r.Left
        $h = $r.Bottom - $r.Top
        $margin = 16
        $y = switch ($Preset[0]) {
            'T' { $area.Top + $margin }
            'M' { $area.Top + [int](($area.Height - $h) / 2) }
            default { $area.Bottom - $h - $margin }
        }
        $x = switch ($Preset[1]) {
            'L' { $area.Left + $margin }
            'C' { $area.Left + [int](($area.Width - $w) / 2) }
            default { $area.Right - $w - $margin }
        }
        Set-WidgetPosition $x $y
        Save-WidgetPosition
        Save-WidgetSettings
    }

    function Switch-WidgetVisibility {
        $st.hidden = -not $st.hidden
        $toggleButton.Content = $(if ($st.hidden) { 'Show widget' } else { 'Hide widget' })
        Update-PanelVisibility
    }

    function Update-PanelVisibility {
        # Hide the content only: the windows stay in place and clicks still pass through them.
        foreach ($part in $parts) {
            if (-not $part.active) { continue }
            $show = (-not $st.hidden) -and ($st.move -or $part.panel.VisibleCount -gt 0)
            $part.root.Visibility = $(if ($show) { 'Visible' } else { 'Hidden' })
        }
    }
    $displayItems = @(
        @{ group = 'GAUGES'; key = 'wbalgauge'; label = "W'bal" },
        @{ group = 'GAUGES'; key = 'powerdial'; label = 'Power' },
        @{ group = 'GAUGES'; key = 'draftdial'; label = 'Draft / brake' },
        @{ group = 'GAUGES'; key = 'winddial'; label = 'Wind' },
        @{ group = 'POWER'; key = 'wbal'; label = "W'bal bar" },
        @{ group = 'POWER'; key = 'wbalmin'; label = "W'bal min" },
        @{ group = 'POWER'; key = 'wdrop'; label = "W'bal drop" },
        @{ group = 'POWER'; key = 'wbaltalk'; label = "W'bal phrases" },
        @{ group = 'POWER'; key = 'power30'; label = 'Power 30s' },
        @{ group = 'POWER'; key = 'wkg'; label = 'W/kg 30s' },
        @{ group = 'POWER'; key = 'intensity'; label = 'Intensity / NP' },
        @{ group = 'POWER'; key = 'vi'; label = 'Variability' },
        @{ group = 'POWER'; key = 'kjftp'; label = 'Work above FTP' },
        @{ group = 'POWER'; key = 'zones'; label = 'Time in zones' },
        @{ group = 'POWER'; key = 'bests'; label = 'Best efforts' },
        @{ group = 'POWER'; key = 'coast'; label = 'Coasting' },
        @{ group = 'BRAKING + DRAFT'; key = 'draft'; label = 'Draft' },
        @{ group = 'BRAKING + DRAFT'; key = 'brake'; label = 'Brake' },
        @{ group = 'BRAKING + DRAFT'; key = 'score'; label = 'Braking score' },
        @{ group = 'BRAKING + DRAFT'; key = 'coach'; label = 'Next corner' },
        @{ group = 'BRAKING + DRAFT'; key = 'missed'; label = 'Missed brakes' },
        @{ group = 'BRAKING + DRAFT'; key = 'alerts'; label = 'Too fast / hard' },
        @{ group = 'BRAKING + DRAFT'; key = 'jokes'; label = 'Funny brake text' },
        @{ group = 'RACE + ROUTE'; key = 'ahead'; label = 'Ahead' },
        @{ group = 'RACE + ROUTE'; key = 'behind'; label = 'Behind' },
        @{ group = 'RACE + ROUTE'; key = 'climb'; label = 'Next climb' },
        @{ group = 'RACE + ROUTE'; key = 'vam'; label = 'VAM 30s' },
        @{ group = 'RACE + ROUTE'; key = 'segment'; label = 'Lap / climb' },
        @{ group = 'RACE + ROUTE'; key = 'key'; label = 'Finish / point' },
        @{ group = 'GRAPHS'; key = 'wbalchart'; label = "W'bal" },
        @{ group = 'GRAPHS'; key = 'powerchart'; label = 'Power' },
        @{ group = 'GRAPHS'; key = 'routechart'; label = 'Route' },
        @{ group = 'TACTICS'; key = 'attack'; label = 'Attacks' },
        @{ group = 'TACTICS'; key = 'groups'; label = 'Groups ahead / behind' },
        @{ group = 'TACTICS'; key = 'pull'; label = 'Time at the front' },
        @{ group = 'TACTICS'; key = 'team'; label = 'Teammates' },
        @{ group = 'MUSIC'; key = 'music'; label = 'Music controls' },
        @{ group = 'MUSIC'; key = 'musictitle'; label = 'Song title' }
    )

    function Update-SizeLabel { $scaleLabel.Text = "$([int]$parts[0].width) x $([int]$parts[0].height)" }

    function Get-MouseScreen {
        $c = New-Object TpvNative+POINT
        [void][TpvNative]::GetCursorPos([ref]$c)
        return [Windows.Point]::new($c.X, $c.Y)
    }

    function Get-PartOf($Sender) {
        foreach ($candidate in $parts) { if ([object]::ReferenceEquals($candidate.window, $Sender)) { return $candidate } }
        return $null
    }

    function Get-PartAt([Windows.Point]$Screen) {
        foreach ($candidate in $parts) {
            if (-not $candidate.active) { continue }
            $r = Get-WindowBounds $candidate.hwnd
            if ($Screen.X -ge $r.Left -and $Screen.X -lt $r.Right -and $Screen.Y -ge $r.Top -and $Screen.Y -lt $r.Bottom) { return $candidate }
        }
        return $null
    }

    function Get-PartChromeHeight($Part) {
        # The title bar of a separate part only exists while editing.
        if ($Part.id -gt 0 -and $st.move) { return $Part.chromeH + 24 }
        return $Part.chromeH
    }

    function Set-PartSize($Part, [double]$Width, [double]$Height) {
        $area = [Windows.Forms.Screen]::FromHandle($Part.hwnd).WorkingArea
        $Part.width = [math]::Round([math]::Max([double]$Part.minW, [math]::Min([double]($area.Width / $st.dpi), $Width)))
        $Part.height = [math]::Round([math]::Max([double]$Part.minH, [math]::Min([double]($area.Height / $st.dpi), $Height)))
        $Part.window.Width = $Part.width
        $Part.window.Height = $Part.height
    }

    function Resize-WidgetParts([double]$Factor) {
        foreach ($part in $parts) { if ($part.active) { Set-PartSize $part ($part.width * $Factor) ($part.height * $Factor) } }
        Update-SizeLabel
        # Keep the menu still so that repeated clicks on + or - stay on the button.
        $st.keepMenu = $true
        try { Set-DisplayLayout } finally { $st.keepMenu = $false }
    }

    function Set-FittedHeight {
        foreach ($part in $parts) {
            if (-not $part.active) { continue }
            $part.panel.Refresh()
            $part.window.UpdateLayout()
            Set-PartSize $part $part.width ($part.panel.FitHeight($part.width - $part.chromeW) + (Get-PartChromeHeight $part))
        }
        Update-SizeLabel
        $st.keepMenu = $true
        try { Set-DisplayLayout } finally { $st.keepMenu = $false }
    }

    function Show-Part($Part) {
        $Part.active = $true
        $Part.window.Show()
        if (-not $Part.width) { $Part.width = 320 }
        if (-not $Part.height) { $Part.height = 240 }
        Set-PartSize $Part $Part.width $Part.height
        if ($null -eq $Part.x -or $null -eq $Part.y) {
            # A new part opens in the first free spot around the existing windows.
            $area = [Windows.Forms.Screen]::FromHandle($st.hwnd).WorkingArea
            $pw = [int]($Part.width * $st.dpi)
            $ph = [int]($Part.height * $st.dpi)
            $others = New-Object System.Collections.ArrayList
            foreach ($other in $parts) { if ($other.active -and $other.id -ne $Part.id) { [void]$others.Add((Get-WindowBounds $other.hwnd)) } }
            $spots = New-Object System.Collections.ArrayList
            foreach ($o in $others) {
                [void]$spots.Add([int[]]@(($o.Right + 8), $o.Top))
                [void]$spots.Add([int[]]@(($o.Left - $pw - 8), $o.Top))
                [void]$spots.Add([int[]]@($o.Left, ($o.Bottom + 8)))
                [void]$spots.Add([int[]]@($o.Left, ($o.Top - $ph - 8)))
            }
            $Part.x = [int]$area.Left + 16
            $Part.y = [int]$area.Top + 16
            foreach ($spot in $spots) {
                if ($spot[0] -lt $area.Left -or $spot[1] -lt $area.Top -or $spot[0] + $pw -gt $area.Right -or $spot[1] + $ph -gt $area.Bottom) { continue }
                $free = $true
                foreach ($o in $others) {
                    if ($spot[0] -lt $o.Right -and $spot[0] + $pw -gt $o.Left -and $spot[1] -lt $o.Bottom -and $spot[1] + $ph -gt $o.Top) { $free = $false; break }
                }
                if ($free) { $Part.x = $spot[0]; $Part.y = $spot[1]; break }
            }
        }
        [void][TpvNative]::SetWindowPos($Part.hwnd, [IntPtr](-1), [int]$Part.x, [int]$Part.y, 0, 0, 0x0011)
        $Part.bar.Visibility = $(if ($st.move) { 'Visible' } else { 'Collapsed' })
        Set-ClickThrough (-not $st.move) $Part.hwnd
        $Part.root.BorderBrush = $(if ($st.move) { $moveBrush } else { $panelBorder })
    }

    function Set-PartsOnScreen {
        foreach ($part in $parts) {
            if ($part.id -eq 0 -or -not $part.active) { continue }
            $r = Get-WindowBounds $part.hwnd
            $area = [Windows.Forms.Screen]::FromHandle($part.hwnd).WorkingArea
            $x = [math]::Max([int]$area.Left, [math]::Min([int]($area.Right - ($r.Right - $r.Left)), [int]$r.Left))
            $y = [math]::Max([int]$area.Top, [math]::Min([int]($area.Bottom - ($r.Bottom - $r.Top)), [int]$r.Top))
            if ($x -ne $r.Left -or $y -ne $r.Top) { [void][TpvNative]::SetWindowPos($part.hwnd, [IntPtr](-1), $x, $y, 0, 0, 0x0011) }
        }
    }

    function Update-PartButtons {
        foreach ($button in $partsGrid.Children) {
            $on = ([int]$button.Tag -eq $st.partCount)
            $button.FontWeight = $(if ($on) { 'Bold' } else { 'Normal' })
            $button.Foreground = $(if ($on) { $partActiveBrush } else { $moveBrush })
        }
    }

    function Set-PartCount([int]$Count) {
        $st.partCount = [math]::Max(1, [math]::Min(3, $Count))
        foreach ($part in $parts) {
            if ($part.id -eq 0) { continue }
            if ($part.id -lt $st.partCount) {
                if (-not $part.active) { Show-Part $part }
            } elseif ($part.active) {
                # Closing a part never loses a block: they all return to the main part.
                $part.panel.MoveAllTo($blocks)
                $part.active = $false
                $part.window.Hide()
            }
        }
        Update-PartButtons
        Set-DisplayLayout
        Save-WidgetSettings
    }

    function Clear-Confirm {
        if (-not $st.confirm) { return }
        $st.confirm.button.Content = $st.confirm.label
        $st.confirm.button.Foreground = $moveBrush
        $st.confirm = $null
    }

    function Test-Confirmed($Button) {
        $now = Get-Date
        $same = $st.confirm -and [object]::ReferenceEquals($st.confirm.button, $Button) -and $now -lt $st.confirm.until
        Clear-Confirm
        if ($same) { return $true }
        $st.confirm = @{ button = $Button; label = $Button.Content; until = $now.AddSeconds(4) }
        $Button.Content = 'Click again to confirm'
        $Button.Foreground = $partActiveBrush
        return $false
    }

    function Get-SnapOffset([int]$Low, [int]$High, [int[]]$LowTargets, [int[]]$HighTargets) {
        $best = 0
        $distance = [int](13 * $st.dpi)
        foreach ($t in $LowTargets) { $delta = $t - $Low; if ([math]::Abs($delta) -lt $distance) { $best = $delta; $distance = [math]::Abs($delta) } }
        foreach ($t in $HighTargets) { $delta = $t - $High; if ([math]::Abs($delta) -lt $distance) { $best = $delta; $distance = [math]::Abs($delta) } }
        return $best
    }

    function Set-PartSnapped($Part) {
        # A window dropped near a screen edge or another part lines up with it.
        $r = Get-WindowBounds $Part.hwnd
        $area = [Windows.Forms.Screen]::FromHandle($Part.hwnd).WorkingArea
        $gap = [int](6 * $st.dpi)
        $lefts = @([int]$area.Left); $rights = @([int]$area.Right); $tops = @([int]$area.Top); $bottoms = @([int]$area.Bottom)
        foreach ($other in $parts) {
            if (-not $other.active -or $other.id -eq $Part.id) { continue }
            $o = Get-WindowBounds $other.hwnd
            $lefts += @([int]$o.Left, [int]($o.Right + $gap)); $rights += @([int]$o.Right, [int]($o.Left - $gap))
            $tops += @([int]$o.Top, [int]($o.Bottom + $gap)); $bottoms += @([int]$o.Bottom, [int]($o.Top - $gap))
        }
        $dx = Get-SnapOffset $r.Left $r.Right $lefts $rights
        $dy = Get-SnapOffset $r.Top $r.Bottom $tops $bottoms
        if ($dx -ne 0 -or $dy -ne 0) { [void][TpvNative]::SetWindowPos($Part.hwnd, [IntPtr](-1), ($r.Left + $dx), ($r.Top + $dy), 0, 0, 0x0011) }
    }

    function Complete-LayoutEdit {
        if (-not $st.edit) { return }
        $e = $st.edit
        $st.edit = $null
        $e.source.window.ReleaseMouseCapture()
        if ($e.kind -eq 'block') {
            $e.part.panel.EndDrag()
            Update-PanelVisibility
        } else {
            $e.part.width = [math]::Round($e.part.window.ActualWidth)
            $e.part.height = [math]::Round($e.part.window.ActualHeight)
            $e.part.window.Width = $e.part.width
            $e.part.window.Height = $e.part.height
            if ($e.part.id -eq 0) {
                $st.preset = $null
                Update-SizeLabel
                Save-WidgetPosition
            }
        }
        Save-WidgetSettings
    }

    function Get-EditZone($Target, $Point) {
        $zone = ''
        if ($Point.Y -lt 9) { $zone += 'T' } elseif ($Point.Y -gt $Target.ActualHeight - 9) { $zone += 'B' }
        if ($Point.X -lt 9) { $zone += 'L' } elseif ($Point.X -gt $Target.ActualWidth - 9) { $zone += 'R' }
        return $zone
    }

    # Same kind in this part first, then same kind in another part, then any block here.
    function Switch-GraphPair($Part, [Windows.Point]$Point) {
        $graphKey = $Part.panel.GraphKeyAt($Point)
        if (-not $graphKey) { return }
        $paired = $Part.panel.ToggleBeside($graphKey, $true)
        if (-not $paired) {
            foreach ($otherPart in $parts) {
                if (-not $otherPart.active -or $otherPart.id -eq $Part.id) { continue }
                $otherGraph = $otherPart.panel.FreeGraphKey($graphKey)
                if (-not $otherGraph) { continue }
                $otherPart.panel.MoveBlockTo($otherGraph, $Part.panel)
                $paired = $Part.panel.ToggleBeside($graphKey, $true)
                break
            }
        }
        if (-not $paired) { $paired = $Part.panel.ToggleBeside($graphKey, $false) }
        if ($paired) { Save-WidgetSettings } else { $ui.RiderText.Text = 'Check a second gauge or graph in the menu' }
    }

    function Switch-EditMode {
        $st.move = -not $st.move
        Complete-LayoutEdit
        $st.editSeen = Get-Date
        foreach ($part in $parts) {
            if (-not $part.active) { continue }
            Set-ClickThrough (-not $st.move) $part.hwnd
            $part.panel.HideBadge()
            $part.root.BorderBrush = $(if ($st.move) { $moveBrush } else { $panelBorder })
            $part.window.Cursor = $null
            if ($part.bar) { $part.bar.Visibility = $(if ($st.move) { 'Visible' } else { 'Collapsed' }) }
        }
        $editButton.Content = $(if ($st.move) { 'Finish editing' } else { 'Edit layout' })
        Update-PanelVisibility
        Update-DataOpacity
        if ($st.move) { $ui.RiderText.Text = 'EDIT: - / + on a block = its size | double-click = full row | right-click = 2 per line | Esc' } else { Show-BrakeScore }
        Show-AlertPreview $st.move
    }

    function Update-VamRefreshButtons {
        foreach ($button in $vamRefreshGrid.Children) {
            $on = ([double]$button.Tag -eq [double]$st.vamRefresh)
            $button.FontWeight = $(if ($on) { 'Bold' } else { 'Normal' })
            $button.Foreground = $(if ($on) { $partActiveBrush } else { $moveBrush })
        }
        $vamRefreshLabel.Text = $(if ($st.vamRefresh -le 0) { 'Live' } else { ([double]$st.vamRefresh).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) + ' s' })
    }

    # 100 m steps up to 1000 m, 250 m up to 3000 m, 500 m up to 10 000 m, then 1000 m up to 20 000 m.
    function Step-RouteSpan([int]$Direction) {
        $v = [double]$st.routeSpan
        $steps = @(@(1000, 100), @(3000, 250), @(10000, 500), @(20000, 1000))
        if ($Direction -gt 0) {
            $size = 1000; foreach ($pair in $steps) { if ($v -lt $pair[0]) { $size = $pair[1]; break } }
            $next = ([math]::Floor($v / $size + 0.000001) + 1) * $size
        } else {
            $size = 1000; foreach ($pair in $steps) { if ($v -le $pair[0]) { $size = $pair[1]; break } }
            $next = ([math]::Ceiling($v / $size - 0.000001) - 1) * $size
        }
        Set-RouteSpan $next
    }

    # Live, then half seconds up to 5 s, then whole seconds up to 30 s.
    function Set-EmptyRefresh([double]$Seconds) {
        $st.emptyRefresh = [math]::Max(0.0, [math]::Min(30.0, $Seconds))
        $st.emptyAt = $null
        $emptyLabel.Text = $(if ($st.emptyRefresh -le 0) { 'Live' } else { ([double]$st.emptyRefresh).ToString('0.#', [Globalization.CultureInfo]::InvariantCulture) + ' s' })
    }

    function Step-EmptyRefresh([int]$Direction) {
        $v = [double]$st.emptyRefresh
        if ($Direction -gt 0) {
            $next = $(if ($v -lt 5) { [math]::Floor($v * 2 + 0.000001) / 2 + 0.5 } else { [math]::Floor($v + 0.000001) + 1 })
        } else {
            $next = $(if ($v -le 5) { [math]::Ceiling($v * 2 - 0.000001) / 2 - 0.5 } else { [math]::Ceiling($v - 0.000001) - 1 })
        }
        Set-EmptyRefresh $next
    }

    function Set-RouteSpan([double]$Meters) {
        $st.routeSpan = [math]::Max(500, [math]::Min(20000, [math]::Round($Meters)))
        $routeChart.Ahead = $st.routeSpan
        $text = ([int]$st.routeSpan).ToString([Globalization.CultureInfo]::InvariantCulture)
        $spanLabel.Text = "$text m"
        $ui.RouteChartTitle.Text = "ROUTE  $text M"
        # The profile is rebuilt for the new distance at the next update.
        $st.routeKey = $null
        $st.roadVersion = -1
    }

    function Set-VamRefresh([double]$Seconds) {
        $st.vamRefresh = [math]::Max([double]0, [math]::Min([double]60, $Seconds))
        $st.vamShownAt = $null
        Update-VamRefreshButtons
    }

    # Half-second steps up to 10 s, then one-second steps up to 60 s.
    function Step-VamRefresh([int]$Direction) {
        $v = [double]$st.vamRefresh
        if ($Direction -gt 0) {
            $next = $(if ($v -lt 10) { [math]::Floor($v * 2 + 0.000001) / 2 + 0.5 } else { [math]::Floor($v + 0.000001) + 1 })
        } else {
            $next = $(if ($v -le 10) { [math]::Ceiling($v * 2 - 0.000001) / 2 - 0.5 } else { [math]::Ceiling($v - 0.000001) - 1 })
        }
        Set-VamRefresh $next
    }

    $st.ftpForced = 0.0
    $st.ownFtpEstimate = $null
    $st.wForced = 0.0
    $st.cpForced = 0.0
    function Get-FtpAtTssStep([double]$Tss, [double]$NormalizedPower, [double]$Seconds) {
        if ($Tss -lt 1 -or $Seconds -lt 60 -or $NormalizedPower -le 0) { return $null }
        $ftp = $NormalizedPower * [math]::Sqrt(100 * $Seconds / (3600 * $Tss))
        if ($ftp -lt 80 -or $ftp -gt 700) { return $null }
        return $ftp
    }

    # The settings only ever hold your own values: AUTO is your FTP (TPV's estimate while you are shown,
    # else the FTP configured in TPV), never another rider's.
    function Test-OwnRider { return (-not $st.ftpRider) -or ([string]$st.ftpRider -eq [string]$script:MyRiderName) }
    function Get-AutoFtp { if ($st.ownFtpEstimate) { return [double]$st.ownFtpEstimate } return [double]$FtpWatts }
    function Get-OwnFtp { if ($st.ftpForced -gt 0) { return [double]$st.ftpForced } return (Get-AutoFtp) }
    # FTP for the rider on screen: yours, or another rider's own estimate (only for that rider's zones).
    function Get-FtpUsed {
        if (Test-OwnRider) { return (Get-OwnFtp) }
        if ($st.ftpEstimate) { return [double]$st.ftpEstimate }
        return (Get-OwnFtp)
    }
    # CP stays TPV's (your logs); without it, your own FTP stands in.
    function Get-CpUsed {
        if ($st.cpForced -gt 0) { return [double]$st.cpForced }
        if ($wProfile) { return [double]$wProfile.cp }
        return (Get-OwnFtp)
    }

    # W' changed during a ride: W'bal keeps its percentage.
    function Set-WPrimeUsed([double]$Joules) {
        if ($Joules -le 0) { if ($st.wbal -and -not $wProfile) { $st.wbal = $null; $st.wbalTarget = 0.0 }; if (-not $wProfile) { return }; $Joules = [double]$wProfile.wPrime }
        if (-not $st.wbal) { $st.wbal = New-WBal $Joules; return }
        $old = [double]$st.wbal.wPrime
        if ($old -le 0 -or [math]::Abs($old - $Joules) -lt 1) { return }
        $k = $Joules / $old
        $st.wbal.wPrime = $Joules
        $st.wbal.value = [double]$st.wbal.value * $k
        $st.wbal.lowest = [double]$st.wbal.lowest * $k
    }

    function Update-ForceLabels {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $ftpLabelText = $(if ($st.ftpForced -gt 0) { "$([int]$st.ftpForced) W SET" } else { "AUTO $([int][math]::Round((Get-AutoFtp))) W" })
        if (-not $forceFtpLabel.IsKeyboardFocused -and $forceFtpLabel.Text -ne $ftpLabelText) { $forceFtpLabel.Text = $ftpLabelText }
        $autoW = $(if ($wProfile) { ([double]$wProfile.wPrime / 1000).ToString('0.0', $inv) + ' kJ' } else { 'none yet' })
        $wLabelText = $(if ($st.wForced -gt 0) { ([double]$st.wForced / 1000).ToString('0.0', $inv) + ' kJ SET' } else { "AUTO $autoW" })
        if (-not $forceWLabel.IsKeyboardFocused -and $forceWLabel.Text -ne $wLabelText) { $forceWLabel.Text = $wLabelText }
        $cpLabelText = $(if ($st.cpForced -gt 0) { "$([int]$st.cpForced) W SET" } elseif ($wProfile) { "AUTO $([int][double]$wProfile.cp) W" } else { 'AUTO = FTP' })
        if (-not $forceCpLabel.IsKeyboardFocused -and $forceCpLabel.Text -ne $cpLabelText) { $forceCpLabel.Text = $cpLabelText }
        $forceCpLabel.Foreground = $(if ($st.cpForced -gt 0) { $wbalOrange } else { [Windows.Media.Brushes]::White })
        $forceFtpLabel.Foreground = $(if ($st.ftpForced -gt 0) { $wbalOrange } else { [Windows.Media.Brushes]::White })
        $forceWLabel.Foreground = $(if ($st.wForced -gt 0) { $wbalOrange } else { [Windows.Media.Brushes]::White })
    }

    function Step-ForcedFtp([int]$Direction) {
        $from = $(if ($st.ftpForced -gt 0) { [double]$st.ftpForced } else { [math]::Round((Get-AutoFtp)) })
        $st.ftpForced = [math]::Max(50, [math]::Min(1000, $from + $Direction))
        Update-ForceLabels
        Show-BrakeScore
    }

    function Step-ForcedWPrime([int]$Direction) {
        $auto = $(if ($wProfile) { [double]$wProfile.wPrime } else { 20000.0 })
        $from = $(if ($st.wForced -gt 0) { [double]$st.wForced } else { 100 * [math]::Round($auto / 100) })
        $st.wForced = [math]::Max(5000, [math]::Min(60000, $from + 100 * $Direction))
        Set-WPrimeUsed $st.wForced
        Update-ForceLabels
    }

    function Step-ForcedCp([int]$Direction) {
        $auto = $(if ($wProfile) { [double]$wProfile.cp } else { Get-OwnFtp })
        $from = $(if ($st.cpForced -gt 0) { [double]$st.cpForced } else { [math]::Round($auto) })
        $st.cpForced = [math]::Max(50, [math]::Min(1000, $from + $Direction))
        Update-ForceLabels
    }

    # ---- tabs ----
    $st.menuTab = 'display'
    function Set-MenuTab([string]$Name) {
        if ($Name -notin 'display', 'layout', 'rider', 'other') { $Name = 'display' }
        $st.menuTab = $Name
        foreach ($pair in @(@('display', 'TabDisplay'), @('layout', 'TabLayout'), @('rider', 'TabRider'), @('other', 'TabOther'))) {
            $menu.FindName($pair[1]).Visibility = $(if ($pair[0] -eq $Name) { 'Visible' } else { 'Collapsed' })
        }
        foreach ($button in $menu.FindName('TabGrid').Children) {
            $on = ([string]$button.Tag -eq $Name)
            $button.FontWeight = $(if ($on) { 'Bold' } else { 'Normal' })
            $button.Foreground = $(if ($on) { $partActiveBrush } else { $moveBrush })
        }
    }

    # ---- layout profiles: each keeps its displayed items, layout, parts, block sizes, position and background ----
    $st.profiles = [ordered]@{}
    $st.profile = ''
    $st.applyingProfile = $false
    function Get-LayoutSnapshot {
        $extra = @()
        foreach ($part in $parts) {
            if ($part.id -eq 0) { continue }
            if ($part.active) { $r = Get-WindowBounds $part.hwnd; $part.x = [int]$r.Left; $part.y = [int]$r.Top }
            $extra += @{ x = $part.x; y = $part.y; width = $part.width; height = $part.height; order = @($part.panel.GetOrder()) }
        }
        $full = @(); $beside = @(); $grow = @()
        foreach ($part in $parts) { $full += @($part.panel.GetFullKeys()); $beside += @($part.panel.GetBesideKeys()); $grow += @($part.panel.GetGrowList()) }
        $display = @{}
        foreach ($key in @($st.display.Keys)) { $display[$key] = [bool]$st.display[$key] }
        $main = Get-WindowBounds $st.hwnd
        return @{ display = $display; partCount = $st.partCount; extra = $extra; order = @($blocks.GetOrder()); fullRow = $full; besideRow = $beside; blockSize = $grow
                  width = $parts[0].width; height = $parts[0].height; preset = $st.preset; x = [int]$main.Left; y = [int]$main.Top; bgOpacity = $st.bgOpacity }
    }

    function Use-LayoutProfile($Saved) {
        $st.applyingProfile = $true
        try {
            foreach ($item in $displayItems) { $value = $Saved.display.($item.key); if ($null -ne $value) { $st.display[$item.key] = [bool]$value } }
            foreach ($part in $parts) { if ($part.id -gt 0) { $part.panel.MoveAllTo($blocks) } }
            $count = [math]::Max(1, [math]::Min(3, [int]$Saved.partCount))
            $extras = @($Saved.extra)
            for ($i = 1; $i -lt $parts.Count; $i++) {
                $part = $parts[$i]
                if ($i -lt $count) {
                    $one = $(if ($i - 1 -lt $extras.Count) { $extras[$i - 1] } else { $null })
                    if ($one) {
                        if ($null -ne $one.x) { $part.x = [int]$one.x }
                        if ($null -ne $one.y) { $part.y = [int]$one.y }
                        if ($one.width) { $part.width = [double]$one.width }
                        if ($one.height) { $part.height = [double]$one.height }
                        foreach ($key in @($one.order)) { if ($key) { $blocks.MoveBlockTo([string]$key, $part.panel) } }
                        $part.panel.SetOrder([string[]]@($one.order | Where-Object { $_ }))
                    }
                    if ($part.active) {
                        Set-PartSize $part $part.width $part.height
                        [void][TpvNative]::SetWindowPos($part.hwnd, [IntPtr](-1), [int]$part.x, [int]$part.y, 0, 0, 0x0011)
                    } else { Show-Part $part }
                } elseif ($part.active) {
                    $part.active = $false
                    $part.window.Hide()
                }
            }
            $st.partCount = $count
            if ($Saved.order) { $blocks.SetOrder([string[]]@($Saved.order)) }
            foreach ($one in $parts) {
                $one.panel.SetFullKeys([string[]]@($Saved.fullRow | Where-Object { $_ }))
                $one.panel.SetBesideKeys([string[]]@($Saved.besideRow | Where-Object { $_ }))
                $one.panel.SetGrowList([string[]]@($Saved.blockSize | Where-Object { $_ }))
            }
            if ($Saved.width -and $Saved.height) { Set-PartSize $parts[0] ([double]$Saved.width) ([double]$Saved.height) }
            if ($null -ne $Saved.bgOpacity) { Set-BackgroundOpacity ([int]$Saved.bgOpacity) }
            $st.preset = $(if ($Saved.preset) { [string]$Saved.preset } else { $null })
            if (-not $st.preset -and $null -ne $Saved.x -and $null -ne $Saved.y) { Set-WidgetPosition ([int]$Saved.x) ([int]$Saved.y); Save-WidgetPosition }
            foreach ($grid in $displayList.Children) {
                if ($grid -isnot [Windows.Controls.Primitives.UniformGrid]) { continue }
                foreach ($box in $grid.Children) { $box.IsChecked = [bool]$st.display[[string]$box.Tag] }
            }
            Update-PartButtons
            Set-DisplayLayout
            Update-SizeLabel
        } finally { $st.applyingProfile = $false }
    }

    function Update-ProfileButtons {
        foreach ($button in $menu.FindName('ProfileGrid').Children) {
            $on = ([string]$button.Tag -eq [string]$st.profile)
            $button.FontWeight = $(if ($on) { 'Bold' } else { 'Normal' })
            $button.Foreground = $(if ($on) { $partActiveBrush } else { $moveBrush })
        }
        $menu.FindName('ProfileHint').Text = $(if ($st.profile) { "Profile $($st.profile): your changes are kept in it." } else { 'No profile: choose one to keep a layout for races, climbs, streams...' })
    }

    # The profile left keeps the layout as it is now; an empty profile starts from the current layout.
    function Select-LayoutProfile([string]$Name) {
        if ($st.profile -and $st.profile -ne $Name) { $st.profiles[$st.profile] = Get-LayoutSnapshot }
        if ($Name -and $st.profiles.Contains($Name)) { Use-LayoutProfile $st.profiles[$Name] }
        $st.profile = $Name
        if ($Name -and -not $st.profiles.Contains($Name)) { $st.profiles[$Name] = Get-LayoutSnapshot }
        Update-ProfileButtons
        Save-WidgetSettings
    }

    # ---- typed rider values ----
    function Enable-MenuTyping {
        if (-not $st.menuHwnd -or $st.menuTyping) { return }
        $st.menuTyping = $true
        $style = [int64][TpvNative]::GetWindowLongPtr($st.menuHwnd, -20) -band (-bnot [int64]0x8000000)
        [void][TpvNative]::SetWindowLongPtr($st.menuHwnd, -20, [IntPtr]$style)
        [void]$menu.Activate()
    }
    function Disable-MenuTyping {
        if (-not $st.menuTyping) { return }
        $st.menuTyping = $false
        Set-ToolWindow $st.menuHwnd
    }
    function Get-RiderValueText([string]$Which) {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        switch ($Which) {
            'ftp' { return ([int][math]::Round((Get-OwnFtp))).ToString($inv) }
            'cp' { return ([int][math]::Round((Get-CpUsed))).ToString($inv) }
            'w' { $j = $(if ($st.wbal) { [double]$st.wbal.wPrime } elseif ($wProfile) { [double]$wProfile.wPrime } else { 20000.0 }); return ($j / 1000).ToString('0.0', $inv) }
        }
    }
    # Accepts "390", "390 W", "31", "31.5", "31,5 kJ" or "31000": out of range or unreadable keeps the value as it was.
    function Set-RiderValue([string]$Which, [string]$Text) {
        $clean = ($Text -replace '[^\d.,]', '').Replace(',', '.')
        $value = 0.0
        if ([double]::TryParse($clean, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
            switch ($Which) {
                'ftp' { if ($value -ge 50 -and $value -le 1000) { $st.ftpForced = [math]::Round($value); Show-BrakeScore } }
                'cp' { if ($value -ge 50 -and $value -le 1000) { $st.cpForced = [math]::Round($value) } }
                'w' {
                    $joules = $(if ($value -lt 100) { $value * 1000 } else { $value })
                    if ($joules -ge 5000 -and $joules -le 60000) { $st.wForced = [math]::Round($joules / 100) * 100; Set-WPrimeUsed $st.wForced }
                }
            }
        }
        Update-ForceLabels
        Save-WidgetSettings
    }

    function Read-WidgetSettings {
        # Shown at first start; a setting saved later always wins.
        $firstStart = 'wbalgauge', 'power30', 'wkg', 'vam', 'draft', 'brake', 'coach', 'climb', 'routechart', 'alerts', 'jokes', 'wbaltalk', 'music', 'musictitle', 'winddial', 'attack', 'groups', 'pull', 'team'
        foreach ($item in $displayItems) { $st.display[$item.key] = ($firstStart -contains $item.key) }
        $saved = Read-JsonSafely $settingsPath
        if (-not $saved) { return }
        try {
            foreach ($item in $displayItems) {
                $value = $saved.display.($item.key)
                if ($null -ne $value) { $st.display[$item.key] = [bool]$value }
            }
            if ($null -ne $saved.vamRefresh -and [double]$saved.vamRefresh -ge 0 -and [double]$saved.vamRefresh -le 60) { $st.vamRefresh = [double]$saved.vamRefresh }
            if ($null -ne $saved.ftpForced -and [double]$saved.ftpForced -ge 50 -and [double]$saved.ftpForced -le 1000) { $st.ftpForced = [double]$saved.ftpForced }
            if ($null -ne $saved.cpForced -and [double]$saved.cpForced -ge 50 -and [double]$saved.cpForced -le 1000) { $st.cpForced = [double]$saved.cpForced }
            if ($null -ne $saved.wForced -and [double]$saved.wForced -ge 5000 -and [double]$saved.wForced -le 60000) { $st.wForced = [double]$saved.wForced }
            if ($null -ne $saved.emptyRefresh -and [double]$saved.emptyRefresh -ge 0 -and [double]$saved.emptyRefresh -le 30) { $st.emptyRefresh = [double]$saved.emptyRefresh }
            if ($null -ne $saved.alertScale -and [double]$saved.alertScale -ge 0.4 -and [double]$saved.alertScale -le 3) { $st.alertScale = [double]$saved.alertScale }
            if ($null -ne $saved.alertX -and [double]$saved.alertX -ge -1 -and [double]$saved.alertX -le 2) { $st.alertX = [double]$saved.alertX }
            if ($null -ne $saved.alertCenterY -and [double]$saved.alertCenterY -ge -1 -and [double]$saved.alertCenterY -le 2) { $st.alertY = [double]$saved.alertCenterY }
            elseif ($null -ne $saved.alertY -and [double]$saved.alertY -ge 0 -and [double]$saved.alertY -le 1) { $st.alertY = [math]::Min(1.0, [double]$saved.alertY + 0.06) }
            if ($null -ne $saved.routeSpan -and [double]$saved.routeSpan -ge 500 -and [double]$saved.routeSpan -le 20000) { $st.routeSpan = [double]$saved.routeSpan }
            if ($null -ne $saved.bgOpacity -and [int]$saved.bgOpacity -ge 30 -and [int]$saved.bgOpacity -le 100) { $st.bgOpacity = [int]$saved.bgOpacity }
            if ($saved.preset) { $st.preset = [string]$saved.preset }
            if ($saved.profiles) { foreach ($property in $saved.profiles.PSObject.Properties) { $st.profiles[$property.Name] = $property.Value } }
            if ($saved.profile) { $st.profile = [string]$saved.profile }
            if ($saved.menuTab) { $st.menuTab = [string]$saved.menuTab }
            if ($saved.scale) { $st.scale = [double]$saved.scale }
            if ($saved.width) { $parts[0].width = [double]$saved.width }
            if ($saved.height) { $parts[0].height = [double]$saved.height }
            if ($saved.partCount) { $st.partCount = [math]::Max(1, [math]::Min(3, [int]$saved.partCount)) }
            $savedParts = @($saved.extra)
            for ($i = 1; $i -lt $st.partCount -and $i -le $savedParts.Count; $i++) {
                $one = $savedParts[$i - 1]
                if ($null -eq $one) { continue }
                if ($null -ne $one.x) { $parts[$i].x = [int]$one.x }
                if ($null -ne $one.y) { $parts[$i].y = [int]$one.y }
                if ($one.width) { $parts[$i].width = [double]$one.width }
                if ($one.height) { $parts[$i].height = [double]$one.height }
                foreach ($key in @($one.order)) { if ($key) { $blocks.MoveBlockTo([string]$key, $parts[$i].panel) } }
                $parts[$i].panel.SetOrder([string[]]@($one.order | Where-Object { $_ }))
            }
            if ($null -eq $saved.display.wbalchart) {
                $st.chartsAdded = $true
                $st.partCount = 3
                foreach ($key in 'wbalchart', 'powerchart', 'routechart') { $blocks.MoveBlockTo($key, $parts[2].panel) }
                if (-not $parts[2].width) { $parts[2].width = 420 }
                if (-not $parts[2].height) { $parts[2].height = 430 }
            }
            if ($saved.order) { $blocks.SetOrder([string[]]@($saved.order)) }
            if ($null -eq $saved.display.wdrop) {
                foreach ($one in $parts) {
                    $keys = @($one.panel.GetOrder() | Where-Object { $_ -ne 'wdrop' })
                    $at = [array]::IndexOf([string[]]$keys, 'wbalmin')
                    if ($at -lt 0) { continue }
                    $blocks.MoveBlockTo('wdrop', $one.panel)
                    $sorted = @($keys[0..$at]) + 'wdrop'
                    if ($at + 1 -lt $keys.Count) { $sorted += @($keys[($at + 1)..($keys.Count - 1)]) }
                    $one.panel.SetOrder([string[]]$sorted)
                    break
                }
            }
            if ($null -eq $saved.display.wbalgauge) {
                $st.chartsAdded = $true
                foreach ($one in $parts) {
                    $keys = @($one.panel.GetOrder() | Where-Object { $_ -ne 'wbalgauge' })
                    $at = [array]::IndexOf([string[]]$keys, 'wbal')
                    if ($at -lt 0) { continue }
                    $blocks.MoveBlockTo('wbalgauge', $one.panel)
                    $sorted = @()
                    if ($at -gt 0) { $sorted += @($keys[0..($at - 1)]) }
                    $sorted += 'wbalgauge'
                    $sorted += @($keys[$at..($keys.Count - 1)])
                    $one.panel.SetOrder([string[]]$sorted)
                    break
                }
                foreach ($key in 'wbal', 'wbalmin', 'wdrop') { $st.display[$key] = $false }
            }
            # The first time, each dial is placed next to the values it groups, still hidden.
            foreach ($placement in @(@('powerdial', 'power30'), @('draftdial', 'draft'))) {
                if ($null -ne $saved.display.($placement[0])) { continue }
                $st.chartsAdded = $true
                foreach ($one in $parts) {
                    $keys = @($one.panel.GetOrder() | Where-Object { $_ -ne $placement[0] })
                    $at = [array]::IndexOf([string[]]$keys, $placement[1])
                    if ($at -lt 0) { continue }
                    $blocks.MoveBlockTo($placement[0], $one.panel)
                    $sorted = @()
                    if ($at -gt 0) { $sorted += @($keys[0..($at - 1)]) }
                    $sorted += $placement[0]
                    $sorted += @($keys[$at..($keys.Count - 1)])
                    $one.panel.SetOrder([string[]]$sorted)
                    break
                }
            }
            if ($saved.fullRow) { foreach ($one in $parts) { $one.panel.SetFullKeys([string[]]@($saved.fullRow)) } }
            if ($saved.besideRow) { foreach ($one in $parts) { $one.panel.SetBesideKeys([string[]]@($saved.besideRow)) } }
            if ($saved.blockSize) { foreach ($one in $parts) { $one.panel.SetGrowList([string[]]@($saved.blockSize)) } }
        } catch { <# Unreadable settings: keep the defaults. #> }
    }

    function Save-WidgetSettings {
        if ($st.applyingProfile) { return }
        if ($st.profile) { $st.profiles[$st.profile] = Get-LayoutSnapshot }
        $extra = @()
        foreach ($part in $parts) {
            if ($part.id -eq 0) { continue }
            if ($part.active) {
                $r = Get-WindowBounds $part.hwnd
                $part.x = [int]$r.Left
                $part.y = [int]$r.Top
            }
            $extra += @{ x = $part.x; y = $part.y; width = $part.width; height = $part.height; order = @($part.panel.GetOrder()) }
        }
        $fullRow = @()
        $besideRow = @()
        $blockSize = @()
        foreach ($part in $parts) { $fullRow += @($part.panel.GetFullKeys()); $besideRow += @($part.panel.GetBesideKeys()); $blockSize += @($part.panel.GetGrowList()) }
        $json = @{ profiles = $st.profiles; profile = $st.profile; menuTab = $st.menuTab; blockSize = $blockSize; ftpForced = $st.ftpForced; wForced = $st.wForced; cpForced = $st.cpForced; emptyRefresh = $st.emptyRefresh; alertX = $st.alertX; alertCenterY = $st.alertY; alertScale = $st.alertScale; routeSpan = $st.routeSpan; bgOpacity = $st.bgOpacity; vamRefresh = $st.vamRefresh; fullRow = $fullRow; besideRow = $besideRow; display = $st.display; preset = $st.preset; width = $parts[0].width; height = $parts[0].height; order = @($blocks.GetOrder()); partCount = $st.partCount; extra = $extra } | ConvertTo-Json -Depth 8
        Write-FileSafely $settingsPath $json
    }

    function Set-DisplayLayout {
        # Room for the fixed-size menu button.
        $ui.RiderText.Margin = [Windows.Thickness]::new(0, 0, 24, 0)
        foreach ($item in $blockItems) {
            $ui[$item[1]].Visibility = $(if ($st.display[$item[0]]) { 'Visible' } else { 'Collapsed' })
        }
        foreach ($part in $parts) { if ($part.active) { $part.panel.Refresh() } }
        Update-PanelVisibility
        $window.UpdateLayout()
        if ($st.preset) {
            Move-WidgetToPreset $st.preset
        } else {
            # A larger widget must stay inside the screen.
            $r = Get-WindowBounds $st.hwnd
            $area = [Windows.Forms.Screen]::FromHandle($st.hwnd).WorkingArea
            # Also brings it back when the screen it was saved on is no longer connected.
            $x = [math]::Max([int]$area.Left, [math]::Min([int]($area.Right - ($r.Right - $r.Left)), [int]$r.Left))
            $y = [math]::Max([int]$area.Top, [math]::Min([int]($area.Bottom - ($r.Bottom - $r.Top)), [int]$r.Top))
            Set-WidgetPosition $x $y
        }
        Set-PartsOnScreen
    }

    function Reset-WidgetStats {
        Reset-BrakeScore $st.score
        Reset-CoachSession $st.coach
        if ($st.wbal) { Reset-WBal $st.wbal }
        Reset-RideStats $st.ride
        Reset-Tactics $st.tactics
        $wbalChart.Clear()
        $powerChart.Clear()
        Show-BrakeScore
    }

    $handle.add_SourceInitialized({
        $st.handleHwnd = (New-Object Windows.Interop.WindowInteropHelper($handle)).Handle
        Set-ToolWindow $st.handleHwnd
    })
    $menu.add_SourceInitialized({
        $st.menuHwnd = (New-Object Windows.Interop.WindowInteropHelper($menu)).Handle
        Set-ToolWindow $st.menuHwnd
    })

    $handleButton.add_PreviewMouseLeftButtonDown({
        $c = New-Object TpvNative+POINT
        [void][TpvNative]::GetCursorPos([ref]$c)
        $r = Get-WindowBounds $st.hwnd
        $st.drag = @{ startX = $c.X; startY = $c.Y; windowX = $r.Left; windowY = $r.Top; moved = $false }
    })
    $handleButton.add_PreviewMouseMove({
        if ($st.drag -and $args[1].LeftButton -eq 'Pressed') {
            $c = New-Object TpvNative+POINT
            [void][TpvNative]::GetCursorPos([ref]$c)
            $dx = $c.X - $st.drag.startX
            $dy = $c.Y - $st.drag.startY
            if ($st.drag.moved -or [math]::Abs($dx) -gt 3 -or [math]::Abs($dy) -gt 3) {
                $st.drag.moved = $true
                Set-WidgetPosition ($st.drag.windowX + $dx) ($st.drag.windowY + $dy)
            }
        }
    })
    $handleButton.add_PreviewMouseLeftButtonUp({
        if ($st.drag -and $st.drag.moved) {
            # A free position replaces the preset.
            $st.preset = $null
            Save-WidgetPosition
            Save-WidgetSettings
            # A drag must not also count as a click that opens the menu.
            $args[1].Handled = $true
            $handleButton.ReleaseMouseCapture()
        }
        $st.drag = $null
    })
    $menu.FindName('CloseMenuButton').add_Click({ $menu.Hide() })
    $handleButton.add_Click({
        if ($menu.Visibility -eq 'Visible') {
            $menu.Hide()
        } else {
            # The whole menu stays reachable on a small screen: it scrolls instead.
            $menu.MaxHeight = [Windows.Forms.Screen]::FromHandle($st.handleHwnd).WorkingArea.Height / $st.dpi - 8
            $menu.Show()
            Set-MenuPosition
        }
    })

    foreach ($presetButton in $menu.FindName('PresetGrid').Children) {
        $presetButton.add_Click({
            Move-WidgetToPreset ([string]$args[0].Tag)
            $menu.Hide()
        })
    }
    [xml]$partXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Widget part" Width="320" Height="240"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False" ResizeMode="NoResize"
        FontFamily="Segoe UI" Foreground="#FFFFFF">
  <Border x:Name="Root" CornerRadius="10" BorderThickness="1.5" BorderBrush="#804F76F5">
    <Border.Background>
      <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
        <GradientStop Color="#E0122A78" Offset="0"/>
        <GradientStop Color="#E00B1A52" Offset="0.55"/>
        <GradientStop Color="#E03A2358" Offset="1"/>
      </LinearGradientBrush>
    </Border.Background>
    <Grid>
      <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <Border x:Name="Bar" Background="#D91C3490" CornerRadius="8.5,8.5,0,0" Height="24" Padding="10,0" Visibility="Collapsed">
        <TextBlock x:Name="BarText" FontSize="11" FontWeight="Bold" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
      </Border>
      <Grid x:Name="PartHost" Grid.Row="1" Margin="5"/>
    </Grid>
  </Border>
</Window>
"@
    $partActiveBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#FFD34D')
    $partsGrid = $menu.FindName('PartsGrid')
    $vamRefreshGrid = $menu.FindName('VamRefreshGrid')
    $vamRefreshLabel = $menu.FindName('VamRefreshLabel')
    $bgLabel = $menu.FindName('BgLabel')
    $spanLabel = $menu.FindName('SpanLabel')
    $bannerLabel = $menu.FindName('BannerLabel')
    $emptyLabel = $menu.FindName('EmptyLabel')
    $st.emptyRefresh = 1.0
    $st.routeSpan = 5000
    $st.bgOpacity = 90
    $st.vamRefresh = 0.0
    $st.vamShownAt = $null
    $st.vamShownRider = $null
    $parts = @(@{ id = 0; window = $window; root = $ui.Panel; panel = $blocks; bar = $null; hwnd = [IntPtr]::Zero; active = $true; x = $null; y = $null; width = $null; height = $null; minW = 220; minH = 150; chromeW = 17; chromeH = 43; top = 33 })
    foreach ($id in 1..2) {
        $partWindow = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $partXaml))
        $partWindow.Title = "Widget part $($id + 1)"
        $partWindow.FindName('BarText').Text = "PART $($id + 1)  |  drag  |  double-click = full row  |  right-click gauge/graph = 2 per line"
        $partPanel = New-Object TpvBlockPanel
        [void]$partWindow.FindName('PartHost').Children.Add($partPanel)
        $partHwnd = (New-Object Windows.Interop.WindowInteropHelper($partWindow)).EnsureHandle()
        Set-ClickThrough $true $partHwnd
        $parts += @{ id = $id; window = $partWindow; root = $partWindow.FindName('Root'); panel = $partPanel; bar = $partWindow.FindName('Bar'); hwnd = $partHwnd; active = $false; x = $null; y = $null; width = $null; height = $null; minW = 160; minH = 90; chromeW = 13; chromeH = 13; top = 26 }
    }
    Read-WidgetSettings
    Update-VamRefreshButtons
    Set-BackgroundOpacity $st.bgOpacity
    Set-RouteSpan $st.routeSpan
    Set-AlertScale $st.alertScale
    Set-EmptyRefresh $st.emptyRefresh
    $forceFtpLabel = $menu.FindName('FtpLabel')
    $forceWLabel = $menu.FindName('WPrimeLabel')
    $forceCpLabel = $menu.FindName('CpLabel')
    if ($st.wForced -gt 0) { Set-WPrimeUsed $st.wForced }
    Update-ForceLabels
    $menu.FindName('FtpLessButton').add_Click({ Step-ForcedFtp -1 })
    $menu.FindName('FtpMoreButton').add_Click({ Step-ForcedFtp 1 })
    $menu.FindName('FtpAutoButton').add_Click({ $st.ftpForced = 0.0; Update-ForceLabels; Show-BrakeScore; Save-WidgetSettings })
    $menu.FindName('WPrimeLessButton').add_Click({ Step-ForcedWPrime -1 })
    $menu.FindName('WPrimeMoreButton').add_Click({ Step-ForcedWPrime 1 })
    $menu.FindName('WPrimeAutoButton').add_Click({ $st.wForced = 0.0; Set-WPrimeUsed 0; Update-ForceLabels; Save-WidgetSettings })
    $menu.FindName('CpLessButton').add_Click({ Step-ForcedCp -1 })
    $menu.FindName('AllAutoButton').add_Click({
        $st.ftpForced = 0.0; $st.wForced = 0.0; $st.cpForced = 0.0
        Set-WPrimeUsed 0
        Update-ForceLabels; Show-BrakeScore; Save-WidgetSettings
    })
    foreach ($typed in @(@('FtpLabel', 'ftp'), @('WPrimeLabel', 'w'), @('CpLabel', 'cp'))) {
        $box = $menu.FindName($typed[0])
        $box.Tag = $typed[1]
        # The menu never takes the keyboard from the game, except while a value is being typed.
        $box.add_PreviewMouseLeftButtonDown({
            if ($args[0].IsKeyboardFocused) { return }
            Enable-MenuTyping
            [void]$args[0].Focus()
            [void][Windows.Input.Keyboard]::Focus($args[0])
            $args[1].Handled = $true
        })
        $box.add_GotKeyboardFocus({ $args[0].Text = Get-RiderValueText ([string]$args[0].Tag); $args[0].SelectAll() })
        $box.add_PreviewKeyDown({
            if ($args[1].Key -eq 'Return') { $st.riderCommit = $true; [void][Windows.Input.Keyboard]::ClearFocus(); $args[1].Handled = $true }
            elseif ($args[1].Key -eq 'Escape') { $st.riderCommit = $false; [void][Windows.Input.Keyboard]::ClearFocus(); $args[1].Handled = $true }
        })
        $box.add_LostKeyboardFocus({
            $commit = $st.riderCommit -ne $false
            $st.riderCommit = $null
            if ($commit) { Set-RiderValue ([string]$args[0].Tag) $args[0].Text } else { Update-ForceLabels }
            Disable-MenuTyping
        })
    }
    $menu.add_IsVisibleChanged({ if (-not $menu.IsVisible) { [void][Windows.Input.Keyboard]::ClearFocus(); Disable-MenuTyping } })
    foreach ($tabButton in $menu.FindName('TabGrid').Children) { $tabButton.add_Click({ Set-MenuTab ([string]$args[0].Tag); Save-WidgetSettings }) }
    foreach ($profileButton in $menu.FindName('ProfileGrid').Children) { $profileButton.add_Click({ Select-LayoutProfile ([string]$args[0].Tag) }) }
    Set-MenuTab $st.menuTab
    Update-ProfileButtons
    $menu.FindName('CpMoreButton').add_Click({ Step-ForcedCp 1 })
    $menu.FindName('CpAutoButton').add_Click({ $st.cpForced = 0.0; Update-ForceLabels; Save-WidgetSettings })
    foreach ($forceStep in 'FtpLessButton', 'FtpMoreButton', 'WPrimeLessButton', 'WPrimeMoreButton', 'CpLessButton', 'CpMoreButton') { $menu.FindName($forceStep).add_PreviewMouseLeftButtonUp({ Save-WidgetSettings }) }
    $menu.FindName('EmptyLessButton').add_Click({ Step-EmptyRefresh -1 })
    $menu.FindName('EmptyMoreButton').add_Click({ Step-EmptyRefresh 1 })
    foreach ($emptyStep in 'EmptyLessButton', 'EmptyMoreButton') { $menu.FindName($emptyStep).add_PreviewMouseLeftButtonUp({ Save-WidgetSettings }) }
    $menu.FindName('BannerLessButton').add_Click({ Set-AlertScale ($st.alertScale - 0.1) })
    $menu.FindName('BannerMoreButton').add_Click({ Set-AlertScale ($st.alertScale + 0.1) })
    foreach ($bannerStep in 'BannerLessButton', 'BannerMoreButton') { $menu.FindName($bannerStep).add_PreviewMouseLeftButtonUp({ Save-WidgetSettings }) }
    $alert.add_MouseLeftButtonDown({
        if (-not $st.move) { return }
        $st.editSeen = Get-Date
        try { $alert.DragMove() } catch { }
        Save-AlertPlacement
    })
    foreach ($sizeButton in @(@('AlertSmaller', -0.1), @('AlertLarger', 0.1))) {
        $alert.FindName($sizeButton[0]).Tag = $sizeButton[1]
        $alert.FindName($sizeButton[0]).add_Click({
            if (-not $st.move) { return }
            $st.editSeen = Get-Date
            Set-AlertScale ($st.alertScale + [double]$args[0].Tag)
            Save-WidgetSettings
        })
    }
    $alert.add_MouseWheel({        if (-not $st.move) { return }
        $st.editSeen = Get-Date
        Set-AlertScale ($st.alertScale + $(if ($args[1].Delta -gt 0) { 0.1 } else { -0.1 }))
        Save-WidgetSettings
    })
    $menu.FindName('SpanLessButton').add_Click({ Step-RouteSpan -1 })
    $menu.FindName('SpanMoreButton').add_Click({ Step-RouteSpan 1 })
    foreach ($spanStep in 'SpanLessButton', 'SpanMoreButton') { $menu.FindName($spanStep).add_PreviewMouseLeftButtonUp({ Save-WidgetSettings }) }
    $menu.FindName('BgLessButton').add_Click({ Set-BackgroundOpacity ($st.bgOpacity - 10) })
    $menu.FindName('BgMoreButton').add_Click({ Set-BackgroundOpacity ($st.bgOpacity + 10) })
    foreach ($bgStep in 'BgLessButton', 'BgMoreButton') { $menu.FindName($bgStep).add_PreviewMouseLeftButtonUp({ Save-WidgetSettings }) }
    foreach ($vamButton in $vamRefreshGrid.Children) {
        $vamButton.add_Click({
            Set-VamRefresh ([double]$args[0].Tag)
            Save-WidgetSettings
        })
    }
    $menu.FindName('VamSlowerButton').add_Click({ Step-VamRefresh -1 })
    $menu.FindName('VamFasterButton').add_Click({ Step-VamRefresh 1 })
    # Saved when the button is released, so that holding it does not write the file repeatedly.
    foreach ($vamStep in 'VamSlowerButton', 'VamFasterButton') { $menu.FindName($vamStep).add_PreviewMouseLeftButtonUp({ Save-WidgetSettings }) }
    $displayList = $menu.FindName('DisplayList')
    $menuGroup = $null
    $groupGrid = $null
    $groupBrush = [Windows.Media.BrushConverter]::new().ConvertFromString('#9DBBFF')
    foreach ($item in $displayItems) {
        if ($item.group -ne $menuGroup) {
            $menuGroup = $item.group
            $groupTitle = New-Object Windows.Controls.TextBlock
            $groupTitle.Text = $menuGroup
            $groupTitle.FontSize = 10
            $groupTitle.FontWeight = 'Bold'
            $groupTitle.Foreground = $groupBrush
            $groupTitle.Margin = [Windows.Thickness]::new(2, 5, 0, 1)
            [void]$displayList.Children.Add($groupTitle)
            $groupGrid = New-Object Windows.Controls.Primitives.UniformGrid
            $groupGrid.Columns = 2
            [void]$displayList.Children.Add($groupGrid)
        }
        $box = New-Object Windows.Controls.CheckBox
        $box.Content = $item.label
        $box.Tag = $item.key
        $box.IsChecked = [bool]$st.display[$item.key]
        $onToggle = {
            if ($st.applyingProfile) { return }
            $st.display[[string]$args[0].Tag] = [bool]$args[0].IsChecked
            Set-DisplayLayout
            Save-WidgetSettings
        }
        $box.add_Checked($onToggle)
        $box.add_Unchecked($onToggle)
        [void]$groupGrid.Children.Add($box)
    }
    $scaleLabel = $menu.FindName('ScaleLabel')
    $editButton = $menu.FindName('EditButton')
    $editButton.add_Click({ Switch-EditMode; $menu.Hide() })
    foreach ($partButton in $partsGrid.Children) {
        $partButton.add_Click({
            $count = [int]$args[0].Tag
            Set-PartCount $count
            # A new part starts empty, so editing opens right away to fill it.
            if ($count -gt 1 -and -not $st.move) { Switch-EditMode }
            $menu.Hide()
        })
    }
    $menu.FindName('ResetLayoutButton').add_Click({ if (Test-Confirmed $args[0]) { Set-PartCount 1; $blocks.SetFullKeys([string[]]@()); foreach ($one in $parts) { $one.panel.SetGrowList([string[]]@()) }; $blocks.SetOrder($defaultOrder); Set-FittedHeight; Save-WidgetSettings } })
    $menu.FindName('SmallerButton').add_Click({ Resize-WidgetParts 0.9; Save-WidgetSettings })
    $menu.FindName('LargerButton').add_Click({ Resize-WidgetParts 1.1; Save-WidgetSettings })
    $menu.FindName('ResetSizeButton').add_Click({ Set-FittedHeight; Save-WidgetSettings })
    $toggleButton.add_Click({ Switch-WidgetVisibility })
    $menu.FindName('ResetButton').add_Click({ if (Test-Confirmed $args[0]) { Reset-WidgetStats; $menu.Hide() } })
    $menu.FindName('QuitButton').add_Click({ if (Test-Confirmed $args[0]) { $app.Shutdown() } })

    foreach ($mousePart in $parts) {
        $mousePart.window.add_PreviewMouseLeftButtonDown({
            if (-not $st.move) { return }
            $part = Get-PartOf $args[0]
            $p = $args[1].GetPosition($part.window)
            $zone = Get-EditZone $part.window $p
            if ($zone) {
                $c = Get-MouseScreen
                $r = Get-WindowBounds $part.hwnd
                $st.edit = @{ kind = 'size'; part = $part; source = $part; zone = $zone; x = $c.X; y = $c.Y; left = $r.Left; top = $r.Top; right = $r.Right; bottom = $r.Bottom }
                [void]$part.window.CaptureMouse()
            } elseif ($p.Y -lt $part.top) {
                $part.window.DragMove()
                Set-PartSnapped $part
                if ($part.id -eq 0) {
                    $st.preset = $null
                    Set-AttachedPosition
                    Save-WidgetPosition
                }
                Save-WidgetSettings
            } elseif (($badgeHit = $part.panel.HitBadge($args[1].GetPosition($part.panel))) -ne 0) {
                # The size badge of the block under the mouse.
                if ($part.panel.StepBadge($badgeHit)) { Save-WidgetSettings }
            } elseif ($args[1].ClickCount -eq 2) {
                if ($part.panel.ToggleFullAt($args[1].GetPosition($part.panel))) { Save-WidgetSettings }
            } elseif ($part.panel.BeginDrag($args[1].GetPosition($part.panel))) {
                $st.edit = @{ kind = 'block'; part = $part; source = $part }
                [void]$part.window.CaptureMouse()
            }
            $args[1].Handled = $true
        })
        $mousePart.window.add_PreviewMouseRightButtonDown({
            if (-not $st.move -or $st.edit) { return }
            $st.editSeen = Get-Date
            $part = Get-PartOf $args[0]
            Switch-GraphPair $part $args[1].GetPosition($part.panel)
            $args[1].Handled = $true
        })
        $mousePart.window.add_PreviewMouseMove({
            if (-not $st.move) { return }
            $st.editSeen = Get-Date
            if (-not $st.edit) {
                $part = Get-PartOf $args[0]
                $zone = Get-EditZone $part.window $args[1].GetPosition($part.window)
                if ($zone) { $part.panel.HideBadge() } else { $part.panel.ShowBadgeAt($args[1].GetPosition($part.panel)) }
                $part.window.Cursor = switch ($zone) {
                    { $_ -in 'T', 'B' } { [Windows.Input.Cursors]::SizeNS; break }
                    { $_ -in 'L', 'R' } { [Windows.Input.Cursors]::SizeWE; break }
                    { $_ -in 'TL', 'BR' } { [Windows.Input.Cursors]::SizeNWSE; break }
                    { $_ -in 'TR', 'BL' } { [Windows.Input.Cursors]::SizeNESW; break }
                    default { [Windows.Input.Cursors]::SizeAll }
                }
                return
            }
            $c = Get-MouseScreen
            $e = $st.edit
            if ($e.kind -eq 'block') {
                # The block follows the cursor into whichever part it is over.
                $over = Get-PartAt $c
                if ($over -and $over.id -ne $e.part.id) {
                    $over.panel.AdoptDrag($e.part.panel, $over.panel.PointFromScreen($c))
                    $e.part = $over
                }
                $e.part.panel.DragTo($e.part.panel.PointFromScreen($c))
                return
            }
            $minW = [int]($e.part.minW * $st.dpi); $minH = [int]($e.part.minH * $st.dpi)
            $l = $e.left; $t = $e.top; $rr = $e.right; $b = $e.bottom
            if ($e.zone -match 'L') { $l = [math]::Min($e.left + $c.X - $e.x, $e.right - $minW) }
            if ($e.zone -match 'R') { $rr = [math]::Max($e.right + $c.X - $e.x, $e.left + $minW) }
            if ($e.zone -match 'T') { $t = [math]::Min($e.top + $c.Y - $e.y, $e.bottom - $minH) }
            if ($e.zone -match 'B') { $b = [math]::Max($e.bottom + $c.Y - $e.y, $e.top + $minH) }
            [void][TpvNative]::SetWindowPos($e.part.hwnd, [IntPtr]::Zero, [int]$l, [int]$t, [int]($rr - $l), [int]($b - $t), 0x0014)
            if ($e.part.id -eq 0) { Set-AttachedPosition }
        })
        $mousePart.window.add_PreviewMouseLeftButtonUp({
            if (-not $st.edit) { return }
            Complete-LayoutEdit
            $args[1].Handled = $true
        })
        # Alt-Tab during a drag must not leave the widget stuck in the middle of it.
        $mousePart.window.add_LostMouseCapture({
            if ($st.edit -and [object]::ReferenceEquals($st.edit.source.window, $args[0])) { Complete-LayoutEdit }
        })
    }
    # Music: the media session Windows shows in its volume flyout (YouTube or YouTube Music in a browser,
    # Spotify...). Loaded only once the block or a shortcut is used. Nothing leaves the PC.
    $music = @{ loaded = $false; failed = $false; asTask = $null; propsType = $null; managerTask = $null; manager = $null; propsTask = $null; propsAt = [datetime]::MinValue; title = ''; artist = ''; session = '' }
    $musicPlayGlyph = [string][char]0xE768
    $musicPauseGlyph = [string][char]0xE769
    $st.musicHotHwnd = [IntPtr]::Zero

    function Initialize-Music {
        if ($music.loaded -or $music.failed) { return }
        try {
            Add-Type -AssemblyName System.Runtime.WindowsRuntime
            $managerType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager,Windows.Media.Control,ContentType=WindowsRuntime]
            $music.propsType = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties,Windows.Media.Control,ContentType=WindowsRuntime]
            $music.asTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
            $music.managerTask = $music.asTask.MakeGenericMethod($managerType).Invoke($null, @($managerType::RequestAsync()))
            # Answers in a few milliseconds; waited for once so that the first shortcut already works.
            [void]$music.managerTask.Wait(1000)
            $music.loaded = $true
        } catch { $music.failed = $true }
    }

    function Get-MusicSession {
        Initialize-Music
        if ($music.failed) { return $null }
        if (-not $music.manager) {
            if (-not $music.managerTask -or -not $music.managerTask.IsCompleted) { return $null }
            if ($music.managerTask.IsFaulted) { $music.failed = $true; return $null }
            $music.manager = $music.managerTask.Result
        }
        try { return $music.manager.GetCurrentSession() } catch { return $null }
    }

    function Invoke-Music([string]$Action) {
        try {
            $session = Get-MusicSession
            if (-not $session) { return }
            # Not waited for: the widget never blocks on the player.
            switch ($Action) {
                'previous' { [void]$session.TrySkipPreviousAsync() }
                'toggle' { [void]$session.TryTogglePlayPauseAsync() }
                'next' { [void]$session.TrySkipNextAsync() }
            }
            $music.propsAt = [datetime]::MinValue
        } catch { }
    }

    function Update-Music {
        try {
            $session = Get-MusicSession
            if (-not $session) {
                $text = $(if ($music.failed) { 'Not available' } else { 'No music' })
                if ($ui.MusicText.Text -ne $text) { $ui.MusicText.Text = $text }
                $ui.MusicPlay.Content = $musicPlayGlyph
                return
            }
            $playing = ([string]$session.GetPlaybackInfo().PlaybackStatus) -eq 'Playing'
            $glyph = $(if ($playing) { $musicPauseGlyph } else { $musicPlayGlyph })
            if ([string]$ui.MusicPlay.Content -ne $glyph) { $ui.MusicPlay.Content = $glyph }
            $id = [string]$session.SourceAppUserModelId
            if ($music.propsTask) {
                if ($music.propsTask.IsCompleted) {
                    if (-not $music.propsTask.IsFaulted -and $music.propsTask.Result) {
                        $music.title = [string]$music.propsTask.Result.Title
                        $music.artist = [string]$music.propsTask.Result.Artist
                    }
                    $music.propsTask = $null
                }
            } elseif (((Get-Date) - $music.propsAt).TotalSeconds -ge 2 -or $id -ne $music.session) {
                if ($id -ne $music.session) { $music.title = ''; $music.artist = '' }
                $music.session = $id
                $music.propsAt = Get-Date
                $music.propsTask = $music.asTask.MakeGenericMethod($music.propsType).Invoke($null, @($session.TryGetMediaPropertiesAsync()))
            }
            if (-not $st.display['musictitle']) { $text = $(if ($playing) { 'Playing' } else { 'Paused' }) }
            elseif (-not $music.title) { $text = '--' }
            elseif ($music.artist) { $text = "$($music.title) - $($music.artist)" }
            else { $text = $music.title }
            if ($ui.MusicText.Text -ne $text) { $ui.MusicText.Text = $text }
        } catch { }
    }

    # The widget lets clicks through to the game; only the music buttons take them, while the mouse is on them.
    function Update-MusicHitTest {
        $want = $false
        $hwnd = [IntPtr]::Zero
        if (-not $st.move -and -not $st.hidden -and $st.display['music'] -and $ui.MusicButtons.IsVisible) {
            $source = [Windows.PresentationSource]::FromVisual($ui.MusicButtons)
            if ($source) {
                $hwnd = $source.Handle
                $a = $ui.MusicButtons.PointToScreen([Windows.Point]::new(0, 0))
                $b = $ui.MusicButtons.PointToScreen([Windows.Point]::new($ui.MusicButtons.ActualWidth, $ui.MusicButtons.ActualHeight))
                $c = Get-MouseScreen
                $want = $c.X -ge $a.X - 3 -and $c.X -le $b.X + 3 -and $c.Y -ge $a.Y - 3 -and $c.Y -le $b.Y + 3
            }
        }
        if ($st.musicHotHwnd -ne [IntPtr]::Zero -and (-not $want -or $hwnd -ne $st.musicHotHwnd)) {
            # Edit mode sets every window itself.
            if (-not $st.move) { Set-ClickThrough $true $st.musicHotHwnd }
            $st.musicHotHwnd = [IntPtr]::Zero
        }
        if ($want -and $st.musicHotHwnd -eq [IntPtr]::Zero) {
            Set-ClickThrough $false $hwnd
            $st.musicHotHwnd = $hwnd
        }
    }

    $ui.MusicPrev.add_Click({ if (-not $st.move) { Invoke-Music 'previous' } })
    $ui.MusicPlay.add_Click({ if (-not $st.move) { Invoke-Music 'toggle' } })
    $ui.MusicNext.add_Click({ if (-not $st.move) { Invoke-Music 'next' } })

    # The default Background priority starves the timer while frames are being rendered.
    $timer = New-Object Windows.Threading.DispatcherTimer ([Windows.Threading.DispatcherPriority]::Normal)
    $timer.Interval = [TimeSpan]::FromMilliseconds(50)
    $timer.add_Tick({
        $st.tick++
        if (Test-Hotkey 0x79) { $app.Shutdown(); return }
        if (Test-Hotkey 0x76) { Reset-WidgetStats }
        if (Test-Hotkey 0x78) { Switch-WidgetVisibility }
        if (Test-Hotkey 0x77) { Switch-EditMode }
        if (Test-Hotkey 0x70) { Invoke-Music 'previous' }
        if (Test-Hotkey 0x71) { Invoke-Music 'toggle' }
        if (Test-Hotkey 0x72) { Invoke-Music 'next' }
        if ($st.display['music']) {
            Update-MusicHitTest
            if ($st.tick % 10 -eq 5 -and -not $st.hidden) { Update-Music }
        }
        if ($st.move) {
            $esc = ([TpvNative]::GetAsyncKeyState(0x1B) -band 0x8000) -ne 0
            if ($esc -and -not $st.escDown) { Switch-EditMode }
            $st.escDown = $esc
            # Edit mode captures clicks, so it never stays on by accident.
            if ($st.move -and -not $st.edit -and $st.tick % 20 -eq 0 -and ((Get-Date) - $st.editSeen).TotalSeconds -ge 120) { Switch-EditMode }
        }
        if ($st.confirm -and (Get-Date) -ge $st.confirm.until) { Clear-Confirm }
        Update-Data
        if ($st.tick % 20 -eq 0 -and $st.lastFocus) { Update-RaceInfo $st.lastFocus }
        if ($st.tick % 20 -eq 10) { Sync-WbalPhrase }
        if ($st.tick % 20 -eq 15 -and $menu.IsVisible) { Update-ForceLabels }
        if ($st.tick % 20 -eq 5) {
            $settingsNow = "$($st.ftpForced)|$($st.wForced)|$($st.cpForced)|$($st.emptyRefresh)|$($st.alertScale)|$($st.routeSpan)|$($st.bgOpacity)|$($st.vamRefresh)"
            if ($null -eq $st.settingsSaved) { $st.settingsSaved = $settingsNow }
            elseif ($settingsNow -ne $st.settingsSaved) { $st.settingsSaved = $settingsNow; Save-WidgetSettings }
        }
        $brakeGauge.SetTarget($st.target)
        $draftGauge.SetTarget($st.draftTarget)
        if ($st.display['draftdial']) { $draftDial.SetValues([double](100 * $st.draftTarget), [double](100 * $st.target), [bool](-not $st.coach.realBrakeSeen)) }
        $wbalGauge.SetTarget($st.wbalTarget)
        # The game gives where the wind comes from, clockwise from the rider's heading, and its speed in mm/s.
        if ($st.display['winddial'] -and $st.tick % 2 -eq 0) {
            $f = $st.lastFocus
            if ($f -and $f.windAngle -is [ValueType] -and $f.windSpeed -is [ValueType]) { $windDial.SetValues([double]$f.windAngle, [double]$f.windSpeed / 1000) } else { $windDial.Clear() }
        }
    })

    Update-Data
    $window.Show()
    $alert.Show()
    $phrase.Show()
    $handle.Show()
    # Window.Show() applies its own default location, so place the widget afterwards.
    $startPosition = Get-StartPosition
    Set-WidgetPosition $startPosition[0] $startPosition[1]
    $st.dpi = [Windows.PresentationSource]::FromVisual($window).CompositionTarget.TransformToDevice.M11
    $parts[0].hwnd = $st.hwnd
    if (-not $parts[0].width) { $parts[0].width = 440 * $st.scale }
    Update-PartButtons
    Set-DisplayLayout
    if ($parts[0].height) {
        Set-PartSize $parts[0] $parts[0].width $parts[0].height
        Update-SizeLabel
        Set-DisplayLayout
    } else {
        $window.Width = $parts[0].width
        $window.UpdateLayout()
        Set-FittedHeight
    }
    foreach ($part in $parts) { if ($part.id -gt 0 -and $part.id -lt $st.partCount) { Show-Part $part } }
    Set-DisplayLayout
    if ($st.chartsAdded) { Save-WidgetSettings }
    $timer.Start()
    [void]$app.Run()
    $timer.Stop()
    Save-RouteProfile $st.profile $learnedRouteDirectory
    try { if ($roads.Dirty) { $roads.Save($roadPath) } } catch { }
    Save-CoachLibrary $st.coach $coachPath
} catch {
    $inner = $_.Exception.InnerException; $trace = $(if ($inner -and $inner.ErrorRecord) { $inner.ErrorRecord.ScriptStackTrace } else { $_.ScriptStackTrace })
    "error $(Get-Date -Format s): $($_ | Out-String)`n$trace" | Out-File -LiteralPath $logPath -Append -Encoding utf8
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
