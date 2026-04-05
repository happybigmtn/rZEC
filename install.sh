#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINER_ADDRESS=""
THREADS=""
ENABLE_NODE=0
ENABLE_MINER=0
ENABLE_NOW=0
RELEASE_TAG=""
RELEASE_REPO="${RZEC_RELEASE_REPO:-happybigmtn/rZEC}"
RELEASE_TMP_BASE="${RZEC_RELEASE_TMP_BASE:-$ROOT_DIR/.tmp/install}"

usage() {
  cat <<'EOF'
Install the public rZEC node and optional miner on this host.

Usage:
  ./install.sh vX.Y.Z --miner-address TM_ADDRESS [--threads N] [--enable-node] [--enable-miner] [--enable-now]
  sudo ./install.sh --miner-address TM_ADDRESS [--threads N] [--enable-node] [--enable-miner] [--enable-now]

If a release tag is provided first, this script downloads the pinned GitHub
release bundle, verifies `SHA256SUMS`, and reruns the bundled installer.

If neither --enable-node nor --enable-miner is provided, both are enabled.
EOF
}

error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    linux*) os="linux" ;;
    *) error "Release bundles currently support Linux hosts only" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) error "Unsupported architecture: $arch" ;;
  esac

  printf '%s-%s\n' "$os" "$arch"
}

verify_release_bundle() {
  local sums_file="$1"
  local tarball="$2"
  if command -v sha256sum >/dev/null 2>&1; then
    (
      cd "$(dirname "$tarball")"
      sha256sum -c "$(basename "$sums_file")" --ignore-missing
    )
    return
  fi
  (
    cd "$(dirname "$tarball")"
    shasum -a 256 -c "$(basename "$sums_file")"
  )
}

install_from_release() {
  local tag="$1"
  shift

  local platform asset_name base_url tmp_dir tarball sums extracted_root
  tmp_dir=""
  platform="$(detect_platform)"
  asset_name="rzec-${tag}-${platform}.tar.gz"
  base_url="${RZEC_RELEASE_DOWNLOAD_BASE:-https://github.com/${RELEASE_REPO}/releases/download/${tag}}"
  mkdir -p "$RELEASE_TMP_BASE"
  tmp_dir="$(mktemp -d "$RELEASE_TMP_BASE/release.XXXXXX")"
  trap '[[ -n "${tmp_dir:-}" ]] && rm -rf "$tmp_dir"' EXIT

  tarball="$tmp_dir/$asset_name"
  sums="$tmp_dir/SHA256SUMS"

  curl -fsSL "$base_url/$asset_name" -o "$tarball"
  curl -fsSL "$base_url/SHA256SUMS" -o "$sums"
  verify_release_bundle "$sums" "$tarball"

  tar -xzf "$tarball" -C "$tmp_dir"
  extracted_root="$(find "$tmp_dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [[ -n "$extracted_root" ]] || error "Release archive did not contain one top-level directory"

  exec "$extracted_root/install.sh" "$@"
}

if [[ $# -gt 0 && "$1" == v* && "$1" != --* ]]; then
  RELEASE_TAG="$1"
  shift
fi

if [[ -n "$RELEASE_TAG" ]]; then
  install_from_release "$RELEASE_TAG" "$@"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --miner-address)
      [[ $# -ge 2 ]] || error "--miner-address requires a value"
      MINER_ADDRESS="$2"
      shift 2
      ;;
    --threads)
      [[ $# -ge 2 ]] || error "--threads requires a value"
      THREADS="$2"
      shift 2
      ;;
    --enable-node)
      ENABLE_NODE=1
      shift
      ;;
    --enable-miner)
      ENABLE_MINER=1
      shift
      ;;
    --enable-now)
      ENABLE_NOW=1
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

[[ -n "$MINER_ADDRESS" ]] || error "--miner-address is required"

if [[ "$ENABLE_NODE" -eq 0 && "$ENABLE_MINER" -eq 0 ]]; then
  ENABLE_NODE=1
  ENABLE_MINER=1
fi

if [[ "$ENABLE_NODE" -eq 1 ]]; then
  node_args=(--miner-address "$MINER_ADDRESS")
  if [[ "$ENABLE_NOW" -eq 1 ]]; then
    node_args+=(--enable-now)
  fi
  "$ROOT_DIR/scripts/install-public-node.sh" "${node_args[@]}"
fi

if [[ "$ENABLE_MINER" -eq 1 ]]; then
  miner_args=(--address "$MINER_ADDRESS")
  if [[ -n "$THREADS" ]]; then
    miner_args+=(--threads "$THREADS")
  fi
  if [[ "$ENABLE_NOW" -eq 1 ]]; then
    miner_args+=(--enable-now)
  fi
  "$ROOT_DIR/scripts/install-public-miner.sh" "${miner_args[@]}"
fi
