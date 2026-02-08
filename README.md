# Conduit Stack

[![License](https://img.shields.io/github/license/ArashDoDo2/Conduit-Stack)](LICENSE)
[![Release](https://img.shields.io/github/v/release/ArashDoDo2/Conduit-Stack?display_name=tag)](https://github.com/ArashDoDo2/Conduit-Stack/releases)

Interactive installer for running a central Conduit monitoring hub and multiple
remote slave servers with Prometheus + Grafana.

The project is Linux-first and built around one script:

- `bootstrap-conduits.sh`

## What It Does

- Deploys a hub stack: `conduit*`, `prometheus`, optional `grafana`, `client-web`
- Generates and serves a remote installer: `http://<hub-ip>:<web-port>/install-client.sh`
- Adds/removes slave servers from Prometheus target discovery (`targets.json`)
- Supports slave upgrade mode without wiping conduit data
- Provisions Grafana dashboards automatically

## Current Menu Flows

When you run `bootstrap-conduits.sh`, main menu options are:

1. `Setup Hub`
2. `Add Slave Server`
3. `Remove Slave Server`

If existing hub containers are detected, you also get:

1. `Keep existing setup`
2. `Upgrade in place` (simple: pull + restart, no backup prompts)
3. `CLEAN install`
4. `Modify existing setup`

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/ArashDoDo2/Conduit-Stack/main/bootstrap-conduits.sh -o bootstrap-conduits.sh
bash bootstrap-conduits.sh
```

Or clone and run locally:

```bash
git clone https://github.com/ArashDoDo2/Conduit-Stack.git
cd Conduit-Stack
chmod +x bootstrap-conduits.sh
./bootstrap-conduits.sh
```

## Hub and Slave Model

- Hub stores target definitions in `targets.json`
- Prometheus scrapes from `targets.json` via file SD
- `Add Slave Server` appends slave targets (conduit metrics + node exporter)
- `Remove Slave Server` removes all targets by alias

### Back Navigation

In slave submenus, entering `b` or `back` returns to the main menu.

## Slave Installer

The generated slave installer supports:

- Fresh/add mode:
  - `--count`
  - `--base-port`
  - `--max-clients`
  - `--bandwidth`
- Upgrade-only mode:
  - `--upgrade`

Upgrade-only mode updates existing slave containers without data reset:

```bash
curl -fsSL http://<hub-ip>:<web-port>/install-client.sh | bash -s -- --upgrade
```

## Data Safety Behavior

- Existing slave `conduitN` containers are preserved by default in normal install flow
- Missing conduits are created, existing ones are not recreated
- `--upgrade` mode upgrades existing conduits and keeps their data volumes

## Dashboard (Current)

Dashboard is provisioned at:

- Folder: `Conduit`
- Title: `Conduit — Clients & Traffic Volume`

Key panels:

- Connected clients (total)
- Max capacity
- Available slots
- Is live
- Connected clients per server (`sum by(alias)`)
- Connecting clients per server (`sum by(alias)`)
- Uploaded bytes per server (cumulative)
- Downloaded bytes per server (cumulative)
- Server count
- Total conduits
- Total uploaded/downloaded (all servers)

Legends are alias-based for readability at scale.

## Version Tracking

Script version is embedded in `bootstrap-conduits.sh` as `STACK_VERSION`.

At runtime the installer writes:

- `stack-version`
- `web/version.txt`

This helps verify which generated installer version is live on the hub.

## Requirements

- Linux host (Debian/Ubuntu and similar supported)
- Docker Engine
- Docker Compose (`docker compose` plugin or `docker-compose`)
- Internet access for pulling images

Notes:

- Installer handles Docker repo URL differences for Ubuntu vs Debian.
- If OpenSSL bcrypt is unavailable, bcrypt generation falls back to Python.

## Generated/Managed Files

Typical workspace after running hub setup:

```text
Conduit-Stack/
├── bootstrap-conduits.sh
├── docker-compose.yml
├── prometheus.yml
├── targets.json
├── web/
│   ├── install-client.sh
│   └── version.txt
├── web-port
├── stack-version
├── node-exporter-password
├── hub-ip
├── prometheus-data/
├── grafana-data/
└── conduit*-data/
```

## Access

- Grafana: `http://<hub-ip>:<grafana-port>`
- Slave installer: `http://<hub-ip>:<web-port>/install-client.sh`

## Troubleshooting

- Slave not visible in Grafana:
  - Confirm alias exists in `targets.json`
  - Confirm slave ports are reachable from hub
  - Wait for Prometheus file SD refresh
- Debian install error to Ubuntu Docker repo:
  - Use latest script version; Debian repo handling is built in
- `b` in submenu exits script:
  - Use latest script version; return handling is fixed under `set -e`
- Old generated slave installer still used:
  - Re-run hub script once to regenerate `web/install-client.sh`

## License

MIT. See [LICENSE](LICENSE).
