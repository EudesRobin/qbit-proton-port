# AGENTS.md — qbit-proton-port

A PowerShell script that keeps qBittorrent's listening port equal to the port forwarded by Proton VPN on Windows. [README.md](./README.md) covers the user's side: setup, usage and security model.

This file is the **only authoritative source of instructions** in the repository. [CLAUDE.md](./CLAUDE.md) and [.github/copilot-instructions.md](./.github/copilot-instructions.md) only point to it. Read it before any action: planning, editing or reviewing a file, answering a question about the project, running the script, committing. Pass it on to any sub-agent.

## Layout

| Path | Role |
|---|---|
| `Sync-QbitProtonPort.ps1` | The whole tool: Proton VPN port detection, `.ini` edit, WebUI API over pinned HTTPS, certificate and scheduled-task management |
| `.env.example` | Settings template, copied to `%LOCALAPPDATA%\qbit-proton-port\.env` |
| `README.md` | User documentation. Its tables must match the script's parameters and error messages |
| `LICENSE` | MIT |
| `harness/Invoke-Harness.ps1` | Runs every offline check: the **Test** step of the Definition of Done (see Harness) |
| `harness/Test-Consistency.ps1` | Script, `.env.example` and Markdown files agree |
| `harness/Test-Secrets.ps1` | No runtime file, key, fingerprint, user path, IP or local `.env` value in what would be published; `-Staged` for the staged diff |
| `harness/Test-CommitMessage.ps1` | Commit message rules (see Git) |
| `harness/Test-Harness.ps1` | Tests of the checks: each rule seen red on a broken case |
| `.githooks/` | `pre-commit` (Invoke-Harness, then `Test-Secrets -Staged`) and `commit-msg` (Test-CommitMessage) |
| `.gitattributes` | Keeps the git hooks in LF, as `sh` requires |
| `.github/workflows/validate.yml` | CI: runs `Invoke-Harness.ps1` on Windows for every push to `main` and every pull request |
| `.idea/` | Shared IDE settings. `workspace.xml` and `misc.xml` (local JDK) are ignored |

Runtime files live **outside the repository**, in `%LOCALAPPDATA%\qbit-proton-port\` (the `QBIT_PROTON_PORT_HOME` environment variable overrides it): `.env`, `secret.xml` (API key, DPAPI-encrypted) and `logs\sync.log`. `-ShowConfig` prints the actual paths. Never move them back into the repository; `.gitignore` still lists them as a safety net.

## External contracts

The script depends on formats it doesn't control. Check them against the real files before changing the parsing:

- **Proton VPN client log**: `%LOCALAPPDATA%\Proton\Proton VPN\Logs\client-logs.txt`, rotated to `client-logs.1.txt`.
  - Lines start with an ISO UTC timestamp. Relevant lines contain `Port pair <public>-><private>`, `Status updated to Disconnected`, and `Port forwarding status changed from 'X' to 'Stopped'`.
  - The file is open in the client, and its reported size is stale: read it with shared access.
  - The VPN adapter (`ProtonVPN`) disappears when the VPN disconnects.
  - The client process is `ProtonVPN.Client`: without it, the VPN is treated as off.
- **qBittorrent**: `%APPDATA%\qBittorrent\qBittorrent.ini`, where the port is `[BitTorrent] Session\Port` and the WebUI keys are under `[Preferences] WebUI\…`.
  - The process is `qbittorrent`: its presence decides between the `.ini` path and the API path.
  - The `.ini` is read at startup only and overwritten on exit, so edit it only while qBittorrent is closed.
  - A running instance is changed only through the Web API (`/api/v2/app/preferences`, `/api/v2/app/setPreferences`, `/api/v2/app/networkInterfaceList`), authenticated with `Authorization: Bearer <API key>` (qBittorrent 5.2+).

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
- **Test**: `.\harness\Invoke-Harness.ps1`. It runs every offline check (see below). Exit 0 = green, 1 = red, 2 = a check could not run. CI runs it too, without Proton VPN or qBittorrent: a green CI doesn't replace **Run**.
- **Verify**: read the actual output and exit code. See each added or modified check fail once on a broken case (table below). Ask the user to run the "qBittorrent closed" and "VPN off" scenarios when that path changed.

A change is not done until **Test** is green and **Verify** has been observed on the real flow. Run, read the failure, fix, run again. Never conclude "done" just because there was no error, or because commands finished without anyone looking at the result.

### Loop after every code edit

After **each** edit of a `.ps1` file, before building anything on top of it, proposing a commit, or saying it's done:

1. Run `.\harness\Invoke-Harness.ps1`.
2. Run the script for real (**Run** above), and read the output and exit code.
3. Red → read the cause, fix, and start again at 1.

**At most 3 attempts.** If the loop is still red after the third fix, stop editing. Reply with a concise report giving, for each attempt, the change made and the resulting error. Then ask the user what to do next. Never weaken or skip a check to turn it green.

### What the checks cover

`harness/Test-Consistency.ps1`:

1. The script parses without errors.
2. Every script parameter appears in the README.
3. Every setting in `.env.example`, and every environment variable the script reads (except Windows ones), appears in the README.
4. **No omission**: every error (`throw`), warning (`Write-Log WARN`, positional or named arguments) and WebUI diagnostic has a row in the README troubleshooting tables.
5. **No stale entry**: every message fragment quoted in those tables still exists in the script.
6. Every relative link in the Markdown files resolves, inline or reference-style.
7. Every anchor (`#heading`) of a link to a Markdown file matches a heading of that file.
8. Every setting the script reads with `Get-Setting` is in `.env.example`.
9. Every Markdown table has at least one data row.

