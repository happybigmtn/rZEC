#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT_DIR="$(cd "$(dirname "$SCRIPT_PATH")/.." && pwd)"
OUTPUT_JSON=0
STRICT=0
EXPECT_PUBLIC=0
EXPECT_MINER=0

usage() {
  cat <<'EOF'
Verify that this host is pointed at the live public rZEC network.

Usage:
  ./scripts/doctor.sh [--root PATH] [--json] [--strict] [--expect-public] [--expect-miner]
  rzec-doctor [--root PATH] [--json] [--strict] [--expect-public] [--expect-miner]
EOF
}

error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || error "--root requires a path"
      ROOT_DIR="$(cd "$2" && pwd)"
      shift 2
      ;;
    --json)
      OUTPUT_JSON=1
      shift
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --expect-public)
      EXPECT_PUBLIC=1
      shift
      ;;
    --expect-miner)
      EXPECT_MINER=1
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

python3 - "$ROOT_DIR" "$OUTPUT_JSON" "$STRICT" "$EXPECT_PUBLIC" "$EXPECT_MINER" <<'PY'
import base64
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

root_dir = Path(sys.argv[1]).resolve()
output_json = sys.argv[2] == "1"
strict = sys.argv[3] == "1"
expect_public = sys.argv[4] == "1"
expect_miner = sys.argv[5] == "1"

network_file = root_dir / "references" / "NETWORK.json"
cookie_file = root_dir / "runtime" / "zebra-cache" / ".cookie"
log_dir = root_dir / "runtime" / "logs"

warnings = []


def warn(message: str) -> None:
    warnings.append(message)


def info_lines(payload: dict) -> list[str]:
    lines = [
        f"[INFO] Blocks: {payload['blocks']}",
        f"[INFO] Genesis hash: {payload['genesis_hash']}",
        f"[INFO] Best block: {payload['best_block_hash']}",
        f"[INFO] P2P sessions: {payload['peer_count']}",
        f"[INFO] lightwalletd metrics: {'ok' if payload['services']['lightwalletd_metrics'] else 'unreachable'}",
    ]
    if payload["services"]["stratum_listening"] is not None:
        if payload["services"]["stratum_listening"]:
            lines.append(f"[INFO] Stratum is listening on :{payload['stratum_port']}")
        else:
            lines.append(f"[WARN] Stratum is not listening on :{payload['stratum_port']}")
    if payload["services"]["nheqminer_running"] is not None:
        if payload["services"]["nheqminer_running"]:
            lines.append("[INFO] nheqminer process detected")
        else:
            lines.append("[WARN] nheqminer process not detected")
    if payload["services"]["accepted_share_seen"] is not None:
        if payload["services"]["accepted_share_seen"]:
            lines.append("[INFO] Accepted shares found in recent miner logs")
        else:
            lines.append("[WARN] No accepted shares found in recent miner logs")
    return lines


