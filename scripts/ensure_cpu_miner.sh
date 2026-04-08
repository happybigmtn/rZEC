#!/usr/bin/env bash

set -euo pipefail

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"
ASSET_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="${RZEC_CPU_MINER_ROOT:-$ASSET_ROOT}"
FORCE_BUILD="${FORCE_BUILD:-0}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc 2>/dev/null || echo 1)}"

eval "$(
  python3 - "$ASSET_ROOT/references/UPSTREAM.json" <<'PY'
import json
import shlex
import sys

payload = json.loads(open(sys.argv[1], encoding="utf-8").read())
values = {
    "NHEQMINER_REPO": payload["miner_stack"]["nheqminer"]["repo"],
    "NHEQMINER_BRANCH": payload["miner_stack"]["nheqminer"]["branch"],
    "NHEQMINER_COMMIT": payload["miner_stack"]["nheqminer"]["commit"],
}
for key, value in values.items():
    print(f"{key}={shlex.quote(str(value))}")
PY
)"

usage() {
  cat <<'EOF'
Build the pinned rZEC CPU miner (`nheqminer`) with the tromp Equihash solver.

Usage:
  ./scripts/ensure_cpu_miner.sh [--root PATH] [--force]
EOF
}

info() { printf '[INFO] %s\n' "$1"; }
warn() { printf '[WARN] %s\n' "$1" >&2; }
error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

run_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  error "Need root privileges to install build dependencies"
}

ensure_build_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    run_root apt-get update -qq
    run_root apt-get install -y build-essential cmake git libboost-all-dev libicu-dev
    return
  fi
  if command -v brew >/dev/null 2>&1; then
    brew install cmake boost icu4c
    return
  fi
  warn "Unknown package manager; assuming nheqminer build dependencies are already installed"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)
      [[ $# -ge 2 ]] || error "--root requires a value"
      BUILD_ROOT="$(cd "$2" && pwd)"
      shift 2
      ;;
    --force)
      FORCE_BUILD=1
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

MINER_ROOT="$BUILD_ROOT/mining/nheqminer"
MINER_BIN="$MINER_ROOT/build/nheqminer"

if [[ "$FORCE_BUILD" != "1" && -x "$MINER_BIN" && -d "$MINER_ROOT/.git" ]]; then
  current_commit="$(git -C "$MINER_ROOT" rev-parse HEAD 2>/dev/null || true)"
  if [[ "$current_commit" == "$NHEQMINER_COMMIT" ]]; then
    info "nheqminer already built at $MINER_BIN"
    exit 0
  fi
fi

ensure_build_deps
mkdir -p "$BUILD_ROOT/mining"

if [[ ! -d "$MINER_ROOT/.git" ]]; then
  info "Cloning nheqminer from $NHEQMINER_REPO"
  git clone "$NHEQMINER_REPO" "$MINER_ROOT"
fi

info "Checking out nheqminer commit $NHEQMINER_COMMIT"
git -C "$MINER_ROOT" fetch origin >/dev/null 2>&1 || true
git -C "$MINER_ROOT" checkout "$NHEQMINER_COMMIT" >/dev/null

mkdir -p "$MINER_ROOT/build"
info "Building nheqminer with the CPU tromp solver"
(
  cd "$MINER_ROOT/build"
  cmake -DUSE_CUDA_DJEZO=OFF -DUSE_CPU_XENONCAT=OFF -DUSE_CPU_TROMP=ON ..
  make -j"$BUILD_JOBS"
)

[[ -x "$MINER_BIN" ]] || error "nheqminer build did not produce $MINER_BIN"
info "nheqminer ready at $MINER_BIN"
