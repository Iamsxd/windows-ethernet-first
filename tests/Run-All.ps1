#Requires -Version 5.1
$ErrorActionPreference='Stop'
$exe=if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME 'pwsh.exe' } else { Join-Path $PSHOME 'powershell.exe' }
foreach ($name in @('Test-Core.ps1','Test-Probe.ps1','Test-Persistence.ps1','Test-Snapshot.ps1','Test-Switching.ps1','Test-ReachabilityPolicy.ps1','Test-Controller.ps1','Test-DashboardModel.ps1','Test-Dashboard.ps1','Test-Entry.ps1')) {
    & $exe -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot $name)
    if ($LASTEXITCODE -ne 0) { throw "$name failed (exit $LASTEXITCODE)." }
}
Write-Output 'PASS: all test scripts. No real adapter settings changed.'
