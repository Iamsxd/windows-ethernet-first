Set-StrictMode -Version Latest

function Get-ViewValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $Default }
    $property=$Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Get-ProfileView {
    param([object[]]$Links,[string]$Profile,[bool]$Stale=$false)
    $state='Unknown'; $detail=@(); $good=0; $bad=0; $unknown=0
    foreach ($link in $Links) {
        $g=[int](Get-ViewValue $link ($Profile+'Good') 0)
        $b=[int](Get-ViewValue $link ($Profile+'Bad') 0)
        $blocked=[bool](Get-ViewValue $link ($Profile+'ProbeBlocked') $true)
        $text='确认中'
        if ($blocked -or $Stale) { $unknown++; $text='未知' }
        elseif ($g -ge 2) { $good++; $text='正常' }
        elseif ($b -ge 3) { $bad++; $text='不可达' }
        $detail+=([string](Get-ViewValue $link Family '')+'：'+$text)
    }
    if (-not $Links.Count) { $state='Disconnected' }
    elseif ($Stale) { $state='Unknown' }
    elseif ($good -eq $Links.Count) { $state='Reachable' }
    elseif ($good) { $state='Partial' }
    elseif ($bad -eq $Links.Count) { $state='Failed' }
    elseif ($unknown) { $state='Unknown' }
    else { $state='Pending' }
    $styles=@{
        Reachable=@('正常','#16866A','#E8F7F1'); Partial=@('部分可达','#B77916','#FFF5DE')
        Failed=@('不可达','#C95157','#FFF0F0'); Unknown=@('未知','#7B879B','#F0F3F8')
        Pending=@('确认中','#A16B17','#FFF5DE'); Disconnected=@('未连接','#8A95A6','#F0F3F8')
    }
    $style=$styles[$state]
    [pscustomobject]@{State=$state;Text=$style[0];Color=$style[1];Background=$style[2];Detail=($detail -join "`n")}
}

function Get-AdapterCardView {
    param([string]$Kind,[object[]]$Adapters,[object[]]$Links,[string[]]$ManagedGuids,[string]$CurrentGuid,[bool]$Stale)
    $available=@($Adapters | Where-Object Kind -eq $Kind)
    $selected=@($available | Where-Object Guid -in $ManagedGuids)
    if (-not @($ManagedGuids).Count -and $available.Count -eq 1) { $selected=@($available[0]) }
    $adapter=if ($selected.Count -eq 1) {$selected[0]} else {$null}
    $guid=[string](Get-ViewValue $adapter Guid '')
    if (-not $guid -and @($ManagedGuids).Count) {
        $matched=@($Links | Where-Object { $_.Kind -eq $Kind -and $_.Guid -in $ManagedGuids } | Select-Object -First 1)
        if ($matched.Count) { $guid=[string]$matched[0].Guid }
    }
    $rows=@($Links | Where-Object { $guid -and $_.Guid -eq $guid })
    $name=[string](Get-ViewValue $adapter Name $(if ($available.Count -gt 1) {'请选择网卡'} else {'等待连接'}))
    $source=@($rows | ForEach-Object { [string](Get-ViewValue $_ Source '') } | Where-Object {$_} | Select-Object -Unique) -join ' / '
    $isCurrent=($guid -and $guid -eq $CurrentGuid)
    $subtitle=if ($source) {$source} else {'连接后显示本机地址'}
    $profile=[string](Get-ViewValue $adapter Profile '')
    if ($Kind -eq 'WiFi' -and $profile) { $subtitle=$profile+'  ·  '+$subtitle }
    [pscustomobject]@{
        Guid=$guid;Name=$name;Subtitle=$subtitle;IsCurrent=[bool]$isCurrent
        NeedsSelection=($available.Count -gt 1 -and -not $guid);HasRoute=($rows.Count -gt 0)
        Badge=$(if ($isCurrent) {'正在使用'} elseif ($rows.Count) {'备用线路'} else {'未连接'})
        Domestic=(Get-ProfileView $rows Domestic $Stale);Foreign=(Get-ProfileView $rows Foreign $Stale)
        CanPrefer=($rows.Count -gt 0 -and -not $isCurrent)
    }
}

