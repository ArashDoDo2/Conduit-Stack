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

hr() { printf '%b\n' "${C_CYAN}--------------------------------------------------${C_RESET}"; }
info() { printf '%b\n' "${C_CYAN}$*${C_RESET}"; }
ok() { printf '%b\n' "${C_GREEN}$*${C_RESET}"; }
warn() { printf '%b\n' "${C_YELLOW}$*${C_RESET}"; }
err() { printf '%b\n' "${C_RED}$*${C_RESET}"; }
title() { printf '%b\n' "${C_BOLD}$*${C_RESET}"; }
section() { printf '%b\n' "${C_BOLD}${C_CYAN}$*${C_RESET}"; }

########################################
# CONFIG
########################################
IMAGE="ghcr.io/psiphon-inc/conduit/cli:latest"
STACK_VERSION="2026.02.08.4"
BASE_PORT=9090
GRAFANA_PORT=3000
BACKUP_DIR="./backups"
WEB_PORT=8088
WEB_DIR="./web"
WEB_PORT_FILE="./web-port"
VERSION_FILE="./stack-version"
TARGETS_FILE="./targets.json"
TARGETS_FILE_CONTAINER="/etc/prometheus/targets.json"
NODE_EXPORTER_USER="node"
NODE_EXPORTER_PASSWORD_FILE="./node-exporter-password"
HUB_IP_FILE="./hub-ip"

########################################
# DOCKER / COMPOSE
########################################
is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || \
  grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null
}

port_in_use() {
  local p="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -ltn "( sport = :$p )" 2>/dev/null | tail -n +2 | grep -q .
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:"$p" -sTCP:LISTEN -P -n >/dev/null 2>&1
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]$p$"
  else
    return 1
  fi
}

grafana_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^grafana$'
}

grafana_host_port() {
  docker inspect -f '{{(index (index .HostConfig.PortBindings "3000/tcp") 0).HostPort}}' grafana 2>/dev/null || true
}

client_web_exists() {
  docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^client-web$'
}

client_web_host_port() {
  docker inspect -f '{{(index (index .HostConfig.PortBindings "80/tcp") 0).HostPort}}' client-web 2>/dev/null || true
}

port_bound_by_ours() {
  local p="$1"
  local names
  names=$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E '^(conduit[0-9]+|grafana|prometheus|client-web)$' || true)
  [ -n "$names" ] || return 1
  while IFS= read -r name; do
    docker inspect -f '{{range $k,$v := .HostConfig.PortBindings}}{{(index $v 0).HostPort}}{{"\n"}}{{end}}' "$name" 2>/dev/null | \
      grep -qx "$p" && return 0
  done <<< "$names"
  return 1
}

next_free_port() {
  local p="$1"
  local tries=0
  while [ "$tries" -lt 200 ] && port_in_use "$p"; do
    p=$((p+1))
    tries=$((tries+1))
  done
  printf '%s' "$p"
}

backup_dir() {
  local src="$1"
  local label="$2"
  [ -d "$src" ] || return 0
  local ts
  ts=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  cp -a "$src" "$BACKUP_DIR/${label}-${ts}"
  ok "Backup created: $BACKUP_DIR/${label}-${ts}"
}

random_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
  fi
}

ensure_node_exporter_password() {
  if [ -r "$NODE_EXPORTER_PASSWORD_FILE" ]; then
    cat "$NODE_EXPORTER_PASSWORD_FILE"
    return 0
  fi
  local pw
  pw=$(random_password)
  printf '%s' "$pw" > "$NODE_EXPORTER_PASSWORD_FILE"
  chmod 600 "$NODE_EXPORTER_PASSWORD_FILE"
  printf '%s' "$pw"
}

ensure_hub_ip() {
  local hub_ip=""
  if [ -r "$HUB_IP_FILE" ]; then
    hub_ip=$(cat "$HUB_IP_FILE" | tr -d '[:space:]')
  fi
  if [ -z "$hub_ip" ]; then
    read -r -u 3 -p "Hub public IP or DNS (for clients to reach you): " hub_ip || true
    hub_ip=$(printf '%s' "$hub_ip" | tr -d '[:space:]')
    [ -n "$hub_ip" ] || { err "Hub IP/DNS is required."; exit 1; }
    printf '%s' "$hub_ip" > "$HUB_IP_FILE"
  fi
  printf '%s' "$hub_ip"
}

generate_client_script() {
  local hub_ip="$1"
  local node_pw="$2"
  mkdir -p "$WEB_DIR"
  cat > "$WEB_DIR/install-client.sh" <<'CLIENT_EOF'
#!/usr/bin/env bash
set -e

if [ -r /dev/tty ]; then
  exec 3</dev/tty
fi

info() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }
err() { printf '%s\n' "$*" >&2; }

HUB_IP="__HUB_IP__"
NODE_EXPORTER_PASSWORD="__NODE_EXPORTER_PASSWORD__"
IMAGE="__IMAGE__"
BASE_PORT_DEFAULT="__BASE_PORT__"

COUNT=""
BASE_PORT=""
MAX_CLIENTS=""
BW_Mbps=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --count) COUNT="$2"; shift 2 ;;
    --base-port) BASE_PORT="$2"; shift 2 ;;
    --max-clients) MAX_CLIENTS="$2"; shift 2 ;;
    --bandwidth) BW_Mbps="$2"; shift 2 ;;
    *) err "Unknown argument: $1"; exit 1 ;;
  esac
done

COUNT=${COUNT:-}
BASE_PORT=${BASE_PORT:-$BASE_PORT_DEFAULT}
MAX_CLIENTS=${MAX_CLIENTS:-50}
BW_Mbps=${BW_Mbps:-8}

