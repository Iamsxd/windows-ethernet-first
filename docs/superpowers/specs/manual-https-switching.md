# Manual switching and HTTPS health

Extend the upstream PowerShell/C# application, retaining MIT attribution and Windows PowerShell 5.1 compatibility. No Python runtime, driver, network adapter disabling, DNS changes or router changes.

- Default is monitor only. Tray actions select wired or Wi-Fi, toggle automatic failover, check now, restore original settings, and exit. Manual preference disables auto. Auto is explicitly enabled, never silently persisted across restarts.
- Manage one physical wired and one physical Wi-Fi adapter, identified by GUID. Ambiguous selection must refuse modification. Never modify virtual adapters or VPN configuration.
- Probe two HTTPS 204 endpoints through the tested interface, including DNS, strict TLS and expected HTTP status. No system proxy or cross-interface DNS fallback. Unknown/local permission failures cannot trigger failover.
- Auto: three consecutive failed rounds on current connection, two consecutive successful rounds on alternate; 180 second cooldown; no automatic failback; refuse ambiguous or split IPv4/IPv6 defaults. Changing default metrics cannot move existing sockets or override more-specific VPN routes.
- Preserve the first baseline by GUID until successful restore. Save operation rollback state before writes, resolve current indexes by GUID, verify writes, roll back partial failures. External metric changes pause automatic control. Ask explicitly in the UI before overwriting externally changed metrics on restore.
- Logs remain local, contain no credentials or browsing history. No automatic installation or startup task is enabled as part of development verification.

This replaces the earlier standalone Python/Tk implementation proposal; its approved user-facing behavior is retained.
