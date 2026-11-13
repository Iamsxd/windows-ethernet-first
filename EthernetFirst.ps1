#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Apply,
    [ValidateSet('Wired','WiFi')][string]$Prefer,
    [switch]$Restore,
    [switch]$ForceRestore,
    [switch]$NoNotifications,
    [switch]$TrayOnly,
    [ValidateSet('auto','zh','ru','en')][string]$Language = 'auto',
    [ValidateRange(5,300)][int]$IntervalSeconds = 15,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'EthernetFirst'),
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
if (([int][bool]$Apply + [int][bool]$Restore + [int][bool]$Prefer) -gt 1) { throw 'Choose only one of -Apply, -Prefer or -Restore.' }
if ($ForceRestore -and -not $Restore) { throw '-ForceRestore requires -Restore.' }
if ($Language -eq 'auto') { $Language = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
$zh = $Language -eq 'zh'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
. (Join-Path $PSScriptRoot 'src\Core.ps1')
. (Join-Path $PSScriptRoot 'src\Controller.ps1')
. (Join-Path $PSScriptRoot 'src\Switching.ps1')
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Apply -or $Prefer -or $Restore) -and -not $admin) { throw 'Network changes require administrator authorization. Use start.bat.' }
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$backupPath = Join-Path $StateDirectory 'original-metrics.json'
$expectedPath = Join-Path $StateDirectory 'managed-metrics.json'
$preferencesPath = Join-Path $StateDirectory 'preferences.json'
# All entry points, including restore, share the same writer lock.
$mutex = [Threading.Mutex]::new($false, 'Global\EthernetFirst-NetworkControl')
$ownsMutex = $false; $tray = $null; $worker = $null; $dashboard=$null
$state = New-ControllerState
$requests = New-Object 'System.Collections.Generic.Queue[string]'
$lastSnapshot = $null; $lastError = ''; $lastEvent = ''; $nextCheck = [DateTime]::MinValue

function Show-Notice([string]$Message) {
    if ($tray) { $tray.BalloonTipTitle='Ethernet First'; $tray.BalloonTipText=$Message; $tray.ShowBalloonTip(6000) }
}

function Show-LinkStatus {
    if ($dashboard) {
        $dashboard.Window.Show()
        if ($dashboard.Window.WindowState -eq 'Minimized') { $dashboard.Window.WindowState='Normal' }
        [void]$dashboard.Window.Activate()
    }
}

function Update-ControllerView([bool]$Busy=$false,[bool]$Force=$false) {
    if ($dashboard) {
        if (-not $Force -and -not $dashboard.Window.IsVisible) { return }
        $stamp=if ($lastSnapshot) {$lastSnapshot.CheckedAt} else {'pending'}
        $hasBackup=Test-Path -LiteralPath $backupPath
        $key=@($stamp,$state.Generation,$state.Mode,$state.ReturnToWired,$state.LastReason,$lastError,$Busy,$hasBackup,$dashboard.SelectionDirty) -join '|'
        if (-not (Test-DashboardRefreshNeeded $dashboard $key $Force)) { return }
        $model=Get-DashboardModel $lastSnapshot $state $settings.ManagedGuids $lastError
        Update-NetworkDashboard $dashboard $model $state $Busy $admin $hasBackup
    }
}

