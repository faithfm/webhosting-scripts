#!/bin/bash

# Import a hand-off bundle made by 'wh db-refresh-export' into the current site's WordPress
# database, re-point URLs, and run the acceptance checks - ie: refresh a staging/dev site from a
# sibling production site on the same server.  Replaces third-party DB-sync plugins.
#
# Run as the TARGET site's own user, from inside its site folder:
#
#   cd ~/app-staging.example.com
#   wh db-refresh-import /tmp/db-refresh-app.example.com-20260101T0000Z.tar.gz
#
# Site-specific behaviour comes from a config file in the target site's folder - never from
# hardcoded defaults - so this script stays generic and the config lives (unversioned) on the box:
#
#   ~/app-staging.example.com/.wh-db-refresh      (see db-refresh/.wh-db-refresh.sample in this repo)
#
# What it does:
#   1. GATES (nothing is imported unless all pass): config valid · hand-off is a dump+manifest pair
#      unpacked into a private temp dir · dump complete · manifest source_url == config SOURCE_URL ·
#      hand-off younger than MAX_HANDOFF_AGE_HOURS · table prefix matches · EXPECT_EXCLUDED tables
#      were left out of the dump · TRUNCATE_TABLES exist · target core files >= source (never let
#      older core files run update-db over newer data) · free space
#   2. puts the site into WordPress maintenance mode (503 before plugins/cron; wp-cli is exempt), then
#      imports (each table DROP+CREATE'd from the dump) · resets the object cache · truncates
#      TRUNCATE_TABLES · optionally clears the inherited cron schedule · core update-db
#   3. re-points URLs, serialized-safe: ONE host pass (source host -> this host), plus a scheme-fix
#      pass when the two sites differ in http/https.  (Refuses up front if THIS site's host contains
#      the source's - that shape needs protection this tool deliberately does not implement.)
#   4. ACCEPTANCE - each printed as PASS/FAIL/WARN/INFO, exit code 1 if anything FAILs:
#        db schema at the version these core files expect · siteurl is this site · truncated tables
#        empty · key row counts vs manifest · table-set parity vs manifest (target-only leftovers
#        reported, NOT dropped) · views the source has that this site lacks (reported, NOT created) ·
#        optional clone-guard canary (CANARY_OPTION must base64-decode to SOURCE_URL = guard armed) ·
#        dry-run: no plain-text source-host references remain · INFO: users now valid here, cron
#        events inherited from the source's schedule, DISABLE_WP_CRON state
#   4b. lifts maintenance mode ONLY if every SAFETY check passed (import complete · truncates done ·
#      host rewritten · canary armed); otherwise the site stays down (far-future stamp) and the
#      recovery command is printed - an unfenced clone is never served
#   5. CLEANUP - on PASS it deletes its own unpacked dump + manifest at once (they are a full copy of
#      the source database; the rollback layer is the DB platform's PITR, never a loose dump - and
#      "re-run the refresh" is the fix for anything that went wrong). On FAIL it keeps them for
#      diagnosis and says so.  --keep-dump keeps them regardless.  The import log is always kept
#      (it holds the search-replace reports you'll want to record).  The /tmp hand-off belongs to
#      the exporting user and self-destructs on the TTL 'wh db-refresh-export' set.
#
# What it deliberately does NOT do: drop stray tables, create views, clear the inherited cron
# schedule (unless CLEAR_CRON=true), or open outbound - those are human decisions.  It detects and
# reports; the operator acts.
#
# The old admin session on the target dies with the import (usermeta is replaced) - log in again.

set -uo pipefail
umask 077

fail() { echo "wh db-refresh-import: ERROR: $1" >&2; exit 1; }
FAILS=0; WARNS=0
pass() { printf '  PASS  %s\n' "$1"; }
info() { printf '  INFO  %s\n' "$1"; }
warn() { printf '  WARN  %s\n' "$1"; WARNS=$((WARNS+1)); }
flunk(){ printf '  FAIL  %s\n' "$1"; FAILS=$((FAILS+1)); }
# a SAFETY failure means the clone is not proven fenced - the site is not brought back up (see mm_* below)
SAFETY_FAILS=0
flunk_safety(){ flunk "$1"; SAFETY_FAILS=$((SAFETY_FAILS+1)); }

# ---- args --------------------------------------------------------------------------------------
HANDOFF=""; KEEP_DUMP=false
for arg in "$@"; do
    case "$arg" in
        --keep-dump) KEEP_DUMP=true ;;
        --*)         fail "unknown option '$arg'" ;;
        *)           [[ -z "$HANDOFF" ]] && HANDOFF="$arg" || fail "unexpected extra argument '$arg'" ;;
    esac
done
[[ -n "$HANDOFF" ]] || fail "usage: wh db-refresh-import <hand-off .tar.gz from wh db-refresh-export> [--keep-dump]"
[[ -r "$HANDOFF" ]] || fail "cannot read '$HANDOFF' (was it exported with --grant-user=$USER ? has its TTL expired?)"

