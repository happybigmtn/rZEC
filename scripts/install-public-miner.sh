#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="${RZEC_INSTALL_ROOT:-/opt/rzec}"
CONFIG_DIR="${RZEC_CONFIG_DIR:-/etc/rzec}"
SERVICE_DIR="${RZEC_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_NAME="${RZEC_MINER_SERVICE_NAME:-rzec-miner.service}"
ENABLE_NOW=0
REMOVE_SERVICE=0
MINE_ADDRESS="${RZEC_MINER_ADDRESS:-}"
THREADS="${RZEC_MINER_THREADS:-}"
eval "$(
  python3 - "$ROOT_DIR/references/UPSTREAM.json" <<'PY'
import json
import shlex
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
values = {
    "NODE_VERSION": payload["toolchain"]["nodejs"],
    "NVM_VERSION": payload["toolchain"]["nvm"],
    "SNOMP_REPO": payload["miner_stack"]["snomp"]["repo"],
    "SNOMP_BRANCH": payload["miner_stack"]["snomp"]["branch"],
    "SNOMP_COMMIT": payload["miner_stack"]["snomp"]["commit"],
    "NHEQMINER_REPO": payload["miner_stack"]["nheqminer"]["repo"],
    "NHEQMINER_BRANCH": payload["miner_stack"]["nheqminer"]["branch"],
    "NHEQMINER_COMMIT": payload["miner_stack"]["nheqminer"]["commit"],
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
)"

usage() {
  cat <<'EOF'
Install or remove a persistent rZEC CPU-miner service.

Usage:
  sudo ./scripts/install-public-miner.sh --address TM_ADDRESS [--threads N] [--enable-now]
  sudo ./scripts/install-public-miner.sh --remove
EOF
}

info() { printf '[INFO] %s\n' "$1"; }
error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

cpu_count() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 1
}

default_threads() {
  local cores percent threads
  cores="$(cpu_count)"
  percent="${RZEC_MINER_CPU_PERCENT:-75}"
  if (( percent < 1 )); then
    percent=1
  fi
  if (( percent > 100 )); then
    percent=100
  fi
  threads=$(( cores * percent / 100 ))
  if (( threads < 1 )); then
    threads=1
  fi
  printf '%s\n' "$threads"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --address)
      [[ $# -ge 2 ]] || error "--address requires a value"
      MINE_ADDRESS="$2"
      shift 2
      ;;
    --threads)
      [[ $# -ge 2 ]] || error "--threads requires a value"
      THREADS="$2"
      shift 2
      ;;
    --enable-now)
      ENABLE_NOW=1
      shift
      ;;
    --remove)
      REMOVE_SERVICE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      error "Unknown argument: $1"
      ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || error "Run this script as root"

if [[ "$REMOVE_SERVICE" -eq 1 ]]; then
  rm -f "$SERVICE_DIR/$SERVICE_NAME" "$CONFIG_DIR/rzec-miner.env"
  systemctl daemon-reload
  if [[ "$ENABLE_NOW" -eq 1 ]]; then
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  fi
  info "Removed $SERVICE_NAME"
  exit 0
fi

[[ -d "$INSTALL_ROOT" ]] || error "Install the public node first at $INSTALL_ROOT"
[[ -n "$MINE_ADDRESS" ]] || error "--address is required"
if [[ -z "$THREADS" ]]; then
  THREADS="$(default_threads)"
fi

apt-get update
apt-get install -y build-essential cmake curl git libicu-dev libsodium-dev redis-server python3
systemctl enable redis-server >/dev/null 2>&1 || true
systemctl start redis-server >/dev/null 2>&1 || service redis-server start

export NVM_DIR="${NVM_DIR:-/root/.nvm}"
if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  curl -4 -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" | bash
fi
. "$NVM_DIR/nvm.sh"
if ! nvm ls "$NODE_VERSION" >/dev/null 2>&1; then
  nvm install "$NODE_VERSION"
fi
nvm use "$NODE_VERSION" >/dev/null

mkdir -p "$INSTALL_ROOT/mining"
if [[ ! -d "$INSTALL_ROOT/mining/s-nomp/.git" ]]; then
  git clone "$SNOMP_REPO" "$INSTALL_ROOT/mining/s-nomp"
fi

git -C "$INSTALL_ROOT/mining/s-nomp" fetch origin >/dev/null 2>&1 || true
git -C "$INSTALL_ROOT/mining/s-nomp" checkout "$SNOMP_COMMIT"
rm -rf "$INSTALL_ROOT/mining/s-nomp/node_modules"
cp "$ROOT_DIR/templates/snomp.config.json" "$INSTALL_ROOT/mining/s-nomp/config.json"
(
  cd "$INSTALL_ROOT/mining/s-nomp"
  npm ci
)
python3 "$ROOT_DIR/scripts/patch-mining-stack.py" --root "$INSTALL_ROOT"

"$ROOT_DIR/scripts/ensure_cpu_miner.sh" --root "$INSTALL_ROOT"

install -d -m 0755 "$CONFIG_DIR" "$SERVICE_DIR"
cat > "$CONFIG_DIR/rzec-miner.env" <<EOF
RZEC_MINER_ADDRESS=$MINE_ADDRESS
RZEC_MINER_THREADS=$THREADS
EOF
chmod 640 "$CONFIG_DIR/rzec-miner.env"

cat > "$SERVICE_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=rZEC CPU miner
After=rzec-runtime.service network-online.target redis-server.service
Requires=rzec-runtime.service

[Service]
Type=simple
WorkingDirectory=$INSTALL_ROOT
Environment=HOME=/root
Environment=USER=root
Environment=NVM_DIR=/root/.nvm
EnvironmentFile=$CONFIG_DIR/rzec-miner.env
ExecStart=$INSTALL_ROOT/scripts/start-public-miner.sh --root $INSTALL_ROOT --address \${RZEC_MINER_ADDRESS} --threads \${RZEC_MINER_THREADS}
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

chmod 755 "$INSTALL_ROOT/scripts/"*.sh
chmod 755 "$INSTALL_ROOT/scripts/"*.py
systemctl daemon-reload
if [[ "$ENABLE_NOW" -eq 1 ]]; then
  systemctl enable --now "$SERVICE_NAME"
fi

info "Installed $SERVICE_NAME"
info "Next: verify with 'rzec-doctor --root $INSTALL_ROOT --expect-miner' and inspect 'journalctl -u $SERVICE_NAME -n 100 --no-pager' if mining does not start"
