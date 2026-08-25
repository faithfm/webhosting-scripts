#!/bin/bash

# Install or update wp-cli on this server.  ADMIN COMMAND - run it from an admin account (forge);
# it uses sudo to write into /usr/local/bin.
#
# THE MODEL (Michael, 2026-08-26): ONE current wp-cli phar per machine, owned root:root, mode 0755,
# at /usr/local/bin/wp.
#   * One phar serves every site on the box. wp-cli is version-agnostic toward WordPress core - one
#     current wp-cli drives every WP version this fleet runs - and the phar is pure PHP, so the same
#     file works on x86_64 and aarch64 alike. There is nothing per-site to install, and no reason to
#     keep more than one copy.
#   * What must match the site is the PHP that EXECUTES the phar, and that is 'wh wp's job, resolved
#     per site from nginx. A second copy of wp-cli would buy nothing.
#   * root ownership is deliberate: it stops a site user's 'wp cli update' from moving the fleet's
#     shared binary out from under everyone else. Re-running THIS script is how the phar advances.
#
# Re-running IS the updater, and it is idempotent: if what is already installed matches the published
# checksum, nothing is written.
#
# It also retires the two older shapes found on this fleet: a hand-written shell wrapper at
# /usr/local/bin/wp pinning one PHP version (superseded by 'wh wp', which detects it per site), and
# a phar parked at /usr/local/lib/wp-cli.phar.

set -o pipefail

WP_URL="https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar"
SHA_URL="$WP_URL.sha512"
TARGET="/usr/local/bin/wp"
LEGACY_LIB="/usr/local/lib/wp-cli.phar"

fail() { echo -e "\nwh wp-install: ERROR: $*\n" >&2; exit 1; }

# Is this file a wp-cli phar? Read the shebang into a variable rather than 'head | grep -q': under
# 'set -o pipefail' a grep that exits early can leave head with SIGPIPE and make the whole pipeline
# report failure on a file that actually matched.
is_phar() {
    local line
    line=$(head -n1 "$1" 2>/dev/null) || return 1
    [[ "$line" == '#!'*php* ]]
}

# What is at a given path right now: a phar, a wrapper, or something else?
describe() {
    local p="$1" own ver
    [[ -e "$p" ]] || { echo "absent"; return; }
    own=$(stat -c '%U:%G %a' "$p" 2>/dev/null)
    if is_phar "$p"; then
        ver=$(php "$p" cli version 2>/dev/null | awk '{print $2}' | head -n1)
        echo "wp-cli phar ${ver:-(version not readable under the default CLI php)}   [$own]"
    elif [[ "$(head -n1 "$p" 2>/dev/null)" == '#!'* ]]; then
        echo "SHELL WRAPPER, $(wc -c < "$p") bytes   [$own]"
    else
        echo "unrecognised file   [$own]"
    fi
}

# Which of this server's PHP versions can actually run the phar? This is the useful half of the
# smoke test: wp-cli's supported window has an UPPER bound as well as a lower one, and some machines
# here default to a CLI php newer than any site targets (wh-7/wh-8 default to 8.5).
smoke() {
    local phar="$1" ok="" bad="" bin v
    for bin in /usr/bin/php[0-9].[0-9] /usr/bin/php[0-9].[0-9][0-9]; do
        [[ -x "$bin" ]] || continue          # an unmatched glob arrives as its own literal text
        v=$(basename "$bin")
        if "$bin" "$phar" --info >/dev/null 2>&1; then ok="$ok $v"; else bad="$bad $v"; fi
    done
    echo "    runs under: ${ok:-  (NONE)}"
    [[ -n "$bad" ]] && echo "    fails under:$bad   <- fine unless a SITE targets one of these"
    [[ -n "$ok" ]]
}

command -v curl      >/dev/null || fail "'curl' not found"
command -v sha512sum >/dev/null || fail "'sha512sum' not found"
command -v sudo      >/dev/null || fail "'sudo' not found - this command needs to write $TARGET"

echo -e "\nwh wp-install: $(hostname)\n"
echo "  BEFORE:"
echo "    $TARGET      : $(describe "$TARGET")"
echo "    $LEGACY_LIB : $(describe "$LEGACY_LIB")"
ON_PATH=$(command -v wp 2>/dev/null)
[[ -n "$ON_PATH" && "$(readlink -f "$ON_PATH")" != "$(readlink -f "$TARGET" 2>/dev/null)" ]] \
    && echo "    NOTE: 'wp' on PATH resolves to $ON_PATH, which is not $TARGET - that copy will still shadow this install"

TMPD=$(mktemp -d /tmp/wh-wp-install.XXXXXX) || fail "could not create a temp dir"
trap 'rm -rf "$TMPD"' EXIT

