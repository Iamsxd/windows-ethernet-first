Set-StrictMode -Version Latest

function Read-SwitchConfiguration {
    param([string]$Path)
    $result = @{ Overrides=@{}; ManagedGuids=@(); Https=@('https://www.gstatic.com/generate_204','https://cp.cloudflare.com/generate_204') }
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $config = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $property = $config.PSObject.Properties['adapterOverrides']
    if ($property -and $property.Value) {
        foreach ($p in $property.Value.PSObject.Properties) {
            if ($p.Value -notin @('Wired','WiFi','Mobile','Virtual','Other')) { throw 'Invalid adapter kind in config.json.' }
            $result.Overrides[$p.Name] = [string]$p.Value
        }
    }
    $property = $config.PSObject.Properties['managedAdapterGuids']
    if ($property -and @($property.Value).Count) {
        $ids = @($property.Value)
        if ($ids.Count -ne 2) { throw 'Select exactly two managedAdapterGuids: one wired and one Wi-Fi.' }
        $normalized = @()
        foreach ($id in $ids) {
            $guid = [Guid]::Empty
            if (-not [Guid]::TryParse([string]$id,[ref]$guid)) { throw 'Invalid managed adapter GUID.' }
            $normalized += $guid.ToString('B')
        }
        if ([Guid]$ids[0] -eq [Guid]$ids[1]) { throw 'Managed adapters must be different.' }
        $result.ManagedGuids = [string[]]$normalized
    }
    $property = $config.PSObject.Properties['httpsEndpoints']
    if ($property) {
        $endpoints = @($property.Value)
        if ($endpoints.Count -ne 2) { throw 'Configure two HTTPS 204 endpoints on different hosts.' }
        $hosts = @()
        foreach ($endpoint in $endpoints) {
            $uri = $null
            if (-not [Uri]::TryCreate([string]$endpoint,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment) {
                throw 'Health endpoints must be absolute HTTPS URLs without credentials or fragments.'
            }
            $hosts += $uri.DnsSafeHost
        }
        if (@($hosts | Select-Object -Unique).Count -ne 2) { throw 'Use two different health endpoint hosts.' }
        $result.Https = [string[]]$endpoints
    }
    return $result
}

function New-ControllerState {
    @{ Mode='Monitor'; LastSwitch=[DateTime]::MinValue; LastReason='Monitor only'; Exit=$false; Generation=0; CheckRequested=$false; RestoreRequested=$false }
}

function Request-SwitchMode {
    param([hashtable]$State, [ValidateSet('Monitor','Auto','Wired','WiFi')][string]$Mode, [bool]$IsAdmin)
    if ($Mode -ne 'Monitor' -and -not $IsAdmin) { throw 'Use start.bat and accept Windows administrator authorization to switch networks.' }
    $State.Mode = $Mode
    $State.Generation++
}

function Request-ConnectionCheck {
    param([hashtable]$State)
    $State.Generation++; $State.CheckRequested=$true
}

function Request-MetricRestore {
    param([hashtable]$State)
    $State.Mode='Monitor'; $State.RestoreRequested=$true
    Request-ConnectionCheck $State
}

function Complete-MetricRestore {
    param([hashtable]$State)
    $State.RestoreRequested=$false
    Request-ConnectionCheck $State
}

function Test-SnapshotCurrent {
    param([hashtable]$State,[int]$Generation)
    return ($State.Generation -eq $Generation -and -not $State.RestoreRequested -and -not $State.Exit)
}

function Invoke-ControllerCycle {
    param([hashtable]$State, $Snapshot, [string[]]$ManagedGuids, [string]$BackupPath, [string]$ExpectedPath, [DateTime]$Now = [DateTime]::UtcNow)
    $mode = $State.Mode
    if ($mode -eq 'Monitor') { return [pscustomobject]@{Plan=@();Reason='Monitor only';TargetGuid=''} }
    # Manual actions are one-shot and always disarm auto, including on failure.
    if ($mode -in @('Wired','WiFi')) { $State.Mode = 'Monitor' }
    try {
        if (-not (Test-ManagedMetrics -ExpectedPath $ExpectedPath -BackupPath $BackupPath)) {
            $State.Mode = 'Monitor'; $State.LastReason = 'Paused: external metric changes detected. Restore or restart after reviewing the settings.'
            return [pscustomobject]@{Plan=@();Reason=$State.LastReason;TargetGuid=''}
        }
        $decision = Get-SwitchDecision -Links $Snapshot.Links -Mode $mode -ManagedGuids $ManagedGuids -LastSwitch $State.LastSwitch -Now $Now -CooldownSeconds 180
        if (@($decision.Plan).Count) {
            Set-SwitchPlan -Plan $decision.Plan -BackupPath $BackupPath -ExpectedPath $ExpectedPath | Out-Null
            $State.LastSwitch = $Now
        }
        $State.LastReason = $decision.Reason
        return $decision
    } catch {
        $State.Mode = 'Monitor'; $State.LastReason = $_.Exception.Message
        throw
    }
}
