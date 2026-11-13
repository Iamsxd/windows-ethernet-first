# Ethernet First — dual-link reachability dashboard

[中文说明](README.zh-CN.md) · [Upstream](https://github.com/w1zardz/windows-ethernet-first)

MIT-licensed Windows 10/11 fork using PowerShell, C# and native WPF. No Python, additional drivers or external PowerShell modules.

## Start

Extract the complete repository and run **start.bat**. Accept Windows UAC; the dashboard starts in **monitor-only mode**. It displays domestic and foreign reachability independently for Ethernet and Wi-Fi, manual controls, automatic settings and recent events. Close hides to the tray; double-click the tray to reopen. The dashboard uses Chinese labels; `-Language en` selects English tray/CLI labels. PowerShell 7 GUI launches require `-STA`.

Manual preference disables auto. Exit leaves current metrics in place; use Restore first to undo them. Every new process starts with auto off unless explicitly passed `-Apply`.

Optional **install.bat** installs a protected elevated task at sign-in, starting monitor-only and tray-only. Portable state lives in `%LOCALAPPDATA%\EthernetFirst`; installed state in `%PROGRAMDATA%\EthernetFirst`. Use the same state directory for recovery. Exit the portable tray before installing/uninstalling. **uninstall.bat** stops the installed task and restores its saved metrics.

## Health and safety

- Two independent HTTPS 204 profiles: domestic defaults are Huawei/vivo; foreign defaults are gstatic/Google. Each succeeds when either endpoint succeeds. Profiles run concurrently for each link, with separate streaks. DNS uses interface-bound same-family servers; TLS validates trust and hostname. No HTTP proxy or system DNS fallback.
- Automatic failover uses **domestic health**: three failed current rounds and two successful alternate rounds in every active protocol. Foreign-only failure leaves the current connection in place. A 180-second cooldown prevents oscillation.
- An independent **return to Ethernet** preference defaults off. With auto enabled, it requires two successful domestic AND foreign rounds on Ethernet in every active family and the normal cooldown before returning from Wi-Fi.
- Only selected physical Ethernet/Wi-Fi adapters are managed. Ambiguous selections, split defaults, unknown local failures and controlling unmanaged/VPN defaults prevent automatic changes. Missing same-family DNS is unknown.
- Save the first baseline by GUID, resolve indexes again before writes, verify actual default-route winners and roll back partial failures. External metric changes pause control. Restore asks before overwriting external changes.
- Both adapters stay connected. No IP, gateway, DNS, system proxy, VPN or router changes. Existing sockets, bound applications and specific VPN routes may retain another connection.

Health refers only to configured test sites, not every domestic/foreign website. Switching cannot fix a router/upstream shared by both links. Rounds start 15 seconds after the previous one finishes, without overlap.

## Configuration and CLI

Select an Ethernet/Wi-Fi pair in the dashboard and save, or choose automatic for both (requires unique physical candidates). Restore outstanding metric changes before changing the managed pair. The state directory's `preferences.json` remembers adapter selection and return preference, overriding corresponding `config.json` defaults; it never persists active Auto mode.

`config.json` accepts `adapterOverrides`, `managedAdapterGuids`, `autoReturnToWired`, `domesticHttpsEndpoints` and `foreignHttpsEndpoints`. Each profile requires exactly two HTTPS 204 URLs on distinct hosts. Legacy `httpsEndpoints` is a foreign-profile alias; explicit `foreignHttpsEndpoints` takes precedence. Overrides cannot turn virtual hardware into physical hardware. Legacy TCP probe lists no longer determine health.

```powershell
# Read-only JSON
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once

# Administrator shell; close existing tray first
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Once -Prefer WiFi
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Apply
powershell -NoProfile -ExecutionPolicy Bypass -File .\EthernetFirst.ps1 -Restore
```

`-TrayOnly` hides the dashboard at startup; `-NoNotifications` omits the GUI. `-Restore -ForceRestore` explicitly permits overwriting external metric changes. Reconnect missing adapters and retry incomplete recovery; never delete the backup to dismiss an error.

## Validation and privacy

Run `tests/Run-All.ps1` with `-STA` under Windows PowerShell 5.1 and PowerShell 7. Policy/transaction/controller/snapshot/entry tests mock Windows network calls. Socket tests use local DNS/TLS peers without adapter or certificate-store changes. WPF tests exercise actual controls, command queues, hide/reopen and scrolling.

Only fixed DNS/HTTPS health requests are sent. Local status, events, preferences and backups contain adapter names, addresses/GUIDs and must not be committed. Platform TLS validation may independently retrieve certificate metadata. No browsing history collection or analytics.
