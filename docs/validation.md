# Validation

Validated on Windows, 2026-11-13.

- Windows PowerShell 5.1 and PowerShell 7: full `tests/Run-All.ps1` passed, 222 assertions per runtime.
- The elevated CLI recovery fixture is conditional: the development process was not elevated. Windows CI runs this additional fixture when its token is administrator.
- A real read-only snapshot verified trusted HTTPS independently through wired and Wi-Fi. A native tray process completed consecutive rounds in Monitor mode without changing interface metrics. The validation process was stopped afterward.
- An independent whole-branch review found problems with stale sampling, interrupted restore ownership, local binding errors and persistence. Regression tests reproduce these failures; fixes passed the full suite.
- Persistence tests include denied replacement and concurrent readers, using actual temporary files. State writes flush before a same-directory native Windows rename; unchanged baselines are not rewritten.
- Network mutation, interrupted mutation and external-change tests use mocked Windows calls. Actual manual metric switching, administrator installation/uninstallation, cable-side packet capture and physical power-loss recovery were not exercised on the development machine.

No real network changes, scheduled task, startup entry, certificate-store change or router configuration change was made for validation. These results do not guarantee every website is reachable or that shared upstream failures can be solved by changing interfaces.
