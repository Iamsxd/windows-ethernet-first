$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$module = Join-Path $PSScriptRoot '..\src\Switching.ps1'
if (-not (Test-Path -LiteralPath $module)) { throw 'RED: Switching.ps1 does not yet implement the switching contract.' }
. $module
$script:assertions = 0
$script:regressionFailures = @()
$script:realAtomicWriter=(Get-Command Write-AtomicJson).ScriptBlock
$script:atomicFailureHook=$null
function Write-AtomicJson {
    param([string]$Path,$Value)
    if ($script:atomicFailureHook) { & $script:atomicFailureHook $Path $Value }
    & $script:realAtomicWriter $Path $Value
}
function Test-Regression([string]$Name, [scriptblock]$Body) {
    try { & $Body } catch { $script:regressionFailures += ($Name+': '+$_.Exception.Message) }
}
function Assert-Switch($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:assertions++
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-Switch $threw $Message
}
function New-TestLink([string]$Guid, [string]$Kind, [string]$Family = 'IPv4', [int]$Metric = 25,
    [int]$Route = 0, [int]$Good = 0, [int]$Bad = 0, [bool]$Hardware = $true) {
    [pscustomobject]@{
        Guid=$Guid; Index=1; Name=$Guid; Kind=$Kind; Family=$Family; Metric=$Metric
        Automatic='Disabled'; RouteMetric=$Route; TotalMetric=($Metric+$Route)
        Healthy=($Good -ge 2); Good=$Good; Bad=$Bad; Hardware=$Hardware; ProbeBlocked=$false
    }
}
$now = [datetime]'2026-11-13T06:00:00Z'
$base = @((New-TestLink 'wire' Wired IPv4 10 20 0 3), (New-TestLink 'wifi' WiFi IPv4 20 40 2 0))
$decision = Get-SwitchDecision -Links $base -Mode Auto -Now $now
Assert-Switch ($decision.TargetGuid -eq 'wifi' -and @($decision.Plan).Count -eq 2) 'Three failures with two consecutive backup successes must permit failover.'
$target = @($decision.Plan | Where-Object Guid -eq wifi)[0]
$other = @($decision.Plan | Where-Object Guid -eq wire)[0]
Assert-Switch (($target.Metric + 40) -lt ($other.Metric + 20)) 'Priority must include route metrics, not compare interface metrics alone.'
Assert-Switch (@((Get-SwitchDecision -Links $base -Mode Monitor -Now $now).Plan).Count -eq 0) 'Monitor mode must never mutate settings.'
Assert-Switch (@((Get-SwitchDecision -Links $base -Mode Auto -Now $now -LastSwitch $now.AddSeconds(-179)).Plan).Count -eq 0) 'The cooldown must prevent a second automatic switch.'
Assert-Switch (@((Get-SwitchDecision -Links $base -Mode Auto -Now $now -LastSwitch $now.AddSeconds(-180)).Plan).Count -eq 2) 'The cooldown expires at its exact boundary.'
$notFailed = @((New-TestLink wire Wired IPv4 10 20 0 2), $base[1])
Assert-Switch (@((Get-SwitchDecision -Links $notFailed -Mode Auto -Now $now).Plan).Count -eq 0) 'Two failures must not cause automatic failover.'
$oneGood = @($base[0], (New-TestLink wifi WiFi IPv4 20 40 1 0))
Assert-Switch (@((Get-SwitchDecision -Links $oneGood -Mode Auto -Now $now).Plan).Count -eq 0) 'One good round or a previously latched healthy value must not qualify a backup.'
$bothBad = @($base[0], (New-TestLink wifi WiFi IPv4 20 40 0 3))
Assert-Switch (@((Get-SwitchDecision -Links $bothBad -Mode Auto -Now $now).Plan).Count -eq 0) 'Two failed links must leave priorities unchanged.'
$healthy = @((New-TestLink wire Wired IPv4 10 20 2 0), $base[1])
Assert-Switch (@((Get-SwitchDecision -Links $healthy -Mode Auto -Now $now).Plan).Count -eq 0) 'A recovered preferred path must not trigger automatic switchback.'
Assert-Switch (@((Get-SwitchDecision -Links $bothBad -Mode WiFi -Now $now).Plan).Count -eq 2) 'A manual selection ignores probe health.'
$many = @($base + (New-TestLink extra Wired IPv4 70 0 2 0))
Assert-Switch (@((Get-SwitchDecision -Links $many -Mode Auto -Now $now).Plan).Count -eq 0) 'Several physical wired adapters require explicit selection.'
Assert-Switch (@((Get-SwitchDecision -Links $many -Mode Auto -ManagedGuids wire,wifi -Now $now).Plan).Count -eq 2) 'Explicit GUID selection may disambiguate extra adapters without modifying them.'
Assert-Switch (@((Get-SwitchDecision -Links @() -Mode Auto -Now $now).Plan).Count -eq 0) 'No adapter must be a safe no-op.'
$fake = @($base[0], (New-TestLink wifi WiFi IPv4 20 40 2 0 $false))
Assert-Switch (@((Get-SwitchDecision -Links $fake -Mode WiFi -Now $now).Plan).Count -eq 0) 'A virtual adapter relabeled as Wi-Fi must not be managed.'
$split = @($base + (New-TestLink wire Wired IPv6 60 0 0 3) + (New-TestLink wifi WiFi IPv6 10 0 2 0))
Assert-Switch (@((Get-SwitchDecision -Links $split -Mode Auto -Now $now).Plan).Count -eq 0) 'Different IPv4 and IPv6 default winners must pause automatic mode.'
$manual = Get-SwitchDecision -Links $split -Mode Wired -Now $now
Assert-Switch (@($manual.Plan).Count -eq 4) 'Manual preference must repair both available protocol families together.'
foreach ($family in @('IPv4','IPv6')) {
    $chosen = @($manual.Plan | Where-Object { $_.Guid -eq 'wire' -and $_.Family -eq $family })[0]
    $standby = @($manual.Plan | Where-Object { $_.Guid -eq 'wifi' -and $_.Family -eq $family })[0]
    $route = if ($family -eq 'IPv4') { 20 } else { 0 }
    $backupRoute = if ($family -eq 'IPv4') { 40 } else { 0 }
    Assert-Switch (($chosen.Metric+$route) -lt ($standby.Metric+$backupRoute)) "Manual preference must win $family without leaving an IPv6 bypass."
}
$missing6 = @($base + (New-TestLink wire Wired IPv6 10 0 0 3))
Assert-Switch (@((Get-SwitchDecision -Links $missing6 -Mode Auto -Now $now).Plan).Count -eq 0) 'A backup missing an active protocol cannot be an automatic target.'
Assert-Switch (@((Get-SwitchDecision -Links $missing6 -Mode WiFi -Now $now).Plan).Count -eq 0) 'A manual switch cannot claim success while leaving IPv6 on the former path.'
$dual = @($base + (New-TestLink wire Wired IPv6 10 0 2 0) + (New-TestLink wifi WiFi IPv6 20 0 2 0))
Assert-Switch (@((Get-SwitchDecision -Links $dual -Mode Auto -Now $now).Plan).Count -eq 0) 'A working active family must prevent whole-path failure classification.'
$vpn = @($base + (New-TestLink vpn Virtual IPv4 1 0 0 0 $false))
Assert-Switch (@((Get-SwitchDecision -Links $vpn -Mode Auto -Now $now).Plan).Count -eq 0) 'An existing VPN default winner must stop automatic switching.'
Assert-Switch (@((Get-SwitchDecision -Links $vpn -Mode WiFi -Now $now).Plan).Count -eq 0) 'Manual switching must not take control away from a VPN.'
$blocked = @((New-TestLink wire Wired IPv4 10 20 0 3), $base[1]); $blocked[0].ProbeBlocked=$true
Assert-Switch (@((Get-SwitchDecision -Links $blocked -Mode Auto -Now $now).Plan).Count -eq 0) 'A more-specific VPN takeover reported by probes must pause automation.'
$tied = @((New-TestLink wire Wired IPv4 10 0 0 3), (New-TestLink wifi WiFi IPv4 10 0 2 0))
Assert-Switch (@((Get-SwitchDecision -Links $tied -Mode Auto -Now $now).Plan).Count -eq 0) 'An ambiguous real route winner must not be guessed.'
$impossible = @((New-TestLink wire Wired IPv4 10 0 0 3), (New-TestLink wifi WiFi IPv4 10 20000 2 0))
Assert-Switch (@((Get-SwitchDecision -Links $impossible -Mode WiFi -Now $now).Plan).Count -eq 0) 'An impossible metric ranking must reject the whole plan.'
$separator = @($base + (New-TestLink external Other IPv4 45 0 0 0))
Assert-Switch (@((Get-SwitchDecision -Links $separator -Mode WiFi -Now $now).Plan).Count -eq 0) 'A switch must not reorder an unrelated default between the two managed paths.'
$vpnBackup = @($base + (New-TestLink vpn Virtual IPv4 80 0 0 0 $false))
$safe = Get-SwitchDecision -Links $vpnBackup -Mode Auto -Now $now
Assert-Switch (@($safe.Plan).Count -eq 2) 'An inactive VPN default need not block safe physical preference changes.'
Assert-Switch (@($safe.Plan | Where-Object { ($_.Metric + $_.RouteMetric) -ge 80 }).Count -eq 0) 'A physical switch must preserve the inactive VPN default priority relationship.'

