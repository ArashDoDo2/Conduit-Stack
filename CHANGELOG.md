# Changelog

All notable changes to this project are documented in this file.

## [2026.03.01.33]
- Bumped stack version to keep versioning aligned with the latest pushed changes.

## [2026.03.01.32]
- Added slave conduit install mode selection (`docker` or `native`) in `Add Slave Server`.
- Added generated slave installer support for `--conduit-mode` and `--native`.
- Added native Conduit systemd flow on slave while keeping node-exporter in Docker for metrics.
- Enforced native mode limit to exactly one Conduit instance per slave.
- In native upgrade mode, updater now downloads latest native `conduit` binary from official Conduit releases and restarts native service.

## [2026.02.08.31]
- Added Grafana region/scope panels for new Conduit per-region gauges:
  - `conduit_region_connected_clients`
  - `conduit_region_connecting_clients`
  - `conduit_region_bytes_uploaded`
  - `conduit_region_bytes_downloaded`
- Grouped region panels by `scope` and `region` labels and moved summary stat row down to avoid panel overlap.

## [2026.02.08.30]
- Added Conduit vNext-safe validation for max common clients (0-1000) in both Hub and generated Slave flows.
- Added Conduit vNext-safe bandwidth validation to allow `-1` (unlimited) or positive numeric values.
- Updated Hub prompts/summary wording to `Max common clients` and bandwidth prompt to mention `-1` unlimited.
- Updated Grafana capacity queries from `conduit_max_clients` to `conduit_max_common_clients`.

## [2026.02.08.29]
- Updated Conduit CLI integration to use `--max-common-clients` instead of deprecated `--max-clients` in Hub and generated Slave compose commands.
- Kept backward compatibility in generated Slave installer argument parsing by accepting both `--max-clients` and `--max-common-clients`.
- Updated generated Slave install command hints to emit `--max-common-clients`.
- Updated bandwidth prompts/summary wording from per-client to total limit and aligned numeric validation with float-compatible Conduit bandwidth flag.

## [2026.02.08.25]
- Fixed hub CPU/RAM graphs by targeting local `node-exporter` via service name.

## [2026.02.08.26]
- Fixed Hub install failure `bcrypt_hash: command not found`.
- Added global `bcrypt_hash()` in main script scope for hub node-exporter config generation.

## [2026.02.08.27]
- Replaced deprecated Python `crypt` fallback with `python3-bcrypt`.
- Added cross-distro best-effort auto-install of bcrypt Python package in both Hub and generated Slave installer flows.

## [2026.02.08.28]
- Replaced global `Is Live` stat with a per-server `Server Status` table.

## [2026.02.08.23]
- Added node-exporter based system metrics panels:
  - `CPU Usage % per Server`
  - `Memory Usage % per Server`
- Shifted summary stat row down to fit the new CPU/RAM graphs.

## [2026.02.08.22]
- Restored bottom table legends on timeseries panels (`lastNotNull`, `max`).
- Increased timeseries panel heights to reduce legend scrolling.
- Shifted lower stat row down to keep dashboard layout aligned.

## [2026.02.08.21]
- Disabled legends on main timeseries panels to remove per-panel scrolling with many servers.
- Timeseries remain readable via tooltip values on hover.

## [2026.02.08.20]
- Fixed back-to-main restart in existing-setup menu when script is launched as `bash bootstrap-conduits.sh`.
- Replaced `exec "$0"` with an absolute script path restart.

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
