# Public rZEC Nodes

rZEC uses Zebra plus `lightwalletd` for the node runtime and `s-nomp` plus
`nheqminer` for the reference mining path. For CPU mining, the pinned
`nheqminer` build with the `tromp` Equihash solver is the supported default.
`cpuminer-opt` is not used on `rZEC` because it targets algorithms like
`sha256d`, not Zcash Equihash.

## Ports

- Zebra P2P: `18233/TCP`
- Zebra RPC: `18232/TCP` and keep its host bind on `127.0.0.1`
- lightwalletd gRPC: `9067/TCP`
- lightwalletd HTTP: `9068/TCP`
- stratum: `1234/TCP`

## Fast Path

From a repo checkout:

```bash
sudo ./scripts/public-apply.sh --address YOUR_RZEC_TRANSPARENT_ADDRESS --enable-now
sudo ufw allow 18233/tcp
sudo ufw allow 9067/tcp
sudo ufw allow 9068/tcp
sudo ufw allow 1234/tcp
```

## CPU Miner Helpers

From a repo checkout:

```bash
./scripts/ensure_cpu_miner.sh
./scripts/start_cpu_miner.sh --address YOUR_RZEC_TRANSPARENT_ADDRESS --pool 127.0.0.1:1234
```

Installed hosts also expose `rzec-ensure-cpu-miner` and `rzec-start-cpu-miner`.
If you do not pass `--threads`, the helper uses 75% of logical CPU threads by
default, which matches upstream `nheqminer` guidance more closely than pinning
all cores.

## Health Checks

Run:

```bash
rzec-doctor --root /opt/rzec --json --strict --expect-public
```

Healthy public nodes should show:
- genesis hash `05a60a92d99d85997cce3b87616c089f6124d7342af37106edc76126334a2c38`
- at least one peer connection
- Zebra RPC reachable on `127.0.0.1:18232`
- `lightwalletd` metrics reachable on `127.0.0.1:9068/metrics`

If the host also runs the reference miner, validate that surface explicitly:

```bash
rzec-doctor --root /opt/rzec --json --strict --expect-public --expect-miner
```

## Migrating A Legacy Host

If a host is still running the older `/opt/zend` layout, promote it in place:

```bash
sudo ./scripts/migrate-legacy-host.sh
```

The migration script:
- installs the public `/opt/rzec` runtime and miner services
- preserves the existing Zebra and `lightwalletd` state
- cuts the host over onto `rzec-runtime.service` and `rzec-miner.service`
- verifies the result with `rzec-doctor`

## Public Seeds

- `95.111.227.14:18233`
- `95.111.229.108:18233`
- `161.97.83.147:18233`
- `161.97.97.83:18233`

## Public lightwalletd

- `http://95.111.227.14:9067`
- `http://95.111.229.108:9067`
- `http://161.97.83.147:9067`
- `http://161.97.97.83:9067`
