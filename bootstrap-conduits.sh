#!/usr/bin/env bash
set -e

########################################
# TTY HANDLING (for curl | bash)
########################################
if [ -r /dev/tty ]; then
  exec 3</dev/tty
else
  echo "No TTY available for interactive input."
  exit 1
fi

########################################
# UI HELPERS
########################################
if [ -t 1 ]; then
  C_RESET="\033[0m"
  C_BOLD="\033[1m"
  C_DIM="\033[2m"
  C_GREEN="\033[32m"
  C_YELLOW="\033[33m"
  C_CYAN="\033[36m"
  C_RED="\033[31m"
else
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_GREEN=""
  C_YELLOW=""
  C_CYAN=""
  C_RED=""
fi

hr() { printf '%b\n' "${C_DIM}--------------------------------------------------${C_RESET}"; }
info() { printf '%b\n' "${C_CYAN}$*${C_RESET}"; }
ok() { printf '%b\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}$*${C_RESET}"; }
err() { printf '%b\n' "${C_RED}$*${C_RESET}"; }

########################################
# CONFIG
########################################
IMAGE="ghcr.io/psiphon-inc/conduit/cli:latest"
BASE_PORT=9090
GRAFANA_PORT=3000

########################################
# DOCKER / COMPOSE
########################################
is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || \
  grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    return 0
  fi

  if is_wsl; then
    err "Docker not found in WSL."
    err "Recommended: install Docker Desktop on Windows and enable WSL integration."
    err "Then re-run this script inside WSL."
    exit 1
  fi

  warn "Docker not found. Installing..."
  OS_ID=""
  if [ -r /etc/os-release ]; then
    OS_ID=$( . /etc/os-release && printf '%s' "$ID" )
  fi

  if command -v apt-get >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y ca-certificates curl gnupg
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update -y
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      apt-get update -y
      apt-get install -y ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
        tee /etc/apt/sources.list.d/docker.list >/dev/null
      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  elif command -v dnf >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      sudo dnf -y install dnf-plugins-core
      sudo dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      sudo dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      dnf -y install dnf-plugins-core
      dnf config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
      dnf -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  elif command -v yum >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      sudo yum -y install yum-utils
      sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      sudo yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      yum -y install yum-utils
      yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
      yum -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
  elif command -v apk >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      sudo apk add --no-cache docker docker-cli-compose
    else
      apk add --no-cache docker docker-cli-compose
    fi
  elif command -v pacman >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      sudo pacman -Sy --noconfirm docker docker-compose
    else
      pacman -Sy --noconfirm docker docker-compose
    fi
  elif command -v zypper >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1; then
      sudo zypper --non-interactive install docker docker-compose
    else
      zypper --non-interactive install docker docker-compose
    fi
  else
    err "Unsupported OS. Please install Docker manually."
    exit 1
  fi

  if ! command -v docker >/dev/null 2>&1; then
    err "Docker installation failed. Please install manually."
    exit 1
  fi
}

ensure_docker

if docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  err "docker compose required"
  exit 1
fi

########################################
# EXISTING SETUP
########################################
EXISTING=$(docker ps -a --format '{{.Names}}' | grep -E '^conduit[0-9]+$|^prometheus$|^grafana$' || true)
EXISTING_CONDUITS=$(docker ps -a --format '{{.Names}}' | grep -E '^conduit[0-9]+$' || true)
EXISTING_MAX_INDEX=0
EXISTING_COUNT=0
EXISTING_IDX=()
if [ -n "$EXISTING_CONDUITS" ]; then
  while IFS= read -r name; do
    idx="${name#conduit}"
    if [[ "$idx" =~ ^[0-9]+$ ]]; then
      EXISTING_IDX+=("$idx")
      EXISTING_COUNT=$((EXISTING_COUNT+1))
      if [ "$idx" -gt "$EXISTING_MAX_INDEX" ]; then
        EXISTING_MAX_INDEX="$idx"
      fi
    fi
  done <<< "$EXISTING_CONDUITS"
fi

if [ -n "$EXISTING" ]; then
  hr
  warn "Existing containers detected"
  while IFS= read -r name; do
    [ -n "$name" ] && printf '  - %s\n' "$name"
  done <<< "$EXISTING"
  echo ""
  info "Choose how to proceed:"
  echo "  1) Keep existing setup"
  echo "  2) Upgrade in place (update images, keep data)"
  echo "  3) CLEAN install (remove containers + data)"
  read -r -u 3 -p "Choose [1/2/3]: " MODE
  if [ "$MODE" = "3" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] && docker rm -f "$name" || true
    done <<< "$EXISTING"
    rm -rf conduit*-data prometheus-data grafana-data grafana-provisioning prometheus.yml docker-compose.yml
  elif [ "$MODE" = "2" ]; then
    UPGRADE=1
  fi
fi

########################################
# CONDUIT COUNT
########################################
hr
printf '%b\n' "${C_BOLD}Conduit Stack Installer${C_RESET}"
hr
info "Answer a few questions to configure your stack."
echo ""

COUNT=
ADD_COUNT=
if [ "${MODE:-1}" = "1" ] && [ "$EXISTING_COUNT" -gt 0 ] && [ "${UPGRADE:-0}" -ne 1 ]; then
  read -r -u 3 -p "You currently have $EXISTING_COUNT Conduit instance(s). How many NEW to add? [0]: " ADD_COUNT || true
  ADD_COUNT=${ADD_COUNT:-0}
  ADD_COUNT=$(printf '%s' "$ADD_COUNT" | tr -d '[:space:]')
  [[ "$ADD_COUNT" =~ ^[0-9]+$ ]] || { err "Invalid number"; exit 1; }
  COUNT=$((EXISTING_MAX_INDEX + ADD_COUNT))
  if [ "$ADD_COUNT" -eq 0 ]; then
    read -r -u 3 -p "No new instances requested. Upgrade images and restart containers? (y/n): " UPGRADE_CONFIRM || true
    [[ "$UPGRADE_CONFIRM" =~ ^[Yy]$ ]] && UPGRADE=1
  fi
