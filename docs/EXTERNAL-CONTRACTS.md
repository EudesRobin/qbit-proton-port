# External contracts

Routed from [AGENTS.md](../AGENTS.md#where-to-look). Read this before changing or diagnosing how the script reads the Proton VPN log, edits `qBittorrent.ini`, calls the Web API or detects a process.

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
