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
  abort("dependency-audit job must not set continue-on-error") if w["jobs"]["dependency-audit"].key?("continue-on-error")
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
if [[ $RC -eq 0 ]] && grep -qi advisory "$SUMMARY" && grep -qi 'exit [1-9]' "$SUMMARY" && ! grep -qi 'findings reported' "$SUMMARY"; then
  pass "advisory mode stays green, says advisory, shows the exit code"
else fail "advisory mode on a failing audit"; cat "$SUMMARY"; fi

run_audit clean-dep high true
if [[ $RC -eq 0 ]] && grep -qi advisory "$SUMMARY"; then pass "advisory mode says advisory on a clean run too"; else fail "advisory clean run does not say advisory"; fi

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

# Partial failure: only the comments call fails. Coverage must not claim
# "/investigate was not used"; it must say unknown.
cat > "$BIN/gh" <<'G'
#!/bin/sh
case "$*" in
  *"--name-only"*) echo "src/app.ts" ;;
  *"title,body"*) echo '{"title":"fix bug","body":""}' ;;
  *"additions,deletions"*) echo '{"additions":3,"deletions":1}' ;;
  *"--json commits"*) echo '{"commits":[{"committedDate":"2026-01-01T00:00:00Z"}]}' ;;
  *comments*) echo "gh: simulated comments failure" >&2; exit 1 ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
G
OUT="$(cd "$ROOT" && TELEMETRY_DIR="$BIN/none" PATH="$BIN:$PATH" bash skill-audit/pr-skill-audit.sh --pr=1 --mode=both 2>&1)"
if grep -qi 'unknown' <<<"$OUT" && grep -qi 'unavailable' <<<"$OUT" && ! grep -q 'was not used but is recommended' <<<"$OUT"; then
  pass "partial gh failure: coverage says unknown, not 'not used'"
else
  fail "partial gh failure treated as empty input"; echo "$OUT"
fi

# JSON output: explicit unavailable field, no empty-string entries.
printf '#!/bin/sh\necho "gh: simulated failure" >&2\nexit 1\n' > "$BIN/gh"
JSON="$(cd "$ROOT" && TELEMETRY_DIR="$BIN/none" PATH="$BIN:$PATH" bash skill-audit/pr-skill-audit.sh --pr=1 --mode=both --format=json 2>/dev/null)"
if [[ "$(jq -r '.unavailable' <<<"$JSON" 2>/dev/null)" == "true" ]] \
   && [[ "$(jq '[.skills_suggested[], .skills_used[]] | map(select(. == "")) | length' <<<"$JSON" 2>/dev/null)" == "0" ]]; then
  pass "json report has unavailable=true and no empty-string entries"
else
  fail "json report hides unavailable state or has empty entries"; echo "$JSON"
fi
rm -f /tmp/skill-audit-report.md

# --- 3. YAML check must reject a malformed file ---------------------------
if bash "$ROOT/scripts/validate-yaml.sh" "$ROOT/tests/fixtures/bad-yaml/broken.yml" >/dev/null 2>&1; then
  fail "YAML check accepted a malformed file"
else
  pass "YAML check rejects a malformed file"
fi
for f in two-docs-second-broken two-docs-valid undefined-alias; do
  if bash "$ROOT/scripts/validate-yaml.sh" "$ROOT/tests/fixtures/bad-yaml/$f.yml" >/dev/null 2>&1; then
    fail "YAML check accepted $f (multi-document file)"
  else
    pass "YAML check rejects $f"
  fi
done
if bash "$ROOT/scripts/validate-yaml.sh" "$ROOT"/.github/workflows/*.yml "$ROOT/skill-audit/action.yml" >/dev/null 2>&1; then
  pass "YAML check accepts this repo's real files"
else
  fail "YAML check rejected this repo's real files"
fi

# --- 4. telemetry fetch: available=true only when a file really landed ------
FT="$ROOT/skill-audit/fetch-telemetry.sh"
if grep -q 'available=true' "$ROOT/skill-audit/action.yml"; then
  fail "action.yml sets available=true itself; it must come from fetch-telemetry.sh"
elif ! grep -q 'fetch-telemetry.sh' "$ROOT/skill-audit/action.yml"; then
  fail "action.yml does not call fetch-telemetry.sh"
else
  pass "action.yml delegates to fetch-telemetry.sh"
fi
W="$(mktemp -d)"
git init -q "$W/origin" && ( cd "$W/origin" && git config user.email t@t && git config user.name t \
  && git commit -q --allow-empty -m base && git branch -M main )
# Clone first, then change the telemetry branch, so each check proves the
# script really fetched the new content.
for c in c1 c2 c3; do git clone -q "$W/origin" "$W/$c" 2>/dev/null; done
check_fetch() { # name expected
  local name="$1" want="$2" out
  out="$(cd "$W/$name" && TELEMETRY_DIR="$W/$name-t" GITHUB_OUTPUT="$W/$name-out" bash "$FT" >/dev/null 2>&1; tail -1 "$W/$name-out")"
  [[ "$out" == "available=$want" ]] && pass "fetch-telemetry: $name -> available=$want" || fail "fetch-telemetry: $name gave '$out', wanted available=$want"
}
check_fetch c1 false   # no telemetry branch
( cd "$W/origin" && git checkout -q -b telemetry/daily && : > tool-telemetry.jsonl && git add . && git commit -q -m empty )
check_fetch c2 false   # branch appeared after clone, files empty
( cd "$W/origin" && echo '{"a":1}' > tool-telemetry.jsonl && git add . && git commit -q -m data )
check_fetch c3 true    # data appeared after clone: only a real fetch finds it
if [[ -s "$W/c3-t/tool-telemetry.jsonl" ]]; then pass "fetch-telemetry copied the new content"; else fail "fetch-telemetry did not copy the new content"; fi

exit "$FAILS"
