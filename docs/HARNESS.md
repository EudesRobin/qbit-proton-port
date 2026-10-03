# Harness — checks and failure cases

Routed from [AGENTS.md](../AGENTS.md#where-to-look), which holds the [verification loop](../AGENTS.md#harness--verification-loop) and the Definition of Done.

## Scripts

| Path | Role |
|---|---|
| [`harness/Invoke-Harness.ps1`](../harness/Invoke-Harness.ps1) | Runs every offline check: the **Test** step of the Definition of Done |
| [`harness/Test-Consistency.ps1`](../harness/Test-Consistency.ps1) | Script, `.env.example` and Markdown files agree |
| [`harness/Test-Secrets.ps1`](../harness/Test-Secrets.ps1) | No runtime file, key, fingerprint, user path, IP or local `.env` value in what would be published; `-Staged` for the staged diff |
| [`harness/Test-Workflows.ps1`](../harness/Test-Workflows.ps1) | The GitHub Actions workflows pass the zizmor audit (see [Contributing](CONTRIBUTING.md#github-actions)) |
| [`harness/Test-Unit.ps1`](../harness/Test-Unit.ps1) | Pester tests of the script's functions, in [`tests/`](../tests/Sync-QbitProtonPort.Tests.ps1): Proton VPN log, `qBittorrent.ini`, `.env` |
| [`harness/requirements.txt`](../harness/requirements.txt) | Not a check: the pinned Python tools of the checks, installed by CI |
| [`harness/Test-CommitMessage.ps1`](../harness/Test-CommitMessage.ps1) | Commit message rules (see [Contributing](CONTRIBUTING.md#commits)): one message for the hook, or the commits of a range with `Invoke-Harness.ps1 -CommitRange` |
| [`harness/Test-Harness.ps1`](../harness/Test-Harness.ps1) | Tests of the checks: each rule seen red on a broken case |
| [`harness/GitHubActions.ps1`](../harness/GitHubActions.ps1) | Not a check: annotations, log groups and job summary on GitHub Actions, dot-sourced by the checks |

## What the checks cover

Each check lists its rules in its own header, which is the reference: update the header with the rule. A new check is added to `Invoke-Harness.ps1`, never to its callers (pre-commit hook, CI).

A troubleshooting row of the README quotes the fixed part of a message in backticks, with `...` for a variable part. A message whose fixed part is too short (under 10 characters) can't be matched: reword it so it starts with a meaningful fixed phrase.

`Test-Harness.ps1` runs each check against a temporary copy of the repository broken on purpose, and expects it red with a given message; it also expects the real repository green. A rule added to a check isn't done until its broken case is in `Test-Harness.ps1` and was seen failing against the check without the rule. A change to a function covered by [`tests/`](../tests/Sync-QbitProtonPort.Tests.ps1) updates its tests in the same commit, and a new behaviour of such a function gets a test seen failing first. Each test points every path into Pester's `TestDrive` and mocks `Write-Log`: a test never touches the user's real files.

A case whose check needs a missing tool (such as zizmor) is skipped and counted as such; the check itself then exits 2 in `Invoke-Harness.ps1`.

## In CI

The [`CI` workflow](../.github/workflows/validate.yml) runs `Invoke-Harness.ps1`. There, each check is a collapsible group of the log, with its exit code and duration; the job summary on the page of the run has a table of the results; and each problem found by `Test-Consistency.ps1`, `Test-Secrets.ps1` or `Test-Workflows.ps1` is an error annotation on its file, and on its line when known, shown in the pull request. CI also passes `-CommitRange`: the commits of the pull request, or those pushed to `main`, each badly written message being an annotation naming the commit. Outside GitHub Actions the output is unchanged, apart from the durations.

An annotation is public on a public repository: like the console messages, it never contains a matched value.

## Failure cases to see red

Don't touch the user's real files. Point `QBIT_PROTON_PORT_HOME` to a temporary folder, copy `.env` and `secret.xml` into it, and break the copies. Remove the variable and the folder afterwards.

| Case | How to break it | Expected |
|---|---|---|
| Missing `.env` | Empty temporary folder | `.env` created from the template, then error |
| Missing key | `.env` copied, no `secret.xml`, `-SyncOnly` | "API key not stored yet" |
| Wrong fingerprint | Change `QBIT_CERT_SHA256` in the copied `.env` | Refused, and the key is not sent |
| Wrong API port | Change `QBIT_API_PORT` in the copied `.env` | The error names the port mismatch |
| Wrong key | Replace the copied `secret.xml` with a dummy key | "rejected the API key" |
| Port drift | Change the port through the API | Restored live |

The API key must not appear in the log (path given by `-ShowConfig`).

## Scenarios that need the user

When the affected path changed, ask the user to act; never do these yourself:

- qBittorrent closed: the `.ini` is updated, then qBittorrent is launched.
- VPN disconnected: error, and nothing launched.

## Before any commit

The [pre-commit hook](../.githooks/pre-commit) refuses the commit while `Invoke-Harness.ps1` or `Test-Secrets.ps1 -Staged` is red. `Test-Secrets.ps1` can't recognise the API key itself, which it never decrypts: still read the staged diff before committing.
