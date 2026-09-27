Set-StrictMode -Version Latest

function Get-AdapterKind {
    param($Adapter, [string]$Profile = '', [hashtable]$Overrides = @{})
    $identity = [string]$Adapter.InterfaceGuid
    if ($Overrides.ContainsKey($identity)) { return $Overrides[$identity] }
    $description = [string]$Adapter.InterfaceDescription
    if ($description -match 'Apple Mobile Device|Remote NDIS|\bRNDIS\b|USB.*Tether|\bWWAN\b|Mobile Broadband') { return 'Mobile' }
    if (-not $Adapter.HardwareInterface) { return 'Virtual' }
    if ("$($Adapter.MediaType) $($Adapter.PhysicalMediaType)" -match '802\.11|Wireless') {
        if ($Profile -match 'iPhone|iPad|Personal Hotspot|Android.*Hotspot') { return 'Mobile' }
        return 'WiFi'
    }
    if ([string]$Adapter.MediaType -match '802\.3') { return 'Wired' }
    return 'Other'
}

function Get-PriorityPlan {
    param([object[]]$Links, [int]$VirtualMetric = 0)
    # Keep every physical default below the priority of existing virtual defaults.
    $baseMetric = [Math]::Max(1000, $VirtualMetric + 100)
    if ($baseMetric -gt 5900) { throw 'Virtual/default metrics are too large for safe automatic adjustment. Use monitor-only mode.' }
    $healthyExists = @($Links | Where-Object { $_.Healthy -eq $true }).Count -gt 0
    if (-not $healthyExists) { return }
    foreach ($link in $Links) {
        # Unknown connectivity must not cause failover. Three failed checks are required.
        $rank = switch ($link.Kind) { 'Wired' { 0 } 'WiFi' { 1000 } 'Mobile' { 2000 } default { 3000 } }
        if ($healthyExists -and $link.Healthy -eq $false) { $rank = 4000 }
        $total = $baseMetric + $rank
        # Route and interface metrics add up; a large custom route is not safely overridden.
        if ($link.RouteMetric -ge $total) { continue }
        [pscustomobject]@{
            Guid = $link.Guid; Index = $link.Index; Family = $link.Family
            Metric = $total - [int]$link.RouteMetric; Name = $link.Name; Kind = $link.Kind
        }
    }
}

function Update-Health {
    param([hashtable]$Memory, [string]$Key, [bool]$Success)
    if (-not $Memory.ContainsKey($Key)) { $Memory[$Key] = @{ Good = 0; Bad = 0; Value = $null } }
    $h = $Memory[$Key]
    if ($Success) { $h.Good++; $h.Bad = 0; if ($h.Good -ge 2) { $h.Value = $true } }
    else { $h.Bad++; $h.Good = 0; if ($h.Bad -ge 3) { $h.Value = $false } }
    return $h.Value
}

function Write-AtomicJson {
    param([string]$Path, $Value)
    $temp = $Path + '.tmp'
    ConvertTo-Json -InputObject $Value -Depth 8 | Set-Content -LiteralPath $temp -Encoding UTF8
    Move-Item -LiteralPath $temp -Destination $Path -Force
}

function Read-JsonArray {
    param([string]$Path)
    # PowerShell 5.1 and 7 enumerate ConvertFrom-Json arrays differently.
    foreach ($entry in (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json)) { $entry }
}

