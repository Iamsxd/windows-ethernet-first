Set-StrictMode -Version Latest

function Get-SwitchDecision {
    [CmdletBinding()]
    param([object[]]$Links = @(), [ValidateSet('Monitor','Auto','Wired','WiFi')][string]$Mode = 'Monitor',
        [string[]]$ManagedGuids = @(), [datetime]$LastSwitch = [datetime]::MinValue,
        [datetime]$Now = [datetime]::UtcNow, [ValidateRange(0,86400)][int]$CooldownSeconds = 180,
        [switch]$ReturnToWired, [object[]]$Adapters=@())

    $result = [pscustomobject]@{ Plan=@(); Reason=''; TargetGuid='' }
    if ($Mode -eq 'Monitor') { $result.Reason='Monitor mode; no settings changed.'; return $result }
    $physical = @($Links | Where-Object { $_.Kind -in @('Wired','WiFi') -and $_.Hardware -eq $true })
    $selected = @($ManagedGuids | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
    if (-not $selected.Count) {
        $candidates=if ($Adapters.Count) {$Adapters} else {$physical}
        $wired = @($candidates | Where-Object Kind -eq 'Wired' | Select-Object -ExpandProperty Guid -Unique)
        $wifi = @($candidates | Where-Object Kind -eq 'WiFi' | Select-Object -ExpandProperty Guid -Unique)
        if ($wired.Count -ne 1 -or $wifi.Count -ne 1) {
            $result.Reason='Select exactly one physical wired adapter and one physical Wi-Fi adapter.'; return $result
        }
        $selected = @($wired[0], $wifi[0])
    }
    $managed = @($physical | Where-Object Guid -in $selected)
    $wired = @($managed | Where-Object Kind -eq 'Wired' | Select-Object -ExpandProperty Guid -Unique)
    $wifi = @($managed | Where-Object Kind -eq 'WiFi' | Select-Object -ExpandProperty Guid -Unique)
    if ($selected.Count -ne 2 -or $wired.Count -ne 1 -or $wifi.Count -ne 1 -or $wired[0] -eq $wifi[0]) {
        $result.Reason='Both selected physical adapters must be available, one wired and one Wi-Fi.'; return $result
    }
    if (@($Links | Where-Object { $_.Guid -in $selected -and ($_.Hardware -ne $true -or $_.Kind -notin @('Wired','WiFi')) }).Count) {
        $result.Reason='A selected adapter is not a supported physical interface.'; return $result
    }
    if (@($managed | Group-Object Guid,Family | Where-Object Count -ne 1).Count) {
        $result.Reason='Ambiguous adapter/default-route data; no settings changed.'; return $result
    }
    $families = @($Links | Where-Object Family -in @('IPv4','IPv6') | Select-Object -ExpandProperty Family -Unique)
    if (-not $families.Count) { $result.Reason='No usable default route.'; return $result }
    $currentGuids = @()
    foreach ($family in $families) {
        $routes = @($Links | Where-Object Family -eq $family | Sort-Object TotalMetric)
        $best = @($routes | Where-Object TotalMetric -eq $routes[0].TotalMetric | Select-Object -ExpandProperty Guid -Unique)
        if (@($best | Where-Object { $_ -notin $selected }).Count) {
            $result.Reason="$family is controlled by an unmanaged or VPN interface; no settings changed."; return $result
        }
        if ($Mode -eq 'Auto' -and $best.Count -ne 1) {
            $result.Reason="$family default interface is ambiguous; automatic mode paused."; return $result
        }
        if ($best.Count -eq 1) { $currentGuids += $best[0] }
    }
    if ($Mode -eq 'Auto') {
        if (@($managed | Where-Object { $_.PSObject.Properties['ProbeBlocked'] -and $_.ProbeBlocked }).Count) {
            $result.Reason='A probe route is controlled by another interface or VPN; automatic mode paused.'; return $result
        }
        if (@($currentGuids | Select-Object -Unique).Count -ne 1) {
            $result.Reason='IPv4 and IPv6 default interfaces differ; automatic mode paused.'; return $result
        }
        if (($Now - $LastSwitch).TotalSeconds -lt $CooldownSeconds) {
            $result.Reason='Automatic switch cooldown is active.'; return $result
        }
        $currentGuid = $currentGuids[0]
        $targetGuid = @($selected | Where-Object { $_ -ne $currentGuid })[0]
        $failoverReady=$true
        $recoveryReady=($ReturnToWired -and $currentGuid -eq $wifi[0] -and $targetGuid -eq $wired[0])
        foreach ($family in $families) {
            $active = @($managed | Where-Object { $_.Guid -eq $currentGuid -and $_.Family -eq $family })
            $backup = @($managed | Where-Object { $_.Guid -eq $targetGuid -and $_.Family -eq $family })
            if ($active.Count -ne 1 -or $backup.Count -ne 1) {
                $result.Reason='The backup lacks an active protocol/address/default route; no automatic switch.'; return $result
            }
            if ([int]$active[0].Bad -lt 3 -or [int]$backup[0].Good -lt 2) {
                $failoverReady=$false
            }
            if ([int]$backup[0].Good -lt 2 -or -not $backup[0].PSObject.Properties['ForeignGood'] -or [int]$backup[0].ForeignGood -lt 2 -or
                ($backup[0].PSObject.Properties['ForeignProbeBlocked'] -and $backup[0].ForeignProbeBlocked)) { $recoveryReady=$false }
        }
        if (-not $failoverReady -and -not $recoveryReady) {
            $result.Reason='Waiting for three failed domestic current rounds and two good domestic backup rounds in every active protocol.'; return $result
        }
    } else { $targetGuid = if ($Mode -eq 'Wired') { $wired[0] } else { $wifi[0] } }

    # Preserve every managed path's strict ordering against all unrelated defaults.
    # Only the ordering of the two explicitly selected physical interfaces may change.
    $plan = @()
    foreach ($family in $families) {
        $rows = @($managed | Where-Object Family -eq $family)
        $target = @($rows | Where-Object Guid -eq $targetGuid)
        if ($target.Count -ne 1) {
            $result.Reason="The selected interface has no usable $family default; refusing a partial switch."; return $result
        }
        $bounds = @{}
        foreach ($row in $rows) {
            $route = [long]$row.RouteMetric
            if ($route -lt 0 -or [long]$row.TotalMetric -ne ($route + [long]$row.Metric)) {
                $result.Reason='Invalid or inconsistent route metric data.'; return $result
            }
            $low = $route + 1L; $high = $route + 9999L
            foreach ($outside in @($Links | Where-Object { $_.Family -eq $family -and $_.Guid -notin $selected })) {
                $outsideTotal = [long]$outside.TotalMetric
                if ([long]$row.TotalMetric -lt $outsideTotal) { $high = [Math]::Min($high, $outsideTotal-1L) }
                elseif ([long]$row.TotalMetric -gt $outsideTotal) { $low = [Math]::Max($low, $outsideTotal+1L) }
                else { $result.Reason='An unrelated default has an equal metric; no safe priority change.'; return $result }
            }
            $bounds[$row.Guid] = @{ Low=$low; High=$high; Current=[long]$row.TotalMetric }
        }
        $targetBounds = $bounds[$targetGuid]
        $other = @($rows | Where-Object Guid -ne $targetGuid)
        $targetHigh = [long]$targetBounds.High
        if ($other.Count) { $targetHigh = [Math]::Min($targetHigh, [long]$bounds[$other[0].Guid].High-1L) }
        if ([long]$targetBounds.Low -gt $targetHigh) {
            $result.Reason='Existing route metrics and unrelated priorities prevent a safe complete switch.'; return $result
        }
        $targetTotal = [Math]::Max([long]$targetBounds.Low, [Math]::Min([long]$targetBounds.Current, $targetHigh))
        $totals = @{}; $totals[$targetGuid] = $targetTotal
        if ($other.Count) {
            $otherBounds = $bounds[$other[0].Guid]
            $otherLow = [Math]::Max([long]$otherBounds.Low, $targetTotal+1L)
            if ($otherLow -gt [long]$otherBounds.High) {
                $result.Reason='No safe interface-metric range exists; entire plan rejected.'; return $result
            }
            $totals[$other[0].Guid] = [Math]::Max($otherLow, [Math]::Min([long]$otherBounds.Current,[long]$otherBounds.High))
        }
        foreach ($row in $rows) {
            $plan += [pscustomobject]@{
                Guid=$row.Guid; Family=$family; Metric=[int]($totals[$row.Guid]-[long]$row.RouteMetric)
                Index=$row.Index; Name=$row.Name; Kind=$row.Kind; RouteMetric=[long]$row.RouteMetric; TargetGuid=$targetGuid
                ControlMode=$Mode; ExpectedCurrentGuid=$(if ($Mode -eq 'Auto') { $currentGuid } else { '' })
                ObservedDefaultGuids=@($Links | Where-Object Family -eq $family | Select-Object -ExpandProperty Guid -Unique)
            }
        }
    }
    $result.Plan=$plan; $result.TargetGuid=$targetGuid
    $result.Reason=if ($Mode -eq 'Auto' -and $recoveryReady -and -not $failoverReady) { 'Wired domestic and foreign access recovered; automatic return is enabled.' }
        elseif ($Mode -eq 'Auto') { 'Current domestic path failed and the backup passed the required consecutive rounds.' } else { "Manual preference: $Mode." }
    return $result
}

function Get-SwitchingState {
    param([string]$Guid, [string]$Family)
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { [string]$_.InterfaceGuid -eq $Guid })
    if ($adapters.Count -ne 1) { throw "Adapter $Guid is missing or ambiguous; no stale interface index will be used." }
    if (-not $adapters[0].HardwareInterface) { throw "Adapter $Guid is not a physical hardware interface." }
    $interfaces = @(Get-NetIPInterface -InterfaceIndex $adapters[0].ifIndex -AddressFamily $Family -ErrorAction Stop)
    if ($interfaces.Count -ne 1) { throw "IP interface $Guid/$Family is missing or ambiguous." }
    [pscustomobject]@{ Guid=$Guid; Family=$Family; Metric=[long]$interfaces[0].InterfaceMetric; Automatic=[string]$interfaces[0].AutomaticMetric }
}

