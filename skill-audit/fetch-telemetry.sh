#!/usr/bin/env bash
# Fetch the telemetry snapshot from origin/telemetry/daily into TELEMETRY_DIR
# (default /tmp/telemetry) and write `available=true|false` to GITHUB_OUTPUT.
# available is true only when at least one non-empty snapshot file landed.
# Run from inside the checked-out repo.
set -uo pipefail
DIR="${TELEMETRY_DIR:-/tmp/telemetry}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

echo "available=false" >> "$OUT"
git fetch origin telemetry/daily 2>/dev/null || exit 0
mkdir -p "$DIR"
for f in tool-telemetry skill-telemetry session-telemetry; do
  git show "origin/telemetry/daily:$f.jsonl" > "$DIR/$f.jsonl" 2>/dev/null || true
done
if [[ -s "$DIR/tool-telemetry.jsonl" || -s "$DIR/skill-telemetry.jsonl" || -s "$DIR/session-telemetry.jsonl" ]]; then
  # Last write wins in GITHUB_OUTPUT.
  echo "available=true" >> "$OUT"
fi
