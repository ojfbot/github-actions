# skill-audit

Composite GitHub Action that analyzes a pull request for skill-usage opportunities and posts a sticky comment.

Uses [`pr-skill-audit.sh`](./pr-skill-audit.sh) (the same script that powers `core/scripts/hooks/pr-skill-audit.sh`). The action handles telemetry fetching, mode resolution, script invocation, and comment upsert.

## Usage

In a consumer repo, add `.github/workflows/skill-audit.yml`:

```yaml
name: Skill Audit
on:
  pull_request:
    types: [opened, synchronize]

jobs:
  skill-audit:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 1
      - uses: ojfbot/github-actions/skill-audit@v1
```

The action infers the PR number from `github.event.pull_request.number`. Override with the `pr-number` input if needed.

## Inputs

| Input | Required | Default | Description |
|---|---|---|---|
| `pr-number` | no | `${{ github.event.pull_request.number }}` | PR to audit |
| `mode` | no | `auto` | One of `auto`, `both`, `heuristic`, `local`. `auto` selects `both` if telemetry is available, `heuristic` otherwise. |

## What it does

1. **Fetches a telemetry snapshot** (optional) from the `telemetry/daily` branch of the consumer repo. Allows skipped if absent — the action falls back to heuristic-only mode.
2. **Runs `pr-skill-audit.sh`** with the resolved mode. The script analyzes the PR diff (heuristic) and/or the telemetry JSONL (local) and emits `/tmp/skill-audit-report.md`.
3. **Upserts a comment** on the PR with the report. The comment is identified by an HTML marker `<!-- skill-audit-results -->` and updated in place on subsequent runs.

## Permissions

The consumer workflow must grant:
- `contents: read` — checkout + telemetry branch fetch
- `pull-requests: write` — for the audit comment

## Source of truth

The script `pr-skill-audit.sh` lives here, in this repo. Previously it lived in `ojfbot/core/scripts/hooks/pr-skill-audit.sh` and was symlinked into consumer repos by `install-agents.sh` — but symlinks pointing outside the repo are gitignored, so CI runners never had the script. See ADR-0067 in `ojfbot/core/decisions/adr/`.

When updating the audit logic, edit `pr-skill-audit.sh` here, tag a new release, and update the consumer pin from `@v1` to `@v2` if the change is breaking.
