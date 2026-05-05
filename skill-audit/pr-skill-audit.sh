#!/usr/bin/env bash
# pr-skill-audit.sh — PR skill usage analysis
#
# Two modes:
#   --mode=local      Read ~/.claude/skill-telemetry.jsonl for actual skill usage
#   --mode=heuristic  Analyze PR diff to suggest skills that should have been used
#
# Usage:
#   bash scripts/hooks/pr-skill-audit.sh --pr=48
#   bash scripts/hooks/pr-skill-audit.sh --pr=48 --mode=heuristic
#   bash scripts/hooks/pr-skill-audit.sh --pr=48 --mode=local
set -euo pipefail

# Defaults
MODE="both"
PR_NUMBER=""
FORMAT="markdown"
REPORT_FILE="/tmp/skill-audit-report.md"
SKILL_TELEMETRY_FILE="${HOME}/.claude/skill-telemetry.jsonl"
TOOL_TELEMETRY_FILE="${HOME}/.claude/tool-telemetry.jsonl"
SESSION_TELEMETRY_FILE="${HOME}/.claude/session-telemetry.jsonl"

# Allow override via TELEMETRY_DIR env var (for CI)
if [[ -n "${TELEMETRY_DIR:-}" ]]; then
  SKILL_TELEMETRY_FILE="$TELEMETRY_DIR/skill-telemetry.jsonl"
  TOOL_TELEMETRY_FILE="$TELEMETRY_DIR/tool-telemetry.jsonl"
  SESSION_TELEMETRY_FILE="$TELEMETRY_DIR/session-telemetry.jsonl"
fi

# Parse arguments
for arg in "$@"; do
  case "$arg" in
    --pr=*) PR_NUMBER="${arg#*=}" ;;
    --mode=*) MODE="${arg#*=}" ;;
    --format=*) FORMAT="${arg#*=}" ;;
  esac
done

if [[ -z "$PR_NUMBER" ]]; then
  echo "Usage: pr-skill-audit.sh --pr=<number> [--mode=local|heuristic|both]" >&2
  exit 1
fi

# Detect repo name
REPO=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# ─── Heuristic analysis ──────────────────────────────────────────────────────

