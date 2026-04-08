#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ASSET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL_ROOT="${RZEC_INSTALL_ROOT:-/opt/rzec}"
CONFIG_DIR="${RZEC_CONFIG_DIR:-/etc/rzec}"
BIN_DIR="${RZEC_BIN_DIR:-/usr/local/bin}"
SERVICE_DIR="${RZEC_SYSTEMD_DIR:-/etc/systemd/system}"
SERVICE_NAME="${RZEC_RUNTIME_SERVICE_NAME:-rzec-runtime.service}"
ENABLE_NOW=0
MINER_ADDRESS=""
EXTERNAL_ADDR="${RZEC_EXTERNAL_ADDR:-}"

usage() {
  cat <<'EOF'
Install rZEC as a long-running public Zebra + lightwalletd node on this host.

Usage:
  sudo ./scripts/install-public-node.sh --miner-address TM_ADDRESS [--external-addr HOST:18233] [--enable-now]
EOF
}

info() { printf '[INFO] %s\n' "$1"; }
error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --miner-address)
      [[ $# -ge 2 ]] || error "--miner-address requires a value"
      MINER_ADDRESS="$2"
      shift 2
      ;;
    --external-addr)
      [[ $# -ge 2 ]] || error "--external-addr requires a value"
      EXTERNAL_ADDR="$2"
      shift 2
      ;;
    --enable-now)
      ENABLE_NOW=1
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
[[ -n "$MINER_ADDRESS" ]] || error "--miner-address is required"

apt-get update
apt-get install -y curl docker.io python3 wget
if ! docker compose version >/dev/null 2>&1; then
  if apt-cache show docker-compose-v2 >/dev/null 2>&1; then
    apt-get install -y docker-compose-v2
  elif apt-cache show docker-compose-plugin >/dev/null 2>&1; then
    apt-get install -y docker-compose-plugin
  else
    error "Docker Compose v2 is not available on this host"
  fi
fi
systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || service docker start

install -d -m 0755 "$INSTALL_ROOT" "$CONFIG_DIR" "$BIN_DIR" "$SERVICE_DIR"
rm -rf "$INSTALL_ROOT/scripts" "$INSTALL_ROOT/profiles" "$INSTALL_ROOT/references" \
  "$INSTALL_ROOT/templates" "$INSTALL_ROOT/contrib" "$INSTALL_ROOT/docs"
cp "$ASSET_ROOT/install.sh" "$INSTALL_ROOT/install.sh"
cp "$ASSET_ROOT/docker-compose.yml" "$INSTALL_ROOT/docker-compose.yml"
cp -R "$ASSET_ROOT/scripts" "$INSTALL_ROOT/scripts"
cp -R "$ASSET_ROOT/profiles" "$INSTALL_ROOT/profiles"
cp -R "$ASSET_ROOT/references" "$INSTALL_ROOT/references"
cp -R "$ASSET_ROOT/templates" "$INSTALL_ROOT/templates"
cp -R "$ASSET_ROOT/contrib" "$INSTALL_ROOT/contrib"
cp -R "$ASSET_ROOT/docs" "$INSTALL_ROOT/docs"

render_args=(--output-root "$INSTALL_ROOT" --miner-address "$MINER_ADDRESS")
if [[ -n "$EXTERNAL_ADDR" ]]; then
  render_args+=(--external-addr "$EXTERNAL_ADDR")
fi
python3 "$INSTALL_ROOT/scripts/render-runtime.py" "${render_args[@]}"

if [[ ! -f "$CONFIG_DIR/rzec.env" ]]; then
  cp "$INSTALL_ROOT/contrib/init/rzec.env.example" "$CONFIG_DIR/rzec.env"
fi

cat > "$SERVICE_DIR/$SERVICE_NAME" <<EOF
[Unit]
Description=rZEC public runtime
After=docker.service network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$INSTALL_ROOT
ExecStart=$INSTALL_ROOT/scripts/start-runtime.sh --root $INSTALL_ROOT
ExecStop=/usr/bin/docker compose -f $INSTALL_ROOT/docker-compose.yml down

[Install]
WantedBy=multi-user.target
EOF

chmod 755 "$INSTALL_ROOT/scripts/"*.sh
chmod 755 "$INSTALL_ROOT/scripts/"*.py
chmod 755 "$INSTALL_ROOT/install.sh"
chmod 755 "$INSTALL_ROOT/scripts/render-runtime.py"
ln -sf "$INSTALL_ROOT/scripts/doctor.sh" "$BIN_DIR/rzec-doctor"
ln -sf "$INSTALL_ROOT/scripts/migrate-legacy-host.sh" "$BIN_DIR/rzec-migrate-legacy-host"
ln -sf "$INSTALL_ROOT/scripts/ensure_cpu_miner.sh" "$BIN_DIR/rzec-ensure-cpu-miner"
ln -sf "$INSTALL_ROOT/scripts/start_cpu_miner.sh" "$BIN_DIR/rzec-start-cpu-miner"
ln -sf "$INSTALL_ROOT/scripts/start-runtime.sh" "$BIN_DIR/rzec-start-runtime"
ln -sf "$INSTALL_ROOT/scripts/public-apply.sh" "$BIN_DIR/rzec-public-apply"
ln -sf "$INSTALL_ROOT/scripts/install-public-node.sh" "$BIN_DIR/rzec-install-public-node"
ln -sf "$INSTALL_ROOT/scripts/install-public-miner.sh" "$BIN_DIR/rzec-install-public-miner"

systemctl daemon-reload
if [[ "$ENABLE_NOW" -eq 1 ]]; then
  systemctl enable --now "$SERVICE_NAME"
fi

info "Installed rZEC public-node assets at $INSTALL_ROOT"
