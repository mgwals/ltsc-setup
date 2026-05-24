<#
.SYNOPSIS
    Win11 GameBoost optimizes Windows 11 for gaming with profiles, reports and rollback.

.DESCRIPTION
    Run without parameters for the WPF interface. Use -NoUi for automation:
      .\GameBoost.ps1 -Profile Safe -Mode Analyze -NoUi
      .\GameBoost.ps1 -Profile Safe -Mode Apply -NoUi
      .\GameBoost.ps1 -Profile Competitive -Mode Apply -NoUi
      .\GameBoost.ps1 -Mode Restore -BackupPath "C:\ProgramData\Win11GameBoost\Backups\..." -NoUi
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

$script:ProductName = "Win11 GameBoost"
$script:ProductVersion = "1.0.0"
$script:IsWindows = $PSVersionTable.PSVersion -and $env:OS -eq "Windows_NT"
$script:DataRoot = if ($script:IsWindows -and $env:ProgramData) {
    Join-Path $env:ProgramData "Win11GameBoost"
} else {
    Join-Path $PSScriptRoot ".gameboost"
}
$script:BackupRoot = Join-Path $script:DataRoot "Backups"
$script:ReportRoot = Join-Path $script:DataRoot "Reports"
$script:LogRoot = Join-Path $script:DataRoot "Logs"

