# db-refresh HOWTO — refresh a WordPress site's database from a sibling site

Two `wh` commands replace third-party DB-sync plugins for the common case of **two WordPress sites on the same server under different unix users** (eg: production and staging): one exports, the other imports. The database never leaves the box, no root is needed, and the importing user can't reach the source site at all — so the worst possible mistake is damage to the *target*, which a re-run fixes.

```
        source site (user A)                                   target site (user B)
  ┌──────────────────────────────┐                      ┌──────────────────────────────┐
  │ cd ~/app.example.com         │                      │ cd ~/app-staging.example.com │
  │ wh db-refresh-export \       │   /tmp/db-refresh-…  │ wh db-refresh-import \       │
  │    --grant-user=B \          │ ───────────────────▶ │    /tmp/db-refresh-….tar.gz  │
  │    --exclude=<queue table>   │  mode 600 + ACL for  │                              │
  │                              │  user B only         │ reads ~/app-staging…/.wh-db-refresh
  │ READ ONLY (no table locks)   │                      │ import → truncate → update-db │
  │ dump + manifest, gate:       │                      │ → search-replace URLs → cache │
  │ "-- Dump completed"          │                      │ → PASS/FAIL acceptance        │
  └──────────────────────────────┘                      └──────────────────────────────┘
```

## One-time setup on the target site

Copy the sample config beside the target site (outside the webroot, never in git — it survives every refresh because only the *database* is replaced):

```bash
cp /path/to/webhosting-scripts/db-refresh/.wh-db-refresh.sample ~/app-staging.example.com/.wh-db-refresh
nano ~/app-staging.example.com/.wh-db-refresh     # fill in SOURCE_URL etc - see the comments in the file
```

The config carries everything site-specific — the source URL, which tables to truncate/require-excluded (an outbound queue, typically), and an optional clone-guard canary option. The scripts themselves contain no site details.

## Each refresh

```bash
# 1 — as the source site's user, inside its folder   (in tmux: a dropped SSH must not kill a dump)
cd ~/app.example.com
wh db-refresh-export --grant-user=app-staging-user --exclude=wp_some_queue_table

# 2 — as the target site's user, inside its folder   (in tmux)
cd ~/app-staging.example.com
wh db-refresh-import /tmp/db-refresh-app.example.com-<timestamp>.tar.gz

# 3 — read the PASS/FAIL/WARN lines; act on WARNs (see below); log in again; browser-check the site
#     (the target is in maintenance mode for the run and comes back up only when the safety checks pass;
#      cleanup is automatic - see below)
```

## Cleanup — automatic by default

Every copy of the dump is a full copy of the source database, and the hand-off is the *only* thing that ever bridges the two sites — so its removal must not depend on anyone remembering:

| Copy | Who owns it | What happens |
|---|---|---|
| `/tmp/db-refresh-….tar.gz` (hand-off) | source user | **self-destructs** after `--ttl` minutes (default 120) via a detached timer the export starts; delete sooner by hand any time. `--ttl=0` disables it — then it's yours. |
| target's unpacked dump (private `/tmp` temp dir) | target user | **deleted on every exit** — PASS, FAIL, and Ctrl+C alike (EXIT trap). A FAIL keeps only the small manifest + log for diagnosis; a re-run uses the hand-off (still in `/tmp` until its TTL) or a fresh export |
| target's `~/.wh-db-refresh/….import.log` + `.manifest` | target user | kept — the search-replace reports and the expected counts; no database content; delete once recorded |
| `--keep-dump` copy → `~/.wh-db-refresh/<name>/` | target user | **the one automatic-looking path that writes a dump into `~`** — explicit opt-in only, printed with a warning; yours to delete promptly |
| source `~/.wh-db-refresh/` copies | source user | only exist with `--keep-local`; yours to delete |

Only a file's owner can delete it under a sticky `/tmp`, so the importer's read grant can never remove the hand-off — that's why the exporter side self-cleans rather than relying on the importer. Every failure path in the export removes what it created (EXIT trap); no failed run leaves a dump behind.

