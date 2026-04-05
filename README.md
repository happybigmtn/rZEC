# rZEC

rZEC is the public runtime repo for the live Zend-owned Zcash-family network.
It packages the chain contract, public seed metadata, and standalone operator
scripts needed to run a public node or mine on the network without checking out
the Zend control-plane repo.

This repo is intentionally public-safe:
- public network metadata, genesis, ports, and seed peers are tracked
- local fleet orchestration, Tailscale hostnames, SSH targets, and private
  inventory stay out of git
- local-only operator data belongs under `private/` or `runtime/`, both ignored

## Network

- network name: `ZendContaboRzec`
- Zingo chain family: `testnet`
- lightwalletd network family: `testnet`
- Zebra P2P: `18233/TCP`
- Zebra RPC: `18232/TCP` and keep it local-only
- lightwalletd gRPC: `9067/TCP`
- lightwalletd HTTP: `9068/TCP`
- stratum: `1234/TCP`

Current public seed peers:
- `95.111.227.14:18233`
- `95.111.229.108:18233`
- `161.97.83.147:18233`
- `161.97.97.83:18233`

Current public lightwalletd endpoints:
- `http://95.111.227.14:9067`
- `http://95.111.229.108:9067`
- `http://161.97.83.147:9067`
- `http://161.97.97.83:9067`

## Fast Path

From a verified checkout on Ubuntu:

```bash
sudo ./install.sh --miner-address YOUR_RZEC_TRANSPARENT_ADDRESS --enable-node --enable-miner
sudo ufw allow 18233/tcp
sudo ufw allow 9067/tcp
sudo ufw allow 9068/tcp
sudo ufw allow 1234/tcp
```

From a pinned GitHub release bundle:

```bash
./install.sh v0.1.0 --miner-address YOUR_RZEC_TRANSPARENT_ADDRESS --enable-node --enable-miner
```

That installs:
- `rzec-runtime.service`
- `rzec-miner.service`
- wrappers in `/usr/local/bin/`
- runtime root under `/opt/rzec`
- config under `/etc/rzec`
- pinned upstream refs from `references/UPSTREAM.json`

## Layout

- `references/NETWORK.json` — public chain contract and seed metadata
- `references/UPSTREAM.json` — pinned upstream image digests and mining refs
- `profiles/rzec/` — public profile metadata plus genesis
- `docs/public-node.md` — public-node and public-miner guide
- `docs/release-process.md` — release and build-from-tag guide
- `scripts/` — standalone install, doctor, and mining helpers
- `private/` — ignored local-only fleet inventory and operator data
- `manifests/` — generated release manifests
- `reports/` — generated upstream verification reports

## Private Local Data

This repo does not track private fleet inventory.

If you are also operating the current Contabo fleet, keep the private inventory
at:

```text
private/contabo-fleet.json
```

That file is ignored by git on purpose.

## Pinned Release Flow

Build one release bundle from the current repo state:

```bash
./scripts/build-release.sh --tag v0.1.0
```

Build the same release from a fresh tagged checkout:

```bash
./scripts/build_from_tag.sh v0.1.0
```
