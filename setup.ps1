<#
.SYNOPSIS
    Compatibility launcher for ApexPulse 11.

.DESCRIPTION
    The original project entry point was setup.ps1. Keep it as a thin wrapper
    so old install notes still work while the real product lives in ApexPulse.ps1.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [ValidateSet("Safe", "Competitive")]
    [string]$Profile = "Safe",

    [ValidateSet("Analyze", "Apply", "Restore")]
    [string]$Mode = "Apply",

    [switch]$NoUi,

    [switch]$Ui,

    [string]$BackupPath,

    [string]$ReportPath
)

$apexPulse = Join-Path $PSScriptRoot "ApexPulse.ps1"

if (-not (Test-Path -LiteralPath $apexPulse)) {
    $fallbackUrl = "https://raw.githubusercontent.com/mgwals/ltsc-setup/refs/heads/main/ApexPulse.ps1"
    $tempRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $fallbackDir = Join-Path $tempRoot "ApexPulse11"
    $apexPulse = Join-Path $fallbackDir "ApexPulse.ps1"

    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
    Invoke-WebRequest -Uri $fallbackUrl -OutFile $apexPulse
}

$arguments = @{
    Profile = $Profile
    Mode = $Mode
}

if ($NoUi.IsPresent -or -not $Ui.IsPresent) { $arguments.NoUi = $true }
if ($BackupPath) { $arguments.BackupPath = $BackupPath }
if ($ReportPath) { $arguments.ReportPath = $ReportPath }
if ($WhatIfPreference) { $arguments.WhatIf = $true }

& $apexPulse @arguments
