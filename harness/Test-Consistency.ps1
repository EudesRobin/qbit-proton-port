#Requires -Version 7.3
<#
.SYNOPSIS
    Checks that Sync-QbitProtonPort.ps1, its settings template and the Markdown files agree. Exit 0 = green, 1 = red.

.DESCRIPTION
    Rules:
      1. The script parses without errors.
      2. Every script parameter appears in README.md as -Name.
      3. Every setting in .env.example and every overriding environment variable appears in README.md.
      4. No omission: every error (throw), warning (Write-Log WARN) and WebUI diagnostic of the script
         is matched by a row of the README troubleshooting tables.
      5. No stale entry: every message fragment quoted in the troubleshooting tables exists in the script.
      6. Every relative link in the Markdown files resolves, inline or reference-style.
      7. Every anchor (#heading) of a link to a Markdown file matches a heading of that file.
      8. Every setting the script reads (Get-Setting) is in .env.example.
      9. Every Markdown table has at least one data row.
     10. No text follows a closing code fence on its line: GitHub would keep the block open to the end of the file.
     11. CHANGELOG.md follows Keep a Changelog: its first section is ## [Unreleased], the others are
         ## [X.Y.Z] - YYYY-MM-DD with decreasing versions and dates, subsections are Upgrade, Added, Changed, Deprecated, Removed, Fixed or Security,
         every section has a link reference, and a version raising MAJOR has an Upgrade subsection.

    Troubleshooting rows quote the static part of a message in backticks; "..." stands for a variable part.
    A message is matched when one of its static parts (10+ characters) and a quoted fragment contain each other.

    On GitHub Actions, each problem is also an error annotation on its file, and on its line when known.

.PARAMETER Root
    Repository root. Defaults to the parent of this folder; point it to a copy to see a rule fail.
#>
param([string] $Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptFile = 'Sync-QbitProtonPort.ps1'
$ScriptPath = Join-Path $Root $ScriptFile
$ReadmePath = Join-Path $Root 'README.md'
$EnvExample = Join-Path $Root '.env.example'
$Failures   = [Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot 'GitHubActions.ps1')
# File is relative to Root, with forward slashes: the annotation points to it in the pull request.
function Fail([string] $Rule, [string] $Message, [string] $File, [int] $Line) {
    $Failures.Add("[$Rule] $Message")
    Write-GitHubError $Rule $Message $File $Line
}

# Environment variables the script only reads from Windows, not user-facing settings.
$SystemEnv = 'LOCALAPPDATA', 'APPDATA', 'USERNAME', 'USERDOMAIN'
$MinLength = 10
$TrimChars = [char[]]" `t.,:;()'`"!?"

$readme = Get-Content $ReadmePath -Raw -Encoding utf8
$scriptText = Get-Content $ScriptPath -Raw -Encoding utf8
$templateNames = foreach ($line in Get-Content $EnvExample -Encoding utf8) {
    if ($line -match '^\s*([A-Z0-9_]+)\s*=') { $Matches[1] }
}

# --- 1. Parse --------------------------------------------------------------------
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
foreach ($e in $parseErrors) { Fail 'parse' "line $($e.Extent.StartLineNumber): $($e.Message)" $ScriptFile $e.Extent.StartLineNumber }

# --- 2. Parameters ---------------------------------------------------------------------
foreach ($p in $ast.ParamBlock.Parameters) {
    $name = $p.Name.VariablePath.UserPath
    if ($readme -notmatch "-$name\b") { Fail 'params' "parameter -$name is not documented in README.md" $ScriptFile $p.Extent.StartLineNumber }
}

# --- 3. Settings and environment variables ------------------------------------------
foreach ($name in $templateNames) {
    if ($readme -notmatch "``$name``") { Fail 'settings' "setting $name (.env.example) is not documented in README.md" '.env.example' }
}
$envVars = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and
        $n.VariablePath.DriveName -eq 'env' }, $true) |
    ForEach-Object { $_.VariablePath.UserPath -replace '^env:', '' } | Sort-Object -Unique
foreach ($v in $envVars | Where-Object { $_ -notin $SystemEnv }) {
    if ($readme -notmatch "``$v``") { Fail 'settings' "environment variable $v is not documented in README.md" $ScriptFile }
}