function Test-SwitchingStateEqual {
    param($Actual, $Wanted, [switch]$AllowAutomaticRecalculation)
    if ([string]$Actual.Automatic -ne [string]$Wanted.Automatic) { return $false }
    if ($AllowAutomaticRecalculation -and [string]$Wanted.Automatic -eq 'Enabled') { return $true }
    return ([long]$Actual.Metric -eq [long]$Wanted.Metric)
}

function New-SwitchingConflict {
    param([string]$Message)
    $errorObject = New-Object System.InvalidOperationException $Message
    $errorObject.Data['SwitchingOwnershipConflict']=$true
    return $errorObject
}

function Invoke-SwitchingStateWrite {
    param($Wanted, $ExpectedBefore, [hashtable]$Attempt, [scriptblock]$BeforeWrite, [switch]$AutomaticOnly)
    $current=Get-SwitchingState $Wanted.Guid $Wanted.Family
    if (-not (Test-SwitchingStateEqual $current $ExpectedBefore)) { throw (New-SwitchingConflict "External metric change before writing $($Wanted.Guid)/$($Wanted.Family).") }
    # A failing cmdlet may have changed either property before throwing. Record
    # only values this particular command could have produced, before issuing it.
    foreach ($metric in @([long]$current.Metric,[long]$Wanted.Metric | Select-Object -Unique)) {
        foreach ($automatic in @([string]$current.Automatic,[string]$Wanted.Automatic | Select-Object -Unique)) {
            $Attempt.Owned += [pscustomobject]@{Guid=$Wanted.Guid;Family=$Wanted.Family;Metric=$metric;Automatic=$automatic}
        }
    }
    $Attempt.Intent=$true
    & $BeforeWrite
    $adapter = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop | Where-Object { [string]$_.InterfaceGuid -eq $Wanted.Guid })
    if ($adapter.Count -ne 1 -or -not $adapter[0].HardwareInterface) { throw 'Adapter identity changed before write.' }
    $latest=Get-SwitchingState $Wanted.Guid $Wanted.Family
    if (-not (Test-SwitchingStateEqual $latest $ExpectedBefore)) { throw (New-SwitchingConflict "External metric change immediately before writing $($Wanted.Guid)/$($Wanted.Family).") }
    $Attempt.Attempted=$true
    if ($AutomaticOnly) {
        Set-NetIPInterface -InterfaceIndex $adapter[0].ifIndex -AddressFamily $Wanted.Family -AutomaticMetric Enabled -ErrorAction Stop
    } else {
        Set-NetIPInterface -InterfaceIndex $adapter[0].ifIndex -AddressFamily $Wanted.Family -AutomaticMetric Disabled -InterfaceMetric $Wanted.Metric -ErrorAction Stop
    }
    $actual=Get-SwitchingState $Wanted.Guid $Wanted.Family
    if (-not (Test-SwitchingStateEqual $actual $Wanted -AllowAutomaticRecalculation)) { throw "Metric readback failed for $($Wanted.Guid)/$($Wanted.Family)." }
    $Attempt.Owned += $actual
    & $BeforeWrite
    return $actual
}

