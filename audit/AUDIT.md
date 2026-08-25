# webhosting-scripts — architecture audit

A static, read-from-source audit. Nothing was executed and no code left the machine. It describes the
repo as of the HEAD recorded in `audit/.context-state.json`; it does **not** describe the live state of
any server.

- **Digest for agents:** [CONTEXT.md](CONTEXT.md) (load this every turn)
- **Graph:** [graph.json](graph.json) — 58 nodes, 108 edges
- **Viz:** [knowledge-graph.html](knowledge-graph.html) — open in a browser, fully offline
- **Traces:** `traces/` — line-by-line walkthroughs, populated by `/audit-repo`

---

## 1. What this is

`webhosting-scripts` is the operations toolkit for Faith FM's Laravel Forge / LEMP web-hosting
servers. It is checked out once per server at `/home/shared/webhosting-scripts`, and `wh.sh` is
symlinked to `/usr/local/bin/wh` so every user on the box gets the same `wh <command>` interface.

Its central idea: **derive the site and project context from where you are standing**, so that the
deployment scripts wired into Laravel Forge and git post-receive hooks can be two or three lines long.

## 2. Architecture

```
  Forge deploy script  ─┐                       ┌─→  wh-scripts/wh-<cmd>.sh   (bash, nvm exported)
  git post-receive hook ├─→  wh  (wh.sh)  ──────┤
  interactive shell    ─┤     ├ derives WH_*    └─→  wh-scripts/wh-<cmd>.py   (python, venv activated)
  /etc/cron.d/wh       ─┘     │
                              ├── /etc/nginx/sites-available/<site>   → WH_SITE_VALID, WH_WEBROOT_DIR, WH_PHP_CMD
                              ├── ancestor .git walk                  → WH_PROJECT_DIR, WH_LARAVEL/VITE/VUE flags
                              ├── <project>/.env                      → WH_APP_NAME
                              └── .python-version + venv/             → python command runtime
```

There is no framework and no shared library: coupling between commands is by **invoking `wh <other>`**
(or, for `wh-docker-get-context.sh`, by being `source`d). The dispatcher is therefore the only place
that "knows" anything, and it is the single highest-leverage file in the repo.

## 3. Layer by layer

### Entry — `wh.sh` and its three installed siblings
`wh.sh` does all context detection then hands off. Three details are easy to miss:

- When the CWD is exactly `$HOME`, it scans for a domain-shaped subfolder and uses that instead. The
  loop has no `break`, so the **last** match wins — a user hosting several sites gets whichever sorts
  last under the shell glob.
- `WH_PHP_CMD` detection has three stages: `fastcgi_pass` in the site file → `fastcgi_pass` in an
  included `forge-conf/*/site.conf` → discard anything not matching `^php[0-9.]*$`. That last guard
  is what keeps a TCP `fastcgi_pass 127.0.0.1:9000` from producing a garbage command name.
- The project-dir walk keeps overwriting `WH_PROJECT_DIR` as it ascends, so it ends up at the
  **highest** ancestor containing `.git`, not the nearest one.

`wh.bash_completion`, `wh.crond` (installs to `/etc/cron.d/wh`) and `wh.pyenv-profile.d` (installs to
`/etc/profile.d/pyenv.sh`) are copied into place by `wh update`.

### Deploy
`wh-checkout-github.sh` and `wh-checkout-PR.sh` are the two entry points, matching the two deployment
mechanisms described in the deployment README. Both delegate the actual git work to `wh git`, which
is what lets a WordPress bare-repo checkout and a normal Laravel in-place checkout share one script.
`--MASTER-BRANCH-ONLY` on `checkout-PR` is the production guard: it matches `ref` against `.*/master$`
per pushed ref.

`wh-composer-deploy.sh` is the largest script and the one most worth reading in full. Its sequencing
matters: composer install → Laravel artisan hooks → conditional npm build → fpm reload → New Relic
capture. The npm build is gated on `.gitignore` containing `public/build`, which is an indirect way of
asking "does this project build its front-end at deploy time?".

### Helpers
`wh-php.sh` / `wh-composer.sh` are the multi-PHP wrappers. `wh-git.py` is the repo/work-tree resolver.
`wh-fpm-reload.sh` is the concurrency guard. `wh-docker-get-context.sh` is a sourced validator.
These are the pieces other commands compose from.

### Docker
A thin wrapper over `docker compose`, with project configuration expressed entirely in the project's
`.env`: `DOCKERFILE_TEMPLATE` and `DOCKERCOMPOSE_TEMPLATE` name shared templates in `docker/`, which
are copied over the project's own `Dockerfile` / `docker-compose.yml` at deploy time. Only the
`express01` pair is currently in the repo, though `wh-docker-get-context.sh`'s docs reference
`express03`/`express05`. `wh-docker-summary.py` is the fleet-level view, reconciling each project's
`DOCKER_PORT` against the `proxy_pass` port nginx actually uses.

