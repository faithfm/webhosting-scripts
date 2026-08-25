#!/bin/bash

# Export the current site's WordPress database as a hand-off bundle for 'wh db-refresh-import'
# on a sibling site hosted on the same server under a different unix user (eg: prod -> staging).
#
# Run as the SOURCE site's own user, from inside its site folder (WH_SITE / WH_WEBROOT_DIR are
# detected from the folder + nginx config, and WH_PHP_CMD makes wp-cli run under the site's PHP):
#
#   cd ~/app.example.com
#   wh db-refresh-export --grant-user=app-staging-user --exclude=wp_some_queue_table
#
# What it does (the source site is only READ - '--single-transaction' means no table locks):
#   1. pre-flight: options valid · setfacl present · free space in /tmp >= ~2x the database size
#   2. dumps every prefixed table except those in --exclude   (mysqldump via wp-cli, GTID-safe)
#      into a private (mode 700) temp dir - never into the home directory
#   3. verifies the dump is complete ("-- Dump completed" tail) - refuses to hand off a partial one
#   4. writes a small manifest beside it (table list, key row counts, source URL, core/db version)
#      which the import side uses for its gates and parity checks
#   5. bundles both into /tmp with mode 600 + a single-reader ACL for --grant-user (the dump never
#      leaves the box and no other user can read it - umask 077 throughout, so there is no window
#      in which the file is world-readable); prints the exact import command to run next
#   6. schedules the hand-off's own deletion after --ttl minutes (default 120) - the bundle is a full
#      copy of the source database and is the ONLY thing bridging the two sites, so it must not
#      depend on anyone remembering to remove it. (Only its owner can delete it under sticky /tmp -
#      the importer's read grant cannot - hence the exporter side self-cleans.)
#   Any failure removes everything it created (EXIT trap) - no failure path leaves a dump behind.
#
# Options:
#   --grant-user=USER     unix user allowed to read the hand-off (the importing site's user). Required.
#   --exclude=t1,t2,...   full table names to leave OUT of the dump (eg: an outbound job/event queue
#                         that must never be shipped to a clone). Optional, default: none.
#   --count=t1,t2,...     extra tables whose row counts go into the manifest for the import side's
#                         "did everything arrive?" check - name the tables that hold the site's real
#                         data (a CRM's contacts table, a shop's orders table). Optional; the core
#                         WordPress tables (users, posts, options, postmeta, usermeta) are always counted.
#   --ttl=MINUTES         minutes until the /tmp hand-off self-destructs (default 120; 0 = never -
#                         then YOU must delete it)
#   --keep-local          also keep the uncompressed dump + manifest in ~/.wh-db-refresh/
#                         (default: nothing is kept outside the /tmp hand-off).  ⚠ Check that your
#                         backup tooling does not include that folder before relying on this.

set -euo pipefail
umask 077   # everything this script creates is owner-only from the first byte

fail() { echo "wh db-refresh-export: ERROR: $1" >&2; echo "  (usage: see the header of $0)" >&2; exit 1; }

# ---- args --------------------------------------------------------------------------------------
GRANT_USER=""; EXCLUDE=""; COUNT=""; KEEP_LOCAL=false; TTL=120
for arg in "$@"; do
    case "$arg" in
        --grant-user=*) GRANT_USER="${arg#*=}" ;;
        --exclude=*)    EXCLUDE="${arg#*=}" ;;
        --count=*)      COUNT="${arg#*=}" ;;
        --ttl=*)        TTL="${arg#*=}" ;;
        --keep-local)   KEEP_LOCAL=true ;;
        *) fail "unknown option '$arg'" ;;
    esac
done
[[ -n "$GRANT_USER" ]] || fail "--grant-user=<importing site's unix user> is required"
id "$GRANT_USER" >/dev/null 2>&1 || fail "user '$GRANT_USER' does not exist on this server"
[[ "$GRANT_USER" != "$USER" ]] || fail "--grant-user must be a DIFFERENT user (the importing site's), not $USER"
[[ "$TTL" =~ ^[0-9]+$ ]] || fail "--ttl must be a whole number of minutes (got '$TTL')"
command -v setfacl >/dev/null || fail "setfacl not available (install the 'acl' package) - the hand-off cannot be secured, nothing exported"
command -v getfacl >/dev/null || fail "getfacl not available (install the 'acl' package) - nothing exported"