if [ -z "$COUNT" ]; then
  if [ -r /dev/tty ]; then
    read -r -u 3 -p "How many Conduit instances do you want? " COUNT || true
  fi
fi
COUNT=$(printf '%s' "$COUNT" | tr -d '[:space:]')
[[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ] || { err "Invalid number of Conduit instances"; exit 1; }

BASE_PORT=$(printf '%s' "$BASE_PORT" | tr -d '[:space:]')
[[ "$BASE_PORT" =~ ^[0-9]+$ ]] && [ "$BASE_PORT" -ge 1 ] && [ "$BASE_PORT" -le 65535 ] || { err "Invalid base port"; exit 1; }

MAX_CLIENTS=$(printf '%s' "$MAX_CLIENTS" | tr -d '[:space:]')
BW_Mbps=$(printf '%s' "$BW_Mbps" | tr -d '[:space:]')
[[ "$MAX_CLIENTS" =~ ^[0-9]+$ ]] && [ "$MAX_CLIENTS" -gt 0 ] || { err "Invalid max clients"; exit 1; }
[[ "$BW_Mbps" =~ ^[0-9]+$ ]] && [ "$BW_Mbps" -gt 0 ] || { err "Invalid bandwidth"; exit 1; }

is_wsl() {
  grep -qiE 'microsoft|wsl' /proc/version 2>/dev/null || \
  grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null
}

detect_deploy_mode() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
      printf '%s' "docker"
      return 0
    fi
    printf '%s' "docker-missing-compose"
    return 0
  fi
  printf '%s' "no-docker"
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
  if command -v apt-get >/dev/null 2>&1; then
    docker_repo_os="ubuntu"
    if [ -r /etc/os-release ]; then
      . /etc/os-release
      if [ "${ID:-}" = "debian" ]; then
        docker_repo_os="debian"
      fi
    fi
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y ca-certificates curl gnupg
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$docker_repo_os/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_repo_os $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update -y
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      apt-get update -y
      apt-get install -y ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$docker_repo_os/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_repo_os $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
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

bcrypt_hash() {
  if command -v openssl >/dev/null 2>&1 && printf 'test' | openssl passwd -bcrypt -stdin >/dev/null 2>&1; then
    printf '%s' "$1" | openssl passwd -bcrypt -stdin
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" <<'PY'
import crypt, sys
pw=sys.argv[1]
method=getattr(crypt, "METHOD_BLOWFISH", None)
if method is None:
    raise SystemExit("python3 crypt does not support bcrypt (METHOD_BLOWFISH missing)")
print(crypt.crypt(pw, crypt.mksalt(method)))
PY
  else
    err "Need openssl or python3 to generate bcrypt hash."
    exit 1
  fi
}

MODE=$(detect_deploy_mode)
if [ "$MODE" = "docker-missing-compose" ]; then
  err "Docker detected but docker compose is missing."
  err "Install Docker Compose plugin or docker-compose, then re-run."
  exit 1
fi

ensure_docker

COMPOSE_BASE=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE_BASE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_BASE=(docker-compose)
else
  err "docker compose required"
  exit 1
fi

compose() {
  "${COMPOSE_BASE[@]}" "$@"
}

info "Configuring firewall (ufw) for node-exporter..."
if command -v ufw >/dev/null 2>&1; then
  ufw allow from "$HUB_IP" to any port 9100 proto tcp >/dev/null 2>&1 || true
  ufw deny 9100 >/dev/null 2>&1 || true
  ufw --force enable >/dev/null 2>&1 || true
else
  warn "ufw not installed; skipping firewall configuration."
fi

mkdir -p node-exporter
HASH=$(bcrypt_hash "$NODE_EXPORTER_PASSWORD")
cat > node-exporter/web.yml <<EOF
basic_auth_users:
  __NODE_EXPORTER_USER__: $HASH
EOF

cat > docker-compose.yml <<EOF
services:
  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    user: "0:0"
    restart: unless-stopped
    command:
      - '--web.config.file=/etc/node-exporter/web.yml'
    ports:
      - "9100:9100"
    volumes:
      - ./node-exporter/web.yml:/etc/node-exporter/web.yml:ro
EOF

for i in $(seq 1 "$COUNT"); do
  PORT=$((BASE_PORT + i - 1))
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
       "--data-dir","/home/conduit/data",
       "--metrics-addr","0.0.0.0:$PORT"]
    ports:
      - "$PORT:$PORT"
    volumes:
      - ./conduit$i-data:/home/conduit/data
EOF
done

for i in $(seq 1 "$COUNT"); do
  mkdir -p "conduit$i-data"
done

info "Starting client stack..."
compose up -d

HOSTNAME=$(hostname | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-30)
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
info "Client ready."
info "Name: ${HOSTNAME:-unknown}"
info "IP: ${IP:-unknown}"
info "Conduits: $COUNT"
info "Base metrics port: $BASE_PORT"
info "node-exporter: 9100 (Basic Auth enabled)"
CLIENT_EOF

  sed -i \
    -e "s|__HUB_IP__|$hub_ip|g" \
    -e "s|__NODE_EXPORTER_PASSWORD__|$node_pw|g" \
    -e "s|__IMAGE__|$IMAGE|g" \
    -e "s|__BASE_PORT__|$BASE_PORT|g" \
    -e "s|__NODE_EXPORTER_USER__|$NODE_EXPORTER_USER|g" \
    "$WEB_DIR/install-client.sh"
  chmod +x "$WEB_DIR/install-client.sh"
}