**The rule: no automatic path ever leaves a copy of the source database outside `/tmp`, and nothing in `/tmp` outlives the run except the exporter's TTL'd hand-off.** Backup tooling routinely includes `/home` and routinely excludes `/tmp` — a dump sitting in `~` for even a few minutes can be captured by a scheduled backup and shipped off-box, silently breaking "the database never leaves the server". Only the two explicit opt-ins (`--keep-local` on export, `--keep-dump` on import) write a dump into `~/.wh-db-refresh/`. Before the first run, check your backup profile (eg: `~/.config/resticprofile/profiles.yaml` for `wh bup`) does **not** include `/tmp` — and if you ever use those opt-ins, either exclude `~/.wh-db-refresh/` there too or delete the copies before the next backup runs.

## What the import checks (and what it leaves to you)

| Line | Meaning | If not PASS |
|---|---|---|
| dump complete · manifest matches config · hand-off age · prefix matches · required exclusions present · truncate targets exist · core files direction (target ≥ source) | **Gates** — nothing is imported unless all pass | fix the cause, re-run |
| every rewrite pass exited clean · db schema at the version the core files expect · siteurl is this site · truncated tables empty · row counts vs manifest · dry-run 0 | the import + rewrite worked | FAIL ⇒ re-run the whole refresh (idempotent) |
| clone-guard canary decodes to source URL *(only if configured)* | the target still sees itself as a clone ⇒ outbound stays blocked | FAIL ⇒ **stop; do not let the site send anything** until understood |
| target-only tables survived | an import only replaces tables *in* the dump; strays live on | **WARN** — review, then drop deliberately |
| views the source has that the target lacks | dumps never carry views; code reading them fails *silently* | **WARN** — recreate from `SHOW CREATE VIEW` on the source, minus `DEFINER` |
| persistent object cache detected *(gate, via `wp cache type`)* | the import resets it right after the import **and** after the rewrites — raw-SQL writes never invalidate it. Default = `wp cache flush` (per-DB-index for Redis, whole-instance for Memcached); if this site shares the *same* Redis index or Memcached instance with the source, that reaches the source's cache. An *unknown* backend fails closed (no instance-wide flush) | **WARN** — confirm separate DB indexes/instances. `SKIP_CACHE_FLUSH=true` is a one-run **stopgap**: only `alloptions`/`notoptions` are invalidated, and posts/users/terms/meta keep pre-import values *indefinitely* if the cache has no TTL — the fix is a separate Redis DB index. All acceptance checks read MySQL directly, so neither mode can hollow them out |
| users imported · cron events inherited · `DISABLE_WP_CRON` state | facts about what the site now holds (below) | **INFO** — act as your setup requires |

The tool **detects and reports; it never drops tables, creates views, clears the cron schedule (unless `CLEAR_CRON=true`), or opens outbound.** Those are human decisions.

## The target is in maintenance mode for the whole run

From the first `DROP TABLE` to the last rewrite the target's database is inconsistent — and every HTTP request would also spawn WP-Cron against the source's freshly imported schedule. So the import puts the site into WordPress's own maintenance mode (the `.maintenance` file: a 503 in `wp-settings.php`, before plugins load, before cron can spawn) right before the import and lifts it **only through one path: every SAFETY check passed** — import complete, truncated tables empty, host rewritten (an un-rewritten `siteurl` equals the source's, so a clone guard keyed on it sees *no* clone and outbound is open), canary armed. Ordinary FAILs (a count drift, a missing view) don't keep the site down; an unfenced clone does.

Mechanics worth knowing:
- **wp-cli exempts itself** from maintenance mode (it hooks `enable_maintenance_mode`), so every step still runs. If it ever didn't, the rewrite commands would die visibly, the sentinels would FAIL, and the site would *stay* in maintenance — the failure direction is safe. **Confirm on the first supervised run** that the steps ran under maintenance rather than taking this on faith.
- WordPress ignores a `.maintenance` stamp older than 10 minutes (its own safety net). A **keepalive re-stamps it every 4 minutes** while the script lives, so a long import stays covered — and a *hard-killed* run (SIGKILL, no trap) self-recovers within ~15 minutes.
- **Ctrl+C, an import failure, or a safety FAIL leave the site down on purpose**, with a far-future stamp WordPress never lifts, and print the recovery: fix and re-run (a passing run lifts it), or `rm <webroot>/.maintenance` by hand.
- If you drive WP-Cron from **system cron via wp-cli** (`wp cron event run`), that path is exempt too — pause it for the run.
- Your own admin session on the target is 503'd for the run's few minutes; it died with the import anyway (usermeta is replaced) — log in again after.

