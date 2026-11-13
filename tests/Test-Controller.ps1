$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$module=Join-Path $PSScriptRoot '..\src\Controller.ps1'
if (Test-Path $module) { . $module }
$script:count=0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:count++ }
Assert ([bool](Get-Command New-ControllerState -ErrorAction SilentlyContinue)) 'Controller must expose explicit monitor-only startup state'
$state=New-ControllerState
Assert ($state.Mode -eq 'Monitor') 'Startup must not enable automatic modification'
Assert ($state.ContainsKey('Generation')) 'Controller must track generations to reject snapshots sampled before UI actions'
$oldGeneration=$state.Generation
Request-ConnectionCheck $state
Assert ($state.CheckRequested -and -not (Test-SnapshotCurrent $state $oldGeneration)) 'Check during an active round must invalidate it and request a fresh one'
Request-SwitchMode $state Auto $true
$oldGeneration=$state.Generation
Request-MetricRestore $state
Assert ($state.Mode -eq 'Monitor' -and $state.RestoreRequested -and -not (Test-SnapshotCurrent $state $oldGeneration)) 'Restore must disarm auto and invalidate pending data before writing metrics'
Complete-MetricRestore $state
Request-SwitchMode $state Auto $true
Assert (-not $state.RestoreRequested -and $state.CheckRequested -and -not (Test-SnapshotCurrent $state $oldGeneration)) 'Auto enabled after restore must await a newly sampled generation'
Assert (Test-SnapshotCurrent $state $state.Generation) 'Fresh generation must be consumable'
$state=New-ControllerState
$denied=$false
try { Request-SwitchMode $state Auto $false } catch { $denied=$true }
Assert ($denied -and $state.Mode -eq 'Monitor') 'Non-admin requests must not enable auto'
Request-SwitchMode $state Auto $true
Assert ($state.Mode -eq 'Auto') 'Explicit admin opt-in enables auto'
Request-SwitchMode $state WiFi $true
Assert ($state.Mode -eq 'WiFi') 'Manual request must replace automatic mode'
$script:writes=0; $script:external=$false; $script:fail=$false
function Test-ManagedMetrics { param($ExpectedPath,$BackupPath) return (-not $script:external) }
function Get-SwitchDecision {
    param($Links,$Mode,$ManagedGuids,$LastSwitch,$Now,$CooldownSeconds)
    [pscustomobject]@{Plan=@([pscustomobject]@{Guid='wifi'});TargetGuid='wifi';Reason='Ready'}
}
function Set-SwitchPlan { param($Plan,$BackupPath,$ExpectedPath); if ($script:fail) { throw 'Write failed' }; $script:writes++; [pscustomobject]@{Success=$true;Changed=2} }
$snapshot=[pscustomobject]@{Links=@()}
$now=[DateTime]'2026-11-13T06:00:00Z'
$d=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now
Assert (@($d).Count -eq 1 -and $d.TargetGuid -eq 'wifi') 'Transaction receipts must not leak into the controller decision contract'
Assert ($script:writes -eq 1 -and $state.Mode -eq 'Monitor') 'Manual action must execute once and leave auto off'
Assert ($state.LastSwitch -eq $now) 'Successful writes must establish cooldown'
$null=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now.AddSeconds(1)
Assert ($script:writes -eq 1) 'Monitor mode must never write metrics'
Request-SwitchMode $state Auto $true
$script:external=$true
$d=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now
Assert ($state.Mode -eq 'Monitor' -and $script:writes -eq 1 -and $d.Reason -match 'external') 'External changes must pause control without overwriting them'
$script:external=$false; $script:fail=$true
Request-SwitchMode $state Wired $true
$failed=$false
try { $null=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now.AddMinutes(10) } catch { $failed=$true }
Assert ($failed -and $state.Mode -eq 'Monitor' -and $state.LastSwitch -eq $now) 'Failed manual writes must not retry or mark a successful switch'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('ef-config-'+[Guid]::NewGuid()+'.json')
try {
    '{"adapterOverrides":{}}' | Set-Content $tmp -Encoding UTF8
    $c=Read-SwitchConfiguration $tmp
    Assert ($c.Https.Count -eq 2 -and $c.ManagedGuids.Count -eq 0) 'Legacy config must receive safe HTTPS defaults'
    '{"httpsEndpoints":["http://example.org/","https://example.net/"]}' | Set-Content $tmp -Encoding UTF8
    $failed=$false; try { $null=Read-SwitchConfiguration $tmp } catch { $failed=$true }
    Assert $failed 'Config must reject insecure health endpoints'
    '{"managedAdapterGuids":["not-a-guid"]}' | Set-Content $tmp -Encoding UTF8
    $failed=$false; try { $null=Read-SwitchConfiguration $tmp } catch { $failed=$true }
    Assert $failed 'Malformed selection must not silently fall back to other adapters'
    '{"managedAdapterGuids":["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"]}' | Set-Content $tmp -Encoding UTF8
    $c=Read-SwitchConfiguration $tmp
    Assert ($c.ManagedGuids[0] -eq '{11111111-1111-4111-8111-111111111111}') 'Valid unbraced GUIDs must match Windows braced adapter identity'
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
Write-Output "PASS: $script:count controller assertions. No system settings changed."
