# ApexPulse 11 Backend and Tweak Review

This review documents how the current backend works, how each tweak is classified, and which improvements would make the optimizer safer, more explainable, and easier to evolve.

## Backend architecture

`ApexPulse.ps1` is both the backend engine and the WPF frontend. The engine is structured into functional regions:

| Area | Responsibility |
| --- | --- |
| Configuration | Product metadata plus `%ProgramData%\ApexPulse11` storage roots for backups, reports, and logs. |
| Core utilities | Logging, storage initialization, Windows/admin detection, and host state capture. |
| Registry helpers | Registry path conversion, safe reads/writes, value state capture, and per-value rollback metadata. |
| Backup and restore | Registry exports, registry value snapshots, service snapshots, package snapshots, active power scheme capture, restore point attempt, and manifest writing. |
| System helpers | Power plan, service, package, WinGet, and Store/LTSC bootstrap operations. |
| Tweak catalog | `Get-ApexPulseTweaks` returns the registry/service tweak objects used by both CLI and UI. |
| Package set | `Get-ApexPulsePackageSet` defines WinGet/MS Store package baselines. |
| Profile execution | `Invoke-ApexPulseProfile` filters tweaks by profile, optionally creates a backup, detects/applies tweaks, runs packages, and writes reports. |
| Reports | JSON and HTML report generation plus CLI summary output. |
| UI | WPF XAML and event handlers that call the same engine functions as the CLI. |

### Execution flow

```text
CLI parameters or WPF button
  -> selected Profile: Safe or Competitive
  -> selected Mode: Analyze, Apply, or Restore
  -> Restore:
       Restore-ApexPulseBackup
  -> Analyze/Apply:
       Invoke-ApexPulseProfile
         -> Assert Windows and initialize storage
         -> Load Get-ApexPulseTweaks
         -> Filter where tweak.Profiles contains selected profile
         -> Apply mode only: require admin and create New-ApexPulseBackup
         -> For each tweak:
              Analyze/WhatIf: run Detect scriptblock
              Apply: run Apply scriptblock
         -> Invoke-ApexPulsePackages
         -> Update backup package snapshots after package install attempts
         -> Write JSON and HTML reports
```

The UI mostly delegates correctly to backend functions. The notable exception is the standalone Privacy Shield panel, which reimplements a mini apply loop instead of calling `Invoke-ApexPulseProfile`; this keeps the UX flexible for checkboxes but duplicates reporting/result construction.

## Rollback model

Rollback coverage is stronger than a simple registry export:

1. Exports every declared registry path for the selected tweaks.
2. Captures individual registry value state for declared values, including missing-before-apply values.
3. Captures selected service startup modes and running states.
4. Captures the active power scheme GUID.
5. Captures package installation state, then removes only packages that were not present before apply when possible.
6. Attempts a Windows restore point when elevated.

Recommended improvement: include tweak metadata in the manifest so future rollback/report tooling can explain why each target was changed, not just what changed.

## Current tweak inventory

| ID | Profile | Area | Targets | Admin | Reboot | Review |
| --- | --- | --- | --- | --- | --- | --- |
| `gaming.game-mode` | Safe + Competitive | Gaming | HKCU GameBar values | No | No | Keep in Safe. Low risk, user-scoped, aligns with Windows gaming feature. Detection should check both values, not just `AutoGameModeEnabled`. |
| `capture.disable-gamedvr` | Safe + Competitive | Background Noise | HKCU GameDVR/GameConfigStore values | No | No | Keep in Safe. Good low-risk gaming tweak for unwanted capture overhead. Detection should check all written values. |
| `power.high-performance` | Safe + Competitive | Power | Active power scheme | Yes | No | Keep, but label as power/battery tradeoff. Detection currently always says it will activate a plan if any active plan exists; improve by detecting Ultimate/High Performance already active. |
| `power.disable-throttling` | Safe + Competitive | Power | HKLM PowerThrottling | Yes | No | Keep in Safe for desktops/gaming rigs. Add clearer laptop/battery caveat in docs/UI. |
| `multimedia.games-priority` | Safe + Competitive | Latency | HKLM MMCSS SystemProfile and Games task | Yes | Yes | Keep but mark as driver/game dependent. Detection should verify all MMCSS values. |
| `capture.fullscreen-exclusive` | Safe + Competitive | Latency | HKCU GameConfigStore FSE values | No | No | Keep with caveat. Windows 11 windowed optimizations make this less universal; make language “prefer” rather than promise. |
| `gaming.disable-overlay` | Safe + Competitive | Latency | HKCU GameBar values | No | No | Keep in Safe, but clarify it disables overlay convenience features. Detection should check both values. |
| `gpu.hags` | Safe + Competitive | GPU | HKLM GraphicsDrivers `HwSchMode` | Yes | Yes | Consider moving to an optional/advanced toggle or explicitly mark hardware dependent. Benefit varies by GPU, driver, and game. |
| `explorer.reduce-consumer-content` | Competitive | Background Noise | HKCU ContentDeliveryManager and Explorer values | No | No | Keep in Competitive. It is privacy/noise oriented, not raw performance. Detection should verify representative values. |
| `visual.reduce-effects` | Competitive | Background Noise | HKCU visual effect values | No | No | Consider optional within Competitive. Performance benefit is small on modern GPUs and UX impact is noticeable. |
| `notifications.suppress-toasts` | Competitive | Background Noise | HKCU PushNotifications and HKCU policy path | No | No | Keep as opt-in. It can hide useful notifications, so avoid Safe. Consider a gaming-session-only approach in future. |
| `services.sysmain` | Competitive | Services | SysMain service state/startup | Yes | No | Reconsider default Competitive inclusion. On SSD systems, disabling SysMain can be neutral or harmful. Better as Advanced/Legacy HDD toggle. |
| `services.wsearch` | Competitive | Services | WSearch service state/startup | Yes | No | Reconsider default Competitive inclusion. Disabling indexing can hurt Start/search UX and does not always improve gaming. Better as optional. |
| `services.diagtrack` | Competitive | Services/Privacy | DiagTrack service state/startup | Yes | No | Keep only under Privacy/Advanced with compatibility caveat. It is a privacy choice more than a performance tweak. |
| `privacy.tailored-experiences` | Competitive | Privacy | HKCU Privacy value | No | No | Keep in Competitive and Privacy Shield. Low risk and user-scoped. |
| `privacy.diagnostic-data` | Competitive | Privacy | HKLM DataCollection policy/current values | Yes | No | Keep but document Windows edition behavior; security-only telemetry may not be honored on all editions. |
| `privacy.cortana-search` | Competitive | Privacy | HKCU Search and HKLM Windows Search policy values | Yes | No | Keep as privacy/noise toggle. README says no admin is required, but the code writes HKLM policy values, so docs should say admin required. |
| `privacy.location-tracking` | Competitive | Privacy | HKLM/HKCU location consent values | Yes | No | Keep as opt-in privacy hardening. Document impact on weather, maps, device location, and apps. |
| `privacy.activity-history` | Competitive | Privacy | HKLM Windows System policy values | Yes | No | Keep. Low gaming risk, privacy oriented. |

