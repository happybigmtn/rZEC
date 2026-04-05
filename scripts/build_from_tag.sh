#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
if [[ -z "$TAG" ]]; then
  echo "Usage: $0 <tag>" >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_URL="${RZEC_RELEASE_REPO_URL:-https://github.com/happybigmtn/rZEC.git}"
WORKDIR="${WORKDIR:-$ROOT_DIR/.cache/build-from-tag}"

mkdir -p "$WORKDIR"
CHECKOUT_DIR="$WORKDIR/rZEC-$TAG"
rm -rf "$CHECKOUT_DIR"
git clone --depth 1 --branch "$TAG" "$REPO_URL" "$CHECKOUT_DIR"
"$CHECKOUT_DIR/scripts/build-release.sh" --tag "$TAG"
