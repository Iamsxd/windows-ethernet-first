#Requires -Version 5.1
[CmdletBinding()]
param([switch]$Uninstall)
$ErrorActionPreference='Stop'
$admin=([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $admin) {
    $argsList = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($Uninstall) { $argsList += ' -Uninstall' }
    $p = Start-Process powershell.exe -Verb RunAs -WindowStyle Hidden -ArgumentList $argsList -PassThru -Wait
    exit $p.ExitCode
}
$destination = Join-Path $env:ProgramFiles 'EthernetFirst'
$state = Join-Path $env:ProgramData 'EthernetFirst'
$taskName='EthernetFirst'
$user=[Security.Principal.WindowsIdentity]::GetCurrent().Name
$exe=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $taskName
    Start-Sleep -Seconds 2
}
if ($Uninstall) {
    if (Test-Path (Join-Path $destination 'EthernetFirst.ps1')) {
        & $exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $destination 'EthernetFirst.ps1') -Restore -StateDirectory $state
        if ($LASTEXITCODE -ne 0) { throw 'Restore incomplete. The stopped task and backup remain available for another restore attempt.' }
    }
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output 'Startup removed and original metrics restored. Program files and diagnostic backups retained.'
    exit
}
New-Item -ItemType Directory -Path $destination,$state -Force | Out-Null
# Elevated scheduled tasks must not execute code/config writable by standard users.
foreach ($folder in @($destination,$state)) {
    $acl=Get-Acl -LiteralPath $folder
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($sid in @('S-1-5-18','S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new($sid),'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
    }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),'ReadAndExecute','ContainerInherit,ObjectInherit','None','Allow'))
    Set-Acl -LiteralPath $folder -AclObject $acl
}
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'EthernetFirst.ps1') -Destination $destination -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'src') -Destination $destination -Recurse -Force
if (-not (Test-Path (Join-Path $destination 'config.json'))) { Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'config.json') -Destination $destination }
$arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -StateDirectory "{1}"' -f (Join-Path $destination 'EthernetFirst.ps1'),$state
$action=New-ScheduledTaskAction -Execute $exe -Argument $arguments
$trigger=New-ScheduledTaskTrigger -AtLogOn -User $user
$principal=New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
$settings=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Monitor HTTPS connectivity; manual network selection and optional automatic failover from the tray.' -Force | Out-Null
Start-ScheduledTask -TaskName $taskName
Write-Output 'Ethernet First installed. Status: C:\ProgramData\EthernetFirst\status.json'