update_target_group() {
  local alias="$1"
  local role="$2"
  shift 2
  local targets=("$@")
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required to update $TARGETS_FILE"
    exit 1
  fi
  python3 - "$TARGETS_FILE" "$alias" "$role" "${targets[@]}" <<'PY'
import json, os, sys
path=sys.argv[1]
alias=sys.argv[2]
role=sys.argv[3]
targets=sys.argv[4:]
data=[]
if os.path.exists(path):
  with open(path, "r") as f:
    raw=f.read().strip()
    if raw:
      data=json.loads(raw)
data=[g for g in data if not (g.get("labels",{}).get("alias")==alias and g.get("labels",{}).get("role")==role)]
if role == "conduit":
  for t in targets:
    host=t.split(":",1)[0]
    conduit=host if host.startswith("conduit") else host
    data.append({"targets": [t], "labels": {"alias": alias, "role": role, "conduit": conduit}})
else:
  data.append({"targets": targets, "labels": {"alias": alias, "role": role}})
with open(path, "w") as f:
  json.dump(data, f, indent=2)
PY
}

migrate_targets_conduit_labels() {
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required to migrate $TARGETS_FILE"
    exit 1
  fi
  python3 - "$TARGETS_FILE" <<'PY'
import json, os, sys
path=sys.argv[1]
if not os.path.exists(path):
  raise SystemExit(0)
with open(path, "r") as f:
  raw=f.read().strip()
  if not raw:
    raise SystemExit(0)
  data=json.loads(raw)
out=[]
changed=False
for g in data:
  labels=dict(g.get("labels", {}))
  role=labels.get("role")
  targets=list(g.get("targets", []))
  if role=="conduit" and "conduit" not in labels and targets:
    changed=True
    if len(targets)==1:
      t=targets[0]
      host=t.split(":",1)[0]
      labels["conduit"]=host if host.startswith("conduit") else "conduit1"
      out.append({"targets":[t], "labels":labels})
    else:
      for i, t in enumerate(targets, start=1):
        nl=dict(labels)
        nl["conduit"]=f"conduit{i}"
        out.append({"targets":[t], "labels":nl})
  else:
    out.append(g)
if changed:
  with open(path, "w") as f:
    json.dump(out, f, indent=2)
PY
}

append_client_targets() {
  local alias="$1"
  local ip="$2"
  local base_port="$3"
  local count="$4"
  if ! command -v python3 >/dev/null 2>&1; then
    err "python3 is required to update $TARGETS_FILE"
    exit 1
  fi
  python3 - "$TARGETS_FILE" "$alias" "$ip" "$base_port" "$count" <<'PY'
import json, os, sys
path=sys.argv[1]
alias=sys.argv[2]
ip=sys.argv[3]
base_port=int(sys.argv[4])
count=int(sys.argv[5])
data=[]
if os.path.exists(path):
  with open(path, "r") as f:
    raw=f.read().strip()
    if raw:
      data=json.loads(raw)
for g in data:
  labels=g.get("labels",{})
  if labels.get("alias")==alias:
    raise SystemExit(f"Alias already exists: {alias}")
conduit_targets=[f"{ip}:{base_port+i}" for i in range(count)]
for i, t in enumerate(conduit_targets, start=1):
  data.append({"targets": [t], "labels": {"alias": alias, "role": "conduit", "conduit": f"conduit{i}"}})
data.append({"targets": [f"{ip}:9100"], "labels": {"alias": alias, "role": "node"}})
with open(path, "w") as f:
  json.dump(data, f, indent=2)
PY
}

add_remote_client() {
  if [ ! -f "$TARGETS_FILE" ]; then
    err "$TARGETS_FILE not found. Run 'Setup Hub' first."
    exit 1
  fi
  if [ ! -r "$NODE_EXPORTER_PASSWORD_FILE" ]; then
    err "$NODE_EXPORTER_PASSWORD_FILE not found. Run 'Setup Hub' first."
    exit 1
  fi

  local hub_ip node_pw client_alias client_ip count base_port max_clients bw_mbps web_port
  node_pw=$(cat "$NODE_EXPORTER_PASSWORD_FILE")
  hub_ip=$(ensure_hub_ip)
  web_port=$(cat "$WEB_PORT_FILE" 2>/dev/null || printf '%s' "$WEB_PORT")

  read -r -u 3 -p "Client name/alias: " client_alias || true
  client_alias=$(printf '%s' "$client_alias" | tr -d '[:space:]')
  [ -n "$client_alias" ] || { err "Client name is required."; exit 1; }

  read -r -u 3 -p "Client IP/DNS: " client_ip || true
  client_ip=$(printf '%s' "$client_ip" | tr -d '[:space:]')
  [ -n "$client_ip" ] || { err "Client IP/DNS is required."; exit 1; }

  read -r -u 3 -p "How many Conduit instances on client? [1]: " count || true
  count=${count:-1}
  count=$(printf '%s' "$count" | tr -d '[:space:]')
  [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ] || { err "Invalid number"; exit 1; }

  read -r -u 3 -p "Client base metrics port? [$BASE_PORT]: " base_port || true
  base_port=${base_port:-$BASE_PORT}
  base_port=$(printf '%s' "$base_port" | tr -d '[:space:]')
  [[ "$base_port" =~ ^[0-9]+$ ]] && [ "$base_port" -ge 1 ] && [ "$base_port" -le 65535 ] || { err "Invalid base port"; exit 1; }

  read -r -u 3 -p "Max clients per Conduit on client? [50]: " max_clients || true
  max_clients=${max_clients:-50}
  max_clients=$(printf '%s' "$max_clients" | tr -d '[:space:]')
  [[ "$max_clients" =~ ^[0-9]+$ ]] && [ "$max_clients" -gt 0 ] || { err "Invalid max clients"; exit 1; }

  read -r -u 3 -p "Bandwidth per client (Mbps) on client? [8]: " bw_mbps || true
  bw_mbps=${bw_mbps:-8}
  bw_mbps=$(printf '%s' "$bw_mbps" | tr -d '[:space:]')
  [[ "$bw_mbps" =~ ^[0-9]+$ ]] && [ "$bw_mbps" -gt 0 ] || { err "Invalid bandwidth"; exit 1; }

  append_client_targets "$client_alias" "$client_ip" "$base_port" "$count"
  migrate_targets_conduit_labels
  generate_client_script "$hub_ip" "$node_pw"

  hr
  ok "Client targets appended to $TARGETS_FILE (Prometheus will pick them up automatically)."
  info "Run this on the client:"
  printf '  curl -fsSL http://%s:%s/install-client.sh | bash -s -- --count %s --base-port %s --max-clients %s --bandwidth %s\n' \
    "$hub_ip" "$web_port" "$count" "$base_port" "$max_clients" "$bw_mbps"
  hr
}

