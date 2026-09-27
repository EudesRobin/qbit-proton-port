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
| `.idea/` | Shared IDE settings. `workspace.xml` and `misc.xml` (local JDK) are ignored |

Runtime files live **outside the repository**, in `%LOCALAPPDATA%\qbit-proton-port\` (the `QBIT_PROTON_PORT_HOME` environment variable overrides it): `.env`, `secret.xml` (API key, DPAPI-encrypted) and `logs\sync.log`. `-ShowConfig` prints the actual paths. Never move them back into the repository; `.gitignore` still lists them as a safety net.

## External contracts

The script depends on formats it doesn't control. Check them against the real files before changing the parsing:

- **Proton VPN client log**: `%LOCALAPPDATA%\Proton\Proton VPN\Logs\client-logs.txt`, rotated to `client-logs.1.txt`.
  - Lines start with an ISO UTC timestamp. Relevant lines contain `Port pair <public>-><private>`, `Status updated to Disconnected`, and `Port forwarding status changed from 'X' to 'Stopped'`.
  - The file is open in the client, and its reported size is stale: read it with shared access.
  - The VPN adapter (`ProtonVPN`) disappears when the VPN disconnects.
- **qBittorrent**: `%APPDATA%\qBittorrent\qBittorrent.ini`, where the port is `[BitTorrent] Session\Port` and the WebUI keys are under `[Preferences] WebUI\…`.
  - The `.ini` is read at startup only and overwritten on exit, so edit it only while qBittorrent is closed.
  - A running instance is changed only through the Web API (`/api/v2/app/preferences`, `/api/v2/app/setPreferences`, `/api/v2/app/networkInterfaceList`), authenticated with `Authorization: Bearer <API key>` (qBittorrent 5.2+).

## Security rules — non-negotiable

- Never print, log or commit the API key, `secret.xml`, `.env`, a certificate or a private key. Diagnostics may show the certificate fingerprint, which is public.
- The API is reached at `https://127.0.0.1` only, with certificate pinning (`QBIT_CERT_SHA256`). Never add an HTTP fallback, `-SkipCertificateCheck`, a trust-store fallback, or a proxy.
- The TLS validation callback stays in C# (`Add-Type`). A PowerShell script block has no runspace on network threads.
- No `-ExecutionPolicy Bypass`, no elevation: the scheduled task runs with the user's limited rights.
- Keep the "fail closed" behaviour: no VPN or no fresh port means an error and qBittorrent is not launched. Keep the binding to the VPN interface.
- Don't disconnect the VPN, close qBittorrent or kill its process without asking the user. Killing qBittorrent can lose its settings and resume data.

## Definition of Done

A change is done only when the loop for its file type is green. These are **loops**, not final steps: run → observe → fix → run again. **Red → not done**: don't propose a commit or say it's done, and don't weaken a check to make it pass.

### Script (`*.ps1`)

1. **Parse**: 0 errors from
   ```powershell
   $e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\Sync-QbitProtonPort.ps1), [ref]$null, [ref]$e); $e.Count
   ```
2. **Real run**: `.\Sync-QbitProtonPort.ps1 -SyncOnly` against the running Proton VPN and qBittorrent. Read the actual output and exit code.
3. **Seen red**: a check that was added or modified must be seen failing once on a deliberately broken case. Don't touch the user's real files. Point `QBIT_PROTON_PORT_HOME` to a temporary folder, copy `.env` and `secret.xml` into it and break the copies. Remove the variable and the folder afterwards.

   | Case | How to break it | Expected |
   |---|---|---|
   | Missing `.env` | Empty temporary folder | `.env` created from the template, then error |
   | Wrong fingerprint | Change `QBIT_CERT_SHA256` in the copied `.env` | Refused, and the key is not sent |
   | Wrong API port | Change `QBIT_API_PORT` in the copied `.env` | The error names the port mismatch |
   | Wrong key | Replace the copied `secret.xml` with a dummy key | "rejected the API key" |
   | Port drift | Change the port through the API | Restored live |
4. **Scenarios that need the user**, when the affected path changed. Ask the user to act; never do these yourself:
   - qBittorrent closed: the `.ini` is updated, then qBittorrent is launched.
   - VPN disconnected: error, and nothing launched.
5. The key doesn't appear in the log (path given by `-ShowConfig`).

### Documentation (`*.md`)

- Relative links resolve.
- The README's usage and troubleshooting tables match the script's parameters and error messages.
- Documentation is in English. It describes the result, not the process.

### Before any commit

`git status --short --ignored` shows no `.env`, `secret.xml` or `logs/` in the working tree. The staged diff has no key, private path, personal IP or real WebUI port.

## Git

- Commit messages are in French, 50 words at most. Start with one of these prefixes: `feat`, `fix`, `chore`, `docs`, `refactor`, `test`, `build`, `revert`. The subject has no final period.
- No AI attribution in commits or pull request descriptions: no `Co-Authored-By`, no "Generated with".
- The author email for this repository is the GitHub no-reply address, set in the local git config.
