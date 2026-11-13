Set-StrictMode -Version Latest

function ConvertTo-HttpsEndpoints {
    param($Value,[string]$Name)
    $endpoints=@($Value)
    if ($endpoints.Count -ne 2) { throw "$Name requires two HTTPS 204 endpoints on different hosts." }
    $hosts=@()
    foreach ($endpoint in $endpoints) {
        $uri=$null
        if (-not [Uri]::TryCreate([string]$endpoint,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Fragment) { throw 'Health endpoints must be absolute HTTPS URLs without credentials or fragments.' }
        $hosts+=$uri.DnsSafeHost
    }
    if (@($hosts | Select-Object -Unique).Count -ne 2) { throw 'Use two different health endpoint hosts.' }
    return [string[]]$endpoints
}

function Read-SwitchConfiguration {
    param([string]$Path)
    $result = @{ Overrides=@{}; ManagedGuids=@(); ReturnToWired=$false
        DomesticHttps=@('https://connectivitycheck.platform.hicloud.com/generate_204','https://wifi.vivo.com.cn/generate_204')
        ForeignHttps=@('https://www.gstatic.com/generate_204','https://www.google.com/generate_204')
        Https=@('https://www.gstatic.com/generate_204','https://www.google.com/generate_204') }
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
        $result.ForeignHttps=@(ConvertTo-HttpsEndpoints $property.Value 'httpsEndpoints')
    }
    foreach ($group in @('Domestic','Foreign')) {
        $property=$config.PSObject.Properties[($group.ToLowerInvariant()+'HttpsEndpoints')]
        if ($property) { $result[$group+'Https']=@(ConvertTo-HttpsEndpoints $property.Value ($group+'HttpsEndpoints')) }
    }
    $property=$config.PSObject.Properties['autoReturnToWired']
    if ($property) {
        if ($property.Value -isnot [bool]) { throw 'autoReturnToWired must be a JSON boolean.' }
        $result.ReturnToWired=$property.Value
    }
    $result.Https=$result.ForeignHttps
    return $result
}

function New-ControllerState {
    @{ Mode='Monitor'; LastSwitch=[DateTime]::MinValue; LastReason='Monitor only'; Exit=$false; Generation=0; CheckRequested=$false; RestoreRequested=$false; ReturnToWired=$false }
}

function Request-WiredRecovery {
    param([hashtable]$State,[bool]$Enabled)
    $State.ReturnToWired=$Enabled
    Request-ConnectionCheck $State
}

function Write-UserPreferences {
    param([string]$Path,[string[]]$ManagedGuids,[bool]$ReturnToWired)
    $normalized=@()
    if (@($ManagedGuids).Count -notin @(0,2)) { throw 'Select both adapters or use automatic selection for both.' }
    foreach ($id in $ManagedGuids) {
        $guid=[Guid]::Empty
        if (-not [Guid]::TryParse($id,[ref]$guid)) { throw 'Invalid managed adapter GUID.' }
        $normalized+=$guid.ToString('B')
    }
    if (@($normalized | Select-Object -Unique).Count -ne $normalized.Count) { throw 'Managed adapters must be different.' }
    Write-AtomicJson $Path @{version=1;managedAdapterGuids=@($normalized);autoReturnToWired=$ReturnToWired}
}

function Read-UserPreferences {
    param([string]$Path,[hashtable]$Defaults)
    $result=@{ManagedGuids=@($Defaults.ManagedGuids);ReturnToWired=[bool]$Defaults.ReturnToWired}
    if (-not (Test-Path -LiteralPath $Path)) { return $result }
    $validated=Read-SwitchConfiguration $Path
    $raw=Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($raw.PSObject.Properties['managedAdapterGuids']) { $result.ManagedGuids=@($validated.ManagedGuids) }
    if ($raw.PSObject.Properties['autoReturnToWired']) { $result.ReturnToWired=$validated.ReturnToWired }
    return $result
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
        $adapters=if ($Snapshot.PSObject.Properties['Adapters']) {@($Snapshot.Adapters)} else {@()}
        $decision = Get-SwitchDecision -Links $Snapshot.Links -Mode $mode -ManagedGuids $ManagedGuids -LastSwitch $State.LastSwitch -Now $Now -CooldownSeconds 180 -ReturnToWired:$State.ReturnToWired -Adapters $adapters
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

function Get-ControllerEvent {
    param($Decision,[string]$RequestedMode)
    if (@($Decision.Plan).Count) {
        $target=@($Decision.Plan | Where-Object Guid -eq $Decision.TargetGuid | Select-Object -First 1)
        $kind=if ($target.Count -and $target[0].PSObject.Properties['Kind']) {[string]$target[0].Kind} else {''}
        $name=switch ($kind) { Wired {'有线网络'} WiFi {'Wi-Fi 网络'} default {'所选线路'} }
        if ($RequestedMode -eq 'Auto') { return '自动切换已完成：当前默认出口为'+$name+'。' }
        return '手动切换已完成：已优先使用'+$name+'。'
    }
    if ($RequestedMode -in @('Wired','WiFi')) { return '手动切换未执行：请确认网卡选择、线路连接和默认出口，详情见诊断信息。' }
    return ''
}
