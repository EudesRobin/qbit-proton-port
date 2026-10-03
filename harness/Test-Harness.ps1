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
    changes a result. GITHUB_ACTIONS and GITHUB_STEP_SUMMARY are cleared for each case, unless the case
    sets them: a broken copy must not annotate the pull request. Every rule added to a check gets its
    broken case here.

    Literals that look private (addresses, user paths, fingerprints, keys) are built by concatenation,
    so that Test-Secrets.ps1 stays green on this file.
#>
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$Root = Split-Path $PSScriptRoot -Parent
# The checks write UTF-8 (GitHubActions.ps1): read their output as such.
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }

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
function Remove-File([string] $Rel) { { param($d) Remove-Item (Join-Path $d $Rel) }.GetNewClosure() }
# Several alterations, in order.
function Steps([scriptblock[]] $Alterations) { { param($d) foreach ($a in $Alterations) { & $a $d } }.GetNewClosure() }
# Makes the folder a git repository: a commit tagged base, then one commit per message, then a merge
# commit with a message breaking every rule when -Merge is set.
function Commits([string[]] $Messages, [switch] $Merge) {
    {
        param($d)
        $git = @('-C', $d, '-c', 'user.name=Test', '-c', 'user.email=test@example.com', '-c', 'commit.gpgsign=false')
        git -C $d init -q -b main
        git @git commit -q --allow-empty -m 'chore: base'
        git -C $d tag base
        foreach ($m in $Messages) { git @git commit -q --allow-empty -m $m }
        if ($Merge) {
            git -C $d switch -q -c side base
            git @git commit -q --allow-empty -m 'test: side'
            git -C $d switch -q main
            git @git merge -q --no-ff side -m 'bad merge message.'
        }
    }.GetNewClosure()
}

function Case {
    param([string] $Name, [string] $Check, [ValidateSet('real', 'copy', 'empty')] [string] $Target,
          [scriptblock] $Alter, [int] $Exit, [string] $Expect,
          [string[]] $Arguments = @('-Root', '{root}'), [hashtable] $Data = @{},
          [hashtable] $Env = @{}, [string] $Absent)
    # Absent: a text the output must not contain.
    [pscustomobject]@{ Name = $Name; Check = $Check; Target = $Target; Alter = $Alter; Exit = $Exit
                       Expect = $Expect; Arguments = $Arguments; Data = $Data; Env = $Env; Absent = $Absent }
}