heuristic_audit() {
  local diff_stat
  diff_stat=$(gh pr diff "$PR_NUMBER" --stat 2>/dev/null || echo "")
  local pr_body
  pr_body=$(gh pr view "$PR_NUMBER" --json body -q '.body' 2>/dev/null || echo "")
  local pr_title
  pr_title=$(gh pr view "$PR_NUMBER" --json title -q '.title' 2>/dev/null || echo "")
  local files_changed
  files_changed=$(gh pr diff "$PR_NUMBER" --name-only 2>/dev/null || echo "")
  local lines_changed
  lines_changed=$(echo "$diff_stat" | tail -1 | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null || echo "0")

  SUGGESTED_SKILLS=()
  REASONS=()

  # Rule: CI/CD files changed
  if echo "$files_changed" | grep -q '\.github/workflows/'; then
    SUGGESTED_SKILLS+=("/setup-ci-cd")
    REASONS+=("CI workflow files modified")
  fi

  # Rule: test files changed
  if echo "$files_changed" | grep -qE '__tests__|\.test\.(ts|tsx|js)'; then
    SUGGESTED_SKILLS+=("/test-expand")
    REASONS+=("Test files modified — verify coverage gaps")
  fi

  # Rule: docs changed
  if echo "$files_changed" | grep -qiE 'README|docs/|CLAUDE\.md'; then
    SUGGESTED_SKILLS+=("/doc-refactor")
    REASONS+=("Documentation files modified")
  fi

  # Rule: ADR files changed
  if echo "$files_changed" | grep -q 'decisions/adr/'; then
    SUGGESTED_SKILLS+=("/adr")
    REASONS+=("ADR files modified — verify completeness")
  fi

  # Rule: large changeset
  if [[ "$lines_changed" -gt 500 ]]; then
    SUGGESTED_SKILLS+=("/validate")
    REASONS+=("Large changeset ($lines_changed lines) — quality gate recommended")
  fi

  # Rule: dependency changes
  if echo "$files_changed" | grep -qE 'package\.json|pnpm-lock\.yaml'; then
    SUGGESTED_SKILLS+=("/hardening")
    REASONS+=("Dependencies modified — security review recommended")
  fi

  # Rule: deploy/release in PR description
  if echo "$pr_title $pr_body" | grep -qi 'deploy\|release\|ship'; then
    SUGGESTED_SKILLS+=("/deploy")
    REASONS+=("PR references deployment/release")
  fi

  # Rule: bug fix or debugging
  if echo "$pr_title $pr_body" | grep -qi 'fix\|bug\|debug\|error'; then
    SUGGESTED_SKILLS+=("/investigate")
    REASONS+=("PR references bug fix — was root cause analyzed?")
  fi

  # Rule: new source files (not tests)
  if echo "$files_changed" | grep -qE 'src/.*\.(ts|tsx)$' && ! echo "$files_changed" | grep -qE '__tests__'; then
    SUGGESTED_SKILLS+=("/validate")
    REASONS+=("New source files — quality gate recommended")
  fi

  # Rule: security-sensitive files
  if echo "$files_changed" | grep -qiE 'auth|security|middleware|permission'; then
    SUGGESTED_SKILLS+=("/hardening")
    REASONS+=("Security-sensitive files modified")
  fi

  # Rule: ESLint config or plugin changes
  if echo "$files_changed" | grep -qE 'eslint|lint'; then
    SUGGESTED_SKILLS+=("/lint-audit")
    REASONS+=("ESLint configuration or rules modified — verify with lint audit")
  fi

  # Rule: schema/model changes without test updates
  if echo "$files_changed" | grep -qE 'models/|schemas/' && ! echo "$files_changed" | grep -qE '\.test\.|\.spec\.|__tests__'; then
    SUGGESTED_SKILLS+=("/test-expand")
    REASONS+=("Schema/model files changed without corresponding test updates")
  fi

  # Rule: TECHDEBT.md modified — verify proposed fixes
  if echo "$files_changed" | grep -q 'TECHDEBT.md'; then
    SUGGESTED_SKILLS+=("/techdebt")
    REASONS+=("TECHDEBT.md modified — verify debt items are properly tracked")
  fi
}

# ─── Local telemetry analysis ────────────────────────────────────────────────