function Get-DashboardModel {
    param($Snapshot,[hashtable]$State,[string[]]$ManagedGuids=@(),[string]$ErrorMessage='')
    $links=@(Get-ViewValue $Snapshot Links @()); $adapters=@(Get-ViewValue $Snapshot Adapters @())
    $current=@()
    foreach ($family in @('IPv4','IPv6')) {
        $rows=@($links | Where-Object Family -eq $family)
        if ($rows.Count) {
            $minimum=($rows | Measure-Object TotalMetric -Minimum).Minimum
            $current+=@($rows | Where-Object TotalMetric -eq $minimum)
        }
    }
    $guids=@($current | Select-Object -ExpandProperty Guid -Unique)
    $currentGuid=''; $currentKind='Pending'; $currentTitle='正在读取连接'; $currentDetail='首次检测将在片刻后完成'
    $noticeKind='Information'; $noticeCode='Monitor'; $notice='当前为只检测模式，可手动选择线路，或开启自动守护。'
    if ($guids.Count -eq 1) {
        $currentGuid=$guids[0]; $currentKind=[string]$current[0].Kind
        $currentTitle=switch ($currentKind) { Wired {'有线网络'} WiFi {'Wi-Fi 网络'} Virtual {'VPN / 虚拟网络'} default {[string]$current[0].Name} }
        $dom=Get-ProfileView $current Domestic ([bool]$ErrorMessage)
        $foreign=Get-ProfileView $current Foreign ([bool]$ErrorMessage)
        $currentDetail='国内 '+$dom.Text+'   /   国外 '+$foreign.Text
        if ($State.Mode -eq 'Auto') { $noticeCode='Guarding'; $notice='自动守护已开启。当前线路国内访问持续失败后，将切换到确认可用的备用线路。' }
        if ($dom.State -eq 'Reachable' -and $foreign.State -eq 'Failed') { $noticeKind='Warning';$noticeCode='ForeignUnavailable';$notice='国内访问正常，国外检测暂不可达。保留当前线路，避免无效切换。' }
        if ($currentKind -eq 'Virtual') { $noticeKind='Warning';$noticeCode='VpnDefault';$notice='默认出口由 VPN 管理；物理线路自动切换会等待，不会接管 VPN 优先级。' }
    } elseif ($guids.Count -gt 1) {
        $currentKind='Split';$currentTitle='存在多个默认出口';$currentDetail='不同协议或相同优先级使出口不明确'
        $noticeKind='Warning';$noticeCode='Split';$notice='当前默认出口不明确，自动切换暂停。可在两条线路均就绪时手动选择。'
    } elseif ($Snapshot) {
        $currentKind='Offline';$currentTitle='尚无可用默认出口';$currentDetail='请检查网线、Wi-Fi 连接和地址分配'
    }
    if ($State.LastReason -like 'Paused:*') { $noticeKind='Warning';$noticeCode='OwnershipPaused';$notice='网卡优先级被外部修改，自动守护已暂停。请检查设置，再使用“恢复原设置”处理。' }
    if ($ErrorMessage) { $noticeKind='Error';$noticeCode='Error';$notice='本轮检测未完成，已暂停自动控制。请重新检测或查看诊断信息。' }
    $stamp=[string](Get-ViewValue $Snapshot CheckedAt '')
    $checked='等待首次检测'
    if ($stamp) { try { $checked='最近检测 '+[DateTimeOffset]::Parse($stamp).ToLocalTime().ToString('HH:mm:ss') } catch { } }
    [pscustomobject]@{
        ManagedGuids=@($ManagedGuids);CurrentGuid=$currentGuid;CurrentKind=$currentKind;CurrentTitle=$currentTitle;CurrentDetail=$currentDetail
        NoticeKind=$noticeKind;NoticeCode=$noticeCode;Notice=$notice;CheckedText=$checked;Adapters=$adapters
        Wired=(Get-AdapterCardView Wired $adapters $links $ManagedGuids $currentGuid ([bool]$ErrorMessage))
        WiFi=(Get-AdapterCardView WiFi $adapters $links $ManagedGuids $currentGuid ([bool]$ErrorMessage))
        ErrorMessage=$ErrorMessage;Mode=$State.Mode;ReturnToWired=$State.ReturnToWired
    }
}