## What the target now contains — read this once

A faithful clone is faithful about everything. After a refresh the target holds, from the source:

- **Every user account with its password hash and role** — the source's logins now work on the target, with the same privileges. If the target is a developers-only environment, restrict access at the web-server level (IP allowlist / basic auth) — that survives refreshes; demoting users in the database does not (the next refresh restores them).
- **Every credential stored in `wp_options`** — SMTP passwords, API keys, OAuth secrets, licence keys, integration tokens. Rotating a secret on the source does **not** rotate the target's copy until the next refresh — and until then the target can *use* those secrets. This is why outbound must be structurally blocked on a clone (the clone-guard pattern), not merely "not expected".
- **The source's WP-Cron schedule** (`wp_options.cron`) — the target will start running the source's scheduled jobs against the imported data on its next page load, for every plugin. A queue exclusion + truncate covers one channel; cron is a second one. Options: rely on the clone-guard blocking every outbound path those jobs could take (know your plugins), set `DISABLE_WP_CRON` on the target, or `CLEAR_CRON=true` in the config.
- **Historical content** — old emails, conversations, logs — that legitimately embeds the source's URLs in encoded forms (base64 tracking links, mail headers) which the rewrite cannot and should not touch. Expected; a deeper sweep is a one-off certification, not a per-refresh check.

## Safety model, in one paragraph

The source is only ever *read* (`--single-transaction`, no locks, no downtime). The hand-off is created under `umask 077` — mode 600 from its first byte — with a `setfacl` grant to exactly one other user; no third user can read it at any moment, and it never crosses the network. The importing user holds no credentials for the source database, so it physically cannot write to production **through the database** — the guarantee stops at shared infrastructure: a persistent object-cache instance shared between the two sites is reachable by `wp cache flush` (hence the `object-cache.php` gate warning and `SKIP_CACHE_FLUSH`), and anything else the two sites share (a mail relay, a search index) is outside this tool's promise. Everything else — the exclusion of outbound queues, the truncate, the required-exclusion gate, the cron handling, the canary check — exists so that a freshly refreshed clone cannot start processing production's pending work: that failure mode is the reason this tooling exists.

## Notes

- **Silence is not a hang.** The import prints nothing for a minute or more, and the search-replace runs a few minutes with no output on a large database. Don't Ctrl+C.
- **`wp` runs under the site's own PHP** (`WH_PHP_CMD`, from nginx) — the same mechanism as `wh php`. On multi-PHP servers plain `wp` may run under an older CLI PHP that current plugins refuse.
- **`update-db` direction rule:** the target's core *files* must be ≥ the source's before its data arrives; the gate enforces it. Update the target's core files first if it fails.
- **Object cache and reads:** every `wp` call is a fresh PHP process, so a persistent object cache is exactly the state that survives between them — and the import's raw-SQL writes never invalidate it. That is why the cache is reset immediately after the import (so `update-db` migrates against the *imported* `db_version`, not the target's cached old one) and again at the end (in between, any WP boot re-caches the *source's* URLs), and why every acceptance check reads `wp_options` straight from MySQL rather than through `get_option()`.
- **Host names must not nest.** The URL rewrite is one `str_replace` pass, which never rescans its own output — so it is safe unless the *target's* host contains the *source's* (`example.com` → `staging.example.com`), where any pre-existing `staging.example.com` text carried in the source's data would be hit by the same pass and double-prefixed. That shape is **refused up front** with a message naming both hosts; pick names where the target does not contain the source (`app.example.com` → `app-staging.example.com`). The reverse direction (`staging.example.com` → `example.com`) cannot self-hit and is fully supported. Sub-directory installs (a path after the host) are refused too.
- **Views:** never in a per-table dump. Once recreated on the target they persist across refreshes.
- **Row counts** are taken just before the dump, so a live source can drift a little either way by the time the import counts again — `ROW_DRIFT_PCT` absorbs that; it is not a defect signal on churny tables like `wp_options`.
