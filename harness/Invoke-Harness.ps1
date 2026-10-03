#Requires -Version 7.3
<#
.SYNOPSIS
    Runs every offline check of the harness. Exit 0 = all green, 1 = a check is red, 2 = a check could not run.

.DESCRIPTION
    The single entry point of the Definition of Done's Test step, of the pre-commit hook and of CI.
    A new check is added to $Checks, never to its callers.
    Each check prints its duration. On GitHub Actions, each check is a collapsible log group,
    and a table of the results is added to the job summary.

.PARAMETER CommitRange
    Git range whose commit messages are also checked, such as origin/main..HEAD. Empty: not checked.
#>
param([string] $CommitRange)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'GitHubActions.ps1')

# Script and arguments, in order: the checks, then the tests of the checks themselves.
$Checks = @(
    ,@('Test-Consistency.ps1')
    ,@('Test-Secrets.ps1')
    ,@('Test-Workflows.ps1')
    if ($CommitRange) { ,@('Test-CommitMessage.ps1', '-Range', $CommitRange) }
    ,@('Test-Harness.ps1')
)

$Verdicts = @{ 0 = 'green'; 1 = 'red'; 2 = 'could not run' }
$worst = 0
$rows = [Collections.Generic.List[string]]::new()
foreach ($c in $Checks) {
    $script, $arguments = $c
    $name = "$script $arguments".Trim()
    Start-GitHubGroup $name
    Write-Host "== $name" -ForegroundColor Cyan
    $timer = [Diagnostics.Stopwatch]::StartNew()
    & pwsh -NoProfile -File (Join-Path $PSScriptRoot $script) @arguments
    $code = $LASTEXITCODE
    $seconds = '{0:N1} s' -f $timer.Elapsed.TotalSeconds
    Write-Host "== $name : exit $code, $seconds" -ForegroundColor Cyan
    Stop-GitHubGroup
    # 1 (red) outranks 2 (could not run), which outranks 0 (green).
    if ($code -eq 1 -or ($code -ne 0 -and $worst -ne 1)) { $worst = if ($code -eq 2) { 2 } else { 1 } }
    $rows.Add("| ``$name`` | $($Verdicts[$code] ?? "exit $code") | $seconds |")
}

$verdict = @{ 0 = 'GREEN: all checks passed.'; 1 = 'RED: a check failed.'; 2 = 'INCOMPLETE: a check could not run.' }[$worst]
Add-GitHubSummary (@('## Harness', '', '| Check | Result | Duration |', '|---|---|---|') + $rows + @('', "**$verdict**"))
Write-Host $verdict -ForegroundColor (@{ 0 = 'Green'; 1 = 'Red'; 2 = 'Yellow' }[$worst])
exit $worst
