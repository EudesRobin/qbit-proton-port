## Context

<!-- The problem or need this pull request answers, in one to three sentences; related issues or pull requests (#n). -->

## Changes

- <!-- A significant change, as seen by someone who runs the script. -->

## Verification

<!-- Tick only a point actually verified; an empty box means not done or not applicable, and "Details" says which. -->

- [ ] `.\harness\Invoke-Harness.ps1` exits 0
- [ ] `.\Sync-QbitProtonPort.ps1 -SyncOnly` run against the real Proton VPN and qBittorrent, and without `-SyncOnly` if the launch path changed
- [ ] Every added or modified check or unit test seen failing first on a broken case
- [ ] Failure cases and user scenarios of `docs/HARNESS.md` run, for the paths this change touches
- [ ] README, `AGENTS.md` and `docs/` updated for any changed behaviour, parameter, setting, message or file location
- [ ] Entry added under `[Unreleased]` in `CHANGELOG.md`
- [ ] CI seen passing on this pull request (workflow changed)

Details:

- <!-- Command run or real test, and the result observed. -->
