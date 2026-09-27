#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$Once,
    [switch]$Apply,
    [switch]$Restore,
    [switch]$NoNotifications,
    [ValidateSet('auto','ru','en')][string]$Language = 'auto',
    [ValidateRange(5,300)][int]$IntervalSeconds = 15,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'EthernetFirst'),
    [string]$ConfigPath
)
$ErrorActionPreference = 'Stop'
if ($Language -eq 'auto') { $Language = [Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName }
$ru = $Language -eq 'ru'
if (-not $ConfigPath) { $ConfigPath = Join-Path $PSScriptRoot 'config.json' }
. (Join-Path $PSScriptRoot 'src\Core.ps1')
if (-not ('EthernetFirst.Probe' -as [type])) { Add-Type -Path (Join-Path $PSScriptRoot 'src\Probe.cs') }
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (($Apply -or $Restore) -and -not $admin) { throw 'Apply/restore needs an administrator PowerShell. Run install.bat for automatic startup.' }
New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
$backupPath = Join-Path $StateDirectory 'original-metrics.json'
if ($Restore) { Restore-Priorities $backupPath; Write-Output 'Original interface settings restored.'; exit }
$overrides = @{}
$probeTargets = @{ IPv4=@('1.1.1.1','8.8.8.8','77.88.55.80'); IPv6=@('2606:4700:4700::1111','2001:4860:4860::8888') }
if (Test-Path -LiteralPath $ConfigPath) {
    $config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
    foreach ($p in $config.adapterOverrides.PSObject.Properties) {
        if ($p.Value -notin @('Wired','WiFi','Mobile','Virtual','Other')) { throw 'Invalid adapter kind in config.json' }
        $overrides[$p.Name] = [string]$p.Value
    }
    foreach ($family in @('IPv4','IPv6')) {
        $property=$config.PSObject.Properties['probe'+$family]
        if ($property -and @($property.Value).Count) {
            foreach ($target in $property.Value) {
                $ip=[Net.IPAddress]::Parse([string]$target)
                if (($family -eq 'IPv4') -ne ($ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork)) { throw 'Probe address family mismatch' }
            }
            $probeTargets[$family]=[string[]]$property.Value
        }
    }
}
$mutex = [Threading.Mutex]::new($false, 'Local\EthernetFirst-' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
$ownsMutex = $false
$tray = $null
try {
    try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
    if (-not $ownsMutex) { throw 'Ethernet First is already running in this session.' }
    if (-not $NoNotifications -and -not $Once) {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon = [Drawing.SystemIcons]::Information
        $tray.Text = 'Ethernet First'
        $tray.Visible = $true
    }
    $health = @{}; $traffic = @{}; $lastEvent = ''; $lastNoticeMessage = ''; $lastNotice = [DateTime]::MinValue
    do {
        try {
            $snapshot = Get-NetworkSnapshot $health $overrides $probeTargets
            $plan = @()
            foreach ($family in @('IPv4','IPv6')) {
                $plan += @(Get-PriorityPlan @($snapshot.Links | Where-Object Family -eq $family) $snapshot.VirtualMetrics[$family])
            }
            if ($Apply) { Set-PriorityPlan $plan $backupPath }
            $messages = @(); $mobileTraffic = @(); $wifiTraffic = @()
            foreach ($item in $snapshot.Traffic) {
                if ($traffic.ContainsKey($item.Guid) -and $item.Kind -eq 'Mobile' -and ($item.Bytes - $traffic[$item.Guid]) -gt 65536) { $mobileTraffic += $item.Name }
                if ($traffic.ContainsKey($item.Guid) -and $item.Kind -eq 'WiFi' -and ($item.Bytes - $traffic[$item.Guid]) -gt 65536) { $wifiTraffic += $item.Name }
                $traffic[$item.Guid] = $item.Bytes
            }
            # Read back applied values, including the route metric. Ties remain ambiguous.
            $winners = @()
            foreach ($family in @('IPv4','IPv6')) {
                $familyLinks = @($snapshot.Links | Where-Object Family -eq $family)
                foreach ($link in $familyLinks) {
                    $ip = Get-NetIPInterface -InterfaceIndex $link.Index -AddressFamily $family -ErrorAction SilentlyContinue
                    if ($ip) { $link.Metric = [int]$ip.InterfaceMetric; $link.TotalMetric = $link.Metric + $link.RouteMetric }
                }
                if ($familyLinks.Count) {
                    $minimum = ($familyLinks | Measure-Object TotalMetric -Minimum).Minimum
                    $selected = @($familyLinks | Where-Object TotalMetric -eq $minimum)
                    $winners += @($selected | Select-Object Name,Kind,Family,TotalMetric)
                    if (@($selected | Where-Object Kind -eq 'Mobile').Count) { $messages += $(if ($ru) { "$family : приоритет у интернета через телефон / модем." } else { "$family : mobile/tethering has a preferred physical default route." }) }
                    elseif (@($selected | Where-Object Kind -eq 'WiFi').Count) { $messages += $(if ($ru) { "$family : приоритет у Wi-Fi." } else { "$family : Wi-Fi has a preferred physical default route." }) }
                    if ($selected.Count -gt 1) { $messages += $(if ($ru) { "$family : одинаковые метрики, выбор физического подключения неоднозначен." } else { "$family : equal physical route metrics; selection is ambiguous." }) }
                }
            }
            if ($mobileTraffic.Count) { $messages += $(if ($ru) { 'Обнаружен трафик через телефон: ' + ($mobileTraffic -join ', ') + '. VPN или приложение может продолжать использовать его.' } else { 'Mobile adapter traffic detected: ' + ($mobileTraffic -join ', ') + '. A VPN or application may still use it.' }) }
            if (@($snapshot.Links | Where-Object ProbeBlocked -eq $true).Count) { $messages += $(if ($ru) { 'Проверку некоторых подключений блокирует локальная сетевая политика; их доступность неизвестна.' } else { 'Local network policy blocks some probes; connectivity is unknown.' }) }
            $healthyWired = @($snapshot.Links | Where-Object { $_.Kind -eq 'Wired' -and $_.Healthy -eq $true }).Count -gt 0
            if ($healthyWired -and $wifiTraffic.Count) { $messages += $(if ($ru) { 'При работающем Ethernet есть трафик через Wi-Fi: ' + ($wifiTraffic -join ', ') + '. Проверьте, не используется ли точка доступа телефона.' } else { 'Wi-Fi traffic observed while wired Ethernet is available: ' + ($wifiTraffic -join ', ') + '. Check whether this is a phone hotspot.' }) }
            if (-not $messages.Count) {
                if ($healthyWired) { $messages += $(if ($ru) { 'Проводной Ethernet работает и имеет приоритет среди физических маршрутов по умолчанию.' } else { 'Wired Ethernet is available and preferred among physical default routes.' }) }
                else { $messages += $(if ($ru) { 'Проверяю доступ в интернет. Подключённый кабель сам по себе не гарантирует связь.' } else { 'Checking connectivity. A live cable alone does not prove Internet access.' }) }
            }
            $message = $messages -join ' '
            $status = [ordered]@{ checkedAt=[DateTime]::UtcNow.ToString('o'); applying=[bool]$Apply; message=$message; physicalDefaults=$winners; links=$snapshot.Links; mobileTraffic=$mobileTraffic; wifiTraffic=$wifiTraffic; virtualDefaultPresent=($snapshot.VirtualMetrics.IPv4 -gt 0 -or $snapshot.VirtualMetrics.IPv6 -gt 0) }
            Write-AtomicJson (Join-Path $StateDirectory 'status.json') $status
            if ($message -ne $lastEvent) {
                $line = '{0} {1}' -f (Get-Date -Format o), $message
                $log = Join-Path $StateDirectory 'events.log'
                if ((Test-Path $log) -and (Get-Item $log).Length -gt 1MB) { Move-Item -LiteralPath $log -Destination ($log+'.1') -Force }
                Add-Content -LiteralPath $log -Value $line -Encoding UTF8
                Write-Output $line
                $lastEvent = $message
            }
                if ($tray -and $message -ne $lastNoticeMessage -and ([DateTime]::UtcNow - $lastNotice).TotalSeconds -ge 30) {
                    $tray.BalloonTipTitle = 'Ethernet First'
                    $tray.BalloonTipText = $message
                    $tray.ShowBalloonTip(12000)
                    $lastNotice = [DateTime]::UtcNow
                    $lastNoticeMessage = $message
                }
            if ($Once) { $status | ConvertTo-Json -Depth 6 }
        } catch {
            $errorStatus = [ordered]@{ checkedAt=[DateTime]::UtcNow.ToString('o'); error=$_.Exception.Message }
            Write-AtomicJson (Join-Path $StateDirectory 'status.json') $errorStatus
            if ($Once) { throw }
            if ($tray -and ([DateTime]::UtcNow - $lastNotice).TotalSeconds -ge 60) {
                $tray.BalloonTipTitle='Ethernet First: error'; $tray.BalloonTipText=$_.Exception.Message
                $tray.ShowBalloonTip(12000); $lastNotice=[DateTime]::UtcNow
            }
        }
        if (-not $Once) {
            for ($n=0; $n -lt ($IntervalSeconds*4); $n++) {
                if ($tray) { [Windows.Forms.Application]::DoEvents() }
                Start-Sleep -Milliseconds 250
            }
        }
    } while (-not $Once)
} finally {
    if ($tray) { $tray.Dispose() }
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
