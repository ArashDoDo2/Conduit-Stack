# Changelog

All notable changes to this project are documented in this file.

## [2026.02.08.19]
- Menu flow polish across installer:
  - Added `q/quit` support in main menu and existing-setup menu.
  - Added `q/quit` support in Add/Remove Slave Server prompts.
  - Improved menu prompt hints and input normalization.

## [2026.02.08.18]
- Added `b/back` option to the existing-setup (upgrade/keep/clean/modify) menu.
- Selecting `b` now returns to the main installer menu.

## [2026.02.08.17]
- Increased timeseries panel heights in Grafana dashboard.
- Moved legends from bottom table view to right-side list view.
- Reduced legend scrolling pressure for multi-server views.

## [2026.02.08.16]
- Added hub IP auto-detection in `ensure_hub_ip`.
- Detection order:
  - Saved `hub-ip` file.
  - `HUB_IP` environment variable.
  - Default route source IP via `ip route get`.
  - Fallback `hostname -I`.
- Prompt is now only used as fallback when auto-detection fails.

## [2026.02.08.15]
- Added slave installer `--upgrade` mode.
- Upgrade mode updates existing slave conduits without data reset.
- Added upgrade command hint in `Add Slave Server` output.

## [2026.02.08.14]
- Simplified hub `Upgrade in place` flow.
- Removed backup prompts in upgrade path.
- Upgrade now returns to the existing-setup menu after success.

## [2026.02.08.13]
- Fixed `b/back` handling under `set -e` so submenu back returns properly.

## [2026.02.08.12]
- Prevented unnecessary recreate of existing slave `conduitN` containers.
- Preserved existing conduits; only missing conduits are created.

## [2026.02.08.11]
- Added gradient fill (`gradientMode: opacity`) to Grafana timeseries panels.

## [2026.02.08.10]
- Improved Grafana dashboard visual styling:
  - Better stat panel color modes.
  - Smoother, thicker timeseries lines.
  - Improved legend and tooltip readability.

## [2026.02.08.9]
- Added Grafana stats for:
  - Server count.
  - Total conduits.
  - Total uploaded/downloaded across all servers.

## [2026.02.08.8]
- Added back-to-main behavior in slave submenus (`b` / `back`).
- Main menu now loops correctly when returning from submenus.

## [2026.02.08.7]
- Added selectable alias list before `Remove Slave Server`.
- Supports remove by number or direct alias input.

## [2026.02.08.6]
- Aggregated Grafana timeseries by server alias (`sum by(alias)`).
- Reduced dashboard clutter for large deployments.

## [2026.02.08.5]
- Renamed remote client UX to `Slave Server`.
- Added `Remove Slave Server` flow to delete targets by alias.

## [2026.02.08.4]
- Added conduit label support in targets for clearer legends.
- Migrated existing targets to include conduit labels when missing.

## [2026.02.08.3]
- Added fallback when OpenSSL bcrypt is unavailable.
- Uses Python bcrypt-capable path when supported.

## [2026.02.08.2]
- Fixed Docker apt repository selection for Debian vs Ubuntu.

## [2026.02.08.1]
- Added script-level version tracking output.
- Added generated version files:
  - `stack-version`
  - `web/version.txt`
