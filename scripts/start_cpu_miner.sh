#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ASSET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="${RZEC_CPU_MINER_ROOT:-$ASSET_ROOT}"
POOL="${RZEC_STRATUM_ENDPOINT:-127.0.0.1:1234}"
ADDRESS="${RZEC_MINER_ADDRESS:-}"
THREADS="${RZEC_MINER_THREADS:-}"
THREAD_PERCENT="${RZEC_MINER_CPU_PERCENT:-75}"
WORKER="${RZEC_MINER_WORKER:-$(hostname -s 2>/dev/null || echo cpu0)}"
LOG_FILE="${RZEC_CPU_MINER_LOG:-}"
BACKGROUND="${RZEC_MINER_BACKGROUND:-0}"
AUTO_INSTALL="${AUTO_INSTALL:-1}"

usage() {
  cat <<'EOF'
Start the pinned rZEC CPU miner (`nheqminer`) against a stratum endpoint.

Usage:
  ./scripts/start_cpu_miner.sh --address TM_ADDRESS [--pool HOST:PORT] [--threads N]
  ./scripts/start_cpu_miner.sh --address TM_ADDRESS [--worker NAME] [--background]
EOF
}

error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

cpu_count() {
  nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 1
}

default_threads() {
  local cores percent threads
  cores="$(cpu_count)"
  percent="${THREAD_PERCENT:-75}"
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
    --root)
      [[ $# -ge 2 ]] || error "--root requires a value"
      ROOT_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --pool)
      [[ $# -ge 2 ]] || error "--pool requires a value"
      POOL="$2"
      shift 2
      ;;
    --address)
      [[ $# -ge 2 ]] || error "--address requires a value"
      ADDRESS="$2"
      shift 2
      ;;
    --threads)
      [[ $# -ge 2 ]] || error "--threads requires a value"
      THREADS="$2"
      shift 2
      ;;
    --worker)
      [[ $# -ge 2 ]] || error "--worker requires a value"
      WORKER="$2"
      shift 2
      ;;
    --log-file)
      [[ $# -ge 2 ]] || error "--log-file requires a value"
      LOG_FILE="$2"
      shift 2
      ;;
    --background)
      BACKGROUND=1
      shift
      ;;
    --foreground)
      BACKGROUND=0
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

[[ -n "$ADDRESS" ]] || error "A transparent rZEC address is required (--address TM_ADDRESS)"

MINER_BIN="$ROOT_DIR/mining/nheqminer/build/nheqminer"
if [[ ! -x "$MINER_BIN" ]]; then
  if [[ "$AUTO_INSTALL" == "1" ]]; then
    "$ASSET_ROOT/scripts/ensure_cpu_miner.sh" --root "$ROOT_DIR"
  fi
fi
[[ -x "$MINER_BIN" ]] || error "nheqminer is not built under $ROOT_DIR/mining/nheqminer/build"

if [[ -z "$THREADS" ]]; then
  THREADS="$(default_threads)"
fi

if [[ -z "$LOG_FILE" ]]; then
  mkdir -p "$ROOT_DIR/runtime/logs"
  LOG_FILE="$ROOT_DIR/runtime/logs/rzec-nheqminer.log"
fi

USERNAME="$ADDRESS"
if [[ -n "$WORKER" && "$ADDRESS" != *.* ]]; then
  USERNAME="${ADDRESS}.${WORKER}"
fi

MINER_ARGS=("$MINER_BIN" -l "$POOL" -u "$USERNAME" -t "$THREADS")

if [[ "$BACKGROUND" == "1" ]]; then
  nohup "${MINER_ARGS[@]}" >"$LOG_FILE" 2>&1 &
  printf '[INFO] nheqminer started in background (pid %s, log %s)\n' "$!" "$LOG_FILE"
  exit 0
fi

exec "${MINER_ARGS[@]}"
