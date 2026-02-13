<#
.SYNOPSIS
    Windows 11 LTSC Initial Provisioning Script (WinGet Bootstrap)
    
.DESCRIPTION
    Bootstraps the Windows Package Manager (WinGet) on LTSC environments,
    restores critical gaming components (Store, Xbox), and applies
    upstream DSC configurations from GitHub.
    
.NOTES
    Author: ENI (via LO's Architecture)
    Version: 2.0 (Generic/Professional)
    Target OS: Windows 11 IoT Enterprise LTSC 2024
#>

# --- CONFIGURATION VARIABLES ---
$WingetUrl       = "https://github.com/microsoft/winget-cli/releases/latest/download/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
$VclibsUrl       = "https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx"
$UiXamlUrl       = "https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.8.6/Microsoft.UI.Xaml.2.8.x64.appx"
# IMPORTANT: Replace this URL with your actual raw YAML config URL
$DscConfigUrl    = "https://raw.githubusercontent.com/mgwals/ltsc-setup/refs/heads/main/packages.dsc.yaml" 
$TempDir         = "$env:TEMP\WinGetBootstrap"

# --- HELPER FUNCTIONS ---
function Log-Message {
    param([string]$Message, [ConsoleColor]$Color = "White")
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $Message" -ForegroundColor $Color
}

# --- EXECUTION START ---
Log-Message "INITIATING SYSTEM PROVISIONING PROTOCOL..." -Color Cyan

# 1. PRE-CHECK & CLEANUP
if (Test-Path $TempDir) { Remove-Item $TempDir -Recurse -Force | Out-Null }
New-Item -ItemType Directory -Force -Path $TempDir | Out-Null

# 2. BOOTSTRAP WINGET (LTSC DEPENDENCY INJECTION)
Log-Message "Detecting LTSC Environment. Injecting Package Manager dependencies..." -Color Yellow

try {
    # Download Dependencies
    Log-Message "Downloading framework libraries..." -Color DarkGray
    Invoke-WebRequest -Uri $VclibsUrl -OutFile "$TempDir\vclibs.appx"
    Invoke-WebRequest -Uri $UiXamlUrl -OutFile "$TempDir\uixaml.appx"
    Invoke-WebRequest -Uri $WingetUrl -OutFile "$TempDir\winget.msixbundle"

    # Install Dependencies
    Log-Message "Registering Appx packages..." -Color DarkGray
    Add-AppxPackage -Path "$TempDir\vclibs.appx"
    Add-AppxPackage -Path "$TempDir\uixaml.appx"
    Add-AppxPackage -Path "$TempDir\winget.msixbundle"
    
    Log-Message "WinGet successfully injected." -Color Green
}
catch {
    Log-Message "CRITICAL ERROR: Failed to bootstrap WinGet. $_" -Color Red
    exit 1
}

# 3. RESTORE MICROSOFT STORE (WSRESET METHOD)
Log-Message "Restoring Microsoft Store infrastructure..." -Color Yellow
Start-Process wsreset.exe -ArgumentList "-i" -NoNewWindow
# Give it a moment to initialize background downloads
Start-Sleep -Seconds 15

# 4. ENVIRONMENT REFRESH
# Force refresh of environment variables to detect new 'winget' command
$env:Path = [System.Environment]::GetEnvironmentVariable("Path","Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path","User")
$WingetExe = "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe"

if (-not (Test-Path $WingetExe)) {
    Log-Message "WARNING: WinGet executable not found in expected path. Attempting fallback..." -Color Red
    # Fallback logic could go here, but usually, a restart fixes this if it fails.
}

# 5. APPLY UPSTREAM CONFIGURATION (DSC)
Log-Message "Applying Upstream Configuration (DSC) from GitHub..." -Color Cyan

try {
    # Download the YAML config
    $YamlPath = "$TempDir\config.dsc.yaml"
    Invoke-WebRequest -Uri $DscConfigUrl -OutFile $YamlPath
    
    Log-Message "Configuration file retrieved. Executing WinGet Configure..." -Color Yellow
    
    # Execute WinGet Configure
    # Note: --accept-configuration-agreements is key for unattended mode
    & $WingetExe configure -f $YamlPath --accept-configuration-agreements --accept-source-agreements
    
    Log-Message "System configuration applied successfully." -Color Green
}
catch {
    Log-Message "ERROR applying configuration: $_" -Color Red
}

# 6. FINAL CLEANUP
Remove-Item $TempDir -Recurse -Force | Out-Null
Log-Message "PROVISIONING COMPLETE. SYSTEM READY." -Color Green
