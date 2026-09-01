#!/bin/bash

# Run Laravel artisan for the current project using the PHP version the SITE targets (WH_PHP_CMD -
# detected from the site's nginx 'fastcgi_pass' directive), rather than the machine's default
# command-line PHP.
#
# Like 'wh wp' - and unlike 'wh php' / 'wh composer' - this command FAILS CLOSED when the site's PHP
# version cannot be detected (Michael, 2026-09-02). artisan does not talk TO the application - it
# BOOTS it: every service provider, every queued job, every migration executes under whichever PHP
# started artisan. Guessing the interpreter for a live Laravel app is not a safe default, so where
# 'wh php artisan' warns and falls back, this refuses.
#
# Accepts the same arguments as 'php artisan' - ie:
#   wh artisan migrate --force
#   wh artisan queue:restart
#   wh artisan tinker
#
# artisan is invoked by full path from WH_PROJECT_DIR (the top-level .git ancestor), so this works
# from anywhere inside the project - eg: public/ - where a bare 'php artisan' cannot even find the
# file. The working directory is left wherever you are standing, so relative arguments resolve
# there; only when you are OUTSIDE the project tree (in practice the cwd=$HOME site-auto-detect
# case) does it cd to the project root first. Laravel itself resolves its base path from the
# artisan file's location, never from the cwd.

fail() { echo "wh artisan: ERROR: $*" >&2; exit 1; }

# ---- project + artisan ---------------------------------------------------------------------------
# (The -f check on the artisan file is exactly what sets WH_LARAVEL_DETECTED in wh.sh.)
[[ -n "${WH_PROJECT_DIR:-}" ]] || fail "no project detected - cd into the site's folder first (check 'wh show-env')"
[[ -f "$WH_PROJECT_DIR/artisan" ]] || fail "'$WH_PROJECT_DIR' is not a Laravel project (no 'artisan' file at its root)"

# ---- site PHP (from wh.sh) - fail closed ---------------------------------------------------------
[[ "${WH_SITE_VALID:-false}" == true ]] || fail "no site detected - cd into the site's folder first (check 'wh show-env')"

if [[ -z "${WH_PHP_CMD:-}" ]]; then
    fail "site PHP version not detected for '$WH_SITE' (WH_PHP_CMD empty - check 'wh show-env').
       Refusing to boot this Laravel app under the default CLI PHP: every provider, job and
       migration would run under an interpreter the site does not use. Fix the nginx detection
       first - or, if you are certain which version you want:  <phpX.Y> $WH_PROJECT_DIR/artisan <args>"
fi
command -v "$WH_PHP_CMD" >/dev/null 2>&1 || fail "detected PHP command '$WH_PHP_CMD' is not installed on this server"

# Not fatal, but worth saying: artisan writes as whoever runs it (storage/, bootstrap/cache/, the
# laravel.log), so running as an admin account can leave files behind that the site's own user then
# cannot rewrite.
if [[ "${WH_USER_VALID:-false}" != true ]]; then
    echo "wh artisan: WARNING: running as '$USER', not the site's user '${WH_USER:-?}' - anything artisan writes will be owned by $USER" >&2
fi

# ---- working directory ---------------------------------------------------------------------------
# Stay wherever the caller is standing when that is already inside the project tree; cd to the
# project root only from outside it. Matching "$PWD/" keeps the prefix test directory-boundary-safe
# ('site.com-old' does not match 'site.com/*').
case "$PWD/" in
    "$WH_PROJECT_DIR"/*) : ;;
    *) cd "$WH_PROJECT_DIR" || fail "cannot cd to project directory '$WH_PROJECT_DIR'" ;;
esac

exec "$WH_PHP_CMD" "$WH_PROJECT_DIR/artisan" "$@"
