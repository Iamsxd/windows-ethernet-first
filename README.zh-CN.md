# Ethernet First：双线路连通面板

这是 [w1zardz/windows-ethernet-first](https://github.com/w1zardz/windows-ethernet-first) 的 MIT 协议分支，适用于 Windows 10 / 11。保留 PowerShell / C# 实现，使用原生 WPF 窗口，不需要 Python、额外驱动或 PowerShell 模块。

## 使用

解压完整仓库后双击 **start.bat**，接受 Windows 管理员授权即可打开主窗口。两张线路卡分别显示国内、国外状态，顶部显示实际默认出口。窗口支持缩放与滚动；关闭窗口会隐藏到托盘，双击托盘图标可重开。托盘图标可能在右下角“隐藏的图标”中。

**启动时只检测，不会自动调整网络。** 主窗口提供手动按钮和自动开关，右键托盘也可操作：

| 操作 | 效果 |
|---|---|
| 优先使用有线 / Wi-Fi | 提高该线路默认出口优先级，同时关闭自动模式 |
| 自动故障切换 | 开启或关闭自动模式；关闭后保留当前优先级 |
| 立即检测 | 重新检测两条线路的 DNS、TLS 和两组 HTTPS 站点 |
| 打开主窗口 | 查看国内、国外状态与各协议的提示 |
| 恢复原设置 | 恢复第一次修改前保存的设置，同时关闭自动模式 |
| 退出 | 停止检测并保留当前优先级；先点“恢复”可还原后退出 |

无需安装开机任务。若运行 **install.bat**，会安装登录启动的托盘程序，默认不弹主窗口；每次启动仍只检测。安装版状态在 `%PROGRAMDATA%\EthernetFirst`，便携版在 `%LOCALAPPDATA%\EthernetFirst`，应避免混用。**uninstall.bat** 停止安装任务并恢复其保存的设置；便携版请先在托盘退出。

## 自动切换规则

默认每轮间隔 15 秒，检测耗时另计，上一轮结束后才开始下一轮。每张物理网卡、每个活动协议独立检测两组 HTTPS 204 地址：国内默认 Huawei / vivo，国外默认 gstatic / Google。每组任一站点成功即为本轮可达，两组并行、分别累计结果。探测同时绑定源 IP 和出口接口，DNS 使用该网卡同协议的 DNS 服务器，验证 TLS 证书和主机名，不使用系统 HTTP 代理。

开启自动模式后，当前线路的**国内检测**连续 **3 轮失败**，且备用线路国内检测连续 **2 轮成功**，才切换。每次切换后冷却 **180 秒**。**仅国外检测失败时保持当前线路**。例如有线能访问国外、Wi-Fi 只能访问国内时，不会为国外故障来回切换。

“**有线恢复后自动切回**”是独立开关，默认关闭，仅在自动模式生效。有线的国内、国外检测都连续两轮成功，并经过冷却后，才从 Wi-Fi 切回有线。此偏好可以记住，但**自动模式每次启动仍默认关闭**。

两条线路都失败、检测权限受限、接口选择不明确、IPv4 / IPv6 默认出口分裂时不自动改优先级。没有同协议 DNS 的 IPv6 探测显示未知，不借用另一线路的 DNS。状态只表示配置站点的可达性，不能保证所有国内 / 国外网站都可用。

只管理一张真实有线和一张真实 Wi-Fi 网卡。保留两张连接，不改 IP、网关、DNS、代理、VPN 或路由器配置。修改前按 GUID 保存基线；写入或验证失败会回滚，原始备份保留。发现外部修改优先级时暂停控制；覆盖恢复前会征询确认。

切换调整默认路由优先级；已有长连接可能要重新连接。VPN 专用路由、应用绑定的连接不一定迁移。两条线路共用同一 GL 或上游时，切换无法解决共同上游故障。

## 网卡选择与检测站点

默认要求唯一一张有线和一张 Wi-Fi。多候选时，在两张卡片中各选一张，点击“保存网卡选择”；两项都选“自动”则使用唯一候选。选择尚未保存时会标明当前生效网卡并禁用切换按钮，可点击“撤销选择”。已有工具修改记录时，先恢复原设置再更换网卡。

网卡选择与自动切回偏好保存在状态目录的 `preferences.json`，优先于 `config.json` 的对应默认值；不保存活动的自动模式。也可在 `config.json` 指定默认 GUID 和检测站点：

```json
{
  "adapterOverrides": {},
  "managedAdapterGuids": [],
  "autoReturnToWired": false,
  "domesticHttpsEndpoints": [
    "https://connectivitycheck.platform.hicloud.com/generate_204",
    "https://wifi.vivo.com.cn/generate_204"
  ],
  "foreignHttpsEndpoints": [
    "https://www.gstatic.com/generate_204",
    "https://www.google.com/generate_204"
  ]
}
```

需要显式 GUID 时，可用 `Get-NetAdapter | Select Name,InterfaceGuid` 查询，并在数组填写两张网卡的真实 GUID。每组须配置两个不同主机、使用 HTTPS 且返回 204 的地址。旧 `httpsEndpoints` 兼容为国外组，新 `foreignHttpsEndpoints` 优先。旧 TCP `probeIPv4` / `probeIPv6` 不再用于健康判定。`adapterOverrides` 不能把虚拟硬件变成可管理网卡。编辑配置后重启程序。

## 命令行

```powershell
# 只检测一次，输出 JSON，不修改网络
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once

# 管理员 PowerShell，先退出正在运行的托盘
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once -Prefer WiFi
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Restore
```

`-Apply` 明确启用自动模式；`-Prefer Wired` / `-Prefer WiFi` 执行一次手动选择。PowerShell 7 图形启动请加 `-STA`。`-TrayOnly` 启动时只显示托盘，`-NoNotifications` 不创建图形界面。`-Restore -ForceRestore` 明确允许覆盖外部修改。恢复时使用原来的 `-StateDirectory`；丢失网卡会保留未完成记录，重连后再试，不要删除备份来清除错误。

## 测试与隐私

```powershell
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\Run-All.ps1
pwsh -NoProfile -STA -File .\tests\Run-All.ps1
```

策略、事务、入口和快照测试模拟 Windows 网络调用；探测测试使用本机临时 DNS/TLS 服务，不修改实际网卡或证书存储。WPF 测试检验真实控件、命令队列、隐藏重开及小窗口滚动。CI 覆盖 PowerShell 5.1 与 7。

仅向指定 DNS 和两组 HTTPS 站点发送固定健康请求，不收集浏览历史。状态、日志、偏好与备份只存本机，含网卡名称、地址和 GUID，请勿上传。系统证书链验证可能自行获取证书元数据；不会绕过证书或主机名验证。