# ---- site context (from wh.sh) -----------------------------------------------------------------
[[ "${WH_SITE_VALID:-false}" == true ]] || fail "no site detected - cd into the source site's folder first (check 'wh show-env')"
[[ "${WH_USER_VALID:-false}" == true ]] || fail "run this as the site's own user ($WH_USER), not as $USER"
[[ -n "${WH_PHP_CMD:-}" ]] || fail "site PHP version not detected (WH_PHP_CMD empty - check 'wh show-env')"
WEBROOT="$WH_WEBROOT_DIR"
[[ -f "$WEBROOT/wp-config.php" ]] || fail "no wp-config.php in detected webroot '$WEBROOT'"
# the PHAR, not 'command -v wp' - on a server where /usr/local/bin/wp is a shell wrapper, PHP would
# echo the wrapper's own source instead of running wp-cli, and every read below would parse that text
[[ -n "${WH_WP_PHAR:-}" ]] || fail "no usable wp-cli phar on this server ('wp' is absent, or is a shell wrapper that must not be handed to PHP - check 'wh show-env') - an admin can install/replace it with: wh wp-install"
WP="$WH_PHP_CMD $WH_WP_PHAR --path=$WEBROOT"
# wp-cli's own PHP-8.x deprecation chatter is not site output - keep it out of what we parse/print;
# </dev/null so no wp subprocess can ever swallow a caller's stdin (eg: inside a while-read loop)
wpq() { $WP "$@" 2>/dev/null </dev/null; }

# ---- work dir + failure cleanup ---------------------------------------------------------------
TS=$(date -u +%Y%m%dT%H%MZ)
NAME="db-refresh-${WH_SITE}-${TS}"
TMPD=$(mktemp -d /tmp/wh-db-refresh-export.XXXXXX)      # mode 700 - private to this user
DUMP="$TMPD/$NAME.sql"; MANIFEST="$TMPD/$NAME.manifest"; ERRS="$TMPD/wp.err"
HANDOFF="/tmp/$NAME.tar.gz"
DONE=false
cleanup() {
    if ! $DONE; then rm -f "$HANDOFF" 2>/dev/null; fi   # a failed run leaves no hand-off behind
    rm -rf "$TMPD"                                        # the temp dir never outlives the script
}
trap cleanup EXIT

echo -e "\nwh db-refresh-export: source site $WH_SITE  (user $WH_USER, $WH_PHP_CMD)"

# ---- read the site --------------------------------------------------------------------------------
PREFIX=$(wpq db prefix)
# a real prefix is [A-Za-z0-9_]+ (WordPress' own install rule) - checking the SHAPE, not just
# non-emptiness, is what stops a broken wp-cli's stray output from being taken for an answer
[[ "$PREFIX" =~ ^[A-Za-z0-9_]+$ ]] || fail "wp-cli did not return a usable table prefix (got '${PREFIX:0:40}') - is the site healthy under $WH_PHP_CMD? Try: $WP db prefix"
# options straight from MySQL (not get_option) - the manifest must record what is IN the database, never
# what a persistent object cache happens to hold
opt() { wpq db query "SELECT option_value FROM ${PREFIX}options WHERE option_name='$1' LIMIT 1" --skip-column-names | head -n1 | tr -d '\r'; }
SITEURL=$(opt siteurl); SITEURL="${SITEURL%/}"   # WP permits a trailing slash on siteurl; it would parse as a path component downstream
CORE=$(wpq core version)
DBVER=$(opt db_version)
[[ "$SITEURL" == http* ]] || fail "could not read siteurl from the database (got '$SITEURL') - is the site healthy under $WH_PHP_CMD?"

