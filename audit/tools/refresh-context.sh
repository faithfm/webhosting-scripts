#!/usr/bin/env bash
#
# refresh-context.sh — DETERMINISTIC context-map refresh. NO LLM. NO network egress.
#
# Updates the managed freshness/drift block in audit/CONTEXT.md and audit/.context-state.json
# by diffing the current HEAD against the commit at which the prose was last enriched by Claude.
#
#   bash audit/tools/refresh-context.sh                 # refresh freshness + drift flags
#   bash audit/tools/refresh-context.sh --mark-enriched # record HEAD as the enriched baseline
#
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
AUDIT_DIR="audit"
CONTEXT="$AUDIT_DIR/CONTEXT.md"
STATE="$AUDIT_DIR/.context-state.json"
START="<!-- CTXMAP:START — managed by refresh-context.sh, do not edit between these markers -->"
END="<!-- CTXMAP:END -->"

[ -f "$CONTEXT" ] || { echo "ERROR: $CONTEXT not found. Create it (or run the enrich job) first." >&2; exit 1; }

HEAD_SHA="$(git rev-parse HEAD)"
HEAD_SHORT="$(git rev-parse --short HEAD)"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

MARK_ENRICHED=0
[ "${1:-}" = "--mark-enriched" ] && MARK_ENRICHED=1

# --- prior enriched baseline ---
ENRICHED_SHA=""
if [ -f "$STATE" ] && command -v jq >/dev/null 2>&1; then
  ENRICHED_SHA="$(jq -r '.enriched_sha // ""' "$STATE" 2>/dev/null || echo "")"
fi
[ "$MARK_ENRICHED" -eq 1 ] && ENRICHED_SHA="$HEAD_SHA"

# --- subsystem map: "path-prefix|label"  (edit per repo as needed) ---
MAP=(
  "wh.sh|Dispatcher / WH_* environment contract"
  "wh.bash_completion|Bash completion"
  "wh.crond|Cron (New Relic forwarder)"
  "wh.pyenv-profile.d|pyenv login profile"
  "wh-scripts/wh-checkout|Deployment - checkout"
  "wh-scripts/wh-composer-deploy|Deployment - composer/npm pipeline"
  "wh-scripts/wh-composer.sh|Helper - site-version composer"
  "wh-scripts/wh-php.sh|Helper - site-version PHP"
  "wh-scripts/wh-git|Helper - git repo/work-tree resolver"
  "wh-scripts/wh-fpm-reload|Helper - PHP-FPM reload"
  "wh-scripts/wh-docker|Docker framework"
  "wh-scripts/wh-bup|Backup framework (restic)"
  "wh-scripts/wh-db-refresh|WordPress DB refresh (export/import)"
  "wh-scripts/wh-nr-|Observability (New Relic markers)"
  "wh-scripts/wh-update|Platform - install/update"
  "wh-scripts/wh-python-update|Platform - pyenv/venv"
  "wh-scripts/wh-show-env|Diagnostics"
  "docker/|Docker templates"
  "db-refresh/|DB-refresh config sample + HOWTO"
  "requirements.txt|Python dependencies"
  ".python-version|Pinned Python version"
)
SRC_PATHS="wh-scripts wh.sh wh.crond wh.bash_completion wh.pyenv-profile.d docker db-refresh requirements.txt .python-version"

# --- compute drift since the enriched baseline ---
CHANGED=""
if [ -n "$ENRICHED_SHA" ] && [ "$MARK_ENRICHED" -eq 0 ] \
   && git cat-file -e "${ENRICHED_SHA}^{commit}" 2>/dev/null \
   && git merge-base --is-ancestor "$ENRICHED_SHA" HEAD 2>/dev/null; then
  CHANGED="$(git diff --name-only "$ENRICHED_SHA" HEAD -- $SRC_PATHS 2>/dev/null || true)"
fi

CHANGED_COUNT=0
DRIFT_LIST=""
if [ -n "$CHANGED" ]; then
  CHANGED_COUNT="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | wc -l | tr -d ' ')"
  for entry in "${MAP[@]}"; do
    pfx="${entry%%|*}"; label="${entry#*|}"
    n="$(printf '%s\n' "$CHANGED" | grep -c "^$pfx" || true)"
    [ "$n" -gt 0 ] && DRIFT_LIST="${DRIFT_LIST}- **${label}** — ${n} file(s) changed"$'\n'
  done
fi

# --- status text ---
if [ -z "$ENRICHED_SHA" ]; then
  STATUS="🟡 **Not yet enriched.** Run the \`enrich\` workflow (Claude) once to generate the semantic digest for the current code."
elif [ "$CHANGED_COUNT" -eq 0 ]; then
  STATUS="✅ **In sync** — the digest below reflects the code as of \`$HEAD_SHORT\`."
else
  STATUS="⚠️ **Stale** — ${CHANGED_COUNT} source file(s) changed since the last Claude enrichment (\`${ENRICHED_SHA:0:7}\`). The digest below may be out of date for:"$'\n\n'"${DRIFT_LIST}"$'\n'"Run the \`enrich\` workflow to refresh the prose."
fi

# --- build the managed block ---
blockfile="$(mktemp)"
{
  echo "$START"
  echo "**Freshness:** HEAD \`$HEAD_SHORT\` · refreshed $NOW (deterministic refresh — no LLM, no egress)."
  echo ""
  printf '%s\n' "$STATUS"
  echo "$END"
} > "$blockfile"

# --- splice it into CONTEXT.md (replace between markers, or insert after the H1) ---
tmp="$(mktemp)"
if grep -qF "$START" "$CONTEXT"; then
  awk -v s="$START" -v e="$END" -v bf="$blockfile" '
    $0==s { while((getline l < bf) > 0) print l; close(bf); skip=1; next }
    skip && $0==e { skip=0; next }
    skip { next }
    { print }
  ' "$CONTEXT" > "$tmp"
else
  awk -v bf="$blockfile" '
    NR==1 { print; print ""; while((getline l < bf) > 0) print l; close(bf); next }
    { print }
  ' "$CONTEXT" > "$tmp"
fi
mv "$tmp" "$CONTEXT"
rm -f "$blockfile"

# --- persist state ---
if command -v jq >/dev/null 2>&1; then
  jq -n --arg e "$ENRICHED_SHA" --arg r "$HEAD_SHA" --arg t "$NOW" \
    '{enriched_sha:$e, last_refresh_sha:$r, last_refresh_at:$t}' > "$STATE"
else
  printf '{\n  "enriched_sha": "%s",\n  "last_refresh_sha": "%s",\n  "last_refresh_at": "%s"\n}\n' \
    "$ENRICHED_SHA" "$HEAD_SHA" "$NOW" > "$STATE"
fi

echo "refresh-context: HEAD=$HEAD_SHORT enriched=${ENRICHED_SHA:0:7} changed=$CHANGED_COUNT mark_enriched=$MARK_ENRICHED"
