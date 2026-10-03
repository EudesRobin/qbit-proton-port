# Changelog

The changes a user of the script can notice, release by release. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html), as described in [Contributing: releases](docs/CONTRIBUTING.md#releases). Before updating to a new major version, read its **Upgrade** section: an existing setup needs you to act.

## [Unreleased]

## [1.0.0] - 2026-09-27

### Added

- Sync of qBittorrent's listening port with the port forwarded by Proton VPN: written to `qBittorrent.ini` before starting qBittorrent when it is closed, changed live through the WebUI API when it is open.
- Binding of qBittorrent to the VPN network interface, so torrent traffic stops instead of leaking if the VPN drops.
- Fail-closed behaviour: no VPN, or no port reported within the last 90 seconds, means an error and qBittorrent is not started.
- WebUI API over HTTPS on `127.0.0.1` with certificate pinning, and an API key encrypted with Windows DPAPI.
- Background scheduled task every 5 minutes, under the user's account and without admin rights.
- Commands `-SyncOnly`, `-PauseOnError`, `-RegisterTask`, `-UnregisterTask`, `-ShowConfig`, `-ResetCredential` and `-NewCertificate`.

[Unreleased]: https://github.com/EudesRobin/qbit-proton-port/compare/1.0.0...HEAD
[1.0.0]: https://github.com/EudesRobin/qbit-proton-port/releases/tag/1.0.0
