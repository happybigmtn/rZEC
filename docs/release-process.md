# Release Process

rZEC releases freeze one public-safe runtime bundle that agents can install or
rebuild later without drifting onto newer upstream inputs.

## What gets pinned

- Zebra container image tag and digest
- `lightwalletd` container image tag and digest
- `s-nomp` mining branch commit
- `nheqminer` mining branch commit
- Node.js and `nvm` installer versions

Those pins live in `references/UPSTREAM.json`.

## Cut a release

```bash
./scripts/build-release.sh --tag vX.Y.Z
git tag vX.Y.Z
git push origin main --tags
gh release create vX.Y.Z dist/rzec-vX.Y.Z-linux-x86_64.tar.gz dist/SHA256SUMS manifests/manifest-vX.Y.Z.json reports/verification-vX.Y.Z.json
```

The build flow:

1. Verifies the upstream release tags, image digests, and mining-branch commits.
2. Packages a Linux release tarball with the public runtime assets.
3. Writes a machine-readable manifest and verification report.
4. Writes `dist/SHA256SUMS` for the release asset.

## Rebuild from a release tag

```bash
./scripts/build_from_tag.sh vX.Y.Z
```

That clones the tagged repo into a disposable worktree and reruns the same
release build there.
