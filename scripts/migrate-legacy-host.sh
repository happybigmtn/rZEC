#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SOURCE_ROOT="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
INSTALL_ROOT="${RZEC_INSTALL_ROOT:-/opt/rzec}"
LEGACY_CHAIN_ROOT="${RZEC_LEGACY_CHAIN_ROOT:-/opt/zend/chain}"
LEGACY_MINER_ROOT="${RZEC_LEGACY_MINER_ROOT:-/opt/zend}"
MINE_ADDRESS="${RZEC_MINER_ADDRESS:-}"
EXTERNAL_ADDR="${RZEC_EXTERNAL_ADDR:-}"
THREADS="${RZEC_MINER_THREADS:-}"

usage() {
  cat <<'EOF'
Promote an existing legacy Zend rZEC host onto the public /opt/rzec runtime.

Usage:
  sudo ./scripts/migrate-legacy-host.sh [--source-root PATH] [--install-root PATH]
    [--legacy-chain-root PATH] [--legacy-miner-root PATH]
    [--address TM_ADDRESS] [--external-addr HOST:18233] [--threads N]

If --address or --external-addr are omitted, the script infers them from the
legacy zebrad.toml when possible.
EOF
}

info() { printf '[INFO] %s\n' "$1"; }
error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

wait_for_doctor() {
  local description="$1"
  shift
  local deadline=$((SECONDS + 180))

  until "$INSTALL_ROOT/scripts/doctor.sh" --root "$INSTALL_ROOT" "$@"; do
    if [[ "$SECONDS" -ge "$deadline" ]]; then
      error "Timed out waiting for $description to become healthy"
    fi
    info "Waiting for $description to stabilize"
    sleep 5
  done
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source-root)
      SOURCE_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --install-root)
      INSTALL_ROOT="$2"
      shift 2
      ;;
    --legacy-chain-root)
      LEGACY_CHAIN_ROOT="$2"
      shift 2
      ;;
    --legacy-miner-root)
      LEGACY_MINER_ROOT="$2"
      shift 2
      ;;
    --address)
      MINE_ADDRESS="$2"
      shift 2
      ;;
    --external-addr)
      EXTERNAL_ADDR="$2"
      shift 2
      ;;
    --threads)
      THREADS="$2"
      shift 2
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
[[ -f "$SOURCE_ROOT/scripts/install-public-node.sh" ]] || error "Missing public runtime scripts under $SOURCE_ROOT"
[[ -f "$LEGACY_CHAIN_ROOT/runtime/zebrad.toml" ]] || error "Missing legacy zebrad.toml under $LEGACY_CHAIN_ROOT"

read -r INFERRED_ADDRESS INFERRED_EXTERNAL_ADDR < <(
  python3 - "$LEGACY_CHAIN_ROOT/runtime/zebrad.toml" <<'PY'
import re
import sys
from pathlib import Path

text = Path(sys.argv[1]).read_text(encoding="utf-8")
address = ""
external = ""
address_match = re.search(r'^\s*miner_address\s*=\s*"([^"]+)"', text, re.MULTILINE)
external_match = re.search(r'^\s*external_addr\s*=\s*"([^"]+)"', text, re.MULTILINE)
if address_match:
    address = address_match.group(1)
if external_match:
    external = external_match.group(1)
print(address, external)
PY
)

if [[ -z "$MINE_ADDRESS" ]]; then
  MINE_ADDRESS="$INFERRED_ADDRESS"
fi
if [[ -z "$EXTERNAL_ADDR" ]]; then
  EXTERNAL_ADDR="$INFERRED_EXTERNAL_ADDR"
fi
if [[ -z "$THREADS" ]]; then
  THREADS="$(
    python3 - <<'PY'
import re
import subprocess

proc = subprocess.run(
    ["pgrep", "-af", "nheqminer"],
    capture_output=True,
    text=True,
    check=False,
)
match = re.search(r"(?:^|\s)-t\s+(\d+)(?:\s|$)", proc.stdout)
print(match.group(1) if match else "")
PY
  )"
fi
if [[ -z "$THREADS" ]]; then
  THREADS="$(nproc 2>/dev/null || echo 1)"
fi

[[ -n "$MINE_ADDRESS" ]] || error "Unable to infer miner address; pass --address"
[[ -n "$EXTERNAL_ADDR" ]] || error "Unable to infer external address; pass --external-addr"

apt-get update
apt-get install -y rsync

info "Installing public runtime assets into $INSTALL_ROOT"
node_args=(--miner-address "$MINE_ADDRESS" --external-addr "$EXTERNAL_ADDR")
bash "$SOURCE_ROOT/scripts/install-public-node.sh" "${node_args[@]}"

info "Installing public miner assets into $INSTALL_ROOT"
miner_args=(--address "$MINE_ADDRESS" --threads "$THREADS")
bash "$SOURCE_ROOT/scripts/install-public-miner.sh" "${miner_args[@]}"

info "Stopping legacy miner processes"
pkill -f "$LEGACY_MINER_ROOT/mining/nheqminer/build/nheqminer" >/dev/null 2>&1 || true
pkill -f "$LEGACY_MINER_ROOT/mining/s-nomp/init.js" >/dev/null 2>&1 || true
fuser -k 1234/tcp >/dev/null 2>&1 || true
fuser -k 17117/tcp >/dev/null 2>&1 || true
fuser -k 8080/tcp >/dev/null 2>&1 || true

info "Stopping legacy chain containers"
if [[ -f "$LEGACY_CHAIN_ROOT/docker-compose.yml" ]]; then
  (
    cd "$LEGACY_CHAIN_ROOT"
    docker compose down
  )
fi

info "Seeding public runtime state from legacy cache"
install -d -m 0755 \
  "$INSTALL_ROOT/runtime/zebra-cache" \
  "$INSTALL_ROOT/runtime/lightwalletd/db"
rsync -a --delete "$LEGACY_CHAIN_ROOT/runtime/zebra-cache/" "$INSTALL_ROOT/runtime/zebra-cache/"
rm -f "$INSTALL_ROOT/runtime/zebra-cache/.cookie"
if [[ -d "$LEGACY_CHAIN_ROOT/runtime/lightwalletd/db" ]]; then
  rsync -a --delete "$LEGACY_CHAIN_ROOT/runtime/lightwalletd/db/" "$INSTALL_ROOT/runtime/lightwalletd/db/"
fi
if [[ -f "$LEGACY_CHAIN_ROOT/runtime/last-submitblock.json" ]]; then
  cp "$LEGACY_CHAIN_ROOT/runtime/last-submitblock.json" "$INSTALL_ROOT/runtime/last-submitblock.json"
fi

info "Starting public runtime service"
systemctl enable --now rzec-runtime.service
systemctl is-active --quiet rzec-runtime.service || error "rzec-runtime.service did not stay active"
wait_for_doctor "public runtime"

info "Starting public miner service"
systemctl enable --now rzec-miner.service
systemctl is-active --quiet rzec-miner.service || error "rzec-miner.service did not stay active"
wait_for_doctor "public miner" --expect-miner

info "Legacy host promoted onto $INSTALL_ROOT"
