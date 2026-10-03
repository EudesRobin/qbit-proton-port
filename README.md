# qbit-proton-port

[![validate](https://github.com/EudesRobin/qbit-proton-port/actions/workflows/validate.yml/badge.svg?branch=main)](https://github.com/EudesRobin/qbit-proton-port/actions/workflows/validate.yml)
[![Dependabot Updates](https://github.com/EudesRobin/qbit-proton-port/actions/workflows/dependabot/dependabot-updates/badge.svg)](https://github.com/EudesRobin/qbit-proton-port/actions/workflows/dependabot/dependabot-updates)

Keeps qBittorrent's listening port equal to the port forwarded by Proton VPN on Windows.

Proton VPN gives you a random forwarded port for P2P, and it changes each time you connect. Unless qBittorrent listens on that exact port, other peers can't reach you. This script reads the current port from Proton VPN and sets it in qBittorrent:

- if qBittorrent is **closed**, it writes the port to qBittorrent's settings and starts it minimized;
- if qBittorrent is **open**, it changes the port live, with no restart;
- if Proton VPN is **off or exposes no port**, it stops with an error and starts nothing.

It also binds qBittorrent to the VPN network interface, so torrent traffic stops instead of leaking if the VPN drops.

## Requirements

- Windows 11
- [PowerShell 7.3+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`). Windows PowerShell 5.1 is not enough.
- Proton VPN for Windows, on a plan that includes port forwarding
- qBittorrent 5.2 or later (for API keys)

Nothing else needs to be installed: the script only uses tools that ship with Windows (`icacls`, `conhost.exe`, and the `NetAdapter`, `ScheduledTasks` and `PKI` modules). Git is optional: you can download a ZIP instead.

Tested on Windows 11 Pro 25H2 (build 26200) with PowerShell 7.6.6, Proton VPN 5.1.8 and qBittorrent 5.2.3.

## Setup (about 5 minutes, once)

### 1. Get the script

Clone or download this repository into a **local folder that is not synced to the cloud**, for example `C:\Tools\qbit-proton-port`. The scheduled task runs the script every few minutes, so nobody else should be able to change it.

If you downloaded a ZIP, read the script, then unblock it so PowerShell will run it:

```powershell
Get-ChildItem C:\Tools\qbit-proton-port | Unblock-File
```

### 2. Proton VPN: turn on port forwarding

1. In Proton VPN's settings, turn **Port forwarding** on.
2. Connect to a server that supports P2P (marked with the P2P icon).

The app then shows the forwarded port. You don't need to note it: the script reads it.

### 3. qBittorrent: enable the local Web API

The script changes the port through qBittorrent's Web API, the only way to change a setting while qBittorrent is running. The API stays private to your PC. In **Tools › Options › Web UI**:

| Setting | Value |
|---|---|
| Web User Interface (Remote control) | checked |
| IP address | `127.0.0.1`, so it can't be reached from your network |
| Port | a port of your choice, **not** the default 8080 (e.g. `27183`) |
| Password | a strong password (the script doesn't use it, it uses the API key) |
| Bypass authentication for clients on localhost | **unchecked** |
| API key | click to generate one, and keep it for step 6 |

Click **Apply**.

### 4. Create your settings file

Your settings, API key and logs are kept outside the script folder, in `%LOCALAPPDATA%\qbit-proton-port\`. That folder is private to your account and not synced, so updating or re-cloning the script never touches them.

```powershell
cd C:\Tools\qbit-proton-port
$data = "$env:LOCALAPPDATA\qbit-proton-port"
New-Item -ItemType Directory $data -Force | Out-Null
Copy-Item .env.example "$data\.env"
notepad "$data\.env"
```

Set `QBIT_API_PORT` to the port chosen in step 3. The other defaults usually fit:

| Setting | Meaning | Default |
|---|---|---|
| `QBIT_API_PORT` | qBittorrent WebUI port (step 3) | *(empty, required)* |
| `QBIT_CERT_SHA256` | Fingerprint of the WebUI certificate, filled in by step 5 | *(empty, required)* |
| `QBIT_PATH` | Path to `qbittorrent.exe` | `C:\Program Files\qBittorrent\qbittorrent.exe` |
| `VPN_INTERFACE` | Name of the Proton VPN network adapter (`Get-NetAdapter` while connected) | `ProtonVPN` |

If you skip this step, the first run creates the file from the template and asks you to fill it in.

To store these files elsewhere, set the environment variable `QBIT_PROTON_PORT_HOME` to another folder.

### 5. Switch the API to HTTPS

```powershell
.\Sync-QbitProtonPort.ps1 -NewCertificate
```

This creates a certificate valid for 2 years in `%APPDATA%\qBittorrent\ssl\`, readable only by your account, and writes its fingerprint to `.env`. Then, in **Tools › Options › Web UI**:

1. Check **Use HTTPS instead of HTTP**.
2. Paste the **Certificate** and **Key** paths printed by the command.
3. Click **Apply**.

### 6. First run

```powershell
.\Sync-QbitProtonPort.ps1
```

When asked, paste the API key from step 3. It is stored encrypted, and only your Windows account on this PC can read it. You should see something like:

```
INFO  Proton VPN forwarded port: 51413.
INFO  qBittorrent updated: port 51413 on 'ProtonVPN'.
```

### 7. Optional: make it automatic

- **Desktop shortcut** that syncs the port, then starts qBittorrent. Right-click the desktop, choose **New › Shortcut**, and enter this location, replacing `<repo>` with the folder from step 1:
  ```
  pwsh.exe -NoProfile -File "<repo>\Sync-QbitProtonPort.ps1" -PauseOnError
  ```
  The window closes by itself unless something went wrong; then it stays open until you press Enter. To give the shortcut qBittorrent's icon, open its **Properties › Change Icon** and browse to `qbittorrent.exe`.
- **Background re-sync** every 5 minutes while you are logged on, for when Proton VPN reconnects and changes the port:
  ```powershell
  .\Sync-QbitProtonPort.ps1 -RegisterTask     # remove with -UnregisterTask
  ```

## Usage

| Command | What it does |
|---|---|
| `.\Sync-QbitProtonPort.ps1` | Sync the port, start qBittorrent if it's closed |
| `.\Sync-QbitProtonPort.ps1 -SyncOnly` | Sync only if qBittorrent is already open; if it's closed, do nothing (used by the task) |
| `.\Sync-QbitProtonPort.ps1 -PauseOnError` | Same as the first line, but wait for Enter after an error so the window stays open (for shortcuts) |
| `.\Sync-QbitProtonPort.ps1 -RegisterTask` / `-UnregisterTask` | Add or remove the 5-minute background task |
| `.\Sync-QbitProtonPort.ps1 -ShowConfig` | Show where the settings, API key, log and certificate are stored, and whether the task is registered |
| `.\Sync-QbitProtonPort.ps1 -ResetCredential` | Store a new API key (after regenerating it in qBittorrent) |
| `.\Sync-QbitProtonPort.ps1 -NewCertificate` | Renew the certificate (you get a warning 30 days before it expires), then redo step 5 in qBittorrent |

Each run is logged to `%LOCALAPPDATA%\qbit-proton-port\logs\sync.log`. Past 1 MB, the log is renamed `sync.log.1` and a new one starts. Exit code 0 means success (synced, nothing to do, or command done); 1 means an error, and qBittorrent is not started.

## Troubleshooting

Messages are quoted by their fixed part; `...` stands for a variable part such as a path or a number.

Errors (exit code 1, qBittorrent is not started):

| Message | Fix |
|---|---|
| `Proton VPN is not running` / `Proton VPN is not connected` | Start Proton VPN and connect to a P2P server |
| `Proton VPN exposes no forwarded port` | Turn on port forwarding (step 2), or wait a few seconds after connecting |
| `Proton VPN log reports an invalid port` | Reconnect Proton VPN. If it persists, the log format may have changed |
| `Created ... from the template` | The `.env` file was missing and has been created: edit it as in step 4, then continue with step 5 |
| `Setting ... is missing or empty` | Fill in that setting in `.env` (step 4 or 5) |
| `QBIT_API_PORT must be a port number` | Set it in `.env` to the WebUI port of step 3, digits only |
| `QBIT_CERT_SHA256 must be a SHA-256 fingerprint` | Run `-NewCertificate` again (step 5) rather than editing the value by hand |
| `WebUI API unreachable` + `WebUI is disabled` | Enable the Web UI in qBittorrent (step 3) |
| `WebUI API unreachable` + `WebUI port is ... but QBIT_API_PORT is ...` | Make `QBIT_API_PORT` in `.env` equal the WebUI port (step 3) |
| `WebUI API unreachable` + `nothing listens on 127.0.0.1` | qBittorrent is still starting, or its WebUI IP address is not `127.0.0.1` (step 3) |
| `WebUI API timed out` | qBittorrent is busy or frozen: retry, or restart it |
| `TLS handshake failed: HTTPS is probably not enabled` | Do the qBittorrent part of step 5 |
| `certificate (...) doesn't match QBIT_CERT_SHA256` | The certificate was changed: run `-NewCertificate` and redo step 5 |
| `qBittorrent rejected the API key` | Run `-ResetCredential` with the current key |
| `API key not stored yet` (scheduled task) | Run the script once by hand to store the key |
| `Cannot decrypt ...secret.xml` | The file comes from another account or PC: run `-ResetCredential` |
| `Empty API key, nothing saved` | Paste the key when asked; an empty entry is rejected |
| `qBittorrent API ... returned HTTP` | Unexpected API error: check that qBittorrent is 5.2 or later |
| `doesn't see a network interface named` | Fix `VPN_INTERFACE` in `.env` (adapter name while connected) |
| `qBittorrent did not apply the settings` | qBittorrent refused the change: check its log, or set the port by hand |
| `qBittorrent not found` | Fix `QBIT_PATH` in `.env` |
| `qBittorrent settings not found` | Start qBittorrent once by hand so it creates its settings file |
| `Cannot restrict permissions` | `-NewCertificate` couldn't secure the key folder; nothing was written. Check your rights on `%APPDATA%\qBittorrent` |

Warnings (the run continues):

| Message | Meaning |
|---|---|
| `WebUI certificate expires in ... days` | Run `-NewCertificate` and redo step 5 in qBittorrent |
| `not bound to the VPN interface yet` | First launch only: qBittorrent may use all interfaces for a few seconds, until the script binds it to the VPN. The binding is then saved |
| `Proton reports different ports` | Proton gave different public and private ports, which is unexpected; the public one is used |

## How it works

- **Port source.** Proton VPN logs the forwarded port about every 10 seconds in `%LOCALAPPDATA%\Proton\Proton VPN\Logs\client-logs.txt`. The script accepts a port only if it was reported within the last 90 seconds and the VPN hasn't disconnected since. A future Proton VPN update that changes this log format would break detection; the script then fails safely with an error.
- **qBittorrent closed.** The script edits `Session\Port` in `%APPDATA%\qBittorrent\qBittorrent.ini`, keeping a one-time backup in `qBittorrent.ini.bak`, then starts qBittorrent minimized. It waits up to 30 seconds for the API, then continues as below.
- **qBittorrent open.** It reads the settings through `/api/v2/app/preferences`. If needed, it changes the listening port and binds qBittorrent to the `VPN_INTERFACE` adapter, found through `/api/v2/app/networkInterfaceList`, with `/api/v2/app/setPreferences`. It then reads the settings again to confirm they were applied.

## Security

- **API key.**
  - It is sent in the `Authorization: Bearer` header, to `127.0.0.1` only.
  - The local copy in `secret.xml` is encrypted with Windows DPAPI, so it is useless on another account or PC.
  - It is never logged and never committed.
- **HTTPS with pinning.**
  - The script trusts only the exact certificate whose SHA-256 is in `.env`, not the Windows certificate store.
  - If another program answers on the port with a different certificate, the connection is refused before the key is sent.
- **Private key.** It sits in `%APPDATA%\qBittorrent\ssl\`, readable only by your account and SYSTEM.
- **Execution policy.** The scheduled task runs under your normal account, without admin rights, and doesn't bypass the PowerShell execution policy.
- **Known limit.** qBittorrent itself stores the API key in plain text in `qBittorrent.ini`. Any program running under your account can read it; this is outside the script's control.
- **Local files.** `.env`, `secret.xml` and the logs are stored in `%LOCALAPPDATA%\qbit-proton-port\`, outside the repository and outside any synced folder. `.env` holds no secret, only the port and the certificate fingerprint. The repository also git-ignores these names and certificate files as a safety net.

## Contributing

Before committing a change, run `.\harness\Invoke-Harness.ps1`. It checks that the script parses and that this README still matches it: parameters, settings, error messages, links and tables. It also checks that no secret, runtime file or private value would be published, and tests these checks against deliberately broken copies of the repository.

To run these checks on every commit, and to check commit messages, [enable the repository's git hooks](docs/CONTRIBUTING.md#setup) once per clone. See [AGENTS.md](AGENTS.md) for the full Definition of Done, and [docs/CONTRIBUTING.md](docs/CONTRIBUTING.md) for commits, pull requests and releases.

## License

[MIT](LICENSE)
