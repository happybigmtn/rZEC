# Public rZEC Nodes

rZEC uses Zebra plus `lightwalletd` for the node runtime and `s-nomp` plus
`nheqminer` for the reference mining path.

## Ports

- Zebra P2P: `18233/TCP`
- Zebra RPC: `18232/TCP` and keep it bound to `127.0.0.1`
- lightwalletd gRPC: `9067/TCP`
- lightwalletd HTTP: `9068/TCP`
- stratum: `1234/TCP`

## Fast Path

From a repo checkout:

```bash
sudo ./scripts/install-public-node.sh --miner-address YOUR_RZEC_TRANSPARENT_ADDRESS --enable-now
sudo ./scripts/install-public-miner.sh --address YOUR_RZEC_TRANSPARENT_ADDRESS --enable-now
sudo ufw allow 18233/tcp
sudo ufw allow 9067/tcp
sudo ufw allow 9068/tcp
sudo ufw allow 1234/tcp
```

## Health Checks

Run:

```bash
rzec-doctor --root /opt/rzec
```

Healthy public nodes should show:
- genesis hash `fa1b34031a2d446cb9b266a9c8b8faeb1f6a8ec512cb5ba5ad8f98fb6b57951c`
- at least one peer connection
- Zebra RPC reachable on `127.0.0.1:18232`
- `lightwalletd` health reachable on `127.0.0.1:9068/health`

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
