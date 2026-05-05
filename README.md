# ojfbot/github-actions

Shared GitHub Actions and reusable workflows for the ojfbot fleet.

Pre-existing problem: ~7 workflow YAML files were duplicated across 14+ repos in the ojfbot cluster (`ci.yml`, `security-scan.yml`, `claude-skill-audit.yml`, `claude-code-review.yml`, `browser-automation-tests.yml`, `deploy.yml`, etc.). Updates required touching every consumer; drift was inevitable. The `claude-skill-audit.yml` workflow specifically was broken on consumer repos because the script it ran (`pr-skill-audit.sh`) lived in `ojfbot/core` and was symlinked into consumers — symlinks pointing outside the repo are gitignored, so CI runners never had the script.

This repo is the durable fix. See [ADR-0067](https://github.com/ojfbot/core/blob/main/decisions/adr/0067-shared-github-actions-repo.md) for the architectural rationale.

## Layout

```
github-actions/
├── skill-audit/                 ← composite action (single job, multi-step)
│   ├── action.yml
│   ├── pr-skill-audit.sh        ← source of truth for the audit logic
│   └── README.md
├── .github/workflows/
│   ├── security-scan.yml        ← reusable workflow (TruffleHog + pnpm audit)
│   └── ci.yml                   ← this repo's own CI
└── README.md
```

Two patterns coexist:
- **Composite actions** (e.g. `skill-audit/`) — single-job, embeddable inside a consumer's existing workflow as a step. Best for workflows that are one job.
- **Reusable workflows** (e.g. `.github/workflows/security-scan.yml`) — multi-job, consumed via `uses: ojfbot/github-actions/.github/workflows/security-scan.yml@v1`. Best for workflows that have multiple parallel jobs.

## Available actions and workflows

| Path | Type | Purpose | Consumer pattern |
|---|---|---|---|
| `skill-audit/` | composite | Analyze PR for skill-usage opportunities; post sticky comment | `uses: ojfbot/github-actions/skill-audit@v1` |
| `.github/workflows/security-scan.yml` | reusable | TruffleHog + API-key grep + dist guard + pnpm audit | `uses: ojfbot/github-actions/.github/workflows/security-scan.yml@v1` |

## Versioning

Pin consumer references to a major-version tag (`@v1`). When breaking changes ship, the new major tag (`@v2`) is created; minor and patch updates flow through `@v1` automatically.

| Pin | Behavior |
|---|---|
| `@v1` | Tracks latest non-breaking release on the v1 line — recommended for consumers |
| `@v1.2.0` | Pinned to a specific version (CI-stable, requires manual bump) |
| `@main` | Bleeding edge — only for testing |

## Migration roadmap (out of this session's scope)

The fleet has additional workflow duplication ripe for migration. In rough priority:

| Candidate | Repos affected | Estimated effort | Notes |
|---|---|---|---|
| `ci.yml` | 14 | High | Likely needs per-stack variants (langgraph apps vs Python vs Chrome ext) |
| `claude-code-review.yml` | 9 | Medium | Wraps `claude-code-action`; thin enough to consolidate |
| `claude.yml` | 8 | Medium | Same |
| `browser-automation-tests.yml` | 8 | High | Docker-based; docker setup would need to live in the action |
| `deploy.yml` (Vercel) | 8 | Medium | Per-app secrets; reusable workflow with input for project ID |
| `pr-welcome.yml` (daily-logger only) | 1 | n/a | Repo-specific, leave alone |

## Adding a new shared action

1. Create a new directory under the repo root (composite) OR a new file under `.github/workflows/` (reusable).
2. Add an entry to the table above.
3. Open a PR; the CI workflow (`ci.yml`) validates the action exists and shellchecks any `.sh` files.
4. After merge, tag a new release:
   ```bash
   git tag v1.x.0
   git tag -f v1
   git push origin v1.x.0 v1 --force
   ```

## License

MIT
