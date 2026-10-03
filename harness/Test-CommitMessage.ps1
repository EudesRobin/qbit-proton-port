#Requires -Version 7.3
<#
.SYNOPSIS
    Checks a commit message against the commit rules of docs/CONTRIBUTING.md. Exit 0 = green, 1 = red.

.DESCRIPTION
    Called by the commit-msg hook (.githooks/commit-msg). Rules:
      - the subject starts with an allowed prefix followed by ': ';
      - the subject doesn't end with a period;
      - the whole message has 50 words at most;
      - no AI attribution (Co-Authored-By or "Generated with" naming an AI tool).
    Lines starting with # and everything below git's scissors line are ignored. Merge commits are not checked.
    The language (French) is not checked.

.PARAMETER Path
    File holding the commit message, as passed by git to the hook.
#>
param([Parameter(Mandatory)] [string] $Path)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Prefixes = 'feat', 'fix', 'chore', 'docs', 'refactor', 'test', 'build', 'revert'
$MaxWords = 50
$AiTools  = '(claude|anthropic|copilot|openai|chatgpt|gpt-\d|gemini|\bia\b|\bai\b)'
$AiAttribution = "(?im)co-authored-by:[^\n]*$AiTools|(generated|g[ée]n[ée]r[ée]e?s?) (with|by|avec|par)[^\n]*$AiTools"
$Scissors = '# ------------------------ >8'

$raw = (Get-Content $Path -Raw -Encoding utf8) ?? ''
$lines = ($raw -split [regex]::Escape($Scissors))[0] -split "`r?`n" | Where-Object { $_ -notmatch '^#' }
$message = ($lines -join "`n").Trim()
if (-not $message -or $message.StartsWith('Merge ')) { exit 0 }

$errors = [Collections.Generic.List[string]]::new()
$subject = ($message -split "`n")[0].TrimEnd()
if ($subject -notmatch "^($($Prefixes -join '|')): \S") {
    $errors.Add("the subject must start with one of: $($Prefixes -join ', '), followed by ': '")
}
if ($subject.EndsWith('.')) { $errors.Add('the subject must not end with a period') }
$words = @($message -split '\s+' | Where-Object { $_ }).Count
if ($words -gt $MaxWords) { $errors.Add("$words words, $MaxWords at most (subject and body)") }
if ($message -match $AiAttribution) { $errors.Add('AI attribution is not allowed (Co-Authored-By, Generated with)') }

foreach ($e in $errors) { Write-Host "commit-msg: $e" -ForegroundColor Red }
exit ([int][bool]$errors.Count)
