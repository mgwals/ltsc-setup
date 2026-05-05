<#
.SYNOPSIS
    Compatibility launcher for Win11 GameBoost.

.DESCRIPTION
    The original project entry point was setup.ps1. Keep it as a thin wrapper
    so old install notes still work while the real product lives in GameBoost.ps1.
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

$gameBoost = Join-Path $PSScriptRoot "GameBoost.ps1"

if (-not (Test-Path -LiteralPath $gameBoost)) {
    $fallbackUrl = "https://raw.githubusercontent.com/mgwals/ltsc-setup/refs/heads/main/GameBoost.ps1"
    $tempRoot = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
    $fallbackDir = Join-Path $tempRoot "Win11GameBoost"
    $gameBoost = Join-Path $fallbackDir "GameBoost.ps1"

    New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
    Invoke-WebRequest -Uri $fallbackUrl -OutFile $gameBoost
}

$arguments = @{
    Profile = $Profile
    Mode = $Mode
}

if ($NoUi.IsPresent -or -not $Ui.IsPresent) { $arguments.NoUi = $true }
if ($BackupPath) { $arguments.BackupPath = $BackupPath }
if ($ReportPath) { $arguments.ReportPath = $ReportPath }
if ($WhatIfPreference) { $arguments.WhatIf = $true }

& $gameBoost @arguments
