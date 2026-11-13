# Manual switching and HTTPS implementation plan

> **For agentic workers:** Use superpowers:executing-plans with independent component implementers. Tests precede production changes.

**Goal:** Deliver the user's fork with manual wired/Wi-Fi selection and optional HTTPS-based automatic failover.

**Architecture:** Retain upstream Core.ps1, Probe.cs and the WinForms tray. Isolate pure switching policy and metric transactions in Switching.ps1; use the entry script as the single writer and serialized UI loop.

**Tech Stack:** Windows PowerShell 5.1 / PowerShell 7, .NET Framework sockets and WinForms; no additional modules.

**Spec:** ../specs/manual-https-switching.md

## Global Constraints

- Monitor only by default; auto requires explicit opt-in on every process start.
- Only selected physical wired/Wi-Fi metrics may change. Leave VPN/IP/DNS/router configuration alone.
- GUID baseline survives until restore; partial changes must roll back.
- TLS validation remains enabled; actual HTTP 204 is required.

## Review Focus

1. Same-subnet wired and Wi-Fi must really probe different interfaces, not merely bind different source addresses.
2. DNS packet spoofing/truncation/compression, stalled TLS and captive portals must never report success.
3. IPv6, equal metrics and multiple physical adapters must refuse unsafe automatic changes.
4. Mid-operation failure, disconnected adapters and external metric edits must not lose the baseline or clobber changes silently.
5. Tray actions and restore must serialize with the worker; startup must not unexpectedly enable auto.

## Task 1: Interface-bound HTTPS probe

Files: src/Probe.cs; tests/Test-Probe.ps1.
Interface: CheckHttps(int index, string source, string[] dnsServers, string[] endpoints, int timeoutMs) -> 1 success / 0 failure / -1 unknown.
- [x] Add deterministic DNS/HTTP/TLS/deadline tests, run and observe RED.
- [x] Implement bounded, per-interface DNS/TLS/HTTPS with strict validation.
- [x] Run Test-Probe.ps1 and upstream Test-Core.ps1; expected PASS.

## Task 2: Switching policy and reversible metric changes

Files: src/Switching.ps1; tests/Test-Switching.ps1.
Interfaces: Get-SwitchDecision(Links, Mode, ManagedGuids, LastSwitch, Now, CooldownSeconds); Set-SwitchPlan(Plan, BackupPath, ExpectedPath); Test-ManagedMetrics(ExpectedPath); Restore-SwitchMetrics(BackupPath, ExpectedPath, Force).
Links carry GUID, family, current metrics, Kind, Hardware, Good/Bad streaks. Decisions carry Plan, Reason, TargetGuid.
- [x] Add tests for manual selection, cooldown, unknown health, split stack, external edits, failure rollback and durable baseline; observe RED.
- [x] Implement pure policy and transactional OS boundary.
- [x] Run Test-Switching.ps1 and Test-Core.ps1; expected PASS.

## Task 3: Snapshot, tray, launch and documentation integration

Files: src/Core.ps1; EthernetFirst.ps1; src/Controller.ps1; start.bat; Start-EthernetFirst.ps1; install.ps1; config.json; README.zh-CN.md; CI and tests.
Consumes Task 1 CheckHttps and Task 2 exact interfaces.
- [x] Add snapshot/controller tests before implementation; observe RED.
- [x] Add DNS-bound snapshots, Chinese tray menus, optional auto, restore confirmation, responsive serialized loop and opt-in UAC launcher.
- [x] Installed startup also defaults to monitor; retain upstream uninstall compatibility.
- [x] Run all tests under PowerShell 5.1 and 7 and read-only real-machine snapshot; expected PASS with no metric changes.
- [x] Fresh independent review, reproduce/fix important findings, rerun full suite.
- [x] Commit and publish to the Iamsxd fork (main and development branch); do not send upstream PR.