# ---- the published checksum first, so we can skip a pointless download ---------------------------
echo -e "\n  Fetching published checksum ..."
curl -fsSL "$SHA_URL" -o "$TMPD/wp-cli.phar.sha512" || fail "could not download $SHA_URL"
EXPECTED=$(awk '{print $1}' "$TMPD/wp-cli.phar.sha512" | head -n1)
[[ "$EXPECTED" =~ ^[0-9a-f]{128}$ ]] || fail "published checksum is not a sha512 hash (got '${EXPECTED:0:40}')"
echo "    expected sha512: ${EXPECTED:0:32}..."

ALREADY_CURRENT=false
if [[ -f "$TARGET" ]] && is_phar "$TARGET"; then
    CURRENT=$(sha512sum "$TARGET" | awk '{print $1}')
    [[ "$CURRENT" == "$EXPECTED" ]] && ALREADY_CURRENT=true
fi

if [[ "$ALREADY_CURRENT" == true ]]; then
    echo -e "\n  Installed phar already matches the published checksum - nothing to download."
    # ...but the OWNERSHIP invariant is enforced even when the bytes are current: a forge-owned copy
    # of the right version is still writable by forge, which is the exact thing root ownership
    # exists to stop. (wh-3's existing phar is a forge-owned current 2.12 - this is the live case.)
    OWN=$(stat -c '%U:%G %a' "$TARGET")
    if [[ "$OWN" != "root:root 755" ]]; then
        echo "  Enforcing ownership/mode on the existing phar: $OWN -> root:root 755"
        sudo chown root:root "$TARGET" || fail "could not chown $TARGET"
        sudo chmod 0755 "$TARGET"      || fail "could not chmod $TARGET"
    fi
else
    echo -e "\n  Downloading $WP_URL ..."
    curl -fsSL "$WP_URL" -o "$TMPD/wp-cli.phar" || fail "could not download $WP_URL"

    echo "  Verifying ..."
    GOT=$(sha512sum "$TMPD/wp-cli.phar" | awk '{print $1}')
    [[ "$GOT" == "$EXPECTED" ]] || fail "CHECKSUM MISMATCH - refusing to install.
       expected $EXPECTED
       got      $GOT"
    echo "    checksum OK"

    echo "  Smoke-testing the downloaded phar against this server's PHP versions ..."
    smoke "$TMPD/wp-cli.phar" || fail "the downloaded phar does not run under ANY php on this server - nothing installed"

    # Keep the outgoing phar. Swapping a production binary with no way back is not worth the tidiness,
    # and a rollback is then just an 'install' away. (A wrapper is not worth keeping - it is in git here.)
    if [[ -f "$TARGET" ]] && is_phar "$TARGET"; then
        PREV_VER=$(php "$TARGET" cli version 2>/dev/null | awk '{print $2}' | head -n1)
        BACKUP="/var/backups/wp-cli-${PREV_VER:-unknown}-$(date -u +%Y%m%dT%H%MZ).phar"
        echo "  Backing up the current phar -> $BACKUP"
        sudo mkdir -p /var/backups && sudo cp -p "$TARGET" "$BACKUP" || fail "could not back up $TARGET"
    fi

    echo "  Installing to $TARGET (root:root 0755) ..."
    sudo -n true 2>/dev/null || echo "    (sudo may prompt for your password)"
    sudo install -o root -g root -m 0755 "$TMPD/wp-cli.phar" "$TARGET.new" || fail "could not stage $TARGET.new"
    sudo mv -f "$TARGET.new" "$TARGET"                                     || fail "could not move $TARGET.new into place"
fi

# ---- retire the older shapes --------------------------------------------------------------------
if [[ -e "$LEGACY_LIB" ]]; then
    echo -e "\n  Removing superseded $LEGACY_LIB"
    echo "    (it existed only to back a pinned shell wrapper - 'wh wp' now selects the PHP per site)"
    sudo rm -f "$LEGACY_LIB" || fail "could not remove $LEGACY_LIB"
fi

# Stray copies in home directories are somebody's own file - report them, never touch them.
STRAYS=$(ls -1 /home/*/wp-cli.phar /home/*/*/wp-cli.phar 2>/dev/null)
if [[ -n "$STRAYS" ]]; then
    echo -e "\n  NOTE: stray wp-cli copies exist under /home (left alone - remove them yourself if unwanted):"
    echo "$STRAYS" | sed 's/^/    /'
fi

echo -e "\n  AFTER:"
echo "    $TARGET      : $(describe "$TARGET")"
echo "    $LEGACY_LIB : $(describe "$LEGACY_LIB")"
[[ "$ALREADY_CURRENT" == true ]] || { echo "    PHP compatibility of the installed phar:"; smoke "$TARGET"; }

[[ -n "${BACKUP:-}" ]] && echo -e "\n  Roll back with:  sudo install -o root -g root -m 0755 $BACKUP $TARGET"

echo -e "\n  Done. Use it per-site with 'wh wp' (which runs it under each site's own PHP) - ie:"
echo -e "    cd ~/<site-folder> && wh wp core version\n"
