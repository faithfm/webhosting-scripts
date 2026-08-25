#!/usr/bin/env bash
#
# regenerate-graph.sh — DETERMINISTIC skeleton reconcile of audit/graph.json. NO LLM. NO egress.
#
# Reconciles the node set against the current file tree WITHOUT destroying the LLM-authored
# descriptions/edges:
#   * adds a skeleton node for each source file no node references yet  (desc = "not yet documented")
#   * flags (or, with --prune, removes) nodes whose `file` no longer exists on disk
#   * keeps every existing node/edge; with --prune also drops edges whose endpoints were removed
#   * re-injects the result into audit/knowledge-graph.html (if python3 is available)
#
#   bash audit/tools/regenerate-graph.sh            # add new nodes, flag stale ones
#   bash audit/tools/regenerate-graph.sh --prune    # also delete stale nodes + dangling edges
#
set -euo pipefail
command -v jq >/dev/null || { echo "ERROR: jq is required." >&2; exit 1; }

ROOT="$(git rev-parse --show-toplevel)"; cd "$ROOT"
GRAPH="audit/graph.json"
HTML="audit/knowledge-graph.html"
[ -f "$GRAPH" ] || { echo "ERROR: $GRAPH not found (run the initial Claude audit first)." >&2; exit 1; }

PRUNE=0; [ "${1:-}" = "--prune" ] && PRUNE=1

# Source dirs whose files map 1:1 to graph nodes.
#   Every `wh <cmd>` is exactly one file in wh-scripts/, so the reconcile scans that dir only.
#   The root-level entry files (wh.sh, wh.crond, wh.bash_completion, wh.pyenv-profile.d) are
#   hand-authored nodes and deliberately excluded: their basenames collide under "${base%.*}"
#   (wh.sh and wh.bash_completion would both become "wh"), and they change too rarely to reconcile.
SRC_DIRS="wh-scripts"
EXT_RE='\.(sh|py)$'
# Nothing in wh-scripts/ is boilerplate - every file is a real command. Placeholder pattern
# (matches nothing) kept so the grep below stays valid.
SKIP_RE='^$'

present="$(mktemp)"; ids="$(mktemp)"; files="$(mktemp)"
trap 'rm -f "$present" "$ids" "$files"' EXIT

git ls-files $SRC_DIRS | grep -E "$EXT_RE" | sort -u > "$present"
jq -r '.nodes[].id'                         "$GRAPH" | sort -u > "$ids"
jq -r '.nodes[]|select(.file!=null).file'   "$GRAPH" | sort -u > "$files"

# path -> group + default trace doc (mirror of the HTML GROUP_TRACE map)
#   Commands are grouped by name prefix, since wh-scripts/ is flat.
#   Order matters: the more specific patterns must come before the broader ones.
classify() {
  case "$1" in
    wh-scripts/wh-checkout-*|wh-scripts/wh-composer-deploy*)  g=deploy;        tr="traces/02-deployment-pipeline.md";;
    wh-scripts/wh-docker-install.sh)                          g=platform;      tr="traces/06-platform-install-update.md";;
    wh-scripts/wh-docker-get-context.sh|wh-scripts/wh-docker-copy-config.sh) \
                                                              g=helper;        tr="traces/03-docker-framework.md";;
    wh-scripts/wh-docker-*)                                   g=docker;        tr="traces/03-docker-framework.md";;
    wh-scripts/wh-bup-install.sh|wh-scripts/wh-bup-selfupdate.sh) \
                                                              g=platform;      tr="traces/06-platform-install-update.md";;
    wh-scripts/wh-bup*)                                       g=backup;        tr="traces/04-backup-framework.md";;
    wh-scripts/wh-db-refresh-*)                               g=dbrefresh;     tr="traces/07-db-refresh.md";;
    wh-scripts/wh-nr-*)                                       g=observability; tr="traces/05-observability-newrelic.md";;
    wh-scripts/wh-update.sh|wh-scripts/wh-update-nvm.sh|wh-scripts/wh-python-update.sh|wh-scripts/wh-git-config.sh) \
                                                              g=platform;      tr="traces/06-platform-install-update.md";;
    wh-scripts/wh-php.sh|wh-scripts/wh-composer.sh|wh-scripts/wh-git.py|wh-scripts/wh-fpm-reload.sh) \
                                                              g=helper;        tr="traces/02-deployment-pipeline.md";;
    wh-scripts/wh-show-env.sh|wh-scripts/wh-hello*)           g=diag;          tr="traces/01-dispatcher-and-environment.md";;
    *)                                                        g=external;      tr="";;
  esac
}

