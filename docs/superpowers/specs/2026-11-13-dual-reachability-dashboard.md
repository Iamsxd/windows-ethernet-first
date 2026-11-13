# Domestic/foreign reachability and desktop dashboard

The user approved separate domestic/foreign health, domestic fallback and an attractive usable desktop UI. Extend the existing PowerShell/C# application with a native WPF window and retain the tray. No browser service, runtime installation, router changes or automatic startup setup.

- Two independent HTTPS 204 profiles per physical interface/family. Domestic defaults: Huawei and vivo; foreign defaults: gstatic and Google. Each profile succeeds when either configured endpoint succeeds. A label describes these test sites, not every site in a country.
- Each profile has independent two-good/three-bad streaks; reconnect, changed identity/endpoints, absent or unknown results reset evidence. Probe both profiles concurrently with the same per-link timeout; bounded non-overlapping rounds and strict TLS/interface-bound DNS remain.
- Normal auto failover uses domestic health. Foreign-only failure leaves the current path in place. If current domestic fails three rounds and backup domestic succeeds two rounds, switch both active families after existing checks/cooldown. Do not change VPN defaults.
- A separate return-to-wired preference is off by default. With auto enabled, it may return from Wi-Fi once wired domestic AND foreign succeed twice in every active family, after the cooldown. No return solely because a cable reappears.
- New dashboard: current default route/operating mode, wired and Wi-Fi cards with domestic/foreign states, adapter selection, manual preference buttons, check now, auto toggle, return preference, restore and recent actions. Closing the window minimizes to tray; explicit Exit retains metrics. Start visible for portable launch; installed startup stays in tray.
- One controller owns writes. UI actions only enqueue commands; generation invalidation and deferred restore remain. Startup remains Monitor. User preferences may remember adapter selection and return preference, never active Auto mode.
- Use native WPF, readable Chinese typography, blue/navy accents, calm light surfaces, meaningful status colors plus text, keyboard focus and scaling/scrolling for smaller screens.
- Preserve legacy endpoint config and command-line compatibility, original GUID baseline and transactional recovery. No real network mutation during development verification.

Approach selected by the implementer: WPF XAML plus the existing PowerShell controller. Retaining only a tray popup would underserve the requested UI; a web/Electron app would add unnecessary services/dependencies.
