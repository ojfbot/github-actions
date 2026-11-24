#!/usr/bin/env bash
# Tests for the three checks in ojfbot/github-actions issue #4.
# Each test feeds bad input and expects the check to go red.
# Needs network for the dependency-audit tests (pnpm audit).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/security-scan.yml"
FAILS=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILS=$((FAILS + 1)); }

# --- 1. dependency audit: run the workflow's real step script -------------
STEP_SCRIPT="$(mktemp)"
ruby -ryaml -e '
  w = YAML.safe_load(File.read(ARGV[0]), aliases: true)
  s = w["jobs"]["dependency-audit"]["steps"].find { |x| x["name"] == "Audit production dependencies" }
  abort("audit step not found") unless s
  abort("audit step must not set continue-on-error") if s.key?("continue-on-error")
  puts s["run"]
' "$WORKFLOW" > "$STEP_SCRIPT" || { fail "audit step extractable and blocking"; exit 1; }

run_audit() { # fixture level advisory -> sets RC, SUMMARY
  local fixture="$1" level="$2" advisory="$3"
  SUMMARY="$(mktemp)"
  ( cd "$ROOT/tests/fixtures/$fixture" && \
    AUDIT_LEVEL="$level" AUDIT_ADVISORY="$advisory" GITHUB_STEP_SUMMARY="$SUMMARY" \
    bash -eo pipefail "$STEP_SCRIPT" >/dev/null 2>&1 )
  RC=$?
}

run_audit vulnerable-dep high false
[[ $RC -ne 0 ]] && pass "audit goes red on a vulnerable dependency" || fail "audit stayed green on a vulnerable dependency"

run_audit clean-dep high false
[[ $RC -eq 0 ]] && pass "audit is green on a clean fixture" || fail "audit went red on a clean fixture"

run_audit vulnerable-dep high true
if [[ $RC -eq 0 ]] && grep -qi advisory "$SUMMARY"; then pass "advisory mode stays green and says advisory in the summary"; else fail "advisory mode behaviour"; fi

# --- 2. skill audit: gh failure must read "unavailable", not empty ---------
BIN="$(mktemp -d)"
printf '#!/bin/sh\necho "gh: simulated failure" >&2\nexit 1\n' > "$BIN/gh"
chmod +x "$BIN/gh"
OUT="$(cd "$ROOT" && PATH="$BIN:$PATH" bash skill-audit/pr-skill-audit.sh --pr=1 --mode=both 2>&1)"
if grep -qi 'unavailable' <<<"$OUT" && ! grep -q 'No skill suggestions for this changeset' <<<"$OUT"; then
  pass "skill audit reports unavailable when gh fails"
else
  fail "skill audit hid a gh failure"; echo "$OUT"
fi
rm -f /tmp/skill-audit-report.md

# --- 3. YAML check must reject a malformed file ---------------------------
if bash "$ROOT/scripts/validate-yaml.sh" "$ROOT/tests/fixtures/bad-yaml/broken.yml" >/dev/null 2>&1; then
  fail "YAML check accepted a malformed file"
else
  pass "YAML check rejects a malformed file"
fi
if bash "$ROOT/scripts/validate-yaml.sh" "$ROOT"/.github/workflows/*.yml "$ROOT/skill-audit/action.yml" >/dev/null 2>&1; then
  pass "YAML check accepts this repo's real files"
else
  fail "YAML check rejected this repo's real files"
fi

exit "$FAILS"
