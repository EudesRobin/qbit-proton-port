#Requires -Version 7.3
<#
.SYNOPSIS
    Analyzes the PowerShell files with PSScriptAnalyzer. Exit 0 = green, 1 = red, 2 = could not run.

.DESCRIPTION
    Runs PSScriptAnalyzer on every .ps1, .psm1 and .psd1 file of the repository, with the errors and warnings
    of PSScriptAnalyzerSettings.psd1. Every finding is red. A rule is excluded in that file, with the reason;
    a single finding is suppressed where it occurs, with a SuppressMessageAttribute and its justification.
    Messages give the rule, the file and the line; on GitHub Actions, each finding is also an error annotation.
    Any PSScriptAnalyzer version runs locally, 1.25.0 in CI. Without the module: exit 2, with the command
    that installs it.

.PARAMETER Root
    Repository root. Defaults to the parent of this folder; point it to a copy to see a rule fail.
#>
param([string] $Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'GitHubActions.ps1')

$module = Get-Module -ListAvailable PSScriptAnalyzer | Sort-Object Version -Descending | Select-Object -First 1
if (-not $module) {
    Write-Host 'PSScriptAnalyzer not found: install it with "Install-PSResource PSScriptAnalyzer -Version 1.25.0 -Scope CurrentUser -TrustRepository" (see docs/CONTRIBUTING.md, Setup).' -ForegroundColor Yellow
    exit 2
}
Import-Module $module.Path

# Errors are collected, not thrown: thrown during a recursive analysis, one leaves the process hanging.
$findings = @(Invoke-ScriptAnalyzer -Path $Root -Recurse -Settings (Join-Path $Root 'PSScriptAnalyzerSettings.psd1') `
    -ErrorAction SilentlyContinue -ErrorVariable failures)
if ($failures) {
    # A failure of the analyzer itself, such as a SuppressMessageAttribute that matches nothing.
    $failures | ForEach-Object { Write-Host "PSScriptAnalyzer failed: $($_.Exception.Message)" -ForegroundColor Yellow }
    exit 2
}
foreach ($f in $findings) {
    $file = [IO.Path]::GetRelativePath($Root, $f.ScriptPath) -replace '\\', '/'
    Write-Host "[$($f.RuleName)] ${file}:$($f.Line) $($f.Message)" -ForegroundColor Red
    Write-GitHubError "PSScriptAnalyzer $($f.RuleName)" $f.Message $file $f.Line
}

if ($findings) { Write-Host "RED: $($findings.Count) finding(s)." -ForegroundColor Red; exit 1 }
Write-Host "GREEN: PowerShell files analyzed by PSScriptAnalyzer $($module.Version)." -ForegroundColor Green
exit 0