### Backup
Thin wrappers over `restic` + `resticprofile`; all real configuration lives in
`~/.config/resticprofile/profiles.yaml`, which `wh bup-config` opens in nano and then reschedules.

### Observability
A two-stage design that exists because deployment scripts run as the *site* user, but the New Relic
API key must not be readable by site users. Stage 1 (`capture`, site user) writes a JSON file into a
sticky-bit spool; stage 2 (`forward`, forge, every minute via cron) reads the key and posts to New
Relic. The forwarder's retry policy distinguishes *permanent* parse failures (60 s grace, in case the
file was caught mid-write) from *transient* API failures (7 days), and quarantines rather than
deletes.

### DB refresh
`wh db-refresh-export` / `wh db-refresh-import` refresh a staging WordPress site from a sibling
production site on the same box, replacing third-party DB-sync plugins. The two halves run as
*different unix users* and never trust each other's environment — everything passes through one
mode-600 `/tmp` bundle carrying a single `setfacl` read grant and a TTL, plus a manifest the import
side uses for its gates and parity checks.

The import is the more interesting of the pair: it is gated (nothing is written unless the manifest's
source URL matches the target's config, the hand-off is fresh, the prefix matches, and the excluded
tables really are absent), it holds the site in WordPress maintenance mode across the whole
inconsistent window with a keepalive that re-stamps `.maintenance` every 4 minutes, and it brings the
site back up **only** if every *safety* check passed — an unfenced clone stays down with a far-future
stamp rather than being served. Options are read straight from MySQL rather than `get_option()`
throughout, so a persistent object cache cannot turn the acceptance checks into vacuous passes.

Site-specific behaviour lives in an unversioned `.wh-db-refresh` beside the target site, the same
pattern as `wh-git-repos.yml` — generic script, per-site config on the box.

### Platform
Install/update commands. `wh update` is the one that runs routinely — it self-updates the repo and
re-asserts every installed artefact and permission, so it doubles as a convergence step for servers
that have drifted.

## 4. Design notes and rough edges

Behaviour worth knowing before changing any of these scripts. Read statically at one commit — none of
it was reproduced on a live server.

**Deliberate design choices that can surprise:**

- **`wh php` / `wh composer` fall back rather than fail.** When `WH_PHP_CMD` is unset or its binary is
  absent, both warn on stderr and run the default PHP. This is the right call — a hard failure would
  break deploys on any site whose nginx config doesn't parse the way the detector expects — but in a
  deploy script whose stderr nobody reads, a site can be rebuilt against the default PHP version with
  no visible failure. `wh show-env` is the check.
- **Docker templates are the source of truth.** `wh docker-copy-config` unconditionally copies over a
  project's `Dockerfile` and `docker-compose.yml` on every deploy, so per-project edits to those two
  files don't survive. Intended, but not reversible — customisation belongs in a new template.
- **`wh update` hard-resets the shared repo** to `origin/master`, discarding local changes made on the
  server. That is what makes it a convergence step for drifted servers.
- **Installers follow upstream vendor procedures.** `wh-update-nvm.sh`, `wh-docker-install.sh` and
  `wh-bup-install.sh` each reproduce their project's documented install steps rather than inventing
  one. They are manual, interactive commands — nothing runs them automatically — so they are best
  reviewed against upstream docs whenever those change.

**Rough edges worth a look:**

- **`wh-bup-install.sh:34` looks incorrect.** `curl … | tar -xz > ~/resticprofile` extracts to the
  *current directory* and captures only tar's (empty) stdout, so the following
  `mv ~/resticprofile /usr/local/bin` may move an empty file while the real binary is left behind. The
  restic line above it (`| bunzip2 >`) is correct; only resticprofile has this shape. Confirm on a
  server before relying on this for a fresh install.
- **Home-folder site detection is order-dependent.** Neither `wh.sh:17-23` nor `wh-git.py:117-120`
  breaks out of its loop, so both keep the **last** matching subfolder — but `wh.sh` iterates a sorted
  shell glob while `wh-git.py` iterates `os.listdir()`, whose order is arbitrary. Irrelevant for a
  single-site user; for a multi-site user invoking a command from `$HOME` the two can select different
  sites, and the python side is not stable between runs. (`switch_home_to_site_folder`'s docstring
  says "first subdirectory", which the code does not do.)
- **`wh fpm-reload` skips rather than waits.** Losing the `/tmp/fpmlockdir` race means exit 1 and no
  reload. Because it is the second-last step of `composer-deploy`, that exit code isn't what the
  deploy reports, so two near-simultaneous deploys can leave one site serving old opcached code.
- **No tests or CI for the scripts themselves.** The GitHub Actions workflow installed alongside this
  audit only refreshes the context map.

## 5. Limits of this audit

Read from source at one commit. Nothing was executed; no server was inspected; server-side state
(`wh-git-repos.yml` contents, `profiles.yaml`, actual nginx configs, installed PHP versions) is
described from what the scripts expect, not from what is there. Run `/audit-repo` for the
line-by-line traces and a severity-rated risk register.
