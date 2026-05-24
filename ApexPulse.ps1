<#
.SYNOPSIS
    ApexPulse 11 optimizes Windows 11 for gaming with profiles, privacy shield, reports and rollback.

.DESCRIPTION
    Run without parameters for the WPF interface. Use -NoUi for automation:
      .\ApexPulse.ps1 -Profile Safe -Mode Analyze -NoUi
      .\ApexPulse.ps1 -Profile Safe -Mode Apply -NoUi
      .\ApexPulse.ps1 -Profile Competitive -Mode Apply -NoUi
      .\ApexPulse.ps1 -Mode Restore -BackupPath "C:\ProgramData\ApexPulse11\Backups\..." -NoUi
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet("Safe", "Competitive")]
    [string]$Profile = "Safe",

    [ValidateSet("Analyze", "Apply", "Restore")]
    [string]$Mode = "Analyze",

    [switch]$NoUi,

    [string]$BackupPath,

    [string]$ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
#region Configuration
# ---------------------------------------------------------------------------

$script:ProductName = "ApexPulse 11"
$script:ProductVersion = "2.0.0"
$script:IsWindows = $PSVersionTable.PSVersion -and $env:OS -eq "Windows_NT"
$script:DataRoot = if ($script:IsWindows -and $env:ProgramData) {
    Join-Path $env:ProgramData "ApexPulse11"
} else {
    Join-Path $PSScriptRoot ".apexpulse"
}
$script:BackupRoot = Join-Path $script:DataRoot "Backups"
$script:ReportRoot = Join-Path $script:DataRoot "Reports"
$script:LogRoot = Join-Path $script:DataRoot "Logs"

#endregion

# ---------------------------------------------------------------------------
#region Core Utilities
# ---------------------------------------------------------------------------

function Write-ApexPulseLog {
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet("Info", "Warn", "Error", "Success")]
        [string]$Level = "Info"
    )

    $prefix = "[{0}] [{1}]" -f (Get-Date -Format "HH:mm:ss"), $Level.ToUpperInvariant()
    $color = switch ($Level) {
        "Warn" { "Yellow" }
        "Error" { "Red" }
        "Success" { "Green" }
        default { "Cyan" }
    }

    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Initialize-ApexPulseStorage {
    foreach ($path in @($script:DataRoot, $script:BackupRoot, $script:ReportRoot, $script:LogRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Test-ApexPulseAdmin {
    if (-not $script:IsWindows) {
        return $false
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-ApexPulseWindows {
    if (-not $script:IsWindows) {
        throw "$script:ProductName only applies to Windows. This host can be used to edit the repo, but not to optimize the OS."
    }
}

function Get-ApexPulseComputerState {
    $admin = Test-ApexPulseAdmin
    $osCaption = "Unknown"
    $osBuild = "Unknown"

    if ($script:IsWindows) {
        try {
            $os = Get-CimInstance -ClassName Win32_OperatingSystem
            $osCaption = $os.Caption
            $osBuild = $os.BuildNumber
        } catch {
            $osCaption = [System.Environment]::OSVersion.VersionString
        }
    }

    [pscustomobject]@{
        Product = $script:ProductName
        Version = $script:ProductVersion
        ComputerName = $env:COMPUTERNAME
        UserName = $env:USERNAME
        IsWindows = $script:IsWindows
        IsAdmin = $admin
        OSCaption = $osCaption
        OSBuild = $osBuild
        Timestamp = (Get-Date).ToString("o")
    }
}

#endregion

# ---------------------------------------------------------------------------
#region Registry Helpers
# ---------------------------------------------------------------------------

function ConvertTo-RegistryCliPath {
    param([Parameter(Mandatory)][string]$Path)

    if ($Path -like "HKCU:\*") {
        return $Path -replace "^HKCU:\\", "HKCU\"
    }
    if ($Path -like "HKLM:\*") {
        return $Path -replace "^HKLM:\\", "HKLM\"
    }
    return $Path
}

function Get-RegistryValueSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $null
    }

    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $null
    }

    return $property.Value
}

function Get-RegistryValueState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    $state = [ordered]@{
        Path = $Path
        Name = $Name
        KeyExists = $false
        Exists = $false
        Value = $null
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]$state
    }

    $state.KeyExists = $true
    $item = Get-ItemProperty -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return [pscustomobject]$state
    }

    $property = $item.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return [pscustomobject]$state
    }

    $state.Exists = $true
    $state.Value = $property.Value
    return [pscustomobject]$state
}

function Set-RegistryValueSafe {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Value,
        [Microsoft.Win32.RegistryValueKind]$Type = [Microsoft.Win32.RegistryValueKind]::DWord
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }

    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
}

function Get-ApexPulseRegistryValueRefs {
    param([Parameter(Mandatory)][array]$Tweaks)

    $refs = @()
    foreach ($tweak in $Tweaks) {
        if ($tweak.PSObject.Properties.Name -notcontains "RegistryValues") {
            continue
        }

        foreach ($valueRef in $tweak.RegistryValues) {
            if (-not $valueRef) {
                continue
            }

            $refs += [pscustomobject]@{
                Path = $valueRef.Path
                Name = $valueRef.Name
            }
        }
    }

    $refs | Sort-Object Path, Name -Unique
}

#endregion

# ---------------------------------------------------------------------------
#region Backup & Restore
# ---------------------------------------------------------------------------

function New-ApexPulseBackup {
    param(
        [Parameter(Mandatory)]
        [array]$Tweaks,

        [Parameter(Mandatory)]
        [string]$SelectedProfile
    )

    Assert-ApexPulseWindows
    Initialize-ApexPulseStorage

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $backupDir = Join-Path $script:BackupRoot "$stamp-$SelectedProfile"
    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    $registryPaths = $Tweaks |
        ForEach-Object { $_.RegistryPaths } |
        Where-Object { $_ } |
        Select-Object -Unique

    $registryExports = @()
    foreach ($path in $registryPaths) {
        $safeName = ((ConvertTo-RegistryCliPath -Path $path) -replace '[\\/:*?"<>| ]', "_")
        $exportPath = Join-Path $backupDir "$safeName.reg"
        $cliPath = ConvertTo-RegistryCliPath -Path $path

        try {
            $prevEAP = $ErrorActionPreference
            try {
                $ErrorActionPreference = "SilentlyContinue"
                $exportOutput = & reg.exe export $cliPath $exportPath /y 2>&1
                $exportExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEAP
            }
            if ($exportExitCode -ne 0) {
                throw "reg export failed with exit code $exportExitCode. $($exportOutput -join ' ')"
            }

            $registryExports += [pscustomobject]@{
                Path = $path
                File = (Split-Path -Leaf $exportPath)
                Exported = $true
            }
        } catch {
            $registryExports += [pscustomobject]@{
                Path = $path
                File = $null
                Exported = $false
                Error = $_.Exception.Message
            }
        }
    }

    $registryValueSnapshots = @()
    foreach ($valueRef in (Get-ApexPulseRegistryValueRefs -Tweaks $Tweaks)) {
        $registryValueSnapshots += Get-RegistryValueState -Path $valueRef.Path -Name $valueRef.Name
    }

    $restorePoint = [pscustomobject]@{
        Attempted = $false
        Created = $false
        Error = $null
    }

    if (Test-ApexPulseAdmin) {
        $restorePoint.Attempted = $true
        try {
            Checkpoint-Computer -Description "$script:ProductName $stamp" -RestorePointType "MODIFY_SETTINGS"
            $restorePoint.Created = $true
        } catch {
            $restorePoint.Error = $_.Exception.Message
        }
    }

    $manifest = [pscustomobject]@{
        Product = $script:ProductName
        Version = $script:ProductVersion
        Profile = $SelectedProfile
        CreatedAt = (Get-Date).ToString("o")
        Computer = Get-ApexPulseComputerState
        ActivePowerSchemeGuid = Get-ActivePowerSchemeGuid
        ServiceSnapshots = @(
            Get-ServiceSnapshot -Name "SysMain"
            Get-ServiceSnapshot -Name "WSearch"
            Get-ServiceSnapshot -Name "DiagTrack"
            Get-ServiceSnapshot -Name "lfsvc"
        )
        PackageSnapshots = @(
            Get-PackageSnapshots -SelectedProfile $SelectedProfile
        )
        RegistryExports = $registryExports
        RegistryValueSnapshots = $registryValueSnapshots
        RestorePoint = $restorePoint
    }

    $manifestPath = Join-Path $backupDir "manifest.json"
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

    return $backupDir
}

function Restore-ApexPulseBackup {
    param([Parameter(Mandatory)][string]$Path)

    Assert-ApexPulseWindows

    $manifestPath = Join-Path $Path "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Backup manifest not found: $manifestPath"
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    $results = @()

    foreach ($export in $manifest.RegistryExports) {
        if (-not $export.Exported -or -not $export.File) {
            $results += [pscustomobject]@{
                Target = $export.Path
                Status = "Skipped"
                Detail = "No registry export was available."
            }
            continue
        }

        $regFile = Join-Path $Path $export.File
        try {
            $prevEAP = $ErrorActionPreference
            try {
                $ErrorActionPreference = "SilentlyContinue"
                $importOutput = & reg.exe import $regFile 2>&1
                $importExitCode = $LASTEXITCODE
            } finally {
                $ErrorActionPreference = $prevEAP
            }
            if ($importExitCode -ne 0) {
                throw "reg import failed with exit code $importExitCode. $($importOutput -join ' ')"
            }

            $results += [pscustomobject]@{
                Target = $export.Path
                Status = "Restored"
                Detail = $regFile
            }
        } catch {
            $results += [pscustomobject]@{
                Target = $export.Path
                Status = "Failed"
                Detail = $_.Exception.Message
            }
        }
    }

    if ($manifest.PSObject.Properties.Name -contains "RegistryValueSnapshots") {
        foreach ($snapshot in $manifest.RegistryValueSnapshots) {
            if ($snapshot.Exists) {
                continue
            }

            try {
                $currentState = Get-RegistryValueState -Path $snapshot.Path -Name $snapshot.Name
                if ((Test-Path -LiteralPath $snapshot.Path) -and
                    $currentState.Exists) {
                    Remove-ItemProperty -LiteralPath $snapshot.Path -Name $snapshot.Name -ErrorAction SilentlyContinue
                }
                $results += [pscustomobject]@{
                    Target = "$($snapshot.Path)\$($snapshot.Name)"
                    Status = "Removed"
                    Detail = "Value did not exist before apply."
                }
            } catch {
                $results += [pscustomobject]@{
                    Target = "$($snapshot.Path)\$($snapshot.Name)"
                    Status = "Failed"
                    Detail = $_.Exception.Message
                }
            }
        }
    }

    if ($manifest.PSObject.Properties.Name -contains "ActivePowerSchemeGuid" -and $manifest.ActivePowerSchemeGuid) {
        try {
            Invoke-PowerCfg -Arguments @("/setactive", $manifest.ActivePowerSchemeGuid) | Out-Null
            $results += [pscustomobject]@{
                Target = "Power scheme"
                Status = "Restored"
                Detail = $manifest.ActivePowerSchemeGuid
            }
        } catch {
            $results += [pscustomobject]@{
                Target = "Power scheme"
                Status = "Failed"
                Detail = $_.Exception.Message
            }
        }
    }

    if ($manifest.PSObject.Properties.Name -contains "ServiceSnapshots") {
        foreach ($serviceSnapshot in $manifest.ServiceSnapshots) {
            $results += Restore-ServiceSnapshot -Snapshot $serviceSnapshot
        }
    }

    if ($manifest.PSObject.Properties.Name -contains "PackageSnapshots") {
        $results += Restore-PackageSnapshots -Snapshots @($manifest.PackageSnapshots)
    }

    return $results
}

function Get-ApexPulseBackups {
    if (-not (Test-Path -LiteralPath $script:BackupRoot)) {
        return @()
    }

    Get-ChildItem -LiteralPath $script:BackupRoot -Directory |
        Where-Object { Test-Path (Join-Path $_.FullName "manifest.json") } |
        Sort-Object Name -Descending |
        ForEach-Object {
            try {
                $manifest = Get-Content (Join-Path $_.FullName "manifest.json") -Raw | ConvertFrom-Json
                [pscustomobject]@{
                    Name = $_.Name
                    Path = $_.FullName
                    Profile = $manifest.Profile
                    CreatedAt = $manifest.CreatedAt
                    Product = if ($manifest.PSObject.Properties.Name -contains "Product") { $manifest.Product } else { "Unknown" }
                }
            } catch {
                $null
            }
        } |
        Where-Object { $_ }
}

#endregion

# ---------------------------------------------------------------------------
#region Power, Service & Package Helpers
# ---------------------------------------------------------------------------

function Invoke-PowerCfg {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = & powercfg.exe @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "powercfg failed with exit code $exitCode. $($output -join ' ')"
    }

    return ($output -join [Environment]::NewLine)
}

function Get-ActivePowerSchemeGuid {
    try {
        $output = Invoke-PowerCfg -Arguments @("/getactivescheme")
        if ($output -match "([a-fA-F0-9-]{36})") {
            return $Matches[1]
        }
    } catch {
        return $null
    }

    return $null
}

function Get-ServiceSnapshot {
    param([Parameter(Mandatory)][string]$Name)

    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$Name'" -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        return [pscustomobject]@{
            Name = $Name
            Exists = $false
            StartMode = $null
            State = $null
        }
    }

    [pscustomobject]@{
        Name = $Name
        Exists = $true
        StartMode = $service.StartMode
        State = $service.State
    }
}

