# webhosting-scripts — agent context digest

<!-- CTXMAP:START — managed by refresh-context.sh, do not edit between these markers -->
**Freshness:** HEAD `6d5e403` · refreshed 2026-08-25T23:16:29Z (deterministic refresh — no LLM, no egress).

✅ **In sync** — the digest below reflects the code as of `6d5e403`.
<!-- CTXMAP:END -->

Faith FM's `wh` command suite for Laravel Forge / LEMP web-hosting servers. A bash dispatcher
auto-detects site + project context from the filesystem and nginx config, then routes to one script
per command. Deployed to `/home/shared/webhosting-scripts`; `wh` is a symlink to `wh.sh`.

**Stack:** bash (26 scripts) + python 3 (5 scripts, run under the repo `venv/`, pinned by
`.python-version` via a shared pyenv at `/home/shared/.pyenv`). No build, tests, or CI. Python deps:
PyYAML, requests, python-dotenv, tabulate.

**How a command runs:** `wh <cmd> [args]` → [wh.sh](../wh.sh) computes the `WH_*` environment → execs
`wh-scripts/wh-<cmd>.sh` (bash, nvm pre-exported) **or** `wh-scripts/wh-<cmd>.py` (python, venv
activated). Dropping a file into `wh-scripts/` is the only step to add a command — the usage list and
bash completion both derive from `ls wh-scripts/wh-*`.

## The environment contract (wh.sh — read this first)

Everything downstream depends on these, all derived in [wh.sh](../wh.sh):

- `WH_USER` / `WH_SITE` — from the `/home/<user>/<site>` path of the CWD. If CWD is `$HOME`, the first
  domain-shaped subfolder is searched instead.
- `WH_SITE_VALID` / `WH_WEBROOT_DIR` — existence + `root` directive of `/etc/nginx/sites-available/$WH_SITE`.
- `WH_PHP_CMD` / `WH_PHP_VERSION` — first `fastcgi_pass` in that nginx file, else in the included
  `forge-conf/*/site.conf`; sanity-checked against `^php[0-9.]*$`.
- `WH_WP_PHAR` — the wp-cli **phar** behind `wp` on PATH (machine-wide, not per-site). Only a real
  phar counts: anything else — a shell wrapper, a stub — leaves it **empty**, and `wh wp` and
  db-refresh fail closed. Never hand a wrapper to PHP: PHP strips the `#!` line and echoes the rest
  as text, so a caller parsing the output gets plausible garbage instead of an error.
- `WH_PROJECT_DIR` / `WH_PROJECT_ENV` / `WH_APP_NAME` — highest ancestor dir containing `.git`; `APP_NAME` from its `.env`.
- `WH_LARAVEL_DETECTED` / `WH_VITE_DETECTED` / `WH_VUE2|3_EXTRA_BUILD` — presence of `artisan`,
  `vite.config.*`, `vue2/package.json`, `vue3/package.json`.

`wh show-env` prints all of them — first diagnostic for any misbehaving site.

## Layer map

**Entry** `wh.sh`, `wh.bash_completion`, `wh.crond`, `wh.pyenv-profile.d`
**Deploy** `wh-checkout-{github,PR}.sh`, `wh-composer-deploy{,-sessions}.sh`
**Helpers** `wh-{php,composer}.sh`, `wh-git.py`, `wh-fpm-reload.sh`, `wh-docker-{get-context,copy-config}.sh`
**Docker** `wh-docker-{deploy,down,summary}.{sh,py}` + `docker/template *`
**Backup** `wh-bup*.sh` · **Observability** `wh-nr-deployment-{capture,forward}.py`
**DB refresh** `wh-db-refresh-{export,import}.sh` + `db-refresh/.wh-db-refresh.sample`
**Platform** `wh-update.sh`, `wh-python-update.sh`, `wh-update-nvm.sh`, `wh-{docker,bup}-install.sh`, `wh-git-config.sh`, `wh-bup-selfupdate.sh`
**Diag** `wh-show-env.sh`, `wh-hello{,-python}`

## Core flows

**Deployment** — triggered by a Forge deploy script (GitHub webhook) or a server-side git
post-receive hook; see [README - deployment](<../README - deployment (checkout, composer, fpm-reload).md>):

