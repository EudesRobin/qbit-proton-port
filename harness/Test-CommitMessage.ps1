#Requires -Version 7.3
<#
.SYNOPSIS
    Checks commit messages against the commit rules of docs/CONTRIBUTING.md. Exit 0 = green, 1 = red, 2 = could not run.

.DESCRIPTION
    Rules:
      - the subject starts with an allowed prefix followed by ': ';
      - the subject doesn't end with a period;
      - the whole message has 50 words at most;
      - no AI attribution (Co-Authored-By or "Generated with" naming an AI tool).
    Lines starting with # and everything below git's scissors line are ignored. Merge commits are not checked.
    The language (French) is not checked.

    -Path checks one message file: the commit-msg hook (.githooks/commit-msg).
    -Range checks every commit of a git range, merges excepted: CI, through Invoke-Harness.ps1 -CommitRange.
    On GitHub Actions, each problem is also an error annotation naming the commit.

.PARAMETER Path
    File holding the commit message, as passed by git to the hook.

.PARAMETER Range
    Git range of the commits to check, such as origin/main..HEAD.

.PARAMETER Root
    Repository holding the range. Defaults to the parent of this folder.
#>
[CmdletBinding(DefaultParameterSetName = 'Path')]
param(
    [Parameter(Mandatory, Position = 0, ParameterSetName = 'Path')] [string] $Path,   # by position from the hook
    [Parameter(Mandatory, ParameterSetName = 'Range')] [string] $Range,
    [Parameter(ParameterSetName = 'Range')] [string] $Root = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'GitHubActions.ps1')

$Prefixes = 'feat', 'fix', 'chore', 'docs', 'refactor', 'test', 'build', 'revert'
$MaxWords = 50
$AiTools  = '(claude|anthropic|copilot|openai|chatgpt|gpt-\d|gemini|\bia\b|\bai\b)'
$AiAttribution = "(?im)co-authored-by:[^\n]*$AiTools|(generated|g[ée]n[ée]r[ée]e?s?) (with|by|avec|par)[^\n]*$AiTools"
$Scissors = '# ------------------------ >8'

# The rules broken by a raw commit message, as a list of errors.
function Test-Message([string] $Raw) {
    $lines = ($Raw -split [regex]::Escape($Scissors))[0] -split "`r?`n" | Where-Object { $_ -notmatch '^#' }
    $message = ($lines -join "`n").Trim()
    if (-not $message -or $message.StartsWith('Merge ')) { return }

    $subject = ($message -split "`n")[0].TrimEnd()
    if ($subject -notmatch "^($($Prefixes -join '|')): \S") {
        "the subject must start with one of: $($Prefixes -join ', '), followed by ': '"
    }
    if ($subject.EndsWith('.')) { 'the subject must not end with a period' }
    $words = @($message -split '\s+' | Where-Object { $_ }).Count
    if ($words -gt $MaxWords) { "$words words, $MaxWords at most (subject and body)" }
    if ($message -match $AiAttribution) { 'AI attribution is not allowed (Co-Authored-By, Generated with)' }
}

if ($PSCmdlet.ParameterSetName -eq 'Path') {
    $errors = @(Test-Message ((Get-Content $Path -Raw -Encoding utf8) ?? ''))
    foreach ($e in $errors) { Write-Host "commit-msg: $e" -ForegroundColor Red }
    exit ([int][bool]$errors.Count)
}

$commits = @(git -C $Root log --no-merges --format=%H $Range)
if ($LASTEXITCODE -ne 0) { Write-Host "Cannot read the commits of range $Range." -ForegroundColor Yellow; exit 2 }
$failed = 0
foreach ($sha in $commits) {
    $short = $sha.Substring(0, 7)
    $errors = @(Test-Message ((git -C $Root log -1 --format=%B $sha) -join "`n"))
    if ($errors) { $failed++ }
    foreach ($e in $errors) {
        Write-Host "commit ${short}: $e" -ForegroundColor Red
        Write-GitHubError "commit $short" $e
    }
}
if ($failed) { Write-Host "RED: $failed of $($commits.Count) commit(s) break the commit rules." -ForegroundColor Red; exit 1 }
Write-Host "GREEN: $($commits.Count) commit(s) checked in $Range." -ForegroundColor Green
exit 0