function Invoke-TrayRequests {
    # A restore is executed only after the read worker is idle. Keep later
    # actions queued so Restore -> Auto preserves ordering and uses fresh data.
    if ($state.RestoreRequested) { return }
    while ($requests.Count) {
        $request = $requests.Dequeue()
        $actionError=''
        try {
            if ($dashboard -and $dashboard.SelectionDirty -and ($request -in @('Wired','WiFi','AutoOn') -or ($request -eq 'AutoToggle' -and $state.Mode -ne 'Auto'))) { throw '请先保存或撤销未保存的网卡选择，再切换线路或开启自动模式。' }
            switch ($request) {
                'Exit' { $state.Exit=$true; $state.Mode='Monitor' }
                'Details' { Show-LinkStatus }
                'Check' { Request-ConnectionCheck $state; $script:nextCheck=[DateTime]::MinValue }
                'AutoToggle' {
                    $mode = if ($state.Mode -eq 'Auto') {'Monitor'} else {'Auto'}
                    Request-SwitchMode $state $mode $admin
                    $script:nextCheck=[DateTime]::MinValue
                }
                {$_ -in @('AutoOn','AutoOff')} {
                    $mode=if ($request -eq 'AutoOn') {'Auto'} else {'Monitor'}
                    Request-SwitchMode $state $mode $admin
                    $script:nextCheck=[DateTime]::MinValue
                }
                {$_ -in @('RecoveryOn','RecoveryOff')} {
                    if (-not $admin) { throw 'Administrator authorization is required to save settings.' }
                    $enabled=($request -eq 'RecoveryOn')
                    Write-UserPreferences $preferencesPath $settings.ManagedGuids $enabled
                    Request-WiredRecovery $state $enabled
                    $script:nextCheck=[DateTime]::MinValue
                }
                'SelectAdapters' {
                    if (-not $admin) { throw 'Administrator authorization is required to save settings.' }
                    $selected=@(Get-DashboardSelection $dashboard)
                    $old=(@($settings.ManagedGuids | Sort-Object) -join ',')
                    $new=(@($selected | Sort-Object) -join ',')
                    if ($old -ne $new -and (Test-Path -LiteralPath $backupPath)) { throw '请先恢复原设置，再更换管理的网卡。' }
                    Write-UserPreferences $preferencesPath $selected $state.ReturnToWired
                    $settings.ManagedGuids=$selected; $dashboard.SelectionDirty=$false
                    Request-SwitchMode $state Monitor $admin
                    Request-ConnectionCheck $state
                    $script:nextCheck=[DateTime]::MinValue
                }
                'CancelSelection' { $dashboard.SelectionDirty=$false }
                'Restore' {
                    Request-MetricRestore $state
                    $script:nextCheck=[DateTime]::MinValue
                    return
                }
                default {
                    Request-SwitchMode $state $request $admin
                    $script:nextCheck=[DateTime]::MinValue
                }
            }
        } catch { $state.Mode='Monitor'; $script:lastError=$_.Exception.Message; $actionError=$script:lastError; Show-Notice $script:lastError }
        if ($dashboard) {
            $message=if ($actionError) {'操作未完成：'+$actionError} else { switch ($request) {
                'Check' {'已请求重新检测两条线路。'}
                'Wired' {'已请求优先使用有线；自动模式已关闭。'}
                'WiFi' {'已请求优先使用 Wi-Fi；自动模式已关闭。'}
                {$_ -in @('AutoToggle','AutoOn','AutoOff')} {if ($state.Mode -eq 'Auto') {'自动守护已开启。'} else {'自动守护已关闭，保留当前优先级。'}}
                {$_ -in @('RecoveryOn','RecoveryOff')} {if ($state.ReturnToWired) {'已开启有线恢复后自动切回。'} else {'已关闭有线恢复后自动切回。'}}
                'SelectAdapters' {'网卡选择已处理，当前为只检测模式。'}
                default {''}
            } }
            if ($message) { Add-DashboardEvent $dashboard $message }
        }
        if ($tray) { $autoItem.Checked=($state.Mode -eq 'Auto') }
    }
}

function Invoke-PendingRestore {
    if (-not $admin) { throw 'Use start.bat to restore settings with administrator authorization.' }
    $force=$false
    if (-not (Test-ManagedMetrics -ExpectedPath $expectedPath -BackupPath $backupPath)) {
        $question=if ($zh) {'网卡设置已被修改，或上次操作未完成。仍要覆盖当前优先级并恢复工具首次保存的设置吗？'} else {'Metrics changed or an earlier operation is incomplete. Overwrite current priorities with the original saved settings?'}
        $answer=[Windows.Forms.MessageBox]::Show($question,'Ethernet First','YesNo','Warning','Button2')
        if ($answer -ne [Windows.Forms.DialogResult]::Yes) {
            if ($dashboard) { Add-DashboardEvent $dashboard '恢复已取消，保留当前优先级；自动模式保持关闭。' }
            return
        }
        $force=$true
    }
    Restore-SwitchMetrics -BackupPath $backupPath -ExpectedPath $expectedPath -Force:$force | Out-Null
    $state.LastReason=if ($zh) {'已恢复原设置；自动切换已关闭。'} else {'Original settings restored; automatic failover is off.'}
    Show-Notice $state.LastReason
    if ($dashboard) { Add-DashboardEvent $dashboard '恢复已完成：原网卡优先级已还原，自动模式已关闭。' }
}

