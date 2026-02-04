# Conduit Stack

[![License](https://img.shields.io/github/license/ArashDoDo2/Conduit-Stack)](LICENSE)

A production-grade, opinionated stack for running **Psiphon Conduit** with
**Prometheus** and **Grafana**, deployed via a single interactive installer.

Run one script, answer a few questions, and get a fully working Conduit
deployment with correct metrics and dashboards with no manual configuration.

## Features

- One-command installer (interactive, minimal questions)
- Multiple Conduit instances (scalable)
- Prometheus + Grafana pre-configured
- Accurate dashboards (no misleading metrics)
- Short, readable instance names in Grafana (`conduit1`, `conduit2`, ...)
- Configurable instance count, max clients, and bandwidth per client (Mbps)
- Clean or keep existing installation modes
- Linux-first, Windows supported via WSL2
- No node_exporter, no rate guessing, no fake traffic graphs

## What This Stack Includes

- Psiphon Conduit
- Prometheus (metrics collection)
- Grafana (pre-provisioned dashboards)

Everything runs via Docker Compose.

## Supported Platforms

### Linux (native)

- Ubuntu, Debian, etc.
- Docker + Docker Compose v2

### Windows (recommended way)

- WSL2 (Ubuntu)
- Docker Desktop with WSL2 backend

Native Windows / PowerShell execution is not supported. This stack is
intentionally Linux-first.

## Requirements

- Docker
- Docker Compose v2 (`docker compose`)
- Internet access (to pull images)

## Quick Start

One-line install (downloads and runs the installer):

```bash
curl -fsSL https://raw.githubusercontent.com/ArashDoDo2/Conduit-Stack/main/bootstrap-conduits.sh | bash
```

```bash
git clone https://github.com/ArashDoDo2/Conduit-Stack.git
cd Conduit-Stack
chmod +x bootstrap-conduits.sh
./bootstrap-conduits.sh
```

The installer will ask:

- Whether to keep or clean an existing setup
- How many Conduit instances to run
- Max clients per Conduit (default: 50)
- Bandwidth per client in Mbps (default: 8)
- Confirmation to proceed

## Grafana Access

After installation:

- URL: `http://<server-ip>:3000`
- Username: `admin`
- Password: `admin`
- Dashboard: Dashboards -> Conduit -> Conduit - Clients & Traffic Volume

Change the admin password on first login.

Prometheus is not exposed on a host port by default. Grafana is the primary UI
for metrics.

## Dashboard Philosophy

This project intentionally avoids misleading graphs.

### What is shown

- Total connected clients
- Capacity and available slots
- Clients per Conduit instance (time series)
- Cumulative traffic volume per Conduit
- Uploaded bytes
- Downloaded bytes
- Total uploaded and downloaded (stat only)

### What is not shown (on purpose)

- Throughput or Mbps graphs (Conduit does not expose true counters)
- node_exporter NIC traffic
- Uptime or idle-time noise

The goal is operational correctness, not pretty but wrong charts.

## Metric Notes

- `--bandwidth` is passed directly in Mbps, exactly as Conduit expects
- Traffic metrics are per-container cumulative gauges
- No rate calculations are performed

## Clean vs Keep Mode

If an existing installation is detected, the installer asks:

- Keep: reuse existing data and containers, update dashboards/configs
- Clean: remove containers and data directories, start fresh

## Repository Structure

```
Conduit-Stack/
├── bootstrap-conduits.sh      # Main installer
├── docker-compose.yml         # Generated
├── prometheus.yml             # Generated
├── grafana-provisioning/
│   ├── datasources/
│   └── dashboards/
├── grafana-data/
├── conduit1-data/
├── conduit2-data/
├── prometheus-data/
└── ...
```

Most files are generated automatically by the installer.

## Windows Users (WSL2)

Recommended setup:

```bash
wsl --install
```

Then install Docker Desktop and enable the WSL2 backend.
Run everything inside the WSL Ubuntu shell:

```bash
./bootstrap-conduits.sh
```

## Production Notes

- Containers run as root inside Docker to avoid permission issues
- Designed for VPS or server environments
- Suitable for long-running Conduit nodes

## Troubleshooting

- Grafana not reachable: check `http://<server-ip>:3000` and ensure port 3000 is open.
- Prometheus not scraping: confirm `prometheus.yml` was generated and containers are healthy.
- Installer fails to pull images: verify internet access and Docker daemon status.
- Docker Compose not found: ensure `docker compose` (v2) or `docker-compose` is installed.
- Permission errors: re-run the installer after ensuring Docker is running and your user can access it.

## Uninstall

If you want a clean removal:

```bash
docker rm -f $(docker ps -aq --filter name=conduit --filter name=prometheus --filter name=grafana) 2>/dev/null || true
rm -rf conduit*-data prometheus-data grafana-data grafana-provisioning prometheus.yml docker-compose.yml
```

## Roadmap (Optional)

- Alerting (capacity thresholds)
- Multi-server or federation setup
- Auto-scaling logic
- Backup and restore helpers

These are intentionally not included in the baseline.

## License

MIT. See [LICENSE](LICENSE).

## Contributing

This repository is intentionally opinionated. Contributions should focus on
correctness, not feature creep.

## Final Note

This stack exists to solve a very specific problem:
deploy Psiphon Conduit correctly, observably, and without lies in the metrics.
If that is what you need, this is for you.