function Restore-ServiceSnapshot {
    param([Parameter(Mandatory)]$Snapshot)

    if (-not $Snapshot.Exists) {
        return [pscustomobject]@{
            Target = $Snapshot.Name
            Status = "Skipped"
            Detail = "Service did not exist before apply."
        }
    }

    $startupType = switch ($Snapshot.StartMode) {
        "Auto" { "Automatic" }
        "Manual" { "Manual" }
        "Disabled" { "Disabled" }
        default { $null }
    }

    try {
        if ($startupType) {
            Set-Service -Name $Snapshot.Name -StartupType $startupType
        }

        if ($Snapshot.State -eq "Running") {
            Start-Service -Name $Snapshot.Name -ErrorAction SilentlyContinue
        } else {
            Stop-Service -Name $Snapshot.Name -Force -ErrorAction SilentlyContinue
        }

        return [pscustomobject]@{
            Target = $Snapshot.Name
            Status = "Restored"
            Detail = "Service startup/state restored."
        }
    } catch {
        return [pscustomobject]@{
            Target = $Snapshot.Name
            Status = "Failed"
            Detail = $_.Exception.Message
        }
    }
}

function Test-WingetPackageInstalled {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Source
    )

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        return $null
    }

    $output = & winget.exe list --id $Id --exact --source $Source --accept-source-agreements 2>&1
    $outputText = $output -join "`n"
    if ($LASTEXITCODE -ne 0) {
        if ($outputText -match "No installed package|No package found|No installed package found|No installed package matching") {
            return $false
        }
        return $null
    }

    return ($outputText -match [regex]::Escape($Id))
}

function Get-PackageSnapshots {
    param([Parameter(Mandatory)][string]$SelectedProfile)

    Get-ApexPulsePackageSet |
        Where-Object { $_.Profile -eq "Safe" -or $SelectedProfile -eq "Competitive" } |
        ForEach-Object {
            [pscustomobject]@{
                Id = $_.Id
                Name = $_.Name
                Source = $_.Source
                Installed = Test-WingetPackageInstalled -Id $_.Id -Source $_.Source
            }
        }
}

function Restore-PackageSnapshots {
    param([Parameter(Mandatory)][array]$Snapshots)

    $results = @()
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    foreach ($snapshot in $Snapshots) {
        if ($snapshot.Installed -ne $false) {
            $results += [pscustomobject]@{
                Target = $snapshot.Id
                Status = "Skipped"
                Detail = "Package was installed before apply or original state was unknown."
            }
            continue
        }

        if (-not $winget) {
            $results += [pscustomobject]@{
                Target = $snapshot.Id
                Status = "Skipped"
                Detail = "winget.exe is not available for package rollback."
            }
            continue
        }

        try {
            $source = if ($snapshot.PSObject.Properties.Name -contains "Source" -and $snapshot.Source) { $snapshot.Source } else { "winget" }
            $output = & winget.exe uninstall --id $snapshot.Id --exact --source $source --silent --accept-source-agreements 2>&1
            $exitCode = $LASTEXITCODE
            if ($exitCode -ne 0) {
                throw "winget uninstall failed with exit code $exitCode. $($output -join ' ')"
            }
            $results += [pscustomobject]@{
                Target = $snapshot.Id
                Status = "Removed"
                Detail = "Package was not present before apply."
            }
        } catch {
            $results += [pscustomobject]@{
                Target = $snapshot.Id
                Status = "Failed"
                Detail = $_.Exception.Message
            }
        }
    }

    return $results
}

function Update-BackupPackageSnapshots {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][array]$PackageResults
    )

    $manifestPath = Join-Path $Path "manifest.json"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return
    }

    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
    if ($manifest.PSObject.Properties.Name -notcontains "PackageSnapshots") {
        return
    }

    foreach ($result in $PackageResults) {
        if ($result.PSObject.Properties.Name -notcontains "PackageId" -or
            $result.PSObject.Properties.Name -notcontains "InstalledBefore") {
            continue
        }

        if ($null -eq $result.InstalledBefore) {
            continue
        }

        foreach ($snapshot in @($manifest.PackageSnapshots)) {
            if ($snapshot.Id -eq $result.PackageId) {
                $snapshot.Installed = $result.InstalledBefore
            }
        }
    }

    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding UTF8
}

