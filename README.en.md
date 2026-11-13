# Ethernet First — manual switching and optional HTTPS failover

[中文说明](README.zh-CN.md) · [Upstream](https://github.com/w1zardz/windows-ethernet-first)

This MIT-licensed fork retains the upstream PowerShell/C# implementation for Windows 10/11. No Python, driver or external PowerShell module is needed.

## Start

Extract the complete repository and run **start.bat**. Accept Windows UAC authorization; the tray starts in **monitor-only mode**. This portable launcher uses Chinese labels. For English, run `EthernetFirst.ps1 -Language en` from an administrator PowerShell.

Right-click the tray to prefer Ethernet, prefer Wi-Fi, toggle automatic failover, check now, view status, restore original metrics, or exit. Manual selection disables auto. Exit leaves current metrics in place; use Restore first to undo them. Each new process starts with auto off unless explicitly passed `-Apply`.

Optional **install.bat** installs a protected, elevated task at the current user's sign-in; it also starts monitor-only. Portable state lives in `%LOCALAPPDATA%\EthernetFirst`; installed state lives in `%PROGRAMDATA%\EthernetFirst`. Use the same state directory to restore. Exit any portable tray before installing or uninstalling. **uninstall.bat** stops the installed task and restores its original metrics.

## Health and safety

- Probe Google and Cloudflare HTTPS 204 endpoints, binding both source and outgoing interface. DNS uses that interface's same-family servers. TLS validates trust and hostname. No HTTP proxy or system DNS fallback is used.
- One healthy endpoint is sufficient. Automatic failover requires three failed current rounds and two successful alternate rounds in every active protocol. A 180-second cooldown prevents oscillation; no automatic failback.
- Only one real wired adapter and one real Wi-Fi adapter are managed. Ambiguous selections, split IPv4/IPv6 defaults, unknown local policy failures, and controlling unmanaged/VPN defaults refuse unsafe changes. Missing same-family DNS is unknown.
- Save the first baseline by GUID, resolve indexes again before writes, verify actual default-route winners and roll back partial failures. External metric changes pause control. Restore asks before overwriting external changes.
- Keep both adapters connected. Do not change IP, gateway, DNS, system proxy, VPN or router configuration. Existing sockets, application-bound traffic and more-specific VPN routes may keep using another connection.

When wired and Wi-Fi share the same router/upstream, switching can bypass a broken local link but cannot fix that common upstream. A successful health endpoint does not guarantee every website works. Each round starts 15 seconds after the previous one finishes; no overlapping probe rounds.

## Configuration and CLI

`config.json` accepts `adapterOverrides`, `managedAdapterGuids` and exactly two `httpsEndpoints` on distinct hosts returning HTTP 204. The default empty GUID list requires exactly one wired and one Wi-Fi candidate. To select explicitly, get GUIDs with `Get-NetAdapter | Select Name,InterfaceGuid`, add the two GUIDs and restart. Overrides cannot turn virtual hardware into physical hardware. Legacy TCP `probeIPv4` / `probeIPv6` lists are no longer used for health.

```powershell
# Read-only, JSON output
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once

# Administrator shell; close existing tray first
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once -Prefer WiFi
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Restore
```

`-ForceRestore` with `-Restore` explicitly permits overwriting external metric changes. Reconnect missing adapters and retry incomplete restoration; their backup remains. Never delete the backup to dismiss a recovery error.

## Validation and privacy

Run `tests/Run-All.ps1` under Windows PowerShell 5.1 and PowerShell 7. Deterministic policy/transaction/controller/snapshot/entry tests mock Windows network calls. Socket tests use temporary local DNS/TLS peers and do not change real adapters or certificate stores.

Only fixed DNS/HTTPS health requests are sent. Logs and state remain local, contain adapter names/GUIDs, and should not be committed. Platform TLS chain validation may independently retrieve certificate metadata; target-host DNS and HTTPS connections remain interface-bound. No analytics or browsing history collection.