```
wh checkout-github [branch]           → wh git fetch / checkout -f / reset --hard origin/<branch>
wh checkout-PR [--MASTER-BRANCH-ONLY] → reads oldrev/newrev/ref on STDIN → wh git checkout -f + clean -f -d
        ↓
wh composer-deploy(-sessions)  [sessions: first rm storage/framework/sessions/*]
   → wh composer install → [Laravel: wh php artisan queue:restart, cache:clear]
   → [if .gitignore has public/build: nvm install/use, npm ci, npm run prod|build; repeat in vue2/, vue3/]
   → wh fpm-reload → wh nr-deployment-capture
```

**Deployment markers:** `capture` writes `/var/log/app-deploys/<epoch>-<user>.log` (JSON, 0644) into a
`forge:forge` **1777+sticky** spool, so site users can add but not delete each other's files.
`wh.crond` runs `forward` as forge every minute: resolve the APM entity GUID for `PHP-H <app>` /
`PHP-N <app>`, post a `changeTrackingCreateDeployment` mutation, delete on success, quarantine to
`errors/` after 60 s (parse failure) or 7 days (API failure).

**Multi-PHP:** each server runs several PHP versions and the CLI default is often older than a given
site's. `wh php` / `wh composer` exec `$WH_PHP_CMD` so `vendor/` and composer scripts match the
runtime the site serves. Both warn to stderr and **fall back to the default** when `WH_PHP_CMD` is
unset/missing — a silent-wrong-version risk; confirm with `wh show-env`.

**wp-cli:** one current phar per server at `/usr/local/bin/wp` (`root:root`), installed/updated by
`wh wp-install`; nothing is per-site because wp-cli is version-agnostic toward WP core. `wh wp` execs
`$WH_PHP_CMD $WH_WP_PHAR --path=$WH_WEBROOT_DIR` — wp-cli *boots* the site's WordPress in-process, so
every plugin and migration runs under whichever PHP started the phar. It **fails closed** where
`wh php`/`wh composer` fall back: that pair runs your code, this runs the site's.

**Docker:** `wh docker-deploy` → `wh docker-copy-config` sources `wh-docker-get-context.sh`, which
sources the project `.env` and resolves `DOCKERFILE_TEMPLATE`/`DOCKERCOMPOSE_TEMPLATE` into
`docker/template <name> …`. Those templates overwrite the project's `Dockerfile` and
`docker-compose.yml` **on every deploy**, then `docker compose up --build --detach`.

**DB refresh** (`wh db-refresh-export` → `wh db-refresh-import`) clones a WordPress database from a
sibling site on the same server, prod → staging. The halves run as different unix users and share only
a mode-600 `/tmp` bundle with one `setfacl` read grant and a TTL. The import reads its gates from an
unversioned `<site>/.wh-db-refresh`, holds the site in WordPress maintenance mode across the import,
and **lifts it only if every safety check passes** — an unproven clone stays 503 rather than being
served. See AUDIT.md §3.

**WordPress checkouts** depend on `wh-git-repos.yml` in the user's home folder, pairing each bare repo
(`git/plugins/*.git`) with its working tree (`htdocs/wp-content/plugins/*`). A bare repo missing there
will not deploy.

## Pointers

- `wh update` hard-resets the repo to `origin/master`, and re-applies `/var/log/app-deploys`
  ownership/permissions every run so existing servers get corrected.
- `wh-fpm-reload.sh` uses `mkdir /tmp/fpmlockdir` as a mutex and **exits 1** rather than waiting.
- `wh-git.py` matches config paths directory-boundary-safely (`my-plugin-v2` ≠ `my-plugin`) and
  propagates git's exit code. `wh-nr-deployment-capture.py` strips git's `--local-env-vars` so it
  works inside post-receive hooks.
- The three installers (`wh-update-nvm.sh`, `wh-docker-install.sh`, `wh-bup-install.sh`) reproduce
  their upstream projects' documented install steps; they are manual commands, never automated.
  `wh-bup-install.sh:34` looks incorrect — see AUDIT.md §4.

## Map files

`audit/graph.json` (58 nodes / 108 edges, `jq`-queryable) · `audit/knowledge-graph.html` (offline viz)
· `audit/AUDIT.md` (fuller overview) · `audit/traces/` (populated by `/audit-repo`; node `trace`
fields are empty until then).