function Install-ApexPulseWingetBootstrap {
    Assert-ApexPulseWindows

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        return "winget.exe is already available."
    }

    if (-not (Test-ApexPulseAdmin)) {
        return "winget.exe is missing and bootstrap requires Administrator."
    }

    $tempDir = Join-Path $env:TEMP "ApexPulse11-WinGetBootstrap"
    if (Test-Path -LiteralPath $tempDir) {
        Remove-Item -LiteralPath $tempDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $tempDir -Force | Out-Null

    $downloads = @(
        [pscustomobject]@{
            Uri = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
            Path = Join-Path $tempDir "vclibs.appx"
        }
        [pscustomobject]@{
            Uri = "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx"
            Path = Join-Path $tempDir "uixaml.appx"
        }
        [pscustomobject]@{
            Uri = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
            Path = Join-Path $tempDir "winget.msixbundle"
        }
    )

    try {
        foreach ($download in $downloads) {
            Invoke-WebRequest -Uri $download.Uri -OutFile $download.Path
        }

        foreach ($download in $downloads) {
            Add-AppxPackage -Path $download.Path
        }

        Start-Process wsreset.exe -ArgumentList "-i" -NoNewWindow -Wait
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
        return "WinGet and Microsoft Store bootstrap completed."
    } finally {
        Remove-Item -LiteralPath $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Repair-ApexPulseStoreInfrastructure {
    Assert-ApexPulseWindows

    if (-not (Test-ApexPulseAdmin)) {
        return "Microsoft Store repair requires Administrator."
    }

    Start-Process wsreset.exe -ArgumentList "-i" -NoNewWindow -Wait
    return "Microsoft Store infrastructure repair requested."
}

#endregion

# ---------------------------------------------------------------------------
#region Optimization Tweaks
# ---------------------------------------------------------------------------

function Get-ApexPulseTweaks {
    $safeProfile = "Safe"
    $competitiveProfile = "Competitive"

    @(
        # ----- Gaming Features -----
        [pscustomobject]@{
            Id = "gaming.game-mode"
            Name = "Game Mode"
            Group = "Gaming Features"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @("HKCU:\Software\Microsoft\GameBar")
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AllowAutoGameMode" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "AutoGameModeEnabled" }
            )
            Detect = {
                $enabled = Get-RegistryValueSafe -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled"
                if ($enabled -eq 1) { "Ready" } else { "Will enable Game Mode for the current user." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\GameBar" -Name "AllowAutoGameMode" -Value 1
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\GameBar" -Name "AutoGameModeEnabled" -Value 1
                "Game Mode enabled."
            }
        }
        [pscustomobject]@{
            Id = "capture.disable-gamedvr"
            Name = "Disable background recording"
            Group = "Background Noise"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @(
                "HKCU:\System\GameConfigStore",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_Enabled" }
                [pscustomobject]@{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_FSEBehaviorMode" }
                [pscustomobject]@{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_HonorUserFSEBehaviorMode" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"; Name = "AppCaptureEnabled" }
            )
            Detect = {
                $capture = Get-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled"
                if ($capture -eq 0) { "Ready" } else { "Will disable GameDVR background capture." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_Enabled" -Value 0
                Set-RegistryValueSafe -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_FSEBehaviorMode" -Value 2
                Set-RegistryValueSafe -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_HonorUserFSEBehaviorMode" -Value 1
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR" -Name "AppCaptureEnabled" -Value 0
                "Background recording disabled."
            }
        }

        # ----- Power -----
        [pscustomobject]@{
            Id = "power.high-performance"
            Name = "Gaming power plan"
            Group = "Power"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @()
            Detect = {
                $plans = Invoke-PowerCfg -Arguments @("/list")
                if ($plans -match "\*") { "Will activate a high-performance gaming power plan." } else { "Will inspect power plans." }
            }
            Apply = {
                $ultimateGuid = "e9a42b02-d5df-448d-aa00-03f14749eb61"
                try {
                    Invoke-PowerCfg -Arguments @("/setactive", $ultimateGuid) | Out-Null
                    "Ultimate Performance activated."
                } catch {
                    Invoke-PowerCfg -Arguments @("/setactive", "SCHEME_MIN") | Out-Null
                    "High Performance activated."
                }
            }
        }
        [pscustomobject]@{
            Id = "power.disable-throttling"
            Name = "Disable power throttling"
            Group = "Power"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @("HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling")
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling"; Name = "PowerThrottlingOff" }
            )
            Detect = {
                $value = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff"
                if ($value -eq 1) { "Ready" } else { "Will disable power throttling to maintain peak CPU performance." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling" -Name "PowerThrottlingOff" -Value 1
                "Power throttling disabled."
            }
        }

        # ----- Latency -----
        [pscustomobject]@{
            Id = "multimedia.games-priority"
            Name = "MMCSS games priority"
            Group = "Latency"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $true
            RegistryPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile",
                "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; Name = "SystemResponsiveness" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"; Name = "NetworkThrottlingIndex" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; Name = "GPU Priority" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; Name = "Priority" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; Name = "Scheduling Category" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"; Name = "SFIO Priority" }
            )
            Detect = {
                $priority = Get-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "Priority"
                if ($priority -eq 6) { "Ready" } else { "Will prioritize the Games multimedia scheduling profile." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "SystemResponsiveness" -Value 0
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xffffffff
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "GPU Priority" -Value 8
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "Priority" -Value 6
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "Scheduling Category" -Value "High" -Type String
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games" -Name "SFIO Priority" -Value "High" -Type String
                "Games multimedia scheduling profile tuned."
            }
        }
        [pscustomobject]@{
            Id = "capture.fullscreen-exclusive"
            Name = "Prefer exclusive fullscreen"
            Group = "Latency"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @("HKCU:\System\GameConfigStore")
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_DXGIHonorFSEWindowsCompatible" }
                [pscustomobject]@{ Path = "HKCU:\System\GameConfigStore"; Name = "GameDVR_EFSEFeatureFlags" }
            )
            Detect = {
                $value = Get-RegistryValueSafe -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_DXGIHonorFSEWindowsCompatible"
                if ($value -eq 1) { "Ready" } else { "Will prefer exclusive fullscreen to reduce compositor overhead." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_DXGIHonorFSEWindowsCompatible" -Value 1
                Set-RegistryValueSafe -Path "HKCU:\System\GameConfigStore" -Name "GameDVR_EFSEFeatureFlags" -Value 0
                "Exclusive fullscreen preferred."
            }
        }
        [pscustomobject]@{
            Id = "gaming.disable-overlay"
            Name = "Disable Game Bar overlay"
            Group = "Latency"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @("HKCU:\Software\Microsoft\GameBar")
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "UseNexusForGameBarEnabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\GameBar"; Name = "ShowStartupPanel" }
            )
            Detect = {
                $value = Get-RegistryValueSafe -Path "HKCU:\Software\Microsoft\GameBar" -Name "UseNexusForGameBarEnabled"
                if ($value -eq 0) { "Ready" } else { "Will disable Game Bar overlay to reduce rendering overhead." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\GameBar" -Name "UseNexusForGameBarEnabled" -Value 0
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\GameBar" -Name "ShowStartupPanel" -Value 0
                "Game Bar overlay disabled."
            }
        }

        # ----- GPU -----
        [pscustomobject]@{
            Id = "gpu.hags"
            Name = "Hardware-accelerated GPU scheduling"
            Group = "GPU"
            Profiles = @($safeProfile, $competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $true
            RegistryPaths = @("HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers")
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"; Name = "HwSchMode" }
            )
            Detect = {
                $value = Get-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode"
                if ($value -eq 2) { "Ready" } else { "Will enable HAGS when the driver supports it." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" -Name "HwSchMode" -Value 2
                "Hardware-accelerated GPU scheduling requested."
            }
        }

        # ----- Competitive-only: Background Noise -----
        [pscustomobject]@{
            Id = "explorer.reduce-consumer-content"
            Name = "Reduce consumer suggestions"
            Group = "Background Noise"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @(
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "ContentDeliveryAllowed" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "OemPreInstalledAppsEnabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "PreInstalledAppsEnabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SilentInstalledAppsEnabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338389Enabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-338393Enabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"; Name = "SubscribedContent-353694Enabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarDa" }
            )
            Detect = {
                "Competitive mode will reduce Windows suggestions and widget noise."
            }
            Apply = {
                $contentPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager"
                foreach ($name in @(
                    "ContentDeliveryAllowed",
                    "OemPreInstalledAppsEnabled",
                    "PreInstalledAppsEnabled",
                    "SilentInstalledAppsEnabled",
                    "SubscribedContent-338389Enabled",
                    "SubscribedContent-338393Enabled",
                    "SubscribedContent-353694Enabled"
                )) {
                    Set-RegistryValueSafe -Path $contentPath -Name $name -Value 0
                }
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarDa" -Value 0
                "Consumer suggestions reduced for the current user."
            }
        }
        [pscustomobject]@{
            Id = "visual.reduce-effects"
            Name = "Reduce visual effects"
            Group = "Background Noise"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @(
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "HKCU:\Software\Microsoft\Windows\DWM",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced",
                "HKCU:\Control Panel\Desktop\WindowMetrics"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"; Name = "EnableTransparency" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\DWM"; Name = "EnableAeroPeek" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"; Name = "TaskbarAnimations" }
                [pscustomobject]@{ Path = "HKCU:\Control Panel\Desktop\WindowMetrics"; Name = "MinAnimate" }
            )
            Detect = {
                $transparency = Get-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency"
                if ($transparency -eq 0) { "Ready" } else { "Competitive mode will reduce transparency and animations to free GPU cycles." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize" -Name "EnableTransparency" -Value 0
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\DWM" -Name "EnableAeroPeek" -Value 0
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAnimations" -Value 0
                Set-RegistryValueSafe -Path "HKCU:\Control Panel\Desktop\WindowMetrics" -Name "MinAnimate" -Value "0" -Type String
                "Visual effects reduced."
            }
        }
        [pscustomobject]@{
            Id = "notifications.suppress-toasts"
            Name = "Suppress notification toasts"
            Group = "Background Noise"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @(
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications",
                "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications"; Name = "ToastEnabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"; Name = "DisableNotificationCenter" }
            )
            Detect = {
                $toasts = Get-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "ToastEnabled"
                if ($toasts -eq 0) { "Ready" } else { "Competitive mode will suppress notification popups during gaming." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications" -Name "ToastEnabled" -Value 0
                Set-RegistryValueSafe -Path "HKCU:\Software\Policies\Microsoft\Windows\Explorer" -Name "DisableNotificationCenter" -Value 1
                "Notification toasts suppressed."
            }
        }

        # ----- Competitive-only: Services -----
        [pscustomobject]@{
            Id = "services.sysmain"
            Name = "SysMain service"
            Group = "Competitive"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @()
            Detect = {
                $service = Get-Service -Name "SysMain" -ErrorAction SilentlyContinue
                if ($null -eq $service) { "SysMain not present." } else { "Competitive mode will stop SysMain to reduce storage/background spikes." }
            }
            Apply = {
                $service = Get-Service -Name "SysMain" -ErrorAction SilentlyContinue
                if ($null -eq $service) { return "SysMain not present." }
                Stop-Service -Name "SysMain" -Force -ErrorAction SilentlyContinue
                Set-Service -Name "SysMain" -StartupType Manual
                "SysMain stopped and set to Manual."
            }
        }
        [pscustomobject]@{
            Id = "services.wsearch"
            Name = "Windows Search service"
            Group = "Competitive"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @()
            Detect = {
                $service = Get-Service -Name "WSearch" -ErrorAction SilentlyContinue
                if ($null -eq $service) { "Windows Search not present." } else { "Competitive mode will stop Windows Search to reduce disk I/O spikes." }
            }
            Apply = {
                $service = Get-Service -Name "WSearch" -ErrorAction SilentlyContinue
                if ($null -eq $service) { return "Windows Search not present." }
                Stop-Service -Name "WSearch" -Force -ErrorAction SilentlyContinue
                Set-Service -Name "WSearch" -StartupType Manual
                "Windows Search stopped and set to Manual."
            }
        }
        [pscustomobject]@{
            Id = "services.diagtrack"
            Name = "Diagnostic tracking service"
            Group = "Competitive"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @()
            Detect = {
                $service = Get-Service -Name "DiagTrack" -ErrorAction SilentlyContinue
                if ($null -eq $service) { "DiagTrack not present." } else { "Competitive mode will stop telemetry to reduce background CPU usage." }
            }
            Apply = {
                $service = Get-Service -Name "DiagTrack" -ErrorAction SilentlyContinue
                if ($null -eq $service) { return "DiagTrack not present." }
                Stop-Service -Name "DiagTrack" -Force -ErrorAction SilentlyContinue
                Set-Service -Name "DiagTrack" -StartupType Manual
                "Diagnostic tracking stopped and set to Manual."
            }
        }

        # ----- Competitive-only: Privacy Matrix -----
        [pscustomobject]@{
            Id = "privacy.tailored-experiences"
            Name = "Disable tailored experiences"
            Group = "Privacy"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $false
            RebootRequired = $false
            RegistryPaths = @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy")
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy"; Name = "TailoredExperiencesWithDiagnosticDataEnabled" }
            )
            Detect = {
                $val = Get-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled"
                if ($val -eq 0) { "Ready" } else { "Will disable tailored experiences based on diagnostic data." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy" -Name "TailoredExperiencesWithDiagnosticDataEnabled" -Value 0
                "Tailored experiences disabled."
            }
        }
        [pscustomobject]@{
            Id = "privacy.diagnostic-data"
            Name = "Reduce diagnostic data upload"
            Group = "Privacy"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @(
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection",
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection"; Name = "AllowTelemetry" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection"; Name = "AllowTelemetry" }
            )
            Detect = {
                $val = Get-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry"
                if ($val -eq 0) { "Ready" } else { "Will reduce diagnostic data upload to security-only level." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection" -Name "AllowTelemetry" -Value 0
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection" -Name "AllowTelemetry" -Value 0
                "Diagnostic data reduced to security-only level."
            }
        }
        [pscustomobject]@{
            Id = "privacy.cortana-search"
            Name = "Disable Cortana and cloud search"
            Group = "Privacy"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @(
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search",
                "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "BingSearchEnabled" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search"; Name = "CortanaConsent" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "AllowCortana" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "DisableWebSearch" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search"; Name = "ConnectedSearchUseWeb" }
            )
            Detect = {
                $val = Get-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled"
                if ($val -eq 0) { "Ready" } else { "Will disable Bing search results and Cortana consent." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "BingSearchEnabled" -Value 0
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "CortanaConsent" -Value 0
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "AllowCortana" -Value 0
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "DisableWebSearch" -Value 1
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search" -Name "ConnectedSearchUseWeb" -Value 0
                "Cortana and cloud search disabled."
            }
        }
        [pscustomobject]@{
            Id = "privacy.location-tracking"
            Name = "Disable location tracking"
            Group = "Privacy"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @(
                "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location",
                "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"
            )
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "Value" }
                [pscustomobject]@{ Path = "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location"; Name = "Value" }
            )
            Detect = {
                $val = Get-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value"
                if ($val -eq "Deny") { "Ready" } else { "Will deny location access system-wide for gaming mode." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny" -Type String
                Set-RegistryValueSafe -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location" -Name "Value" -Value "Deny" -Type String
                "Location tracking disabled."
            }
        }
        [pscustomobject]@{
            Id = "privacy.activity-history"
            Name = "Disable activity history"
            Group = "Privacy"
            Profiles = @($competitiveProfile)
            RequiresAdmin = $true
            RebootRequired = $false
            RegistryPaths = @("HKLM:\SOFTWARE\Policies\Microsoft\Windows\System")
            RegistryValues = @(
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "EnableActivityFeed" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "PublishUserActivities" }
                [pscustomobject]@{ Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System"; Name = "UploadUserActivities" }
            )
            Detect = {
                $val = Get-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed"
                if ($val -eq 0) { "Ready" } else { "Will disable activity history collection and upload." }
            }
            Apply = {
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "EnableActivityFeed" -Value 0
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "PublishUserActivities" -Value 0
                Set-RegistryValueSafe -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Name "UploadUserActivities" -Value 0
                "Activity history disabled."
            }
        }
    )
}

function Get-ApexPulsePrivacyTweakIds {
    @(
        "privacy.tailored-experiences",
        "privacy.diagnostic-data",
        "privacy.cortana-search",
        "privacy.location-tracking",
        "privacy.activity-history"
    )
}

#endregion

# ---------------------------------------------------------------------------
#region Package Set
# ---------------------------------------------------------------------------

function Get-ApexPulsePackageSet {
    @(
        [pscustomobject]@{ Id = "Valve.Steam"; Name = "Steam"; Profile = "Safe"; Source = "winget" }
        [pscustomobject]@{ Id = "9MV0B5HZVK9Z"; Name = "Xbox App"; Profile = "Safe"; Source = "msstore" }
        [pscustomobject]@{ Id = "Discord.Discord"; Name = "Discord"; Profile = "Safe"; Source = "winget" }
        [pscustomobject]@{ Id = "7zip.7zip"; Name = "7-Zip"; Profile = "Safe"; Source = "winget" }
        [pscustomobject]@{ Id = "EpicGames.EpicGamesLauncher"; Name = "Epic Games Launcher"; Profile = "Competitive"; Source = "winget" }
        [pscustomobject]@{ Id = "GOG.Galaxy"; Name = "GOG Galaxy"; Profile = "Competitive"; Source = "winget" }
    )
}

function Invoke-ApexPulsePackages {
    param(
        [Parameter(Mandatory)][string]$SelectedProfile,
        [Parameter(Mandatory)][bool]$Apply
    )

    $selected = Get-ApexPulsePackageSet | Where-Object {
        $_.Profile -eq "Safe" -or $SelectedProfile -eq "Competitive"
    }

    $results = @()
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        if ($Apply) {
            try {
                $bootstrapDetail = Install-ApexPulseWingetBootstrap
                $bootstrapStatus = if (Get-Command winget.exe -ErrorAction SilentlyContinue) { "Applied" } else { "Skipped" }
            } catch {
                $bootstrapDetail = $_.Exception.Message
                $bootstrapStatus = "Failed"
            }

            $results += [pscustomobject]@{
                Id = "package.bootstrap-winget"
                Name = "WinGet bootstrap"
                Group = "Packages"
                Status = $bootstrapStatus
                Detail = $bootstrapDetail
                RebootRequired = $false
            }
            $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
        }
    }

    if (-not $winget) {
        foreach ($pkg in $selected) {
            $results += [pscustomobject]@{
                Id = "package.$($pkg.Id)"
                PackageId = $pkg.Id
                Source = $pkg.Source
                Name = $pkg.Name
                Group = "Packages"
                Status = "Skipped"
                Detail = "winget.exe was not found. On LTSC, run Store/App Installer bootstrap first or use packages.dsc.yaml."
                InstalledBefore = $null
                RebootRequired = $false
            }
        }
        return $results
    }

    if ($Apply -and ($selected | Where-Object { $_.Source -eq "msstore" } | Select-Object -First 1)) {
        try {
            $storeDetail = Repair-ApexPulseStoreInfrastructure
            $results += [pscustomobject]@{
                Id = "package.repair-msstore"
                Name = "Microsoft Store repair"
                Group = "Packages"
                Status = "Applied"
                Detail = $storeDetail
                RebootRequired = $false
            }
        } catch {
            $results += [pscustomobject]@{
                Id = "package.repair-msstore"
                Name = "Microsoft Store repair"
                Group = "Packages"
                Status = "Failed"
                Detail = $_.Exception.Message
                RebootRequired = $false
            }
        }
    }

    foreach ($pkg in $selected) {
        $installedBefore = $null
        if (-not $Apply) {
            $results += [pscustomobject]@{
                Id = "package.$($pkg.Id)"
                PackageId = $pkg.Id
                Source = $pkg.Source
                Name = $pkg.Name
                Group = "Packages"
                Status = "Planned"
                Detail = "Will ensure $($pkg.Id) is installed from $($pkg.Source)."
                InstalledBefore = $null
                RebootRequired = $false
            }
            continue
        }

        try {
            $installedBefore = Test-WingetPackageInstalled -Id $pkg.Id -Source $pkg.Source
            if ($installedBefore -ne $true) {
                $wingetOutput = & winget.exe install --id $pkg.Id --exact --source $pkg.Source --accept-package-agreements --accept-source-agreements --silent 2>&1
                $wingetExitCode = $LASTEXITCODE
                if ($wingetExitCode -ne 0) {
                    throw "winget install failed with exit code $wingetExitCode. $($wingetOutput -join ' ')"
                }
            }

            $packageDetail = if ($installedBefore) { "$($pkg.Id) was already present." } else { "$($pkg.Id) installed." }
            $results += [pscustomobject]@{
                Id = "package.$($pkg.Id)"
                PackageId = $pkg.Id
                Source = $pkg.Source
                Name = $pkg.Name
                Group = "Packages"
                Status = "Applied"
                Detail = $packageDetail
                InstalledBefore = $installedBefore
                RebootRequired = $false
            }
        } catch {
            $results += [pscustomobject]@{
                Id = "package.$($pkg.Id)"
                PackageId = $pkg.Id
                Source = $pkg.Source
                Name = $pkg.Name
                Group = "Packages"
                Status = "Failed"
                Detail = $_.Exception.Message
                InstalledBefore = $installedBefore
                RebootRequired = $false
            }
        }
    }

    return $results
}

#endregion

# ---------------------------------------------------------------------------
#region Profile Execution Engine
# ---------------------------------------------------------------------------

function Invoke-ApexPulseProfile {
    param(
        [ValidateSet("Safe", "Competitive")]
        [string]$SelectedProfile,

        [ValidateSet("Analyze", "Apply")]
        [string]$SelectedMode
    )

    Assert-ApexPulseWindows
    Initialize-ApexPulseStorage

    $admin = Test-ApexPulseAdmin
    $shouldApply = $SelectedMode -eq "Apply"
    $whatIf = [bool]$WhatIfPreference
    $canMutate = $shouldApply -and -not $whatIf
    $allTweaks = Get-ApexPulseTweaks
    $tweaks = $allTweaks | Where-Object { $_.Profiles -contains $SelectedProfile }
    $backup = $null

    if ($canMutate) {
        if (-not $admin) {
            throw "$script:ProductName needs an elevated PowerShell session to apply system-level optimizations."
        }

        $backup = New-ApexPulseBackup -Tweaks $tweaks -SelectedProfile $SelectedProfile
        Write-ApexPulseLog "Backup created: $backup" -Level Success
    }

    $results = @()
    foreach ($tweak in $tweaks) {
        try {
            if ($tweak.RequiresAdmin -and -not $admin) {
                $results += [pscustomobject]@{
                    Id = $tweak.Id
                    Name = $tweak.Name
                    Group = $tweak.Group
                    Status = "NeedsAdmin"
                    Detail = "Run as administrator to inspect or apply this optimization."
                    RebootRequired = $tweak.RebootRequired
                }
                continue
            }

            if (-not $shouldApply -or $whatIf) {
                $detail = & $tweak.Detect
                $plannedStatus = if ($whatIf) { "WhatIf" } else { "Planned" }
                $results += [pscustomobject]@{
                    Id = $tweak.Id
                    Name = $tweak.Name
                    Group = $tweak.Group
                    Status = $plannedStatus
                    Detail = $detail
                    RebootRequired = $tweak.RebootRequired
                }
                continue
            }

            if ($PSCmdlet.ShouldProcess($tweak.Name, "Apply $SelectedProfile optimization")) {
                $detail = & $tweak.Apply
                $results += [pscustomobject]@{
                    Id = $tweak.Id
                    Name = $tweak.Name
                    Group = $tweak.Group
                    Status = "Applied"
                    Detail = $detail
                    RebootRequired = $tweak.RebootRequired
                }
            }
        } catch {
            $results += [pscustomobject]@{
                Id = $tweak.Id
                Name = $tweak.Name
                Group = $tweak.Group
                Status = "Failed"
                Detail = $_.Exception.Message
                RebootRequired = $tweak.RebootRequired
            }
        }
    }

    $packageResults = Invoke-ApexPulsePackages -SelectedProfile $SelectedProfile -Apply $canMutate
    $results += $packageResults
    if ($canMutate -and $backup) {
        Update-BackupPackageSnapshots -Path $backup -PackageResults $packageResults
    }

    $report = [pscustomobject]@{
        Product = $script:ProductName
        Version = $script:ProductVersion
        Profile = $SelectedProfile
        Mode = $SelectedMode
        BackupPath = $backup
        Computer = Get-ApexPulseComputerState
        Results = $results
        RebootRequired = [bool]($results | Where-Object { $_.Status -eq "Applied" -and $_.RebootRequired } | Select-Object -First 1)
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $jsonPath = if ($ReportPath) {
        $ReportPath
    } else {
        Join-Path $script:ReportRoot ("report-{0}-{1}.json" -f $stamp, $SelectedProfile)
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonPath -Encoding UTF8

    $htmlPath = [IO.Path]::ChangeExtension($jsonPath, ".html")
    New-ApexPulseHtmlReport -Report $report -Path $htmlPath

    $report | Add-Member -MemberType NoteProperty -Name ReportPath -Value $jsonPath -Force
    $report | Add-Member -MemberType NoteProperty -Name HtmlReportPath -Value $htmlPath -Force
    return $report
}

#endregion

# ---------------------------------------------------------------------------
#region HTML Report Generation
# ---------------------------------------------------------------------------

function New-ApexPulseHtmlReport {
    param(
        [Parameter(Mandatory)]$Report,
        [Parameter(Mandatory)][string]$Path
    )

    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $rows = ""
    foreach ($item in $Report.Results) {
        $statusClass = switch ($item.Status) {
            "Applied"    { "applied" }
            "Failed"     { "failed" }
            "NeedsAdmin" { "warn" }
            "Planned"    { "planned" }
            "Skipped"    { "skipped" }
            "Ready"      { "applied" }
            default      { "planned" }
        }
        $reboot = if ($item.PSObject.Properties.Name -contains "RebootRequired" -and $item.RebootRequired) { "Yes" } else { "" }
        $escapedDetail = [System.Net.WebUtility]::HtmlEncode($item.Detail)
        $escapedName = [System.Net.WebUtility]::HtmlEncode($item.Name)
        $escapedGroup = [System.Net.WebUtility]::HtmlEncode($item.Group)
        $rows += "<tr><td class=`"$statusClass`">$($item.Status)</td><td>$escapedName</td><td>$escapedGroup</td><td>$escapedDetail</td><td>$reboot</td></tr>`n"
    }

    $backupLine = if ($Report.BackupPath) { "<p><strong>Backup:</strong> $([System.Net.WebUtility]::HtmlEncode($Report.BackupPath))</p>" } else { "" }
    $rebootLine = if ($Report.RebootRequired) { "<p class=`"warn`">A reboot is recommended to finish GPU/MMCSS changes.</p>" } else { "" }
    $osCaption = [System.Net.WebUtility]::HtmlEncode($Report.Computer.OSCaption)
    $computerName = [System.Net.WebUtility]::HtmlEncode($Report.Computer.ComputerName)

    $html = @"
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>$($script:ProductName) Report</title>
<style>
  :root { --bg: #0B0E17; --card: #111827; --border: #1E293B; --text: #F8FAFC; --muted: #94A3B8; --accent: #22D3EE; }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body { background: var(--bg); color: var(--text); font-family: 'Segoe UI', system-ui, sans-serif; padding: 40px; line-height: 1.6; }
  .header { margin-bottom: 32px; }
  .header h1 { font-size: 28px; color: var(--accent); font-weight: 900; }
  .header p { color: var(--muted); font-size: 14px; }
  .summary { background: var(--card); border: 1px solid var(--border); border-radius: 12px; padding: 20px; margin-bottom: 24px; }
  .summary p { margin: 4px 0; font-size: 14px; }
  table { width: 100%; border-collapse: collapse; background: var(--card); border: 1px solid var(--border); border-radius: 12px; overflow: hidden; }
  th { background: #1E293B; text-align: left; padding: 12px 16px; font-size: 13px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.5px; }
  td { padding: 10px 16px; border-top: 1px solid var(--border); font-size: 14px; }
  tr:hover { background: #0F172A; }
  .applied { color: #A3E635; font-weight: bold; }
  .failed { color: #EF4444; font-weight: bold; }
  .warn { color: #FBBF24; font-weight: bold; }
  .planned { color: #22D3EE; }
  .skipped { color: #64748B; }
  .footer { margin-top: 32px; color: var(--muted); font-size: 12px; text-align: center; }
</style>
</head>
<body>
<div class="header">
  <h1>$($script:ProductName)</h1>
  <p>Optimization Report &mdash; $timestamp</p>
</div>
<div class="summary">
  <p><strong>Profile:</strong> $($Report.Profile) &nbsp;&bull;&nbsp; <strong>Mode:</strong> $($Report.Mode)</p>
  <p><strong>Computer:</strong> $computerName &nbsp;&bull;&nbsp; <strong>OS:</strong> $osCaption</p>
  $backupLine
  $rebootLine
</div>
<table>
  <thead><tr><th>Status</th><th>Name</th><th>Group</th><th>Detail</th><th>Reboot</th></tr></thead>
  <tbody>
$rows  </tbody>
</table>
<div class="footer">Generated by $($script:ProductName) v$($script:ProductVersion)</div>
</body>
</html>
"@

    $html | Set-Content -LiteralPath $Path -Encoding UTF8
}

#endregion

# ---------------------------------------------------------------------------
#region Console Summary
# ---------------------------------------------------------------------------

function Show-ApexPulseConsoleSummary {
    param([Parameter(Mandatory)]$Report)

    Write-ApexPulseLog "$($Report.Product) $($Report.Version) - $($Report.Profile) / $($Report.Mode)" -Level Info
    foreach ($item in $Report.Results) {
        $level = switch ($item.Status) {
            "Applied" { "Success" }
            "Failed" { "Error" }
            "NeedsAdmin" { "Warn" }
            default { "Info" }
        }
        Write-ApexPulseLog "$($item.Status): $($item.Name) - $($item.Detail)" -Level $level
    }

    if ($Report.BackupPath) {
        Write-ApexPulseLog "Backup: $($Report.BackupPath)" -Level Success
    }
    Write-ApexPulseLog "Report (JSON): $($Report.ReportPath)" -Level Success
    if ($Report.PSObject.Properties.Name -contains "HtmlReportPath") {
        Write-ApexPulseLog "Report (HTML): $($Report.HtmlReportPath)" -Level Success
    }
    if ($Report.RebootRequired) {
        Write-ApexPulseLog "A reboot is recommended to finish GPU/MMCSS changes." -Level Warn
    }
}

#endregion

# ---------------------------------------------------------------------------
#region WPF User Interface
# ---------------------------------------------------------------------------

function Show-ApexPulseUi {
    Assert-ApexPulseWindows
    Initialize-ApexPulseStorage

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    # UI v2 — Dark Precision redesign
    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ApexPulse 11"
        Width="1040" Height="640"
        MinWidth="860" MinHeight="560"
        WindowStartupLocation="CenterScreen"
        WindowStyle="None"
        ResizeMode="CanResize"
        Background="#0d0f10"
        Foreground="#e8eaed"
        FontFamily="Segoe UI Variable Text, Segoe UI"
        FontSize="13"
        UseLayoutRounding="True"
        SnapsToDevicePixels="True"
        TextOptions.TextFormattingMode="Display"
        TextOptions.TextRenderingMode="ClearType">
  <WindowChrome.WindowChrome>
    <WindowChrome CaptionHeight="34"
                  ResizeBorderThickness="6"
                  GlassFrameThickness="0"
                  UseAeroCaptionButtons="False"
                  CornerRadius="0"/>
  </WindowChrome.WindowChrome>
  <Window.Resources>
    <!-- Color palette -->
    <SolidColorBrush x:Key="BgPrimary" Color="#0d0f10"/>
    <SolidColorBrush x:Key="BgSurface" Color="#141618"/>
    <SolidColorBrush x:Key="BgElevated" Color="#1c1e21"/>
    <SolidColorBrush x:Key="BgHover" Color="#23262a"/>
    <SolidColorBrush x:Key="AccentCyan" Color="#00d4ff"/>
    <SolidColorBrush x:Key="AccentCyanSoft" Color="#1a00d4ff"/>
    <SolidColorBrush x:Key="AccentGreen" Color="#a3e635"/>
    <SolidColorBrush x:Key="AccentGreenSoft" Color="#1aa3e635"/>
    <SolidColorBrush x:Key="DangerRed" Color="#ff4757"/>
    <SolidColorBrush x:Key="DangerRedSoft" Color="#1aff4757"/>
    <SolidColorBrush x:Key="TextPrimary" Color="#e8eaed"/>
    <SolidColorBrush x:Key="TextMuted" Color="#7a7e82"/>
    <SolidColorBrush x:Key="TextSubtle" Color="#5b5f63"/>
    <SolidColorBrush x:Key="DividerBrush" Color="#2a2d31"/>
    <SolidColorBrush x:Key="AdminAmber" Color="#f59e0b"/>
    <SolidColorBrush x:Key="AdminAmberSoft" Color="#26f59e0b"/>

    <CubicEase x:Key="EaseOutCubic" EasingMode="EaseOut"/>

    <Style TargetType="TextBlock">
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
    </Style>

    <Style TargetType="ScrollBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#2a2d31"/>
      <Setter Property="Width" Value="8"/>
    </Style>

    <!-- Window control button (min/max) -->
    <Style x:Key="WindowControlButtonStyle" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#23262a"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style x:Key="CloseControlButtonStyle" TargetType="Button">
      <Setter Property="Width" Value="46"/>
      <Setter Property="Height" Value="34"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="WindowChrome.IsHitTestVisibleInChrome" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="#ff4757"/>
                <Setter Property="Foreground" Value="White"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Sidebar nav radio -->
    <Style x:Key="NavRadio" TargetType="RadioButton">
      <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="Padding" Value="14,9"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Grid>
              <Border x:Name="bgRoot" Background="{TemplateBinding Background}" CornerRadius="6"/>
              <Rectangle x:Name="accent" Width="3" Height="20" HorizontalAlignment="Left" Fill="Transparent" RadiusX="1.5" RadiusY="1.5" Margin="0,0,0,0"/>
              <ContentPresenter Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bgRoot" Property="Background" Value="#1c1e21"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="bgRoot" Property="Background" Value="{StaticResource AccentCyanSoft}"/>
                <Setter TargetName="accent" Property="Fill" Value="{StaticResource AccentCyan}"/>
                <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Primary cyan button -->
    <Style x:Key="PrimaryButton" TargetType="Button">
      <Setter Property="Background" Value="{StaticResource AccentCyan}"/>
      <Setter Property="Foreground" Value="#062028"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Padding" Value="18,9"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="6" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform x:Name="st" ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
              <Border.Effect>
                <DropShadowEffect Color="#00d4ff" ShadowDepth="0" BlurRadius="14" Opacity="0.30"/>
              </Border.Effect>
              <Grid>
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                <Border x:Name="overlay" Background="White" Opacity="0" CornerRadius="6" IsHitTestVisible="False"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="overlay" Property="Opacity" Value="0.06"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="0.97" Duration="0:0:0.08"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="0.97" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Safe (green) variant -->
    <Style x:Key="SafeApplyButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="{StaticResource AccentGreen}"/>
      <Setter Property="Foreground" Value="#1a2308"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="6" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform x:Name="st" ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
              <Border.Effect>
                <DropShadowEffect Color="#a3e635" ShadowDepth="0" BlurRadius="14" Opacity="0.30"/>
              </Border.Effect>
              <Grid>
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                <Border x:Name="overlay" Background="White" Opacity="0" CornerRadius="6" IsHitTestVisible="False"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="overlay" Property="Opacity" Value="0.06"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="0.97" Duration="0:0:0.08"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="0.97" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Danger button -->
    <Style x:Key="DangerButton" TargetType="Button" BasedOn="{StaticResource PrimaryButton}">
      <Setter Property="Background" Value="{StaticResource DangerRed}"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="6" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform x:Name="st" ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
              <Border.Effect>
                <DropShadowEffect Color="#ff4757" ShadowDepth="0" BlurRadius="12" Opacity="0.30"/>
              </Border.Effect>
              <Grid>
                <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
                <Border x:Name="overlay" Background="White" Opacity="0" CornerRadius="6" IsHitTestVisible="False"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="overlay" Property="Opacity" Value="0.08"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="0.97" Duration="0:0:0.08"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="0.97" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Outline / secondary button -->
    <Style x:Key="SecondaryButton" TargetType="Button">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Display, Segoe UI"/>
      <Setter Property="FontWeight" Value="Medium"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Padding" Value="14,8"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="RenderTransformOrigin" Value="0.5,0.5"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bg" Background="{TemplateBinding Background}" CornerRadius="6" BorderBrush="{StaticResource DividerBrush}" BorderThickness="1" RenderTransformOrigin="0.5,0.5">
              <Border.RenderTransform>
                <ScaleTransform x:Name="st" ScaleX="1" ScaleY="1"/>
              </Border.RenderTransform>
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bg" Property="Background" Value="{StaticResource BgElevated}"/>
                <Setter TargetName="bg" Property="BorderBrush" Value="{StaticResource AccentCyan}"/>
                <Setter Property="Foreground" Value="{StaticResource AccentCyan}"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="0.97" Duration="0:0:0.08"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="0.97" Duration="0:0:0.08"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.EnterActions>
                <Trigger.ExitActions>
                  <BeginStoryboard>
                    <Storyboard>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.12"/>
                      <DoubleAnimation Storyboard.TargetName="st" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.12"/>
                    </Storyboard>
                  </BeginStoryboard>
                </Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.5"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Profile card (RadioButton styled as full card) -->
    <Style x:Key="ProfileCard" TargetType="RadioButton">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="HorizontalContentAlignment" Value="Stretch"/>
      <Setter Property="VerticalContentAlignment" Value="Stretch"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="RadioButton">
            <Border x:Name="card" Background="{StaticResource BgSurface}" CornerRadius="8" BorderBrush="{StaticResource DividerBrush}" BorderThickness="1" Padding="22">
              <ContentPresenter HorizontalAlignment="Stretch" VerticalAlignment="Stretch"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="card" Property="Background" Value="{StaticResource BgElevated}"/>
                <Setter TargetName="card" Property="BorderBrush" Value="#3a3d42"/>
              </Trigger>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="card" Property="BorderBrush" Value="{StaticResource AccentCyan}"/>
                <Setter TargetName="card" Property="BorderThickness" Value="1.5"/>
                <Setter TargetName="card" Property="Background" Value="{StaticResource BgElevated}"/>
                <Setter TargetName="card" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#00d4ff" ShadowDepth="0" BlurRadius="24" Opacity="0.35"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Pill toggle (privacy switches) -->
    <Style x:Key="PillToggle" TargetType="ToggleButton">
      <Setter Property="Width" Value="44"/>
      <Setter Property="Height" Value="24"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Background" Value="#2a2d31"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ToggleButton">
            <Border x:Name="track" Background="{TemplateBinding Background}" CornerRadius="12">
              <Grid>
                <Ellipse x:Name="thumb" Width="18" Height="18" Fill="#7a7e82" HorizontalAlignment="Left" Margin="3,0,0,0"/>
              </Grid>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="{StaticResource AccentCyan}"/>
                <Setter TargetName="thumb" Property="Fill" Value="White"/>
                <Setter TargetName="thumb" Property="HorizontalAlignment" Value="Right"/>
                <Setter TargetName="thumb" Property="Margin" Value="0,0,3,0"/>
                <Setter TargetName="track" Property="Effect">
                  <Setter.Value>
                    <DropShadowEffect Color="#00d4ff" ShadowDepth="0" BlurRadius="10" Opacity="0.45"/>
                  </Setter.Value>
                </Setter>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <!-- Console-style read-only TextBox -->
    <Style x:Key="ConsoleTextBox" TargetType="TextBox">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="Padding" Value="14"/>
      <Setter Property="CaretBrush" Value="{StaticResource AccentCyan}"/>
    </Style>

    <!-- Section pill label -->
    <Style x:Key="SectionLabel" TargetType="TextBlock">
      <Setter Property="FontSize" Value="9"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Foreground" Value="{StaticResource TextSubtle}"/>
    </Style>

    <!-- DataGrid -->
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="{StaticResource BgSurface}"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="GridLinesVisibility" Value="None"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="CanUserResizeRows" Value="False"/>
      <Setter Property="CanUserSortColumns" Value="False"/>
      <Setter Property="RowBackground" Value="#141618"/>
      <Setter Property="AlternatingRowBackground" Value="#1c1e21"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Auto"/>
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="SelectionMode" Value="Single"/>
      <Setter Property="SelectionUnit" Value="FullRow"/>
      <Setter Property="IsReadOnly" Value="True"/>
      <Setter Property="ColumnHeaderHeight" Value="32"/>
      <Setter Property="RowHeight" Value="42"/>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="{StaticResource BgSurface}"/>
      <Setter Property="Foreground" Value="{StaticResource TextSubtle}"/>
      <Setter Property="FontFamily" Value="Segoe UI Variable Text, Segoe UI"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="10"/>
      <Setter Property="BorderBrush" Value="{StaticResource DividerBrush}"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
    </Style>

    <Style TargetType="DataGridCell">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="16,0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="DataGridCell">
            <Grid Background="{TemplateBinding Background}">
              <ContentPresenter VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="{StaticResource AccentCyanSoft}"/>
          <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
        </Trigger>
      </Style.Triggers>
    </Style>

    <Style TargetType="DataGridRow">
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
    </Style>

    <Style x:Key="GridRowButton" TargetType="Button" BasedOn="{StaticResource DangerButton}">
      <Setter Property="Padding" Value="14,5"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,5,14,5"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <Style x:Key="GridRowOpenButton" TargetType="Button" BasedOn="{StaticResource SecondaryButton}">
      <Setter Property="Padding" Value="14,5"/>
      <Setter Property="FontSize" Value="11"/>
      <Setter Property="Margin" Value="0,5,14,5"/>
      <Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="VerticalAlignment" Value="Center"/>
    </Style>

    <!-- Progress bar (top loading) -->
    <Style x:Key="LoadingBarStyle" TargetType="ProgressBar">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="{StaticResource AccentCyan}"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Height" Value="3"/>
      <Setter Property="IsIndeterminate" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ProgressBar">
            <Grid>
              <Border Background="Transparent"/>
              <Border x:Name="PART_Track" Background="Transparent"/>
              <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}" HorizontalAlignment="Left">
                <Border.Effect>
                  <DropShadowEffect Color="#00d4ff" ShadowDepth="0" BlurRadius="10" Opacity="0.6"/>
                </Border.Effect>
              </Border>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border Background="{StaticResource BgPrimary}">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="3"/>
        <RowDefinition Height="34"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="28"/>
      </Grid.RowDefinitions>

      <!-- Top loading bar -->
      <ProgressBar Grid.Row="0" x:Name="LoadingBar" Style="{StaticResource LoadingBarStyle}" Visibility="Hidden"/>

      <!-- Title bar (drag region via WindowChrome.CaptionHeight) -->
      <Grid Grid.Row="1" Background="{StaticResource BgPrimary}">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="Auto"/>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="Auto"/>
        </Grid.ColumnDefinitions>
        <StackPanel Grid.Column="0" Orientation="Horizontal" Margin="14,0,0,0" VerticalAlignment="Center">
          <TextBlock Text="&#x26A1;" Foreground="{StaticResource AccentCyan}" FontSize="14" VerticalAlignment="Center"/>
          <TextBlock Text="APEXPULSE 11" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="Bold" FontSize="12" Margin="9,0,0,0" VerticalAlignment="Center" Foreground="{StaticResource TextPrimary}"/>
          <Border Background="{StaticResource AccentGreenSoft}" CornerRadius="3" Padding="6,2" Margin="10,0,0,0" VerticalAlignment="Center">
            <TextBlock Text="v2.0" FontSize="9" FontWeight="Bold" Foreground="{StaticResource AccentGreen}"/>
          </Border>
        </StackPanel>
        <StackPanel Grid.Column="2" Orientation="Horizontal">
          <Button x:Name="MinButton" Style="{StaticResource WindowControlButtonStyle}" Content="&#xE949;" ToolTip="Minimize"/>
          <Button x:Name="MaxButton" Style="{StaticResource WindowControlButtonStyle}" Content="&#xE739;" ToolTip="Maximize"/>
          <Button x:Name="CloseButton" Style="{StaticResource CloseControlButtonStyle}" Content="&#xE8BB;" ToolTip="Close"/>
        </StackPanel>
      </Grid>

      <!-- Main: sidebar + content -->
      <Grid Grid.Row="2">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="218"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Border Grid.Column="0" Background="{StaticResource BgPrimary}" BorderBrush="{StaticResource DividerBrush}" BorderThickness="0,0,1,0">
          <DockPanel LastChildFill="False">
            <StackPanel DockPanel.Dock="Top" Margin="12,14,12,0">
              <TextBlock Text="NAVIGATION" Style="{StaticResource SectionLabel}" Margin="8,0,0,8"/>
              <RadioButton x:Name="NavDashboard" Style="{StaticResource NavRadio}" GroupName="Nav" IsChecked="True">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE80F;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,12,0" VerticalAlignment="Center" Foreground="{StaticResource AccentCyan}"/>
                  <TextBlock Text="Dashboard" VerticalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavPrivacy" Style="{StaticResource NavRadio}" GroupName="Nav">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE72E;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,12,0" VerticalAlignment="Center" Foreground="{StaticResource AccentCyan}"/>
                  <TextBlock Text="Privacy Shield" VerticalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavRollback" Style="{StaticResource NavRadio}" GroupName="Nav">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE7A7;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,12,0" VerticalAlignment="Center" Foreground="{StaticResource AccentCyan}"/>
                  <TextBlock Text="Rollback" VerticalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
              <RadioButton x:Name="NavReports" Style="{StaticResource NavRadio}" GroupName="Nav">
                <StackPanel Orientation="Horizontal">
                  <TextBlock Text="&#xE9F9;" FontFamily="Segoe MDL2 Assets" FontSize="14" Margin="0,0,12,0" VerticalAlignment="Center" Foreground="{StaticResource AccentCyan}"/>
                  <TextBlock Text="Reports" VerticalAlignment="Center"/>
                </StackPanel>
              </RadioButton>
            </StackPanel>
            <Border DockPanel.Dock="Bottom" Margin="12,12,12,14" Padding="10,8" Background="{StaticResource BgSurface}" CornerRadius="6">
              <StackPanel>
                <TextBlock Text="SESSION" Style="{StaticResource SectionLabel}" Margin="0,0,0,4"/>
                <TextBlock x:Name="AdminStatus" FontSize="10" Foreground="{StaticResource TextMuted}" TextWrapping="Wrap"/>
              </StackPanel>
            </Border>
          </DockPanel>
        </Border>

        <!-- Content area -->
        <Grid Grid.Column="1" Background="{StaticResource BgPrimary}" ClipToBounds="True">
          <!-- Notification banner (slides down) -->
          <Border x:Name="NotifyBanner" VerticalAlignment="Top" Background="{StaticResource BgElevated}" BorderBrush="{StaticResource AccentCyan}" BorderThickness="0,0,0,2" Padding="22,12" Visibility="Collapsed" Panel.ZIndex="50">
            <Border.RenderTransform>
              <TranslateTransform x:Name="NotifyTransform" Y="-60"/>
            </Border.RenderTransform>
            <StackPanel Orientation="Horizontal">
              <TextBlock x:Name="NotifyIcon" Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="13" Foreground="{StaticResource AccentCyan}" VerticalAlignment="Center" Margin="0,0,10,0"/>
              <TextBlock x:Name="NotifyText" Foreground="{StaticResource TextPrimary}" FontSize="12" VerticalAlignment="Center"/>
            </StackPanel>
          </Border>

          <!-- Dashboard -->
          <Grid x:Name="DashboardPanel" Margin="24,18,24,18">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Margin="0,0,0,18">
              <TextBlock Text="Dashboard" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold" FontSize="24" Foreground="{StaticResource TextPrimary}"/>
              <TextBlock Text="Pick a profile. Safe is recommended for most setups; Competitive adds privacy and noise reduction." Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,4,0,0"/>
            </StackPanel>

            <Grid Grid.Row="1">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="16"/>
                <ColumnDefinition Width="*"/>
              </Grid.ColumnDefinitions>

              <!-- Safe card -->
              <RadioButton Grid.Column="0" x:Name="SafeProfile" Style="{StaticResource ProfileCard}" GroupName="Profile" IsChecked="True">
                <StackPanel x:Name="SafeCardContent" Opacity="0">
                  <StackPanel.RenderTransform>
                    <TranslateTransform x:Name="SafeCardTranslate" Y="8"/>
                  </StackPanel.RenderTransform>
                  <StackPanel Orientation="Horizontal">
                    <Border Background="{StaticResource AccentGreenSoft}" CornerRadius="4" Padding="6,2">
                      <TextBlock Text="RECOMMENDED" FontSize="9" FontWeight="Bold" Foreground="{StaticResource AccentGreen}"/>
                    </Border>
                  </StackPanel>
                  <TextBlock Text="Safe Performance" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold" FontSize="20" Foreground="{StaticResource TextPrimary}" Margin="0,12,0,4"/>
                  <TextBlock Text="Zero-compromise gaming tweaks with full Windows compatibility." TextWrapping="Wrap" Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,0,0,16"/>
                  <StackPanel Margin="0,0,0,16">
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentGreen}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="Game Mode + HAGS scheduling" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentGreen}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="Ultimate Performance power plan" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentGreen}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="MMCSS tuning + exclusive fullscreen" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentGreen}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="GameDVR + power throttling off" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentGreen}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="Gaming essentials via WinGet" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                  </StackPanel>
                  <Button x:Name="ApplySafeButton" Style="{StaticResource SafeApplyButton}" Content="Apply Safe" HorizontalAlignment="Stretch"/>
                </StackPanel>
              </RadioButton>

              <!-- Competitive card -->
              <RadioButton Grid.Column="2" x:Name="CompetitiveProfile" Style="{StaticResource ProfileCard}" GroupName="Profile">
                <StackPanel x:Name="CompetitiveCardContent" Opacity="0">
                  <StackPanel.RenderTransform>
                    <TranslateTransform x:Name="CompetitiveCardTranslate" Y="8"/>
                  </StackPanel.RenderTransform>
                  <StackPanel Orientation="Horizontal">
                    <Border Background="{StaticResource AccentCyanSoft}" CornerRadius="4" Padding="6,2">
                      <TextBlock Text="ESPORTS" FontSize="9" FontWeight="Bold" Foreground="{StaticResource AccentCyan}"/>
                    </Border>
                  </StackPanel>
                  <TextBlock Text="Competitive" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold" FontSize="20" Foreground="{StaticResource TextPrimary}" Margin="0,12,0,4"/>
                  <TextBlock Text="Adds privacy shield, background-noise reductions and latency-oriented tweaks." TextWrapping="Wrap" Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,0,0,16"/>
                  <StackPanel Margin="0,0,0,16">
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentCyan}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="Everything in Safe Performance" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentCyan}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="Full Privacy Shield (5 tweaks)" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentCyan}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="SysMain + WSearch + DiagTrack tuned" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentCyan}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="Visual effects + toast suppression" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                    <StackPanel Orientation="Horizontal" Margin="0,3">
                      <TextBlock Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="10" Foreground="{StaticResource AccentCyan}" Margin="0,0,10,0" VerticalAlignment="Center"/>
                      <TextBlock Text="Consumer suggestion reduction" Foreground="{StaticResource TextPrimary}" FontSize="12"/>
                    </StackPanel>
                  </StackPanel>
                  <Button x:Name="ApplyCompetitiveButton" Style="{StaticResource PrimaryButton}" Content="Apply Competitive" HorizontalAlignment="Stretch"/>
                </StackPanel>
              </RadioButton>
            </Grid>

            <!-- Status chips + analyze -->
            <Border Grid.Row="2" Background="{StaticResource BgSurface}" CornerRadius="8" Padding="16,12" Margin="0,16,0,0">
              <Grid>
                <Grid.ColumnDefinitions>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="*"/>
                  <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <StackPanel Grid.Column="0">
                  <TextBlock Text="POWER" Style="{StaticResource SectionLabel}"/>
                  <TextBlock x:Name="PowerStatus" Text="Idle" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="1">
                  <TextBlock Text="GPU" Style="{StaticResource SectionLabel}"/>
                  <TextBlock x:Name="GpuStatus" Text="Idle" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="2">
                  <TextBlock Text="NOISE" Style="{StaticResource SectionLabel}"/>
                  <TextBlock x:Name="NoiseStatus" Text="Idle" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="3">
                  <TextBlock Text="LATENCY" Style="{StaticResource SectionLabel}"/>
                  <TextBlock x:Name="LatencyStatus" Text="Idle" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" Margin="0,2,0,0"/>
                </StackPanel>
                <StackPanel Grid.Column="4">
                  <TextBlock Text="PRIVACY" Style="{StaticResource SectionLabel}"/>
                  <TextBlock x:Name="PrivacyStatusCard" Text="Idle" FontSize="13" FontWeight="SemiBold" Foreground="{StaticResource TextPrimary}" Margin="0,2,0,0"/>
                </StackPanel>
                <Button Grid.Column="5" x:Name="AnalyzeButton" Style="{StaticResource SecondaryButton}" Content="Analyze (no changes)" VerticalAlignment="Center"/>
              </Grid>
            </Border>

            <!-- Output console -->
            <Border Grid.Row="3" Background="{StaticResource BgSurface}" CornerRadius="8" Margin="0,12,0,0">
              <DockPanel>
                <Border DockPanel.Dock="Top" Background="{StaticResource BgElevated}" Padding="14,8" CornerRadius="8,8,0,0">
                  <TextBlock Text="OUTPUT" Style="{StaticResource SectionLabel}"/>
                </Border>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                  <TextBox x:Name="OutputBox" Style="{StaticResource ConsoleTextBox}"/>
                </ScrollViewer>
              </DockPanel>
            </Border>
          </Grid>

          <!-- Privacy Shield -->
          <Grid x:Name="PrivacyPanel" Margin="24,18,24,18" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Margin="0,0,0,18">
              <TextBlock Text="Privacy Shield" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold" FontSize="24" Foreground="{StaticResource TextPrimary}"/>
              <TextBlock Text="Control Windows telemetry, tracking and data collection. Each setting can be toggled individually before applying." Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,4,0,0" TextWrapping="Wrap"/>
            </StackPanel>

            <Border Grid.Row="1" Background="{StaticResource BgSurface}" CornerRadius="8">
              <StackPanel>
                <Border Padding="20,14" BorderBrush="{StaticResource DividerBrush}" BorderThickness="0,0,0,1">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,16,0">
                      <TextBlock Text="Tailored Experiences" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="13"/>
                      <TextBlock Text="Prevents Windows from using diagnostic data to personalize tips and recommendations." Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <ToggleButton Grid.Column="1" x:Name="PrivTailored" Style="{StaticResource PillToggle}" IsChecked="True" VerticalAlignment="Center"/>
                  </Grid>
                </Border>

                <Border Padding="20,14" BorderBrush="{StaticResource DividerBrush}" BorderThickness="0,0,0,1">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,16,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="Diagnostic Data Upload" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
                        <Border Background="{StaticResource AdminAmberSoft}" CornerRadius="3" Padding="6,1" Margin="10,0,0,0" VerticalAlignment="Center">
                          <TextBlock Text="ADMIN" FontSize="9" FontWeight="Bold" Foreground="{StaticResource AdminAmber}"/>
                        </Border>
                      </StackPanel>
                      <TextBlock Text="Sets telemetry to security-only level. Requires elevation." Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <ToggleButton Grid.Column="1" x:Name="PrivDiagnostic" Style="{StaticResource PillToggle}" IsChecked="True" VerticalAlignment="Center"/>
                  </Grid>
                </Border>

                <Border Padding="20,14" BorderBrush="{StaticResource DividerBrush}" BorderThickness="0,0,0,1">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,16,0">
                      <TextBlock Text="Cortana &amp; Cloud Search" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="13"/>
                      <TextBlock Text="Disables Bing web results in Start Menu search and Cortana consent." Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <ToggleButton Grid.Column="1" x:Name="PrivCortana" Style="{StaticResource PillToggle}" IsChecked="True" VerticalAlignment="Center"/>
                  </Grid>
                </Border>

                <Border Padding="20,14" BorderBrush="{StaticResource DividerBrush}" BorderThickness="0,0,0,1">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,16,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="Location Tracking" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
                        <Border Background="{StaticResource AdminAmberSoft}" CornerRadius="3" Padding="6,1" Margin="10,0,0,0" VerticalAlignment="Center">
                          <TextBlock Text="ADMIN" FontSize="9" FontWeight="Bold" Foreground="{StaticResource AdminAmber}"/>
                        </Border>
                      </StackPanel>
                      <TextBlock Text="Denies location access system-wide and per-user." Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <ToggleButton Grid.Column="1" x:Name="PrivLocation" Style="{StaticResource PillToggle}" IsChecked="True" VerticalAlignment="Center"/>
                  </Grid>
                </Border>

                <Border Padding="20,14">
                  <Grid>
                    <Grid.ColumnDefinitions>
                      <ColumnDefinition Width="*"/>
                      <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <StackPanel Grid.Column="0" Margin="0,0,16,0">
                      <StackPanel Orientation="Horizontal">
                        <TextBlock Text="Activity History" Foreground="{StaticResource TextPrimary}" FontWeight="SemiBold" FontSize="13" VerticalAlignment="Center"/>
                        <Border Background="{StaticResource AdminAmberSoft}" CornerRadius="3" Padding="6,1" Margin="10,0,0,0" VerticalAlignment="Center">
                          <TextBlock Text="ADMIN" FontSize="9" FontWeight="Bold" Foreground="{StaticResource AdminAmber}"/>
                        </Border>
                      </StackPanel>
                      <TextBlock Text="Stops Windows from collecting and uploading activity history." Foreground="{StaticResource TextMuted}" FontSize="11" Margin="0,4,0,0" TextWrapping="Wrap"/>
                    </StackPanel>
                    <ToggleButton Grid.Column="1" x:Name="PrivActivity" Style="{StaticResource PillToggle}" IsChecked="True" VerticalAlignment="Center"/>
                  </Grid>
                </Border>
              </StackPanel>
            </Border>

            <Grid Grid.Row="2" Margin="0,16,0,0">
              <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
              </Grid.RowDefinitions>
              <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,12">
                <Button x:Name="PrivScanButton" Style="{StaticResource SecondaryButton}" Content="Scan Privacy" Margin="0,0,10,0"/>
                <Button x:Name="PrivApplyButton" Style="{StaticResource PrimaryButton}" Content="Apply Privacy Shield"/>
              </StackPanel>
              <Border Grid.Row="1" Background="{StaticResource BgSurface}" CornerRadius="8">
                <DockPanel>
                  <Border DockPanel.Dock="Top" Background="{StaticResource BgElevated}" Padding="14,8" CornerRadius="8,8,0,0">
                    <TextBlock Text="OUTPUT" Style="{StaticResource SectionLabel}"/>
                  </Border>
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <TextBox x:Name="PrivacyOutputBox" Style="{StaticResource ConsoleTextBox}"/>
                  </ScrollViewer>
                </DockPanel>
              </Border>
            </Grid>
          </Grid>

          <!-- Rollback Center -->
          <Grid x:Name="RollbackPanel" Margin="24,18,24,18" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
              <RowDefinition Height="Auto"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Margin="0,0,0,12">
              <TextBlock Text="Rollback Center" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold" FontSize="24" Foreground="{StaticResource TextPrimary}"/>
              <TextBlock Text="Restore your system to a previous state from any ApexPulse backup." Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,4,0,0"/>
              <TextBlock x:Name="BackupDirLabel" Foreground="{StaticResource TextSubtle}" FontSize="11" FontFamily="Cascadia Mono, Consolas" Margin="0,2,0,0"/>
            </StackPanel>

            <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,12">
              <Button x:Name="CreateBackupNowButton" Style="{StaticResource SafeApplyButton}" Content="Create Backup Now" Margin="0,0,10,0"/>
              <Button x:Name="RefreshBackupsButton" Style="{StaticResource SecondaryButton}" Content="Refresh"/>
            </StackPanel>

            <Grid Grid.Row="2">
              <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="14"/>
                <ColumnDefinition Width="320"/>
              </Grid.ColumnDefinitions>

              <Border Grid.Column="0" Background="{StaticResource BgSurface}" CornerRadius="8" ClipToBounds="True">
                <DataGrid x:Name="BackupList">
                  <DataGrid.Columns>
                    <DataGridTextColumn Header="TIMESTAMP" Binding="{Binding Name}" Width="220">
                      <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                          <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
                          <Setter Property="FontSize" Value="11"/>
                          <Setter Property="VerticalAlignment" Value="Center"/>
                          <Setter Property="Foreground" Value="#e8eaed"/>
                        </Style>
                      </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTextColumn Header="PROFILE" Binding="{Binding Profile}" Width="*">
                      <DataGridTextColumn.ElementStyle>
                        <Style TargetType="TextBlock">
                          <Setter Property="FontSize" Value="12"/>
                          <Setter Property="VerticalAlignment" Value="Center"/>
                          <Setter Property="Foreground" Value="#e8eaed"/>
                        </Style>
                      </DataGridTextColumn.ElementStyle>
                    </DataGridTextColumn>
                    <DataGridTemplateColumn Header="ACTION" Width="140">
                      <DataGridTemplateColumn.CellTemplate>
                        <DataTemplate>
                          <Button Tag="RestoreRow" Content="Restore" Style="{StaticResource GridRowButton}"/>
                        </DataTemplate>
                      </DataGridTemplateColumn.CellTemplate>
                    </DataGridTemplateColumn>
                  </DataGrid.Columns>
                </DataGrid>
              </Border>

              <Border Grid.Column="2" Background="{StaticResource BgSurface}" CornerRadius="8">
                <DockPanel>
                  <Border DockPanel.Dock="Top" Background="{StaticResource BgElevated}" Padding="14,8" CornerRadius="8,8,0,0">
                    <TextBlock Text="BACKUP DETAILS" Style="{StaticResource SectionLabel}"/>
                  </Border>
                  <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <TextBox x:Name="BackupDetailBox" Style="{StaticResource ConsoleTextBox}"/>
                  </ScrollViewer>
                </DockPanel>
              </Border>
            </Grid>

            <Border Grid.Row="3" Margin="0,14,0,0" Background="{StaticResource BgSurface}" CornerRadius="8" Padding="14,10">
              <StackPanel Orientation="Horizontal">
                <TextBlock Text="&#xE946;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{StaticResource AccentCyan}" VerticalAlignment="Center" Margin="0,0,10,0"/>
                <TextBlock Text="Every Apply run creates a backup automatically. Click Restore on a row to revert." Foreground="{StaticResource TextMuted}" FontSize="11" VerticalAlignment="Center"/>
              </StackPanel>
            </Border>
          </Grid>

          <!-- Reports -->
          <Grid x:Name="ReportsPanel" Margin="24,18,24,18" Visibility="Collapsed">
            <Grid.RowDefinitions>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="Auto"/>
              <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Margin="0,0,0,12">
              <TextBlock Text="Reports" FontFamily="Segoe UI Variable Display, Segoe UI" FontWeight="SemiBold" FontSize="24" Foreground="{StaticResource TextPrimary}"/>
              <TextBlock Text="Timestamped HTML and JSON reports from every run." Foreground="{StaticResource TextMuted}" FontSize="12" Margin="0,4,0,0"/>
              <TextBlock x:Name="ReportDirLabel" Foreground="{StaticResource TextSubtle}" FontSize="11" FontFamily="Cascadia Mono, Consolas" Margin="0,2,0,0"/>
            </StackPanel>

            <StackPanel Grid.Row="1" Orientation="Horizontal" Margin="0,0,0,12">
              <Button x:Name="RefreshReportsButton" Style="{StaticResource SecondaryButton}" Content="Refresh"/>
            </StackPanel>

            <Border Grid.Row="2" Background="{StaticResource BgSurface}" CornerRadius="8" ClipToBounds="True">
              <DataGrid x:Name="ReportsList">
                <DataGrid.Columns>
                  <DataGridTextColumn Header="REPORT" Binding="{Binding DisplayName}" Width="*">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock">
                        <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
                        <Setter Property="FontSize" Value="11"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                        <Setter Property="Foreground" Value="#e8eaed"/>
                      </Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTextColumn Header="CREATED" Binding="{Binding Created}" Width="180">
                    <DataGridTextColumn.ElementStyle>
                      <Style TargetType="TextBlock">
                        <Setter Property="FontFamily" Value="Cascadia Mono, Consolas"/>
                        <Setter Property="FontSize" Value="11"/>
                        <Setter Property="VerticalAlignment" Value="Center"/>
                        <Setter Property="Foreground" Value="#e8eaed"/>
                      </Style>
                    </DataGridTextColumn.ElementStyle>
                  </DataGridTextColumn>
                  <DataGridTemplateColumn Header="ACTION" Width="140">
                    <DataGridTemplateColumn.CellTemplate>
                      <DataTemplate>
                        <Button Tag="OpenRow" Content="Open" Style="{StaticResource GridRowOpenButton}"/>
                      </DataTemplate>
                    </DataGridTemplateColumn.CellTemplate>
                  </DataGridTemplateColumn>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </Grid>
        </Grid>
      </Grid>

      <!-- Status bar -->
      <Border Grid.Row="3" Background="{StaticResource BgSurface}" BorderBrush="{StaticResource DividerBrush}" BorderThickness="0,1,0,0">
        <Grid Margin="14,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="Auto"/>
          </Grid.ColumnDefinitions>
          <TextBlock Grid.Column="0" x:Name="StatusText" Text="Ready." Foreground="{StaticResource TextMuted}" FontSize="11" VerticalAlignment="Center"/>
          <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
            <TextBlock Text="LAST RUN" Style="{StaticResource SectionLabel}" VerticalAlignment="Center" Margin="0,0,8,0"/>
            <TextBlock x:Name="LastRunText" Text="—" Foreground="{StaticResource TextPrimary}" FontFamily="Cascadia Mono, Consolas" FontSize="11" VerticalAlignment="Center"/>
          </StackPanel>
        </Grid>
      </Border>
    </Grid>
  </Border>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # --- Find controls ---
    $minButton            = $window.FindName("MinButton")
    $maxButton            = $window.FindName("MaxButton")
    $closeButton          = $window.FindName("CloseButton")
    $loadingBar           = $window.FindName("LoadingBar")
    $notifyBanner         = $window.FindName("NotifyBanner")
    $notifyIcon           = $window.FindName("NotifyIcon")
    $notifyText           = $window.FindName("NotifyText")
    $notifyTransform      = $window.FindName("NotifyTransform")

    $navDashboard         = $window.FindName("NavDashboard")
    $navPrivacy           = $window.FindName("NavPrivacy")
    $navRollback          = $window.FindName("NavRollback")
    $navReports           = $window.FindName("NavReports")

    $dashboardPanel       = $window.FindName("DashboardPanel")
    $privacyPanel         = $window.FindName("PrivacyPanel")
    $rollbackPanel        = $window.FindName("RollbackPanel")
    $reportsPanel         = $window.FindName("ReportsPanel")

    $adminStatusLabel     = $window.FindName("AdminStatus")
    $statusText           = $window.FindName("StatusText")
    $lastRunText          = $window.FindName("LastRunText")

    $safeProfile          = $window.FindName("SafeProfile")
    $competitiveProfile   = $window.FindName("CompetitiveProfile")
    $safeCardContent      = $window.FindName("SafeCardContent")
    $competitiveCardContent = $window.FindName("CompetitiveCardContent")
    $safeCardTranslate    = $window.FindName("SafeCardTranslate")
    $competitiveCardTranslate = $window.FindName("CompetitiveCardTranslate")

    $analyzeButton        = $window.FindName("AnalyzeButton")
    $applySafeButton      = $window.FindName("ApplySafeButton")
    $applyCompetitiveButton = $window.FindName("ApplyCompetitiveButton")
    $outputBox            = $window.FindName("OutputBox")

    $powerStatus          = $window.FindName("PowerStatus")
    $gpuStatus            = $window.FindName("GpuStatus")
    $noiseStatus          = $window.FindName("NoiseStatus")
    $latencyStatus        = $window.FindName("LatencyStatus")
    $privacyStatusCard    = $window.FindName("PrivacyStatusCard")

    $privTailored         = $window.FindName("PrivTailored")
    $privDiagnostic       = $window.FindName("PrivDiagnostic")
    $privCortana          = $window.FindName("PrivCortana")
    $privLocation         = $window.FindName("PrivLocation")
    $privActivity         = $window.FindName("PrivActivity")
    $privScanButton       = $window.FindName("PrivScanButton")
    $privApplyButton      = $window.FindName("PrivApplyButton")
    $privacyOutputBox     = $window.FindName("PrivacyOutputBox")

    $backupDirLabel       = $window.FindName("BackupDirLabel")
    $backupList           = $window.FindName("BackupList")
    $backupDetailBox      = $window.FindName("BackupDetailBox")
    $refreshBackups       = $window.FindName("RefreshBackupsButton")
    $createBackupNow      = $window.FindName("CreateBackupNowButton")

    $reportsList          = $window.FindName("ReportsList")
    $refreshReports       = $window.FindName("RefreshReportsButton")
    $reportDirLabel       = $window.FindName("ReportDirLabel")

    # --- Window chrome buttons ---
    $minButton.Add_Click({ $window.WindowState = [System.Windows.WindowState]::Minimized })
    $maxButton.Add_Click({
        if ($window.WindowState -eq [System.Windows.WindowState]::Maximized) {
            $window.WindowState = [System.Windows.WindowState]::Normal
            $maxButton.Content = [char]0xE739
        } else {
            $window.WindowState = [System.Windows.WindowState]::Maximized
            $maxButton.Content = [char]0xE923
        }
    })
    $closeButton.Add_Click({ $window.Close() })

    # --- Admin indicator ---
    $isAdmin = Test-ApexPulseAdmin
    $adminStatusLabel.Text = if ($isAdmin) { "Running as Administrator" } else { "Standard user (some tweaks need elevation)" }

    # --- Status bar helper with fade-in animation ---
    $setStatus = {
        param([string]$msg)
        $statusText.Text = $msg
        $anim = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(200)))
        $anim.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut }
        $statusText.BeginAnimation([System.Windows.Controls.TextBlock]::OpacityProperty, $anim)
    }

    $setLastRun = {
        $lastRunText.Text = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    }

    # --- Loading bar control ---
    $showLoading = {
        $loadingBar.Visibility = [System.Windows.Visibility]::Visible
        $loadingBar.IsIndeterminate = $true
    }
    $hideLoading = {
        $loadingBar.IsIndeterminate = $false
        $loadingBar.Visibility = [System.Windows.Visibility]::Hidden
    }

    # --- Notification banner with slide-down + auto-dismiss ---
    $script:NotifyTimer = $null
    $showNotify = {
        param([string]$msg, [string]$kind = "info")
        $notifyText.Text = $msg
        switch ($kind) {
            "success" {
                $notifyBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#a3e635")
                $notifyIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#a3e635")
                $notifyIcon.Text = [char]0xE73E
            }
            "error" {
                $notifyBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#ff4757")
                $notifyIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#ff4757")
                $notifyIcon.Text = [char]0xEA39
            }
            default {
                $notifyBanner.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#00d4ff")
                $notifyIcon.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFrom("#00d4ff")
                $notifyIcon.Text = [char]0xE946
            }
        }
        $notifyBanner.Visibility = [System.Windows.Visibility]::Visible
        $notifyBanner.Opacity = 0

        $slide = New-Object System.Windows.Media.Animation.DoubleAnimation(-60.0, 0.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $slide.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut }
        $notifyTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slide)

        $fade = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $notifyBanner.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $fade)

        if ($script:NotifyTimer) { $script:NotifyTimer.Stop() }
        $script:NotifyTimer = New-Object System.Windows.Threading.DispatcherTimer
        $script:NotifyTimer.Interval = [TimeSpan]::FromSeconds(4)
        $script:NotifyTimer.Add_Tick({
            $script:NotifyTimer.Stop()
            $slideOut = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, -60.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
            $slideOut.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseIn }
            $notifyTransform.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slideOut)
            $fadeOut = New-Object System.Windows.Media.Animation.DoubleAnimation(1.0, 0.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
            $fadeOut.Completed += { $notifyBanner.Visibility = [System.Windows.Visibility]::Collapsed }
            $notifyBanner.BeginAnimation([System.Windows.Controls.Border]::OpacityProperty, $fadeOut)
        })
        $script:NotifyTimer.Start()
    }

    # --- Card entry animation: opacity 0->1 + translateY 8->0, with stagger ---
    $animateCardsIn = {
        $safeCardContent.Opacity = 0
        $safeCardTranslate.Y = 8
        $competitiveCardContent.Opacity = 0
        $competitiveCardTranslate.Y = 8

        $easeCubic = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut }

        $fadeSafe = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $fadeSafe.EasingFunction = $easeCubic
        $slideSafe = New-Object System.Windows.Media.Animation.DoubleAnimation(8.0, 0.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
        $slideSafe.EasingFunction = $easeCubic
        $safeCardContent.BeginAnimation([System.Windows.Controls.StackPanel]::OpacityProperty, $fadeSafe)
        $safeCardTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slideSafe)

        $compTimer = New-Object System.Windows.Threading.DispatcherTimer
        $compTimer.Interval = [TimeSpan]::FromMilliseconds(50)
        $compTimer.Add_Tick({
            $compTimer.Stop()
            $fadeC = New-Object System.Windows.Media.Animation.DoubleAnimation(0.0, 1.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
            $fadeC.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut }
            $slideC = New-Object System.Windows.Media.Animation.DoubleAnimation(8.0, 0.0, [System.Windows.Duration]::new([TimeSpan]::FromMilliseconds(220)))
            $slideC.EasingFunction = New-Object System.Windows.Media.Animation.CubicEase -Property @{ EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut }
            $competitiveCardContent.BeginAnimation([System.Windows.Controls.StackPanel]::OpacityProperty, $fadeC)
            $competitiveCardTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::YProperty, $slideC)
        })
        $compTimer.Start()
    }

    # --- Navigation ---
    $switchPanel = {
        param([string]$target)
        $dashboardPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $privacyPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $rollbackPanel.Visibility = [System.Windows.Visibility]::Collapsed
        $reportsPanel.Visibility = [System.Windows.Visibility]::Collapsed

        switch ($target) {
            "Dashboard" {
                $dashboardPanel.Visibility = [System.Windows.Visibility]::Visible
                & $animateCardsIn
                & $setStatus "Dashboard"
            }
            "Privacy" {
                $privacyPanel.Visibility = [System.Windows.Visibility]::Visible
                & $setStatus "Privacy Shield"
            }
            "Rollback" {
                $rollbackPanel.Visibility = [System.Windows.Visibility]::Visible
                & $setStatus "Rollback Center"
            }
            "Reports" {
                $reportsPanel.Visibility = [System.Windows.Visibility]::Visible
                & $setStatus "Reports"
            }
        }
    }

    $navDashboard.Add_Checked({ & $switchPanel "Dashboard" })
    $navPrivacy.Add_Checked({ & $switchPanel "Privacy" })
    $navRollback.Add_Checked({
        & $switchPanel "Rollback"
        & $loadBackups
    })
    $navReports.Add_Checked({
        & $switchPanel "Reports"
        & $loadReports
    })

    # --- Dashboard: render report ---
    $renderReport = {
        param($report)

        $lines = @()
        $lines += "$($report.Product) v$($report.Version)"
        $lines += "Profile: $($report.Profile)"
        $lines += "Mode: $($report.Mode)"
        $lines += "Report: $($report.ReportPath)"
        if ($report.PSObject.Properties.Name -contains "HtmlReportPath") {
            $lines += "HTML Report: $($report.HtmlReportPath)"
        }
        if ($report.BackupPath) { $lines += "Backup: $($report.BackupPath)" }
        $lines += ""
        foreach ($item in $report.Results) {
            $lines += "[{0}] {1} :: {2}" -f $item.Status, $item.Name, $item.Detail
        }
        if ($report.RebootRequired) {
            $lines += ""
            $lines += "Reboot recommended."
        }

        $outputBox.Text = $lines -join [Environment]::NewLine

        $powerItem = $report.Results | Where-Object { $_.Group -eq "Power" } | Select-Object -First 1
        $gpuItem = $report.Results | Where-Object { $_.Group -eq "GPU" } | Select-Object -First 1
        $noiseItem = $report.Results | Where-Object { $_.Group -eq "Background Noise" } | Select-Object -First 1
        $latencyItem = $report.Results | Where-Object { $_.Group -eq "Latency" } | Select-Object -First 1
        $privacyItem = $report.Results | Where-Object { $_.Group -eq "Privacy" } | Select-Object -First 1

        $powerStatus.Text = if ($powerItem) { $powerItem.Status } else { "N/A" }
        $gpuStatus.Text = if ($gpuItem) { $gpuItem.Status } else { "N/A" }
        $noiseStatus.Text = if ($noiseItem) { $noiseItem.Status } else { "N/A" }
        $latencyStatus.Text = if ($latencyItem) { $latencyItem.Status } else { "N/A" }
        $privacyStatusCard.Text = if ($privacyItem) { $privacyItem.Status } else { "N/A" }
    }

    $getProfile = {
        if ($competitiveProfile.IsChecked) { "Competitive" } else { "Safe" }
    }

    $analyzeButton.Add_Click({
        try {
            & $setStatus "Analyzing..."
            $outputBox.Text = "Analyzing..."
            [Windows.Forms.Application]::DoEvents() 2>$null
            $report = Invoke-ApexPulseProfile -SelectedProfile (& $getProfile) -SelectedMode "Analyze"
            & $renderReport $report
            & $setLastRun
            & $setStatus "Analyze complete."
            & $showNotify "Analyze complete" "success"
        } catch {
            $outputBox.Text = $_.Exception.Message
            & $setStatus "Analyze failed."
            & $showNotify $_.Exception.Message "error"
        }
    })

    $runApply = {
        param([string]$profileName)
        try {
            $safeProfile.IsChecked = ($profileName -eq "Safe")
            $competitiveProfile.IsChecked = ($profileName -eq "Competitive")
            $applySafeButton.IsEnabled = $false
            $applyCompetitiveButton.IsEnabled = $false
            & $showLoading
            & $setStatus "Applying $profileName optimizations..."
            $outputBox.Text = "Creating backup and restore point, then applying optimizations..."
            [Windows.Forms.Application]::DoEvents() 2>$null
            $report = Invoke-ApexPulseProfile -SelectedProfile $profileName -SelectedMode "Apply"
            & $renderReport $report
            & $setLastRun
            & $hideLoading
            $applySafeButton.IsEnabled = $true
            $applyCompetitiveButton.IsEnabled = $true
            & $setStatus "$profileName apply complete."
            & $showNotify "$profileName profile applied" "success"
        } catch {
            $outputBox.Text = $_.Exception.Message
            & $hideLoading
            $applySafeButton.IsEnabled = $true
            $applyCompetitiveButton.IsEnabled = $true
            & $setStatus "Apply failed."
            & $showNotify $_.Exception.Message "error"
        }
    }

    $applySafeButton.Add_Click({ & $runApply "Safe" })
    $applyCompetitiveButton.Add_Click({ & $runApply "Competitive" })

    # --- Privacy Shield ---
    $privacyCheckboxMap = @{
        "privacy.tailored-experiences" = $privTailored
        "privacy.diagnostic-data"     = $privDiagnostic
        "privacy.cortana-search"      = $privCortana
        "privacy.location-tracking"   = $privLocation
        "privacy.activity-history"    = $privActivity
    }

    $privScanButton.Add_Click({
        try {
            & $setStatus "Scanning privacy settings..."
            $privacyOutputBox.Text = "Scanning privacy settings..."
            [Windows.Forms.Application]::DoEvents() 2>$null
            $allTweaks = Get-ApexPulseTweaks
            $privacyIds = Get-ApexPulsePrivacyTweakIds
            $privTweaks = $allTweaks | Where-Object { $privacyIds -contains $_.Id }
            $lines = @()
            $admin = Test-ApexPulseAdmin
            foreach ($tweak in $privTweaks) {
                if ($tweak.RequiresAdmin -and -not $admin) {
                    $lines += "[NeedsAdmin] $($tweak.Name) - Requires elevation."
                } else {
                    $detail = & $tweak.Detect
                    $lines += "[$detail] $($tweak.Name)"
                }
            }
            $privacyOutputBox.Text = $lines -join [Environment]::NewLine
            & $setStatus "Privacy scan complete."
        } catch {
            $privacyOutputBox.Text = $_.Exception.Message
            & $setStatus "Privacy scan failed."
            & $showNotify $_.Exception.Message "error"
        }
    })

    $privApplyButton.Add_Click({
        try {
            $allTweaks = Get-ApexPulseTweaks
            $privacyIds = Get-ApexPulsePrivacyTweakIds
            $selectedTweaks = @()
            foreach ($id in $privacyIds) {
                $cb = $privacyCheckboxMap[$id]
                if ($cb -and $cb.IsChecked) {
                    $tweak = $allTweaks | Where-Object { $_.Id -eq $id }
                    if ($tweak) { $selectedTweaks += $tweak }
                }
            }

            if ($selectedTweaks.Count -eq 0) {
                $privacyOutputBox.Text = "No privacy tweaks selected."
                & $showNotify "No privacy tweaks selected" "info"
                return
            }

            & $showLoading
            & $setStatus "Applying Privacy Shield..."
            $privacyOutputBox.Text = "Creating backup and applying privacy shield..."
            [Windows.Forms.Application]::DoEvents() 2>$null

            $admin = Test-ApexPulseAdmin
            $backup = $null
            if ($admin) {
                $backup = New-ApexPulseBackup -Tweaks $selectedTweaks -SelectedProfile "Privacy"
            }

            $lines = @()
            if ($backup) { $lines += "Backup: $backup" }
            $lines += ""

            $privResults = @()
            foreach ($tweak in $selectedTweaks) {
                try {
                    if ($tweak.RequiresAdmin -and -not $admin) {
                        $lines += "[NeedsAdmin] $($tweak.Name) - Requires elevation."
                        $privResults += [pscustomobject]@{ Id = $tweak.Id; Name = $tweak.Name; Group = $tweak.Group; Status = "NeedsAdmin"; Detail = "Requires elevation."; RebootRequired = $false }
                        continue
                    }
                    $detail = & $tweak.Apply
                    $lines += "[Applied] $($tweak.Name) - $detail"
                    $privResults += [pscustomobject]@{ Id = $tweak.Id; Name = $tweak.Name; Group = $tweak.Group; Status = "Applied"; Detail = $detail; RebootRequired = $false }
                } catch {
                    $lines += "[Failed] $($tweak.Name) - $($_.Exception.Message)"
                    $privResults += [pscustomobject]@{ Id = $tweak.Id; Name = $tweak.Name; Group = $tweak.Group; Status = "Failed"; Detail = $_.Exception.Message; RebootRequired = $false }
                }
            }

            $privReport = [pscustomobject]@{
                Product = $script:ProductName
                Version = $script:ProductVersion
                Profile = "Privacy"
                Mode = "Apply"
                BackupPath = $backup
                Computer = Get-ApexPulseComputerState
                Results = $privResults
                RebootRequired = $false
            }
            $privStamp = Get-Date -Format "yyyyMMdd-HHmmss"
            $privJsonPath = Join-Path $script:ReportRoot ("report-{0}-Privacy.json" -f $privStamp)
            $privReport | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $privJsonPath -Encoding UTF8
            $privHtmlPath = [IO.Path]::ChangeExtension($privJsonPath, ".html")
            New-ApexPulseHtmlReport -Report $privReport -Path $privHtmlPath
            $lines += ""
            $lines += "Report: $privJsonPath"
            $lines += "HTML Report: $privHtmlPath"

            $privacyOutputBox.Text = $lines -join [Environment]::NewLine
            & $setLastRun
            & $hideLoading
            & $setStatus "Privacy Shield applied."
            & $showNotify "Privacy Shield applied" "success"
        } catch {
            $privacyOutputBox.Text = $_.Exception.Message
            & $hideLoading
            & $setStatus "Privacy apply failed."
            & $showNotify $_.Exception.Message "error"
        }
    })

    # --- Rollback Center ---
    $backupDirLabel.Text = "Backups: $($script:BackupRoot)"
    $script:BackupEntries = @()

    $loadBackups = {
        $script:BackupEntries = @(Get-ApexPulseBackups)
        $backupList.ItemsSource = $script:BackupEntries
        $backupDetailBox.Text = if ($script:BackupEntries.Count -eq 0) {
            "No backups found yet. Run an Apply or click Create Backup Now."
        } else {
            "Select a backup to view its manifest."
        }
    }

    $refreshBackups.Add_Click({ & $loadBackups })

    $backupList.Add_SelectionChanged({
        $entry = $backupList.SelectedItem
        if ($null -eq $entry) {
            $backupDetailBox.Text = ""
            return
        }

        $manifestPath = Join-Path $entry.Path "manifest.json"
        if (Test-Path -LiteralPath $manifestPath) {
            try {
                $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                $lines = @()
                $lines += "Product: $($manifest.Product)"
                $lines += "Profile: $($manifest.Profile)"
                $lines += "Created: $($manifest.CreatedAt)"
                if ($manifest.PSObject.Properties.Name -contains "Computer" -and $manifest.Computer) {
                    $lines += "Computer: $($manifest.Computer.ComputerName)"
                    $lines += "OS: $($manifest.Computer.OSCaption)"
                }
                if ($manifest.PSObject.Properties.Name -contains "RestorePoint" -and $manifest.RestorePoint) {
                    $rpStatus = if ($manifest.RestorePoint.Created) { "Yes" } else { "No" }
                    $lines += "Restore point: $rpStatus"
                }
                $regCount = ($manifest.RegistryExports | Where-Object { $_.Exported }).Count
                $lines += "Registry exports: $regCount"
                if ($manifest.PSObject.Properties.Name -contains "RegistryValueSnapshots") {
                    $lines += "Value snapshots: $($manifest.RegistryValueSnapshots.Count)"
                }
                $backupDetailBox.Text = $lines -join [Environment]::NewLine
            } catch {
                $backupDetailBox.Text = "Error reading manifest: $($_.Exception.Message)"
            }
        } else {
            $backupDetailBox.Text = "manifest.json not found."
        }
    })

    # Per-row Restore button (routed Click event from DataGrid cells)
    $backupList.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($s, $e)
            $btn = $e.OriginalSource
            if (-not ($btn -is [System.Windows.Controls.Button])) { return }
            if ($btn.Tag -ne "RestoreRow") { return }
            $entry = $btn.DataContext
            if ($null -eq $entry) { return }
            try {
                & $showLoading
                & $setStatus "Restoring from $($entry.Name)..."
                $backupDetailBox.Text = "Restoring from $($entry.Name)..."
                [Windows.Forms.Application]::DoEvents() 2>$null
                $results = Restore-ApexPulseBackup -Path $entry.Path
                $lines = @("Restore complete:", "")
                foreach ($r in $results) {
                    $lines += "[$($r.Status)] $($r.Target) - $($r.Detail)"
                }
                $backupDetailBox.Text = $lines -join [Environment]::NewLine
                & $hideLoading
                & $setLastRun
                & $setStatus "Restore complete."
                & $showNotify "Backup restored" "success"
            } catch {
                & $hideLoading
                $backupDetailBox.Text = "Restore failed: $($_.Exception.Message)"
                & $setStatus "Restore failed."
                & $showNotify $_.Exception.Message "error"
            }
        }
    )

    $createBackupNow.Add_Click({
        try {
            & $showLoading
            & $setStatus "Creating backup..."
            [Windows.Forms.Application]::DoEvents() 2>$null
            $profileName = & $getProfile
            $allTweaks = Get-ApexPulseTweaks
            $tweaks = $allTweaks | Where-Object { $_.Profiles -contains $profileName }
            $admin = Test-ApexPulseAdmin
            if (-not $admin) {
                & $hideLoading
                & $setStatus "Backup requires Administrator."
                & $showNotify "Backup requires Administrator" "error"
                return
            }
            $backupPath = New-ApexPulseBackup -Tweaks $tweaks -SelectedProfile $profileName
            & $loadBackups
            & $hideLoading
            & $setLastRun
            & $setStatus "Backup created."
            & $showNotify "Backup created: $(Split-Path $backupPath -Leaf)" "success"
        } catch {
            & $hideLoading
            & $setStatus "Backup failed."
            & $showNotify $_.Exception.Message "error"
        }
    })

    # --- Reports ---
    $reportDirLabel.Text = "Reports: $($script:ReportRoot)"

    $loadReports = {
        $items = @()
        if (Test-Path -LiteralPath $script:ReportRoot) {
            $items = @(
                Get-ChildItem -LiteralPath $script:ReportRoot -File -ErrorAction SilentlyContinue |
                    Where-Object { $_.Extension -in @(".html", ".json") } |
                    Sort-Object LastWriteTime -Descending |
                    ForEach-Object {
                        [pscustomobject]@{
                            DisplayName = $_.Name
                            Created     = $_.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
                            Path        = $_.FullName
                        }
                    }
            )
        }
        $reportsList.ItemsSource = $items
    }

    $refreshReports.Add_Click({ & $loadReports })

    $reportsList.AddHandler(
        [System.Windows.Controls.Primitives.ButtonBase]::ClickEvent,
        [System.Windows.RoutedEventHandler]{
            param($s, $e)
            $btn = $e.OriginalSource
            if (-not ($btn -is [System.Windows.Controls.Button])) { return }
            if ($btn.Tag -ne "OpenRow") { return }
            $entry = $btn.DataContext
            if ($null -eq $entry) { return }
            try {
                Start-Process -FilePath $entry.Path
                & $setStatus "Opened $($entry.DisplayName)"
            } catch {
                & $showNotify "Failed to open report: $($_.Exception.Message)" "error"
            }
        }
    )

    # --- Init ---
    $outputBox.Text = "Choose a profile and click Apply or Analyze (no changes)."
    $statusText.Text = "Ready."
    $window.Add_Loaded({ & $animateCardsIn })
    [void]$window.ShowDialog()
}

#endregion

# ---------------------------------------------------------------------------
#region Main Entry Point
# ---------------------------------------------------------------------------

try {
    if ($Mode -eq "Restore") {
        if (-not $BackupPath) {
            throw "-BackupPath is required when -Mode Restore is used."
        }
        $restoreResults = Restore-ApexPulseBackup -Path $BackupPath
        $restoreResults | Format-Table -AutoSize
        if ($restoreResults | Where-Object { $_.Status -eq "Failed" } | Select-Object -First 1) {
            exit 2
        }
        return
    }

    if (-not $NoUi) {
        Show-ApexPulseUi
        return
    }

    $report = Invoke-ApexPulseProfile -SelectedProfile $Profile -SelectedMode $Mode
    Show-ApexPulseConsoleSummary -Report $report
    if ($Mode -eq "Apply" -and ($report.Results | Where-Object { $_.Status -eq "Failed" } | Select-Object -First 1)) {
        exit 2
    }
} catch {
    Write-ApexPulseLog $_.Exception.Message -Level Error
    exit 1
}

#endregion
