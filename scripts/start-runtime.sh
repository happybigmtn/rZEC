#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
COOKIE_FILE="$ROOT_DIR/runtime/zebra-cache/.cookie"
RPC_PORT="$(
  python3 - "$ROOT_DIR/references/NETWORK.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
print(payload["ports"]["zebra_rpc"])
PY
)"
LIGHTWALLETD_HTTP_PORT="$(
  python3 - "$ROOT_DIR/references/NETWORK.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
print(payload["ports"]["lightwalletd_http"])
PY
)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      ROOT_DIR="$(cd "$2" && pwd)"
      COOKIE_FILE="$ROOT_DIR/runtime/zebra-cache/.cookie"
      RPC_PORT="$(
        python3 - "$ROOT_DIR/references/NETWORK.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
print(payload["ports"]["zebra_rpc"])
PY
)"
      LIGHTWALLETD_HTTP_PORT="$(
        python3 - "$ROOT_DIR/references/NETWORK.json" <<'PY'
import json
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
print(payload["ports"]["lightwalletd_http"])
PY
)"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

cd "$ROOT_DIR"
rm -f "$COOKIE_FILE"
docker compose up -d --force-recreate zebra

deadline=$((SECONDS + 60))
while [[ ! -f "$COOKIE_FILE" ]]; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "Error: timed out waiting for Zebra cookie at $COOKIE_FILE" >&2
    exit 1
  fi
  sleep 1
done

deadline=$((SECONDS + 60))
while ! python3 - "$COOKIE_FILE" "$RPC_PORT" <<'PY'
import base64
import json
import sys
import urllib.error
import urllib.request
from pathlib import Path

cookie = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
rpc_port = sys.argv[2]
user, password = cookie.split(":", 1)
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")
payload = json.dumps(
    {"jsonrpc": "1.0", "id": "rzec-start-runtime", "method": "getblockcount", "params": []}
).encode("utf-8")
request = urllib.request.Request(
    f"http://127.0.0.1:{rpc_port}",
    data=payload,
    headers={
        "Authorization": f"Basic {auth}",
        "Content-Type": "application/json",
    },
    method="POST",
)
with urllib.request.urlopen(request, timeout=5) as response:
    body = json.loads(response.read() or b"{}")
    if body.get("error") is not None:
        raise SystemExit(1)
PY
do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "Error: timed out waiting for Zebra RPC on 127.0.0.1:$RPC_PORT" >&2
    exit 1
  fi
  sleep 1
done

"$ROOT_DIR/scripts/prepare-lightwalletd-conf.sh"
docker compose up -d --force-recreate lightwalletd

deadline=$((SECONDS + 60))
while ! wget -qO- "http://127.0.0.1:${LIGHTWALLETD_HTTP_PORT}/metrics" >/dev/null; do
  if [[ "$SECONDS" -ge "$deadline" ]]; then
    echo "Error: timed out waiting for lightwalletd metrics on 127.0.0.1:${LIGHTWALLETD_HTTP_PORT}" >&2
    exit 1
  fi
  sleep 1
done
