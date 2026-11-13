#Requires -Version 5.1
# Portable launcher: UAC grants permission, but starting the tray does not enable auto.
param([switch]$Elevated)
$ErrorActionPreference='Stop'
$entry=Join-Path $PSScriptRoot 'EthernetFirst.ps1'
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
try {
    $admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $admin) {
        if ($Elevated) { throw 'Windows administrator authorization was not granted.' }
        $arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Elevated' -f $PSCommandPath
        Start-Process -FilePath $exe -Verb RunAs -WindowStyle Hidden -ArgumentList $arguments -WorkingDirectory $PSScriptRoot | Out-Null
        return
    }
    # Keep startup failures (for example an existing tray instance) visible even
    # though the console is hidden. Do not save credentials or auto-enable control.
    & $entry -Language zh
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message,'Ethernet First')
}
