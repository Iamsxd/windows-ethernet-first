Set-StrictMode -Version Latest

function New-NetworkDashboard {
    param([System.Collections.Generic.Queue[string]]$Queue)
    Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
    $markup=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Dashboard.xaml'))
    $window=[Windows.Markup.XamlReader]::Parse($markup)
    $controls=@{}
    foreach ($match in [regex]::Matches($markup,'x:Name="([^"]+)"')) {
        $name=$match.Groups[1].Value
        $control=$window.FindName($name)
        if ($control) { $controls[$name]=$control }
    }
    $ui=@{Window=$window;Controls=$controls;AllowClose=$false;Updating=$false;SelectionDirty=$false;InventoryKey='';History=(New-Object 'System.Collections.ObjectModel.ObservableCollection[object]');LastNotice='';Queue=$Queue}
    $controls.HistoryList.ItemsSource=$ui.History
    foreach ($pair in @(@('CheckButton','Check'),@('WiredButton','Wired'),@('WifiButton','WiFi'),@('RestoreButton','Restore'),@('SaveAdaptersButton','SelectAdapters'))) {
        $command=$pair[1]; $q=$Queue
        $controls[$pair[0]].Add_Click({$q.Enqueue($command)}.GetNewClosure())
    }
    $controls.AutoSwitch.Add_Click({$Queue.Enqueue($(if ($ui.Controls.AutoSwitch.IsChecked) {'AutoOn'} else {'AutoOff'}))}.GetNewClosure())
    $controls.ReturnSwitch.Add_Click({$Queue.Enqueue($(if ($ui.Controls.ReturnSwitch.IsChecked) {'RecoveryOn'} else {'RecoveryOff'}))}.GetNewClosure())
    $controls.HideButton.Add_Click({$ui.Window.Hide()}.GetNewClosure())
    $window.Add_Closing({param($sender,$eventArgs) if (-not $ui.AllowClose) {$eventArgs.Cancel=$true;$sender.Hide()}}.GetNewClosure())
    foreach ($name in @('WiredSelector','WifiSelector')) {
        $controls[$name].Add_SelectionChanged({if (-not $ui.Updating) {$ui.SelectionDirty=$true;$ui.Controls.SelectionHint.Text='网卡选择尚未保存，点击“保存网卡选择”后生效。'}}.GetNewClosure())
    }
    foreach ($pair in @(@('OverviewNav','OverviewSection'),@('SettingsNav','SettingsSection'),@('HelpNav','HelpSection'))) {
        $target=$controls[$pair[1]]
        $controls[$pair[0]].Add_Click({$target.BringIntoView()}.GetNewClosure())
    }
    return $ui
}

function Get-DashboardSelection {
    param([hashtable]$UI)
    $wired=[string]$UI.Controls.WiredSelector.SelectedValue
    $wifi=[string]$UI.Controls.WifiSelector.SelectedValue
    if ([bool]$wired -ne [bool]$wifi) { throw '请同时选择一张有线和一张 Wi-Fi 网卡，或两项都选择“自动识别”。' }
    if ($wired -and $wifi) { return @($wired,$wifi) }
    return @()
}

function Add-DashboardEvent {
    param([hashtable]$UI,[string]$Message)
    $UI.History.Insert(0,[pscustomobject]@{Time=(Get-Date -Format HH:mm:ss);Message=$Message})
    while ($UI.History.Count -gt 20) {$UI.History.RemoveAt($UI.History.Count-1)}
}

