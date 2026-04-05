#!/usr/bin/env python3
"""Render the public rZEC runtime files for one node host."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
NETWORK_PATH = REPO_ROOT / "references" / "NETWORK.json"
GENESIS_PATH = REPO_ROOT / "profiles" / "rzec" / "genesis.hex"


def _load_network() -> dict:
    payload = json.loads(NETWORK_PATH.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError(f"Expected JSON object at {NETWORK_PATH}")
    return payload


def _zebrad_toml(
    network: dict,
    *,
    miner_address: str,
    external_addr: str | None,
    seed_peers: list[str],
) -> str:
    peers_text = ", ".join(json.dumps(peer) for peer in seed_peers)
    magic_text = ", ".join(str(part) for part in network["network_magic"])
    activation_lines = "\n".join(
        f"{name} = {height}" for name, height in network["activation_heights"].items()
    )
    lines = [
        "[mining]",
        f'miner_address = "{miner_address}"',
        "",
        "[network]",
        'network = "Testnet"',
        f'listen_addr = "0.0.0.0:{network["ports"]["zebra_p2p"]}"',
    ]
    if external_addr:
        lines.append(f'external_addr = "{external_addr}"')
    lines.extend(
        [
            f"initial_testnet_peers = [{peers_text}]",
            "",
            "[network.testnet_parameters]",
            f'network_name = "{network["network_name"]}"',
            f"network_magic = [{magic_text}]",
            "slow_start_interval = 0",
            f'target_difficulty_limit = "{network["target_difficulty_limit"]}"',
            "disable_pow = false",
            "",
            "[network.testnet_parameters.activation_heights]",
            activation_lines,
            "",
            "[rpc]",
            f'listen_addr = "0.0.0.0:{network["ports"]["zebra_rpc"]}"',
            'cookie_dir = "/home/zebra/.cache/zebra"',
            "enable_cookie_auth = true",
            "",
            "[state]",
            'cache_dir = "/home/zebra/.cache/zebra"',
            "ephemeral = false",
            "",
            "[mempool]",
            "debug_enable_at_height = 0",
            "",
        ]
    )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-root", default=str(REPO_ROOT))
    parser.add_argument("--miner-address", required=True)
    parser.add_argument("--external-addr")
    parser.add_argument("--seed-peer", action="append", default=[])
    args = parser.parse_args()

    network = _load_network()
    output_root = Path(args.output_root).expanduser().resolve()
    runtime_dir = output_root / "runtime"
    lightwalletd_dir = runtime_dir / "lightwalletd"
    zebra_cache_dir = runtime_dir / "zebra-cache"
    for path in (runtime_dir, lightwalletd_dir / "db", zebra_cache_dir / "state"):
        path.mkdir(parents=True, exist_ok=True)

    seed_peers = args.seed_peer or list(network["bootstrap_peers"])
    (output_root / ".env").write_text(
        "\n".join(
            [
                "RZEC_CHAIN_RPC_BIND_HOST=127.0.0.1",
                "RZEC_CHAIN_P2P_BIND_HOST=0.0.0.0",
                "RZEC_CHAIN_LIGHTWALLETD_GRPC_BIND_HOST=0.0.0.0",
                "RZEC_CHAIN_LIGHTWALLETD_HTTP_BIND_HOST=0.0.0.0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (runtime_dir / "profile.json").write_text(
        json.dumps(
            {
                "profile": "rzec_contabo",
                "network_name": network["network_name"],
                "zingo_chain": network["zingo_chain"],
                "lightwalletd_network": network["lightwalletd_network"],
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    (runtime_dir / "genesis.hex").write_text(
        GENESIS_PATH.read_text(encoding="utf-8").strip() + "\n", encoding="utf-8"
    )
    (runtime_dir / "zebrad.toml").write_text(
        _zebrad_toml(
            network,
            miner_address=args.miner_address,
            external_addr=args.external_addr,
            seed_peers=seed_peers,
        ),
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
