# Ethernet First — prefer Ethernet over iPhone USB tethering on Windows

[Русская документация](README.md)

Windows may select **Apple Mobile Device Ethernet** when you plug in your
iPhone, even with a working wired Internet connection. Ethernet First is an
open-source Windows 10/11 PowerShell network monitor that prefers working
wired Ethernet, retains Wi-Fi / phone fallback, and displays notifications.

## Install

[Download and extract the ZIP](https://github.com/w1zardz/windows-ethernet-first/archive/refs/heads/main.zip), run **install.bat**, and accept the
Windows administrator prompt. No Python or third-party PowerShell modules are
required. The current administrator account gets an interactive scheduled task
at sign-in, with a tray icon and checks every 15 seconds.

Code lives in `C:\Program Files\EthernetFirst`; status, logs and original
metrics live in `C:\ProgramData\EthernetFirst`. Installation folders are
protected against standard-user writes because the task runs elevated.

## How it works

1. Classify hardware Ethernet, Wi-Fi, Apple USB tethering and RNDIS adapters.
2. Probe several public TCP/443 endpoints with sockets bound to both the source
   address and the outgoing interface. IPv4 and IPv6 are independent.
3. Require two successful checks for health and three failed checks for failure.
4. Prefer **working wired Ethernet → Wi-Fi → phone tethering**. Deprioritize
   failed connections only when another connection is proven available.
5. Save original metrics by adapter GUID before any change, for restoration.

The script does not disable adapters, alter VPN configuration or edit individual
routes. Physical default metrics remain below the priority of existing virtual
defaults. More-specific routes, existing sockets and VPN endpoints may continue
using another connection: changing metrics cannot guarantee all traffic moves.
Observed mobile-adapter traffic triggers an additional warning. Adapter byte
counts include local traffic and are not a cellular billing meter.
Wi-Fi traffic with healthy Ethernet also triggers a warning, covering hotspots
with arbitrary names. Notifications support English and Russian (`-Language`).

A fast link speed is not proof of Internet availability. A TCP handshake is
not a speed test or proof that DNS / every website works. No change is applied
while all connectivity results are unknown or failed. Large custom route
metrics are left alone. VPN throughput, MTU, DPI and server problems require
separate diagnostics.
Windows access-denied socket errors mean unknown connectivity, not an outage.
VPN Kill Switch policies can block direct probes. Configure permitted public
TCP/443 addresses using `probeIPv4` / `probeIPv6` arrays in `config.json` if needed.

## Detecting Wi-Fi hotspots

Wi-Fi hardware alone does not reveal whether the access point is a phone.
Names containing iPhone / iPad / Personal Hotspot are heuristic hints; unknown
Wi-Fi is simply lower priority than working wired Ethernet. Use adapter GUID
overrides in `config.json` for known hardware, then restart the task:

```json
{"adapterOverrides":{"{YOUR-ADAPTER-GUID}":"Mobile"}}
```

Find GUIDs with `Get-NetAdapter | Select Name,InterfaceDescription,InterfaceGuid`.
Overrides apply to the whole adapter across all Wi-Fi networks. Do not classify
a VPN as physical hardware.

## Monitor only / restore

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1
```

Standalone state defaults to `%LOCALAPPDATA%\EthernetFirst`. `-Apply` requires
elevation. Stop the monitor before using `-Restore` with the same state directory.
For an installed copy, **uninstall.bat** stops the task and restores original
metrics. Disconnected adapters may need to be reconnected before restoration;
unrestored entries are retained. Files and backups are kept after uninstall.

Notifications are state based and rate limited. Windows Do Not Disturb can
hide them; `status.json` and `events.log` remain available.

## Privacy and tests

Probes contact Cloudflare, Google and Yandex public IPs without sending application
payloads. No analytics, uploaded logs or bandwidth downloads. Local state
contains adapter names and GUIDs; keep it and VPN credentials out of Git.

Run `tests/Test-Core.ps1` for deterministic policy tests and socket-probe
compilation. GitHub Actions runs Windows PowerShell 5.1 and PowerShell 7.

MIT license. See the Russian README for Microsoft networking references.
