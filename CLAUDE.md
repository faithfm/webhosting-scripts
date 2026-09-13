# CLAUDE.md — webhosting-scripts

Faith FM's `wh` command suite for Laravel Forge / LEMP web-hosting servers: a bash dispatcher
([wh.sh](wh.sh)) derives the `WH_*` environment from the filesystem and nginx config, then routes
`wh <cmd>` to one script in `wh-scripts/`. Deployed to `/home/shared/webhosting-scripts` on every
server by `wh update`, which is a hard reset to `origin/master`.

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
- `wh show-env` prints the full `WH_*` environment — the first diagnostic for any misbehaving site.

## Local context map (optional, never committed)

`audit/` is gitignored. On a machine where it exists it holds a local knowledge graph and digest of
this repo — read `audit/CONTEXT.md` first when it is present; when it is absent, start from `wh.sh`.
