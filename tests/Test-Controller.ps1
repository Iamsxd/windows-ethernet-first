$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\src\Core.ps1')
$module=Join-Path $PSScriptRoot '..\src\Controller.ps1'
if (Test-Path $module) { . $module }
$script:count=0
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message }; $script:count++ }
Assert ([bool](Get-Command New-ControllerState -ErrorAction SilentlyContinue)) 'Controller must expose explicit monitor-only startup state'
$state=New-ControllerState
Assert ($state.Mode -eq 'Monitor') 'Startup must not enable automatic modification'
Assert ($state.ContainsKey('ReturnToWired') -and -not $state.ReturnToWired) 'Wired recovery must remain explicitly off at first launch'
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
$generation=$state.Generation
Request-WiredRecovery $state $true
Assert ($state.ReturnToWired -and $state.Mode -eq 'Monitor' -and $state.Generation -gt $generation) 'Changing recovery preference must invalidate stale samples without enabling control'
Request-WiredRecovery $state $false
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
    param($Links,$Mode,$ManagedGuids,$LastSwitch,$Now,$CooldownSeconds,[switch]$ReturnToWired,$Adapters)
    $script:receivedRecovery=[bool]$ReturnToWired
    $script:receivedAdapters=@($Adapters)
    [pscustomobject]@{Plan=@([pscustomobject]@{Guid='wifi'});TargetGuid='wifi';Reason='Ready'}
}
function Set-SwitchPlan { param($Plan,$BackupPath,$ExpectedPath); if ($script:fail) { throw 'Write failed' }; $script:writes++; [pscustomobject]@{Success=$true;Changed=2} }
$snapshot=[pscustomobject]@{Links=@();Adapters=@([pscustomobject]@{Kind='Wired'},[pscustomobject]@{Kind='WiFi'})}
$now=[DateTime]'2026-11-13T06:00:00Z'
$d=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now
Assert (@($d).Count -eq 1 -and $d.TargetGuid -eq 'wifi') 'Transaction receipts must not leak into the controller decision contract'
Assert ($script:writes -eq 1 -and $state.Mode -eq 'Monitor') 'Manual action must execute once and leave auto off'
Assert ($state.LastSwitch -eq $now) 'Successful writes must establish cooldown'
Assert ($script:receivedAdapters.Count -eq 2) 'Controller must pass all installed candidates to policy, not just active links'
$null=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now.AddSeconds(1)
Assert ($script:writes -eq 1) 'Monitor mode must never write metrics'
Request-SwitchMode $state Auto $true
$state.ReturnToWired=$true
$script:external=$false; $script:fail=$false
$null=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now.AddMinutes(5)
Assert $script:receivedRecovery 'The controller must pass the opt-in preference to actual policy evaluation'
$script:external=$true
$d=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now
Assert ($state.Mode -eq 'Monitor' -and $script:writes -eq 2 -and $d.Reason -match 'external') 'External changes must pause control without overwriting them'
$script:external=$false; $script:fail=$true
Request-SwitchMode $state Wired $true
$failed=$false
try { $null=Invoke-ControllerCycle $state $snapshot @() 'unused-baseline' 'unused-expected' $now.AddMinutes(10) } catch { $failed=$true }
Assert ($failed -and $state.Mode -eq 'Monitor' -and $state.LastSwitch -eq $now.AddMinutes(5)) 'Failed manual writes must not retry or mark a successful switch'
$tmp=Join-Path ([IO.Path]::GetTempPath()) ('ef-config-'+[Guid]::NewGuid()+'.json')
try {
    '{"adapterOverrides":{}}' | Set-Content $tmp -Encoding UTF8
    $c=Read-SwitchConfiguration $tmp
    Assert ($c.Https.Count -eq 2 -and $c.ManagedGuids.Count -eq 0) 'Legacy config must receive safe HTTPS defaults'
    Assert ($c.DomesticHttps.Count -eq 2 -and $c.ForeignHttps.Count -eq 2 -and -not $c.ReturnToWired) 'Two independent profiles and opt-in wired recovery must have safe defaults'
    '{"domesticHttpsEndpoints":["http://example.org/","https://example.net/"]}' | Set-Content $tmp -Encoding UTF8
    $failed=$false; try { $null=Read-SwitchConfiguration $tmp } catch { $failed=$true }
    Assert $failed 'Domestic endpoints must retain strict HTTPS configuration validation'
    '{"autoReturnToWired":"false"}' | Set-Content $tmp -Encoding UTF8
    $failed=$false; try { $null=Read-SwitchConfiguration $tmp } catch { $failed=$true }
    Assert $failed 'A string preference must not accidentally enable automatic return'
    '{"httpsEndpoints":["http://example.org/","https://example.net/"]}' | Set-Content $tmp -Encoding UTF8
    $failed=$false; try { $null=Read-SwitchConfiguration $tmp } catch { $failed=$true }
    Assert $failed 'Config must reject insecure health endpoints'
    '{"managedAdapterGuids":["not-a-guid"]}' | Set-Content $tmp -Encoding UTF8
    $failed=$false; try { $null=Read-SwitchConfiguration $tmp } catch { $failed=$true }
    Assert $failed 'Malformed selection must not silently fall back to other adapters'
    '{"managedAdapterGuids":["11111111-1111-4111-8111-111111111111","22222222-2222-4222-8222-222222222222"]}' | Set-Content $tmp -Encoding UTF8
    $c=Read-SwitchConfiguration $tmp
    Assert ($c.ManagedGuids[0] -eq '{11111111-1111-4111-8111-111111111111}') 'Valid unbraced GUIDs must match Windows braced adapter identity'
    Write-UserPreferences $tmp $c.ManagedGuids $true
    $prefs=Read-UserPreferences $tmp (Read-SwitchConfiguration 'missing-config-fixture')
    Assert ($prefs.ManagedGuids.Count -eq 2 -and $prefs.ReturnToWired) 'Adapter selection and wired recovery must survive a preference roundtrip'
    $raw=Get-Content $tmp -Raw | ConvertFrom-Json
    Assert (-not $raw.PSObject.Properties['mode'] -and -not $raw.PSObject.Properties['applying']) 'Saved preferences must never silently reactivate automatic control'
} finally { Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue }
$eventDecision=[pscustomobject]@{Plan=@([pscustomobject]@{Guid='wire';Kind='Wired'});TargetGuid='wire';Reason='Ready'}
Assert ((Get-ControllerEvent $eventDecision Auto) -match '自动.*有线') 'A committed automatic switch must produce a named outcome for history'
$eventDecision.Plan=@()
Assert ([bool](Get-ControllerEvent $eventDecision WiFi)) 'A rejected manual action must produce a distinct outcome'
Assert (-not (Get-ControllerEvent $eventDecision Auto)) 'Unchanged automatic rounds must not spam the history'
Write-Output "PASS: $script:count controller assertions. No system settings changed."
