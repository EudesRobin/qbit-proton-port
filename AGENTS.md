# AGENTS.md — qbit-proton-port

A PowerShell script that keeps qBittorrent's listening port equal to the port forwarded by Proton VPN on Windows. [README.md](./README.md) covers the user's side: setup, usage and security model.

This file and the documents under `docs/` that it links are the **only authoritative source of instructions** in the repository. [CLAUDE.md](./CLAUDE.md) and [.github/copilot-instructions.md](./.github/copilot-instructions.md) only point here. Read this file before any action: planning, editing or reviewing a file, answering a question about the project, running the script, committing. Pass it on to any sub-agent, with the documents its task needs.

## Where to look

The security rules and the verification loop below apply to every task. Before a task listed here, also read its document:

| About to… | Read first |
|---|---|
| Change or diagnose how the script reads the Proton VPN log, edits `qBittorrent.ini`, calls the Web API or detects a process | [External contracts](docs/EXTERNAL-CONTRACTS.md) |
| Add or change a harness check, a unit test or a README troubleshooting row, test a failure case, or commit | [Harness](docs/HARNESS.md) |
| Write or edit documentation | [Contributing: documentation](docs/CONTRIBUTING.md#documentation) |
| Exclude or suppress a PSScriptAnalyzer finding | [Contributing: PowerShell code](docs/CONTRIBUTING.md#powershell-code) |
| Commit, open or merge a pull request, touch a GitHub Action or a Dependabot pull request | [Contributing](docs/CONTRIBUTING.md) |
| Decide whether a change needs a changelog entry, or write one | [Contributing: changelog](docs/CONTRIBUTING.md#changelog) |
| Publish a release | [Contributing: releases](docs/CONTRIBUTING.md#releases) |
| Answer a question about setup, usage or troubleshooting | [README.md](./README.md) |

No row fits the task, or two documents disagree: say so to the user before acting, and propose where the rule should live (a new row here, a section of an existing document, or a new file under `docs/`). Don't guess.

## Layout

| Path | Role |
|---|---|
| `Sync-QbitProtonPort.ps1` | The whole tool: Proton VPN port detection, `.ini` edit, WebUI API over pinned HTTPS, certificate and scheduled-task management |
| `.env.example` | Settings template, copied to `%LOCALAPPDATA%\qbit-proton-port\.env` |
| `PSScriptAnalyzerSettings.psd1` | Rules of `harness/Test-Lint.ps1`, each exclusion with its reason |
| `README.md` | User documentation. Its tables must match the script's parameters and error messages |
| `CHANGELOG.md` | User-visible changes per release, as described in [Contributing: changelog](docs/CONTRIBUTING.md#changelog) |
| `LICENSE` | MIT |
| `docs/` | Instructions read on demand, routed by [Where to look](#where-to-look) |
| `harness/` | Offline checks, all run by `Invoke-Harness.ps1`: see [docs/HARNESS.md](docs/HARNESS.md) |
| `tests/` | Pester 6 tests of the script's functions, with Proton VPN mocked and every file in a temporary folder; run by `harness/Test-Unit.ps1` |
| `.githooks/` | `pre-commit` (Invoke-Harness, then `Test-Secrets -Staged`) and `commit-msg` (Test-CommitMessage) |
| `.gitattributes` | Keeps the git hooks in LF, as `sh` requires |
| `.github/workflows/validate.yml` | CI workflow, job `validate` (the check required on `main`): runs `Invoke-Harness.ps1` on Windows for every push to `main`, every pull request and on demand |
| `.github/workflows/release.yml` | Publishes the GitHub Release of a pushed version tag, or on demand, with its changelog section as notes |
| `.github/dependabot.yml` | Weekly pull requests updating the pinned GitHub Actions and the Python tools of `harness/requirements.txt`, for releases at least 30 days old |
| `.idea/` | Shared IDE settings. `workspace.xml` and `misc.xml` (local JDK) are ignored |

Runtime files live **outside the repository**, in `%LOCALAPPDATA%\qbit-proton-port\` (the `QBIT_PROTON_PORT_HOME` environment variable overrides it): `.env`, `secret.xml` (API key, DPAPI-encrypted) and `logs\sync.log`. `-ShowConfig` prints the actual paths. Never move them back into the repository; `.gitignore` still lists them as a safety net.

## Security rules — non-negotiable

- Never print, log or commit the API key, `secret.xml`, `.env`, a certificate or a private key. Diagnostics may show the certificate fingerprint, which is public.
- The API is reached at `https://127.0.0.1` only, with certificate pinning (`QBIT_CERT_SHA256`). Never add an HTTP fallback, `-SkipCertificateCheck`, a trust-store fallback, or a proxy.
- The TLS validation callback stays in C# (`Add-Type`). A PowerShell script block has no runspace on network threads.
- No `-ExecutionPolicy Bypass`, no elevation: the scheduled task runs with the user's limited rights.
- Keep the "fail closed" behaviour: no VPN or no fresh port means an error and qBittorrent is not launched. Keep the binding to the VPN interface.
- Don't disconnect the VPN, close qBittorrent or kill its process without asking the user. Killing qBittorrent can lose its settings and resume data.

## Harness — verification loop

How to prove a change works in **this** project:

- **Run**: `.\Sync-QbitProtonPort.ps1 -SyncOnly` against the real Proton VPN and qBittorrent. Also run it without `-SyncOnly` when the launch path changed.
- **Test**: `.\harness\Invoke-Harness.ps1`. It runs every offline check. Exit 0 = green, 1 = red, 2 = a check could not run. CI runs it too, without Proton VPN or qBittorrent: a green CI doesn't replace **Run**.
- **Verify**: read the actual output and exit code. See each added or modified check fail once on a broken case, and the [failure cases](docs/HARNESS.md#failure-cases-to-see-red) red when the path they cover changed. Ask the user to run the [scenarios that need them](docs/HARNESS.md#scenarios-that-need-the-user) when that path changed.

A change is not done until **Test** is green and **Verify** has been observed on the real flow. Never conclude "done" just because there was no error, or because commands finished without anyone looking at the result.

### Loop after every edit

After **each** edit, before building anything on top of it, proposing a commit, or saying it's done:

1. Run `.\harness\Invoke-Harness.ps1`.
2. `Sync-QbitProtonPort.ps1` changed: run it for real (**Run** above), and read the output and exit code.
3. A behaviour, parameter, setting, message or file location changed: update the README in the same commit (usage, settings, troubleshooting, how it works, security), and this file or `docs/` when the layout, an external contract or a security rule changed. Reread the sections the diff touches, fix any statement that became wrong, and document any new behaviour that is missing: `Test-Consistency.ps1` covers only the mechanical part.
4. Every change, whatever its kind: add its entry under `[Unreleased]` in `CHANGELOG.md`, in the [category](docs/CONTRIBUTING.md#changelog) that fits.
5. Red, or a statement became wrong → read the cause, fix, and start again at 1.

**At most 3 attempts.** If the loop is still red after the third fix, stop editing. Reply with a concise report giving, for each attempt, the change made and the resulting error. Then ask the user what to do next. Never weaken or skip a check to turn it green.