function Set-SwitchingState {
    param($Wanted, $ExpectedBefore, [hashtable]$Attempt, [scriptblock]$BeforeWrite)
    $current=Get-SwitchingState $Wanted.Guid $Wanted.Family
    if (-not (Test-SwitchingStateEqual $current $ExpectedBefore)) { throw (New-SwitchingConflict "External metric change before writing $($Wanted.Guid)/$($Wanted.Family).") }
    if (Test-SwitchingStateEqual $current $Wanted -AllowAutomaticRecalculation) { return $false }
    $disabled=[pscustomobject]@{Guid=$Wanted.Guid;Family=$Wanted.Family;Metric=[long]$Wanted.Metric;Automatic='Disabled'}
    $actual=Invoke-SwitchingStateWrite $disabled $current $Attempt $BeforeWrite
    if ($Wanted.Automatic -eq 'Enabled') {
        $null=Invoke-SwitchingStateWrite $Wanted $actual $Attempt $BeforeWrite -AutomaticOnly
    }
    return $true
}

function Merge-SwitchingStates {
    param([object[]]$Existing, [object[]]$Replacement)
    $keys = @($Replacement | ForEach-Object { "$($_.Guid)/$($_.Family)" })
    @($Existing | Where-Object { $null -ne $_ } | Where-Object { "$($_.Guid)/$($_.Family)" -notin $keys }) + @($Replacement)
}

