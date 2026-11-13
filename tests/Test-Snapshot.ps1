$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$script:count=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }; $script:count++
}
$vpn=[pscustomobject]@{InterfaceGuid='vpn'; InterfaceDescription='VPN'; HardwareInterface=$false; MediaType='802.3'; PhysicalMediaType='802.3'}
Assert ((Get-AdapterKind $vpn '' @{vpn='Wired'}) -eq 'Virtual') 'A config override must never turn virtual hardware into a managed physical adapter'
$script:wirePresent=$true; $script:source='192.0.2.7'; $script:probe=1; $script:foreignProbe=$null; $script:osFailure=$false
function Get-NetAdapter {
    if ($script:osFailure) { throw 'OS snapshot failed' }
    if ($script:wirePresent) { [pscustomobject]@{InterfaceGuid='wired';ifIndex=11;Name='Ethernet';InterfaceDescription='Ethernet';HardwareInterface=$true;MediaType='802.3';PhysicalMediaType='802.3';Status='Up';LinkSpeed='1 Gbps'} }
    [pscustomobject]@{InterfaceGuid='vpn';ifIndex=55;Name='VPN';InterfaceDescription='VPN';HardwareInterface=$false;MediaType='IP';PhysicalMediaType='IP';Status='Up';LinkSpeed='1 Gbps'}
}
$script:profile='Cafe'
function Get-NetConnectionProfile { [pscustomobject]@{InterfaceIndex=11;Name=$script:profile} }
function Get-NetIPInterface {
    foreach ($i in @(11,55)) { [pscustomobject]@{InterfaceIndex=$i;AddressFamily='IPv4';InterfaceMetric=25;AutomaticMetric='Enabled'} }
}
function Get-NetIPAddress { [pscustomobject]@{InterfaceIndex=11;AddressFamily='IPv4';IPAddress=$script:source;AddressState='Preferred';SkipAsSource=$false} }
function Get-NetRoute {
    [pscustomobject]@{InterfaceIndex=11;AddressFamily='IPv4';RouteMetric=10;DestinationPrefix='0.0.0.0/0'}
    [pscustomobject]@{InterfaceIndex=55;AddressFamily='IPv4';RouteMetric=0;DestinationPrefix='0.0.0.0/0'}
}
function Get-DnsClientServerAddress { [pscustomobject]@{InterfaceIndex=11;ServerAddresses=@('192.0.2.1','2001:db8::53')} }
function Get-NetAdapterStatistics { [pscustomobject]@{ReceivedBytes=100;SentBytes=200} }
$script:calls=@()
function Invoke-LinkProbe {
    param($Index,$Source,$DnsServers,$DomesticEndpoints,$ForeignEndpoints,$TimeoutMs)
    $script:calls+=,[pscustomobject]@{Index=$Index;Source=$Source;Dns=@($DnsServers);Endpoints=@($ForeignEndpoints);Domestic=@($DomesticEndpoints)}
    $foreign=if ($null -eq $script:foreignProbe) {$script:probe} else {$script:foreignProbe}
    return @($script:probe,$foreign)
}
$h=@{}
$s=Get-NetworkSnapshot $h
$wired=@($s.Links | Where-Object Guid -eq 'wired')[0]
Assert ($script:calls.Count -eq 1) 'Only supported physical links should be probed'
Assert ($script:calls[0].Index -eq 11 -and $script:calls[0].Source -eq '192.0.2.7') 'HTTPS must use this adapter and source'
Assert ($script:calls[0].Dns.Count -eq 1 -and $script:calls[0].Dns[0] -eq '192.0.2.1') 'DNS must use the tested interface and source address family'
Assert ($script:calls[0].Endpoints.Count -eq 2 -and $script:calls[0].Endpoints[0] -like 'https://*') 'Default health must verify HTTPS endpoints'
Assert ($null -eq $wired.Healthy -and $wired.Good -eq 1 -and $wired.Bad -eq 0) 'One success is insufficient for failover'
Assert (@($s.Links | Where-Object Kind -eq 'Virtual').Count -eq 1) 'Virtual defaults must be visible to safe switching policy'
$s=Get-NetworkSnapshot $h
Assert (($s.Links | Where-Object Guid -eq 'wired').Good -eq 2) 'Snapshot must expose consecutive success counts'
$script:foreignProbe=0
for ($round=0; $round -lt 3; $round++) { $s=Get-NetworkSnapshot $h }
$row=@($s.Links | Where-Object Guid -eq 'wired')[0]
Assert ($row.DomesticGood -ge 2 -and $row.ForeignBad -eq 3 -and $row.Bad -eq 0) 'A foreign-only outage must preserve domestic health and its separate streak'
Assert ($script:calls[0].Domestic.Count -eq 2) 'Domestic reachability must use its own endpoint group'
Assert (@($s.Adapters | Where-Object Guid -eq 'wired').Count -eq 1) 'The dashboard must receive physical adapter inventory'
$script:foreignProbe=$null
$script:probe=0
$null=Get-NetworkSnapshot $h; $null=Get-NetworkSnapshot $h
$script:wirePresent=$false; $null=Get-NetworkSnapshot $h
$script:wirePresent=$true; $s=Get-NetworkSnapshot $h
Assert (($s.Links | Where-Object Guid -eq 'wired').Bad -eq 1) 'A missing adapter round must break the consecutive outage streak'
$null=Get-NetworkSnapshot $h
$script:source='192.0.2.8'; $s=Get-NetworkSnapshot $h
Assert (($s.Links | Where-Object Guid -eq 'wired').Bad -eq 1) 'A new source network must not inherit the old network outage streak'
$script:osFailure=$true
try { $null=Get-NetworkSnapshot $h } catch { }
Assert ($h.Count -eq 0) 'A failed overall snapshot must invalidate all consecutive evidence'
$script:osFailure=$false
$script:probe=1; $h.Clear()
$targets=@{Domestic=@('https://a.test/OK','https://b.test/OK');Foreign=@('https://c.test/OK','https://d.test/OK')}
$null=Get-NetworkSnapshot $h @{} $targets
$script:profile='cafe';$s=Get-NetworkSnapshot $h @{} $targets
$row=@($s.Links | Where-Object Guid -eq 'wired')[0]
Assert ($row.DomesticGood -eq 1 -and $row.ForeignGood -eq 1) 'A case-only SSID change must reset both profile streaks'
$targets.Domestic[0]='https://a.test/ok';$s=Get-NetworkSnapshot $h @{} $targets
$row=@($s.Links | Where-Object Guid -eq 'wired')[0]
Assert ($row.DomesticGood -eq 1 -and $row.ForeignGood -eq 2) 'A case-only HTTP path change must reset only that profile'
function Invoke-LinkProbe { return @(-1,-1) }
$s=Get-NetworkSnapshot $h
$wired=@($s.Links | Where-Object Guid -eq 'wired')[0]
Assert ($null -eq $wired.Healthy -and $wired.Good -eq 0 -and $wired.Bad -eq 0 -and $wired.ProbeBlocked) 'Unknown probes must reset streaks and never count as failed rounds'
Write-Output "PASS: $script:count snapshot assertions. No system settings changed."
