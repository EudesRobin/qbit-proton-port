#Requires -Version 7.3
<#
.SYNOPSIS
    Runs the Pester tests of tests/. Exit 0 = green, 1 = red, 2 = could not run.

.DESCRIPTION
    The tests cover the functions of Sync-QbitProtonPort.ps1 that don't need Proton VPN or qBittorrent:
    reading the Proton VPN log, editing qBittorrent.ini, reading and writing the .env file.
    They need Pester 6: any 6.x version installed locally, 6.1.0 in CI. Without it, exit 2 with the command
    that installs it. On GitHub Actions, each failed test is also an error annotation on its line.

.PARAMETER Root
    Repository root. Defaults to the parent of this folder; point it to a copy to see a test fail.
#>
param([string] $Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'GitHubActions.ps1')

$pester = Get-Module -ListAvailable Pester | Where-Object { $_.Version.Major -eq 6 } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) {
    Write-Host 'Pester 6 not found: install it with "Install-Module Pester -RequiredVersion 6.1.0 -Force -SkipPublisherCheck" (see docs/CONTRIBUTING.md, Setup).' -ForegroundColor Yellow
    exit 2
}
Import-Module $pester.Path

$config = New-PesterConfiguration
$config.Run.Path = Join-Path $Root 'tests'
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $config

foreach ($test in $result.Failed) {
    $file = [IO.Path]::GetRelativePath($Root, $test.ScriptBlock.File) -replace '\\', '/'
    $message = "$($test.ExpandedPath): $($test.ErrorRecord[0].Exception.Message)"
    Write-GitHubError 'Pester' $message $file $test.ScriptBlock.StartPosition.StartLine
}

if ($result.Result -ne 'Passed') {
    Write-Host "RED: $($result.FailedCount) test(s) failed, $($result.FailedBlocksCount) block(s) failed to run." -ForegroundColor Red
    exit 1
}
Write-Host "GREEN: $($result.PassedCount) test(s) passed with Pester $($pester.Version)." -ForegroundColor Green
exit 0
