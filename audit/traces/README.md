# traces/

Line-by-line walkthroughs of each layer, plus the master risk register (`00-index.md`).

**Not yet generated.** These are produced by the deep audit pass — run `/audit-repo` in Claude Code.
Until then the `trace` field on every node in `audit/graph.json` is deliberately empty, so the viz
does not render links to files that do not exist.

`audit/tools/regenerate-graph.sh` is already wired with the intended filenames, and will assign them
to any newly-added command:

| Doc | Covers |
|---|---|
| `01-dispatcher-and-environment.md` | `wh.sh` context detection, the `WH_*` contract, diagnostics |
| `02-deployment-pipeline.md` | checkout → composer-deploy → fpm-reload, and the `wh php`/`composer`/`git` helpers |
| `03-docker-framework.md` | docker deploy/down/summary + the template-copy mechanism |
| `04-backup-framework.md` | restic / resticprofile commands |
| `05-observability-newrelic.md` | deployment marker capture + forward |
| `06-platform-install-update.md` | install/update commands |
| `07-db-refresh.md` | WordPress DB export/import: gates, maintenance mode, acceptance checks |