hr
title "Conduit Stack Installer"
hr
info "Version: $STACK_VERSION"
info "Choose an action:"
printf '  %b1%b) Setup Hub %b(Prometheus + Grafana + Web installer)%b\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
printf '  %b2%b) Add Remote Client %b(append targets + generate install command)%b\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
read -r -u 3 -p "Choose [1/2]: " MAIN_MODE || true
case "$MAIN_MODE" in
  1|"") MAIN_MODE="hub" ;;
  2) MAIN_MODE="client" ;;
  *) err "Invalid selection"; exit 1 ;;
esac

if [ "$MAIN_MODE" = "client" ]; then
  add_remote_client
  exit 0
fi

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
    docker_repo_os="ubuntu"
    if [ -r /etc/os-release ]; then
      . /etc/os-release
      if [ "${ID:-}" = "debian" ]; then
        docker_repo_os="debian"
      fi
    fi
    if command -v sudo >/dev/null 2>&1; then
      sudo apt-get update -y
      sudo apt-get install -y ca-certificates curl gnupg
      sudo install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$docker_repo_os/gpg" | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      sudo chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_repo_os $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
        sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      sudo apt-get update -y
      sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
      apt-get update -y
      apt-get install -y ca-certificates curl gnupg
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL "https://download.docker.com/linux/$docker_repo_os/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
      chmod a+r /etc/apt/keyrings/docker.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$docker_repo_os $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
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

COMPOSE_BASE=()
if docker compose version >/dev/null 2>&1; then
  COMPOSE_BASE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_BASE=(docker-compose)
else
  err "docker compose required"
  exit 1
fi

compose() {
  # Reuse the original compose project name if the stack was created from another directory.
  # This avoids "container name is already in use" conflicts when container_name is set.
  if [ -n "${COMPOSE_PROJECT_NAME_OVERRIDE:-}" ]; then
    "${COMPOSE_BASE[@]}" -p "$COMPOSE_PROJECT_NAME_OVERRIDE" "$@"
  elif [ -n "${COMPOSE_PROJECT_NAME:-}" ]; then
    "${COMPOSE_BASE[@]}" -p "$COMPOSE_PROJECT_NAME" "$@"
  else
    "${COMPOSE_BASE[@]}" "$@"
  fi
}

########################################
# EXISTING SETUP
########################################
EXISTING=$(docker ps -a --format '{{.Names}}' | grep -E '^conduit[0-9]+$|^prometheus$|^grafana$|^client-web$' || true)
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
  # If the existing stack was started from a different directory, docker compose's default
  # project name will differ. Reuse the old project name from compose labels to "adopt"
  # the existing containers instead of failing with name conflicts.
  if [ -z "${COMPOSE_PROJECT_NAME:-}" ]; then
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      pn=$(docker inspect -f '{{ index .Config.Labels "com.docker.compose.project" }}' "$name" 2>/dev/null || true)
      if [ -n "$pn" ]; then
        COMPOSE_PROJECT_NAME="$pn"
        break
      fi
    done <<< "$EXISTING"
  fi

  hr
  section "Existing containers detected"
  while IFS= read -r name; do
    [ -n "$name" ] && printf '  - %s\n' "$name"
  done <<< "$EXISTING"
  echo ""
  info "Choose how to proceed:"
  printf '  %b1%b) Keep existing setup %b(add new containers to current setup)%b\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %b2%b) Upgrade in place %b(pull latest images, restart, keep data)%b\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %b3%b) CLEAN install %b(remove containers + data, start fresh)%b\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  printf '  %b4%b) Modify existing setup %b(add or remove specific conduits)%b\n' "$C_BOLD" "$C_RESET" "$C_DIM" "$C_RESET"
  read -r -u 3 -p "Choose [1/2/3/4]: " MODE
  if [ "$MODE" = "3" ]; then
if [ -d grafana-data ]; then
  read -r -u 3 -p "Backup Grafana data before CLEAN install? (y/n) [y]: " BK_GRAFANA || true
  BK_GRAFANA=${BK_GRAFANA:-y}
  if [[ "$BK_GRAFANA" =~ ^[Yy]$ ]]; then
    backup_dir "grafana-data" "grafana-data"
  fi
