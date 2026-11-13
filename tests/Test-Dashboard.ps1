param([string]$SnapshotPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Controller.ps1')
. (Join-Path $PSScriptRoot '..\src\DashboardModel.ps1')
$module=Join-Path $PSScriptRoot '..\src\Dashboard.ps1'
if (Test-Path $module) { . $module }
$count=0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:count++ }
Assert ([bool](Get-Command New-NetworkDashboard -ErrorAction SilentlyContinue)) 'A native dashboard must expose real command controls'
$queue=New-Object 'System.Collections.Generic.Queue[string]'
$ui=New-NetworkDashboard $queue
try {
    $state=New-ControllerState
    $model=Get-DashboardModel $null $state @() ''
    Update-NetworkDashboard $ui $model $state $true $false $false
    $click=[Windows.RoutedEventArgs]::new([Windows.Controls.Primitives.ButtonBase]::ClickEvent)
    $ui.Controls.CheckButton.RaiseEvent($click)
    Assert ($queue.Dequeue() -eq 'Check') 'Check button must reach the controller queue'
    $ui.Controls.AutoSwitch.IsChecked=$true
    $ui.Controls.AutoSwitch.RaiseEvent($click)
    Assert ($queue.Dequeue() -eq 'AutoOn') 'Auto switch must enqueue explicit enable rather than silently edit metrics'
    $ui.Controls.ReturnSwitch.IsChecked=$true
    $ui.Controls.ReturnSwitch.RaiseEvent($click)
    Assert ($queue.Dequeue() -eq 'RecoveryOn') 'Return switch must enqueue its explicit preference'
    Assert ($queue.Count -eq 0) 'Rendering state must never fabricate controller actions'
    $ui.Controls.WiredButton.IsEnabled=$true; $ui.Controls.WiredButton.RaiseEvent($click)
    Assert ($queue.Dequeue() -eq 'Wired') 'Manual wired choice must reuse the existing command queue'
    $ui.Controls.WifiButton.IsEnabled=$true; $ui.Controls.WifiButton.RaiseEvent($click)
    Assert ($queue.Dequeue() -eq 'WiFi') 'Manual Wi-Fi choice must reuse the existing command queue'
    $ui.Controls.RestoreButton.RaiseEvent($click)
    Assert ($queue.Dequeue() -eq 'Restore') 'Restore must be deferred through the controller queue'
    $ui.Controls.SaveAdaptersButton.RaiseEvent($click)
    Assert ($queue.Dequeue() -eq 'SelectAdapters') 'Selection must be validated and saved by the controller'
    Assert (@(Get-DashboardSelection $ui).Count -eq 0) 'Automatic selection must return no explicit GUIDs'
    $model.Adapters=@([pscustomobject]@{Guid='{11111111-1111-1111-1111-111111111111}';Name='Ethernet';Kind='Wired'})
    Update-NetworkDashboard $ui $model $state $false $true $false
    $ui.Controls.WiredSelector.SelectedIndex=1
    Assert $ui.SelectionDirty 'User selection must survive rendering until saved'
    Update-NetworkDashboard $ui $model $state $false $true $false
    Assert ($ui.Controls.WiredSelector.SelectedIndex -eq 1) 'Polling must not discard unsaved selection'
    $ui.Controls.WiredSelector.ApplyTemplate() | Out-Null
    $label=$ui.Controls.WiredSelector.Template.FindName('SelectionLabel',$ui.Controls.WiredSelector)
    Assert ($null -ne $label -and $label.Text -eq 'Ethernet') 'Adapter picker must display the friendly name, never the PowerShell object representation'
    $model.Wired.CanPrefer=$true;$model.WiFi.CanPrefer=$true;$model.Wired.Name='Ethernet'
    Update-NetworkDashboard $ui $model $state $false $true $false
    Assert (-not $ui.Controls.WiredButton.IsEnabled -and -not $ui.Controls.WifiButton.IsEnabled -and $ui.Controls.WiredSubtitle.Text -match '未保存.*Ethernet') 'Unsaved choices must name the effective adapter and prevent an ambiguous manual action'
    $failed=$false;try { Get-DashboardSelection $ui } catch {$failed=$true}
    Assert $failed 'One-sided adapter selection must be rejected'
    Assert ($queue.Count -eq 0) 'Programmatic toggle updates and selection edits must not change network state'
    $ui.Window.Show();$ui.Window.Close()
    Assert (-not $ui.Window.IsVisible) 'Closing the dashboard must hide it without disposing the controller view'
    $ui.Window.Show()
    Assert $ui.Window.IsVisible 'The hidden dashboard must reopen from the tray'
    Assert (Test-DashboardRefreshNeeded $ui 'frame-1') 'A changed visible frame must render'
    Assert (-not (Test-DashboardRefreshNeeded $ui 'frame-1')) 'An unchanged frame must not repeat expensive model rendering'
    $ui.Window.Width=940;$ui.Window.Height=680;$ui.Window.UpdateLayout()
    Assert ($ui.Controls.MainScroll.ScrollableHeight -gt 0) 'Small windows must scroll instead of clipping settings'
    $ui.Window.Hide()
    Assert (-not (Test-DashboardRefreshNeeded $ui 'frame-2')) 'Hidden tray sessions must skip dashboard rendering'
    $small=New-NetworkDashboard $queue ([pscustomobject]@{Width=800;Height=500;Left=0;Top=0})
    try {
        Assert ($small.Window.Width -le 800 -and $small.Window.Height -le 500 -and $small.Window.MinWidth -le 800 -and $small.Window.MinHeight -le 500) 'The complete window must fit the scaled desktop work area'
        $small.Window.Show();$small.Window.UpdateLayout()
        Assert ([Windows.Controls.Grid]::GetRow($small.Controls.WifiCard) -eq 2) 'Narrow windows must stack the two cards without overlapping headers'
        $small.Controls.RestoreButton.BringIntoView();$small.Window.UpdateLayout()
        $point=$small.Controls.RestoreButton.TranslatePoint([Windows.Point]::new(0,0),$small.Controls.MainScroll)
        Assert ($point.Y -ge 0 -and $point.Y -lt $small.Controls.MainScroll.ViewportHeight) 'Settings actions must be reachable by scrolling at 800 by 500'
    } finally {$small.AllowClose=$true;$small.Window.Close()}
    if ($SnapshotPath) {
        $ui.AllowClose=$true;$ui.Window.Close()
        $ui=New-NetworkDashboard $queue
        $ui.SelectionDirty=$false
        $state=New-ControllerState
        $adapters=@([pscustomobject]@{Guid='wired-demo';Name='以太网';Kind='Wired'},[pscustomobject]@{Guid='wifi-demo';Name='WLAN';Kind='WiFi';Profile='Home Wi-Fi'})
        $links=@()
        foreach ($kind in @('Wired','WiFi')) {
            $wired=($kind -eq 'Wired')
            $links+=[pscustomobject]@{Guid=$(if($wired){'wired-demo'}else{'wifi-demo'});Name=$kind;Kind=$kind;Family='IPv4';TotalMetric=$(if($wired){20}else{80});Source=$(if($wired){'192.168.7.25'}else{'192.168.31.25'});DomesticGood=3;DomesticBad=0;DomesticProbeBlocked=$false;ForeignGood=$(if($wired){3}else{0});ForeignBad=$(if($wired){0}else{3});ForeignProbeBlocked=$false}
        }
        $model=Get-DashboardModel ([pscustomobject]@{Adapters=$adapters;Links=$links;CheckedAt='2026-11-13T03:28:00Z'}) $state @() ''
        $ui.History.Clear();$ui.LastNotice=''
        Update-NetworkDashboard $ui $model $state $false $true $true
        $content=$ui.Window.Content
        $content.Measure([Windows.Size]::new(1120,1030)); $content.Arrange([Windows.Rect]::new(0,0,1120,1030)); $content.UpdateLayout()
        $bitmap=[Windows.Media.Imaging.RenderTargetBitmap]::new(1120,1030,96,96,[Windows.Media.PixelFormats]::Pbgra32)
        $bitmap.Render($content)
        $encoder=[Windows.Media.Imaging.PngBitmapEncoder]::new(); $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
        $stream=[IO.File]::Create($SnapshotPath); try { $encoder.Save($stream) } finally { $stream.Dispose() }
    }
    Write-Output "PASS: $count native dashboard assertions. No network mutations."
} finally { $ui.AllowClose=$true; $ui.Window.Close() }