$Script = 'Sync-QbitProtonPort.ps1'
$C = 'Test-Consistency.ps1'
$S = 'Test-Secrets.ps1'
$M = 'Test-CommitMessage.ps1'
$MsgArgs = @('-Path', '{root}/MSG')
$RangeArgs = @('-Range', 'base..HEAD', '-Root', '{root}')
$Ip = '192.168.' + '1.20'
$UserPath = 'C:\Us' + 'ers\alice\Downloads'
$PemKey = '-----BEGIN RSA ' + 'PRIVATE KEY-----'
$Fence = '```'

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
    Case 'consistency: dead link from a subfolder' $C copy (Add-Text 'docs/HARNESS.md' "`n[x](./AGENTS.md)") 1 '[links] docs/HARNESS.md'
    Case 'consistency: dead anchor, same file' $C copy (Add-Text 'README.md' "`n[x](#nowhere)") 1 '[anchors]'
    Case 'consistency: dead anchor, other file' $C copy (Add-Text 'README.md' "`n[x](AGENTS.md#nowhere)") 1 '[anchors]'
    Case 'consistency: table without rows' $C copy (Add-Text 'AGENTS.md' "`n| A | B |`n|---|---|`nText") 1 '[tables]'
    Case 'consistency: text after a closing fence' $C copy (Add-Text 'README.md' "`n$($Fence)text`nx`n$Fence See the rest.") 1 '[fences]'
    Case 'consistency: annotation in CI' $C copy (Add-Text 'docs/HARNESS.md' "`n[x](./absent.md)") 1 '::error file=docs/HARNESS.md,line=' -Env @{ GITHUB_ACTIONS = 'true' }
    Case 'consistency: no annotation outside CI' $C copy (Add-Text 'docs/HARNESS.md' "`n[x](./absent.md)") 1 '[links]' -Absent '::error'
    Case 'consistency: changelog missing' $C copy (Remove-File 'CHANGELOG.md') 1 '[changelog] CHANGELOG.md is missing'
    Case 'consistency: changelog without Unreleased first' $C copy (Edit-Text 'CHANGELOG.md' '## [Unreleased]' '## [Next]') 1 'the first section must be ## [Unreleased]'
    Case 'consistency: changelog heading without date' $C copy (Edit-Text 'CHANGELOG.md' '## [1.0.0] - 2026-09-27' '## [1.0.0]') 1 "'## [1.0.0]' is not"
    Case 'consistency: changelog unknown subsection' $C copy (Edit-Text 'CHANGELOG.md' '### 🚀 Added' '### Added') 1 "'### Added' is not one of"
    Case 'consistency: changelog link reference missing' $C copy (Edit-Text 'CHANGELOG.md' '[1.0.0]: https' '[1.0]: https') 1 'no link reference for [1.0.0]'
    Case 'consistency: changelog versions not decreasing' $C copy (Steps (Edit-Text 'CHANGELOG.md' '## [1.0.0]' "## [0.9.0] - 2026-09-27`n`n### 🐛 Fixed`n`n- x`n`n## [1.0.0]"), (Add-Text 'CHANGELOG.md' '[0.9.0]: https://example.com')) 1 'decreasing order (1.0.0 after 0.9.0)'
    Case 'consistency: changelog dates increasing' $C copy (Steps (Edit-Text 'CHANGELOG.md' '## [1.0.0]' "## [1.0.1] - 2026-09-01`n`n### 🐛 Fixed`n`n- x`n`n## [1.0.0]"), (Add-Text 'CHANGELOG.md' '[1.0.1]: https://example.com')) 1 'dates must not increase'
    Case 'consistency: changelog major without Upgrade' $C copy (Steps (Edit-Text 'CHANGELOG.md' '## [1.0.0]' "## [2.0.0] - 2026-10-01`n`n### 🔥 Removed`n`n- x`n`n## [1.0.0]"), (Add-Text 'CHANGELOG.md' '[2.0.0]: https://example.com')) 1 '2.0.0 raises MAJOR and has no ### 💥 Upgrade'
    Case 'consistency: changelog major with Upgrade' $C copy (Steps (Edit-Text 'CHANGELOG.md' '## [1.0.0]' "## [2.0.0] - 2026-10-01`n`n### 💥 Upgrade`n`n- x`n`n### 🔥 Removed`n`n- x`n`n## [1.0.0]"), (Add-Text 'CHANGELOG.md' '[2.0.0]: https://example.com')) 0 'GREEN'
    Case 'consistency: changelog subsections out of order' $C copy (Edit-Text 'CHANGELOG.md' '### 🚀 Added' "### 🐛 Fixed`n`n- x`n`n### 🚀 Added") 1 "'### 🚀 Added' must come before '### 🐛 Fixed'"
    Case 'consistency: changelog subsection twice' $C copy (Edit-Text 'CHANGELOG.md' '### 🚀 Added' "### 🚀 Added`n`n- x`n`n### 🚀 Added") 1 "'### 🚀 Added' must come before '### 🚀 Added'"

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
    Case 'secrets: annotation without the value' $S copy (Add-Text 'AGENTS.md' "WebUI on $Ip") 1 '::error file=AGENTS.md,line=' -Env @{ GITHUB_ACTIONS = 'true' } -Absent $Ip
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
    Case 'commit: path by position, as the hook passes it' $M empty (Message 'corrige la lecture du port') 1 'must start with' @('{root}/MSG')
    Case 'commit range: valid commits' $M empty (Commits 'feat: ajoute un réglage', 'fix: corrige la lecture') 0 'GREEN: 2 commit(s)' $RangeArgs
    Case 'commit range: bad message' $M empty (Commits 'feat: ajoute un réglage', 'corrige la lecture') 1 'must start with' $RangeArgs
    Case 'commit range: merge commit not checked' $M empty (Commits 'feat: ajoute un réglage' -Merge) 0 'GREEN: 2 commit(s)' $RangeArgs
    Case 'commit range: unknown range' $M empty (Commits 'feat: ajoute un réglage') 2 'Cannot read the commits' @('-Range', 'nowhere..HEAD', '-Root', '{root}')
    Case 'commit range: annotation in CI' $M empty (Commits 'corrige la lecture') 1 '::error title=commit ' $RangeArgs -Env @{ GITHUB_ACTIONS = 'true' }
)

$failed = 0
$CiVariables = 'GITHUB_ACTIONS', 'GITHUB_STEP_SUMMARY'
$saved = @{}
foreach ($name in @('QBIT_PROTON_PORT_HOME') + $CiVariables) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
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
        foreach ($name in $CiVariables) { [Environment]::SetEnvironmentVariable($name, $c.Env[$name]) }
        $output = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot $c.Check) @arguments 2>&1 | Out-String)
        $exit = $LASTEXITCODE
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        if (Test-Path $work) { Remove-Item $work -Recurse -Force }
    }
    if ($exit -eq $c.Exit -and $output.Contains($c.Expect) -and -not ($c.Absent -and $output.Contains($c.Absent))) {
        Write-Host "ok    $($c.Name)" -ForegroundColor Gray
    } else {
        $failed++
        $without = if ($c.Absent) { ", without '$($c.Absent)'" } else { '' }
        Write-Host "FAIL  $($c.Name) : expected exit $($c.Exit) and '$($c.Expect)'$without, got exit $exit" -ForegroundColor Red
        Write-Host ($output.TrimEnd() -replace '(?m)^', '      ')
    }
}

if ($failed) { Write-Host "RED: $failed of $($Cases.Count) case(s) failed." -ForegroundColor Red; exit 1 }
Write-Host "GREEN: $($Cases.Count) cases." -ForegroundColor Green
exit 0