A troubleshooting row quotes the fixed part of a message in backticks, with `...` for a variable part. A message whose fixed part is too short (under 10 characters) can't be matched: reword it so it starts with a meaningful fixed phrase.

`harness/Test-Harness.ps1` runs each check against a temporary copy of the repository broken on purpose, and expects it red with a given message; it also expects the real repository green. A rule added to a check isn't done until its broken case is in `Test-Harness.ps1` and was seen failing against the check without the rule.

### Documentation stays true

Any change to behaviour, a parameter, a setting, a message or a file location updates the README **in the same commit**: usage, settings, troubleshooting, how it works, security. `Test-Consistency.ps1` covers only the mechanical part. Reread the README sections the diff touches, fix any statement that became wrong, and document any new behaviour that is missing. The same applies to `AGENTS.md` (layout, external contracts, security rules).

Documentation is in English. It describes the result, not the process.

### Failure cases to see red

Don't touch the user's real files. Point `QBIT_PROTON_PORT_HOME` to a temporary folder, copy `.env` and `secret.xml` into it, and break the copies. Remove the variable and the folder afterwards.

| Case | How to break it | Expected |
|---|---|---|
| Missing `.env` | Empty temporary folder | `.env` created from the template, then error |
| Missing key | `.env` copied, no `secret.xml`, `-SyncOnly` | "API key not stored yet" |
| Wrong fingerprint | Change `QBIT_CERT_SHA256` in the copied `.env` | Refused, and the key is not sent |
| Wrong API port | Change `QBIT_API_PORT` in the copied `.env` | The error names the port mismatch |
| Wrong key | Replace the copied `secret.xml` with a dummy key | "rejected the API key" |
| Port drift | Change the port through the API | Restored live |

**Scenarios that need the user**, when the affected path changed. Ask the user to act; never do these yourself:
- qBittorrent closed: the `.ini` is updated, then qBittorrent is launched.
- VPN disconnected: error, and nothing launched.

The API key must not appear in the log (path given by `-ShowConfig`).

### Before any commit

The `pre-commit` hook refuses the commit unless both are green:

- `.\harness\Invoke-Harness.ps1`;
- `.\harness\Test-Secrets.ps1 -Staged`: no `.env`, `secret.xml`, `logs/`, `qBittorrent.ini` or certificate file staged, and no private key, fingerprint, user folder path, IP address other than loopback, or value of your local `.env` in the added lines.

`Test-Secrets.ps1` can't recognise the API key itself, which it never decrypts: still read the staged diff before committing.

## Git

- Commit messages are in French, 50 words at most. Start with one of these prefixes: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `build`, `revert`. The subject has no final period.
- No AI attribution in commits or pull request descriptions: no `Co-Authored-By`, no "Generated with".
- The author email for this repository is the GitHub no-reply address, set in the local git config.
- `main` is protected: every change goes through a branch and a pull request, merged once the `validate` check is green.
- GitHub Actions are pinned to a commit SHA, with the version in a comment (`uses: owner/action@<sha>  # vX.Y.Z`): a tag can be moved to other code.
- The `commit-msg` hook checks the prefix, the final period, the length and the AI attribution; the language isn't checked.
- The git hooks apply only once enabled in the clone. Before the first commit, check that `git config core.hooksPath` returns `.githooks`, and otherwise enable them:

  ```powershell
  git config core.hooksPath .githooks
  ```
