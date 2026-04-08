#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
MINE_ADDRESS="${RZEC_MINER_ADDRESS:-}"
THREADS="${RZEC_MINER_THREADS:-}"
LOG_DIR="${RZEC_LOG_DIR:-}"
NODE_VERSION="$(
  python3 - "$ROOT_DIR/references/UPSTREAM.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
print(payload["toolchain"]["nodejs"])
PY
)"
SNOMP_PID=""
MINER_PID=""

usage() {
  cat <<'EOF'
Start the public rZEC stratum plus CPU-miner stack on this host.

Usage:
  ./scripts/start-public-miner.sh --address TM_ADDRESS [--threads N] [--root PATH]
EOF
}

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

cleanup() {
  if [[ -n "$MINER_PID" ]]; then
    kill "$MINER_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$SNOMP_PID" ]]; then
    kill "$SNOMP_PID" >/dev/null 2>&1 || true
  fi
}

trap cleanup EXIT INT TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --address)
      [[ $# -ge 2 ]] || { echo "--address requires a value" >&2; exit 1; }
      MINE_ADDRESS="$2"
      shift 2
      ;;
    --threads)
      [[ $# -ge 2 ]] || { echo "--threads requires a value" >&2; exit 1; }
      THREADS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

[[ -n "$MINE_ADDRESS" ]] || { echo "A transparent rZEC address is required" >&2; exit 1; }
if [[ -z "$THREADS" ]]; then
  THREADS="$(default_threads)"
fi
[[ -x "$ROOT_DIR/mining/nheqminer/build/nheqminer" ]] || {
  echo "nheqminer is not built under $ROOT_DIR/mining/nheqminer/build. Run ./scripts/ensure_cpu_miner.sh --root $ROOT_DIR first." >&2
  exit 1
}
[[ -f "$ROOT_DIR/runtime/zebra-cache/.cookie" ]] || {
  echo "Zebra cookie not found. Start the node runtime first." >&2
  exit 1
}

systemctl start redis-server >/dev/null 2>&1 || service redis-server start
export HOME="${HOME:-/root}"
export USER="${USER:-root}"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
[[ -s "$NVM_DIR/nvm.sh" ]] || {
  echo "nvm is not installed under $NVM_DIR" >&2
  exit 1
}
. "$NVM_DIR/nvm.sh"
nvm use "$NODE_VERSION" >/dev/null

if [[ -z "$LOG_DIR" ]]; then
  LOG_DIR="$ROOT_DIR/runtime/logs"
fi
mkdir -p "$LOG_DIR"

python3 - "$ROOT_DIR" "$MINE_ADDRESS" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
address = sys.argv[2]
template_path = root / "templates" / "pool.config.template.json"
target_path = root / "mining" / "s-nomp" / "pool_configs" / "rzec.json"
stock_path = root / "mining" / "s-nomp" / "pool_configs" / "zcash_testnet.json"
cookie_path = root / "runtime" / "zebra-cache" / ".cookie"
payload = json.loads(template_path.read_text(encoding="utf-8"))
payload["address"] = address
payload["invalidAddress"] = address
user, password = cookie_path.read_text(encoding="utf-8").strip().split(":", 1)
for daemon in payload.get("daemons", []):
    daemon["user"] = user
    daemon["password"] = password
payment = payload.get("paymentProcessing", {}).get("daemon")
if payment is not None:
    payment["user"] = user
    payment["password"] = password
target_path.parent.mkdir(parents=True, exist_ok=True)
target_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
if stock_path.exists():
    stock = json.loads(stock_path.read_text(encoding="utf-8"))
    stock["enabled"] = False
    stock_path.write_text(json.dumps(stock, indent=2) + "\n", encoding="utf-8")
PY

pkill -f "$ROOT_DIR/mining/nheqminer/build/nheqminer" >/dev/null 2>&1 || true
fuser -k 1234/tcp >/dev/null 2>&1 || true
fuser -k 17117/tcp >/dev/null 2>&1 || true
fuser -k 8080/tcp >/dev/null 2>&1 || true
sleep 1

cd "$ROOT_DIR/mining/s-nomp"
npm start >"$LOG_DIR/rzec-snomp.log" 2>&1 &
SNOMP_PID="$!"

deadline=$((SECONDS + 30))
while ! ss -ltn | grep -q ':1234 '; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "Timed out waiting for stratum on :1234" >&2
    exit 1
  fi
  sleep 1
done

"$ROOT_DIR/mining/nheqminer/build/nheqminer" \
  -l 127.0.0.1:1234 \
  -u "${MINE_ADDRESS}.$(hostname -s)" \
  -t "$THREADS" >"$LOG_DIR/rzec-nheqminer.log" 2>&1 &
MINER_PID="$!"

wait -n "$SNOMP_PID" "$MINER_PID"
