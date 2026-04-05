#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
COOKIE_FILE="$ROOT_DIR/runtime/zebra-cache/.cookie"
NETWORK_FILE="$ROOT_DIR/references/NETWORK.json"
HEALTHY=1

usage() {
  cat <<'EOF'
Verify that this host is pointed at the live public rZEC network.

Usage:
  ./scripts/doctor.sh [--root PATH]
  rzec-doctor [--root PATH]
EOF
}

info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1"; HEALTHY=0; }
error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="$(cd "$2" && pwd)"
      COOKIE_FILE="$ROOT_DIR/runtime/zebra-cache/.cookie"
      NETWORK_FILE="$ROOT_DIR/references/NETWORK.json"
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

[[ -f "$NETWORK_FILE" ]] || error "Missing $NETWORK_FILE"
[[ -f "$COOKIE_FILE" ]] || error "Missing Zebra cookie at $COOKIE_FILE"

python3 - "$NETWORK_FILE" "$COOKIE_FILE" <<'PY'
import base64
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

network = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
cookie = Path(sys.argv[2]).read_text(encoding="utf-8").strip()
user, password = cookie.split(":", 1)
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

def rpc(method, params=None):
    payload = json.dumps({
        "jsonrpc": "1.0",
        "id": "rzec-doctor",
        "method": method,
        "params": params or [],
    }).encode("utf-8")
    request = urllib.request.Request(
        f"http://127.0.0.1:{network['ports']['zebra_rpc']}",
        data=payload,
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        body = json.loads(response.read() or b"{}")
    return body.get("result")

info = rpc("getinfo")
genesis_hash = rpc("getblockhash", [0])
count = rpc("getconnectioncount")
health_request = urllib.request.Request(
    f"http://127.0.0.1:{network['ports']['lightwalletd_http']}/health",
    method="GET",
)
try:
    with urllib.request.urlopen(health_request, timeout=5) as response:
        health_ok = response.status == 200
except urllib.error.URLError:
    health_ok = False

print(f'[INFO] Chain family: {info.get("chain", "unknown")}')
print(f'[INFO] Blocks: {info.get("blocks", "unknown")}')
print(f'[INFO] Genesis hash: {genesis_hash}')
print(f'[INFO] Peers: {count}')
print(f'[INFO] lightwalletd health: {"ok" if health_ok else "unreachable"}')
if genesis_hash != network["genesis_hash"]:
    print(f'[WARN] Unexpected genesis hash: {genesis_hash}')
    sys.exit(1)
if not isinstance(count, int) or count < 1:
    print('[WARN] No peer connections yet')
    sys.exit(1)
if not health_ok:
    print('[WARN] lightwalletd health endpoint is not reachable')
    sys.exit(1)
PY
