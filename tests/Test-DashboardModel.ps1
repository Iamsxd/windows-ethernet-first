$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Controller.ps1')
$module=Join-Path $PSScriptRoot '..\src\DashboardModel.ps1'
if (Test-Path $module) { . $module }
$count=0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:count++ }
Assert ([bool](Get-Command Get-DashboardModel -ErrorAction SilentlyContinue)) 'Dashboard must derive view state without network writes'
function Row($Guid,$Kind,$Metric,$DomGood,$DomBad,$ForeignGood,$ForeignBad) {
    [pscustomobject]@{Guid=$Guid;Name=$Guid;Kind=$Kind;Family='IPv4';Metric=$Metric;RouteMetric=0;TotalMetric=$Metric;Source='192.0.2.7';Gateway='192.0.2.1';Profile='Example';DomesticGood=$DomGood;DomesticBad=$DomBad;DomesticProbeBlocked=$false;ForeignGood=$ForeignGood;ForeignBad=$ForeignBad;ForeignProbeBlocked=$false}
}
$s=[pscustomobject]@{Links=@((Row wire Wired 10 2 0 2 0),(Row wifi WiFi 20 2 0 0 3));Adapters=@([pscustomobject]@{Guid='wire';Name='Ethernet';Kind='Wired';Status='Up';Profile='Office'},[pscustomobject]@{Guid='wifi';Name='Wireless';Kind='WiFi';Status='Up';Profile='Domestic Wi-Fi'});CheckedAt='2026-11-13T08:00:00Z'}
$state=New-ControllerState
$m=Get-DashboardModel $s $state @() ''
Assert ($m.CurrentGuid -eq 'wire' -and $m.Wired.IsCurrent -and -not $m.WiFi.IsCurrent) 'Current outlet must follow actual default metrics'
Assert ($m.Wired.Domestic.State -eq 'Reachable' -and $m.Wired.Foreign.State -eq 'Reachable') 'A fully reachable wired card must show both capabilities'
Assert ($m.WiFi.Domestic.State -eq 'Reachable' -and $m.WiFi.Foreign.State -eq 'Failed') 'A domestic-only card must not show a total outage'
$s.Links[0].ForeignGood=0; $s.Links[0].ForeignBad=3
$m=Get-DashboardModel $s $state @() ''
Assert ($m.NoticeKind -eq 'Warning' -and $m.NoticeCode -eq 'ForeignUnavailable') 'Foreign-only failure needs a clear notice while preserving domestic status'
$m=Get-DashboardModel $s $state @() 'Snapshot failed'
Assert ($m.Wired.Domestic.State -eq 'Unknown' -and $m.NoticeKind -eq 'Error') 'Old green results must be invalidated after an overall snapshot error'
$s.Links=@($s.Links | Where-Object Guid -ne 'wire'); $s.Adapters[0].Status='Disconnected'
$m=Get-DashboardModel $s $state @() ''
Assert ($m.Wired.Domestic.State -eq 'Disconnected' -and $m.CurrentGuid -eq 'wifi') 'Disconnected hardware must remain visible while default selection follows Wi-Fi'
$s.Adapters+=,[pscustomobject]@{Guid='second-wire';Name='USB Ethernet';Kind='Wired';Status='Up';Profile='Other'}
$m=Get-DashboardModel $s $state @() ''
Assert (-not $m.Wired.Guid -and $m.Wired.NeedsSelection) 'Multiple wired adapters must require a real selection rather than guessing'
$m=Get-DashboardModel $s $state @('wire','wifi') ''
Assert ($m.Wired.Guid -eq 'wire') 'Explicit GUID preferences must resolve the intended card'
$pending=Get-DashboardModel $null $state @() ''
Assert ($pending.CurrentKind -eq 'Pending' -and $pending.Wired.Domestic.State -ne 'Reachable') 'Startup cannot display fabricated healthy connections'
$state.LastReason='Paused: external metric changes detected.'
$paused=Get-DashboardModel $s $state @() ''
Assert ($paused.NoticeCode -eq 'OwnershipPaused') 'An ownership pause must be visible without opening technical diagnostics'
Write-Output "PASS: $count dashboard model assertions. No OS calls."
