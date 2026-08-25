# CLAUDE.md — webhosting-scripts

## Start here

Read [audit/CONTEXT.md](audit/CONTEXT.md) first, every session. It is the compact digest of what this
repo is, how `wh` dispatches, and the `WH_*` environment contract every script depends on.

Then, as needed:

| Need | File |
|---|---|
| What calls what | [audit/graph.json](audit/graph.json) — 58 nodes / 108 edges, `jq`-queryable |
| Visual map | [audit/knowledge-graph.html](audit/knowledge-graph.html) — open in a browser (offline) |
| Fuller architecture + observations | [audit/AUDIT.md](audit/AUDIT.md) |
| Line-by-line traces | `audit/traces/` — populated by `/audit-repo` |

Useful queries:

```bash
jq -r '.nodes[] | select(.group=="deploy") | "\(.id)  \(.file)"' audit/graph.json
jq -r --arg n wh-composer-deploy '.links[] | select(.s==$n or .t==$n) | "\(.s) -[\(.r)]-> \(.t)"' audit/graph.json
```

## Working in this repo

- A `wh <cmd>` command is exactly one file: `wh-scripts/wh-<cmd>.sh` (bash) or `wh-scripts/wh-<cmd>.py`
  (python, run under `venv/`). Nothing else needs registering — the usage list and bash completion
  both derive from `ls wh-scripts/wh-*`.
- Scripts run on production hosting servers as site users and as `forge`, often from non-interactive
  Forge deploy scripts and git post-receive hooks. Assume no TTY and unread stderr.
- Anything touching a site's PHP must go through `wh php` / `wh composer`, never bare `php` /
  `composer` — the servers run several PHP versions and the CLI default is often not the site's.
- `chmod 755` new scripts before committing.
- Adding a python dependency: `source venv/bin/activate && pip install X && pip freeze > requirements.txt`.

## Keeping the map current

```bash
bash audit/tools/regenerate-graph.sh   # reconcile nodes against wh-scripts/ (deterministic, no LLM)
bash audit/tools/refresh-context.sh    # update the freshness/drift block in CONTEXT.md
```

Both are local-only — no network egress. See [audit/tools/README.md](audit/tools/README.md). After
substantively editing a script, update its node `desc` in `audit/graph.json` and re-run
`refresh-context.sh --mark-enriched`.
