# qbit-proton-port

Keeps qBittorrent's listening port equal to the port forwarded by Proton VPN on Windows.

Proton VPN gives you a random forwarded port for P2P, and it changes each time you connect. Unless qBittorrent listens on that exact port, other peers can't reach you. This script reads the current port from Proton VPN and sets it in qBittorrent:

- if qBittorrent is **closed**, it writes the port to qBittorrent's settings and starts it minimized;
- if qBittorrent is **open**, it changes the port live, with no restart;
- if Proton VPN is **off or exposes no port**, it stops with an error and starts nothing.

It also binds qBittorrent to the VPN network interface, so torrent traffic stops instead of leaking if the VPN drops.

## Requirements

- Windows 10 or 11
- [PowerShell 7.3+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows) (`pwsh`). Windows PowerShell 5.1 is not enough.
- Proton VPN for Windows, on a plan that includes port forwarding
- qBittorrent 5.2 or later (for API keys)

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
| Password | change it from the default |
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

Set `QBIT_API_PORT` to the port chosen in step 3. The other defaults usually fit.

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

- **Desktop shortcut** that starts qBittorrent through the script. Its target:
  ```
  pwsh.exe -NoProfile -File "C:\Tools\qbit-proton-port\Sync-QbitProtonPort.ps1" -PauseOnError
  ```
  The window closes by itself unless something went wrong.
- **Background re-sync** every 5 minutes while you are logged on, for when Proton VPN reconnects and changes the port:
  ```powershell
  .\Sync-QbitProtonPort.ps1 -RegisterTask     # remove with -UnregisterTask
  ```

## Usage

| Command | What it does |
|---|---|
| `.\Sync-QbitProtonPort.ps1` | Sync the port, start qBittorrent if it's closed |
| `.\Sync-QbitProtonPort.ps1 -SyncOnly` | Sync only if qBittorrent is already open (used by the task) |
| `.\Sync-QbitProtonPort.ps1 -RegisterTask` / `-UnregisterTask` | Add or remove the 5-minute background task |
| `.\Sync-QbitProtonPort.ps1 -ShowConfig` | Show where the settings, API key, log and certificate are stored |
| `.\Sync-QbitProtonPort.ps1 -ResetCredential` | Store a new API key (after regenerating it in qBittorrent) |
| `.\Sync-QbitProtonPort.ps1 -NewCertificate` | Renew the certificate (you get a warning 30 days before it expires), then redo step 5 in qBittorrent |

Each run is logged to `%LOCALAPPDATA%\qbit-proton-port\logs\sync.log`. Exit code 0 means synced; 1 means an error.

## Troubleshooting

| Message | Fix |
|---|---|
| `Proton VPN is not running` / `not connected` | Start Proton VPN and connect to a P2P server |
| `Proton VPN exposes no forwarded port` | Turn on port forwarding (step 2), or wait a few seconds after connecting |
| `Created ...\.env from the template` | Edit that file as in step 4, then continue with step 5 |
| `WebUI is disabled` / `WebUI port is X but QBIT_API_PORT is Y` | Check step 3 and `.env` |
| `TLS handshake failed: HTTPS is probably not enabled` | Do the qBittorrent part of step 5 |
| `certificate (...) doesn't match QBIT_CERT_SHA256` | The certificate was changed: run `-NewCertificate` and redo step 5 |
| `qBittorrent rejected the API key` | Run `-ResetCredential` with the current key |
| `Missing secret.xml` (scheduled task) | Run the script once by hand to store the key |

## How it works

- **Port source.** Proton VPN logs the forwarded port about every 10 seconds in `%LOCALAPPDATA%\Proton\Proton VPN\Logs\client-logs.txt`. The script accepts a port only if it was reported within the last 90 seconds and the VPN hasn't disconnected since. A future Proton VPN update that changes this log format would break detection; the script then fails safely with an error.
- **qBittorrent closed.** The script edits `Session\Port` in `%APPDATA%\qBittorrent\qBittorrent.ini`, keeping a one-time backup in `qBittorrent.ini.bak`, then starts qBittorrent.
- **qBittorrent open.** It reads and updates the settings through `/api/v2/app/preferences` and `/api/v2/app/setPreferences`.

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

## License

[MIT](LICENSE)
