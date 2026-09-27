#Requires -Version 7.3
<#
.SYNOPSIS
    Runs every offline check of the harness. Exit 0 = all green, 1 = a check is red, 2 = a check could not run.

.DESCRIPTION
    The single entry point of the Definition of Done's Test step, of the pre-commit hook and of CI.
    A new check is added to $Checks, never to its callers.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

# Script and arguments, in order: the checks, then the tests of the checks themselves.
$Checks = @(
    ,@('Test-Consistency.ps1')
    ,@('Test-Secrets.ps1')
    ,@('Test-Harness.ps1')
)

$worst = 0
foreach ($c in $Checks) {
    $script, $arguments = $c
    Write-Host "== $script $arguments" -ForegroundColor Cyan
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot $script) @arguments
    $code = $LASTEXITCODE
    # 1 (red) outranks 2 (could not run), which outranks 0 (green).
    if ($code -eq 1 -or ($code -ne 0 -and $worst -ne 1)) { $worst = if ($code -eq 2) { 2 } else { 1 } }
}

$verdict = @{ 0 = 'GREEN: all checks passed.'; 1 = 'RED: a check failed.'; 2 = 'INCOMPLETE: a check could not run.' }[$worst]
Write-Host $verdict -ForegroundColor (@{ 0 = 'Green'; 1 = 'Red'; 2 = 'Yellow' }[$worst])
exit $worst