added=0
while IFS= read -r path; do
  [ -n "$path" ] || continue
  printf '%s\n' "$path" | grep -qE "$SKIP_RE" && continue   # framework boilerplate
  base="$(basename "$path")"; id="${base%.*}"
  # already documented if a node points at this file OR shares this id
  grep -qxF "$path" "$files" && continue
  grep -qxF "$id"   "$ids"   && continue
  classify "$path"
  tmp="$(mktemp)"
  jq --arg id "$id" --arg label "$id" --arg group "$g" --arg file "$path" --arg trace "$tr" \
    '.nodes += [{id:$id,label:$label,group:$group,file:$file,
                 desc:"⟂ Not yet documented — added by skeleton reconcile; run enrich / a deep pass.",
                 trace:$trace, skeleton:true}]' "$GRAPH" > "$tmp" && mv "$tmp" "$GRAPH"
  echo "$id" >> "$ids"
  echo "  + node  $id  ($g)  $path"
  added=$((added+1))
done < "$present"

staleN=0; prunedN=0
while IFS= read -r f; do
  case "$f" in wh-scripts/*) ;; *) continue;; esac            # only reconciled source paths
                                                              # (root entry files, docker/ templates
                                                              #  and config nodes are hand-authored)
  grep -qxF "$f" "$present" && continue                        # still exists → fine
  tmp="$(mktemp)"
  if [ "$PRUNE" -eq 1 ]; then
    jq --arg f "$f" 'del(.nodes[]|select(.file==$f))' "$GRAPH" > "$tmp" && mv "$tmp" "$GRAPH"
    echo "  - prune $f"; prunedN=$((prunedN+1))
  else
    jq --arg f "$f" '(.nodes[]|select(.file==$f)) |= (. + {stale:"file not found on disk"})' "$GRAPH" > "$tmp" && mv "$tmp" "$GRAPH"
    echo "  ! stale $f"; staleN=$((staleN+1))
  fi
done < "$files"

# drop edges whose endpoints no longer exist (only matters after prune)
tmp="$(mktemp)"
jq '(.nodes|map(.id)) as $ids
    | .links |= map(select(.s as $s | .t as $t | ($ids|index($s)) and ($ids|index($t))))
    | .meta.node_count = (.nodes|length)' "$GRAPH" > "$tmp" && mv "$tmp" "$GRAPH"

# validate
jq -e . "$GRAPH" >/dev/null || { echo "ERROR: graph.json became invalid." >&2; exit 1; }

# keep the HTML in sync (embedded copy of graph.json)
if command -v python3 >/dev/null 2>&1 && [ -f "$HTML" ]; then
  python3 - "$GRAPH" "$HTML" <<'PY'
import json, re, sys
data = open(sys.argv[1]).read(); json.loads(data)
html = open(sys.argv[2]).read()
pat = re.compile(r'(<script id="graph-data" type="application/json">)(.*?)(</script>)', re.S)
if pat.search(html):
    open(sys.argv[2],'w').write(pat.sub(lambda m: m.group(1)+'\n'+data+'\n'+m.group(3), html, count=1))
    print("  graph re-injected into knowledge-graph.html")
PY
fi

total="$(jq '.nodes|length' "$GRAPH")"
echo "regenerate-graph: +$added new · ${staleN} flagged · ${prunedN} pruned · nodes now $total"
[ "$added" -gt 0 ] && echo "  (new nodes are skeleton stubs — run enrich / a deep pass to describe + connect them)"
exit 0
