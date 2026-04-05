#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
MINE_ADDRESS="${RZEC_MINER_ADDRESS:-}"
THREADS="${RZEC_MINER_THREADS:-$(nproc 2>/dev/null || echo 1)}"
NODE_VERSION="10.24.1"
SNOMP_PID=""
MINER_PID=""

usage() {
  cat <<'EOF'
Start the public rZEC miner stack on this host.

Usage:
  ./scripts/start-public-miner.sh --address TM_ADDRESS [--threads N] [--root PATH]
EOF
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
[[ -x "$ROOT_DIR/mining/nheqminer/build/nheqminer" ]] || {
  echo "nheqminer is not built under $ROOT_DIR/mining/nheqminer/build" >&2
  exit 1
}
[[ -f "$ROOT_DIR/runtime/zebra-cache/.cookie" ]] || {
  echo "Zebra cookie not found. Start the node runtime first." >&2
  exit 1
}

systemctl start redis-server >/dev/null 2>&1 || service redis-server start
export NVM_DIR="${NVM_DIR:-/root/.nvm}"
. "$NVM_DIR/nvm.sh"
nvm use "$NODE_VERSION" >/dev/null

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

python3 - "$ROOT_DIR/mining/s-nomp/node_modules/stratum-pool/lib/daemon.js" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
legacy_batch = """    function batchCmd(cmdArray, callback, timeout) {

        var requestJson = [];

        for (var i = 0; i < cmdArray.length; i++) {
            requestJson.push({
                method: cmdArray[i][0],
                params: cmdArray[i][1],
                id: Date.now() + Math.floor(Math.random() * 10) + i
            });
        }

        var serializedRequest = JSON.stringify(requestJson);

        performHttpRequest(instances[0], serializedRequest, function (error, result) {
            callback(error, result);
        }, timeout);
    }
"""
patched_batch = """    function batchCmd(cmdArray, callback, timeout) {

        async.mapSeries(cmdArray, function (cmd, eachCallback) {
            var serializedRequest = JSON.stringify({
                jsonrpc: "1.0",
                method: cmd[0],
                params: cmd[1],
                id: Date.now() + Math.floor(Math.random() * 10)
            });

            performHttpRequest(instances[0], serializedRequest, function (error, result) {
                if (result) {
                    eachCallback(null, result);
                    return;
                }
                eachCallback(null, {error: error, result: null});
            }, timeout);
        }, function (_, results) {
            callback(null, results);
        });
    }
"""
updated = text.replace(legacy_batch, patched_batch)
updated = updated.replace("jsonrpc: 1.0", "jsonrpc: \"1.0\"")
if updated != text:
    path.write_text(updated, encoding="utf-8")
PY

python3 - "$ROOT_DIR/mining/s-nomp/node_modules/stratum-pool/lib/blockTemplate.js" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
marker = "    this.rpcData = rpcData;"
assignment = "    this.rpcData.fundingstreams = this.rpcData.fundingstreams || [];"
insert = "\n".join([
    "    this.rpcData = rpcData;",
    assignment,
    "    this.rpcData.certificates = this.rpcData.certificates || [];",
    "    this.rpcData.miner = this.rpcData.miner || 0;",
])
if assignment not in text and marker in text:
    text = text.replace(marker, insert, 1)
header_line = "        header.write(this.merkleRoot, position += 32, 32, 'hex');"
job_param_line = "                this.merkleRoot,"
if header_line in text:
    text = text.replace(
        header_line,
        "        header.write(this.merkleRootReversed, position += 32, 32, 'hex');",
        1,
    )
if job_param_line in text:
    text = text.replace(job_param_line, "                this.merkleRootReversed,", 1)
path.write_text(text, encoding="utf-8")
PY

python3 - "$ROOT_DIR/mining/s-nomp/node_modules/stratum-pool/lib/merkleTree.js" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
legacy = "    hashes = [util.reverseBuffer(new Buffer(generateTxRaw, 'hex')).toString('hex')];"
replacement = "    hashes = [generateTxRaw];"
updated = text.replace(legacy, replacement)
if updated != text:
    path.write_text(updated, encoding="utf-8")
PY

pkill -f "$ROOT_DIR/mining/nheqminer/build/nheqminer" >/dev/null 2>&1 || true
fuser -k 1234/tcp >/dev/null 2>&1 || true
fuser -k 17117/tcp >/dev/null 2>&1 || true
fuser -k 8080/tcp >/dev/null 2>&1 || true
sleep 1

cd "$ROOT_DIR/mining/s-nomp"
npm start >/tmp/rzec-snomp.log 2>&1 &
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
  -t "$THREADS" >/tmp/rzec-nheqminer.log 2>&1 &
MINER_PID="$!"

wait -n "$SNOMP_PID" "$MINER_PID"
