#!/usr/bin/env python3
"""Probe the Contabo rZEC fleet from private inventory and print JSON status."""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


REMOTE_SCRIPT = r"""
set -euo pipefail

CHAIN_ROOT=""
CHAIN_FLAVOR=""
for candidate in /opt/rzec /opt/zend/chain; do
  if [ -f "$candidate/runtime/zebra-cache/.cookie" ]; then
    CHAIN_ROOT="$candidate"
    case "$candidate" in
      /opt/rzec) CHAIN_FLAVOR="public-rzec" ;;
      /opt/zend/chain) CHAIN_FLAVOR="legacy-zend-chain" ;;
    esac
    break
  fi
done

MINER_ROOT=""
MINER_FLAVOR=""
for candidate in /opt/rzec /opt/zend; do
  if [ -d "$candidate/mining/s-nomp" ]; then
    MINER_ROOT="$candidate"
    case "$candidate" in
      /opt/rzec) MINER_FLAVOR="public-rzec" ;;
      /opt/zend) MINER_FLAVOR="legacy-zend" ;;
    esac
    break
  fi
done

python3 - "$CHAIN_ROOT" "$CHAIN_FLAVOR" "$MINER_ROOT" "$MINER_FLAVOR" <<'PY'
import base64
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path


def rpc(cookie_path: Path, method: str):
    cookie = cookie_path.read_text(encoding="utf-8").strip()
    auth = base64.b64encode(cookie.encode("utf-8")).decode("ascii")
    payload = json.dumps(
        {"jsonrpc": "1.0", "id": "fleet-status", "method": method, "params": []}
    ).encode("utf-8")
    request = urllib.request.Request(
        "http://127.0.0.1:18232",
        data=payload,
        headers={
            "Authorization": f"Basic {auth}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=5) as response:
        return json.loads(response.read() or b"{}")


def count_container_sessions(container_name: str, port: int) -> int:
    proc = subprocess.run(
        [
            "docker",
            "exec",
            container_name,
            "sh",
            "-lc",
            "cat /proc/net/tcp /proc/net/tcp6 2>/dev/null",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        return 0

    count = 0
    port_hex = f"{port:04X}"
    for raw_line in proc.stdout.splitlines()[1:]:
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


def systemd_status(unit_name: str) -> dict:
    active = subprocess.run(
        ["systemctl", "is-active", unit_name],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    enabled = subprocess.run(
        ["systemctl", "is-enabled", unit_name],
        capture_output=True,
        text=True,
        check=False,
    ).stdout.strip()
    return {
        "active": active or "unknown",
        "enabled": enabled or "unknown",
    }


def docker_container_details(container_name: str) -> dict | None:
    proc = subprocess.run(
        [
            "docker",
            "inspect",
            "--format",
            "{{.Config.Image}}|{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{end}}",
            container_name,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    line = proc.stdout.strip()
    if not line:
        return None
    image, _, remainder = line.partition("|")
    status, _, health = remainder.partition("|")
    return {
        "name": container_name,
        "image": image,
        "status": status,
        "health": health or None,
    }


chain_root = Path(sys.argv[1]) if sys.argv[1] else None
chain_flavor = sys.argv[2] or None
miner_root = Path(sys.argv[3]) if sys.argv[3] else None
miner_flavor = sys.argv[4] or None

result = {
    "hostname": subprocess.run(
        ["hostname", "-s"], capture_output=True, text=True, check=False
    ).stdout.strip(),
    "chain_root": str(chain_root) if chain_root else None,
    "chain_flavor": chain_flavor,
    "miner_root": str(miner_root) if miner_root else None,
    "miner_flavor": miner_flavor,
    "services": {
        "rzec_runtime": systemd_status("rzec-runtime.service"),
        "rzec_miner": systemd_status("rzec-miner.service"),
    },
}

if chain_root:
    cookie_path = chain_root / "runtime" / "zebra-cache" / ".cookie"
    blockcount = rpc(cookie_path, "getblockcount")
    bestblockhash = rpc(cookie_path, "getbestblockhash")
    metrics_ok = False
    try:
        with urllib.request.urlopen("http://127.0.0.1:9068/metrics", timeout=5) as response:
            metrics_ok = response.status == 200
    except urllib.error.URLError:
        metrics_ok = False
    container_name = "rzec-zebra" if chain_flavor == "public-rzec" else "zend-private-zebra"
    result["chain"] = {
        "blockcount": blockcount.get("result"),
        "bestblockhash": bestblockhash.get("result"),
        "metrics_ok": metrics_ok,
        "p2p_established": count_container_sessions(container_name, 18233),
        "container": docker_container_details(container_name),
        "lightwalletd_container": docker_container_details("rzec-lightwalletd")
        or docker_container_details("zend-private-lightwalletd"),
    }
else:
    result["chain"] = None

if miner_root:
    ss_output = subprocess.run(
        ["ss", "-ltn"], capture_output=True, text=True, check=False
    ).stdout
    pgrep_output = subprocess.run(
        ["pgrep", "-af", "nheqminer|/mining/s-nomp/init.js"],
        capture_output=True,
        text=True,
        check=False,
    ).stdout
    snomp_log_candidates = [
        miner_root / "runtime" / "logs" / "rzec-snomp.log",
        Path("/tmp/rzec-snomp.log"),
    ]
    miner_log_candidates = [
        miner_root / "runtime" / "logs" / "rzec-nheqminer.log",
        Path("/tmp/rzec-nheqminer.log"),
    ]

    def first_existing(paths):
        for path in paths:
            if path.exists():
                return path
        return None

    snomp_log = first_existing(snomp_log_candidates)
    miner_log = first_existing(miner_log_candidates)
    accepted_share = False
    if miner_log is not None:
        tail = subprocess.run(
            ["tail", "-n", "40", str(miner_log)],
            capture_output=True,
            text=True,
            check=False,
        ).stdout
        accepted_share = "Accepted share" in tail

    result["miner"] = {
        "stratum_listening": ":1234" in ss_output,
        "cli_listening": "127.0.0.1:17117" in ss_output,
        "web_listening": ":8080" in ss_output,
        "processes": [line for line in pgrep_output.splitlines() if line.strip()],
        "accepted_share_seen": accepted_share,
        "snomp_log": str(snomp_log) if snomp_log else None,
        "miner_log": str(miner_log) if miner_log else None,
    }
else:
    result["miner"] = None

print(json.dumps(result))
PY
"""