function Get-SwitchingRoutes {
    param([string[]]$Families = @('IPv4','IPv6'))
    $adapters = @(Get-NetAdapter -IncludeHidden -ErrorAction Stop)
    foreach ($route in @(Get-NetRoute -ErrorAction Stop | Where-Object {
        [string]$_.AddressFamily -in $Families -and $_.DestinationPrefix -in @('0.0.0.0/0','::/0')
    })) {
        $adapter = @($adapters | Where-Object ifIndex -eq $route.InterfaceIndex)
        if ($adapter.Count -ne 1) { throw 'A live default route has no unambiguous adapter identity.' }
        if ([string]$adapter[0].Status -ne 'Up') { continue }
        $iface = @(Get-NetIPInterface -InterfaceIndex $route.InterfaceIndex -AddressFamily $route.AddressFamily -ErrorAction Stop)
        if ($iface.Count -ne 1) { throw 'Cannot verify live default route metrics.' }
        if ($iface[0].PSObject.Properties['ConnectionState'] -and [string]$iface[0].ConnectionState -eq 'Disconnected') { continue }
        [pscustomobject]@{
            Guid=[string]$adapter[0].InterfaceGuid; Family=[string]$route.AddressFamily
            RouteMetric=[long]$route.RouteMetric; TotalMetric=([long]$route.RouteMetric+[long]$iface[0].InterfaceMetric)
        }
    }
}

function Get-SwitchingTargets {
    param([object[]]$Plan)
    $families = @($Plan | Select-Object -ExpandProperty Family -Unique)
    $routes = @(Get-SwitchingRoutes)
    if (@($routes | Where-Object Family -notin $families).Count) { throw 'An active protocol is absent from the plan; recalculate before switching.' }
    foreach ($family in $families) {
        $items = @($Plan | Where-Object Family -eq $family)
        $predicted = @()
        foreach ($route in @($routes | Where-Object Family -eq $family)) {
            $item = @($items | Where-Object Guid -eq $route.Guid)
            $total = if ($item.Count) { [long]$route.RouteMetric+[long]$item[0].Metric } else { [long]$route.TotalMetric }
            $predicted += [pscustomobject]@{ Guid=$route.Guid; Total=$total }
        }
        foreach ($item in $items) {
            if (-not @($routes | Where-Object { $_.Guid -eq $item.Guid -and $_.Family -eq $family }).Count) { throw "Default route disappeared for $($item.Guid)/$family." }
        }
        if (-not $predicted.Count) { throw "No live $family default route to verify." }
        $minimum = ($predicted | Measure-Object Total -Minimum).Minimum
        $winners = @($predicted | Where-Object Total -eq $minimum | Select-Object -ExpandProperty Guid -Unique)
        $declared = @($items | Where-Object { $_.PSObject.Properties['TargetGuid'] -and $_.TargetGuid } | Select-Object -ExpandProperty TargetGuid -Unique)
        if ($winners.Count -ne 1 -or $winners[0] -notin @($items.Guid) -or $declared.Count -gt 1 -or ($declared.Count -eq 1 -and $declared[0] -ne $winners[0])) {
            throw "The plan cannot establish a unique selected $family default without overriding another interface."
        }
        [pscustomobject]@{ Family=$family; Guid=$winners[0] }
    }
}