# The only OS mutations are replaced at the cmdlet boundary; ledgers are real temporary JSON files.
$script:adapters=@{}; $script:interfaces=@{}; $script:routes=@{}; $script:writes=0; $script:failAt=0; $script:ignoreAt=0; $script:changeRouteAt=0; $script:addIPv6At=0; $script:removeAt=0; $script:addVpnAt=0; $script:externalAt=0; $script:externalGuid=''; $script:externalMetric=0
function Reset-TestNetwork {
    $script:adapters=@{
        wire=[pscustomobject]@{InterfaceGuid='wire';ifIndex=7;HardwareInterface=$true;Status='Up'}
        wifi=[pscustomobject]@{InterfaceGuid='wifi';ifIndex=8;HardwareInterface=$true;Status='Up'}
    }
    $script:interfaces=@{
        'wire/IPv4'=[pscustomobject]@{InterfaceMetric=25;AutomaticMetric='Enabled'}
        'wifi/IPv4'=[pscustomobject]@{InterfaceMetric=35;AutomaticMetric='Disabled'}
    }
    $script:routes=@{'wire/IPv4'=0;'wifi/IPv4'=0}
    $script:writes=0; $script:failAt=0; $script:ignoreAt=0; $script:changeRouteAt=0; $script:addIPv6At=0; $script:removeAt=0; $script:addVpnAt=0; $script:externalAt=0; $script:externalGuid=''; $script:externalMetric=0
    $script:atomicFailureHook=$null
}
function Add-TestVpn {
    $script:adapters.vpn=[pscustomobject]@{InterfaceGuid='vpn';ifIndex=99;HardwareInterface=$false;Status='Up'}
    $script:routes['vpn/IPv4']=0
    $script:interfaces['vpn/IPv4']=[pscustomobject]@{InterfaceMetric=60;AutomaticMetric='Disabled'}
}
function Get-NetAdapter { param([switch]$IncludeHidden,$ErrorAction) $script:adapters.Values }
function Get-NetIPInterface {
    param($InterfaceIndex,$AddressFamily,$ErrorAction)
    $adapter=@($script:adapters.Values | Where-Object ifIndex -eq $InterfaceIndex)
    if ($adapter.Count -ne 1) { throw 'Adapter disappeared.' }
    $key="$($adapter[0].InterfaceGuid)/$AddressFamily"
    if (-not $script:interfaces.ContainsKey($key)) { throw 'IP interface disappeared.' }
    $value=$script:interfaces[$key]
    [pscustomobject]@{InterfaceMetric=$value.InterfaceMetric;AutomaticMetric=$value.AutomaticMetric}
}
function Set-NetIPInterface {
    param($InterfaceIndex,$AddressFamily,$InterfaceMetric,$AutomaticMetric,$ErrorAction)
    $script:writes++
    if ($script:writes -eq $script:removeAt) { $script:adapters.Remove('wifi') }
    if ($script:writes -eq $script:failAt) { throw 'Injected write failure.' }
    if ($script:writes -eq $script:ignoreAt) { return }
    $adapter=@($script:adapters.Values | Where-Object ifIndex -eq $InterfaceIndex)
    if ($adapter.Count -ne 1) { throw 'A stale interface index was used.' }
    $value=$script:interfaces["$($adapter[0].InterfaceGuid)/$AddressFamily"]
    if ($PSBoundParameters.ContainsKey('InterfaceMetric')) { $value.InterfaceMetric=[long]$InterfaceMetric }
    if ($PSBoundParameters.ContainsKey('AutomaticMetric')) { $value.AutomaticMetric=[string]$AutomaticMetric }
    if ($script:writes -eq $script:changeRouteAt) { $script:routes['wifi/IPv4']=1000 }
    if ($script:writes -eq $script:addIPv6At) {
        $script:routes['wire/IPv6']=0
        $script:interfaces['wire/IPv6']=[pscustomobject]@{InterfaceMetric=10;AutomaticMetric='Disabled'}
    }
    if ($script:writes -eq $script:addVpnAt) { Add-TestVpn }
    if ($script:writes -eq $script:externalAt) {
        $script:interfaces[($script:externalGuid+'/IPv4')].InterfaceMetric=$script:externalMetric
        $script:interfaces[($script:externalGuid+'/IPv4')].AutomaticMetric='Disabled'
    }
}
function Get-NetRoute {
    param($ErrorAction)
    foreach ($key in $script:routes.Keys) {
        $parts=$key.Split('/')
        if (-not $script:adapters.ContainsKey($parts[0])) { continue }
        $prefix=if ($parts[1] -eq 'IPv4') { '0.0.0.0/0' } else { '::/0' }
        [pscustomobject]@{InterfaceIndex=$script:adapters[$parts[0]].ifIndex;AddressFamily=$parts[1];DestinationPrefix=$prefix;RouteMetric=$script:routes[$key]}
    }
}
$tempRoot=Join-Path ([IO.Path]::GetTempPath()) ('switching-tests-'+[guid]::NewGuid())
[IO.Directory]::CreateDirectory($tempRoot) | Out-Null
$baseline=Join-Path $tempRoot 'original.json'; $expected=Join-Path $tempRoot 'expected.json'
$plan=@(
    [pscustomobject]@{Guid='wire';Family='IPv4';Metric=100;Kind='Wired';Index=1;TargetGuid='wifi'},
    [pscustomobject]@{Guid='wifi';Family='IPv4';Metric=50;Kind='WiFi';Index=2;TargetGuid='wifi'}
)
function Clear-TestLedgers { Get-ChildItem -LiteralPath $tempRoot -File | Remove-Item -Force }
try {
    Reset-TestNetwork
    Assert-Switch (Test-ManagedMetrics -ExpectedPath $expected) 'No expected ledger must not report an external modification.'
    Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected | Out-Null
    $saved=@(Read-JsonArray $baseline)
    Assert-Switch ($saved.Count -eq 2 -and @($saved | Where-Object Guid -eq wire)[0].Metric -eq 25) 'The baseline must save settings from before the first modification.'
    Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Disabled' -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 50) 'The transaction must apply all requested metrics.'
    Assert-Switch (Test-ManagedMetrics -ExpectedPath $expected) 'Successful readback must establish an expected last-applied state.'
    $writes=$script:writes
    Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected | Out-Null
    Assert-Switch ($script:writes -eq $writes) 'Reapplying the same settings must not write again.'
    $script:adapters.wire.ifIndex=77; $script:adapters.wifi.ifIndex=88
    $plan2=@($plan | ForEach-Object { [pscustomobject]@{Guid=$_.Guid;Family=$_.Family;Metric=($_.Metric+5);Kind=$_.Kind;Index=$_.Index} })
    Set-SwitchPlan -Plan $plan2 -BackupPath $baseline -ExpectedPath $expected | Out-Null
    Assert-Switch (@(Read-JsonArray $baseline | Where-Object Guid -eq wire)[0].Metric -eq 25) 'Later switches and a changed interface index must not replace the original baseline.'
    $script:interfaces['wifi/IPv4'].InterfaceMetric=777
    Assert-Switch (-not (Test-ManagedMetrics -ExpectedPath $expected)) 'An external metric modification must be detected.'
    $before=$script:writes
    Assert-Throws { Restore-SwitchMetrics -BackupPath $baseline -ExpectedPath $expected } 'Restore must require explicit confirmation before overwriting an external change.'
    Assert-Switch ($script:writes -eq $before -and (Test-Path -LiteralPath $baseline)) 'A refused restore must neither write nor lose the baseline.'
    $script:adapters.wire.Status='Disconnected'
    Restore-SwitchMetrics -BackupPath $baseline -ExpectedPath $expected -Force | Out-Null
    Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Enabled' -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35) 'Restore must include disconnected adapters and the original automatic-metric switch.'
    Assert-Switch (-not (Test-Path -LiteralPath $baseline) -and -not (Test-Path -LiteralPath $expected)) 'A successful restore ends the baseline and expected state.'

    Clear-TestLedgers; Reset-TestNetwork
    $script:interfaces['wire/IPv4'].InterfaceMetric=100; $script:interfaces['wire/IPv4'].AutomaticMetric='Disabled'
    $script:interfaces['wifi/IPv4'].InterfaceMetric=50
    Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected | Out-Null
    Assert-Switch ($script:writes -eq 0 -and -not (Test-Path -LiteralPath $baseline)) 'An already-applied preference must not fabricate an original-settings baseline.'
    Restore-SwitchMetrics -BackupPath $baseline -ExpectedPath $expected | Out-Null
    Assert-Switch (-not (Test-Path -LiteralPath $expected)) 'Ending a no-write preference must also end expected-state ownership.'

    Clear-TestLedgers; Reset-TestNetwork; $script:failAt=2
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A mid-transaction write failure must be reported.'
    Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Enabled' -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35) 'A mid-transaction failure must roll back the entire operation.'
    Assert-Switch (-not (Test-Path -LiteralPath $expected)) 'A failed first operation must not publish its desired state as applied.'
    Assert-Switch (Test-Path -LiteralPath $baseline) 'A failed operation must preserve the recovery baseline.'

    Clear-TestLedgers; Reset-TestNetwork; $script:ignoreAt=2
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A silently ignored OS write must fail readback.'
    Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Enabled' -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35) 'Readback failure must roll back every changed interface.'

    Clear-TestLedgers; Reset-TestNetwork; $script:changeRouteAt=2
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A concurrent DHCP/default route metric change must fail actual-route verification.'
    Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Enabled' -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35) 'Actual-route verification failure must restore the pre-operation metrics.'

    Clear-TestLedgers; Reset-TestNetwork; $script:addIPv6At=2
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A protocol appearing during the operation must not bypass the selected default.'
    Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Enabled' -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35) 'A newly acquired IPv6 default must roll back a now-incomplete switch.'

    Clear-TestLedgers; Reset-TestNetwork
    $script:routes['wire/IPv6']=0
    $script:interfaces['wire/IPv6']=[pscustomobject]@{InterfaceMetric=10;AutomaticMetric='Disabled'}
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A stale IPv4-only plan must reject a newly active IPv6 default before mutation.'
    Assert-Switch ($script:writes -eq 0) 'All currently active families must be covered before the first write.'
    $splitPlan=@($plan + [pscustomobject]@{Guid='wire';Family='IPv6';Metric=50;Kind='Wired';TargetGuid='wire'})
    Assert-Throws { Set-SwitchPlan -Plan $splitPlan -BackupPath $baseline -ExpectedPath $expected } 'A forged plan cannot choose different default targets for different protocols.'
    Assert-Switch ($script:writes -eq 0) 'Cross-protocol consistency must be checked before writes.'

    Clear-TestLedgers; Reset-TestNetwork; Add-TestVpn
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A stale plan must not move the former physical path behind an unrelated VPN backup.'
    Assert-Switch ($script:writes -eq 0 -and $script:interfaces['vpn/IPv4'].InterfaceMetric -eq 60) 'Live unrelated priority bounds must be verified before any write.'
    Clear-TestLedgers; Reset-TestNetwork; $script:addVpnAt=2
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A new VPN default during application must preserve its relation to both physical paths.'
    Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Enabled' -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35 -and $script:interfaces['vpn/IPv4'].InterfaceMetric -eq 60) 'Concurrent unrelated-route conflict must roll back only the managed interface settings.'

    Clear-TestLedgers; Reset-TestNetwork
    Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected | Out-Null
    $oldExpected=Get-Content -LiteralPath $expected -Raw
    $script:failAt=$script:writes+2
    Assert-Throws { Set-SwitchPlan -Plan $plan2 -BackupPath $baseline -ExpectedPath $expected } 'A later operation must retain the previous successful state when it fails.'
    Assert-Switch ($script:interfaces['wire/IPv4'].InterfaceMetric -eq 100 -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 50) 'Rollback must use the immediate pre-operation state rather than the original baseline.'
    Assert-Switch ((Get-Content -LiteralPath $expected -Raw) -eq $oldExpected) 'A failed later operation must not replace the last-applied ledger.'

    Clear-TestLedgers; Reset-TestNetwork; $script:removeAt=2
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'Adapter removal during a write must report incomplete rollback.'
    Assert-Switch ((Test-Path -LiteralPath ($expected+'.pending.json')) -and -not (Test-ManagedMetrics $expected)) 'Incomplete rollback must keep a durable marker that pauses automation.'
    $before=$script:writes
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'An unresolved operation must block further switches.'
    Assert-Switch ($script:writes -eq $before) 'An unresolved journal must be checked before OS writes.'
    $script:adapters.wifi=[pscustomobject]@{InterfaceGuid='wifi';ifIndex=88;HardwareInterface=$true;Status='Disconnected'}
    Restore-SwitchMetrics -BackupPath $baseline -ExpectedPath $expected -Force | Out-Null
    Assert-Switch (-not (Test-Path -LiteralPath ($expected+'.pending.json')) -and -not (Test-Path -LiteralPath $baseline)) 'Explicit restore after adapter return must clear interrupted-operation recovery data.'

    Clear-TestLedgers; Reset-TestNetwork; $script:adapters.Remove('wifi')
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A missing adapter must reject the whole transaction.'
    Assert-Switch ($script:writes -eq 0) 'All adapter identities must be resolved before any write.'

    Clear-TestLedgers; Reset-TestNetwork
    Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected | Out-Null
    $script:adapters.Remove('wifi'); $before=$script:writes
    Assert-Throws { Restore-SwitchMetrics -BackupPath $baseline -ExpectedPath $expected -Force } 'A genuinely missing adapter must retain the original recovery baseline.'
    Assert-Switch ($script:writes -eq $before -and (Test-Path -LiteralPath $baseline)) 'Incomplete restoration must not change the remaining adapter or clear recovery data.'

    Clear-TestLedgers; Reset-TestNetwork
    $script:adapters.wifi.HardwareInterface=$false
    Assert-Throws { Set-SwitchPlan -Plan $plan -BackupPath $baseline -ExpectedPath $expected } 'A virtual adapter cannot be written even through a forged plan.'
    Assert-Switch ($script:writes -eq 0) 'Virtual-adapter protection must precede every OS write.'

    Test-Regression 'A original UInt32 metric remains recoverable' {
        Clear-TestLedgers; Reset-TestNetwork
        $script:interfaces['wire/IPv4'].InterfaceMetric=4294967295L
        $script:interfaces['wire/IPv4'].AutomaticMetric='Disabled'
        Set-SwitchPlan $plan $baseline $expected | Out-Null
        Restore-SwitchMetrics $baseline $expected | Out-Null
        Assert-Switch ($script:interfaces['wire/IPv4'].InterfaceMetric -eq 4294967295L) 'Restore must accept an original metric throughout the system UInt32 range.'
        $tooLarge=@([pscustomobject]@{Guid='wire';Family='IPv4';Metric=10000;Kind='Wired'})
        Assert-Throws { Set-SwitchPlan $tooLarge $baseline $expected } 'New managed plans must retain their conservative 1..9999 metric range.'
    }
    Test-Regression 'B baseline without lastApplied fails closed' {
        Clear-TestLedgers; Reset-TestNetwork; $script:failAt=2
        Assert-Throws { Set-SwitchPlan $plan $baseline $expected } 'The failed first switch is required for the restore-ownership regression.'
        $script:interfaces['wifi/IPv4'].InterfaceMetric=777
        $beforeWrites=$script:writes
        Assert-Throws { Restore-SwitchMetrics $baseline $expected } 'A failed first switch must not authorize overwriting later external settings.'
        Assert-Switch ($script:writes -eq $beforeWrites -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 777) 'Missing lastApplied must not permit an unconfirmed restore.'
        Assert-Switch (-not (Test-ManagedMetrics -ExpectedPath $expected -BackupPath $baseline)) 'An unowned or migrated baseline must pause automatic changes.'
        Restore-SwitchMetrics $baseline $expected -Force | Out-Null
    }
    Test-Regression 'C failed forced recovery retains the original pending evidence' {
        Clear-TestLedgers; Reset-TestNetwork; $script:removeAt=2
        Assert-Throws { Set-SwitchPlan $plan $baseline $expected } 'Create an interrupted operation for forced-recovery regression.'
        $pendingBefore=Get-Content -LiteralPath ($expected+'.pending.json') -Raw
        $script:adapters.wifi=[pscustomobject]@{InterfaceGuid='wifi';ifIndex=88;HardwareInterface=$true;Status='Disconnected'}
        $script:interfaces['wire/IPv4'].InterfaceMetric=100; $script:interfaces['wire/IPv4'].AutomaticMetric='Disabled'
        $script:interfaces['wifi/IPv4'].InterfaceMetric=50
        $script:failAt=$script:writes+3
        Assert-Throws { Restore-SwitchMetrics $baseline $expected -Force } 'An injected restore failure must return to its immediate pre-restore partial state.'
        Assert-Switch ((Test-Path -LiteralPath ($expected+'.pending.json')) -and (Get-Content -LiteralPath ($expected+'.pending.json') -Raw) -eq $pendingBefore) 'Failed forced restore must preserve the original journal byte for byte.'
        Assert-Switch (-not (Test-ManagedMetrics -ExpectedPath $expected -BackupPath $baseline)) 'Failed forced restoration must never release automatic control.'
    }
    Test-Regression 'D1 unattempted row keeps an external edit' {
        Clear-TestLedgers; Reset-TestNetwork
        $script:externalAt=1; $script:externalGuid='wifi'; $script:externalMetric=777
        Assert-Throws { Set-SwitchPlan $plan $baseline $expected } 'A pre-write external edit to the next interface must stop the transaction.'
        Assert-Switch ($script:interfaces['wifi/IPv4'].InterfaceMetric -eq 777) 'Rollback must never overwrite an interface this operation did not touch.'
        Assert-Switch ($script:interfaces['wire/IPv4'].AutomaticMetric -eq 'Enabled') 'The owned first interface should still roll back.'
        Assert-Switch (-not (Test-ManagedMetrics -ExpectedPath $expected -BackupPath $baseline)) 'An ownership conflict must retain recovery evidence.'
    }
    Test-Regression 'D2 attempted row keeps a later external edit' {
        Clear-TestLedgers; Reset-TestNetwork
        $script:externalAt=2; $script:externalGuid='wire'; $script:externalMetric=777
        Assert-Throws { Set-SwitchPlan $plan $baseline $expected } 'An external edit after the first write must be detected at final readback.'
        Assert-Switch ($script:interfaces['wire/IPv4'].InterfaceMetric -eq 777) 'Rollback must not overwrite a touched interface whose current value is no longer owned.'
        Assert-Switch ($script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35) 'Other still-owned writes should roll back even when one conflicts.'
        Assert-Switch (Test-Path -LiteralPath ($expected+'.pending.json')) 'An incomplete ownership rollback must retain the journal.'
    }
    Test-Regression 'E1 automatic plan cannot act on an already changed current path' {
        Clear-TestLedgers; Reset-TestNetwork
        $sample=@((New-TestLink wire Wired IPv4 25 0 0 3),(New-TestLink wifi WiFi IPv4 35 0 2 0))
        $autoPlan=@((Get-SwitchDecision $sample Auto -Now $now).Plan)
        $script:interfaces['wire/IPv4'].InterfaceMetric=40
        Assert-Throws { Set-SwitchPlan $autoPlan $baseline $expected } 'Automatic commit must still have the same uniquely failing current GUID.'
        Assert-Switch ($script:writes -eq 0) 'A Windows-completed fallback must not be overwritten by a stale automatic decision.'
        $script:interfaces['wire/IPv4'].InterfaceMetric=35
        Assert-Throws { Set-SwitchPlan $autoPlan $baseline $expected } 'Automatic commit must reject a newly tied live default.'
    }
    Test-Regression 'E0 a fresh automatic sample commits while manual ties remain repairable' {
        Clear-TestLedgers; Reset-TestNetwork
        $sample=@((New-TestLink wire Wired IPv4 25 0 0 3),(New-TestLink wifi WiFi IPv4 35 0 2 0))
        $autoPlan=@((Get-SwitchDecision $sample Auto -Now $now).Plan)
        Set-SwitchPlan $autoPlan $baseline $expected | Out-Null
        Assert-Switch ($script:interfaces['wire/IPv4'].InterfaceMetric -eq 36 -and $script:interfaces['wifi/IPv4'].InterfaceMetric -eq 35) 'Fresh automatic metadata must allow its intended failover.'
        Clear-TestLedgers; Reset-TestNetwork
        $script:interfaces['wire/IPv4'].InterfaceMetric=35
        $manualPlan=@((Get-SwitchDecision @((New-TestLink wire Wired IPv4 35),(New-TestLink wifi WiFi IPv4 35)) WiFi).Plan)
        Set-SwitchPlan $manualPlan $baseline $expected | Out-Null
        Assert-Switch ($script:interfaces['wire/IPv4'].InterfaceMetric -gt $script:interfaces['wifi/IPv4'].InterfaceMetric) 'Manual selection must still repair a tied live default.'
    }
    Test-Regression 'E2 automatic topology change is rejected even when priority is safe' {
        Clear-TestLedgers; Reset-TestNetwork
        $sample=@((New-TestLink wire Wired IPv4 25 0 0 3),(New-TestLink wifi WiFi IPv4 35 0 2 0))
        $autoPlan=@((Get-SwitchDecision $sample Auto -Now $now).Plan)
        Add-TestVpn
        Assert-Throws { Set-SwitchPlan $autoPlan $baseline $expected } 'A new third default adapter must invalidate an automatic sample.'
        Assert-Switch ($script:writes -eq 0) 'Automatic topology invalidation must precede every write.'
    }
    Test-Regression 'E3 automatic dual-stack current must still match both sampled families' {
        Clear-TestLedgers; Reset-TestNetwork
        $sample=@((New-TestLink wire Wired IPv4 25 0 0 3),(New-TestLink wifi WiFi IPv4 35 0 2 0),
            (New-TestLink wire Wired IPv6 25 0 0 3),(New-TestLink wifi WiFi IPv6 35 0 2 0))
        $autoPlan=@((Get-SwitchDecision $sample Auto -Now $now).Plan)
        $script:interfaces['wire/IPv6']=[pscustomobject]@{InterfaceMetric=40;AutomaticMetric='Disabled'}
        $script:interfaces['wifi/IPv6']=[pscustomobject]@{InterfaceMetric=35;AutomaticMetric='Disabled'}
        $script:routes['wire/IPv6']=0; $script:routes['wifi/IPv6']=0
        Assert-Throws { Set-SwitchPlan $autoPlan $baseline $expected } 'A newly split live IPv4/IPv6 default must invalidate automatic failover.'
        Assert-Switch ($script:writes -eq 0) 'A stale automatic split cannot be repaired without a manual selection.'
    }
    Test-Regression 'F unchanged original ledger is never rewritten' {
        Clear-TestLedgers; Reset-TestNetwork
        Set-SwitchPlan $plan $baseline $expected | Out-Null
        $sentinel=([datetimeoffset]'2001-01-01T00:00:00Z').UtcDateTime
        [IO.File]::SetLastWriteTimeUtc($baseline,$sentinel)
        Set-SwitchPlan $plan2 $baseline $expected | Out-Null
        Assert-Switch ([IO.File]::GetLastWriteTimeUtc($baseline) -eq $sentinel) 'A later switch without new original rows must not rewrite the permanent baseline.'
    }
    Test-Regression 'D3 a failed intent journal never makes an unissued write owned' {
        Clear-TestLedgers; Reset-TestNetwork
        $script:atomicFailureHook={
            param($Path,$Value)
            if ($Path -eq ($expected+'.pending.json') -and $Value.Attempts.Count -and $Value.Attempts[0].Owned.Count) {
                $script:atomicFailureHook=$null
                $script:interfaces['wire/IPv4'].InterfaceMetric=100
                $script:interfaces['wire/IPv4'].AutomaticMetric='Disabled'
                throw 'Injected intent-persistence failure accompanied by an external edit.'
            }
        }
        Assert-Throws { Set-SwitchPlan $plan $baseline $expected } 'Intent persistence failure must stop before any cmdlet write.'
        Assert-Switch ($script:writes -eq 0 -and $script:interfaces['wire/IPv4'].InterfaceMetric -eq 100) 'Rollback cannot own or overwrite a row whose OS write was never issued.'
        Assert-Switch (Test-Path -LiteralPath ($expected+'.pending.json')) 'The unissued-write ownership conflict must retain its journal.'
    }
    if ($script:regressionFailures.Count) { throw ($script:regressionFailures -join [Environment]::NewLine) }
} finally {
    # This absolute path was created by this test under the OS temp directory.
    if ([IO.Path]::GetFullPath($tempRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force
    }
}
Write-Output "PASS: $script:assertions switching assertions; OS calls mocked; no host networking changed."