fi
    if [ -d prometheus-data ]; then
      read -r -u 3 -p "Backup Prometheus data before CLEAN install? (y/n) [y]: " BK_PROM || true
      BK_PROM=${BK_PROM:-y}
      if [[ "$BK_PROM" =~ ^[Yy]$ ]]; then
        backup_dir "prometheus-data" "prometheus-data"
      fi
    fi
    DELETE_GRAFANA_DATA=1
    if [ -d grafana-data ]; then
      read -r -u 3 -p "Delete Grafana data? (y/n) [n]: " DEL_GRAFANA || true
      DEL_GRAFANA=${DEL_GRAFANA:-n}
      [[ "$DEL_GRAFANA" =~ ^[Yy]$ ]] || DELETE_GRAFANA_DATA=0
    fi
    while IFS= read -r name; do
      [ -n "$name" ] && docker rm -f "$name" || true
    done <<< "$EXISTING"
    rm -rf conduit*-data prometheus-data grafana-provisioning prometheus.yml docker-compose.yml \
      "$WEB_DIR" "$TARGETS_FILE" "$NODE_EXPORTER_PASSWORD_FILE" "$HUB_IP_FILE" "$WEB_PORT_FILE"
    if [ "$DELETE_GRAFANA_DATA" -eq 1 ]; then
      rm -rf grafana-data
    fi
  elif [ "$MODE" = "2" ]; then
    UPGRADE=1
    if [ -d grafana-data ]; then
      read -r -u 3 -p "Backup Grafana data before upgrade? (y/n) [y]: " BK_GRAFANA || true
      BK_GRAFANA=${BK_GRAFANA:-y}
      if [[ "$BK_GRAFANA" =~ ^[Yy]$ ]]; then
        backup_dir "grafana-data" "grafana-data"
      fi
    fi
    if [ -d prometheus-data ]; then
      read -r -u 3 -p "Backup Prometheus data before upgrade? (y/n) [y]: " BK_PROM || true
      BK_PROM=${BK_PROM:-y}
      if [[ "$BK_PROM" =~ ^[Yy]$ ]]; then
        backup_dir "prometheus-data" "prometheus-data"
      fi
    fi
  elif [ "$MODE" = "4" ]; then
    MODIFY=1
  fi
fi

########################################
# CONDUIT COUNT
########################################
hr
title "Hub Setup"
hr
info "Answer a few questions to configure your stack."
echo ""

HUB_ALIAS=
read -r -u 3 -p "Hub alias (label in Grafana)? [hub]: " HUB_ALIAS || true
HUB_ALIAS=${HUB_ALIAS:-hub}
HUB_ALIAS=$(printf '%s' "$HUB_ALIAS" | tr -d '[:space:]')
if [ -z "$HUB_ALIAS" ]; then
  HUB_ALIAS="hub"
fi

COUNT=
ADD_COUNT=
REMOVE_IDX=()
REMOVE_DATA=0
EXISTING_MAX_CLIENTS=""
EXISTING_BW=""
if [ -f docker-compose.yml ]; then
  EXISTING_MAX_CLIENTS=$(sed -n 's/.*--max-clients","\([0-9][0-9]*\)".*/\1/p' docker-compose.yml | head -n1 || true)
  EXISTING_BW=$(sed -n 's/.*--bandwidth","\([0-9][0-9]*\)".*/\1/p' docker-compose.yml | head -n1 || true)