function Confirm-SwitchingTargets {
    param([object[]]$Targets)
    $routes = @(Get-SwitchingRoutes)
    if (@($routes | Where-Object Family -notin @($Targets.Family)).Count) { throw 'A new active protocol appeared during the switch; refusing a partial switch.' }
    foreach ($target in $Targets) {
        $rows = @($routes | Where-Object Family -eq $target.Family)
        if (-not $rows.Count) { throw "No live $($target.Family) default after writing metrics." }
        $minimum = ($rows | Measure-Object TotalMetric -Minimum).Minimum
        $winners = @($rows | Where-Object TotalMetric -eq $minimum | Select-Object -ExpandProperty Guid -Unique)
        if ($winners.Count -ne 1 -or $winners[0] -ne $target.Guid) { throw "Actual $($target.Family) default route did not switch to $($target.Guid)." }
    }
}

function Confirm-SwitchingUnmanagedOrder {
    param([object[]]$Wanted, [object[]]$Before, [switch]$Proposed)
    $routes = @(Get-SwitchingRoutes)
    $managedGuids = @($Wanted.Guid | Select-Object -Unique)
    foreach ($item in $Wanted) {
        $route = @($routes | Where-Object { $_.Guid -eq $item.Guid -and $_.Family -eq $item.Family } | Sort-Object TotalMetric | Select-Object -First 1)
        if ($route.Count -ne 1) { throw 'A managed default route disappeared during priority verification.' }
        $old = @($Before | Where-Object { $_.Guid -eq $item.Guid -and $_.Family -eq $item.Family })[0]
        # Recompute the no-change reference using the LIVE route metric, including
        # unrelated routes that arrived after planning. Only our metric delta may
        # be responsible for a changed ordering, never a VPN's own configuration.
        $reference = [long]$route[0].RouteMetric+[long]$old.Metric
        $after = if ($Proposed) { [long]$route[0].RouteMetric+[long]$item.Metric } else { [long]$route[0].TotalMetric }
        foreach ($outside in @($routes | Where-Object { $_.Family -eq $item.Family -and $_.Guid -notin $managedGuids } | Group-Object Guid | ForEach-Object { $_.Group | Sort-Object TotalMetric | Select-Object -First 1 })) {
            $outsideTotal=[long]$outside.TotalMetric
            $oldOrder=$reference.CompareTo($outsideTotal); $newOrder=$after.CompareTo($outsideTotal)
            if ($oldOrder -eq 0 -or $oldOrder -ne $newOrder) { throw 'Live unrelated/VPN default priority would change; recalculate the complete switch plan.' }
        }
    }
}