def load_inventory(path: Path) -> dict:
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"Expected JSON object at {path}")
    return payload


def run_ssh(host: str, user: str) -> dict:
    proc = subprocess.run(
        ["ssh", f"{user}@{host}", "bash", "-s"],
        input=REMOTE_SCRIPT,
        capture_output=True,
        text=True,
        check=False,
    )
    if proc.returncode != 0:
        return {
            "ok": False,
            "error": proc.stderr.strip() or proc.stdout.strip() or f"ssh exit {proc.returncode}",
        }
    try:
        payload = json.loads(proc.stdout.strip().splitlines()[-1])
    except Exception as exc:  # pragma: no cover - defensive
        return {
            "ok": False,
            "error": f"invalid-json: {exc}",
            "raw": proc.stdout.strip(),
        }
    payload["ok"] = True
    return payload


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--inventory",
        default="private/contabo-fleet.json",
        help="Path to private fleet inventory",
    )
    args = parser.parse_args()

    inventory_path = Path(args.inventory).expanduser().resolve()
    inventory = load_inventory(inventory_path)

    results = []
    for node in inventory.get("nodes", []):
        host = node.get("ssh_host") or node.get("public_host")
        user = node.get("ssh_user", "root")
        status = run_ssh(host, user)
        status["id"] = node.get("id")
        status["public_host"] = node.get("public_host")
        results.append(status)

    json.dump({"inventory": str(inventory_path), "nodes": results}, sys.stdout, indent=2)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
