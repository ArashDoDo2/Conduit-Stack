#!/usr/bin/env bash
set -e

########################################
# TTY HANDLING (for curl | bash)
########################################
if [ ! -t 0 ]; then
  if [ -r /dev/tty ]; then
    exec < /dev/tty
  else
    echo "No TTY available for interactive input."
    exit 1
  fi
fi

########################################
# CONFIG
########################################
IMAGE="ghcr.io/psiphon-inc/conduit/cli:latest"
BASE_PORT=9090
GRAFANA_PORT=3000

########################################
# DOCKER / COMPOSE
########################################
command -v docker >/dev/null 2>&1 || { echo "❌ Docker not installed"; exit 1; }

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  echo "❌ docker compose required"
  exit 1
fi

########################################
# EXISTING SETUP
########################################
EXISTING=$(docker ps -a --format '{{.Names}}' | grep -E '^conduit[0-9]+$|^prometheus$|^grafana$' || true)

if [ -n "$EXISTING" ]; then
  echo "Existing containers detected:"
  echo "$EXISTING"
  echo "1) Keep existing setup"
  echo "2) CLEAN install (remove containers + data)"
  read -r -p "Choose [1/2]: " MODE
  if [ "$MODE" = "2" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && docker rm -f "$name" || true
    done <<< "$EXISTING"
    rm -rf conduit*-data prometheus-data grafana-data grafana-provisioning prometheus.yml docker-compose.yml
  fi
fi

########################################
# CONDUIT COUNT
########################################
COUNT=
read -r -p "How many Conduit instances do you want? " COUNT || true
COUNT=$(printf '%s' "$COUNT" | tr -d '[:space:]')
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ] || { echo "Invalid number"; exit 1; }

########################################
# PER-CLIENT LIMITS
########################################
MAX_CLIENTS=
read -r -p "Max clients per Conduit? [50]: " MAX_CLIENTS || true
MAX_CLIENTS=${MAX_CLIENTS:-50}
MAX_CLIENTS=$(printf '%s' "$MAX_CLIENTS" | tr -d '[:space:]')

BW_Mbps=
read -r -p "Bandwidth per client (Mbps)? [8]: " BW_Mbps || true
BW_Mbps=${BW_Mbps:-8}
BW_Mbps=$(printf '%s' "$BW_Mbps" | tr -d '[:space:]')

[[ "$MAX_CLIENTS" =~ ^[0-9]+$ ]] && [ "$MAX_CLIENTS" -gt 0 ] || { echo "Invalid max clients"; exit 1; }
[[ "$BW_Mbps" =~ ^[0-9]+$ ]] && [ "$BW_Mbps" -gt 0 ] || { echo "Invalid bandwidth"; exit 1; }

echo ""
echo "Summary:"
echo "  Conduit instances : $COUNT"
echo "  Max clients       : $MAX_CLIENTS per Conduit"
echo "  Bandwidth limit   : $BW_Mbps Mbps per client"
echo ""

CONFIRM=
read -r -p "Proceed with installation? (y/n): " CONFIRM || true
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

########################################
# DIRECTORIES
########################################
mkdir -p prometheus-data grafana-data grafana-provisioning/{datasources,dashboards}
for ((i=1; i<=COUNT; i++)); do mkdir -p "conduit$i-data"; done

########################################
# PROMETHEUS CONFIG
########################################
cat > prometheus.yml <<EOF
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: conduit
    static_configs:
      - targets:
EOF

for ((i=1; i<=COUNT; i++)); do
  echo "          - conduit$i:$((BASE_PORT+i-1))" >> prometheus.yml
done

########################################
# GRAFANA DATASOURCE
########################################
cat > grafana-provisioning/datasources/prometheus.yaml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: http://prometheus:9090
    isDefault: true
EOF

########################################
# DASHBOARD PROVIDER
########################################
cat > grafana-provisioning/dashboards/dashboards.yaml <<EOF
apiVersion: 1
providers:
  - name: conduit
    folder: Conduit
    type: file
    editable: false
    options:
      path: /etc/grafana/provisioning/dashboards
EOF

