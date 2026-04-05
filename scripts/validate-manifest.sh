#!/usr/bin/env bash
set -euo pipefail

MANIFEST_FILE="${1:-./manifests/manifest.json}"
SCHEMA_FILE="${SCHEMA_FILE:-./schemas/manifest.schema.json}"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "FAIL: manifest not found: $MANIFEST_FILE" >&2
  exit 1
fi

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "FAIL: schema not found: $SCHEMA_FILE" >&2
  exit 1
fi

python3 - "$MANIFEST_FILE" "$SCHEMA_FILE" <<'PY'
import json
import sys

manifest_file = sys.argv[1]
schema_file = sys.argv[2]

with open(schema_file, "r", encoding="utf-8") as handle:
    schema = json.load(handle)
with open(manifest_file, "r", encoding="utf-8") as handle:
    data = json.load(handle)

for key in schema.get("required", []):
    if key not in data:
        print(f"FAIL: missing required key: {key}")
        sys.exit(1)

artifacts = data.get("artifacts")
if not isinstance(artifacts, list) or not artifacts:
    print("FAIL: artifacts must be a non-empty array")
    sys.exit(1)

for artifact in artifacts:
    if "path" not in artifact or "sha256" not in artifact:
        print("FAIL: artifact missing path or sha256")
        sys.exit(1)

print("PASS: manifest validation ok")
PY
