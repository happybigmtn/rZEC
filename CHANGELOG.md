# Changelog

## 0.1.1

- Fixed `install.sh vX.Y.Z` release-bundle staging to avoid `/tmp` quota failures.
- Kept release-bundle cleanup safe under `set -u`.

## 0.1.0

- Added the first public-safe `rZEC` runtime repo.
- Published the live network contract, genesis, and public seed metadata.
- Added standalone public-node, public-miner, and doctor scripts.
- Pinned Zebra, lightwalletd, `s-nomp`, and `nheqminer` upstream refs for agent-safe releases.
- Added release packaging, manifest validation, and upstream verification scripts.
- Reserved `private/` and `runtime/` as ignored local-only paths.