fi
if [ "${MODE:-1}" = "4" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  echo ""
  info "Existing conduits:"
  EXISTING_LABELS=()
  for idx in "${EXISTING_IDX[@]}"; do EXISTING_LABELS+=("conduit$idx"); done
  printf '  %b%s%b\n' "$C_BOLD" "${EXISTING_LABELS[*]}" "$C_RESET"
  read -r -u 3 -p "Conduit numbers to remove (comma-separated) [none]: " REMOVE_RAW || true
  REMOVE_RAW=$(printf '%s' "$REMOVE_RAW" | tr -d '[:space:]')
  if [ -n "$REMOVE_RAW" ]; then
    IFS=',' read -r -a REMOVE_IDX <<< "$REMOVE_RAW"
    for r in "${REMOVE_IDX[@]}"; do
      [[ "$r" =~ ^[0-9]+$ ]] || { err "Invalid conduit number: $r"; exit 1; }
      if ! printf '%s\n' "${EXISTING_IDX[@]}" | grep -qx "$r"; then
        err "Conduit $r not found in existing setup"
        exit 1
      fi
    done
    read -r -u 3 -p "Remove data directories for selected conduits? (y/n): " REMOVE_DATA_CONFIRM || true
    [[ "$REMOVE_DATA_CONFIRM" =~ ^[Yy]$ ]] && REMOVE_DATA=1
  fi

  read -r -u 3 -p "How many NEW Conduit instances to add? [0]: " ADD_COUNT || true
  ADD_COUNT=${ADD_COUNT:-0}
  ADD_COUNT=$(printf '%s' "$ADD_COUNT" | tr -d '[:space:]')
  [[ "$ADD_COUNT" =~ ^[0-9]+$ ]] || { err "Invalid number"; exit 1; }

  # Apply removals now to avoid conflicts
  if [ "${#REMOVE_IDX[@]}" -gt 0 ]; then
    for r in "${REMOVE_IDX[@]}"; do
      docker rm -f "conduit$r" >/dev/null 2>&1 || true
      if [ "$REMOVE_DATA" -eq 1 ]; then
        rm -rf "conduit$r-data"
      fi
    done
  fi

  EXISTING_MAX_INDEX=0
  REMAIN_IDX=()
  for idx in "${EXISTING_IDX[@]}"; do
    skip=0
    for r in "${REMOVE_IDX[@]}"; do
      [ "$idx" = "$r" ] && skip=1 && break
    done
    if [ "$skip" -eq 0 ]; then
      REMAIN_IDX+=("$idx")
      if [ "$idx" -gt "$EXISTING_MAX_INDEX" ]; then
        EXISTING_MAX_INDEX="$idx"
      fi
    fi
  done

  COUNT=$((EXISTING_MAX_INDEX + ADD_COUNT))
  if [ "$COUNT" -le 0 ]; then
    err "No conduits selected. Aborting."
    exit 1
  fi
elif [ "${MODE:-1}" = "1" ] && [ "$EXISTING_COUNT" -gt 0 ] && [ "${UPGRADE:-0}" -ne 1 ]; then
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

if [ "${MODE:-1}" = "1" ] && [ "$EXISTING_COUNT" -gt 0 ] && [ "${ADD_COUNT:-0}" -eq 0 ] && [ "${UPGRADE:-0}" -ne 1 ]; then
  info "No changes requested. Exiting."
  exit 0
fi

########################################
# PER-CLIENT LIMITS
########################################
MAX_CLIENTS=
BW_Mbps=
NEED_LIMITS=1
if [ "${MODE:-1}" = "4" ] && [ "${ADD_COUNT:-0}" -eq 0 ] && [ "${UPGRADE:-0}" -ne 1 ]; then
  NEED_LIMITS=0
fi

if [ "$NEED_LIMITS" -eq 1 ]; then
  read -r -u 3 -p "Max clients per Conduit? [${EXISTING_MAX_CLIENTS:-50}]: " MAX_CLIENTS || true
  MAX_CLIENTS=${MAX_CLIENTS:-${EXISTING_MAX_CLIENTS:-50}}
  MAX_CLIENTS=$(printf '%s' "$MAX_CLIENTS" | tr -d '[:space:]')

  read -r -u 3 -p "Bandwidth per client (Mbps)? [${EXISTING_BW:-8}]: " BW_Mbps || true
  BW_Mbps=${BW_Mbps:-${EXISTING_BW:-8}}
  BW_Mbps=$(printf '%s' "$BW_Mbps" | tr -d '[:space:]')
else
  MAX_CLIENTS=${EXISTING_MAX_CLIENTS:-50}
  BW_Mbps=${EXISTING_BW:-8}
fi

[[ "$MAX_CLIENTS" =~ ^[0-9]+$ ]] && [ "$MAX_CLIENTS" -gt 0 ] || { err "Invalid max clients"; exit 1; }
[[ "$BW_Mbps" =~ ^[0-9]+$ ]] && [ "$BW_Mbps" -gt 0 ] || { err "Invalid bandwidth"; exit 1; }

########################################
# GRAFANA
########################################
ENABLE_GRAFANA=1
GRAFANA_CHOICE=
read -r -u 3 -p "Enable Grafana? (y/n) [y]: " GRAFANA_CHOICE || true
GRAFANA_CHOICE=${GRAFANA_CHOICE:-y}
if [[ "$GRAFANA_CHOICE" =~ ^[Nn]$ ]]; then
  ENABLE_GRAFANA=0
elif ! [[ "$GRAFANA_CHOICE" =~ ^[Yy]$ ]]; then
  err "Invalid Grafana choice"
  exit 1
fi
if [ "$ENABLE_GRAFANA" -eq 1 ]; then
  read -r -u 3 -p "Grafana host port? [$GRAFANA_PORT]: " GRAFANA_PORT_INPUT || true
  GRAFANA_PORT_INPUT=${GRAFANA_PORT_INPUT:-$GRAFANA_PORT}
  GRAFANA_PORT_INPUT=$(printf '%s' "$GRAFANA_PORT_INPUT" | tr -d '[:space:]')
  [[ "$GRAFANA_PORT_INPUT" =~ ^[0-9]+$ ]] || { err "Invalid Grafana port"; exit 1; }
  [ "$GRAFANA_PORT_INPUT" -ge 1 ] && [ "$GRAFANA_PORT_INPUT" -le 65535 ] || { err "Invalid Grafana port"; exit 1; }
  GRAFANA_PORT="$GRAFANA_PORT_INPUT"
  if port_in_use "$GRAFANA_PORT"; then
    EXISTING_GRAFANA_PORT=""
    if grafana_exists; then
      EXISTING_GRAFANA_PORT=$(grafana_host_port)
    fi
    if [ -n "$EXISTING_GRAFANA_PORT" ] && [ "$EXISTING_GRAFANA_PORT" = "$GRAFANA_PORT" ]; then
      info "Port $GRAFANA_PORT already used by existing Grafana; keeping it."
    elif port_bound_by_ours "$GRAFANA_PORT"; then
      info "Port $GRAFANA_PORT already used by existing Conduit stack; keeping it."
    else
      warn "Port $GRAFANA_PORT is already in use."
    SUGGESTED_PORT=$(next_free_port "$((GRAFANA_PORT+1))")
    read -r -u 3 -p "Use $SUGGESTED_PORT instead? (y/n) [y]: " PORT_CONFIRM || true
    PORT_CONFIRM=${PORT_CONFIRM:-y}
    if [[ "$PORT_CONFIRM" =~ ^[Yy]$ ]]; then
      GRAFANA_PORT="$SUGGESTED_PORT"
    else
      while :; do
        read -r -u 3 -p "Enter an available Grafana port: " ALT_PORT || true
        ALT_PORT=$(printf '%s' "$ALT_PORT" | tr -d '[:space:]')
        [[ "$ALT_PORT" =~ ^[0-9]+$ ]] || { err "Invalid Grafana port"; continue; }
        [ "$ALT_PORT" -ge 1 ] && [ "$ALT_PORT" -le 65535 ] || { err "Invalid Grafana port"; continue; }
        if port_in_use "$ALT_PORT"; then
          warn "Port $ALT_PORT is still in use."
        else
          GRAFANA_PORT="$ALT_PORT"
          break
        fi
      done
    fi
    fi
  fi
fi

########################################
# WEB INSTALLER
########################################
read -r -u 3 -p "Client installer web port? [$WEB_PORT]: " WEB_PORT_INPUT || true
WEB_PORT_INPUT=${WEB_PORT_INPUT:-$WEB_PORT}
WEB_PORT_INPUT=$(printf '%s' "$WEB_PORT_INPUT" | tr -d '[:space:]')
[[ "$WEB_PORT_INPUT" =~ ^[0-9]+$ ]] || { err "Invalid web port"; exit 1; }
[ "$WEB_PORT_INPUT" -ge 1 ] && [ "$WEB_PORT_INPUT" -le 65535 ] || { err "Invalid web port"; exit 1; }
WEB_PORT="$WEB_PORT_INPUT"
if port_in_use "$WEB_PORT"; then
  EXISTING_WEB_PORT=""
  if client_web_exists; then
    EXISTING_WEB_PORT=$(client_web_host_port)
  fi
  if [ -n "$EXISTING_WEB_PORT" ] && [ "$EXISTING_WEB_PORT" = "$WEB_PORT" ]; then
    info "Port $WEB_PORT already used by existing client-web; keeping it."
  elif port_bound_by_ours "$WEB_PORT"; then
    info "Port $WEB_PORT already used by existing Conduit stack; keeping it."
  else
    warn "Port $WEB_PORT is already in use."
    SUGGESTED_PORT=$(next_free_port "$((WEB_PORT+1))")
    read -r -u 3 -p "Use $SUGGESTED_PORT instead? (y/n) [y]: " PORT_CONFIRM || true
    PORT_CONFIRM=${PORT_CONFIRM:-y}
    if [[ "$PORT_CONFIRM" =~ ^[Yy]$ ]]; then
      WEB_PORT="$SUGGESTED_PORT"
    else
      while :; do
        read -r -u 3 -p "Enter an available web port: " ALT_PORT || true
        ALT_PORT=$(printf '%s' "$ALT_PORT" | tr -d '[:space:]')
        [[ "$ALT_PORT" =~ ^[0-9]+$ ]] || { err "Invalid web port"; continue; }
        [ "$ALT_PORT" -ge 1 ] && [ "$ALT_PORT" -le 65535 ] || { err "Invalid web port"; continue; }
        if port_in_use "$ALT_PORT"; then
          warn "Port $ALT_PORT is still in use."
        else
          WEB_PORT="$ALT_PORT"
          break
        fi
      done
    fi
  fi
fi

echo ""
hr
title "Summary"
if [ "${MODE:-1}" = "1" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  printf '  %-20s %s\n' "Existing conduits:" "$EXISTING_COUNT"
  printf '  %-20s %s\n' "Adding:" "${ADD_COUNT:-0}"
  printf '  %-20s %s\n' "Total conduits:" "$COUNT"
elif [ "${MODE:-1}" = "4" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  printf '  %-20s %s\n' "Existing conduits:" "$EXISTING_COUNT"
  if [ -n "${REMOVE_RAW:-}" ]; then
    REMOVE_NAMES=()
    for r in "${REMOVE_IDX[@]}"; do REMOVE_NAMES+=("conduit$r"); done
    printf '  %-20s %s\n' "Removing:" "${REMOVE_NAMES[*]}"
  else
    printf '  %-20s %s\n' "Removing:" "none"
  fi
  printf '  %-20s %s\n' "Adding:" "${ADD_COUNT:-0}"
  printf '  %-20s %s\n' "Total conduits:" "$COUNT"
else
  printf '  %-20s %s\n' "Conduit instances:" "$COUNT"
fi
printf '  %-20s %s\n' "Max clients:" "$MAX_CLIENTS per Conduit"
printf '  %-20s %s\n' "Bandwidth limit:" "$BW_Mbps Mbps per client"
if [ "$ENABLE_GRAFANA" -eq 1 ]; then
  printf '  %-20s %s\n' "Grafana:" "enabled (port $GRAFANA_PORT)"
else
  printf '  %-20s %s\n' "Grafana:" "disabled"
fi
printf '  %-20s %s\n' "Client installer:" "enabled (port $WEB_PORT)"
hr
echo ""

CONFIRM=
read -r -u 3 -p "Proceed with installation? (y/n): " CONFIRM || true
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 0

########################################
# DIRECTORIES
########################################
mkdir -p prometheus-data
if [ "$ENABLE_GRAFANA" -eq 1 ]; then
  mkdir -p grafana-data grafana-provisioning/{datasources,dashboards,plugins,alerting}
fi
mkdir -p "$WEB_DIR"
printf '%s' "$WEB_PORT" > "$WEB_PORT_FILE"
printf '%s\n' "$STACK_VERSION" > "$VERSION_FILE"
printf 'version=%s\nupdated_at=%s\n' "$STACK_VERSION" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$WEB_DIR/version.txt"
NODE_EXPORTER_PASSWORD=$(ensure_node_exporter_password)
HUB_IP=$(ensure_hub_ip)
INDICES=()
if [ "${MODE:-1}" = "4" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  for idx in "${REMAIN_IDX[@]}"; do INDICES+=("$idx"); done
  for ((i=EXISTING_MAX_INDEX+1; i<=COUNT; i++)); do INDICES+=("$i"); done
elif [ "${MODE:-1}" = "1" ] && [ "$EXISTING_COUNT" -gt 0 ]; then
  for idx in "${EXISTING_IDX[@]}"; do INDICES+=("$idx"); done
  for ((i=EXISTING_MAX_INDEX+1; i<=COUNT; i++)); do INDICES+=("$i"); done
else
  for ((i=1; i<=COUNT; i++)); do INDICES+=("$i"); done
fi
for idx in "${INDICES[@]}"; do mkdir -p "conduit$idx-data"; done

LOCAL_TARGETS=()
for idx in "${INDICES[@]}"; do
  LOCAL_TARGETS+=("conduit$idx:$((BASE_PORT+idx-1))")
done
update_target_group "$HUB_ALIAS" "conduit" "${LOCAL_TARGETS[@]}"
migrate_targets_conduit_labels
generate_client_script "$HUB_IP" "$NODE_EXPORTER_PASSWORD"

########################################
# PROMETHEUS CONFIG
########################################
cat > prometheus.yml <<EOF
global:
  scrape_interval: 5s

scrape_configs:
  - job_name: conduit
    file_sd_configs:
      - files:
          - $TARGETS_FILE_CONTAINER
        refresh_interval: 5s
    relabel_configs:
      - source_labels: [role]
        regex: conduit
        action: keep
  - job_name: node
    file_sd_configs:
      - files:
          - $TARGETS_FILE_CONTAINER
        refresh_interval: 5s
    basic_auth:
      username: $NODE_EXPORTER_USER
      password: $NODE_EXPORTER_PASSWORD
    relabel_configs:
      - source_labels: [role]
        regex: node
        action: keep
EOF

########################################
# GRAFANA DATASOURCE
########################################
if [ "$ENABLE_GRAFANA" -eq 1 ]; then
  DS_URL="http://prometheus:9090"
cat > grafana-provisioning/datasources/prometheus.yaml <<EOF
apiVersion: 1
datasources:
  - name: Prometheus
    type: prometheus
    access: proxy
    url: $DS_URL
    isDefault: true
EOF
fi

########################################
# DASHBOARD PROVIDER
########################################
if [ "$ENABLE_GRAFANA" -eq 1 ]; then
cat > grafana-provisioning/dashboards/dashboards.yaml <<EOF
apiVersion: 1
providers:
  - name: conduit
    folder: Conduit
    type: file
    editable: false
    updateIntervalSeconds: 10
    options:
      path: /etc/grafana/provisioning/dashboards
EOF
fi

########################################
# DASHBOARD JSON
########################################
if [ "$ENABLE_GRAFANA" -eq 1 ]; then
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
        "expr": "conduit_connected_clients",
        "legendFormat": "{{alias}}/{{conduit}}"
      }]
    },
    {
      "type": "timeseries",
      "title": "Connecting Clients per Conduit",
      "gridPos": { "x": 12, "y": 4, "w": 12, "h": 7 },
      "targets": [{
        "expr": "conduit_connecting_clients",
        "legendFormat": "{{alias}}/{{conduit}}"
      }]
    },

    {
      "type": "timeseries",
      "title": "Uploaded Bytes per Conduit (cumulative)",
      "gridPos": { "x": 0, "y": 11, "w": 12, "h": 7 },
      "fieldConfig": {
        "defaults": {
          "unit": "bytes"
        }
      },
      "targets": [{
        "expr": "conduit_bytes_uploaded",
        "legendFormat": "{{alias}}/{{conduit}}"
      }]
    },
    {
      "type": "timeseries",
      "title": "Downloaded Bytes per Conduit (cumulative)",
      "gridPos": { "x": 12, "y": 11, "w": 12, "h": 7 },
      "fieldConfig": {
        "defaults": {
          "unit": "bytes"
        }
      },
      "targets": [{
        "expr": "conduit_bytes_downloaded",
        "legendFormat": "{{alias}}/{{conduit}}"
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
fi

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

EOF

cat >> docker-compose.yml <<EOF
  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    user: "0:0"
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml
      - $TARGETS_FILE:$TARGETS_FILE_CONTAINER
      - ./prometheus-data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
EOF

cat >> docker-compose.yml <<EOF

  client-web:
    image: nginx:alpine
    container_name: client-web
    user: "0:0"
    restart: unless-stopped
    ports:
      - "$WEB_PORT:80"
    volumes:
      - $WEB_DIR:/usr/share/nginx/html:ro
EOF

if [ "$ENABLE_GRAFANA" -eq 1 ]; then
cat >> docker-compose.yml <<EOF

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    user: "0:0"
    restart: unless-stopped
    ports:
      - "$GRAFANA_PORT:3000"
    environment:
      - GF_USERS_DEFAULT_THEME=dark
      - GF_SECURITY_ALLOW_EMBEDDING=true
      - GF_LOG_LEVEL=warn
    volumes:
      - ./grafana-data:/var/lib/grafana
      - ./grafana-provisioning:/etc/grafana/provisioning
EOF
fi

########################################
# RUN
########################################
echo ""
info "Starting stack..."
if [ -f prometheus-data/lock ]; then
  warn "Prometheus lock file detected; removing it to avoid startup loops."
  rm -f prometheus-data/lock
fi
if [ "${UPGRADE:-0}" -eq 1 ]; then
  info "Pulling latest images..."
  compose pull
fi
if [ "${MODE:-1}" = "2" ]; then
  compose up -d --remove-orphans
else
  compose up -d
fi
if [ "$ENABLE_GRAFANA" -eq 1 ]; then
  ok "DONE → Grafana http://$HUB_IP:$GRAFANA_PORT"
else
  ok "DONE → Prometheus is running"
fi
ok "DONE → Client installer http://$HUB_IP:$WEB_PORT/install-client.sh"
info "Run this on a client (copy/paste):"
printf '  curl -fsSL http://%s:%s/install-client.sh | bash\n' "$HUB_IP" "$WEB_PORT"
ok "DONE → Stack version $STACK_VERSION"