function Get-NetworkSnapshot {
    param([hashtable]$Health, [hashtable]$Overrides = @{}, [hashtable]$ProbeTargets = @{
        IPv4 = @('1.1.1.1','8.8.8.8','77.88.55.80')
        IPv6 = @('2606:4700:4700::1111','2001:4860:4860::8888')
    })
    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object Status -eq 'Up')
    $profiles = @(Get-NetConnectionProfile -ErrorAction SilentlyContinue)
    $ipInterfaces = @(Get-NetIPInterface -ErrorAction Stop)
    $addresses = @(Get-NetIPAddress -ErrorAction Stop | Where-Object AddressState -eq 'Preferred')
    $routes = @(Get-NetRoute -ErrorAction Stop | Where-Object DestinationPrefix -in @('0.0.0.0/0', '::/0'))
    $links = @(); $virtualMetrics = @{ IPv4 = 0; IPv6 = 0 }; $physical = @()
    foreach ($adapter in $adapters) {
        $profile = @($profiles | Where-Object InterfaceIndex -eq $adapter.ifIndex | Select-Object -First 1)
        $profileName = if ($profile.Count) { [string]$profile[0].Name } else { '' }
        $kind = Get-AdapterKind $adapter $profileName $Overrides
        foreach ($family in @('IPv4', 'IPv6')) {
            $iface = @($ipInterfaces | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex -and [string]$_.AddressFamily -eq $family } | Select-Object -First 1)
            $defaults = @($routes | Where-Object { $_.InterfaceIndex -eq $adapter.ifIndex -and [string]$_.AddressFamily -eq $family } | Sort-Object RouteMetric)
            if (-not $iface.Count -or -not $defaults.Count) { continue }
            $total = [int]$iface[0].InterfaceMetric + [int]$defaults[0].RouteMetric
            if ($kind -eq 'Virtual') { $virtualMetrics[$family] = [Math]::Max($virtualMetrics[$family], $total); continue }
            $source = @($addresses | Where-Object {
                $_.InterfaceIndex -eq $adapter.ifIndex -and [string]$_.AddressFamily -eq $family -and
                $_.IPAddress -notmatch '^(169\.254\.|fe80:|::1$)' -and -not $_.SkipAsSource
            } | Select-Object -First 1)
            if (-not $source.Count) { continue }
            $probe = [EthernetFirst.Probe]::Check([int]$adapter.ifIndex, [string]$source[0].IPAddress, $ProbeTargets[$family], 1200)
            $key = "$($adapter.InterfaceGuid)/$family"
            if ($probe -eq -1) { $Health.Remove($key); $healthy=$null }
            else { $healthy = Update-Health $Health $key ($probe -eq 1) }
            $links += [pscustomobject]@{
                Guid = [string]$adapter.InterfaceGuid; Index = [int]$adapter.ifIndex
                Name = [string]$adapter.Name; Kind = $kind; Family = $family
                Healthy = $healthy; ProbeSuccess = ($probe -eq 1); ProbeBlocked = ($probe -eq -1); Metric = [int]$iface[0].InterfaceMetric
                Automatic = [string]$iface[0].AutomaticMetric; RouteMetric = [int]$defaults[0].RouteMetric
                TotalMetric = $total; LinkSpeed = [string]$adapter.LinkSpeed
            }
        }
        if ($kind -ne 'Virtual') {
            $stats = Get-NetAdapterStatistics -Name $adapter.Name -ErrorAction SilentlyContinue
            if ($stats) { $physical += [pscustomobject]@{ Guid=[string]$adapter.InterfaceGuid; Name=$adapter.Name; Kind=$kind; Bytes=([double]$stats.ReceivedBytes + [double]$stats.SentBytes) } }
        }
    }
    [pscustomobject]@{ Links=$links; Traffic=$physical; VirtualMetrics=$virtualMetrics }
}

function Set-PriorityPlan {
    param([object[]]$Plan, [string]$BackupPath)
    $backup = @()
    if (Test-Path -LiteralPath $BackupPath) { $backup = @(Read-JsonArray $BackupPath) }
    foreach ($item in $Plan) {
        # Resolve stable GUID again: Windows interface indexes change after reconnects.
        $adapter = @(Get-NetAdapter | Where-Object { [string]$_.InterfaceGuid -eq $item.Guid })
        if ($adapter.Count -ne 1) { continue }
        $current = Get-NetIPInterface -InterfaceIndex $adapter[0].ifIndex -AddressFamily $item.Family -ErrorAction Stop
        if ([int]$current.InterfaceMetric -eq $item.Metric -and [string]$current.AutomaticMetric -eq 'Disabled') { continue }
        if (-not @($backup | Where-Object { $_.Guid -eq $item.Guid -and $_.Family -eq $item.Family }).Count) {
            $backup += [pscustomobject]@{ Guid=$item.Guid; Family=$item.Family; Metric=[int]$current.InterfaceMetric; Automatic=[string]$current.AutomaticMetric }
            Write-AtomicJson $BackupPath @($backup)
        }
        Set-NetIPInterface -InterfaceIndex $adapter[0].ifIndex -AddressFamily $item.Family -AutomaticMetric Disabled -InterfaceMetric $item.Metric -ErrorAction Stop
    }
}

function Restore-Priorities {
    param([string]$BackupPath)
    if (-not (Test-Path -LiteralPath $BackupPath)) { return }
    $remaining = @()
    foreach ($saved in @(Read-JsonArray $BackupPath)) {
        $adapter = @(Get-NetAdapter -IncludeHidden | Where-Object { [string]$_.InterfaceGuid -eq $saved.Guid })
        if ($adapter.Count -ne 1) { $remaining += $saved; continue }
        try {
            Set-NetIPInterface -InterfaceIndex $adapter[0].ifIndex -AddressFamily $saved.Family -InterfaceMetric $saved.Metric -AutomaticMetric Disabled -ErrorAction Stop
            if ($saved.Automatic -eq 'Enabled') {
                Set-NetIPInterface -InterfaceIndex $adapter[0].ifIndex -AddressFamily $saved.Family -AutomaticMetric Enabled -ErrorAction Stop
            }
        } catch { $remaining += $saved; Write-Warning $_.Exception.Message }
    }
    Write-AtomicJson $BackupPath @($remaining)
    if ($remaining.Count) { throw 'Some adapters could not be restored. Reconnect them and run restore again; their backup was retained.' }
}
