<#
.SYNOPSIS
    Legacy redirect to ApexPulse 11.

.DESCRIPTION
    GameBoost.ps1 has been superseded by ApexPulse.ps1. This wrapper forwards
    all parameters so existing automation and shortcuts keep working.
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

$apexPulse = Join-Path $PSScriptRoot "ApexPulse.ps1"

if (-not (Test-Path -LiteralPath $apexPulse)) {
    throw "ApexPulse.ps1 not found alongside GameBoost.ps1. Please download the full release."
}

$arguments = @{
    Profile = $Profile
    Mode    = $Mode
}

if ($NoUi.IsPresent) { $arguments.NoUi = $true }
if ($BackupPath) { $arguments.BackupPath = $BackupPath }
if ($ReportPath) { $arguments.ReportPath = $ReportPath }
if ($WhatIfPreference) { $arguments.WhatIf = $true }

& $apexPulse @arguments