# table list minus exclusions (exact-name matches only - a typo must not silently export the queue)
ALL_TABLES=$(wpq db tables --all-tables-with-prefix --format=csv | tr ',' '\n')
TABLES="$ALL_TABLES"
if [[ -n "$EXCLUDE" ]]; then
    for t in ${EXCLUDE//,/ }; do
        grep -qx "$t" <<<"$ALL_TABLES" || fail "--exclude table '$t' does not exist on $WH_SITE (nothing exported)"
        TABLES=$(grep -vx "$t" <<<"$TABLES")
    done
fi
# --count tables must be real and must be in the dump - checked BEFORE the dump so a typo costs nothing
if [[ -n "$COUNT" ]]; then
    for t in ${COUNT//,/ }; do
        grep -qx "$t" <<<"$TABLES" || fail "--count table '$t' is not in the dump (typo, or it is in --exclude?) - nothing exported"
    done
fi
TABLE_CSV=$(paste -sd, - <<<"$TABLES")
N_ALL=$(grep -c . <<<"$ALL_TABLES"); N_DUMP=$(grep -c . <<<"$TABLES")

# free space: dump (~db size) + tar (~1/5) + slack, all under /tmp
DB_KB=$(wpq db query "SELECT COALESCE(ROUND(SUM(data_length+index_length)/1024),0) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE()" --skip-column-names | tr -d '[:space:]')
FREE_KB=$(df -Pk /tmp | awk 'NR==2{print $4}')
[[ "$DB_KB" =~ ^[0-9]+$ && "$FREE_KB" =~ ^[0-9]+$ ]] || fail "could not determine database size / free space"
NEED_KB=$(( DB_KB * 2 + 102400 ))
(( FREE_KB >= NEED_KB )) || fail "not enough free space in /tmp: need ~$((NEED_KB/1024)) MB (2x the ~$((DB_KB/1024)) MB database), have $((FREE_KB/1024)) MB"

echo "  prefix $PREFIX  |  siteurl $SITEURL  |  core $CORE (db $DBVER)  |  db ~$((DB_KB/1024)) MB"
echo "  tables: $N_ALL on site, $N_DUMP in dump${EXCLUDE:+  (excluded: $EXCLUDE)}"

# ---- manifest row counts (taken just before the dump; the import allows ROW_DRIFT_PCT for the
#      writes that land between this count and the dump's snapshot - a live site keeps writing) ---
ROWS=""
for t in ${PREFIX}users ${PREFIX}posts ${PREFIX}options ${PREFIX}postmeta ${PREFIX}usermeta ${COUNT//,/ }; do
    grep -qx "$t" <<<"$TABLES" || continue
    ROWS+="rows.$t=$(wpq db query "SELECT COUNT(*) FROM $t" --skip-column-names | tr -d '[:space:]')"$'\n'
done

# ---- export ---------------------------------------------------------------------------------------
echo "  dumping ..."
# --single-transaction: no locks on the live source.  --set-gtid-purged=OFF: without it, mysqldump 8
# writes GTID/SQL_LOG_BIN headers that need SUPER on import and the restore dies with ERROR 1227.
if ! $WP db export "$DUMP" --tables="$TABLE_CSV" --single-transaction --add-drop-table --set-gtid-purged=OFF >/dev/null 2>"$ERRS" </dev/null; then
    echo "  --- last lines from wp-cli (deprecation noise filtered) ---" >&2
    grep -avE 'Deprecated:|PHP Warning:  PHP Startup' "$ERRS" | tail -n 8 >&2
    fail "database export failed - nothing handed off"
fi
# completeness gate - never hand off a partial dump
tail -c 200 "$DUMP" | grep -q -- '-- Dump completed' || fail "dump did not finish (no '-- Dump completed' tail) - nothing handed off. Re-run."
echo "  dump complete ($(du -h "$DUMP" | cut -f1))"

# ---- manifest (gates + parity data for the import side) ----------------------------------------
{
    echo "source_site=$WH_SITE"
    echo "source_url=$SITEURL"
    echo "source_prefix=$PREFIX"
    echo "source_core=$CORE"
    echo "source_db_version=$DBVER"
    echo "excluded=$EXCLUDE"
    echo "timestamp=$TS"
    echo "table_count=$N_DUMP"
    echo "tables=$TABLE_CSV"
    # true byte size of the dump - the import's free-space gate reads THIS (gzip's ISIZE trailer is
    # 32-bit and wraps above 4 GiB, so it cannot be trusted for large databases)
    echo "dump_bytes=$(wc -c <"$DUMP" | tr -d ' ')"
    printf '%s' "$ROWS"
    # views are NOT in the dump (a per-table mysqldump lists none) - the import side reports missing ones
    echo "views=$(wpq db query "SELECT TABLE_NAME FROM information_schema.VIEWS WHERE TABLE_SCHEMA=DATABASE()" --skip-column-names | paste -sd, -)"
} > "$MANIFEST"

# ---- hand-off: bundle into /tmp (created 600 under umask 077), then exactly one ACL reader --------
# manifest FIRST: the import reads it alone (a tiny read of the stream) before deciding to unpack the dump
tar -czf "$HANDOFF" -C "$TMPD" "$NAME.manifest" "$NAME.sql"
setfacl -m "u:$GRANT_USER:r" "$HANDOFF"
ACL=$(getfacl -p "$HANDOFF" 2>/dev/null)
if ! grep -qx "user:$GRANT_USER:r--" <<<"$ACL" || grep -qE '^(group|other)::.*r' <<<"$ACL"; then
    fail "ACL grant did not verify (got: $(tr '\n' ' ' <<<"$ACL")) - hand-off removed, nothing left behind"
fi

# optional local copies (explicit opt-in; outside /tmp, so subject to whatever backs up ~)
if $KEEP_LOCAL; then
    KEEP=~/.wh-db-refresh; install -d -m 700 "$KEEP"
    cp "$DUMP" "$MANIFEST" "$KEEP/"
fi

# self-destruct: a detached sleeper owned by this user removes the hand-off after TTL minutes and
# survives logout (setsid where available - Linux - else nohup+disown). Deleting it sooner by hand
# is always fine. The timer's liveness is VERIFIED before it is promised.
TIMER_OK=false; TIMER_PID=""; EXPIRES=""
if (( TTL > 0 )); then
    if command -v setsid >/dev/null; then
        setsid nohup bash -c "sleep $((TTL*60)); rm -f '$HANDOFF'" >/dev/null 2>&1 </dev/null &
    else
        nohup bash -c "sleep $((TTL*60)); rm -f '$HANDOFF'" >/dev/null 2>&1 </dev/null & disown
    fi
    TIMER_PID=$!
    sleep 0.2; kill -0 "$TIMER_PID" 2>/dev/null && TIMER_OK=true
    EXPIRES=$(date -u -d "+$TTL minutes" +%H:%MZ 2>/dev/null || date -u -v+"$TTL"M +%H:%MZ)
fi

DONE=true   # from here the EXIT trap keeps the hand-off and only removes the temp dir

echo -e "\n  hand-off ready: $HANDOFF  ($(du -h "$HANDOFF" | cut -f1); readable by $WH_USER + $GRANT_USER only)"
if (( TTL > 0 )) && $TIMER_OK; then
    echo "  self-destructs at ${EXPIRES} UTC (--ttl=$TTL, timer pid $TIMER_PID) - or delete it sooner: rm -f $HANDOFF"
elif (( TTL > 0 )); then
    echo "  ⚠ could not start the self-destruct timer - this hand-off will NOT expire on its own. Delete it yourself once the import passes: rm -f $HANDOFF"
else
    echo "  ⚠ --ttl=0: this hand-off will NOT self-destruct - delete it yourself once the import passes: rm -f $HANDOFF"
fi
$KEEP_LOCAL && echo "  local copies kept (yours to delete): ~/.wh-db-refresh/$NAME.sql + .manifest"
echo -e "\nNext - as $GRANT_USER, from inside the TARGET site's folder:"
echo "  wh db-refresh-import $HANDOFF"
echo ""
