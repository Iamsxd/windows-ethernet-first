# Ethernet First：手动切换 + 可选自动故障切换

这是 [w1zardz/windows-ethernet-first](https://github.com/w1zardz/windows-ethernet-first) 的 MIT 协议分支，适用于 Windows 10 / 11。保留 PowerShell 和 C# 实现，不需要 Python、额外驱动或 PowerShell 模块。

## 使用

解压完整仓库后双击 **start.bat**，接受 Windows 管理员授权。右下角托盘图标可能在“隐藏的图标”中。

**启动时只检测，不会自动调整网络。** 右键图标可选择：

| 操作 | 效果 |
|---|---|
| 优先使用有线 | 提高有线默认出口优先级，同时关闭自动模式 |
| 优先使用 Wi-Fi | 提高 Wi-Fi 默认出口优先级，同时关闭自动模式 |
| 启用自动故障切换 | 显式开启或关闭自动模式；关闭后保留当前优先级 |
| 立即检测两条线路 | 检测 DNS、TLS 和 HTTPS 响应 |
| 查看线路状态 | 查看各网卡、IPv4 / IPv6 的检测结果 |
| 恢复工具修改前的设置 | 恢复第一次修改前保存的设置，并关闭自动模式 |
| 退出 | 停止检测并保留当前优先级；先点“恢复”可还原后退出 |

无需安装开机任务。若自行运行 **install.bat**，会安装登录启动的托盘程序；每次启动仍只观察，需要手动开启自动模式。安装版状态在 `%PROGRAMDATA%\EthernetFirst`，便携版在 `%LOCALAPPDATA%\EthernetFirst`，两者应避免混用。**uninstall.bat** 停止安装任务并恢复其保存的设置；便携版先在托盘退出。

## 自动切换规则

默认每轮间隔 15 秒，检测耗时另计，上一轮结束后才会开始下一轮。探测使用 Google / Cloudflare 两个小型 HTTPS 204 地址；单个站点失败不会判线路故障。实际探测同时绑定源 IP 和出口接口，DNS 使用该网卡对应协议的 DNS 服务器，验证 TLS 证书和主机名，不使用系统 HTTP 代理。

当前线路连续 **3 轮全部失败**，且备用线路连续 **2 轮成功**，才切换。每次切换后冷却 **180 秒**，不会主动抢回刚恢复的原线路。两条线路都失败、检测权限受限、接口选择不明确、IPv4 / IPv6 默认出口分裂时不自动改优先级。没有同协议 DNS 的 IPv6 探测会显示未知，不会擅自借用另一线路的 DNS。

只管理一张真实有线网卡和一张真实 Wi-Fi 网卡。两张网卡保持连接，不改 IP、网关、DNS、代理、VPN 或 GL 路由器配置。修改前按 GUID 保存基线；写入或验证失败会回滚，原始备份保留。发现其他软件修改优先级时暂停控制；覆盖恢复前会征询确认。

切换调整的是默认路由优先级。浏览器已有连接可能需要刷新；VPN 的专用路由、应用绑定的连接不会因此全部迁移。有线与 Wi-Fi 都接同一台 GL 时，只能绕过单条链路问题，无法解决 GL 或共同上游的故障。

## 多网卡配置

默认要求恰好一张有线和一张 Wi-Fi；如果检测到多张候选网卡，修改 `config.json`，明确指定两张网卡的 GUID：

```powershell
Get-NetAdapter | Select-Object Name, InterfaceDescription, InterfaceGuid
```

```json
{
  "adapterOverrides": {},
  "managedAdapterGuids": ["{有线网卡的GUID}", "{无线网卡的GUID}"],
  "httpsEndpoints": [
    "https://www.gstatic.com/generate_204",
    "https://cp.cloudflare.com/generate_204"
  ]
}
```

占位符必须替换成真实 GUID。配置修改后重启程序。两个检测地址须来自不同主机、使用 HTTPS 并正常返回 204；请按要检测的网络能力选择地址。旧 `probeIPv4` / `probeIPv6` TCP 地址配置不再用于健康判定。`adapterOverrides` 只允许分类真实硬件，不能把虚拟网卡变成可管理网卡。

## 命令行

```powershell
# 只检测一次，输出 JSON，不修改网络
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once

# 以下操作需管理员 PowerShell，且先退出正在运行的托盘
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once -Prefer WiFi
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Restore
```

`-Apply` 明确启用自动模式；`-Prefer Wired` / `-Prefer WiFi` 只执行一次手动选择。`-Restore -ForceRestore` 是明确允许覆盖外部优先级修改的命令。恢复时请使用原来的 `-StateDirectory`；离线或丢失的网卡会保留未完成的恢复记录，重新连接后重试。不要删除备份来清除错误。

## 测试与隐私

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Run-All.ps1
pwsh -NoProfile -File .\tests\Run-All.ps1
```

策略、事务、入口和快照测试使用模拟的 Windows 网络调用；探测测试使用本机临时 DNS/TLS 服务，不修改实际网卡或证书存储。CI 覆盖 PowerShell 5.1 与 7。实际外网可用性取决于网络环境。

探测会向指定 DNS 和两个 HTTPS 站点发送固定健康请求，不收集浏览历史。`status.json`、`events.log` 和网卡备份仅保存在本机，含网卡名称与 GUID，请勿上传。系统 TLS 证书链验证可能自行获取证书元数据；不会绕过证书或主机名验证。
