# Win11 GameBoost

Windows 11 gaming optimization with a simple UI, safe defaults, competitive mode, reports and rollback.

`ltsc-setup` started as a Windows 11 LTSC bootstrap script. It is now a small product: a PowerShell/WPF optimizer for Windows 11 PCs used for gaming, including LTSC machines that need WinGet and gaming packages restored.

## What It Looks Like

```
WIN11 GAMEBOOST
Gaming optimization for Windows 11

[ Safe Performance ]      Analyze PC
[ Competitive      ]      Optimize Now
                         Restore Backup

Power: Planned    GPU: Planned    Noise: Planned
```

The UI is intentionally simple: choose one profile, analyze, optimize, restore if needed. No wall of mystery checkboxes.

## Profiles

| Profile | Use it when | What it does |
| --- | --- | --- |
| Safe Performance | Default for almost everyone | Enables gaming-oriented Windows settings, power tuning, background capture reduction, GPU scheduling request, MMCSS games profile and gaming packages. |
| Competitive | Opt-in for leaner gaming sessions | Includes Safe Performance plus reversible background-noise reductions and SysMain set to manual. |

Safe Performance is designed to stay compatible with Microsoft Store, Game Pass, Windows Update, Defender, Firewall and anticheats. Competitive is still reversible, but it is more opinionated.

## Quick Start

Open PowerShell as Administrator:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\GameBoost.ps1
```

Headless mode:

```powershell
.\GameBoost.ps1 -Profile Safe -Mode Analyze -NoUi
.\GameBoost.ps1 -Profile Safe -Mode Apply -NoUi
.\GameBoost.ps1 -Profile Competitive -Mode Apply -NoUi
```

The old entry point still works:

```powershell
.\setup.ps1 -Profile Safe -Mode Apply -NoUi
```

For compatibility, `.\setup.ps1` is headless by default and can fetch `GameBoost.ps1` if someone still runs the old one-file bootstrap path. Use `.\setup.ps1 -Ui` only when you explicitly want the visual launcher through the old file name.

## Restore

Every apply run creates a backup under:

```text
%ProgramData%\Win11GameBoost\Backups
```

Restore from the UI or CLI:

```powershell
.\GameBoost.ps1 -Mode Restore -BackupPath "C:\ProgramData\Win11GameBoost\Backups\20260505-201500-Safe" -NoUi
```

Reports are written to:

```text
%ProgramData%\Win11GameBoost\Reports
```

## Optimization Matrix

| Area | Safe | Competitive | Notes |
| --- | --- | --- | --- |
| Game Mode | Yes | Yes | Enables Windows Game Mode for the current user. |
| Background recording | Yes | Yes | Disables GameDVR background capture. |
| Power plan | Yes | Yes | Activates Ultimate Performance when available, with High Performance fallback. |
| Multimedia scheduling | Yes | Yes | Tunes the Windows Games MMCSS profile. Reboot recommended. |
| HAGS | Yes | Yes | Requests hardware-accelerated GPU scheduling. Driver support still decides behavior. |
| Packages | Yes | Yes | Installs gaming essentials with WinGet when available. Xbox/Game Pass dependencies remain managed by Microsoft Store/Xbox App. |
| Consumer suggestions | No | Yes | Reduces Windows suggestions and widget noise for the current user. |
| SysMain | No | Yes | Stops SysMain and sets it to Manual. Useful on some gaming rigs, not universal. |

## What It Does Not Do

Win11 GameBoost does not disable Defender, Firewall, Windows Update, Core Isolation/VBS, Secure Boot, TPM, anticheat services or driver security features automatically. Those choices can affect security, game compatibility and system support too much to hide behind a shiny button.

## LTSC Notes

Windows 11 LTSC can miss pieces that normal Windows 11 installs already have. `packages.dsc.yaml` keeps the package baseline separate and repeatable through WinGet Configuration/DSC. If WinGet is missing, Apply mode attempts the same App Installer bootstrap path this repo originally used for LTSC, then runs `wsreset.exe -i` so Microsoft Store packages such as Xbox can resolve through `msstore`. If that fails, install Microsoft App Installer/Microsoft Store manually and run GameBoost again.

Apply the package baseline manually:

```powershell
winget configure -f .\packages.dsc.yaml --accept-configuration-agreements --accept-source-agreements
```

## Files

| File | Purpose |
| --- | --- |
| `GameBoost.ps1` | Main UI, CLI, tweak engine, backup, restore and reporting. |
| `setup.ps1` | Compatibility wrapper for the old project entry point. |
| `packages.dsc.yaml` | WinGet Configuration package baseline. |

## Safety Model

- Analyze mode does not apply changes.
- Apply mode requires Administrator for system-level optimizations.
- Registry paths touched by the selected profile are exported before changes.
- A Windows restore point is attempted when System Restore allows it.
- Reports list every applied, skipped or failed item.
- Competitive mode is opt-in.

## Official Windows Features Used

- WinGet Configuration / DSC: https://learn.microsoft.com/windows/package-manager/configuration/
- Optimizations for windowed games: https://support.microsoft.com/windows/optimizations-for-windowed-games-in-windows-11-3f006843-2c7e-4ed0-9a5e-f9389e535952
- Auto HDR: https://support.microsoft.com/windows/use-auto-hdr-for-better-gaming-in-windows-0cce8402-3de5-4512-a742-e027ca7aa79c
- Power mode: https://support.microsoft.com/windows/change-the-power-mode-for-your-windows-pc-c2aff038-22c9-f46d-5ca0-78696fdf2de8

## License

MIT.
