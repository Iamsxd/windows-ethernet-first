$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
. (Join-Path $PSScriptRoot '..\src\Switching.ps1')
$count=0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:count++ }
function Link($Guid,$Kind,$Metric,$Good,$Bad,$ForeignGood=0,$ForeignBad=0,$Family='IPv4') {
    [pscustomobject]@{Guid=$Guid;Index=1;Name=$Guid;Kind=$Kind;Family=$Family;Metric=$Metric;RouteMetric=0;TotalMetric=$Metric;Hardware=$true;Healthy=($Good -ge 2);Good=$Good;Bad=$Bad;ProbeBlocked=$false;ForeignGood=$ForeignGood;ForeignBad=$ForeignBad;ForeignProbeBlocked=$false}
}
$now=[DateTime]'2026-11-13T08:00:00Z'
$recovered=@((Link wire Wired 20 2 0 2),(Link wifi WiFi 10 3 0 0 3))
Assert (@((Get-SwitchDecision $recovered Auto -Now $now).Plan).Count -eq 0) 'Returning to wired must remain opt-in even when foreign access recovers'
$d=Get-SwitchDecision $recovered Auto -Now $now -ReturnToWired
Assert ($d.TargetGuid -eq 'wire' -and $d.Plan.Count -eq 2) 'Enabled recovery must return to twice-confirmed domestic and foreign wired service'
Assert (@($d.Plan | Where-Object { $_.ControlMode -ne 'Auto' -or $_.ExpectedCurrentGuid -ne 'wifi' }).Count -eq 0) 'Recovery must retain automatic commit preconditions rather than masquerade as manual control'
Assert (@((Get-SwitchDecision $recovered Auto -Now $now -LastSwitch $now.AddSeconds(-179) -ReturnToWired).Plan).Count -eq 0) 'Recovery must honor the same cooldown'
$foreignOnly=@((Link wire Wired 10 3 0 0 3),(Link wifi WiFi 20 3 0 0 3))
Assert (@((Get-SwitchDecision $foreignOnly Auto -Now $now -ReturnToWired).Plan).Count -eq 0) 'Foreign-only failure must never cause domestic-capable links to oscillate'
$fallback=@((Link wire Wired 10 0 3 0 3),(Link wifi WiFi 20 2 0 0 3))
$d=Get-SwitchDecision $fallback Auto -Now $now
Assert ($d.TargetGuid -eq 'wifi' -and $d.Plan.Count -eq 2) 'Domestic-only Wi-Fi is a valid fallback for a fully failed current domestic path'
$notRecovered=@((Link wire Wired 20 2 0 1),(Link wifi WiFi 10 3 0 0 3))
Assert (@((Get-SwitchDecision $notRecovered Auto -Now $now -ReturnToWired).Plan).Count -eq 0) 'One foreign success is insufficient for return'
$unknown=@((Link wire Wired 20 2 0 2),(Link wifi WiFi 10 3 0 0 3)); $unknown[0].ForeignProbeBlocked=$true
Assert (@((Get-SwitchDecision $unknown Auto -Now $now -ReturnToWired).Plan).Count -eq 0) 'Unknown foreign binding must not authorize wired recovery'
$dual=@($recovered + (Link wire Wired 20 2 0 1 0 IPv6) + (Link wifi WiFi 10 3 0 0 3 IPv6))
Assert (@((Get-SwitchDecision $dual Auto -Now $now -ReturnToWired).Plan).Count -eq 0) 'Every active protocol must confirm both profiles before return'
Assert (@((Get-SwitchDecision $recovered Monitor -Now $now -ReturnToWired).Plan).Count -eq 0) 'The preference must not activate control in Monitor mode'
$inventory=@([pscustomobject]@{Guid='wire';Kind='Wired'},[pscustomobject]@{Guid='unplugged-wire';Kind='Wired'},[pscustomobject]@{Guid='wifi';Kind='WiFi'})
Assert (@((Get-SwitchDecision $fallback Auto -Now $now -Adapters $inventory).Plan).Count -eq 0) 'Disconnected extra candidates must require the same explicit selection as the dashboard'
Assert (@((Get-SwitchDecision $fallback Wired -Now $now -Adapters $inventory).Plan).Count -eq 0) 'Tray manual commands must use the same candidate rule'
Assert (@((Get-SwitchDecision $fallback Auto -Now $now -Adapters $inventory -ManagedGuids @('wire','wifi')).Plan).Count -eq 2) 'An explicit saved pair may ignore disconnected unrelated candidates'
Write-Output "PASS: $count dual-reachability policy assertions. No OS mutations."
