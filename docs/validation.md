# Validation

Validated on Windows, 2026-11-13.

- Full Windows PowerShell 5.1 and PowerShell 7 suites: 300 assertions per runtime. The additional elevated CLI recovery fixture runs when the token is administrator (covered by Windows CI); the development process was not elevated.
- Probe tests cover independent profile results, strict TLS, interface binding, bounded concurrent profiles and DNS validation. Snapshot/policy/controller tests cover independent streaks, endpoint identity reset, unknown protocols, domestic-only fallback, foreign-only failure, opt-in recovery, cooldown and preference persistence without active Auto mode.
- WPF tests exercise actual buttons/toggles, serialized command requests, friendly adapter names, unsaved-selection labels and disabled actions, hide/reopen, hidden-render suppression, and fit/stack/scroll at an injected 800 by 500 work area. The README image uses fictional connection data.
- A native WPF validation host ran the real entry/controller in Monitor with an isolated fixture mutex. Wired domestic and foreign profiles reached 9+ good rounds; disconnected Wi-Fi remained visible. Check/settings navigation and closing to the tray were exercised. The process continued after closing the window, and real interface metrics were exactly equal before/after. The validation instance was then stopped without stopping the user's controller.
- Final independent review findings were fixed with regressions for installed-candidate selection, case-sensitive SSIDs/HTTP paths, staged selections, scaled desktops and actual outcome history. A two-peer hanging TLS test directly verifies concurrent profile deadlines and both connection closures.
- Entry fixtures use a copied entry with only a unique mutex name substituted, and mocked OS network boundaries. The production machine-wide single-writer lock is unchanged.
- Persistence tests include denied replacement and concurrent readers using actual temporary files. GUID baseline, ownership checks, deferred restore and transactional rollback regressions remain covered.
- Actual metric writes, administrator installation/uninstallation, cable-side capture, Wi-Fi failover and physical power-loss recovery were not exercised on the development machine. These platform interactions still need user-operated acceptance.

No real network settings, scheduled task, startup entry, certificate store or router configuration was changed for validation. Passing configured health endpoints does not guarantee every website is reachable.