## Package baseline review

Packages are valuable for LTSC gaming setup, but they are not the same as OS optimization:

| Package | Current profile | Review |
| --- | --- | --- |
| Steam | Safe | Reasonable gaming baseline, but still a software install side effect. |
| Xbox App | Safe | Important for Game Pass/LTSC, but depends on Store infrastructure. |
| Discord | Safe | Useful gaming companion, not required for performance. |
| 7-Zip | Safe | General utility, not gaming-specific. Consider moving to package baseline docs rather than Safe optimization. |
| Epic Games Launcher | Competitive | Package choice does not match “competitive” semantics; this is a launcher preference, not a riskier optimization. |
| GOG Galaxy | Competitive | Same concern as Epic. |

Recommendation: keep package automation, but separate it as a `Packages` step or optional setup baseline instead of treating package installs as Safe/Competitive optimizations. The existing `packages.dsc.yaml` already supports that separation.

## Safe vs Competitive assessment

Two modes are a good top-level UX choice. They make the tool approachable and preserve the current message: safe by default, aggressive by choice.

However, two modes are too coarse for the backend. The current `Profiles` array answers only “which preset includes this?” It does not encode why a tweak belongs there, how risky it is, what it affects, or how strong the evidence is.

Recommended model:

1. Keep `Safe` and `Competitive` as curated presets.
2. Add tweak metadata:
   - `Risk`: Low, Medium, High
   - `Impact`: Gaming, Latency, Privacy, Noise, Packages, UX, Power
   - `Evidence`: WindowsFeature, MicrosoftPolicy, HardwareDependent, CommunityTuning, Convenience
   - `Compatibility`: Store, GamePass, Search, Notifications, LaptopBattery, Anticheat, DriverDependent
   - `Default`: Safe, Competitive, Advanced, or Optional
3. Use metadata in reports and UI details before changing behavior.
4. Later, expose Advanced/category toggles without breaking the simple preset UX.

This lets ApexPulse stay simple for normal users while giving advanced users and maintainers a more defensible model.

## Recommended implementation backlog

### Quick wins

1. Fix README admin requirement for Cortana/cloud search.
2. Add backend/tweak documentation and link it from README.
3. Add metadata fields to tweak objects without changing behavior.
4. Include metadata in JSON/HTML reports.
5. Improve detection for multi-value tweaks so “Ready” means all relevant values are configured.

### Medium changes

1. Refactor Privacy Shield apply to reuse a shared execution helper instead of duplicating profile execution logic.
2. Separate package baseline execution from profile optimization, or add a UI/package-only choice.
3. Add a manifest section recording selected tweak IDs and metadata.
4. Add tests or script checks that enumerate all tweaks and validate required fields.

### Larger product decisions

1. Move SysMain and Windows Search to Advanced or optional Competitive toggles.
2. Decide whether HAGS should remain Safe or become an optional hardware-dependent tweak.
3. Add a Custom/Advanced mode backed by metadata, not hard-coded profile-only logic.
4. Consider session-oriented toggles for notifications/services, where settings can be restored after gaming.

## Current recommendation

Keep two modes for the main product. Do not delete Safe/Competitive. Instead, make the backend richer:

- Safe: low-risk gaming defaults with strong compatibility.
- Competitive: opt-in privacy/noise reduction with clear UX tradeoffs.
- Advanced metadata: explains risk and enables future custom toggles.

The most questionable current defaults are service changes (`SysMain`, `WSearch`) and package installs being bundled into optimization profiles. Those should be reviewed before adding more aggressive tweaks.
