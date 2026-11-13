$ErrorActionPreference='Stop'
$entry=Join-Path $PSScriptRoot '..\EthernetFirst.ps1'
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
    $null=& $entry -Once -NoNotifications -StateDirectory $tmp
    $status=Get-Content (Join-Path $tmp 'status.json') -Raw | ConvertFrom-Json
    if (-not $status.PSObject.Properties['mode'] -or $status.mode -ne 'Monitor' -or $script:writes -ne 0) { throw 'Default entry must publish monitor mode and never change network settings' }
    if ($status.probeType -ne 'HTTPS') { throw 'Entry must publish actual HTTPS probe type' }
    $failed=$false
    try { & $entry -Once -Apply -Restore -NoNotifications -StateDirectory $tmp } catch { $failed=$true }
    if (-not $failed) { throw 'Conflicting mutation commands must be rejected' }
    $assertions=3
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
