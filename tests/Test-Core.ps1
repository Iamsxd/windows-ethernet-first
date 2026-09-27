$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$script:count=0
function Assert($Condition,[string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:count++
}
function Adapter($Description,$Hardware,$Media) {
    [pscustomobject]@{ InterfaceGuid='guid'; InterfaceDescription=$Description; HardwareInterface=$Hardware; MediaType=$Media; PhysicalMediaType=$Media }
}
function Link($Kind,$Healthy,$Route=0) {
    [pscustomobject]@{ Guid=$Kind; Index=1; Family='IPv4'; Name=$Kind; Kind=$Kind; Healthy=$Healthy; RouteMetric=$Route }
}
Assert ((Get-AdapterKind (Adapter 'Apple Mobile Device Ethernet' $true '802.3')) -eq 'Mobile') 'iPhone USB must not be classified as ordinary Ethernet'
Assert ((Get-AdapterKind (Adapter 'Realtek USB GbE Family Controller' $true '802.3')) -eq 'Wired') 'A USB Ethernet dongle is wired, not tethering'
Assert ((Get-AdapterKind (Adapter 'Remote NDIS Compatible Device' $true '802.3')) -eq 'Mobile') 'RNDIS tethering should be recognized'
Assert ((Get-AdapterKind (Adapter 'WireGuard Tunnel' $false 'IP')) -eq 'Virtual') 'VPN must be excluded'
Assert ((Get-AdapterKind (Adapter 'Intel WiFi' $true 'Native 802.11') 'My iPhone') -eq 'Mobile') 'iPhone Wi-Fi hotspot should be recognized'
Assert ((Get-AdapterKind (Adapter 'Intel WiFi' $true 'Native 802.11') 'CoffeeShop') -eq 'WiFi') 'Unknown Wi-Fi must not be claimed to be a phone'
Assert ((Get-AdapterKind (Adapter 'Unknown' $true '802.3') '' @{guid='Mobile'}) -eq 'Mobile') 'Explicit override must win'
$plan=@(Get-PriorityPlan @((Link 'Wired' $true),(Link 'Mobile' $true),(Link 'WiFi' $true)) 5)
Assert (($plan | Where-Object Kind -eq Wired).Metric -lt ($plan | Where-Object Kind -eq Mobile).Metric) 'Healthy Ethernet should beat mobile'
Assert (($plan | Where-Object Kind -eq WiFi).Metric -lt ($plan | Where-Object Kind -eq Mobile).Metric) 'Wi-Fi should beat USB tethering'
Assert (($plan | Where-Object Kind -eq Wired).Metric -gt 5) 'Existing VPN default must retain priority'
$plan=@(Get-PriorityPlan @((Link 'Wired' $false),(Link 'Mobile' $true)) 1200)
Assert (($plan | Where-Object Kind -eq Mobile).Metric -lt ($plan | Where-Object Kind -eq Wired).Metric) 'Dead cable Internet should fail over to working mobile'
Assert (($plan | Where-Object Kind -eq Mobile).Metric -gt 1200) 'Unusual virtual metric must retain priority'
Assert (@(Get-PriorityPlan @((Link 'Wired' $null),(Link 'Mobile' $null))).Count -eq 0) 'Unknown connectivity must not change metrics'
Assert (@(Get-PriorityPlan @((Link 'Wired' $false),(Link 'Mobile' $false))).Count -eq 0) 'All-failed probes must not rewrite routes'
$plan=@(Get-PriorityPlan @((Link 'Wired' $true 100),(Link 'Mobile' $true 20)))
Assert (($plan | Where-Object Kind -eq Wired).Metric -eq 900) 'Must account for route metric, not just interface metric'
Assert (@(Get-PriorityPlan @((Link 'Wired' $true 12000))).Count -eq 0) 'Custom metrics must not overflow or invert intended priority'
$h=@{}
Assert ($null -eq (Update-Health $h 'a/IPv4' $true)) 'One success must not prematurely classify a connection'
Assert ((Update-Health $h 'a/IPv4' $true) -eq $true) 'Two successes establish health'
Assert ((Update-Health $h 'a/IPv4' $false) -eq $true) 'One failure must not trigger failover'
Assert ((Update-Health $h 'a/IPv4' $false) -eq $true) 'Two failures must not trigger failover'
Assert ((Update-Health $h 'a/IPv4' $false) -eq $false) 'Three failures trigger failover'
Assert ($null -eq (Update-Health $h 'a/IPv6' $true)) 'IPv6 health must be independent'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('ethernet-first-test-'+[Guid]::NewGuid()+'.json')
try {
    Write-AtomicJson $temp @()
    Assert ((Get-Content $temp -Raw) -match '^\s*\[\s*\]\s*$') 'Empty restore ledger must remain valid JSON'
} finally { Remove-Item -LiteralPath $temp -ErrorAction SilentlyContinue }
Add-Type -Path (Join-Path $PSScriptRoot '..\src\Probe.cs')
# Simulate OS calls to exercise backup/apply/restore without modifying this machine.
$script:mockIndex=7
$script:mockMetric=25
$script:mockAutomatic='Enabled'
$script:mockAvailable=$true
$script:mockWrites=0
function Get-NetAdapter {
    param([switch]$IncludeHidden)
    if ($script:mockAvailable) { [pscustomobject]@{InterfaceGuid='stable-guid';ifIndex=$script:mockIndex} }
}
function Get-NetIPInterface {
    param($InterfaceIndex,$AddressFamily,$ErrorAction)
    [pscustomobject]@{InterfaceMetric=$script:mockMetric;AutomaticMetric=$script:mockAutomatic}
}
function Set-NetIPInterface {
    param($InterfaceIndex,$AddressFamily,$InterfaceMetric,$AutomaticMetric,$ErrorAction)
    Assert ($InterfaceIndex -eq $script:mockIndex) 'Mutation must resolve the current interface index'
    $script:mockWrites++
    if ($PSBoundParameters.ContainsKey('InterfaceMetric')) { $script:mockMetric=[int]$InterfaceMetric }
    if ($PSBoundParameters.ContainsKey('AutomaticMetric')) { $script:mockAutomatic=[string]$AutomaticMetric }
}
$ledger=Join-Path ([IO.Path]::GetTempPath()) ('ethernet-first-ledger-'+[Guid]::NewGuid()+'.json')
$mockPlan=@([pscustomobject]@{Guid='stable-guid';Index=1;Family='IPv4';Metric=1000;Name='test';Kind='Wired'})
try {
    Set-PriorityPlan $mockPlan $ledger
    $original=@(Read-JsonArray $ledger)
    Assert ($original.Count -eq 1 -and $original[0].Metric -eq 25 -and $original[0].Automatic -eq 'Enabled') 'Must save original settings, not replacement values'
    $writes=$script:mockWrites
    Set-PriorityPlan $mockPlan $ledger
    Assert ($script:mockWrites -eq $writes) 'Unchanged policy must not write repeatedly'
    $script:mockIndex=77
    Restore-Priorities $ledger
    Assert ($script:mockMetric -eq 25 -and $script:mockAutomatic -eq 'Enabled') 'Restore must re-enable automatic metric'
    Assert (@(Read-JsonArray $ledger).Count -eq 0) 'Successful restoration clears the ledger'
    Set-PriorityPlan $mockPlan $ledger
    $script:mockAvailable=$false
    $failed=$false
    try { Restore-Priorities $ledger } catch { $failed=$true }
    Assert $failed 'Missing adapter must report incomplete restoration'
    Assert (@(Read-JsonArray $ledger).Count -eq 1) 'Missing adapter backup must be retained'
} finally { Remove-Item -LiteralPath $ledger -ErrorAction SilentlyContinue }
# A loopback listener is deliberately not used: public reachability must not be inferred from localhost.
Write-Output "PASS: $script:count assertions; socket probe compiled. No system settings changed."