function Update-NetworkDashboard {
    param([hashtable]$UI,$Model,[hashtable]$State,[bool]$Busy,[bool]$IsAdmin,[bool]$HasBackup)
    $c=$UI.Controls; $UI.Updating=$true
    try {
        $c.CurrentTitle.Text=$Model.CurrentTitle; $c.CurrentDetail.Text=$Model.CurrentDetail; $c.CheckedText.Text=$Model.CheckedText
        $c.NoticeText.Text=$Model.Notice
        $c.NoticeBorder.Background=if ($Model.NoticeKind -in @('Error','Warning')) {'#FFF3DF'} else {'#E8EFFC'}
        $c.ModeText.Text=if ($State.Mode -eq 'Auto') {'●  自动守护中'} else {'●  只检测模式'}
        $c.AutoSwitch.IsChecked=($State.Mode -eq 'Auto'); $c.ReturnSwitch.IsChecked=$State.ReturnToWired
        $c.AutoSwitch.IsEnabled=$IsAdmin; $c.ReturnSwitch.IsEnabled=$IsAdmin
        $c.BusyText.Visibility=if ($Busy) {'Visible'} else {'Hidden'}
        $c.BusyBar.Visibility=if ($Busy) {'Visible'} else {'Hidden'}
        $key=(@($Model.Adapters | Sort-Object Guid | ForEach-Object {$_.Guid+'|'+$_.Name+'|'+$_.Kind}) -join ';')
        if ($key -ne $UI.InventoryKey -or $c.WiredSelector.Items.Count -eq 0) {
            foreach ($kind in @('Wired','Wifi')) {
                $selector=$c[$kind+'Selector']; $selected=[string]$selector.SelectedValue
                $available=@($Model.Adapters | Where-Object Kind -eq $kind | Sort-Object Name | Select-Object Guid,Name)
                $automaticName=if ($available.Count -eq 1) {'自动 · '+$available[0].Name} else {'自动识别（唯一物理网卡）'}
                $items=@([pscustomobject]@{Guid='';Name=$automaticName})+$available
                $selector.ItemsSource=$items
                $selector.SelectedValue=$selected
                if ($selector.SelectedIndex -lt 0) { $selector.SelectedIndex=0 }
            }
            $UI.InventoryKey=$key
        }
        foreach ($kind in @('Wired','Wifi')) {
            $card=if ($kind -eq 'Wired') {$Model.Wired} else {$Model.WiFi}
            $c[$kind+'Subtitle'].Text=if ($card.NeedsSelection) {'检测到多张网卡，请选择并保存。'} else {$card.Subtitle}
            $c[$kind+'Subtitle'].ToolTip=$card.Name+' · '+$card.Subtitle
            $c[$kind+'Badge'].Text=$card.Badge
            $c[$kind+'BadgeBorder'].Background=if ($card.IsCurrent) {'#E8F7F1'} else {'#F0F3F8'}
            $c[$kind+'Button'].Content=if ($card.IsCurrent) {'✓  正在使用'} elseif ($kind -eq 'Wired') {'优先使用有线'} else {'优先使用 Wi-Fi'}
            $c[$kind+'Button'].IsEnabled=($IsAdmin -and $card.CanPrefer -and -not $State.RestoreRequested)
            if (-not $UI.SelectionDirty) {
                $c[$kind+'Selector'].SelectedValue=if (@($Model.ManagedGuids).Count) {$card.Guid} else {''}
                if ($c[$kind+'Selector'].SelectedIndex -lt 0) { $c[$kind+'Selector'].SelectedIndex=0 }
            }
            foreach ($profile in @('Domestic','Foreign')) {
                $status=$card.$profile
                $c[$kind+$profile].Text=$status.Text; $c[$kind+$profile].Foreground=$status.Color
                $c[$kind+$profile+'Bg'].Background=$status.Background; $c[$kind+$profile+'Bg'].ToolTip=$status.Detail
            }
        }
        $c.RestoreButton.IsEnabled=($IsAdmin -and $HasBackup -and -not $State.RestoreRequested)
        $c.SaveAdaptersButton.IsEnabled=$IsAdmin
        if (-not $UI.SelectionDirty) { $c.SelectionHint.Text=if ($IsAdmin) {'手动切换会关闭自动模式；每次启动也默认只检测。'} else {'当前没有管理员权限，仅可查看。请通过 start.bat 启动以切换线路。'} }
        $c.DiagnosticText.Text=([string]$State.LastReason)+$(if ($Model.ErrorMessage) {"`r`n"+$Model.ErrorMessage})
        $notice=$Model.NoticeCode+'|'+$Model.Notice
        if ($notice -ne $UI.LastNotice) {
            Add-DashboardEvent $UI $Model.Notice
            $UI.LastNotice=$notice
        }
    } finally { $UI.Updating=$false }
}