########################################
# DASHBOARD JSON
########################################
cat > grafana-provisioning/dashboards/conduit-dashboard.json <<'EOF'
{
  "uid": "conduit-final",
  "title": "Conduit — Clients & Traffic Volume",
  "schemaVersion": 38,
  "refresh": "5s",
  "time": { "from": "now-1h", "to": "now" },
  "panels": [

    {
      "type": "stat",
      "title": "Connected Clients (Total)",
      "gridPos": { "x": 0, "y": 0, "w": 6, "h": 4 },
      "targets": [{ "expr": "sum(conduit_connected_clients)" }]
    },
    {
      "type": "stat",
      "title": "Max Capacity",
      "gridPos": { "x": 6, "y": 0, "w": 6, "h": 4 },
      "targets": [{ "expr": "sum(conduit_max_clients)" }]
    },
    {
      "type": "stat",
      "title": "Available Slots",
      "gridPos": { "x": 12, "y": 0, "w": 6, "h": 4 },
      "targets": [{ "expr": "sum(conduit_max_clients) - sum(conduit_connected_clients)" }]
    },
    {
      "type": "stat",
      "title": "Is Live",
      "gridPos": { "x": 18, "y": 0, "w": 6, "h": 4 },
      "targets": [{ "expr": "min(conduit_is_live)" }]
    },

    {
      "type": "timeseries",
      "title": "Connected Clients per Conduit",
      "gridPos": { "x": 0, "y": 4, "w": 12, "h": 7 },
      "targets": [{
        "expr": "label_replace(conduit_connected_clients,\"name\",\"$1\",\"instance\",\"([^:]+):.*\")",
        "legendFormat": "{{name}}"
      }]
    },
    {
      "type": "timeseries",
      "title": "Connecting Clients per Conduit",
      "gridPos": { "x": 12, "y": 4, "w": 12, "h": 7 },
      "targets": [{
        "expr": "label_replace(conduit_connecting_clients,\"name\",\"$1\",\"instance\",\"([^:]+):.*\")",
        "legendFormat": "{{name}}"
      }]
    },

    {
      "type": "timeseries",
      "title": "Uploaded Bytes per Conduit (cumulative)",
      "gridPos": { "x": 0, "y": 11, "w": 12, "h": 7 },
      "targets": [{
        "expr": "label_replace(conduit_bytes_uploaded,\"name\",\"$1\",\"instance\",\"([^:]+):.*\")",
        "legendFormat": "{{name}}"
      }]
    },
    {
      "type": "timeseries",
      "title": "Downloaded Bytes per Conduit (cumulative)",
      "gridPos": { "x": 12, "y": 11, "w": 12, "h": 7 },
      "targets": [{
        "expr": "label_replace(conduit_bytes_downloaded,\"name\",\"$1\",\"instance\",\"([^:]+):.*\")",
        "legendFormat": "{{name}}"
      }]
    },

    {
      "type": "stat",
      "title": "Total Uploaded (bytes)",
      "gridPos": { "x": 0, "y": 18, "w": 12, "h": 4 },
      "targets": [{ "expr": "sum(conduit_bytes_uploaded)" }]
    },
    {
      "type": "stat",
      "title": "Total Downloaded (bytes)",
      "gridPos": { "x": 12, "y": 18, "w": 12, "h": 4 },
      "targets": [{ "expr": "sum(conduit_bytes_downloaded)" }]
    }
  ]
}
EOF

########################################
# DOCKER COMPOSE
########################################
cat > docker-compose.yml <<EOF
services:
EOF

for ((i=1; i<=COUNT; i++)); do
cat >> docker-compose.yml <<EOF
  conduit$i:
    image: $IMAGE
    container_name: conduit$i
    user: "0:0"
    restart: unless-stopped
    command:
      ["start",
       "--max-clients","$MAX_CLIENTS",
       "--bandwidth","$BW_Mbps",
       "--data-dir","/data",
       "--metrics-addr","0.0.0.0:$((BASE_PORT+i-1))"]
    volumes:
      - ./conduit$i-data:/data
EOF
done

cat >> docker-compose.yml <<EOF

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    user: "0:0"
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - ./prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    user: "0:0"
    restart: unless-stopped
    ports:
      - "$GRAFANA_PORT:3000"
    volumes:
      - ./grafana-data:/var/lib/grafana
      - ./grafana-provisioning:/etc/grafana/provisioning
EOF

########################################
# RUN
########################################
echo "🚀 Starting stack..."
$COMPOSE_CMD up -d --remove-orphans
echo "✅ DONE → Grafana http://<server-ip>:$GRAFANA_PORT"
