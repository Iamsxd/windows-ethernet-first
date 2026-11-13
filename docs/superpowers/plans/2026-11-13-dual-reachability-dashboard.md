# Dual reachability dashboard implementation plan

> **For agentic workers:** Use superpowers:executing-plans; tests precede behavior changes.

**Goal:** Deliver independent domestic/foreign health and a usable native dashboard in the existing fork.

**Architecture:** Probe.cs runs two bounded profiles; Core.ps1 captures independent health and adapter inventory; Switching.ps1 keeps its transaction boundary and adds opt-in return policy; Controller.ps1 owns preferences and commands; Dashboard.xaml/ps1 present state without writing network settings.

**Tech Stack:** PowerShell 5.1/7, C#, WPF, existing WinForms tray. No external runtime.

**Spec:** ../specs/2026-11-13-dual-reachability-dashboard.md

## Global Constraints

- Monitor and return-to-wired are off by default; never persist active Auto mode.
- Only selected physical interface metrics may change; preserve all existing recovery checks.
- Distinct endpoint profiles retain strict TLS, bounded time and interface-bound DNS.
- All metric changes remain on the serialized controller thread, never UI event handlers.

## Review Focus

1. Foreign-only failure must not masquerade as complete link failure.
2. Missing/unknown IPv6 and endpoint/profile changes must not reuse stale streaks.
3. Return-to-wired must retain Auto topology/ownership preconditions, cooldown and both-profile evidence.
4. Window close/reopen, settings changes during a worker, non-admin actions and restore must not bypass serialization.
5. WPF must render and remain usable at smaller sizes, with actual actions wired through the real queue.

## Task 1: Independent probes and snapshot health

Files: src/Probe.cs, src/Core.ps1, src/Controller.ps1, config.json; probe/snapshot/config tests.
- [x] Add failing tests for independent profile results, bounded concurrent profiles, missing evidence and config validation.
- [x] Implement CheckProfiles and per-profile streaks, preserve primary domestic aliases and adapter inventory.
- [x] Run focused tests and full suite, expect PASS.

## Task 2: Domestic failover and optional wired recovery

Files: src/Switching.ps1, src/Controller.ps1; switching/controller tests.
- [x] RED: foreign-only outage does not switch; complete domestic failure can use domestic-only backup; return off/on, cooldown, dual-stack and unknown coverage.
- [x] Implement policy and local preferences, retaining transaction metadata and restore behavior.
- [x] Run focused tests and full suite, expect PASS.

## Task 3: WPF dashboard and integration

Files: src/Dashboard.xaml, src/Dashboard.ps1, src/DashboardModel.ps1, EthernetFirst.ps1, launch/install files; model/UI integration tests.
- [x] RED: model states, selected route, settings/command queue and UI control actions.
- [x] Build the visible dashboard and tray reopening, connect controls to the existing generation-aware queue.
- [x] Verify actual window visually and exercise safe controls without changing real metrics.
- [ ] Run full PS5.1/7 suite, inspect changes independently, publish to fork and package portable source.
