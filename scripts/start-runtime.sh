#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
COOKIE_FILE="$ROOT_DIR/runtime/zebra-cache/.cookie"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="$(cd "$2" && pwd)"
      COOKIE_FILE="$ROOT_DIR/runtime/zebra-cache/.cookie"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"
docker compose up -d zebra

deadline=$((SECONDS + 60))
while [[ ! -f "$COOKIE_FILE" ]]; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "Error: timed out waiting for Zebra cookie at $COOKIE_FILE" >&2
    exit 1
  fi
  sleep 1
done

"$ROOT_DIR/scripts/prepare-lightwalletd-conf.sh"
docker compose up -d lightwalletd