function Confirm-SwitchingAutoPreconditions {
    param([object[]]$Plan, [switch]$AfterWrite)
    $auto=@($Plan | Where-Object { $_.PSObject.Properties['ControlMode'] -and $_.ControlMode -eq 'Auto' })
    if (-not $auto.Count) { return }
    if ($auto.Count -ne $Plan.Count) { throw 'Mixed manual and automatic operation metadata.' }
    $routes=@(Get-SwitchingRoutes)
    $families=@($Plan.Family | Select-Object -Unique)
    if (@($routes | Where-Object Family -notin $families).Count) { throw 'Automatic sample no longer covers the live protocols.' }
    foreach ($family in $families) {
        $items=@($auto | Where-Object Family -eq $family)
        $live=@($routes | Where-Object Family -eq $family)
        if (-not $live.Count) { throw 'An automatic sample default route disappeared.' }
        $liveGuids=@($live.Guid | Sort-Object -Unique)
        foreach ($item in $items) {
            if (-not $item.PSObject.Properties['ExpectedCurrentGuid'] -or -not $item.ExpectedCurrentGuid -or -not $item.PSObject.Properties['ObservedDefaultGuids']) { throw 'Automatic plan is missing its sampled-route preconditions.' }
            $observed=@($item.ObservedDefaultGuids | Sort-Object -Unique)
            if (@(Compare-Object $observed $liveGuids).Count) { throw 'Default adapter topology changed after the automatic health sample.' }
        }
        $expected=@($items.ExpectedCurrentGuid | Select-Object -Unique)
        if ($expected.Count -ne 1) { throw 'Automatic sample has conflicting current interfaces.' }
        if (-not $AfterWrite) {
            $minimum=($live | Measure-Object TotalMetric -Minimum).Minimum
            $winners=@($live | Where-Object TotalMetric -eq $minimum | Select-Object -ExpandProperty Guid -Unique)
            if ($winners.Count -ne 1 -or $winners[0] -ne $expected[0]) { throw 'The uniquely failing sampled default interface is no longer current; resample before automatic switching.' }
        }
    }
}

function Get-SwitchingPendingPaths {
    param([string]$ExpectedPath)
    $full=[IO.Path]::GetFullPath($ExpectedPath)
    $directory=[IO.Path]::GetDirectoryName($full); $name=[IO.Path]::GetFileName($full)
    if (-not (Test-Path -LiteralPath $directory)) { return }
    foreach ($file in @(Get-ChildItem -LiteralPath $directory -File -ErrorAction Stop)) {
        if ($file.Name -eq ($name+'.pending.json') -or ($file.Name.StartsWith($name+'.restore-',[StringComparison]::OrdinalIgnoreCase) -and $file.Name.EndsWith('.pending.json',[StringComparison]::OrdinalIgnoreCase))) { $file.FullName }
    }
}

function Test-ManagedMetrics {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$ExpectedPath, [string]$BackupPath = '')
    try {
        if (@(Get-SwitchingPendingPaths $ExpectedPath).Count) { return $false }
        if (-not (Test-Path -LiteralPath $ExpectedPath)) {
            return (-not ($BackupPath -and (Test-Path -LiteralPath $BackupPath)))
        }
        foreach ($saved in @(Read-JsonArray $ExpectedPath)) {
            $actual = Get-SwitchingState $saved.Guid $saved.Family
            if (-not (Test-SwitchingStateEqual $actual $saved)) { return $false }
        }
        return $true
    } catch { return $false }
}