# --- Arguments of a command call, by parameter name then by position ----------------------
function Get-CommandArguments([Management.Automation.Language.CommandAst] $Command, [string[]] $Positional) {
    $bound = @{}; $position = 0
    $elements = $Command.CommandElements
    for ($i = 1; $i -lt $elements.Count; $i++) {
        $e = $elements[$i]
        if ($e -is [Management.Automation.Language.CommandParameterAst]) {
            if ($e.Argument) { $bound[$e.ParameterName] = $e.Argument }
            elseif ($i + 1 -lt $elements.Count) { $bound[$e.ParameterName] = $elements[++$i] }
        } elseif ($position -lt $Positional.Count) {
            while ($position -lt $Positional.Count -and $bound.ContainsKey($Positional[$position])) { $position++ }
            if ($position -lt $Positional.Count) { $bound[$Positional[$position++]] = $e }
        }
    }
    return $bound
}

# --- 8. Settings read by the script are in the template -----------------------------------
foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Get-Setting' }, $true)) {
    $name = (Get-CommandArguments $c 'Settings', 'Name')['Name']
    if ($name -is [Management.Automation.Language.StringConstantExpressionAst] -and $name.Value -notin $templateNames) {
        Fail 'template' "line $($c.Extent.StartLineNumber): setting $($name.Value) is read by the script but missing from .env.example" $ScriptFile $c.Extent.StartLineNumber
    }
}

# --- Messages of the script ----------------------------------------------------------
function Get-StaticParts([Management.Automation.Language.Ast] $Node) {
    # Unwrap ('format {0}' -f ...) and (...) to the string literal.
    while ($Node -is [Management.Automation.Language.ParenExpressionAst] -or
           $Node -is [Management.Automation.Language.PipelineAst] -or
           $Node -is [Management.Automation.Language.CommandExpressionAst] -or
           $Node -is [Management.Automation.Language.BinaryExpressionAst]) {
        $Node = switch ($Node.GetType().Name) {
            'ParenExpressionAst'    { $Node.Pipeline }
            'PipelineAst'           { $Node.PipelineElements[0] }
            'CommandExpressionAst'  { $Node.Expression }
            'BinaryExpressionAst'   { $Node.Left }
        }
    }
    if ($Node -isnot [Management.Automation.Language.StringConstantExpressionAst] -and
        $Node -isnot [Management.Automation.Language.ExpandableStringExpressionAst]) { return @() }
    $raw = $Node.Extent.Text.Substring(1, $Node.Extent.Text.Length - 2)
    # Cut at variables, subexpressions and format placeholders: what remains is always shown as is.
    return @($raw -split '\$\((?>[^()]|\((?<d>)|\)(?<-d>))*\)|\$[\w:]+|\{\d+(:[^}]*)?\}' |
        ForEach-Object { $_.Trim($TrimChars) } | Where-Object { $_.Length -ge $MinLength })
}

