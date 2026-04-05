#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINER_ADDRESS=""
THREADS=""
ENABLE_NODE=0
ENABLE_MINER=0
ENABLE_NOW=0

usage() {
  cat <<'EOF'
Install the public rZEC node and optional miner on this host.

Usage:
  sudo ./install.sh --miner-address TM_ADDRESS [--threads N] [--enable-node] [--enable-miner] [--enable-now]

If neither --enable-node nor --enable-miner is provided, both are enabled.
EOF
}

error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --miner-address)
      [[ $# -ge 2 ]] || error "--miner-address requires a value"
      MINER_ADDRESS="$2"
      shift 2
      ;;
    --threads)
      [[ $# -ge 2 ]] || error "--threads requires a value"
      THREADS="$2"
      shift 2
      ;;
    --enable-node)
      ENABLE_NODE=1
      shift
      ;;
    --enable-miner)
      ENABLE_MINER=1
      shift
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

[[ -n "$MINER_ADDRESS" ]] || error "--miner-address is required"

if [[ "$ENABLE_NODE" -eq 0 && "$ENABLE_MINER" -eq 0 ]]; then
  ENABLE_NODE=1
  ENABLE_MINER=1
fi

if [[ "$ENABLE_NODE" -eq 1 ]]; then
  node_args=(--miner-address "$MINER_ADDRESS")
  if [[ "$ENABLE_NOW" -eq 1 ]]; then
    node_args+=(--enable-now)
  fi
  "$ROOT_DIR/scripts/install-public-node.sh" "${node_args[@]}"
fi

if [[ "$ENABLE_MINER" -eq 1 ]]; then
  miner_args=(--address "$MINER_ADDRESS")
  if [[ -n "$THREADS" ]]; then
    miner_args+=(--threads "$THREADS")
  fi
  if [[ "$ENABLE_NOW" -eq 1 ]]; then
    miner_args+=(--enable-now)
  fi
  "$ROOT_DIR/scripts/install-public-miner.sh" "${miner_args[@]}"
fi
