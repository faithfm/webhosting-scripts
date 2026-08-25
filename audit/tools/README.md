# context-map — a local, safe Graphify alternative

Keeps an LLM-readable architecture digest (`audit/CONTEXT.md`) fresh as the codebase changes, and makes the whole `audit/` map adoptable across every repo in the org. Built from the audit in `audit/`.

## The two tiers (why this is safe)

A faithful rebuild of the digest needs an LLM (the prose is model-authored). So the work is split so the *automatic, every-push* part never touches an LLM or the network:

| Tier | When | Engine | Egress | Output |
|---|---|---|---|---|
| **refresh** | every relevant push (+ on demand) | `refresh-context.sh` — pure bash/git | **none** | Stamps the freshness block in `CONTEXT.md`; flags which subsystems changed since the last enrichment (drift). |
| **enrich** | manual dispatch / weekly | Claude Code headless | code → Anthropic API (your key) | Re-reads changed files and rewrites `CONTEXT.md` prose. |

So between enrichments you always know **how stale** the digest is and **where**; you spend LLM tokens only when you choose to.

## Safety properties (baked in)

- **Reviewed, never silent.** Output goes to a `audit/context-map` branch and an auto-PR. `main` stays branch-protected; a human merges.
- **No secret exposure.** Triggers are `push` (default branch), `workflow_dispatch`, and `schedule` only — never `pull_request`/`pull_request_target`, so `ANTHROPIC_API_KEY` is never handed to untrusted fork code.
- **Least privilege.** Workflow token is `contents: write` + `pull-requests: write`; PRs are created with the built-in `GITHUB_TOKEN` via `gh` (no third-party actions beyond first-party `actions/checkout`).
- **Zero-egress default.** The push path runs only `refresh` (no LLM). `enrich` is opt-in and fails loud if the API key is missing.
- **Fail loud.** Malformed/empty output ⇒ CI red, no partial commit. Freshness + the enriched commit SHA are stamped in `CONTEXT.md` so staleness is always visible.
- **No commit loop.** The PR branch isn't the default branch, and the push trigger's path filter excludes `audit/`, so merging the digest never re-triggers the workflow.

## Files

- `refresh-context.sh` — deterministic refresh + drift detection. `--mark-enriched` records HEAD as the new baseline (the enrich job calls this).
- `regenerate-graph.sh` — deterministic skeleton reconcile of `graph.json` against the file tree: adds a stub node for each new source file, flags (`--prune` removes) nodes whose file was deleted, keeps all existing descriptions/edges, and re-injects into `knowledge-graph.html`. Edit `SRC_DIRS`, the `classify()` map, and `SKIP_RE` per repo.
- `enrich.md` — the constrained prompt Claude runs (edits only `audit/CONTEXT.md`).
- `bootstrap.sh` — installs the kit into another repo.
- `../../.github/workflows/context-map.yml` — the workflow (refresh/enrich + PR).

State lives in `audit/.context-state.json` (`enriched_sha`, `last_refresh_sha`, timestamps).

## Roll out to another repo

```bash
cd /path/to/other-repo
bash /path/to/faithsched-v2/audit/tools/bootstrap.sh
# then: add ANTHROPIC_API_KEY secret, protect the default branch,
#       run Actions ▸ context-map ▸ enrich once, commit the added files.
```

The bootstrap installs the same scripts + workflow + starter `CLAUDE.md`/`CONTEXT.md` and runs the first (no-egress) refresh. Edit the `MAP=()` subsystem table and the `paths:` filter in each repo to match its layout (e.g. Zig: `src/**`; Go: `internal/**`, `cmd/**`).

## Promote to a central org workflow (less drift)

For many repos, move the orchestration to one place so you maintain it once:

1. Put `refresh-context.sh`, `enrich.md`, and a `workflow_call` version of the workflow in **`faithfm/.github`** (the org's shared repo).
2. In each repo, keep only a thin caller:
   ```yaml
   # .github/workflows/context-map.yml
   on:
     push: { branches: [main], paths: ['src/**','app/**'] }
     workflow_dispatch: { inputs: { mode: { type: choice, options: [refresh, enrich], default: refresh } } }
     schedule: [{ cron: '17 6 * * 1' }]
   jobs:
     ctx:
       uses: faithfm/.github/.github/workflows/context-map.yml@v1
       secrets: { ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }} }
   ```
   The reusable job checks out the org `.github` repo for the scripts, so logic updates land everywhere at once. Only the thin caller (triggers + path filter) lives per-repo.

## Note on what auto-rebuild can and can't do

| Artifact | Auto-rebuilt? | By |
|---|---|---|
| `CONTEXT.md` freshness + drift flags | ✅ every push | `refresh-context.sh` (no LLM) |
| `graph.json` / `knowledge-graph.html` **node set** (new files in, deleted flagged) | ✅ every push | `regenerate-graph.sh` (no LLM) |
| `CONTEXT.md` **prose** | ✅ on enrich (manual/weekly) | Claude |
| New nodes' **descriptions + edges** | ⚠️ stubs only | needs enrich / a deep pass |
| Line-by-line `traces/**` | ❌ manual | a deeper Claude pass on demand |

So the *structure* self-heals with zero egress (you always see new/removed entities), while the *semantics* (prose, descriptions, edges, traces) refresh when you choose to spend LLM tokens. New nodes show up as `skeleton: true` stubs with a "not yet documented" desc — a visible to-do, never a silent gap.
