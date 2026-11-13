# Ethernet First — 手动切换与可选自动故障切换

[中文使用说明](README.zh-CN.md) · [English](README.en.md) · [原项目](https://github.com/w1zardz/windows-ethernet-first)

Windows 10 / 11 有线与 Wi-Fi 切换工具，基于上游 PowerShell / C# 修改，MIT 协议。

- 托盘手动选择有线或 Wi-Fi，两张网卡保持连接。
- **默认只检测**，自动故障切换可随时开关。
- 每张网卡独立进行 DNS、严格 TLS 和 HTTPS 204 检测。
- 连续失败才切换，三分钟冷却，不自动抢回。
- 按 GUID 保存原优先级；操作失败回滚，可恢复原设置。
- 不修改 GL 路由器、DNS、IP 或 VPN 配置。

下载完整代码后双击 **start.bat**，接受 Windows 管理员授权，再右键托盘图标操作。不需要 Python 或额外模块。启动程序不会安装登录任务，也不会自行开启自动模式。

多网卡选择、双协议限制、安装版与便携版的状态目录及测试方法，详见[中文说明](README.zh-CN.md)。

[原版俄文说明](README.upstream.ru.md) 保留供参考，描述的是上游旧行为；本分支以当前中英文说明为准。
