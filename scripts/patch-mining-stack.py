#!/usr/bin/env python3
"""Apply deterministic compatibility patches to the pinned s-nomp stack."""

from __future__ import annotations

import argparse
from pathlib import Path


def replace_once(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    if new in text:
        return
    if old not in text:
        raise RuntimeError(f"Expected pattern not found in {path}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", required=True, help="Install root containing mining/s-nomp")
    args = parser.parse_args()

    root = Path(args.root).expanduser().resolve()
    snomp_root = root / "mining" / "s-nomp" / "node_modules" / "stratum-pool" / "lib"

    replace_once(
        snomp_root / "daemon.js",
        """    function batchCmd(cmdArray, callback, timeout) {

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
""",
        """    function batchCmd(cmdArray, callback, timeout) {

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
""",
    )

    daemon_path = snomp_root / "daemon.js"
    daemon_text = daemon_path.read_text(encoding="utf-8")
    patched_daemon_text = daemon_text.replace('jsonrpc: 1.0', 'jsonrpc: "1.0"')
    if patched_daemon_text != daemon_text:
        daemon_path.write_text(patched_daemon_text, encoding="utf-8")

    block_template_path = snomp_root / "blockTemplate.js"
    block_template_text = block_template_path.read_text(encoding="utf-8")
    if "this.rpcData.fundingstreams = this.rpcData.fundingstreams || [];" not in block_template_text:
        marker = "    this.rpcData = rpcData;"
        replacement = "\n".join(
            [
                "    this.rpcData = rpcData;",
                "    this.rpcData.fundingstreams = this.rpcData.fundingstreams || [];",
                "    this.rpcData.certificates = this.rpcData.certificates || [];",
                "    this.rpcData.miner = this.rpcData.miner || 0;",
            ]
        )
        if marker not in block_template_text:
            raise RuntimeError(f"Expected marker not found in {block_template_path}")
        block_template_text = block_template_text.replace(marker, replacement, 1)
    block_template_text = block_template_text.replace(
        "        header.write(this.merkleRoot, position += 32, 32, 'hex');",
        "        header.write(this.merkleRootReversed, position += 32, 32, 'hex');",
        1,
    )
    block_template_text = block_template_text.replace(
        "                this.merkleRoot,",
        "                this.merkleRootReversed,",
        1,
    )
    block_template_path.write_text(block_template_text, encoding="utf-8")

    replace_once(
        snomp_root / "merkleTree.js",
        "    hashes = [util.reverseBuffer(new Buffer(generateTxRaw, 'hex')).toString('hex')];",
        "    hashes = [generateTxRaw];",
    )


if __name__ == "__main__":
    main()
