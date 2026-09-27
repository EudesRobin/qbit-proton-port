#Requires -Version 7.3
<#
.SYNOPSIS
    Tests the harness checks: each rule is seen red on a deliberately broken case,
    and the real repository stays green. Exit 0 = all cases pass, 1 = a case failed.

.DESCRIPTION
    A case runs one check against a target, then expects an exit code and a message fragment:
      real   the repository itself;
      copy   a copy of the repository files (tracked and untracked, minus git-ignored ones), altered;
      empty  an empty folder, filled by the alteration (commit messages).
    Each case gets its own empty data folder through QBIT_PROTON_PORT_HOME, so the local .env never
    changes a result. Every rule added to a check gets its broken case here.

    Literals that look private (addresses, user paths, fingerprints, keys) are built by concatenation,
    so that Test-Secrets.ps1 stays green on this file.
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

# --- Alterations, applied to the target folder ---------------------------------------------
function Add-Text([string] $Rel, [string] $Text) {
    {
        param($d)
        $path = Join-Path $d $Rel
        New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
        Add-Content -Path $path -Value $Text -Encoding utf8
    }.GetNewClosure()
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
# Makes the copy a git repository with everything staged, then applies $Then and stages it too (-f: ignored files).
function Stage([scriptblock] $Then) {
    {
        param($d)
        git -C $d init -q; git -C $d -c core.autocrlf=false add -A
        & $Then $d
        git -C $d -c core.autocrlf=false add -A -f
    }.GetNewClosure()
}
function Message([string] $Text) { Add-Text 'MSG' $Text }

function Case {
    param([string] $Name, [string] $Check, [ValidateSet('real', 'copy', 'empty')] [string] $Target,
          [scriptblock] $Alter, [int] $Exit, [string] $Expect,
          [string[]] $Arguments = @('-Root', '{root}'), [hashtable] $Data = @{})
    [pscustomobject]@{ Name = $Name; Check = $Check; Target = $Target; Alter = $Alter; Exit = $Exit
                       Expect = $Expect; Arguments = $Arguments; Data = $Data }
}

$Script = 'Sync-QbitProtonPort.ps1'
$C = 'Test-Consistency.ps1'
$S = 'Test-Secrets.ps1'
$M = 'Test-CommitMessage.ps1'
$MsgArgs = @('-Path', '{root}/MSG')
$Ip = '192.168.' + '1.20'
$UserPath = 'C:\Us' + 'ers\alice\Downloads'
$PemKey = '-----BEGIN RSA ' + 'PRIVATE KEY-----'

$Cases = @(
    # --- Test-Consistency.ps1
    Case 'consistency: real repository' $C real $null 0 'GREEN'
    Case 'consistency: valid anchors' $C copy (Add-Text 'README.md' "`n[a](#troubleshooting) [b](AGENTS.md#harness--verification-loop)`n[c]: AGENTS.md#layout") 0 'GREEN'
    Case 'consistency: parse error' $C copy (Add-Text $Script "`nfunction Broken {") 1 '[parse]'
    Case 'consistency: undocumented parameter' $C copy (Edit-Text $Script '[switch] $ShowConfig' "[switch] `$ShowConfig,`n    [switch] `$UndocumentedSwitch") 1 '[params] parameter -UndocumentedSwitch'
    Case 'consistency: undocumented setting' $C copy (Add-Text '.env.example' 'UNDOCUMENTED_SETTING=1') 1 '[settings] setting UNDOCUMENTED_SETTING'
    Case 'consistency: undocumented environment variable' $C copy (Add-Text $Script "`n`$x = `$env:QBIT_UNDOCUMENTED_VAR") 1 '[settings] environment variable QBIT_UNDOCUMENTED_VAR'
    Case 'consistency: setting missing from template' $C copy (Add-Text $Script "`n`$x = Get-Setting -Settings @{} -Name 'MISSING_FROM_TEMPLATE'") 1 '[template]'
    Case 'consistency: undocumented error' $C copy (Add-Text $Script "`nthrow 'A brand new error nobody documented.'") 1 '[omission]'
    Case 'consistency: undocumented warning, named arguments' $C copy (Add-Text $Script "`nWrite-Log -Level WARN -Message 'A brand new warning nobody documented.'") 1 '[omission]'
    Case 'consistency: stale troubleshooting entry' $C copy (Edit-Text 'README.md' '`Proton VPN log reports an invalid port`' '`Proton VPN log reports a bogus port`') 1 '[stale]'
    Case 'consistency: dead inline link' $C copy (Add-Text 'README.md' "`n[x](./absent.md)") 1 '[links]'
    Case 'consistency: dead reference link' $C copy (Add-Text 'README.md' "`n[r]: ./absent.md") 1 '[links]'
    Case 'consistency: dead anchor, same file' $C copy (Add-Text 'README.md' "`n[x](#nowhere)") 1 '[anchors]'
    Case 'consistency: dead anchor, other file' $C copy (Add-Text 'README.md' "`n[x](AGENTS.md#nowhere)") 1 '[anchors]'
    Case 'consistency: table without rows' $C copy (Add-Text 'AGENTS.md' "`n| A | B |`n|---|---|`nText") 1 '[tables]'

    # --- Test-Secrets.ps1
    Case 'secrets: real repository' $S real $null 0 'GREEN'
    Case 'secrets: settings file' $S copy (Add-Text '.env' 'QBIT_API_PORT=1') 1 '[files] .env'
    Case 'secrets: log file' $S copy (Add-Text 'logs/sync.log' 'INFO') 1 '[files] logs/sync.log'
    Case 'secrets: certificate key file' $S copy (Add-Text 'ssl/webui.key' 'x') 1 '[files] ssl/webui.key'
    Case 'secrets: private key block' $S copy (Add-Text 'README.md' $PemKey) 1 '[private-key] README.md'
    Case 'secrets: fingerprint' $S copy (Add-Text 'README.md' ('AB' * 32)) 1 '[fingerprint] README.md'
    Case 'secrets: fingerprint with colons' $S copy (Add-Text 'README.md' ((@('AB') * 32) -join ':')) 1 '[fingerprint] README.md'
    Case 'secrets: user folder path' $S copy (Add-Text 'README.md' $UserPath) 1 '[paths] README.md'
    Case 'secrets: path placeholder allowed' $S copy (Add-Text 'README.md' 'C:\Users\<you>\x and %LOCALAPPDATA%') 0 'GREEN'
    Case 'secrets: IPv4 address' $S copy (Add-Text 'AGENTS.md' "WebUI on $Ip") 1 '[ip] AGENTS.md'
    Case 'secrets: local API port' $S copy (Add-Text 'README.md' 'Port 45678 here.') 1 '[local] README.md' -Data @{ '.env' = "QBIT_API_PORT=45678`nQBIT_CERT_SHA256=" }
    Case 'secrets: staged settings file' $S copy (Stage (Add-Text '.env' 'QBIT_API_PORT=1')) 1 '[files] .env is staged' @('-Root', '{root}', '-Staged')
    Case 'secrets: staged IPv4 address' $S copy (Stage (Add-Text 'README.md' "`nWebUI on $Ip")) 1 '[ip] README.md' @('-Root', '{root}', '-Staged')
    Case 'secrets: staged clean change' $S copy (Stage (Add-Text 'README.md' "`nA harmless line.")) 0 'GREEN' @('-Root', '{root}', '-Staged')

    # --- Test-CommitMessage.ps1
    Case 'commit: valid message' $M empty (Message "fix: corrige la lecture du port`n`nLe journal tourne plus tôt que prévu.") 0 '' $MsgArgs
    Case 'commit: comments and scissors ignored' $M empty (Message "docs: précise le README`n# Please enter the commit message`n# ------------------------ >8`n$('mot ' * 80)") 0 '' $MsgArgs
    Case 'commit: merge commit not checked' $M empty (Message "Merge pull request #1 from x/y") 0 '' $MsgArgs
    Case 'commit: tool named by a generator allowed' $M empty (Message "docs: PDF généré par pandoc") 0 '' $MsgArgs
    Case 'commit: no prefix' $M empty (Message 'corrige la lecture du port') 1 'must start with' $MsgArgs
    Case 'commit: unknown prefix' $M empty (Message 'feature: ajoute un réglage') 1 'must start with' $MsgArgs
    Case 'commit: final period' $M empty (Message 'fix: corrige la lecture du port.') 1 'period' $MsgArgs
    Case 'commit: too many words' $M empty (Message "fix: x`n`n$('mot ' * 50)") 1 '52 words' $MsgArgs
    Case 'commit: Co-Authored-By an AI' $M empty (Message "fix: x`n`nCo-Authored-By: Claude <noreply@anthropic.com>") 1 'AI attribution' $MsgArgs
    Case 'commit: generated with an AI' $M empty (Message "fix: x`n`nGenerated with Claude Code") 1 'AI attribution' $MsgArgs
)

$failed = 0
$savedHome = $env:QBIT_PROTON_PORT_HOME
foreach ($c in $Cases) {
    $work = Join-Path ([IO.Path]::GetTempPath()) "qbit-harness-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $target = if ($c.Target -eq 'real') { $Root } else { Join-Path $work 'target' }
    $dataDir = Join-Path $work 'data'
    try {
        New-Item -ItemType Directory -Path $dataDir -Force | Out-Null
        foreach ($name in $c.Data.Keys) { Set-Content -Path (Join-Path $dataDir $name) -Value $c.Data[$name] -Encoding utf8 }
        if ($c.Target -ne 'real') { New-Item -ItemType Directory -Path $target | Out-Null }
        if ($c.Target -eq 'copy') { Copy-Repository $target }
        if ($c.Alter) { & $c.Alter $target | Out-Null }
        $arguments = @($c.Arguments | ForEach-Object { $_.Replace('{root}', $target) })
        $env:QBIT_PROTON_PORT_HOME = $dataDir
        $output = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot $c.Check) @arguments 2>&1 | Out-String)
        $exit = $LASTEXITCODE
    } finally {
        $env:QBIT_PROTON_PORT_HOME = $savedHome
        if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    }
    if ($exit -eq $c.Exit -and $output.Contains($c.Expect)) {
        Write-Host "ok    $($c.Name)" -ForegroundColor Gray
    } else {
        $failed++
        Write-Host "FAIL  $($c.Name) : expected exit $($c.Exit) and '$($c.Expect)', got exit $exit" -ForegroundColor Red
        Write-Host ($output.TrimEnd() -replace '(?m)^', '      ')
    }
}

if ($failed) { Write-Host "RED: $failed of $($Cases.Count) case(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "GREEN: $($Cases.Count) cases." -ForegroundColor Green
exit 0