def count_p2p_sessions(port: int) -> int:
    def parse_proc_net(payload: str) -> int:
        count = 0
        port_hex = f"{port:04X}"
        for raw_line in payload.splitlines()[1:]:
            line = raw_line.strip()
            if not line:
                continue
            columns = line.split()
            if len(columns) < 4:
                continue
            local_address = columns[1]
            remote_address = columns[2]
            state = columns[3]
            local_port = local_address.split(":")[-1].upper()
            remote_port = remote_address.split(":")[-1].upper()
            if state == "01" and (local_port == port_hex or remote_port == port_hex):
                count += 1
        return count

    proc = subprocess.run(
        ["docker", "exec", "rzec-zebra", "sh", "-lc", "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null"],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode == 0 and proc.stdout.strip():
        return parse_proc_net(proc.stdout)

    ss_output = subprocess.run(["ss", "-Htan"], capture_output=True, text=True, check=False).stdout
    return sum(1 for line in ss_output.splitlines() if "ESTAB" in line and f":{port}" in line)


def ss_listening(port: int) -> bool:
    proc = subprocess.run(["ss", "-ltn"], capture_output=True, text=True, check=False)
    return f":{port} " in proc.stdout


payload = {
    "chain_ok": False,
    "rpc_ok": False,
    "public_reachable": False,
    "miner_configured": False,
    "miner_running": False,
    "ready": False,
    "genesis_hash": "",
    "best_block_hash": "",
    "blocks": -1,
    "peer_count": 0,
    "warnings": warnings,
    "services": {
        "zebra_rpc": False,
        "lightwalletd_metrics": False,
        "stratum_listening": None,
        "nheqminer_running": None,
        "accepted_share_seen": None,
    },
}

if not network_file.is_file():
    warn(f"Missing {network_file}")
if not cookie_file.is_file():
    warn(f"Missing Zebra cookie at {cookie_file}")

network = json.loads(network_file.read_text(encoding="utf-8")) if network_file.is_file() else {"ports": {}, "genesis_hash": ""}
stratum_port = int(network.get("ports", {}).get("stratum", 0) or 0)
payload["stratum_port"] = stratum_port

if cookie_file.is_file() and network_file.is_file():
    cookie = cookie_file.read_text(encoding="utf-8").strip()
    if ":" not in cookie:
        warn(f"Invalid Zebra cookie payload at {cookie_file}")
    else:
        user, password = cookie.split(":", 1)
        auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("ascii")

        def rpc(method: str, params: list | None = None):
            request = urllib.request.Request(
                f"http://127.0.0.1:{network['ports']['zebra_rpc']}",
                data=json.dumps(
                    {"jsonrpc": "1.0", "id": "rzec-doctor", "method": method, "params": params or []}
                ).encode("utf-8"),
                headers={
                    "Authorization": f"Basic {auth}",
                    "Content-Type": "application/json",
                },
                method="POST",
            )
            with urllib.request.urlopen(request, timeout=5) as response:
                body = json.loads(response.read() or b"{}")
            return body.get("result")

        try:
            payload["blocks"] = rpc("getblockcount")
            payload["genesis_hash"] = rpc("getblockhash", [0])
            payload["best_block_hash"] = rpc("getbestblockhash")
            payload["rpc_ok"] = True
            payload["services"]["zebra_rpc"] = True
        except Exception:
            warn("Zebra RPC is not reachable on the configured local port")

        try:
            with urllib.request.urlopen(
                urllib.request.Request(
                    f"http://127.0.0.1:{network['ports']['lightwalletd_http']}/metrics",
                    method="GET",
                ),
                timeout=5,
            ) as response:
                payload["services"]["lightwalletd_metrics"] = response.status == 200
        except urllib.error.URLError:
            payload["services"]["lightwalletd_metrics"] = False

        payload["peer_count"] = count_p2p_sessions(int(network["ports"]["zebra_p2p"]))

if payload["genesis_hash"] == network.get("genesis_hash"):
    payload["chain_ok"] = True
else:
    if payload["genesis_hash"]:
        warn(f"Unexpected genesis hash: {payload['genesis_hash']}")

if not isinstance(payload["blocks"], int) or payload["blocks"] < 0:
    warn("Unable to read block count")

if payload["peer_count"] < 1:
    warn("No peer connections yet")

if not payload["services"]["lightwalletd_metrics"]:
    warn("lightwalletd metrics endpoint is not reachable")

zebra_p2p_port = int(network.get("ports", {}).get("zebra_p2p", 0) or 0)
payload["public_reachable"] = zebra_p2p_port > 0 and ss_listening(zebra_p2p_port) and payload["peer_count"] > 0
if expect_public and not payload["public_reachable"]:
    warn("Expected a public node, but public P2P reachability is not yet proven")

miner_installed = (root_dir / "mining" / "s-nomp").is_dir() or (root_dir / "mining" / "nheqminer" / "build" / "nheqminer").exists()
payload["miner_configured"] = miner_installed
if miner_installed or expect_miner:
    payload["services"]["stratum_listening"] = stratum_port > 0 and ss_listening(stratum_port)
    payload["services"]["nheqminer_running"] = subprocess.run(
        ["pgrep", "-af", "nheqminer"], capture_output=True, text=True, check=False
    ).returncode == 0
    payload["miner_running"] = bool(payload["services"]["nheqminer_running"])

    accepted_share_seen = False
    for candidate in [log_dir / "rzec-nheqminer.log", Path("/tmp/rzec-nheqminer.log")]:
        if candidate.is_file() and "Accepted share" in candidate.read_text(encoding="utf-8", errors="ignore")[-8000:]:
            accepted_share_seen = True
            break
    payload["services"]["accepted_share_seen"] = accepted_share_seen

    if not payload["services"]["stratum_listening"]:
        warn(f"Stratum is not listening on :{stratum_port}")
    if not payload["services"]["nheqminer_running"]:
        warn("nheqminer process not detected")
    if not accepted_share_seen:
        warn("No accepted shares found in recent miner logs")

payload["ready"] = (
    payload["chain_ok"]
    and payload["rpc_ok"]
    and payload["services"]["lightwalletd_metrics"]
    and payload["peer_count"] > 0
    and (not expect_public or payload["public_reachable"])
    and (
        not expect_miner
        or (
            payload["services"]["stratum_listening"]
            and payload["services"]["nheqminer_running"]
            and payload["services"]["accepted_share_seen"]
        )
    )
)

if output_json:
    print(json.dumps(payload, indent=2))
else:
    for line in info_lines(payload):
        print(line)
    if payload["ready"]:
        print("[INFO] Node looks healthy for the live rZEC network")
    else:
        for message in warnings:
            if not message.startswith("Stratum is not listening") and not message.startswith("nheqminer process not detected") and not message.startswith("No accepted shares"):
                print(f"[WARN] {message}")

exit_code = 0 if payload["ready"] else 1
if not strict and not expect_public and not expect_miner:
    sys.exit(exit_code)
sys.exit(exit_code)
PY