elif [ "${MODE:-1}" = "2" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  ADD_COUNT=0
  COUNT="$EXISTING_MAX_INDEX"
  UPGRADE=1
else
  read -r -u 3 -p "How many Conduit instances do you want? " COUNT || true
  COUNT=$(printf '%s' "$COUNT" | tr -d '[:space:]')
  [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ] || { err "Invalid number"; exit 1; }
fi

########################################
# PER-CLIENT LIMITS
########################################
MAX_CLIENTS=
read -r -u 3 -p "Max clients per Conduit? [50]: " MAX_CLIENTS || true
MAX_CLIENTS=${MAX_CLIENTS:-50}
MAX_CLIENTS=$(printf '%s' "$MAX_CLIENTS" | tr -d '[:space:]')

BW_Mbps=
read -r -u 3 -p "Bandwidth per client (Mbps)? [8]: " BW_Mbps || true
BW_Mbps=${BW_Mbps:-8}
BW_Mbps=$(printf '%s' "$BW_Mbps" | tr -d '[:space:]')

[[ "$MAX_CLIENTS" =~ ^[0-9]+$ ]] && [ "$MAX_CLIENTS" -gt 0 ] || { err "Invalid max clients"; exit 1; }
[[ "$BW_Mbps" =~ ^[0-9]+$ ]] && [ "$BW_Mbps" -gt 0 ] || { err "Invalid bandwidth"; exit 1; }

echo ""
hr
printf '%b\n' "${C_BOLD}Summary${C_RESET}"
if [ "${MODE:-1}" = "1" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  printf '  %-20s %s\n' "Existing conduits:" "$EXISTING_COUNT"
  printf '  %-20s %s\n' "Adding:" "${ADD_COUNT:-0}"
  printf '  %-20s %s\n' "Total conduits:" "$COUNT"
else
  printf '  %-20s %s\n' "Conduit instances:" "$COUNT"
fi
printf '  %-20s %s\n' "Max clients:" "$MAX_CLIENTS per Conduit"
printf '  %-20s %s\n' "Bandwidth limit:" "$BW_Mbps Mbps per client"
hr
echo ""

CONFIRM=
read -r -u 3 -p "Proceed with installation? (y/n): " CONFIRM || true
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

########################################
# DIRECTORIES
########################################
mkdir -p prometheus-data grafana-data grafana-provisioning/{datasources,dashboards}
INDICES=()
if [ "${MODE:-1}" = "1" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  for idx in "${EXISTING_IDX[@]}"; do INDICES+=("$idx"); done
  for ((i=EXISTING_MAX_INDEX+1; i<=COUNT; i++)); do INDICES+=("$i"); done
else
  for ((i=1; i<=COUNT; i++)); do INDICES+=("$i"); done
fi
for idx in "${INDICES[@]}"; do mkdir -p "conduit$idx-data"; done

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

for idx in "${INDICES[@]}"; do
  echo "          - conduit$idx:$((BASE_PORT+idx-1))" >> prometheus.yml
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
      "fieldConfig": {
        "defaults": { "unit": "bytes" }
      },
      "targets": [{
        "expr": "label_replace(conduit_bytes_uploaded,\"name\",\"$1\",\"instance\",\"([^:]+):.*\")",
        "legendFormat": "{{name}}"
      }]
    },
    {
      "type": "timeseries",
      "title": "Downloaded Bytes per Conduit (cumulative)",
      "gridPos": { "x": 12, "y": 11, "w": 12, "h": 7 },
      "fieldConfig": {
        "defaults": { "unit": "bytes" }
      },
      "targets": [{
        "expr": "label_replace(conduit_bytes_downloaded,\"name\",\"$1\",\"instance\",\"([^:]+):.*\")",
        "legendFormat": "{{name}}"
      }]
    },

    {
      "type": "stat",
      "title": "Total Uploaded (bytes)",
      "gridPos": { "x": 0, "y": 18, "w": 12, "h": 4 },
      "fieldConfig": {
        "defaults": { "unit": "bytes" }
      },
      "targets": [{ "expr": "sum(conduit_bytes_uploaded)" }]
    },
    {
      "type": "stat",
      "title": "Total Downloaded (bytes)",
      "gridPos": { "x": 12, "y": 18, "w": 12, "h": 4 },
      "fieldConfig": {
        "defaults": { "unit": "bytes" }
      },
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

for idx in "${INDICES[@]}"; do
cat >> docker-compose.yml <<EOF
  conduit$idx:
    image: $IMAGE
    container_name: conduit$idx
    user: "0:0"
    restart: unless-stopped
    command:
      ["start",
       "--max-clients","$MAX_CLIENTS",
       "--bandwidth","$BW_Mbps",
       "--data-dir","/home/conduit/data",
       "--metrics-addr","0.0.0.0:$((BASE_PORT+idx-1))"]
    volumes:
      - ./conduit$idx-data:/home/conduit/data
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
echo ""
info "Starting stack..."
if [ "${MODE:-1}" = "1" ] && [ "${UPGRADE:-0}" -eq 1 ]; then
  info "Pulling latest images..."
  $COMPOSE_CMD pull
  $COMPOSE_CMD up -d
elif [ "${MODE:-1}" = "2" ]; then
  $COMPOSE_CMD up -d --remove-orphans
else
  $COMPOSE_CMD up -d
fi
ok "DONE → Grafana http://<server-ip>:$GRAFANA_PORT"
