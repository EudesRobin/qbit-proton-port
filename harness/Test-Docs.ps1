#Requires -Version 7.3
<#
.SYNOPSIS
    Checks that the documentation still matches Sync-QbitProtonPort.ps1. Exit 0 = green, 1 = red.

.DESCRIPTION
    Rules:
      1. The script parses without errors.
      2. Every script parameter appears in README.md as -Name.
      3. Every setting in .env.example and every overriding environment variable appears in README.md.
      4. No omission: every error (throw), warning (Write-Log WARN) and WebUI diagnostic of the script
         is matched by a row of the README troubleshooting tables.
      5. No stale entry: every message fragment quoted in the troubleshooting tables exists in the script.
      6. Every relative link in the Markdown files resolves.

    Troubleshooting rows quote the static part of a message in backticks; "..." stands for a variable part.
    A message is matched when one of its static parts (10+ characters) and a quoted fragment contain each other.

.PARAMETER Root
    Repository root. Defaults to the parent of this folder; point it to a copy to see a rule fail.
#>
param([string] $Root = (Split-Path $PSScriptRoot -Parent))

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptPath = Join-Path $Root 'Sync-QbitProtonPort.ps1'
$ReadmePath = Join-Path $Root 'README.md'
$Failures   = [Collections.Generic.List[string]]::new()
function Fail([string] $Rule, [string] $Message) { $Failures.Add("[$Rule] $Message") }

# Environment variables the script only reads from Windows, not user-facing settings.
$SystemEnv = 'LOCALAPPDATA', 'APPDATA', 'USERNAME', 'USERDOMAIN'
$MinLength = 10
$TrimChars = [char[]]" `t.,:;()'`"!?"

$readme = Get-Content $ReadmePath -Raw -Encoding utf8
$scriptText = Get-Content $ScriptPath -Raw -Encoding utf8

# --- 1. Parse --------------------------------------------------------------------
$tokens = $null; $parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$parseErrors)
foreach ($e in $parseErrors) { Fail 'parse' "line $($e.Extent.StartLineNumber): $($e.Message)" }

# --- 2. Parameters ---------------------------------------------------------------------
foreach ($p in $ast.ParamBlock.Parameters) {
    $name = $p.Name.VariablePath.UserPath
    if ($readme -notmatch "-$name\b") { Fail 'params' "parameter -$name is not documented in README.md" }
}

# --- 3. Settings and environment variables ------------------------------------------
foreach ($line in Get-Content (Join-Path $Root '.env.example') -Encoding utf8) {
    if ($line -match '^\s*([A-Z0-9_]+)\s*=' -and $readme -notmatch "``$($Matches[1])``") {
        Fail 'settings' "setting $($Matches[1]) (.env.example) is not documented in README.md"
    }
}
$envVars = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and
        $n.VariablePath.DriveName -eq 'env' }, $true) |
    ForEach-Object { $_.VariablePath.UserPath -replace '^env:', '' } | Sort-Object -Unique
foreach ($v in $envVars | Where-Object { $_ -notin $SystemEnv }) {
    if ($readme -notmatch "``$v``") { Fail 'settings' "environment variable $v is not documented in README.md" }
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
        $n.GetCommandName() -eq 'Write-Log' -and $n.CommandElements.Count -ge 3 -and
        $n.CommandElements[1].Extent.Text -eq 'WARN' }, $true)) {
    $messages.Add([pscustomobject]@{ Line = $c.Extent.StartLineNumber; Parts = @(Get-StaticParts $c.CommandElements[2]) })
}
$diag = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-WebUiDiagnostic' }, $true)
if ($diag) {
    foreach ($r in $diag.FindAll({ param($n) $n -is [Management.Automation.Language.ReturnStatementAst] -and $n.Pipeline }, $true)) {
        $messages.Add([pscustomobject]@{ Line = $r.Extent.StartLineNumber; Parts = @(Get-StaticParts $r.Pipeline) })
    }
}

# --- Troubleshooting fragments of the README -------------------------------------------
$section = [regex]::Match($readme, '(?ms)^## Troubleshooting\s*$(.*?)(?=^## |\z)').Groups[1].Value
if (-not $section) { Fail 'readme' 'README.md has no "## Troubleshooting" section' }
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
    if (-not $covered) { Fail 'omission' "line $($msg.Line): '$($msg.Parts[0])' has no row in README Troubleshooting" }
}

# --- 5. No stale entry -------------------------------------------------------------------
foreach ($f in $fragments | Sort-Object -Unique) {
    if (-not $scriptText.Contains($f)) { Fail 'stale' "README Troubleshooting quotes '$f', which the script no longer contains" }
}

# --- 6. Relative links -----------------------------------------------------------------------
foreach ($md in Get-ChildItem $Root -Recurse -Filter *.md -File | Where-Object FullName -notmatch '\\\.git\\') {
    $text = Get-Content $md.FullName -Raw -Encoding utf8
    foreach ($m in [regex]::Matches($text, '\]\(([^)\s#]+)(#[^)]*)?\)')) {
        $target = $m.Groups[1].Value
        if ($target -match '^[a-z]+:') { continue }   # http:, https:, mailto:
        if (-not (Test-Path (Join-Path $md.DirectoryName $target))) {
            Fail 'links' "$($md.Name): link '$target' doesn't resolve"
        }
    }
}

# --- Result ---------------------------------------------------------------------------------
if ($Failures.Count) {
    $Failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host "RED: $($Failures.Count) problem(s)." -ForegroundColor Red
    exit 1
}
Write-Host ("GREEN: {0} parameters, {1} messages, {2} troubleshooting fragments checked." -f
    $ast.ParamBlock.Parameters.Count, $messages.Count, @($fragments).Count) -ForegroundColor Green
exit 0
