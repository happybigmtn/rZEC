#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
COOKIE_FILE="${RZEC_COOKIE_FILE:-$ROOT_DIR/runtime/zebra-cache/.cookie}"
TARGET_FILE="${RZEC_LIGHTWALLETD_CONF:-$ROOT_DIR/runtime/lightwalletd/zcash.conf}"
RPC_PORT="${RZEC_ZEBRA_RPC_PORT:-18232}"

if [[ ! -f "$COOKIE_FILE" ]]; then
  echo "Error: Zebra cookie not found at $COOKIE_FILE" >&2
  exit 1
fi

if [[ -d "$TARGET_FILE" ]]; then
  rm -rf "$TARGET_FILE"
fi

mkdir -p "$(dirname "$TARGET_FILE")"
cookie_payload="$(< "$COOKIE_FILE")"
rpc_user="${cookie_payload%%:*}"
rpc_password="${cookie_payload#*:}"
if [[ -z "$rpc_user" || -z "$rpc_password" || "$rpc_user" == "$cookie_payload" ]]; then
  echo "Error: Invalid Zebra cookie payload at $COOKIE_FILE" >&2
  exit 1
fi
cat > "$TARGET_FILE" <<EOF
rpcconnect=127.0.0.1
rpcport=$RPC_PORT
rpcuser=$rpc_user
rpcpassword=$rpc_password
testnet=1
EOF
