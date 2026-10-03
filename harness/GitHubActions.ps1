<#
.SYNOPSIS
    GitHub Actions workflow commands for the harness: error annotations, log groups and the job summary.

.DESCRIPTION
    Dot-sourced by the checks. Outside GitHub Actions (GITHUB_ACTIONS not 'true'), every function does nothing,
    so the local output stays unchanged. Never pass a secret value: annotations are public on a public repository.
#>

# Messages and workflow commands are written in UTF-8, even when the output is redirected (CI, Test-Harness):
# otherwise a non-ASCII character, such as the changelog emojis, is printed as '?'.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { Write-Verbose "Output encoding unchanged: $_" }

function Test-GitHubActions { $env:GITHUB_ACTIONS -eq 'true' }

# Escaping of workflow commands: %, CR and LF in the message; also : and , in a property.
function ConvertTo-CommandValue([string] $Text, [switch] $Property) {
    $Text = $Text.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
    if ($Property) { $Text = $Text.Replace(':', '%3A').Replace(',', '%2C') }
    return $Text
}

# An error annotation, shown on the file and line in the pull request when they are given.
function Write-GitHubError([string] $Title, [string] $Message, [string] $File, [int] $Line) {
    if (-not (Test-GitHubActions)) { return }
    $properties = @()
    if ($File) { $properties += 'file=' + (ConvertTo-CommandValue $File -Property) }
    if ($File -and $Line -gt 0) { $properties += "line=$Line" }
    if ($Title) { $properties += 'title=' + (ConvertTo-CommandValue $Title -Property) }
    $command = if ($properties) { '::error ' + ($properties -join ',') } else { '::error' }
    Write-Host "${command}::$(ConvertTo-CommandValue $Message)"
}

# A collapsible section of the log, closed by Stop-GitHubGroup.
function Start-GitHubGroup([string] $Title) { if (Test-GitHubActions) { Write-Host "::group::$Title" } }
function Stop-GitHubGroup { if (Test-GitHubActions) { Write-Host '::endgroup::' } }

# Markdown appended to the summary shown on the page of the run.
function Add-GitHubSummary([string[]] $Lines) {
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Lines -Encoding utf8 }
}
