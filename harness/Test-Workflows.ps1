#Requires -Version 7.3
<#
.SYNOPSIS
    Audits the GitHub Actions workflows with zizmor. Exit 0 = green, 1 = red, 2 = could not run.

.DESCRIPTION
    Runs zizmor, offline, with its default persona on .github/workflows: template injection, credentials left
    by checkout, excessive permissions, unpinned actions, dangerous triggers... Every finding is red, whatever
    its severity. A finding accepted on purpose is ignored in the workflow itself, with a comment
    `# zizmor: ignore[<audit>]` saying why.
    Messages give the audit, the file and the line; on GitHub Actions, each finding is also an error annotation.
    zizmor missing from the PATH: exit 2, with the command that installs it.

.PARAMETER Root
    Repository root. Defaults to the parent of this folder; point it to a copy to see a rule fail.
#>
param([string] $Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'GitHubActions.ps1')

if (-not (Get-Command zizmor -ErrorAction SilentlyContinue)) {
    Write-Host 'zizmor not found: install it with "python -m pip install -r harness/requirements.txt" (see docs/CONTRIBUTING.md, Setup).' -ForegroundColor Yellow
    exit 2
}

Push-Location $Root
try {
    $json = zizmor --offline --no-progress --format json-v1 .github/workflows 2>$null | Out-String
    $code = $LASTEXITCODE
} finally { Pop-Location }
# zizmor exits 0 without finding, 10 or more with findings; anything else is a failure of its own.
if ($code -ne 0 -and $code -lt 10) { Write-Host "zizmor failed (exit $code)." -ForegroundColor Yellow; exit 2 }

$findings = @($json | ConvertFrom-Json -NoEnumerate | ForEach-Object { $_ } | Where-Object { -not $_.ignored })
foreach ($f in $findings) {
    $primary = @($f.locations | Where-Object { $_.symbolic.kind -eq 'Primary' })[0] ?? $f.locations[0]
    $file = $primary.symbolic.key.Local.verbatim_path -replace '\\', '/'
    $line = $primary.concrete.location.start_point.row + 1
    $message = "$($f.desc): $($primary.symbolic.annotation)"
    Write-Host "[$($f.ident)] ${file}:$line $message" -ForegroundColor Red
    Write-GitHubError "zizmor $($f.ident)" $message $file $line
}

if ($findings) { Write-Host "RED: $($findings.Count) finding(s)." -ForegroundColor Red; exit 1 }
Write-Host "GREEN: workflows audited by $(zizmor --version)." -ForegroundColor Green
exit 0
