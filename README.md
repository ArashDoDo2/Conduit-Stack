# Conduit Stack

[![License](https://img.shields.io/github/license/ArashDoDo2/Conduit-Stack)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ArashDoDo2/Conduit-Stack?display_name=tag)](https://github.com/ArashDoDo2/Conduit-Stack/releases)

Interactive Linux-first installer for running a central Conduit monitoring hub
and multiple remote slave servers with Prometheus + Grafana.

Main script:

- `bootstrap-conduits.sh`

## Goals

- Fast hub bootstrap with sane defaults
- Manage slave server registration/removal safely
- Keep Conduit data persistent during normal operations and upgrades
- Provide useful, scale-friendly dashboards (including CPU/RAM per server)

## What The Installer Manages

- Hub services:
  - `conduit*`
  - `prometheus`
  - `grafana` (optional)
  - `client-web` (serves slave installer)
- Discovery and metadata:
  - `targets.json`
  - `hub-ip`
  - `web-port`
  - `stack-version`
  - `web/version.txt`

## Main Menu

1. `Setup Hub`
2. `Add Slave Server`
3. `Remove Slave Server`

Navigation:

- `b` or `back`: go to previous/main menu where available
- `q` or `quit`: exit

## Existing Setup Menu (Hub Already Running)

1. `Keep existing setup`
2. `Upgrade in place`
3. `CLEAN install`
4. `Modify existing setup`

Important behavior:

- `Upgrade in place` only pulls/restarts containers.
- `Upgrade in place` does **not** regenerate dashboard/config files.
- To apply dashboard/config changes from new script code, use `Keep existing setup` and proceed with install.

## Quick Start

Run from GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/ArashDoDo2/Conduit-Stack/main/bootstrap-conduits.sh -o bootstrap-conduits.sh
bash bootstrap-conduits.sh
```

Or clone:

```bash
git clone https://github.com/ArashDoDo2/Conduit-Stack.git
cd Conduit-Stack
chmod +x bootstrap-conduits.sh
./bootstrap-conduits.sh
```

## Slave Server Flow

`Add Slave Server` updates `targets.json` and prints ready-to-run commands.

Generated installer URL:

- `http://<hub-ip>:<web-port>/install-client.sh`

Installer modes:

- Fresh/add mode:
  - `--count`
  - `--base-port`
  - `--max-clients`
  - `--bandwidth`
- Upgrade-only mode:
  - `--upgrade`

Upgrade-only example:

```bash
curl -fsSL http://<hub-ip>:<web-port>/install-client.sh | bash -s -- --upgrade
```

Data safety on slave:

- Existing `conduitN` containers are preserved in normal add flow.
- Only missing conduits are created.
- `--upgrade` updates existing conduits without wiping data volumes.

## Dashboard Coverage

Provisioned dashboard:

- Folder: `Conduit`
- Title: `Conduit — Clients & Traffic Volume`

Panels include:

- Connected clients, capacity, slots, liveness
- Per-server connected/connecting clients
- Per-server uploaded/downloaded bytes (cumulative)
- Per-server CPU usage %
- Per-server memory usage %
- Server count, total conduits, total traffic

Notes:

- Per-server charts are alias-based (`sum by(alias)` where relevant).
- CPU/RAM panels depend on `node-exporter` metrics.

## Access

- Grafana: `http://<hub-ip>:<grafana-port>`
- Slave installer: `http://<hub-ip>:<web-port>/install-client.sh`

## Applying New Dashboard Changes (Recommended Checklist)

After pulling newer script code on hub:

1. `bash bootstrap-conduits.sh`
2. Choose `Setup Hub`
3. In existing setup menu choose `Keep existing setup`
4. Continue and confirm install
5. Restart/refresh Grafana UI (`Ctrl+F5`)

## Requirements

- Linux host (Debian/Ubuntu and similar)
- Docker Engine
- Docker Compose (`docker compose` or `docker-compose`)
- Internet access for image pulls

Implementation notes:

- Docker apt repo handling supports Debian vs Ubuntu automatically.
- If OpenSSL bcrypt is unavailable, installer falls back to Python capability.
- Hub IP is auto-detected before prompting (with manual fallback).

## Repository Files (Common Runtime State)

```text
Conduit-Stack/
├── bootstrap-conduits.sh
├── CHANGELOG.md
├── README.md
├── docker-compose.yml              # generated
├── prometheus.yml                 # generated
├── targets.json                   # generated
├── web/
│   ├── install-client.sh          # generated
│   └── version.txt                # generated
├── web-port                       # generated
├── stack-version                  # generated
├── hub-ip                         # generated
├── node-exporter-password         # generated
├── grafana-provisioning/          # generated
├── prometheus-data/
├── grafana-data/
└── conduit*-data/
```

## Troubleshooting

- Slave not visible in Grafana:
  - Confirm alias exists in `targets.json`
  - Confirm slave metrics ports are reachable from hub
  - Wait for Prometheus file SD refresh
- Dashboard changes not visible:
  - Ensure you used `Keep existing setup` (not only `Upgrade in place`)
  - Hard refresh Grafana browser cache (`Ctrl+F5`)
- Old slave installer still being served:
  - Re-run hub setup once to regenerate `web/install-client.sh`
- Running script as `bash bootstrap-conduits.sh` and menu back issues:
  - Use latest script version (fixed in recent versions)

## Versioning and Change History

- Script runtime version is `STACK_VERSION` inside `bootstrap-conduits.sh`.
- Detailed change history lives in `CHANGELOG.md`.

## License

MIT. See [LICENSE](LICENSE).
