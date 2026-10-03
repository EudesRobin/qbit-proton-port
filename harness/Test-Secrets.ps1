#Requires -Version 7.3
<#
.SYNOPSIS
    Checks that no runtime file, secret or private value would be published. Exit 0 = green, 1 = red.

.DESCRIPTION
    Rules:
      files        no runtime or key file: .env, secret.xml, logs/, qBittorrent.ini, *.crt, *.key, *.pem, *.pfx
      private-key  no PEM private key block
      fingerprint  no SHA-256 fingerprint (64 hexadecimal characters, with or without colons)
      paths        no user folder path: C:\Users\<name>, /Users/<name>, /home/<name>
      ip           no IPv4 address other than 127.0.0.1, 0.0.0.0 and the allowed OIDs ($AllowedIp)
      local        none of the values of the local runtime .env (QBIT_API_PORT, QBIT_CERT_SHA256), when it exists

    Messages give the file and line, never the matched value. On GitHub Actions, each problem is also
    an error annotation on that file and line, with the same message.

.PARAMETER Root
    Repository root. Defaults to the parent of this folder.

.PARAMETER Staged
    Check the staged changes (pre-commit hook): staged file names and added lines only.
    Without it, check every file git would publish: tracked and untracked, minus ignored ones
    (every file when Root is not a git repository).
#>
param(
    [string] $Root = (Split-Path $PSScriptRoot -Parent),
    [switch] $Staged
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Failures = [Collections.Generic.List[string]]::new()
. (Join-Path $PSScriptRoot 'GitHubActions.ps1')
function Fail([string] $Rule, [string] $Message, [string] $File, [int] $Line) {
    $Failures.Add("[$Rule] $Message")
    Write-GitHubError $Rule $Message $File $Line
}

$ForbiddenFile = '(^|/)(\.env|secret\.xml|qBittorrent\.ini(\.bak)?)$|(^|/)logs/|\.(crt|key|pem|pfx)$'
$Patterns = [ordered]@{
    'private-key' = '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    'fingerprint' = '(?<![0-9A-Fa-f])([0-9A-Fa-f]{64}|([0-9A-Fa-f]{2}:){31}[0-9A-Fa-f]{2})(?![0-9A-Fa-f])'
    # A placeholder (<name>, {name}, %VAR%, $var) is not a real user folder.
    'paths'       = '(?i)\b[a-z]:[\\/]+Users[\\/]+(?![<{%$])[^\\/\s''"`]+|(?<![\w.~])/(home|Users)/(?![<{$])[^/\s]+'
    'ip'          = '(?<![\d.])(\d{1,3}\.){3}\d{1,3}(?![\d.])'
}
# Dotted numbers that are not personal addresses: loopback, any, and the X.509 extension OIDs of -NewCertificate.
$AllowedIp = '127.0.0.1', '0.0.0.0', '2.5.29.17', '2.5.29.37'

# Values of the local runtime .env: not secrets, but they identify this installation.
$dataDir = if ($env:QBIT_PROTON_PORT_HOME) { $env:QBIT_PROTON_PORT_HOME } else { Join-Path $env:LOCALAPPDATA 'qbit-proton-port' }
$envFile = Join-Path $dataDir '.env'
$local = [ordered]@{}
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile -Encoding utf8) {
        if ($line -match '^\s*(QBIT_API_PORT|QBIT_CERT_SHA256)\s*=\s*"?([^"\s]+)"?\s*$') {
            $value = $Matches[2] -replace ':', ''
            $local[$Matches[1]] = if ($Matches[1] -eq 'QBIT_API_PORT') { "(?<!\d)$value(?!\d)" } else { "(?i)$value" }
        }
    }
}

function Test-Line([string] $File, [int] $Number, [string] $Line) {
    foreach ($rule in $Patterns.Keys) {
        $found = @([regex]::Matches($Line, $Patterns[$rule]) | ForEach-Object Value)
        if ($rule -eq 'ip') { $found = $found | Where-Object { $_ -notin $AllowedIp } }
        if ($found) { Fail $rule "${File}:$Number" $File $Number }
    }
    foreach ($name in $local.Keys) {
        # The fingerprint is compared without colons, like the script does.
        $text = if ($name -eq 'QBIT_CERT_SHA256') { $Line -replace ':', '' } else { $Line }
        if ($text -match $local[$name]) { Fail 'local' "${File}:$Number contains your local $name value" $File $Number }
    }
}

$isGit = (git -C $Root rev-parse --is-inside-work-tree 2>$null) -eq 'true'
if ($Staged) {
    if (-not $isGit) { Write-Host "$Root is not a git repository." -ForegroundColor Yellow; exit 2 }
    $files = @(git -C $Root diff --cached --name-only --diff-filter=ACMR)
    foreach ($f in $files) { if ($f -match $ForbiddenFile) { Fail 'files' "$f is staged" $f } }
    # Added lines only, with the file and line number from each hunk header.
    $file = $null; $number = 0
    foreach ($line in git -C $Root -c core.quotepath=off diff --cached -U0 --no-color --diff-filter=ACMR) {
        if ($line -match '^\+\+\+ (b/)?(.*)$') { $file = $Matches[2]; continue }
        if ($line -match '^@@ -\S+ \+(\d+)') { $number = [int]$Matches[1]; continue }
        if ($line -match '^\+' -and $file) { Test-Line $file $number $line.Substring(1); $number++ }
    }
} else {
    $files = if ($isGit) { @(git -C $Root ls-files --cached --others --exclude-standard) } else {
        @(Get-ChildItem $Root -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($Root, $_.FullName) -replace '\\', '/' })
    }
    foreach ($f in $files) {
        $path = Join-Path $Root $f
        if (-not (Test-Path $path -PathType Leaf)) { continue }   # deleted in the working tree
        if ($f -match $ForbiddenFile) { Fail 'files' "$f would be published" $f }
        $number = 0
        foreach ($line in [IO.File]::ReadLines($path)) { $number++; Test-Line $f $number $line }
    }
}

if ($Failures.Count) {
    $Failures | ForEach-Object { Write-Host $_ -ForegroundColor Red }
    Write-Host "RED: $($Failures.Count) problem(s)." -ForegroundColor Red
    exit 1
}
Write-Host ("GREEN: {0} file(s) checked{1}." -f $files.Count,
    $(if ($local.Count) { ", with the local .env values" } else { '' })) -ForegroundColor Green
exit 0