function Write-GameBoostLog {
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

function Initialize-GameBoostStorage {
    foreach ($path in @($script:DataRoot, $script:BackupRoot, $script:ReportRoot, $script:LogRoot)) {
        if (-not (Test-Path -LiteralPath $path)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }
}

function Test-GameBoostAdmin {
    if (-not $script:IsWindows) {
        return $false
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Assert-GameBoostWindows {
    if (-not $script:IsWindows) {
        throw "$script:ProductName only applies to Windows. This host can be used to edit the repo, but not to optimize the OS."
    }
}

function Get-GameBoostComputerState {
    $admin = Test-GameBoostAdmin
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

function Get-GameBoostRegistryValueRefs {
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

function New-GameBoostBackup {
    param(
        [Parameter(Mandatory)]
        [array]$Tweaks,

        [Parameter(Mandatory)]
        [string]$SelectedProfile
    )

    Assert-GameBoostWindows
    Initialize-GameBoostStorage

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
            $exportOutput = & reg.exe export $cliPath $exportPath /y 2>&1
            $exportExitCode = $LASTEXITCODE
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
    foreach ($valueRef in (Get-GameBoostRegistryValueRefs -Tweaks $Tweaks)) {
        $registryValueSnapshots += Get-RegistryValueState -Path $valueRef.Path -Name $valueRef.Name
    }

    $restorePoint = [pscustomobject]@{
        Attempted = $false
        Created = $false
        Error = $null
    }

    if (Test-GameBoostAdmin) {
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
        Computer = Get-GameBoostComputerState
        ActivePowerSchemeGuid = Get-ActivePowerSchemeGuid
        ServiceSnapshots = @(
            Get-ServiceSnapshot -Name "SysMain"
            Get-ServiceSnapshot -Name "WSearch"
            Get-ServiceSnapshot -Name "DiagTrack"
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

function Restore-GameBoostBackup {
    param([Parameter(Mandatory)][string]$Path)

    Assert-GameBoostWindows

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
            $importOutput = & reg.exe import $regFile 2>&1
            $importExitCode = $LASTEXITCODE
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
                    Detail = "Value did not exist before GameBoost apply."
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

    Get-GameBoostPackageSet |
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

function Install-GameBoostWingetBootstrap {
    Assert-GameBoostWindows

    if (Get-Command winget.exe -ErrorAction SilentlyContinue) {
        return "winget.exe is already available."
    }

    if (-not (Test-GameBoostAdmin)) {
        return "winget.exe is missing and bootstrap requires Administrator."
    }

    $tempDir = Join-Path $env:TEMP "Win11GameBoost-WinGetBootstrap"
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

function Repair-GameBoostStoreInfrastructure {
    Assert-GameBoostWindows

    if (-not (Test-GameBoostAdmin)) {
        return "Microsoft Store repair requires Administrator."
    }

    Start-Process wsreset.exe -ArgumentList "-i" -NoNewWindow -Wait
    return "Microsoft Store infrastructure repair requested."
}

function Get-GameBoostTweaks {
    $safeProfile = "Safe"
    $competitiveProfile = "Competitive"

    @(
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
    )
}

function Get-GameBoostPackageSet {
    @(
        [pscustomobject]@{ Id = "Valve.Steam"; Name = "Steam"; Profile = "Safe"; Source = "winget" }
        [pscustomobject]@{ Id = "9MV0B5HZVK9Z"; Name = "Xbox App"; Profile = "Safe"; Source = "msstore" }
        [pscustomobject]@{ Id = "Discord.Discord"; Name = "Discord"; Profile = "Safe"; Source = "winget" }
        [pscustomobject]@{ Id = "7zip.7zip"; Name = "7-Zip"; Profile = "Safe"; Source = "winget" }
        [pscustomobject]@{ Id = "EpicGames.EpicGamesLauncher"; Name = "Epic Games Launcher"; Profile = "Competitive"; Source = "winget" }
        [pscustomobject]@{ Id = "GOG.Galaxy"; Name = "GOG Galaxy"; Profile = "Competitive"; Source = "winget" }
    )
}

function Invoke-GameBoostPackages {
    param(
        [Parameter(Mandatory)][string]$SelectedProfile,
        [Parameter(Mandatory)][bool]$Apply
    )

    $selected = Get-GameBoostPackageSet | Where-Object {
        $_.Profile -eq "Safe" -or $SelectedProfile -eq "Competitive"
    }

    $results = @()
    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if (-not $winget) {
        if ($Apply) {
            try {
                $bootstrapDetail = Install-GameBoostWingetBootstrap
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
            $storeDetail = Repair-GameBoostStoreInfrastructure
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

function Invoke-GameBoostProfile {
    param(
        [ValidateSet("Safe", "Competitive")]
        [string]$SelectedProfile,

        [ValidateSet("Analyze", "Apply")]
        [string]$SelectedMode
    )

    Assert-GameBoostWindows
    Initialize-GameBoostStorage

    $admin = Test-GameBoostAdmin
    $shouldApply = $SelectedMode -eq "Apply"
    $whatIf = [bool]$WhatIfPreference
    $canMutate = $shouldApply -and -not $whatIf
    $allTweaks = Get-GameBoostTweaks
    $tweaks = $allTweaks | Where-Object { $_.Profiles -contains $SelectedProfile }
    $backup = $null

    if ($canMutate) {
        if (-not $admin) {
            throw "$script:ProductName needs an elevated PowerShell session to apply system-level optimizations."
        }

        $backup = New-GameBoostBackup -Tweaks $tweaks -SelectedProfile $SelectedProfile
        Write-GameBoostLog "Backup created: $backup" -Level Success
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

    $packageResults = Invoke-GameBoostPackages -SelectedProfile $SelectedProfile -Apply $canMutate
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
        Computer = Get-GameBoostComputerState
        Results = $results
        RebootRequired = [bool]($results | Where-Object { $_.Status -eq "Applied" -and $_.RebootRequired } | Select-Object -First 1)
    }

    $path = if ($ReportPath) {
        $ReportPath
    } else {
        Join-Path $script:ReportRoot ("report-{0}-{1}.json" -f (Get-Date -Format "yyyyMMdd-HHmmss"), $SelectedProfile)
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding UTF8
    $report | Add-Member -MemberType NoteProperty -Name ReportPath -Value $path -Force
    return $report
}

function Show-GameBoostConsoleSummary {
    param([Parameter(Mandatory)]$Report)

    Write-GameBoostLog "$($Report.Product) $($Report.Version) - $($Report.Profile) / $($Report.Mode)" -Level Info
    foreach ($item in $Report.Results) {
        $level = switch ($item.Status) {
            "Applied" { "Success" }
            "Failed" { "Error" }
            "NeedsAdmin" { "Warn" }
            default { "Info" }
        }
        Write-GameBoostLog "$($item.Status): $($item.Name) - $($item.Detail)" -Level $level
    }

    if ($Report.BackupPath) {
        Write-GameBoostLog "Backup: $($Report.BackupPath)" -Level Success
    }
    Write-GameBoostLog "Report: $($Report.ReportPath)" -Level Success
    if ($Report.RebootRequired) {
        Write-GameBoostLog "A reboot is recommended to finish GPU/MMCSS changes." -Level Warn
    }
}

function Show-GameBoostUi {
    Assert-GameBoostWindows
    Initialize-GameBoostStorage

    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase

    [xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Win11 GameBoost" Height="720" Width="1080" WindowStartupLocation="CenterScreen"
        Background="#0B1020" Foreground="#F8FAFC" ResizeMode="CanResize">
  <Window.Resources>
    <Style TargetType="Button">
      <Setter Property="Background" Value="#22D3EE"/>
      <Setter Property="Foreground" Value="#07111F"/>
      <Setter Property="FontWeight" Value="Bold"/>
      <Setter Property="Padding" Value="16,10"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Margin" Value="0,0,10,0"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>
    <Style TargetType="RadioButton">
      <Setter Property="Foreground" Value="#E2E8F0"/>
      <Setter Property="FontSize" Value="15"/>
      <Setter Property="Margin" Value="0,8,0,8"/>
    </Style>
  </Window.Resources>
  <Grid Margin="28">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0" Margin="0,0,0,24">
      <TextBlock Text="WIN11 GAMEBOOST" Foreground="#22D3EE" FontSize="14" FontWeight="Bold"/>
      <TextBlock Text="Gaming optimization for Windows 11" FontSize="42" FontWeight="Black" Margin="0,4,0,4"/>
      <TextBlock Text="Analyze, optimize and restore without turning Windows into a mystery box." Foreground="#94A3B8" FontSize="16"/>
    </StackPanel>

    <Grid Grid.Row="1">
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="360"/>
        <ColumnDefinition Width="*"/>
      </Grid.ColumnDefinitions>

      <Border Grid.Column="0" Background="#111827" CornerRadius="14" Padding="22" BorderBrush="#1F2937" BorderThickness="1">
        <StackPanel>
          <TextBlock Text="Profile" FontSize="24" FontWeight="Bold" Margin="0,0,0,12"/>
          <RadioButton Name="SafeProfile" IsChecked="True" Content="Safe Performance"/>
          <TextBlock Text="Recommended. Meaningful gaming tweaks, backup and compatibility with Store, Game Pass, Windows Update and anticheats." TextWrapping="Wrap" Foreground="#94A3B8" Margin="28,0,0,12"/>
          <RadioButton Name="CompetitiveProfile" Content="Competitive"/>
          <TextBlock Text="Opt-in. Adds background-noise reductions and latency-oriented tweaks with clear rollback." TextWrapping="Wrap" Foreground="#94A3B8" Margin="28,0,0,24"/>

          <TextBlock Text="Actions" FontSize="24" FontWeight="Bold" Margin="0,6,0,14"/>
          <Button Name="AnalyzeButton" Content="Analyze PC" Margin="0,0,0,10"/>
          <Button Name="ApplyButton" Content="Optimize Now" Background="#A3E635" Margin="0,0,0,10"/>
          <Button Name="RestoreButton" Content="Restore Backup" Background="#F97316" Foreground="#111827" Margin="0,0,0,10"/>
        </StackPanel>
      </Border>

      <Border Grid.Column="1" Background="#0F172A" CornerRadius="14" Padding="22" Margin="20,0,0,0" BorderBrush="#1E293B" BorderThickness="1">
        <Grid>
          <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
          </Grid.RowDefinitions>
          <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,16">
            <Border Background="#172554" CornerRadius="10" Padding="14" Margin="0,0,12,0">
              <StackPanel>
                <TextBlock Text="Power" Foreground="#93C5FD"/>
                <TextBlock Name="PowerStatus" Text="Waiting" FontSize="20" FontWeight="Bold"/>
              </StackPanel>
            </Border>
            <Border Background="#164E63" CornerRadius="10" Padding="14" Margin="0,0,12,0">
              <StackPanel>
                <TextBlock Text="GPU" Foreground="#67E8F9"/>
                <TextBlock Name="GpuStatus" Text="Waiting" FontSize="20" FontWeight="Bold"/>
              </StackPanel>
            </Border>
            <Border Background="#3B0764" CornerRadius="10" Padding="14" Margin="0,0,12,0">
              <StackPanel>
                <TextBlock Text="Noise" Foreground="#D8B4FE"/>
                <TextBlock Name="NoiseStatus" Text="Waiting" FontSize="20" FontWeight="Bold"/>
              </StackPanel>
            </Border>
            <Border Background="#1E3A5F" CornerRadius="10" Padding="14">
              <StackPanel>
                <TextBlock Text="Latency" Foreground="#7DD3FC"/>
                <TextBlock Name="LatencyStatus" Text="Waiting" FontSize="20" FontWeight="Bold"/>
              </StackPanel>
            </Border>
          </StackPanel>
          <TextBox Grid.Row="1" Name="OutputBox" Background="#020617" Foreground="#E2E8F0" BorderBrush="#334155"
                   FontFamily="Consolas" FontSize="13" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"
                   IsReadOnly="True" Padding="14"/>
        </Grid>
      </Border>
    </Grid>

    <TextBlock Grid.Row="2" Text="Safe by default. Competitive by choice. Restore when needed." Foreground="#64748B" Margin="0,18,0,0"/>
  </Grid>
</Window>
"@

    $reader = [System.Xml.XmlNodeReader]::new($xaml)
    $window = [Windows.Markup.XamlReader]::Load($reader)
    $safeProfile = $window.FindName("SafeProfile")
    $competitiveProfile = $window.FindName("CompetitiveProfile")
    $analyzeButton = $window.FindName("AnalyzeButton")
    $applyButton = $window.FindName("ApplyButton")
    $restoreButton = $window.FindName("RestoreButton")
    $outputBox = $window.FindName("OutputBox")
    $powerStatus = $window.FindName("PowerStatus")
    $gpuStatus = $window.FindName("GpuStatus")
    $noiseStatus = $window.FindName("NoiseStatus")
    $latencyStatus = $window.FindName("LatencyStatus")

    $renderReport = {
        param($report)

        $lines = @()
        $lines += "$($report.Product) $($report.Version)"
        $lines += "Profile: $($report.Profile)"
        $lines += "Mode: $($report.Mode)"
        $lines += "Report: $($report.ReportPath)"
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

        $powerStatus.Text = if ($powerItem) { $powerItem.Status } else { "Skipped" }
        $gpuStatus.Text = if ($gpuItem) { $gpuItem.Status } else { "Skipped" }
        $noiseStatus.Text = if ($noiseItem) { $noiseItem.Status } else { "Skipped" }

        $latencyItem = $report.Results | Where-Object { $_.Group -eq "Latency" } | Select-Object -First 1
        $latencyStatus.Text = if ($latencyItem) { $latencyItem.Status } else { "Skipped" }
    }

    $getProfile = {
        if ($competitiveProfile.IsChecked) { "Competitive" } else { "Safe" }
    }

    $analyzeButton.Add_Click({
        try {
            $report = Invoke-GameBoostProfile -SelectedProfile (& $getProfile) -SelectedMode "Analyze"
            & $renderReport $report
        } catch {
            $outputBox.Text = $_.Exception.Message
        }
    })

    $applyButton.Add_Click({
        try {
            $report = Invoke-GameBoostProfile -SelectedProfile (& $getProfile) -SelectedMode "Apply"
            & $renderReport $report
        } catch {
            $outputBox.Text = $_.Exception.Message
        }
    })

    $restoreButton.Add_Click({
        try {
            $dialog = [Microsoft.Win32.OpenFileDialog]::new()
            $dialog.Title = "Select a Win11 GameBoost manifest.json"
            $dialog.Filter = "GameBoost manifest (manifest.json)|manifest.json|JSON files (*.json)|*.json"
            $dialog.InitialDirectory = $script:BackupRoot
            if ($dialog.ShowDialog() -eq $true) {
                $results = Restore-GameBoostBackup -Path (Split-Path -Parent $dialog.FileName)
                $outputBox.Text = ($results | Format-Table -AutoSize | Out-String)
            }
        } catch {
            $outputBox.Text = $_.Exception.Message
        }
    })

    $outputBox.Text = "Choose a profile and click Analyze PC."
    [void]$window.ShowDialog()
}

try {
    if ($Mode -eq "Restore") {
        if (-not $BackupPath) {
            throw "-BackupPath is required when -Mode Restore is used."
        }
        $restoreResults = Restore-GameBoostBackup -Path $BackupPath
        $restoreResults | Format-Table -AutoSize
        if ($restoreResults | Where-Object { $_.Status -eq "Failed" } | Select-Object -First 1) {
            exit 2
        }
        return
    }

    if (-not $NoUi) {
        Show-GameBoostUi
        return
    }

    $report = Invoke-GameBoostProfile -SelectedProfile $Profile -SelectedMode $Mode
    Show-GameBoostConsoleSummary -Report $report
    if ($Mode -eq "Apply" -and ($report.Results | Where-Object { $_.Status -eq "Failed" } | Select-Object -First 1)) {
        exit 2
    }
} catch {
    Write-GameBoostLog $_.Exception.Message -Level Error
    exit 1
}