function Invoke-SwitchingLock {
    param([string]$BackupPath, [scriptblock]$Action)
    $directory = Split-Path -Parent ([IO.Path]::GetFullPath($BackupPath))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $lock = $null
    try {
        $lock = [IO.File]::Open(($BackupPath+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        & $Action
    } finally { if ($lock) { $lock.Dispose() } }
}

function Invoke-SwitchingTransaction {
    param([object[]]$Wanted, [string]$BackupPath, [string]$ExpectedPath, [switch]$Restore, [switch]$Force)
    $previousPending=@(Get-SwitchingPendingPaths $ExpectedPath)
    if (-not $Restore -and $previousPending.Count) { throw 'An incomplete operation needs explicit restoration before further switching.' }
    if ($Restore -and -not $Force -and -not (Test-ManagedMetrics $ExpectedPath $BackupPath)) { throw 'Missing ownership evidence, external metric changes or an incomplete operation require explicit confirmation (-Force) before restore.' }
    $isAuto=@($Wanted | Where-Object { $_.PSObject.Properties['ControlMode'] -and $_.ControlMode -eq 'Auto' }).Count -gt 0
    if ($isAuto -and -not (Test-ManagedMetrics $ExpectedPath $BackupPath)) { throw 'Automatic switching cannot overwrite externally changed or unowned metrics.' }
    if (@($Wanted | Group-Object Guid,Family | Where-Object Count -ne 1).Count) { throw 'Duplicate GUID/protocol in metric operation.' }
    $before = @()
    $minimumMetric=1L; $maximumMetric=9999L
    if ($Restore) { $minimumMetric=0L; $maximumMetric=4294967295L }
    foreach ($item in $Wanted) {
        if ([string]::IsNullOrWhiteSpace($item.Guid) -or $item.Family -notin @('IPv4','IPv6') -or [long]$item.Metric -lt $minimumMetric -or [long]$item.Metric -gt $maximumMetric -or $item.Automatic -notin @('Enabled','Disabled')) {
            throw 'Invalid GUID, protocol, metric, or automatic-metric state.'
        }
        $before += Get-SwitchingState $item.Guid $item.Family
    }
    $hadExpected = Test-Path -LiteralPath $ExpectedPath
    $expectedBefore = @(); if ($hadExpected) { $expectedBefore = @(Read-JsonArray $ExpectedPath) }
    $targets = @(); if (-not $Restore) {
        Confirm-SwitchingAutoPreconditions $Wanted
        $targets = @(Get-SwitchingTargets $Wanted)
        if (@($targets | Select-Object -ExpandProperty Guid -Unique).Count -ne 1) { throw 'All active protocols must select the same physical interface.' }
        Confirm-SwitchingUnmanagedOrder $Wanted $before -Proposed
    }
    if (-not $Restore) {
        $baseline = @(); if (Test-Path -LiteralPath $BackupPath) { $baseline = @(Read-JsonArray $BackupPath) }
        $newOriginal = @($before | Where-Object { $key="$($_.Guid)/$($_.Family)"; $key -notin @($baseline | ForEach-Object { "$($_.Guid)/$($_.Family)" }) })
        $needsChange = @($Wanted | Where-Object {
            $item=$_; $current=@($before | Where-Object { $_.Guid -eq $item.Guid -and $_.Family -eq $item.Family })[0]
            -not (Test-SwitchingStateEqual $current $item -AllowAutomaticRecalculation)
        }).Count -gt 0
        if ($needsChange -and $newOriginal.Count) { Write-AtomicJson $BackupPath @($baseline+$newOriginal) }
    }
    # A recovery operation gets its own journal. It never replaces evidence of the
    # interrupted operation whose partial state it is trying to recover.
    $pendingPath=$ExpectedPath+'.pending.json'
    if ($previousPending.Count) { $pendingPath=$ExpectedPath+'.restore-'+[guid]::NewGuid().ToString('N')+'.pending.json' }
    $attempts=New-Object System.Collections.ArrayList
    $journal=[pscustomobject]@{ Before=@($before); ExpectedBefore=@($expectedBefore); HadExpected=[bool]$hadExpected; Attempts=$attempts; Restore=[bool]$Restore }
    $persist={ Write-AtomicJson $pendingPath $journal }
    & $persist
    $changed=0
    try {
        if (-not $Restore) { Confirm-SwitchingAutoPreconditions $Wanted }
        foreach ($item in $Wanted) {
            $old=@($before | Where-Object { $_.Guid -eq $item.Guid -and $_.Family -eq $item.Family })[0]
            $attempt=@{ Before=$old; Attempted=$false; Owned=@() }
            $null=$attempts.Add($attempt)
            if (Set-SwitchingState $item $old $attempt $persist) { $changed++ }
        }
        foreach ($item in $Wanted) {
            if (-not (Test-SwitchingStateEqual (Get-SwitchingState $item.Guid $item.Family) $item -AllowAutomaticRecalculation)) { throw 'Final metric readback failed.' }
        }
        if ($Restore) {
            if (Test-Path -LiteralPath $ExpectedPath) { Remove-Item -LiteralPath $ExpectedPath -Force -ErrorAction Stop }
            foreach ($path in @($previousPending+@($pendingPath))) { Remove-Item -LiteralPath $path -Force -ErrorAction Stop }
            Remove-Item -LiteralPath $BackupPath -Force -ErrorAction Stop
        } else {
            Confirm-SwitchingAutoPreconditions $Wanted -AfterWrite
            Confirm-SwitchingTargets $targets
            Confirm-SwitchingUnmanagedOrder $Wanted $before
            $after = @($Wanted | ForEach-Object { Get-SwitchingState $_.Guid $_.Family })
            Write-AtomicJson $ExpectedPath @(Merge-SwitchingStates $expectedBefore $after)
            Remove-Item -LiteralPath $pendingPath -Force -ErrorAction Stop
        }
        [pscustomobject]@{ Success=$true; Changed=$changed }
    } catch {
        Write-Verbose $_.ScriptStackTrace
        $failure=$_.Exception.Message; $rollbackErrors=@()
        if ($_.Exception.Data.Contains('SwitchingOwnershipConflict')) { $rollbackErrors += 'External metric ownership conflict; conflicting values were not overwritten.' }
        foreach ($old in $before) {
            $issued=@($attempts | Where-Object { $_.Attempted -and $_.Before.Guid -eq $old.Guid -and $_.Before.Family -eq $old.Family })
            if ($issued.Count) { continue }
            try {
                if (-not (Test-SwitchingStateEqual (Get-SwitchingState $old.Guid $old.Family) $old)) { throw "Untouched interface $($old.Guid)/$($old.Family) changed externally; rollback left it untouched." }
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        for ($position=$attempts.Count-1; $position -ge 0; $position--) {
            $attempt=$attempts[$position]
            if (-not $attempt.Attempted) { continue }
            $old=$attempt.Before
            try {
                $actual=Get-SwitchingState $old.Guid $old.Family
                if (Test-SwitchingStateEqual $actual $old) { continue }
                $owned=@($attempt.Owned | Where-Object { Test-SwitchingStateEqual $actual $_ })
                if (-not $owned.Count) { throw "External change to $($old.Guid)/$($old.Family); rollback left it untouched." }
                Set-SwitchingState $old $actual $attempt $persist | Out-Null
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        if (-not $rollbackErrors.Count) {
            try {
                if ($hadExpected) { Write-AtomicJson $ExpectedPath @($expectedBefore) }
                elseif (Test-Path -LiteralPath $ExpectedPath) { Remove-Item -LiteralPath $ExpectedPath -Force -ErrorAction Stop }
                # Only this operation's journal may be removed on rollback. Any
                # prior interrupted-operation journal remains an automatic stop.
                if (Test-Path -LiteralPath $pendingPath) { Remove-Item -LiteralPath $pendingPath -Force -ErrorAction Stop }
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count) { throw "$failure Rollback incomplete: $($rollbackErrors -join '; '). Recovery baseline and operation journal retained." }
        throw "$failure All operation metrics were rolled back; recovery baseline retained."
    }
}

function Set-SwitchPlan {
    [CmdletBinding()]
    param([object[]]$Plan, [Parameter(Mandatory=$true)][string]$BackupPath, [Parameter(Mandatory=$true)][string]$ExpectedPath)
    if (-not @($Plan).Count) { return [pscustomobject]@{ Success=$true; Changed=0 } }
    if (@($Plan | Select-Object -ExpandProperty Guid -Unique).Count -gt 2) { throw 'A switch may manage at most two physical adapters.' }
    $wanted = @($Plan | ForEach-Object {
        if ($_.PSObject.Properties['Kind'] -and $_.Kind -notin @('Wired','WiFi')) { throw 'Only physical wired and Wi-Fi interfaces may be switched.' }
        $state=[pscustomobject]@{ Guid=$_.Guid; Family=$_.Family; Metric=$_.Metric; Automatic='Disabled' }
        foreach ($name in @('TargetGuid','ControlMode','ExpectedCurrentGuid','ObservedDefaultGuids')) {
            if ($_.PSObject.Properties[$name]) { $state | Add-Member NoteProperty $name $_.$name }
        }
        $state
    })
    Invoke-SwitchingLock $BackupPath { Invoke-SwitchingTransaction $wanted $BackupPath $ExpectedPath }
}

function Restore-SwitchMetrics {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$BackupPath, [Parameter(Mandatory=$true)][string]$ExpectedPath, [switch]$Force)
    Invoke-SwitchingLock $BackupPath {
        if (-not (Test-Path -LiteralPath $BackupPath)) {
            if (@(Get-SwitchingPendingPaths $ExpectedPath).Count) { throw 'An incomplete operation has no recovery baseline; manual recovery is required.' }
            if (Test-Path -LiteralPath $ExpectedPath) { Remove-Item -LiteralPath $ExpectedPath -Force -ErrorAction Stop }
            return [pscustomobject]@{ Success=$true; Changed=0 }
        }
        $original = @(Read-JsonArray $BackupPath)
        Invoke-SwitchingTransaction $original $BackupPath $ExpectedPath -Restore -Force:$Force
    }
}