try {
    try { $ownsMutex=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex=$true }
    if (-not $ownsMutex) { throw 'Ethernet First is already running. Use its tray menu, or close it before running another command.' }
    if ($Restore) {
        Restore-SwitchMetrics -BackupPath $backupPath -ExpectedPath $expectedPath -Force:$ForceRestore
        Write-Output 'Original interface settings restored.'
        return
    }
    # Restoration does not depend on health endpoint configuration or Probe.cs.
    $settings=Read-SwitchConfiguration $ConfigPath
    $preferences=Read-UserPreferences $preferencesPath $settings
    $settings.ManagedGuids=@($preferences.ManagedGuids)
    $state.ReturnToWired=$preferences.ReturnToWired
    if (-not ('EthernetFirst.Probe' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'src\Probe.cs') }
    if ($Apply) { Request-SwitchMode $state Auto $admin }
    if ($Prefer) { Request-SwitchMode $state $Prefer $admin }
    if (-not $NoNotifications -and -not $Once) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        . (Join-Path $PSScriptRoot 'src\DashboardModel.ps1')
        . (Join-Path $PSScriptRoot 'src\Dashboard.ps1')
        $dashboard=New-NetworkDashboard $requests
        Update-ControllerView $true $true
        if (-not $TrayOnly) { $dashboard.Window.Show() }
        $tray = New-Object Windows.Forms.NotifyIcon
        $tray.Icon=[Drawing.SystemIcons]::Information
        $tray.Text='Ethernet First'; $tray.Visible=$true
        $menu=New-Object Windows.Forms.ContextMenuStrip
        $wiredItem=$menu.Items.Add($(if ($zh) {'优先使用有线（关闭自动）'} else {'Prefer Ethernet (auto off)'}))
        $wiredItem.Add_Click({$requests.Enqueue('Wired')})
        $wifiItem=$menu.Items.Add($(if ($zh) {'优先使用 Wi-Fi（关闭自动）'} else {'Prefer Wi-Fi (auto off)'}))
        $wifiItem.Add_Click({$requests.Enqueue('WiFi')})
        $autoItem=$menu.Items.Add($(if ($zh) {'启用自动故障切换'} else {'Enable automatic failover'}))
        $autoItem.Checked=($state.Mode -eq 'Auto'); $autoItem.Add_Click({$requests.Enqueue('AutoToggle')})
        [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
        $checkItem=$menu.Items.Add($(if ($zh) {'立即检测两条线路'} else {'Check connections now'}))
        $checkItem.Add_Click({$requests.Enqueue('Check')})
        $detailsItem=$menu.Items.Add($(if ($zh) {'打开主窗口'} else {'Open dashboard'}))
        $detailsItem.Add_Click({$requests.Enqueue('Details')})
        $restoreItem=$menu.Items.Add($(if ($zh) {'恢复工具修改前的设置'} else {'Restore original settings'}))
        $restoreItem.Add_Click({$requests.Enqueue('Restore')})
        $exitItem=$menu.Items.Add($(if ($zh) {'退出（保留当前优先级）'} else {'Exit (keep current metrics)'}))
        $exitItem.Add_Click({$state.Mode='Monitor'; $state.Exit=$true})
        $tray.Add_DoubleClick({$requests.Enqueue('Details')})
        $tray.ContextMenuStrip=$menu
    }
    $health=@{}
    do {
        if ($tray) { [Windows.Forms.Application]::DoEvents(); Invoke-TrayRequests; Update-ControllerView }
        if ($state.Exit) { break }
        if ($state.RestoreRequested) {
            try { Invoke-PendingRestore }
            catch { $lastError=$_.Exception.Message; Show-Notice $lastError; if ($dashboard) { Add-DashboardEvent $dashboard ('恢复未完成：'+$lastError) } }
            finally {
                Complete-MetricRestore $state; $health.Clear(); $nextCheck=[DateTime]::MinValue
                if ($tray) { $autoItem.Checked=$false }
            }
            continue
        }
        if ([DateTime]::UtcNow -lt $nextCheck) { Start-Sleep -Milliseconds 100; continue }
        $requestedMode=''
        try {
            $sampleGeneration=$state.Generation; $state.CheckRequested=$false
            # One worker at a time. The UI continues pumping while DNS/TLS is pending;
            # all metric changes and menu actions stay on this single controller thread.
            $worker=[PowerShell]::Create()
            [void]$worker.AddScript({param($root,$memory,$overrides,$targets)
                . (Join-Path $root 'src\Core.ps1')
                Get-NetworkSnapshot $memory $overrides $targets
            }).AddArgument($PSScriptRoot).AddArgument($health).AddArgument($settings.Overrides).AddArgument(@{Domestic=$settings.DomesticHttps;Foreign=$settings.ForeignHttps})
            # -Once executes in the current scope, allowing deterministic OS-boundary tests.
            if ($Once) { $snapshot=Get-NetworkSnapshot $health $settings.Overrides @{Domestic=$settings.DomesticHttps;Foreign=$settings.ForeignHttps} }
            else {
                $pending=$worker.BeginInvoke()
                while (-not $pending.IsCompleted -and -not $state.Exit) {
                    if ($tray) { [Windows.Forms.Application]::DoEvents(); Invoke-TrayRequests; Update-ControllerView $true }
                    Start-Sleep -Milliseconds 100
                }
                if ($state.Exit) { $worker.Stop(); break }
                $results=@($worker.EndInvoke($pending))
                if ($worker.HadErrors) { throw [string]$worker.Streams.Error[0] }
                if ($results.Count -ne 1) { throw 'Network snapshot did not return exactly one result.' }
                $snapshot=$results[0]
            }
            $worker.Dispose(); $worker=$null
            if (-not (Test-SnapshotCurrent $state $sampleGeneration)) {
                $health.Clear(); $nextCheck=[DateTime]::MinValue
                continue
            }
            $lastSnapshot=$snapshot
            $requestedMode=$state.Mode
            $decision=Invoke-ControllerCycle $state $snapshot $settings.ManagedGuids $backupPath $expectedPath
            $outcome=Get-ControllerEvent $decision $requestedMode
            if ($dashboard -and $outcome) { Add-DashboardEvent $dashboard $outcome }
            $lastError=''
            # Read the live defaults after a successful transaction for the status display.
            foreach ($link in $snapshot.Links) {
                $ip=Get-NetIPInterface -InterfaceIndex $link.Index -AddressFamily $link.Family -ErrorAction Stop
                $link.Metric=[int]$ip.InterfaceMetric; $link.TotalMetric=$link.Metric+$link.RouteMetric
            }
            $winners=@()
            foreach ($family in @('IPv4','IPv6')) {
                $links=@($snapshot.Links | Where-Object Family -eq $family)
                if ($links.Count) {
                    $minimum=($links | Measure-Object TotalMetric -Minimum).Minimum
                    $winners+=@($links | Where-Object TotalMetric -eq $minimum | Select-Object Guid,Name,Kind,Family,TotalMetric)
                }
            }
            $status=[ordered]@{checkedAt=$snapshot.CheckedAt; mode=$state.Mode; applying=($state.Mode -eq 'Auto'); autoReturnToWired=$state.ReturnToWired; probeType='HTTPS'; probeProfiles=@('Domestic','Foreign'); message=$state.LastReason; physicalDefaults=@($winners | Where-Object Kind -ne Virtual); defaultRoutes=$winners; links=$snapshot.Links; adapters=$snapshot.Adapters}
            Write-AtomicJson (Join-Path $StateDirectory 'status.json') $status
            if ($state.LastReason -ne $lastEvent) {
                $line='{0} {1}' -f (Get-Date -Format o),$state.LastReason
                $log=Join-Path $StateDirectory 'events.log'
                if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item -LiteralPath $log -Destination ($log+'.1') -Force }
                Add-Content -LiteralPath $log -Value $line -Encoding UTF8
                if (-not $Once) { Write-Output $line; Show-Notice $state.LastReason }
                $lastEvent=$state.LastReason
            }
            if ($tray) { $autoItem.Checked=($state.Mode -eq 'Auto') }
            Update-ControllerView
            if ($Once) { $status | ConvertTo-Json -Depth 8 }
        } catch {
            $state.Mode='Monitor'; $lastError=$_.Exception.Message
            if ($dashboard -and $requestedMode -in @('Wired','WiFi','Auto')) { Add-DashboardEvent $dashboard ('切换未完成，自动模式已关闭：'+$lastError) }
            Write-AtomicJson (Join-Path $StateDirectory 'status.json') @{checkedAt=[DateTime]::UtcNow.ToString('o');mode='Monitor';error=$lastError}
            if ($Once) { throw }
            Show-Notice $lastError
        } finally {
            if ($worker) { $worker.Dispose(); $worker=$null }
            if ($tray) { $autoItem.Checked=($state.Mode -eq 'Auto') }
            Update-ControllerView
        }
        $nextCheck=if ($state.CheckRequested) {[DateTime]::MinValue} else {[DateTime]::UtcNow.AddSeconds($IntervalSeconds)}
    } while (-not $Once)
} finally {
    if ($worker) { $worker.Dispose() }
    if ($dashboard) { $dashboard.AllowClose=$true; $dashboard.Window.Close() }
    if ($tray) { $tray.Dispose(); $menu.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