# ---- site context (from wh.sh) -----------------------------------------------------------------
[[ "${WH_SITE_VALID:-false}" == true ]] || fail "no site detected - cd into the TARGET site's folder first (check 'wh show-env')"
[[ "${WH_USER_VALID:-false}" == true ]] || fail "run this as the site's own user ($WH_USER), not as $USER"
[[ -n "${WH_PHP_CMD:-}" ]] || fail "site PHP version not detected (WH_PHP_CMD empty - check 'wh show-env')"
WEBROOT="$WH_WEBROOT_DIR"
[[ -f "$WEBROOT/wp-config.php" ]] || fail "no wp-config.php in detected webroot '$WEBROOT'"
WP_BIN=$(command -v wp || true); [[ -n "$WP_BIN" ]] || fail "wp-cli ('wp') not found in PATH"
WP="$WH_PHP_CMD $WP_BIN --path=$WEBROOT"
wpq() { $WP "$@" 2>/dev/null </dev/null; }

# ---- config (site-specific, lives beside the site, never in this repo) -----------------------------
SITE_DIR="/home/$WH_USER/$WH_SITE"
CONFIG="$SITE_DIR/.wh-db-refresh"
[[ -f "$CONFIG" ]] || fail "no config at $CONFIG - copy $WH_BASE_DIR/db-refresh/.wh-db-refresh.sample there and fill it in"
SOURCE_URL=""; TRUNCATE_TABLES=""; CANARY_OPTION=""; EXPECT_EXCLUDED=""; ROW_DRIFT_PCT=1
MAX_HANDOFF_AGE_HOURS=24; CLEAR_CRON=false; SKIP_CACHE_FLUSH=false
# shellcheck disable=SC1090
source "$CONFIG"
[[ -n "$SOURCE_URL" ]] || fail "SOURCE_URL is not set in $CONFIG"
SOURCE_URL="${SOURCE_URL%/}"   # a trailing slash is legal in WP but would parse as a path component below
[[ "$ROW_DRIFT_PCT" =~ ^[0-9]+$ ]] || fail "ROW_DRIFT_PCT must be a whole number (got '$ROW_DRIFT_PCT')"
[[ "$MAX_HANDOFF_AGE_HOURS" =~ ^[0-9]+$ ]] || fail "MAX_HANDOFF_AGE_HOURS must be a whole number (got '$MAX_HANDOFF_AGE_HOURS')"
[[ "$CLEAR_CRON" == true || "$CLEAR_CRON" == false ]] || fail "CLEAR_CRON must be true or false"
[[ "$SKIP_CACHE_FLUSH" == true || "$SKIP_CACHE_FLUSH" == false ]] || fail "SKIP_CACHE_FLUSH must be true or false"
# names go into SQL unquoted (identifiers) or single-quoted (option name) - constrain them to a safe charset
# up front rather than escaping downstream
for t in ${TRUNCATE_TABLES//,/ } ${EXPECT_EXCLUDED//,/ }; do
    [[ "$t" =~ ^[A-Za-z0-9_]+$ ]] || fail "table name '$t' in TRUNCATE_TABLES/EXPECT_EXCLUDED has characters outside [A-Za-z0-9_]"
done
[[ -z "$CANARY_OPTION" || "$CANARY_OPTION" =~ ^[A-Za-z0-9_.:-]+$ ]] || fail "CANARY_OPTION '$CANARY_OPTION' has characters outside [A-Za-z0-9_.:-]"

# positive control: prove wp-cli actually answers before trusting any later "0" or empty result
# (stderr is suppressed everywhere below, so a broken wp would otherwise read as clean zeros).
# Options are read STRAIGHT FROM MYSQL throughout this script - never via 'option get' / get_option() -
# because a persistent object cache (Redis/Memcached drop-in) survives between wp-cli processes and is
# NOT invalidated by the raw-SQL writes the import performs; reading through it would return
# pre-import values and turn the checks below into vacuous passes.
PREFIX=$(wpq db prefix)
[[ -n "$PREFIX" ]] || fail "wp-cli could not read this site (empty table prefix) - is it healthy under $WH_PHP_CMD? Try: $WP db prefix"
# NOTE: a reader for SHORT single-line values only (siteurl, db_version, a base64 canary) - mysql batch
# output escapes tab/newline/backslash and 'head -n1' keeps one line, so do not reuse it for multi-line
# or backslash-bearing options (the cron array is read separately, via $wpdb). Option names are
# charset-validated above; the quote-doubling is belt-and-braces.
opt() { wpq db query "SELECT option_value FROM ${PREFIX}options WHERE option_name='${1//\'/\'\'}' LIMIT 1" --skip-column-names | head -n1 | tr -d '\r'; }
TARGET_URL=$(opt siteurl); TARGET_URL="${TARGET_URL%/}"
[[ "$TARGET_URL" == http* ]] || fail "could not read siteurl from the database (got '$TARGET_URL') - is the site healthy under $WH_PHP_CMD?"
[[ "$SOURCE_URL" != "$TARGET_URL" ]] || fail "SOURCE_URL equals this site's own URL ($TARGET_URL) - refusing: that would import a site over itself"

# URL parts. Sub-directory installs (a path after the host) are not supported by this version.
SOURCE_SCHEME="${SOURCE_URL%%://*}"; TARGET_SCHEME="${TARGET_URL%%://*}"
SOURCE_HOST="${SOURCE_URL#*://}";    TARGET_HOST="${TARGET_URL#*://}"
[[ "$SOURCE_HOST" != */* && "$TARGET_HOST" != */* ]] || fail "URLs with a path component (sub-directory installs) are not supported: source '$SOURCE_URL', target '$TARGET_URL'"
[[ "$SOURCE_HOST" != "$TARGET_HOST" ]] || fail "source and target have the same host with different schemes - not a refresh scenario this tool handles"
# The rewrite is ONE str_replace pass, and str_replace never rescans its own output - so source->target
# is safe whenever this site's host does not CONTAIN the source's. When it does (example.com ->
# staging.example.com), pre-existing "staging.example.com" text in the source data would be hit by that
# same pass and end up double-prefixed; guarding it needs a protect/restore round-trip that this tool
# deliberately does not implement, so the shape is refused instead. The reverse direction
# (staging.example.com -> example.com) cannot self-hit and is fully supported.
[[ "$TARGET_HOST" != *"$SOURCE_HOST"* ]] || fail "this site's host ('$TARGET_HOST') CONTAINS the source host ('$SOURCE_HOST') - not supported: the URL rewrite would double-prefix any pre-existing '$TARGET_HOST' text carried in the source's data. Use hosts where this site's does not contain the source's (eg: app-staging.example.com refreshed from app.example.com)."

# ---- unpack into a private temp dir (never trust ~ for "the newest dump") -----------------------------
TMPD=$(mktemp -d /tmp/wh-db-refresh-import.XXXXXX)   # mode 700
LOGDIR=~/.wh-db-refresh; install -d -m 700 "$LOGDIR"

# ---- maintenance mode -------------------------------------------------------------------------------
# From the first DROP TABLE to the last rewrite the database is inconsistent - and every HTTP hit would
# also spawn wp-cron against the source's schedule. WordPress' own .maintenance file closes all of that
# in wp-settings.php: a 503 before plugins load, before cron spawns. wp-cli exempts itself (it hooks the
# 'enable_maintenance_mode' filter), so every command below still runs. WordPress ignores the file once
# its stamp is >10 min old (its safety net against a crashed upgrade), so a keepalive re-stamps it every
# 4 min while this script lives: a long import stays covered, and a HARD-killed run (no trap) still
# self-recovers within ~15 min. The site comes back up ONLY through the explicit "safety passed" path at
# the end: import complete · truncates done · host rewritten · canary armed. Anything else - Ctrl+C,
# an import failure, a safety FAIL - leaves it in maintenance with a far-future stamp (WordPress then
# never lifts it on its own) and prints the recovery command; a successful re-run lifts it too.
MM_FILE="$WEBROOT/.maintenance"; MM_PID=""; MM_ON=false
mm_stamp(){ printf '<?php $upgrading = %s; ?>\n' "$1" > "$MM_FILE" 2>/dev/null && chmod 644 "$MM_FILE" 2>/dev/null; }   # 644: the FPM pool may run as another user
mm_on()   { mm_stamp "$(date +%s)" || fail "could not write $MM_FILE - refusing to import a live site"
            ( while kill -0 $$ 2>/dev/null; do sleep 240; kill -0 $$ 2>/dev/null && printf '<?php $upgrading = %s; ?>\n' "$(date +%s)" > "$MM_FILE" 2>/dev/null; done ) </dev/null >/dev/null 2>&1 &
            MM_PID=$!; MM_ON=true; }
# 'wait' after the kill: signalling is asynchronous, and a keepalive caught mid-write would otherwise
# land AFTER whatever its caller does next - re-creating .maintenance just after mm_off removed it (site
# down despite a PASS), or overwriting mm_hold's far-future stamp with a current one (WordPress lifts
# maintenance ~10 min later on a clone that was never proven fenced). Reaping here covers both callers.
mm_kill() { [[ -n "$MM_PID" ]] && { kill "$MM_PID" 2>/dev/null; wait "$MM_PID" 2>/dev/null; }; MM_PID=""; }
mm_off()  { mm_kill; rm -f "$MM_FILE"; MM_ON=false; }
mm_hold() { mm_kill; mm_stamp "$(( $(date +%s) + 30*24*3600 ))"; MM_ON=false
            echo "  ⚠ SITE LEFT IN MAINTENANCE MODE (503) - the clone is not proven safe to serve. Fix and re-run (a passing run lifts it), or lift by hand: rm -f $MM_FILE" >&2; }
# The temp dir - and with it the unpacked dump - is removed on EVERY exit, Ctrl+C included. No automatic
# path leaves a copy of the source database outside /tmp; only the explicit --keep-dump does (see cleanup).
cleanup() { $MM_ON && mm_hold; rm -rf "$TMPD"; }
trap cleanup EXIT
echo -e "\nwh db-refresh-import: target site $WH_SITE  (user $WH_USER, $WH_PHP_CMD)"
echo "  hand-off: $HANDOFF"
# Member names follow the export's convention (<bundle-name>.sql / .manifest). The manifest is the
# FIRST member, so extracting it alone (--occurrence=1 stops GNU tar at the first match) costs one tiny
# read of the stream - and it carries the dump's true byte size, which is what the free-space gate needs
# (gzip's own ISIZE trailer is 32-bit and wraps above 4 GiB - it cannot be trusted for this).
BASE=$(basename "$HANDOFF" .tar.gz); DUMP_NAME="$BASE.sql"; MAN_NAME="$BASE.manifest"
[[ "$BASE" == db-refresh-* && "$BASE" != "$(basename "$HANDOFF")" ]] || fail "'$HANDOFF' is not a db-refresh-*.tar.gz hand-off"
tar -xzf "$HANDOFF" -C "$TMPD" --occurrence=1 "$MAN_NAME" 2>/dev/null || tar -xzf "$HANDOFF" -C "$TMPD" "$MAN_NAME" 2>/dev/null \
    || fail "hand-off does not contain $MAN_NAME - not a bundle made by wh db-refresh-export (or renamed)"
MANIFEST="$TMPD/$MAN_NAME"; DUMP="$TMPD/$DUMP_NAME"
mf() { grep "^$1=" "$MANIFEST" | head -n1 | cut -d= -f2-; }   # manifest field
DUMP_B=$(mf dump_bytes)
[[ "$DUMP_B" =~ ^[0-9]+$ && "$DUMP_B" -gt 0 ]] || fail "manifest has no usable dump_bytes ('$DUMP_B') - re-export with a current wh db-refresh-export"
NEED_KB=$(( DUMP_B / 1024 * 11 / 10 + 51200 ))
FREE_KB=$(df -Pk /tmp | awk 'NR==2{print $4}')
[[ "$FREE_KB" =~ ^[0-9]+$ ]] || fail "could not determine free space in /tmp (df returned '$FREE_KB')"
(( FREE_KB >= NEED_KB )) || fail "not enough free space in /tmp to unpack: need ~$((NEED_KB/1024)) MB, have $((FREE_KB/1024)) MB"
tar -xzf "$HANDOFF" -C "$TMPD" "$DUMP_NAME" 2>/dev/null || fail "could not unpack $DUMP_NAME from the hand-off"
[[ -s "$DUMP" ]] || fail "unpacked dump is missing or empty"
[[ "$(wc -c <"$DUMP" | tr -d ' ')" == "$DUMP_B" ]] || fail "unpacked dump is $(wc -c <"$DUMP" | tr -d ' ') bytes but the manifest says $DUMP_B - truncated or tampered bundle"

SRC_SITE=$(mf source_site); SRC_URL=$(mf source_url); SRC_PREFIX=$(mf source_prefix)
SRC_URL="${SRC_URL%/}"   # older manifests may still carry the slash
SRC_CORE=$(mf source_core); SRC_DBVER=$(mf source_db_version); SRC_EXCLUDED=$(mf excluded); SRC_TS=$(mf timestamp)
LOG="$LOGDIR/${DUMP_NAME%.sql}.import.log"
echo "  source: $SRC_SITE ($SRC_URL)  core $SRC_CORE (db $SRC_DBVER)  excluded: ${SRC_EXCLUDED:-none}  exported: $SRC_TS"

# ---- gates ------------------------------------------------------------------------------------------
echo -e "\nGates:"
tail -c 200 "$DUMP" | grep -q -- '-- Dump completed' && pass "dump complete" || flunk "dump has no '-- Dump completed' tail"
[[ "$SRC_URL" == "$SOURCE_URL" ]] && pass "manifest source_url matches config SOURCE_URL" \
    || flunk "config SOURCE_URL ($SOURCE_URL) != manifest source_url ($SRC_URL) - wrong hand-off or wrong config"
# staleness: an old hand-off imports "clean" but is not the refresh anyone meant
if (( MAX_HANDOFF_AGE_HOURS > 0 )); then
    SRC_EPOCH=$(date -u -d "${SRC_TS:0:8} ${SRC_TS:9:2}:${SRC_TS:11:2}" +%s 2>/dev/null || echo "")
    if [[ -n "$SRC_EPOCH" ]]; then
        AGE_H=$(( ( $(date -u +%s) - SRC_EPOCH ) / 3600 ))
        (( AGE_H <= MAX_HANDOFF_AGE_HOURS )) && pass "hand-off is ${AGE_H}h old (limit ${MAX_HANDOFF_AGE_HOURS}h)" \
            || flunk "hand-off is ${AGE_H}h old - older than MAX_HANDOFF_AGE_HOURS=$MAX_HANDOFF_AGE_HOURS; export a fresh one"
    else
        warn "could not parse the manifest timestamp '$SRC_TS' - staleness not checked"
    fi
fi
[[ "$PREFIX" == "$SRC_PREFIX" ]] && pass "table prefix matches ($PREFIX)" || flunk "prefix mismatch: this site '$PREFIX' vs source '$SRC_PREFIX'"
if [[ -n "$EXPECT_EXCLUDED" ]]; then   # eg: the outbound queue MUST have been left out of the dump
    for t in ${EXPECT_EXCLUDED//,/ }; do
        grep -qw "$t" <<<"$SRC_EXCLUDED" && pass "excluded from dump as required: $t" \
            || flunk "$t was NOT excluded from the dump (config EXPECT_EXCLUDED) - refusing to import an outbound backlog"
    done
fi
# TRUNCATE targets must exist - either already on this site (an excluded table that survives the
# import untouched) or inside the dump - checked NOW so a typo cannot surface after the DB is replaced
if [[ -n "$TRUNCATE_TABLES" ]]; then
    TGT_NOW=$(wpq db tables --all-tables-with-prefix --format=csv | tr ',' '\n')
    for t in ${TRUNCATE_TABLES//,/ }; do
        if grep -qx "$t" <<<"$TGT_NOW" || grep -qx "$t" <<<"$(mf tables | tr ',' '\n')"; then pass "truncate target exists: $t"
        else flunk "TRUNCATE_TABLES entry '$t' exists neither on this site nor in the dump (typo?)"; fi
    done
fi
CORE=$(wpq core version)
if [[ "$(printf '%s\n%s\n' "$SRC_CORE" "$CORE" | sort -V | tail -n1)" == "$CORE" ]]; then
    pass "core files direction rule: target $CORE >= source $SRC_CORE"
else
    flunk "target core $CORE is OLDER than source $SRC_CORE - update this site's core files first (never update-db older files over newer data)"
fi
# Persistent object cache. 'wp cache type' reports the live backend (survives a custom WP_CONTENT_DIR;
# "Default" = no persistent cache). A drop-in makes 'wp cache flush' call ITS flush() - for the common
# Redis / Memcached drop-ins that is FLUSHDB (per Redis DB index) / flush_all (whole Memcached instance).
# A shared Redis INSTANCE with distinct DB indexes is fine; a shared INDEX, or a shared Memcached, is not.
CACHE_TYPE=$(wpq cache type | head -n1 | tr -d '\r'); PERSISTENT_CACHE=false
if [[ -z "$CACHE_TYPE" ]]; then
    # unknown = fail CLOSED with respect to the source: never run an instance-wide flush blind
    warn "could not determine the object cache backend ('wp cache type' returned nothing) - no instance-wide flush will be run (targeted invalidation only). If this site has a persistent object cache that is NOT shared with the source, flush it yourself afterwards: wp cache flush"
    SKIP_CACHE_FLUSH=true; PERSISTENT_CACHE=true; CACHE_TYPE="unknown"
elif [[ "$CACHE_TYPE" != "Default" ]]; then
    PERSISTENT_CACHE=true
    if $SKIP_CACHE_FLUSH; then
        warn "persistent object cache ($CACHE_TYPE); SKIP_CACHE_FLUSH=true - only the 'alloptions'/'notoptions' keys are invalidated. Posts, users, terms, meta and any individually cached option keep their PRE-IMPORT values - and with no TTL that means indefinitely. STOPGAP for one run: the fix is a separate Redis DB index for this site (or selective flush), then the default"
    else
        warn "persistent object cache ($CACHE_TYPE) - 'wp cache flush' calls its flush(): per-DB-index for Redis, whole-instance for Memcached. If this site shares the SAME Redis DB index or the same Memcached instance with the source, set SKIP_CACHE_FLUSH=true (targeted invalidation instead); a shared Redis instance with separate DB indexes is fine"
    fi
elif $SKIP_CACHE_FLUSH; then
    info "SKIP_CACHE_FLUSH=true but no persistent object cache is active ($CACHE_TYPE) - nothing to skip"
fi
if (( FAILS > 0 )); then
    echo; fail "$FAILS gate(s) failed - nothing imported (unpacked copies removed)"
fi

# ---- import ---------------------------------------------------------------------------------------
# Everything that must be true BEFORE this site serves its next request goes right after the import,
# ahead of the minutes-long rewrites: the source's pending-work channels (queue tables, cron schedule)
# arrive live and mostly past-due, and nginx keeps serving throughout - any request spawns wp-cron.
#
# Object cache: the import and the search-replaces are RAW SQL writes - nothing invalidates a persistent
# object cache. Reset it (1) right after the import, so 'core update-db' and every WP boot from here on
# read the imported values rather than the target's stale pre-import ones, and (2) at the very end, after
# the rewrites - between the two, any WP boot re-caches the SOURCE's URLs from MySQL. With
# SKIP_CACHE_FLUSH (shared index/instance) the reset is a targeted delete of THIS site's options keys
# ('alloptions'/'notoptions', scoped to its key prefix - a working shared setup must already have
# distinct prefixes) instead of an instance-wide flush.
cache_reset() {
    if $SKIP_CACHE_FLUSH; then
        echo "### cache: targeted invalidation of this site's options keys ($1)"
        $WP cache delete alloptions options || true   # non-zero just means the key was not cached
        $WP cache delete notoptions options || true
    else
        echo "### cache flush ($1)"
        $WP cache flush                                                         || echo "CACHE_FLUSH_FAILED $1"
    fi
}
mm_on
echo -e "\nSite in maintenance mode (503) until the clone is proven safe. Importing (do not interrupt):"
{
    echo "### import"
    $WP db import "$DUMP"                                                       || echo "IMPORT_FAILED"
    cache_reset after-import
    for t in ${TRUNCATE_TABLES//,/ }; do
        echo "### truncate $t"
        $WP db query "TRUNCATE TABLE $t"                                        || echo "TRUNCATE_FAILED $t"
    done
    if $CLEAR_CRON; then
        echo "### clear inherited cron schedule"
        $WP option delete cron                                                  || echo "CLEAR_CRON_FAILED"
    fi
    echo "### update-db"
    $WP core update-db                                                          || echo "UPDATE_DB_FAILED"
    echo "### rewrite host: $SOURCE_HOST -> $TARGET_HOST"
    $WP search-replace "$SOURCE_HOST" "$TARGET_HOST"     --all-tables --precise --report-changed-only || echo "REWRITE_FAILED host"
    if [[ "$SOURCE_SCHEME" != "$TARGET_SCHEME" ]]; then
        echo "### scheme fix: $SOURCE_SCHEME://$TARGET_HOST -> $TARGET_URL"
        $WP search-replace "$SOURCE_SCHEME://$TARGET_HOST" "$TARGET_URL" --all-tables --precise --report-changed-only || echo "REWRITE_FAILED scheme"
    fi
    cache_reset final
} > "$LOG" 2>&1 </dev/null
if grep -q '^IMPORT_FAILED' "$LOG"; then
    echo "  --- import error (see $LOG) ---"; grep -avE 'Deprecated:|PHP Warning:  PHP Startup' "$LOG" | grep -B2 -A6 -i 'error' | head -n 20
    cp "$MANIFEST" "$LOGDIR/" 2>/dev/null   # small, non-sensitive - useful next to the log for diagnosis
    fail "db import failed - the database is in an UNKNOWN state: fix the cause and re-run the whole refresh from the hand-off ($HANDOFF, until its TTL) or a fresh export. Manifest + log kept in $LOGDIR; the unpacked dump is removed (no copy of the source DB is left outside /tmp)"
fi
grep -E '^Success: (Imported|WordPress database|Made|The cache)' "$LOG" | sed 's/^/  /'
REPL=$(awk '/^### rewrite host/{f=1} /^### (scheme|cache)/{f=0} f && /Made [0-9]+ replacements/{for(i=1;i<=NF;i++) if($i=="Made") s+=$(i+1)} END{print s+0}' "$LOG")
echo "  host rewrite replacements: $REPL   (full search-replace reports: $LOG)"

# ---- acceptance -----------------------------------------------------------------------------------
echo -e "\nAcceptance:"
# SAFETY-classified checks (flunk_safety) decide whether the site comes back up: an untruncated queue, an
# un-rewritten host (siteurl == source ⇒ a clone guard keyed on it sees NO clone and outbound is OPEN),
# or an unarmed canary each mean the clone is not fenced - it stays in maintenance until fixed.
for t in ${TRUNCATE_TABLES//,/ }; do
    grep -q "^TRUNCATE_FAILED $t" "$LOG" && flunk_safety "TRUNCATE of $t failed (see $LOG)"
done
# every rewrite pass must have exited clean (a per-table failure inside a pass is what the dry-run
# below is for; a whole-pass failure is caught here)
for p in host scheme; do
    if grep -q "^REWRITE_FAILED $p" "$LOG"; then
        if [[ "$p" == host ]]; then flunk_safety "search-replace pass '$p' reported failure (see $LOG)"; else flunk "search-replace pass '$p' reported failure (see $LOG)"; fi
    fi
done
for c in after-import final; do
    grep -q "^CACHE_FLUSH_FAILED $c" "$LOG" && flunk "object cache flush ($c) reported failure (see $LOG) - stale pre-import values may be served"
done
# schema: update-db must have run clean AND left db_version at what these core files expect
# (all option reads below go to MySQL via opt() - see the note at the top - so a stale or skipped
# object cache cannot make them pass)
FILE_DBVER=$(grep -oE '\$wp_db_version *= *[0-9]+' "$WEBROOT/wp-includes/version.php" 2>/dev/null | grep -oE '[0-9]+$')
NOW_DBVER=$(opt db_version)
if grep -q '^UPDATE_DB_FAILED' "$LOG"; then
    flunk "core update-db reported failure (see $LOG) - schema may be half-migrated"
elif [[ -n "$FILE_DBVER" && "$NOW_DBVER" == "$FILE_DBVER" ]]; then
    pass "db schema at version $NOW_DBVER = what these core files expect (source was $SRC_DBVER)"
else
    flunk "db_version is '$NOW_DBVER' but these core files expect '$FILE_DBVER' (source was $SRC_DBVER) - schema not aligned"
fi
NOW_URL=$(opt siteurl); NOW_URL="${NOW_URL%/}"
[[ "$NOW_URL" == "$TARGET_URL" ]] && pass "siteurl is this site ($NOW_URL)" || flunk_safety "siteurl is '$NOW_URL' - expected $TARGET_URL"

for t in ${TRUNCATE_TABLES//,/ }; do
    n=$(wpq db query "SELECT COUNT(*) FROM $t" --skip-column-names | tr -d '[:space:]')
    [[ "$n" == "0" ]] && pass "$t is empty" || flunk_safety "$t has ${n:-?} rows - expected 0"
done

# row counts vs manifest (write-drift tolerance: ROW_DRIFT_PCT, default 1% - the source keeps writing
# between the manifest's count and the dump's snapshot, and this site keeps writing since the import)
while IFS='=' read -r k v; do
    t="${k#rows.}"; n=$(wpq db query "SELECT COUNT(*) FROM $t" --skip-column-names | tr -d '[:space:]')
    [[ "$n" =~ ^[0-9]+$ ]] || { flunk "$t: could not count rows (got '$n')"; continue; }
    if [[ "$n" == "$v" ]]; then pass "$t rows $n = source"
    elif (( v > 0 )) && (( (n > v ? n - v : v - n) * 100 <= v * ROW_DRIFT_PCT )); then pass "$t rows $n ~ source $v (within ${ROW_DRIFT_PCT}% write-drift)"
    else flunk "$t rows $n vs source $v (beyond ${ROW_DRIFT_PCT}% drift)"; fi
done < <(grep '^rows\.' "$MANIFEST")

# table-set parity: an import only replaces tables present in the dump - target-only strays survive silently
SRC_TABLES=$(mf tables | tr ',' '\n' | sort)
TGT_TABLES=$(wpq db tables --all-tables-with-prefix --format=csv | tr ',' '\n' | sort)
if [[ -n "$SRC_EXCLUDED" ]]; then for t in ${SRC_EXCLUDED//,/ }; do SRC_TABLES=$(grep -vx "$t" <<<"$SRC_TABLES"); TGT_TABLES=$(grep -vx "$t" <<<"$TGT_TABLES"); done; fi
EXTRA=$(comm -13 <(echo "$SRC_TABLES") <(echo "$TGT_TABLES")); MISSING=$(comm -23 <(echo "$SRC_TABLES") <(echo "$TGT_TABLES"))
if [[ -z "$EXTRA" && -z "$MISSING" ]]; then pass "table set matches source ($(grep -c . <<<"$SRC_TABLES") tables)"; fi
[[ -n "$MISSING" ]] && flunk "tables in the dump but absent here: $(paste -sd, - <<<"$MISSING")"
[[ -n "$EXTRA" ]] && warn "target-only tables survived the import (not in source) - review + drop deliberately: $(paste -sd, - <<<"$EXTRA")"

# views: never in the dump - report what the source has that this site lacks
SRC_VIEWS=$(mf views | tr ',' '\n' | sed '/^$/d' | sort)
TGT_VIEWS=$(wpq db query "SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA=DATABASE()" --skip-column-names | sort)
VMISS=$(comm -23 <(echo "$SRC_VIEWS") <(echo "$TGT_VIEWS") | sed '/^$/d')
[[ -z "$VMISS" ]] && pass "views: this site has every view the source has" \
    || warn "views on source but MISSING here (dumps never carry views; apps reading them fail silently) - recreate deliberately from 'SHOW CREATE VIEW' on the source, minus DEFINER: $(paste -sd, - <<<"$VMISS")"

# clone-guard canary (optional): the option must base64-decode to the SOURCE url = guard armed on this clone
if [[ -n "$CANARY_OPTION" ]]; then
    RAW=$(opt "$CANARY_OPTION"); DEC=$(base64 -d <<<"$RAW" 2>/dev/null || true)
    [[ "$DEC" == "$SOURCE_URL" ]] && pass "clone-guard canary '$CANARY_OPTION' decodes to source URL (guard armed)" \
        || flunk_safety "clone-guard canary '$CANARY_OPTION' decodes to '${DEC:-<unreadable>}' - expected $SOURCE_URL. Guard NOT armed - the site stays in maintenance until fixed"
fi

# what this site now holds that came from the source (facts to act on, not failures)
USERS_N=$(wpq db query "SELECT COUNT(*) FROM ${PREFIX}users" --skip-column-names | tr -d '[:space:]')
info "${USERS_N:-?} user accounts imported - the source's logins (and their roles) are now valid on this site"
# cron count from the 'cron' option row itself (raw $wpdb read + unserialize), NOT 'cron event list',
# which goes through get_option() and would report the cached pre-import schedule
CRON_N=$(wpq eval 'global $wpdb; $c=maybe_unserialize($wpdb->get_var("SELECT option_value FROM $wpdb->options WHERE option_name=\"cron\"")); $n=0; if(is_array($c)){foreach($c as $k=>$hooks){ if($k==="version"||!is_array($hooks)) continue; foreach($hooks as $evs) $n+=is_array($evs)?count($evs):0; }} echo $n;' | tr -d '[:space:]')
CRON_OFF=$(wpq eval 'echo (defined("DISABLE_WP_CRON") && DISABLE_WP_CRON) ? "yes" : "no";')
if $CLEAR_CRON; then
    # verified, not asserted: the delete ran inside the import block; re-count what is actually scheduled now
    if grep -q '^CLEAR_CRON_FAILED' "$LOG"; then
        flunk "CLEAR_CRON=true but 'wp option delete cron' failed (see $LOG) - the source's schedule (${CRON_N:-?} events) is live on this site"
    else
        pass "CLEAR_CRON: inherited cron schedule dropped right after the import; ${CRON_N:-?} event(s) scheduled now (core/plugins re-registering their own)"
    fi
else
    info "${CRON_N:-?} cron events inherited from the source's schedule (wp_options.cron travels with the dump) - this site will run them; DISABLE_WP_CRON=$CRON_OFF. Set CLEAR_CRON=true in the config to drop them on import"
fi

# object cache: under SKIP mode the site is now serving pre-import content for every non-options group
if $PERSISTENT_CACHE && $SKIP_CACHE_FLUSH; then
    warn "object cache NOT flushed (SKIP_CACHE_FLUSH / unknown backend): posts, users, terms, meta and individually cached options still hold PRE-IMPORT values - indefinitely, if the cache has no TTL. Give this site its own Redis DB index (or selective flush) and re-run with the default; or, if the cache is definitely not shared: wp cache flush"
fi

# dry-run, LAST (the site is in maintenance, but wp-cli boots above may still have written rows):
# no plain-text source-host references remain
DRY=$(wpq search-replace "$SOURCE_HOST" "DRYRUN" --all-tables --dry-run | grep -oE '[0-9]+ replacements' | awk '{print $1}')
[[ "${DRY:-x}" == "0" ]] && pass "dry-run: 0 remaining plain-text references to $SOURCE_HOST" \
    || flunk "dry-run reports ${DRY:-?} remaining references to $SOURCE_HOST"

# ---- summary + cleanup ---------------------------------------------------------------------------------
echo
if (( FAILS == 0 )); then
    echo "RESULT: PASS  ($WARNS warning(s) to review above)"
else
    echo "RESULT: FAIL  ($FAILS failure(s), $WARNS warning(s)) - diagnose, then re-run the whole refresh (idempotent)"
fi

# the site comes back up ONLY here, and only if every SAFETY check passed (an ordinary FAIL - a row-count
# drift, a missing view - is not a reason to keep it down; an unfenced clone is)
echo -e "\nSite:"
if (( SAFETY_FAILS == 0 )); then
    mm_off; echo "  maintenance mode lifted - the site is serving again$( (( FAILS > 0 )) && echo " (with the non-safety FAILs above to resolve)" )"
else
    mm_hold   # prints the recovery line itself; sets MM_ON=false so the EXIT trap does not repeat it
fi

echo -e "\nCleanup:"
# Rule: no AUTOMATIC path leaves a copy of the source database outside /tmp, and nothing in /tmp outlives
# this run except the exporter's TTL'd hand-off. So the unpacked dump goes on PASS *and* on FAIL (the
# EXIT trap removes the temp dir); on FAIL only the small manifest is kept next to the log for diagnosis,
# and a re-run uses the hand-off (still in /tmp until its TTL) or a fresh export. The ONE exception is the
# explicit --keep-dump, which writes a dump into ~/.wh-db-refresh/ - and says so, because ~ is subject to
# whatever backs up home directories.
(( FAILS == 0 )) || cp "$MANIFEST" "$LOGDIR/" 2>/dev/null       # manifest kept only when there is something to diagnose
find "$LOGDIR" -maxdepth 1 -type f \( -name '*.import.log' -o -name '*.manifest' \) -mtime +60 -delete 2>/dev/null   # old records; never touches --keep-dump dirs
if $KEEP_DUMP; then
    KEEPDIR="$LOGDIR/${DUMP_NAME%.sql}"; install -d -m 700 "$KEEPDIR"
    if mv "$DUMP" "$KEEPDIR/" 2>/dev/null; then
        echo "  --keep-dump: dump kept in $KEEPDIR  ⚠ this is a full copy of the source database in your HOME directory - subject to whatever backs up ~; delete as soon as you are done: rm -rf $KEEPDIR"
    else
        echo "  --keep-dump: could not move the dump into $KEEPDIR - it will be removed with the temp dir (nothing kept)"
    fi
elif (( FAILS == 0 )); then
    echo "  deleting this side's unpacked dump (a full copy of the source database; PITR is the rollback, not loose dumps)"
else
    echo "  FAIL - the unpacked dump is deleted anyway (no copy of the source DB is left outside /tmp); the manifest is kept next to the log for diagnosis. Re-run from the hand-off while its TTL lasts, or export afresh"
fi
echo "  kept the import log (search-replace reports; records older than 60 days are pruned): $LOG"
if [[ -e "$HANDOFF" ]]; then
    echo "  the /tmp hand-off still exists (owned by the exporting user; self-destructs on its TTL, or that user removes it now): $HANDOFF"
else
    echo "  the /tmp hand-off is already gone"
fi
echo -e "\nReminders: log in again (old sessions died with the import) · then do the browser/function checks."
echo ""
(( FAILS == 0 ))
