#Requires -Version 7.3
<#
.SYNOPSIS
    Tests the harness checks: each rule is seen red on a deliberately broken copy of the repository,
    and the real repository stays green. Exit 0 = all cases pass, 1 = a case failed.

.DESCRIPTION
    Each case copies the repository files (tracked and untracked, minus git-ignored ones) to a temporary
    folder, breaks the copy, runs a check against it and expects an exit code and a message fragment.
    Every rule added to a check gets its broken case here.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path $PSScriptRoot -Parent

function Copy-Repository([string] $Destination) {
    foreach ($rel in git -C $Root ls-files --cached --others --exclude-standard) {
        $source = Join-Path $Root $rel
        if (-not (Test-Path $source -PathType Leaf)) { continue }   # deleted in the working tree
        $target = Join-Path $Destination $rel
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item $source $target
    }
}

# Alterations applied to the copy.
function Add-Text([string] $Rel, [string] $Text) {
    { param($d) Add-Content -Path (Join-Path $d $Rel) -Value $Text -Encoding utf8 }.GetNewClosure()
}
function Edit-Text([string] $Rel, [string] $Before, [string] $After) {
    {
        param($d)
        $path = Join-Path $d $Rel
        $text = Get-Content $path -Raw -Encoding utf8
        if (-not $text.Contains($Before)) { throw "pattern not found in ${Rel}: $Before" }
        $i = $text.IndexOf($Before)
        Set-Content -Path $path -Value ($text.Substring(0, $i) + $After + $text.Substring($i + $Before.Length)) -NoNewline -Encoding utf8
    }.GetNewClosure()
}

$Script = 'Sync-QbitProtonPort.ps1'
# Name, check run with -Root <copy>, alteration, expected exit code, expected output fragment.
$Cases = @(
    ,@('real repository', 'Test-Consistency.ps1', $null, 0, 'GREEN')
    ,@('valid anchors', 'Test-Consistency.ps1',
        (Add-Text 'README.md' "`n[a](#troubleshooting) [b](AGENTS.md#harness--verification-loop)`n[c]: AGENTS.md#layout"), 0, 'GREEN')
    ,@('parse error', 'Test-Consistency.ps1', (Add-Text $Script "`nfunction Broken {"), 1, '[parse]')
    ,@('undocumented parameter', 'Test-Consistency.ps1',
        (Edit-Text $Script '[switch] $ShowConfig' "[switch] `$ShowConfig,`n    [switch] `$UndocumentedSwitch"), 1, '[params] parameter -UndocumentedSwitch')
    ,@('undocumented setting', 'Test-Consistency.ps1', (Add-Text '.env.example' 'UNDOCUMENTED_SETTING=1'), 1, '[settings] setting UNDOCUMENTED_SETTING')
    ,@('undocumented environment variable', 'Test-Consistency.ps1',
        (Add-Text $Script "`n`$x = `$env:QBIT_UNDOCUMENTED_VAR"), 1, '[settings] environment variable QBIT_UNDOCUMENTED_VAR')
    ,@('setting missing from template', 'Test-Consistency.ps1',
        (Add-Text $Script "`n`$x = Get-Setting -Settings @{} -Name 'MISSING_FROM_TEMPLATE'"), 1, '[template]')
    ,@('undocumented error', 'Test-Consistency.ps1',
        (Add-Text $Script "`nthrow 'A brand new error nobody documented.'"), 1, "[omission]")
    ,@('undocumented warning, named arguments', 'Test-Consistency.ps1',
        (Add-Text $Script "`nWrite-Log -Level WARN -Message 'A brand new warning nobody documented.'"), 1, '[omission]')
    ,@('stale troubleshooting entry', 'Test-Consistency.ps1',
        (Edit-Text 'README.md' '`Proton VPN log reports an invalid port`' '`Proton VPN log reports a bogus port`'), 1, '[stale]')
    ,@('dead inline link', 'Test-Consistency.ps1', (Add-Text 'README.md' "`n[x](./absent.md)"), 1, '[links]')
    ,@('dead reference link', 'Test-Consistency.ps1', (Add-Text 'README.md' "`n[r]: ./absent.md"), 1, '[links]')
    ,@('dead anchor, same file', 'Test-Consistency.ps1', (Add-Text 'README.md' "`n[x](#nowhere)"), 1, '[anchors]')
    ,@('dead anchor, other file', 'Test-Consistency.ps1', (Add-Text 'README.md' "`n[x](AGENTS.md#nowhere)"), 1, '[anchors]')
    ,@('table without rows', 'Test-Consistency.ps1', (Add-Text 'AGENTS.md' "`n| A | B |`n|---|---|`nText"), 1, '[tables]')
)

$failed = 0
foreach ($c in $Cases) {
    $name, $check, $alter, $expectedExit, $expected = $c
    $copy = Join-Path ([IO.Path]::GetTempPath()) "qbit-harness-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    try {
        if ($alter) { Copy-Repository $copy; & $alter $copy; $target = $copy } else { $target = $Root }
        $output = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot $check) -Root $target 2>&1 | Out-String)
        $exit = $LASTEXITCODE
    } finally {
        if (Test-Path $copy) { Remove-Item $copy -Recurse -Force }
    }
    if ($exit -eq $expectedExit -and $output.Contains($expected)) {
        Write-Host "ok    $name" -ForegroundColor Gray
    } else {
        $failed++
        Write-Host "FAIL  $name : expected exit $expectedExit and '$expected', got exit $exit" -ForegroundColor Red
        Write-Host ($output.TrimEnd() -replace '(?m)^', '      ')
    }
}

if ($failed) { Write-Host "RED: $failed of $($Cases.Count) case(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "GREEN: $($Cases.Count) cases." -ForegroundColor Green
exit 0
