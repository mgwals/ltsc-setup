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
            $ErrorActionPreference = "SilentlyContinue"
            $exportOutput = & reg.exe export $cliPath $exportPath /y 2>&1
            $exportExitCode = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
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
            $ErrorActionPreference = "SilentlyContinue"
            $importOutput = & reg.exe import $regFile 2>&1
            $importExitCode = $LASTEXITCODE
            $ErrorActionPreference = $prevEAP
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

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ApexPulse 11" Height="800" Width="1280" WindowStartupLocation="CenterScreen"
        Background="#0B0E17" Foreground="#F8FAFC" ResizeMode="CanResize" MinWidth="960" MinHeight="600">
  <Window.Resources>
    <Style TargetType="Button" x:Key="NavBtn">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="Foreground" Value="#94A3B8"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="14,11"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Margin" Value="0,2"/>
    </Style>
    <Style TargetType="Button" x:Key="ActionBtn">
      <Setter Property="Background" Value="#22D3EE"/>
      <Setter Property="Foreground" Value="#07111F"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Padding" Value="20,12"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Margin" Value="0,0,0,10"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalAlignment" Value="Stretch"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="0,8,0,8"/>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="FontSize" Value="14"/>
      <Setter Property="Margin" Value="0,6,0,6"/>
    </Style>
  </Window.Resources>

  <Grid>
    <Grid.ColumnDefinitions>
      <ColumnDefinition Width="240"/>
      <ColumnDefinition Width="*"/>
    </Grid.ColumnDefinitions>

    <!-- Sidebar -->
    <Border Grid.Column="0" Background="#111827" BorderBrush="#1E293B" BorderThickness="0,0,1,0">
      <DockPanel LastChildFill="True">
        <StackPanel DockPanel.Dock="Top" Margin="20,28,20,28">
          <TextBlock FontSize="22" FontWeight="Black">
            <Run Text="APEX" Foreground="#22D3EE"/><Run Text="PULSE" Foreground="#A3E635"/>
          </TextBlock>
          <TextBlock Text="11" FontSize="36" FontWeight="Black" Foreground="#F8FAFC" Margin="0,-8,0,0"/>
          <TextBlock Text="Windows 11 Optimizer" FontSize="12" Foreground="#64748B" Margin="0,4,0,0"/>
        </StackPanel>

        <Border DockPanel.Dock="Bottom" Margin="16,0,16,16" Padding="12,8" Background="#0F172A" CornerRadius="8">
          <TextBlock Name="AdminStatus" FontSize="11" Foreground="#94A3B8" TextWrapping="Wrap"/>
        </Border>

        <StackPanel Margin="8,0">
          <Button Name="NavDashboard" Content="Dashboard" Style="{StaticResource NavBtn}" Background="#1E293B" Foreground="#F8FAFC"/>
          <Button Name="NavPrivacy" Content="Privacy Shield" Style="{StaticResource NavBtn}"/>
          <Button Name="NavRollback" Content="Rollback Center" Style="{StaticResource NavBtn}"/>
        </StackPanel>
      </DockPanel>
    </Border>

    <!-- Content -->
    <Grid Grid.Column="1" Margin="28">

      <!-- ========== DASHBOARD ========== -->
      <Grid Name="DashboardPanel">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <!-- Status cards -->
        <WrapPanel Grid.Row="0" Margin="0,0,0,20">
          <Border Background="#172554" CornerRadius="10" Padding="16,12" Margin="0,0,10,10" MinWidth="130">
            <StackPanel>
              <TextBlock Text="Power" Foreground="#93C5FD" FontSize="12"/>
              <TextBlock Name="PowerStatus" Text="Waiting" FontSize="18" FontWeight="Bold"/>
            </StackPanel>
          </Border>
          <Border Background="#164E63" CornerRadius="10" Padding="16,12" Margin="0,0,10,10" MinWidth="130">
            <StackPanel>
              <TextBlock Text="GPU" Foreground="#67E8F9" FontSize="12"/>
              <TextBlock Name="GpuStatus" Text="Waiting" FontSize="18" FontWeight="Bold"/>
            </StackPanel>
          </Border>
          <Border Background="#3B0764" CornerRadius="10" Padding="16,12" Margin="0,0,10,10" MinWidth="130">
            <StackPanel>
              <TextBlock Text="Noise" Foreground="#D8B4FE" FontSize="12"/>
              <TextBlock Name="NoiseStatus" Text="Waiting" FontSize="18" FontWeight="Bold"/>
            </StackPanel>
          </Border>
          <Border Background="#1E3A5F" CornerRadius="10" Padding="16,12" Margin="0,0,10,10" MinWidth="130">
            <StackPanel>
              <TextBlock Text="Latency" Foreground="#7DD3FC" FontSize="12"/>
              <TextBlock Name="LatencyStatus" Text="Waiting" FontSize="18" FontWeight="Bold"/>
            </StackPanel>
          </Border>
          <Border Background="#134E4A" CornerRadius="10" Padding="16,12" Margin="0,0,0,10" MinWidth="130">
            <StackPanel>
              <TextBlock Text="Privacy" Foreground="#2DD4BF" FontSize="12"/>
              <TextBlock Name="PrivacyStatusCard" Text="Waiting" FontSize="18" FontWeight="Bold"/>
            </StackPanel>
          </Border>
        </WrapPanel>

        <!-- Profile + Actions -->
        <Border Grid.Row="1" Background="#111827" CornerRadius="14" Padding="22" Margin="0,0,0,16" BorderBrush="#1F2937" BorderThickness="1">
          <Grid>
            <Grid.ColumnDefinitions>
              <ColumnDefinition Width="*"/>
              <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <StackPanel Grid.Column="0">
              <TextBlock Text="Profile" FontSize="20" FontWeight="Bold" Margin="0,0,0,12"/>
              <RadioButton Name="SafeProfile" IsChecked="True" Content="Safe Performance"/>
              <TextBlock Text="Gaming tweaks, backup, full compatibility with Store, Game Pass, Update and anticheats." TextWrapping="Wrap" Foreground="#94A3B8" FontSize="12" Margin="28,0,0,8"/>
              <RadioButton Name="CompetitiveProfile" Content="Competitive"/>
              <TextBlock Text="Adds privacy shield, background-noise reductions and latency-oriented tweaks with clear rollback." TextWrapping="Wrap" Foreground="#94A3B8" FontSize="12" Margin="28,0,0,0"/>
            </StackPanel>

            <StackPanel Grid.Column="1" Margin="24,0,0,0">
              <TextBlock Text="Quick Actions" FontSize="20" FontWeight="Bold" Margin="0,0,0,12"/>
              <Button Name="AnalyzeButton" Content="Analyze PC" Style="{StaticResource ActionBtn}"/>
              <Button Name="ApplyButton" Content="Optimize Now" Style="{StaticResource ActionBtn}" Background="#A3E635"/>
            </StackPanel>
          </Grid>
        </Border>

        <!-- Output console -->
        <TextBox Grid.Row="2" Name="OutputBox" Background="#020617" Foreground="#E2E8F0" BorderBrush="#334155"
                 FontFamily="Consolas" FontSize="13" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                 IsReadOnly="True" Padding="14" BorderThickness="1"/>

        <TextBlock Grid.Row="3" Text="Safe by default. Competitive by choice. Restore when needed."
                   Foreground="#475569" Margin="0,10,0,0" FontSize="12"/>
      </Grid>

      <!-- ========== PRIVACY SHIELD ========== -->
      <Grid Name="PrivacyPanel" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,20">
          <TextBlock Text="Privacy Shield" FontSize="32" FontWeight="Black" Foreground="#F8FAFC"/>
          <TextBlock Text="Control Windows telemetry, tracking and data collection. These optimizations are included in the Competitive profile but can also be applied independently." TextWrapping="Wrap" Foreground="#94A3B8" FontSize="14" Margin="0,4,0,0"/>
        </StackPanel>

        <Border Grid.Row="1" Background="#111827" CornerRadius="14" Padding="22" BorderBrush="#1F2937" BorderThickness="1" Margin="0,0,0,16">
          <StackPanel>
            <CheckBox Name="PrivTailored" Content="Disable Tailored Experiences" IsChecked="True"/>
            <TextBlock Text="Prevents Windows from using diagnostic data to personalize tips and recommendations." Foreground="#64748B" FontSize="12" Margin="28,0,0,10" TextWrapping="Wrap"/>

            <CheckBox Name="PrivDiagnostic" Content="Reduce Diagnostic Data Upload" IsChecked="True"/>
            <TextBlock Text="Sets telemetry to security-only level. Requires Administrator." Foreground="#64748B" FontSize="12" Margin="28,0,0,10" TextWrapping="Wrap"/>

            <CheckBox Name="PrivCortana" Content="Disable Cortana and Cloud Search" IsChecked="True"/>
            <TextBlock Text="Disables Bing web results in Start Menu search and Cortana consent." Foreground="#64748B" FontSize="12" Margin="28,0,0,10" TextWrapping="Wrap"/>

            <CheckBox Name="PrivLocation" Content="Disable Location Tracking" IsChecked="True"/>
            <TextBlock Text="Denies location access system-wide and for the current user. Requires Administrator." Foreground="#64748B" FontSize="12" Margin="28,0,0,10" TextWrapping="Wrap"/>

            <CheckBox Name="PrivActivity" Content="Disable Activity History" IsChecked="True"/>
            <TextBlock Text="Stops Windows from collecting and uploading activity history. Requires Administrator." Foreground="#64748B" FontSize="12" Margin="28,0,0,14" TextWrapping="Wrap"/>

            <StackPanel Orientation="Horizontal">
              <Button Name="PrivScanButton" Content="Scan Privacy" Style="{StaticResource ActionBtn}" Background="#2DD4BF" Margin="0,0,10,0" HorizontalAlignment="Left" Width="180"/>
              <Button Name="PrivApplyButton" Content="Apply Privacy Shield" Style="{StaticResource ActionBtn}" Background="#A3E635" HorizontalAlignment="Left" Width="220"/>
            </StackPanel>
          </StackPanel>
        </Border>

        <TextBox Grid.Row="2" Name="PrivacyOutputBox" Background="#020617" Foreground="#E2E8F0"
                 BorderBrush="#334155" FontFamily="Consolas" FontSize="13" TextWrapping="Wrap"
                 VerticalScrollBarVisibility="Auto" IsReadOnly="True" Padding="14" BorderThickness="1"/>
      </Grid>

      <!-- ========== ROLLBACK CENTER ========== -->
      <Grid Name="RollbackPanel" Visibility="Collapsed">
        <Grid.RowDefinitions>
          <RowDefinition Height="Auto"/>
          <RowDefinition Height="*"/>
          <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>

        <StackPanel Grid.Row="0" Margin="0,0,0,16">
          <TextBlock Text="Rollback Center" FontSize="32" FontWeight="Black" Foreground="#F8FAFC"/>
          <TextBlock Text="Restore your system to a previous state from any ApexPulse backup." Foreground="#94A3B8" FontSize="14" Margin="0,4,0,0" TextWrapping="Wrap"/>
          <TextBlock Name="BackupDirLabel" Foreground="#475569" FontSize="12" Margin="0,4,0,0"/>
        </StackPanel>

        <Grid Grid.Row="1">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>

          <Border Grid.Column="0" Background="#111827" CornerRadius="14" Padding="16" BorderBrush="#1F2937" BorderThickness="1" Margin="0,0,10,0">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="Available Backups" FontSize="16" FontWeight="Bold" Margin="0,0,0,12"/>
              <Button DockPanel.Dock="Bottom" Name="RefreshBackupsButton" Content="Refresh" Style="{StaticResource ActionBtn}" Background="#334155" Foreground="#E2E8F0" Margin="0,12,0,0"/>
              <ListBox Name="BackupList" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#1E293B" BorderThickness="1" Padding="4" FontSize="13"/>
            </DockPanel>
          </Border>

          <Border Grid.Column="1" Background="#111827" CornerRadius="14" Padding="16" BorderBrush="#1F2937" BorderThickness="1">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="Backup Details" FontSize="16" FontWeight="Bold" Margin="0,0,0,12"/>
              <TextBox Name="BackupDetailBox" Background="#0F172A" Foreground="#E2E8F0" BorderBrush="#1E293B"
                       FontFamily="Consolas" FontSize="12" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                       IsReadOnly="True" Padding="10" BorderThickness="1"/>
            </DockPanel>
          </Border>
        </Grid>

        <StackPanel Grid.Row="2" Orientation="Horizontal" Margin="0,14,0,0">
          <Button Name="RestoreButton" Content="Restore Selected Backup" Style="{StaticResource ActionBtn}" Background="#F97316" Foreground="#111827" HorizontalAlignment="Left" Width="280"/>
        </StackPanel>
      </Grid>

    </Grid>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)

    # --- Find controls ---
    $navDashboard      = $window.FindName("NavDashboard")
    $navPrivacy        = $window.FindName("NavPrivacy")
    $navRollback       = $window.FindName("NavRollback")
    $dashboardPanel    = $window.FindName("DashboardPanel")
    $privacyPanel      = $window.FindName("PrivacyPanel")
    $rollbackPanel     = $window.FindName("RollbackPanel")
    $adminStatusLabel  = $window.FindName("AdminStatus")
    $safeProfile       = $window.FindName("SafeProfile")
    $competitiveProfile = $window.FindName("CompetitiveProfile")
    $analyzeButton     = $window.FindName("AnalyzeButton")
    $applyButton       = $window.FindName("ApplyButton")
    $outputBox         = $window.FindName("OutputBox")
    $powerStatus       = $window.FindName("PowerStatus")
    $gpuStatus         = $window.FindName("GpuStatus")
    $noiseStatus       = $window.FindName("NoiseStatus")
    $latencyStatus     = $window.FindName("LatencyStatus")
    $privacyStatusCard = $window.FindName("PrivacyStatusCard")
    $privTailored      = $window.FindName("PrivTailored")
    $privDiagnostic    = $window.FindName("PrivDiagnostic")
    $privCortana       = $window.FindName("PrivCortana")
    $privLocation      = $window.FindName("PrivLocation")
    $privActivity      = $window.FindName("PrivActivity")
    $privScanButton    = $window.FindName("PrivScanButton")
    $privApplyButton   = $window.FindName("PrivApplyButton")
    $privacyOutputBox  = $window.FindName("PrivacyOutputBox")
    $backupDirLabel    = $window.FindName("BackupDirLabel")
    $backupList        = $window.FindName("BackupList")
    $backupDetailBox   = $window.FindName("BackupDetailBox")
    $refreshBackups    = $window.FindName("RefreshBackupsButton")
    $restoreButton     = $window.FindName("RestoreButton")

    # --- Admin indicator ---
    $isAdmin = Test-ApexPulseAdmin
    $adminStatusLabel.Text = if ($isAdmin) { "Running as Administrator" } else { "Standard user (some tweaks need elevation)" }

    # --- Navigation ---
    $switchPanel = {
        param($target)
        $dashboardPanel.Visibility = "Collapsed"
        $privacyPanel.Visibility = "Collapsed"
        $rollbackPanel.Visibility = "Collapsed"

        $navDashboard.Background = [Windows.Media.Brushes]::Transparent
        $navDashboard.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom("#94A3B8")
        $navPrivacy.Background = [Windows.Media.Brushes]::Transparent
        $navPrivacy.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom("#94A3B8")
        $navRollback.Background = [Windows.Media.Brushes]::Transparent
        $navRollback.Foreground = [Windows.Media.BrushConverter]::new().ConvertFrom("#94A3B8")

        switch ($target) {
            "Dashboard" {
                $dashboardPanel.Visibility = "Visible"
                $navDashboard.Background = [Windows.Media.BrushConverter]::new().ConvertFrom("#1E293B")
                $navDashboard.Foreground = [Windows.Media.Brushes]::White
            }
            "Privacy" {
                $privacyPanel.Visibility = "Visible"
                $navPrivacy.Background = [Windows.Media.BrushConverter]::new().ConvertFrom("#1E293B")
                $navPrivacy.Foreground = [Windows.Media.Brushes]::White
            }
            "Rollback" {
                $rollbackPanel.Visibility = "Visible"
                $navRollback.Background = [Windows.Media.BrushConverter]::new().ConvertFrom("#1E293B")
                $navRollback.Foreground = [Windows.Media.Brushes]::White
            }
        }
    }

    $navDashboard.Add_Click({ & $switchPanel "Dashboard" })
    $navPrivacy.Add_Click({ & $switchPanel "Privacy" })
    $navRollback.Add_Click({
        & $switchPanel "Rollback"
        & $loadBackups
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
            $outputBox.Text = "Analyzing..."
            [Windows.Forms.Application]::DoEvents() 2>$null
            $report = Invoke-ApexPulseProfile -SelectedProfile (& $getProfile) -SelectedMode "Analyze"
            & $renderReport $report
        } catch {
            $outputBox.Text = $_.Exception.Message
        }
    })

    $applyButton.Add_Click({
        try {
            $outputBox.Text = "Creating backup and restore point, then applying optimizations..."
            [Windows.Forms.Application]::DoEvents() 2>$null
            $report = Invoke-ApexPulseProfile -SelectedProfile (& $getProfile) -SelectedMode "Apply"
            & $renderReport $report
        } catch {
            $outputBox.Text = $_.Exception.Message
        }
    })

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
        } catch {
            $privacyOutputBox.Text = $_.Exception.Message
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
                return
            }

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
        } catch {
            $privacyOutputBox.Text = $_.Exception.Message
        }
    })

    # --- Rollback Center ---
    $backupDirLabel.Text = "Backups: $($script:BackupRoot)"
    $script:BackupEntries = @()

    $loadBackups = {
        $backupList.Items.Clear()
        $backupDetailBox.Text = ""
        $script:BackupEntries = @(Get-ApexPulseBackups)

        if ($script:BackupEntries.Count -eq 0) {
            $backupList.Items.Add("No backups found.") | Out-Null
        } else {
            foreach ($entry in $script:BackupEntries) {
                $display = "$($entry.Name)  ($($entry.Profile))"
                $backupList.Items.Add($display) | Out-Null
            }
        }
    }

    $refreshBackups.Add_Click({ & $loadBackups })

    $backupList.Add_SelectionChanged({
        $idx = $backupList.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:BackupEntries.Count) {
            $backupDetailBox.Text = ""
            return
        }

        $entry = $script:BackupEntries[$idx]
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

    $restoreButton.Add_Click({
        $idx = $backupList.SelectedIndex
        if ($idx -lt 0 -or $idx -ge $script:BackupEntries.Count) {
            $backupDetailBox.Text = "Select a backup first."
            return
        }

        $entry = $script:BackupEntries[$idx]
        try {
            $backupDetailBox.Text = "Restoring from $($entry.Name)..."
            [Windows.Forms.Application]::DoEvents() 2>$null
            $results = Restore-ApexPulseBackup -Path $entry.Path
            $lines = @("Restore complete:", "")
            foreach ($r in $results) {
                $lines += "[$($r.Status)] $($r.Target) - $($r.Detail)"
            }
            $backupDetailBox.Text = $lines -join [Environment]::NewLine
        } catch {
            $backupDetailBox.Text = "Restore failed: $($_.Exception.Message)"
        }
    })

    # --- Init ---
    $outputBox.Text = "Choose a profile and click Analyze PC."
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
