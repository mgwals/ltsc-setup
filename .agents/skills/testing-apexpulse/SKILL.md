---
name: testing-apexpulse
description: Test the ApexPulse 11 WPF GUI and CLI end-to-end. Use when verifying UI, privacy tweaks, rollback, or CLI changes.
---

# Testing ApexPulse 11

## Environment Requirements

- **OS:** Windows 10/11 or Windows Server 2022+ with Desktop Experience
- **PowerShell:** 5.1+ (ships with Windows)
- **WPF:** PresentationFramework assembly must be available (verify with `Add-Type -AssemblyName PresentationFramework`)
- **Admin:** Run as Administrator for full testing (some privacy tweaks and backup/restore require elevation)
- No external secrets or credentials needed — this is a local system optimization tool

## Devin Secrets Needed

None. This is a fully local tool with no external service dependencies.

## How to Launch

### GUI Mode
```powershell
# Launch the WPF GUI (default mode)
Start-Process powershell -ArgumentList '-NoExit', '-Command', '& "path\to\ApexPulse.ps1"' -WindowStyle Maximized
```

### Headless CLI Mode
```powershell
# Analyze without modifying system (safe for testing)
.\ApexPulse.ps1 -Profile Safe -Mode Analyze -NoUi
.\ApexPulse.ps1 -Profile Competitive -Mode Analyze -NoUi

# Apply optimizations (modifies registry — creates backup first)
.\ApexPulse.ps1 -Profile Competitive -Mode Apply -NoUi
```

### Legacy Entry Points
```powershell
# Both forward to ApexPulse.ps1
.\setup.ps1 -Profile Safe -Mode Analyze -NoUi
.\GameBoost.ps1 -Profile Safe -Mode Analyze -NoUi
```

## UI Navigation

The WPF GUI has a sidebar with 3 navigation buttons:
1. **Dashboard** (default) — Profile radio buttons (Safe/Competitive), Analyze PC button, Optimize Now button, 5 status cards, output console
2. **Privacy Shield** — 5 checkboxes for privacy tweaks, Scan Privacy button, Apply Privacy Shield button, output console
3. **Rollback Center** — Backup list, backup detail pane, Refresh button, Restore Selected Backup button

## Key Test Flows

### 1. Safe vs Competitive Profile Differentiation
- Safe profile: 8 gaming tweaks, Privacy card = "N/A", no privacy items in output
- Competitive profile: Same 8 gaming tweaks + competitive extras + 5 privacy tweaks, Privacy card = "Planned"
- **Adversarial check:** If privacy items appear in Safe output, profile filtering is broken

### 2. Privacy Shield Apply
- Click Privacy Shield in sidebar
- All 5 checkboxes should be checked by default
- Click "Apply Privacy Shield"
- Expect: Backup path shown, all 5 tweaks show [Applied]
- Backup directory created under `%ProgramData%\ApexPulse11\Backups\`

### 3. Rollback Center Restore
- Click Rollback Center in sidebar
- Select a backup from the list
- Verify manifest details appear (Product, Profile, Created, Computer, OS, Registry exports count)
- Click "Restore Selected Backup"
- Expect: All entries show [Restored], [Removed], or [Skipped] — zero [Failed]

### 4. HTML Report Verification
- After any CLI run, check `%ProgramData%\ApexPulse11\Reports\` for HTML files
- HTML should have dark theme CSS, "ApexPulse 11" title, styled table with status classes

## Known Gotchas

- **PowerShell `&&` operator:** Does not work in Windows PowerShell 5.1. Use `;` to chain commands instead.
- **PowerShell multiline commit messages:** Avoid dashes in multiline strings — PowerShell interprets them as subtraction operators. Use single-line messages.
- **reg.exe stderr:** `reg.exe import` writes success messages to stderr. If `$ErrorActionPreference` is not `SilentlyContinue`, PowerShell's `2>&1` redirect captures stderr as ErrorRecords that can trigger catch blocks. The code now handles this, but watch for similar patterns with other external executables.
- **winget not available:** On Windows Server or LTSC, winget might not be installed. Package-related tweaks will show [Skipped] — this is expected behavior, not a bug.
- **Restore points:** System Restore Points might not be available on Windows Server. The manifest will show "Restore point: No" — this is expected.
- **WPF on Server:** WPF works on Windows Server 2022 with Desktop Experience but the window might need to be launched via `Start-Process` to get a proper interactive session.

## CI/CD

- PSScriptAnalyzer lint runs on every PR (`release.yml`)
- Tagged releases (`v*`) trigger a zip build
- Warnings are non-blocking (PSUseSingularNouns, PSAvoidWriteHost, etc. are style conventions)