local_audit() {
  USED_SKILLS=()

  # Get PR time window for filtering telemetry events.
  #
  # Prior implementation used [first_commit_ts, last_commit_ts] which produced
  # a zero-width window for single-commit PRs. The user typically invokes
  # skills BEFORE the commit (e.g. /grill-with-docs, /plan-feature during
  # prep), so the window must extend backward to capture them.
  #
  # New window:
  #   from = first_commit_ts - 24h (default lookback for prep work)
  #   to   = max(last_commit_ts, NOW) — covers in-progress PRs
  #
  # Override via env: PR_AUDIT_LOOKBACK_HOURS (default 24).
  PR_FIRST_COMMIT_TS=$(gh pr view "$PR_NUMBER" --json commits -q '.commits[0].committedDate' 2>/dev/null || echo "")
  PR_LAST_COMMIT_TS=$(gh pr view "$PR_NUMBER" --json commits -q '.commits[-1].committedDate' 2>/dev/null || echo "")

  if [[ -z "$PR_FIRST_COMMIT_TS" || -z "$PR_LAST_COMMIT_TS" ]]; then
    return
  fi

  local lookback_hours="${PR_AUDIT_LOOKBACK_HOURS:-24}"
  local window_from window_to
  # Prep-work lookback before first commit
  if [[ "$(uname)" == "Darwin" ]]; then
    window_from=$(date -u -j -v-${lookback_hours}H -f "%Y-%m-%dT%H:%M:%SZ" "$PR_FIRST_COMMIT_TS" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$PR_FIRST_COMMIT_TS")
  else
    window_from=$(date -u -d "$PR_FIRST_COMMIT_TS - ${lookback_hours} hours" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || echo "$PR_FIRST_COMMIT_TS")
  fi
  window_to=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Export for downstream tool/session summaries
  PR_WINDOW_FROM="$window_from"
  PR_WINDOW_TO="$window_to"

  # Primary source: skill-telemetry.jsonl
  if [[ -f "$SKILL_TELEMETRY_FILE" && -s "$SKILL_TELEMETRY_FILE" ]]; then
    while IFS= read -r line; do
      skill=$(echo "$line" | jq -r '.skill // empty')
      if [[ -n "$skill" ]]; then
        USED_SKILLS+=("/$skill")
      fi
    done < <(jq -c --arg repo "$REPO" --arg from "$window_from" --arg to "$window_to" \
      'select(.repo == $repo and .ts >= $from and .ts <= $to and .event == "skill:invoked")' \
      "$SKILL_TELEMETRY_FILE" 2>/dev/null || true)
  fi

  # Fallback: extract skills from tool-telemetry.jsonl (catch-all logger)
  if [[ ${#USED_SKILLS[@]} -eq 0 && -f "$TOOL_TELEMETRY_FILE" && -s "$TOOL_TELEMETRY_FILE" ]]; then
    while IFS= read -r line; do
      skill=$(echo "$line" | jq -r '.skill // empty')
      if [[ -n "$skill" ]]; then
        USED_SKILLS+=("/$skill")
      fi
    done < <(jq -c --arg repo "$REPO" --arg from "$window_from" --arg to "$window_to" \
      'select(.repo == $repo and .ts >= $from and .ts <= $to and .skill != "" and .skill != null)' \
      "$TOOL_TELEMETRY_FILE" 2>/dev/null || true)
  fi

  # Coverage credit: if a sibling <!-- skill-usage-report --> comment carries
  # the <!-- has-investigation --> sub-marker, the bead-session hook embedded
  # an /investigate report on this PR. Credit /investigate even when the
  # telemetry/daily branch is stale (worst case: cron missed last sleep
  # window). bead-session.sh writes the sub-marker only when the per-session
  # ~/.claude/last-investigation-${SESSION_ID}.md file exists.
  local already_has_investigate=false
  for s in "${USED_SKILLS[@]}"; do
    case "$s" in /investigate|/investigate:*) already_has_investigate=true ;; esac
  done
  if [[ "$already_has_investigate" == "false" ]]; then
    if gh pr view "$PR_NUMBER" --json comments --jq \
      '.comments[].body' 2>/dev/null | grep -q '<!-- has-investigation -->'; then
      USED_SKILLS+=("/investigate")
    fi
  fi

  # Normalize namespaced skill names (e.g. "/adr:adr" → "/adr") so that
  # downstream coverage matchers (which compare against base names) credit
  # the skill correctly. Keep the original entry too — display in "Skills
  # used" preserves the namespaced form.
  local normalized=()
  for s in "${USED_SKILLS[@]}"; do
    normalized+=("$s")
    case "$s" in
      /*:*) normalized+=("/${s#/*:}") ;;
    esac
  done
  USED_SKILLS=("${normalized[@]}")

  # Deduplicate
  if [[ ${#USED_SKILLS[@]} -gt 0 ]]; then
    USED_SKILLS=($(printf '%s\n' "${USED_SKILLS[@]}" | sort -u))
  fi
}

# ─── Tool usage summary ────────────────────────────────────────────────────────

tool_summary() {
  TOOL_COUNTS=""
  TOTAL_TOOL_CALLS=0

  if [[ ! -f "$TOOL_TELEMETRY_FILE" || ! -s "$TOOL_TELEMETRY_FILE" ]]; then
    return
  fi
  if [[ -z "${PR_WINDOW_FROM:-}" || -z "${PR_WINDOW_TO:-}" ]]; then
    return
  fi

  TOOL_COUNTS=$(jq -c --arg repo "$REPO" --arg from "$PR_WINDOW_FROM" --arg to "$PR_WINDOW_TO" \
    'select(.repo == $repo and .ts >= $from and .ts <= $to) | .tool_name' \
    "$TOOL_TELEMETRY_FILE" 2>/dev/null | sort | uniq -c | sort -rn | head -8 || true)

  TOTAL_TOOL_CALLS=$(echo "$TOOL_COUNTS" | awk '{s+=$1} END {print s+0}')
}

# ─── Session summary ───────────────────────────────────────────────────────────

session_summary() {
  SESSION_COUNT=0

  if [[ ! -f "$SESSION_TELEMETRY_FILE" || ! -s "$SESSION_TELEMETRY_FILE" ]]; then
    return
  fi
  if [[ -z "${PR_WINDOW_FROM:-}" || -z "${PR_WINDOW_TO:-}" ]]; then
    return
  fi

  SESSION_COUNT=$(jq -r --arg repo "$REPO" --arg from "$PR_WINDOW_FROM" --arg to "$PR_WINDOW_TO" \
    'select(.repo == $repo and .ts >= $from and .ts <= $to) | .session_id' \
    "$SESSION_TELEMETRY_FILE" 2>/dev/null | sort -u | wc -l | tr -d ' ' || echo "0")
}

# ─── Lint summary ──────────────────────────────────────────────────────────────

lint_summary() {
  LINT_FIXED=0
  LINT_REGRESSIONS=0

  if [[ ! -f "$TOOL_TELEMETRY_FILE" || ! -s "$TOOL_TELEMETRY_FILE" ]]; then
    return
  fi
  if [[ -z "$PR_FIRST_COMMIT_TS" || -z "$PR_LAST_COMMIT_TS" ]]; then
    return
  fi

  LINT_FIXED=$(jq --slurp --arg repo "$REPO" --arg from "$PR_FIRST_COMMIT_TS" --arg to "$PR_LAST_COMMIT_TS" \
    '[.[] | select(.repo == $repo and .ts >= $from and .ts <= $to and .event == "lint:fixed") | .violations_fixed] | add // 0' \
    "$TOOL_TELEMETRY_FILE" 2>/dev/null || echo "0")

  LINT_REGRESSIONS=$(jq --slurp --arg repo "$REPO" --arg from "$PR_FIRST_COMMIT_TS" --arg to "$PR_LAST_COMMIT_TS" \
    '[.[] | select(.repo == $repo and .ts >= $from and .ts <= $to and .event == "lint:regression") | .new_violations] | add // 0' \
    "$TOOL_TELEMETRY_FILE" 2>/dev/null || echo "0")
}

# ─── Generate report ─────────────────────────────────────────────────────────

generate_report() {
  {
    echo "## Skill Audit — PR #${PR_NUMBER}"
    echo ""

    if [[ "$MODE" == "local" || "$MODE" == "both" ]]; then
      echo "### Skills used during development"
      echo ""
      if [[ ${#USED_SKILLS[@]} -gt 0 ]]; then
        for skill in "${USED_SKILLS[@]}"; do
          echo "- \`$skill\`"
        done
      else
        echo "_No skill telemetry found for this PR's time range._"
      fi
      echo ""
    fi

    # Session context (light — just how many sessions went into this PR)
    if [[ "$SESSION_COUNT" -gt 0 ]]; then
      echo "**Sessions**: $SESSION_COUNT"
      echo ""
    fi

    # Lint summary (if any lint events)
    if [[ "$LINT_FIXED" -gt 0 || "$LINT_REGRESSIONS" -gt 0 ]]; then
      echo "### Lint activity"
      echo ""
      echo "- Violations fixed: **$LINT_FIXED**"
      echo "- Regressions introduced: **$LINT_REGRESSIONS**"
      echo ""
    fi

    if [[ "$MODE" == "heuristic" || "$MODE" == "both" ]]; then
      echo "### Recommended skills (based on diff analysis)"
      echo ""
      if [[ ${#SUGGESTED_SKILLS[@]} -gt 0 ]]; then
        for i in "${!SUGGESTED_SKILLS[@]}"; do
          echo "- \`${SUGGESTED_SKILLS[$i]}\` — ${REASONS[$i]}"
        done
      else
        echo "_No skill suggestions for this changeset._"
      fi
      echo ""
    fi

    if [[ "$MODE" == "both" && ${#SUGGESTED_SKILLS[@]} -gt 0 && ${#USED_SKILLS[@]} -ge 0 ]]; then
      echo "### Coverage"
      echo ""
      local missed=0
      for suggested in "${SUGGESTED_SKILLS[@]}"; do
        local found=false
        for used in "${USED_SKILLS[@]}"; do
          if [[ "$suggested" == "$used" ]]; then
            found=true
            break
          fi
        done
        if [[ "$found" == "false" ]]; then
          echo "- \`$suggested\` was not used but is recommended"
          missed=$((missed + 1))
        fi
      done
      if [[ $missed -eq 0 ]]; then
        echo "_All recommended skills were used._ ✓"
      fi
      echo ""
    fi

    echo "---"
    echo "_Generated by [skill-audit](https://github.com/ojfbot/core/blob/main/scripts/hooks/pr-skill-audit.sh)_"
  } > "$REPORT_FILE"

  cat "$REPORT_FILE"
}

# ─── JSON output ─────────────────────────────────────────────────────────────

generate_json_report() {
  jq -nc \
    --arg pr "$PR_NUMBER" \
    --arg repo "$REPO" \
    --argjson tool_calls "$TOTAL_TOOL_CALLS" \
    --argjson sessions "$SESSION_COUNT" \
    --argjson lint_fixed "$LINT_FIXED" \
    --argjson lint_regressions "$LINT_REGRESSIONS" \
    --argjson used_skills "$(printf '%s\n' "${USED_SKILLS[@]:-}" | jq -R . | jq -s .)" \
    --argjson suggested_skills "$(printf '%s\n' "${SUGGESTED_SKILLS[@]:-}" | jq -R . | jq -s .)" \
    --argjson tool_breakdown "$(echo "${TOOL_COUNTS:-}" | awk '{print $2, $1}' | tr -d '"' | jq -Rn '[inputs | split(" ") | {(.[0]): (.[1] | tonumber)}] | add // {}')" \
    '{
      pr: $pr,
      repo: $repo,
      skills_used: $used_skills,
      skills_suggested: $suggested_skills,
      tool_calls: $tool_calls,
      sessions: $sessions,
      lint_fixed: $lint_fixed,
      lint_regressions: $lint_regressions,
      tool_breakdown: $tool_breakdown
    }'
}

# ─── Main ─────────────────────────────────────────────────────────────────────

SUGGESTED_SKILLS=()
REASONS=()
USED_SKILLS=()
PR_FIRST_COMMIT_TS=""
PR_LAST_COMMIT_TS=""
TOOL_COUNTS=""
TOTAL_TOOL_CALLS=0
SESSION_COUNT=0
LINT_FIXED=0
LINT_REGRESSIONS=0

case "$MODE" in
  local)
    local_audit
    tool_summary
    session_summary
    lint_summary
    ;;
  heuristic)
    heuristic_audit
    ;;
  both)
    heuristic_audit
    local_audit
    tool_summary
    session_summary
    lint_summary
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    exit 1
    ;;
esac

case "$FORMAT" in
  json)
    generate_json_report
    ;;
  markdown|*)
    generate_report
    ;;
esac
