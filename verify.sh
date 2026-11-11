#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
VARS_FILE="$SCRIPT_DIR/vars.env"
[[ -f "$VARS_FILE" ]] || { echo "Missing vars.env. Copy vars.example.env to vars.env and fill it in." >&2; exit 2; }
RUN_STAMP=$(date +%F-%H%M)
OUT="$SCRIPT_DIR/evidence/acceptance-client-$RUN_STAMP"
node "$SCRIPT_DIR/scripts/si/dl-verify.mjs" run --vars "$VARS_FILE" --out "$OUT"
printf 'Evidence written to %s\n' "$OUT"