$messages = [Collections.Generic.List[object]]::new()
foreach ($t in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.ThrowStatementAst] -and $n.Pipeline }, $true)) {
    $messages.Add([pscustomobject]@{ Line = $t.Extent.StartLineNumber; Parts = @(Get-StaticParts $t.Pipeline) })
}
foreach ($c in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] -and
        $n.GetCommandName() -eq 'Write-Log' }, $true)) {
    $arguments = Get-CommandArguments $c 'Level', 'Message'
    if ($arguments['Level'] -and $arguments['Level'].Extent.Text.Trim("'`"") -eq 'WARN' -and $arguments['Message']) {
        $messages.Add([pscustomobject]@{ Line = $c.Extent.StartLineNumber; Parts = @(Get-StaticParts $arguments['Message']) })
    }
}
$diag = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WebUiDiagnostic' }, $true)
if ($diag) {
    foreach ($r in $diag.FindAll({ param($n) $n -is [Management.Automation.Language.ReturnStatementAst] -and $n.Pipeline }, $true)) {
        $messages.Add([pscustomobject]@{ Line = $r.Extent.StartLineNumber; Parts = @(Get-StaticParts $r.Pipeline) })
    }
}

# --- Troubleshooting fragments of the README -------------------------------------------
$section = [regex]::Match($readme, '(?ms)^## Troubleshooting\s*$(.*?)(?=^## |\z)').Groups[1].Value
if (-not $section) { Fail 'readme' 'README.md has no "## Troubleshooting" section' 'README.md' }
$fragments = foreach ($row in $section -split "`r?`n" | Where-Object { $_ -match '^\|\s*`' }) {
    $firstCell = ($row -split '(?<!\\)\|')[1]
    foreach ($m in [regex]::Matches($firstCell, '`([^`]+)`')) {
        foreach ($piece in $m.Groups[1].Value -split '\.\.\.') {
            $piece = $piece.Trim($TrimChars)
            if ($piece.Length -ge 3) { $piece }
        }
    }
}

# --- 4. No omission --------------------------------------------------------------------
foreach ($msg in $messages) {
    if (-not $msg.Parts) { continue }   # bare rethrow or fully dynamic message
    $covered = $msg.Parts | Where-Object { $part = $_
        $fragments | Where-Object { $_.Length -ge $MinLength -and ($part.Contains($_) -or $_.Contains($part)) } }
    if (-not $covered) { Fail 'omission' "line $($msg.Line): '$($msg.Parts[0])' has no row in README Troubleshooting" $ScriptFile $msg.Line }
}

# --- 5. No stale entry -------------------------------------------------------------------
foreach ($f in $fragments | Sort-Object -Unique) {
    if (-not $scriptText.Contains($f)) { Fail 'stale' "README Troubleshooting quotes '$f', which the script no longer contains" 'README.md' }
}

# --- Markdown files: lines outside fenced code blocks ----------------------------------------
function Get-LineNumber([string] $Text, [int] $Index) { ($Text.Substring(0, $Index) -split "`n").Count }

function Get-ProseLines([string] $Text) {
    $inFence = $false
    foreach ($line in $Text -split "`r?`n") {
        if ($line -match '^\s*(```|~~~)') { $inFence = -not $inFence; continue }
        if (-not $inFence) { $line }
    }
}

# GitHub heading anchors: lower case, punctuation dropped, spaces to hyphens, -1, -2... for duplicates.
function Get-Anchors([string] $Path) {
    $seen = @{}
    foreach ($line in Get-ProseLines (Get-Content $Path -Raw -Encoding utf8)) {
        if ($line -notmatch '^#{1,6}\s+(.+?)\s*#*\s*$') { continue }
        $slug = ($Matches[1].ToLowerInvariant() -replace '[^\p{L}\p{Nd}\s_-]', '') -replace '\s', '-'
        if ($seen.ContainsKey($slug)) { $seen[$slug]++; "$slug-$($seen[$slug])" } else { $seen[$slug] = 0; $slug }
    }
}

$mdFiles = Get-ChildItem $Root -Recurse -Filter *.md -File | Where-Object FullName -notmatch '\\\.git\\'
$anchorCache = @{}
foreach ($md in $mdFiles) {
    $rel = [IO.Path]::GetRelativePath($Root, $md.FullName) -replace '\\', '/'
    $text = Get-Content $md.FullName -Raw -Encoding utf8
    $prose = @(Get-ProseLines $text)

    # --- 10. Closing fences carry no text ----------------------------------------------------------
    $inFence = $false
    $n = 0
    foreach ($line in $text -split "`r?`n") {
        $n++
        if ($line -notmatch '^\s*(```|~~~)') { continue }
        if ($inFence -and $line -match '^\s*(```|~~~)\s*\S') { Fail 'fences' "${rel}: line ${n}: text after a closing fence" $rel $n }
        $inFence = -not $inFence
    }

    # --- 6. Relative links and 7. anchors ------------------------------------------------------
    $links = @([regex]::Matches($text, '\]\(([^)\s#]*)(#[^)\s]*)?\)')) +
             @([regex]::Matches($text, '(?m)^ {0,3}\[[^\]]+\]:\s*<?([^>\s#]*)(#[^>\s]*)?>?'))
    foreach ($m in $links) {
        $target = $m.Groups[1].Value
        $anchor = $m.Groups[2].Value.TrimStart('#')
        if ($target -match '^[a-z]+:') { continue }   # http:, https:, mailto:
        $path = if ($target) { Join-Path $md.DirectoryName $target } else { $md.FullName }
        if (-not (Test-Path $path)) { Fail 'links' "${rel}: link '$target' doesn't resolve" $rel (Get-LineNumber $text $m.Index); continue }
        if (-not $anchor -or $path -notmatch '\.md$') { continue }
        $full = (Resolve-Path $path).Path
        if (-not $anchorCache.ContainsKey($full)) { $anchorCache[$full] = @(Get-Anchors $full) }
        if ($anchor -notin $anchorCache[$full]) {
            Fail 'anchors' "${rel}: anchor '#$anchor' matches no heading of $(Split-Path $full -Leaf)" $rel (Get-LineNumber $text $m.Index)
        }
    }

    # --- 9. Tables have rows ---------------------------------------------------------------------
    for ($i = 0; $i -lt $prose.Count; $i++) {
        # A separator row has at least one pipe; a bare --- is a horizontal rule.
        if ($prose[$i] -notmatch '\|' -or $prose[$i] -notmatch '^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$') { continue }
        if ($i + 1 -ge $prose.Count -or $prose[$i + 1] -notmatch '^\s*\|') {
            Fail 'tables' "${rel}: table header '$($prose[$i - 1].Trim())' has no row" $rel
        }
    }
}

# --- 11. Changelog -----------------------------------------------------------------------------
$ChangelogFile = 'CHANGELOG.md'
$ChangelogSections = 'Upgrade', 'Added', 'Changed', 'Deprecated', 'Removed', 'Fixed', 'Security'
$changelogPath = Join-Path $Root $ChangelogFile
$releases = [Collections.Generic.List[object]]::new()
if (-not (Test-Path $changelogPath)) { Fail 'changelog' "$ChangelogFile is missing" $ChangelogFile }
else {
    $changelog = Get-Content $changelogPath -Raw -Encoding utf8
    $n = 0; $headings = 0; $current = $null
    foreach ($line in $changelog -split "`r?`n") {
        $n++
        if ($line -match '^##\s+(.+?)\s*$') {
            $heading = $Matches[1]; $headings++; $current = $null
            if ($headings -eq 1) {
                if ($heading -ne '[Unreleased]') { Fail 'changelog' "${ChangelogFile}: line ${n}: the first section must be ## [Unreleased]" $ChangelogFile $n }
                continue
            }
            $date = [datetime]::MinValue
            if ($heading -match '^\[(\d+\.\d+\.\d+)\] - (\d{4}-\d\d-\d\d)$' -and
                [datetime]::TryParseExact($Matches[2], 'yyyy-MM-dd', $null, 'None', [ref]$date)) {
                $current = [pscustomobject]@{ Version = [version]$Matches[1]; Date = $date; Line = $n
                                              Sections = [Collections.Generic.List[string]]::new() }
                $releases.Add($current)
            } else {
                Fail 'changelog' "${ChangelogFile}: line ${n}: '## $heading' is not '## [X.Y.Z] - YYYY-MM-DD'" $ChangelogFile $n
            }
        } elseif ($line -match '^###\s+(.+?)\s*$') {
            if ($Matches[1] -notin $ChangelogSections) {
                Fail 'changelog' "${ChangelogFile}: line ${n}: '### $($Matches[1])' is not one of: $($ChangelogSections -join ', ')" $ChangelogFile $n
            } elseif ($current) { $current.Sections.Add($Matches[1]) }
        }
    }
    if (-not $headings) { Fail 'changelog' "$ChangelogFile has no ## [Unreleased] section" $ChangelogFile }
    for ($i = 1; $i -lt $releases.Count; $i++) {
        $newer = $releases[$i - 1]; $older = $releases[$i]
        if ($older.Version -ge $newer.Version) {
            Fail 'changelog' "${ChangelogFile}: line $($older.Line): versions must be in decreasing order ($($older.Version) after $($newer.Version))" $ChangelogFile $older.Line
        }
        if ($older.Date -gt $newer.Date) {
            Fail 'changelog' "${ChangelogFile}: line $($older.Line): dates must not increase down the file" $ChangelogFile $older.Line
        }
        if ($newer.Version.Major -gt $older.Version.Major -and 'Upgrade' -notin $newer.Sections) {
            Fail 'changelog' "${ChangelogFile}: line $($newer.Line): $($newer.Version) raises MAJOR and has no ### Upgrade section" $ChangelogFile $newer.Line
        }
    }
    foreach ($name in @('Unreleased') + @($releases | ForEach-Object { "$($_.Version)" })) {
        if ($changelog -notmatch "(?m)^\[$([regex]::Escape($name))\]:\s*https://") {
            Fail 'changelog' "${ChangelogFile}: no link reference for [$name]" $ChangelogFile
        }
    }
}

# --- Result ---------------------------------------------------------------------------------
if ($Failures.Count) {
    $Failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host "RED: $($Failures.Count) problem(s)." -ForegroundColor Red
    exit 1
}
Write-Host ("GREEN: {0} parameters, {1} messages, {2} troubleshooting fragments, {3} Markdown files, {4} releases checked." -f
    $ast.ParamBlock.Parameters.Count, $messages.Count, @($fragments).Count, @($mdFiles).Count, $releases.Count) -ForegroundColor Green
exit 0
