$ErrorActionPreference='Stop'
$sourceEntry=Join-Path $PSScriptRoot '..\EthernetFirst.ps1'
$script:writes=0
function Get-NetAdapter { [pscustomobject]@{InterfaceGuid='virtual';ifIndex=55;Name='VPN';InterfaceDescription='VPN';HardwareInterface=$false;MediaType='IP';PhysicalMediaType='IP';Status='Up';LinkSpeed='1 Gbps'} }
function Get-NetConnectionProfile { }
function Get-NetIPInterface { [pscustomobject]@{InterfaceIndex=55;AddressFamily='IPv4';InterfaceMetric=5;AutomaticMetric='Disabled'} }
function Get-NetIPAddress { }
function Get-NetRoute { [pscustomobject]@{InterfaceIndex=55;AddressFamily='IPv4';RouteMetric=0;DestinationPrefix='0.0.0.0/0'} }
function Get-DnsClientServerAddress { }
function Set-NetIPInterface { $script:writes++; throw 'Monitor attempted to mutate network' }
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('ef-entry-'+[Guid]::NewGuid())
try {
    # Test an otherwise identical isolated copy, never compete with the user's
    # active production mutex. All OS network boundaries below are mocked.
    [void][IO.Directory]::CreateDirectory($tmp)
    $entry=Join-Path $tmp 'EthernetFirst.ps1'
    $content=[IO.File]::ReadAllText($sourceEntry).Replace('Global\EthernetFirst-NetworkControl',('Local\EF-Test-'+[Guid]::NewGuid()))
    [IO.File]::WriteAllText($entry,$content,[Text.UTF8Encoding]::new($true))
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '..\src') -Destination (Join-Path $tmp 'src') -Recurse
    $defaults=@{autoReturnToWired=$true;managedAdapterGuids=@()}
    $defaults | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $tmp 'preferences.json') -Encoding UTF8
    $null=& $entry -Once -NoNotifications -StateDirectory $tmp
    $status=Get-Content (Join-Path $tmp 'status.json') -Raw | ConvertFrom-Json
    if (-not $status.PSObject.Properties['mode'] -or $status.mode -ne 'Monitor' -or $script:writes -ne 0) { throw 'Default entry must publish monitor mode and never change network settings' }
    if ($status.probeType -ne 'HTTPS') { throw 'Entry must publish actual HTTPS probe type' }
    if (-not $status.PSObject.Properties['autoReturnToWired'] -or -not $status.autoReturnToWired) { throw 'Entry must load the saved recovery preference without enabling Auto' }
    if (-not $status.PSObject.Properties['adapters'] -or -not $status.PSObject.Properties['probeProfiles']) { throw 'Status must include adapter inventory and both probe profiles' }
    $failed=$false
    try { & $entry -Once -Apply -Restore -NoNotifications -StateDirectory $tmp } catch { $failed=$true }
    if (-not $failed) { throw 'Conflicting mutation commands must be rejected' }
    $assertions=5
    # Exercise real entry command/restore handlers with mock effects, without
    # starting a controller or acquiring another production writer lock.
    . (Join-Path $PSScriptRoot '..\src\Controller.ps1')
    $tokens=$null;$parseErrors=$null
    $ast=[Management.Automation.Language.Parser]::ParseFile($entry,[ref]$tokens,[ref]$parseErrors)
    foreach ($name in @('Invoke-TrayRequests','Invoke-PendingRestore','Update-ControllerView')) {
        $definition=$ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name},$true)
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $script:events=New-Object 'System.Collections.Generic.List[string]'
    function Add-DashboardEvent { param($UI,$Message); $script:events.Add($Message) }
    function Show-Notice { param($Message) }
    function Test-ManagedMetrics { return $true }
    function Restore-SwitchMetrics { $script:restored=$true }
    $script:modelBuilds=0
    function Get-DashboardModel { $script:modelBuilds++ }
    $dashboard=@{Window=[pscustomobject]@{IsVisible=$false}}
    Update-ControllerView
    if ($script:modelBuilds -ne 0) { throw 'The real entry must skip model construction in a hidden tray session' };$assertions++
    $state=New-ControllerState;$requests=New-Object 'System.Collections.Generic.Queue[string]'
    $dashboard=@{SelectionDirty=$true};$tray=$null;$admin=$true;$zh=$true
    $backupPath=Join-Path $tmp 'mock-backup';$expectedPath=Join-Path $tmp 'mock-expected'
    $requests.Enqueue('Wired'); Invoke-TrayRequests
    if ($state.Mode -ne 'Monitor' -or $state.Generation -ne 0 -or $script:events[0] -notmatch '未保存') { throw 'Dirty selection must block even a queued/tray manual action, with a visible explanation' };$assertions++
    $requests.Enqueue('CancelSelection');Invoke-TrayRequests
    if ($dashboard.SelectionDirty) { throw 'Cancel must restore the effective selection without changing metrics' };$assertions++
    $script:restored=$false;Invoke-PendingRestore
    if (-not $script:restored -or $script:events[$script:events.Count-1] -notmatch '恢复已完成') { throw 'Real restore handler must publish its completed outcome after the effect succeeds' };$assertions++
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($admin) {
        # An empty isolated recovery state causes no OS changes. Probe/config
        # damage must not block restoration; elevated Windows CI covers this.
        $fixture=Join-Path $tmp 'broken-install'; $src=Join-Path $fixture 'src'
        [void][IO.Directory]::CreateDirectory($src)
        Copy-Item -LiteralPath $entry -Destination (Join-Path $fixture 'EthernetFirst.ps1')
        foreach ($name in @('Core.ps1','Controller.ps1','Switching.ps1','Persistence.cs')) {
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot ('..\src\'+$name)) -Destination $src
        }
        [IO.File]::WriteAllText((Join-Path $fixture 'config.json'),'{broken JSON')
        [IO.File]::WriteAllText((Join-Path $src 'Probe.cs'),'not C sharp')
        $exe=if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
        $null=& $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $fixture 'EthernetFirst.ps1') -Restore -StateDirectory (Join-Path $fixture 'state')
        if ($LASTEXITCODE -ne 0) { throw 'Broken config/probe must not block the isolated CLI recovery process' }
        if ($script:writes -ne 0) { throw 'Empty recovery state must not write OS metrics' }
        $assertions++
    } else { Write-Output 'SKIP: elevated CLI recovery fixture (current process is not administrator).' }
    Write-Output "PASS: $assertions entry assertions. No system settings changed."
} finally {
    # Only the new, explicit temporary test directory is removed.
    if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force }
}
