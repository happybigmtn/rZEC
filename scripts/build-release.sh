#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${RZEC_RELEASE_TAG:-}"
PLATFORM="${RZEC_RELEASE_PLATFORM:-}"
OUTPUT_DIR="${RZEC_RELEASE_OUTPUT_DIR:-$ROOT_DIR/dist}"
MANIFEST_DIR="${RZEC_RELEASE_MANIFEST_DIR:-$ROOT_DIR/manifests}"
REPORT_DIR="${RZEC_RELEASE_REPORT_DIR:-$ROOT_DIR/reports}"
STAGING_DIR_BASE="${RZEC_RELEASE_STAGING_DIR:-$ROOT_DIR/.tmp/release}"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-}"

usage() {
  cat <<'EOF'
Build and package a pinned rZEC release tarball.

Usage:
  ./scripts/build-release.sh --tag TAG [--platform PLATFORM] [--output-dir DIR]
EOF
}

info() { printf '[INFO] %s\n' "$1"; }
error() { printf '[ERROR] %s\n' "$1" >&2; exit 1; }

detect_platform() {
  local os arch
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch="$(uname -m)"

  case "$os" in
    linux*) os="linux" ;;
    *) error "Unsupported OS: $os" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="x86_64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) error "Unsupported architecture: $arch" ;;
  esac

  printf '%s-%s\n' "$os" "$arch"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --tag)
        [[ $# -ge 2 ]] || error "--tag requires a value"
        TAG="$2"
        shift 2
        ;;
      --platform)
        [[ $# -ge 2 ]] || error "--platform requires a value"
        PLATFORM="$2"
        shift 2
        ;;
      --output-dir)
        [[ $# -ge 2 ]] || error "--output-dir requires a path"
        OUTPUT_DIR="$2"
        shift 2
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
}

resolve_source_date_epoch() {
  if [[ -n "$SOURCE_DATE_EPOCH" ]]; then
    return
  fi
  SOURCE_DATE_EPOCH="$(git -C "$ROOT_DIR" log -1 --format=%ct HEAD)"
}

main() {
  parse_args "$@"
  [[ -n "$TAG" ]] || error "--tag is required"
  if [[ -z "$PLATFORM" ]]; then
    PLATFORM="$(detect_platform)"
  fi
  resolve_source_date_epoch

  mkdir -p "$OUTPUT_DIR" "$MANIFEST_DIR" "$REPORT_DIR"
  mkdir -p "$STAGING_DIR_BASE"

  local report_path manifest_path latest_manifest stage_root stage_parent package_root tarball
  stage_parent=""
  report_path="$REPORT_DIR/verification-$TAG.json"
  manifest_path="$MANIFEST_DIR/manifest-$TAG.json"
  latest_manifest="$MANIFEST_DIR/manifest.json"

  "$ROOT_DIR/scripts/verify-upstream-lock.py" \
    --release-tag "$TAG" \
    --output "$report_path"

  package_root="rzec-$TAG-$PLATFORM"
  stage_parent="$(mktemp -d "$STAGING_DIR_BASE/stage.XXXXXX")"
  trap '[[ -n "${stage_parent:-}" ]] && rm -rf "$stage_parent"' EXIT
  stage_root="$stage_parent/$package_root"
  mkdir -p "$stage_root"

  cp "$ROOT_DIR/install.sh" "$stage_root/install.sh"
  cp "$ROOT_DIR/docker-compose.yml" "$stage_root/docker-compose.yml"
  cp -R "$ROOT_DIR/contrib" "$stage_root/contrib"
  cp -R "$ROOT_DIR/docs" "$stage_root/docs"
  cp -R "$ROOT_DIR/profiles" "$stage_root/profiles"
  cp -R "$ROOT_DIR/references" "$stage_root/references"
  cp -R "$ROOT_DIR/scripts" "$stage_root/scripts"
  cp -R "$ROOT_DIR/templates" "$stage_root/templates"
  cp "$report_path" "$stage_root/verification-$TAG.json"
  find "$stage_root" -type d -name "__pycache__" -prune -exec rm -rf {} +

  python3 - "$stage_root" "$manifest_path" "$latest_manifest" "$TAG" <<'PY'
import hashlib
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

stage_root = Path(sys.argv[1]).resolve()
manifest_path = Path(sys.argv[2]).resolve()
latest_manifest = Path(sys.argv[3]).resolve()
tag = sys.argv[4]

artifacts = []
for path in sorted(stage_root.rglob("*")):
    if not path.is_file():
        continue
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    artifacts.append(
        {
            "path": "./" + path.relative_to(stage_root).as_posix(),
            "sha256": digest,
        }
    )

payload = {
    "release_tag": tag,
    "upstream_lock": "./references/UPSTREAM.json",
    "verification_report": f"./verification-{tag}.json",
    "timestamp": datetime.now(timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z"),
    "artifacts": artifacts,
}
text = json.dumps(payload, indent=2) + "\n"
stage_manifest = stage_root / f"manifest-{tag}.json"
stage_manifest.write_text(text, encoding="utf-8")
manifest_path.write_text(text, encoding="utf-8")
latest_manifest.write_text(text, encoding="utf-8")
PY

  "$ROOT_DIR/scripts/validate-manifest.sh" "$manifest_path"

  tarball="$OUTPUT_DIR/${package_root}.tar.gz"
  python3 - "$stage_root" "$tarball" "$SOURCE_DATE_EPOCH" <<'PY'
import gzip
import os
import tarfile
import sys
from pathlib import Path

source_root = Path(sys.argv[1]).resolve()
tarball = Path(sys.argv[2]).resolve()
mtime = int(sys.argv[3])

def normalized_mode(path: Path) -> int:
    if path.is_dir():
        return 0o755
    if os.access(path, os.X_OK):
        return 0o755
    return 0o644

with tarball.open("wb") as raw:
    with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=mtime) as gz:
        with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as archive:
            for path in [source_root, *sorted(source_root.rglob("*"))]:
                arcname = path.relative_to(source_root.parent).as_posix()
                info = archive.gettarinfo(str(path), arcname)
                info.uid = 0
                info.gid = 0
                info.uname = "root"
                info.gname = "root"
                info.mtime = mtime
                info.mode = normalized_mode(path)
                if path.is_file():
                    with path.open("rb") as handle:
                        archive.addfile(info, handle)
                else:
                    archive.addfile(info)
PY

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$OUTPUT_DIR" && sha256sum "$(basename "$tarball")" > SHA256SUMS)
  else
    (cd "$OUTPUT_DIR" && shasum -a 256 "$(basename "$tarball")" > SHA256SUMS)
  fi

  info "Built release tarball $tarball"
}

main "$@"
