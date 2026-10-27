#!/bin/bash

# Run wp-cli against the current site using the PHP version the SITE targets (WH_PHP_CMD - detected
# from the site's nginx 'fastcgi_pass' directive), rather than the machine's default command-line PHP.
#
# This matters more here than anywhere else 'wh' wraps a tool. wp-cli does not talk TO WordPress -
# it BOOTS WordPress inside its own PHP process. Every plugin, every theme, every 'core update-db'
# migration and every 'search-replace' pass executes under whichever PHP started the phar. So on a
# multi-PHP server a bare 'wp' runs the site's own code under an interpreter the site never uses:
# wh-3 defaults to PHP 7.4 on the command line while crm-ffm, crm-staging-ffm and store-ffm all run
# 8.4.
#
# Unlike 'wh php' and 'wh composer', this command FAILS CLOSED when the site's PHP version cannot be
# detected (Michael, 2026-08-26). Those two run YOUR code under a default interpreter and a warning
# is proportionate; this one runs the SITE's code, where guessing the interpreter for a live
# WordPress install is not a safe default.
#
# One current wp-cli phar serves every site on a server (see 'wh wp-install' for why) - what varies
# per site is only the PHP that executes it, which is this script's whole job.
#
# Accepts the same arguments as the normal 'wp' command - ie:
#   wh wp core version
#   wh wp plugin list --status=active
#   wh wp search-replace old.example.com new.example.com --dry-run
#
# '--path' is supplied automatically from the site's nginx webroot unless you pass your own, or the
# site's own user has a 'path:' in its ~/.wp-cli/config.yml (for a WordPress below the webroot).

fail() { echo "wh wp: ERROR: $*" >&2; exit 1; }

# ---- wp-cli itself ------------------------------------------------------------------------------
[[ -n "${WH_WP_PHAR:-}" ]] || fail "no usable wp-cli phar on this server - 'wp' is either absent or a shell
       wrapper that must not be handed to PHP (check WH_WP_PHAR in 'wh show-env').
       An admin account can install or replace it with:  wh wp-install"

# ---- site context (from wh.sh) ------------------------------------------------------------------
[[ "${WH_SITE_VALID:-false}" == true ]] || fail "no site detected - cd into the site's folder first (check 'wh show-env')"

if [[ -z "${WH_PHP_CMD:-}" ]]; then
    fail "site PHP version not detected for '$WH_SITE' (WH_PHP_CMD empty - check 'wh show-env').
       Refusing to boot this site's WordPress under the default CLI PHP: every plugin would run
       under an interpreter the site does not use. Fix the nginx detection first - or, if you are
       certain which version you want:  <phpX.Y> $WH_WP_PHAR --path=<webroot> <args>"
fi
command -v "$WH_PHP_CMD" >/dev/null 2>&1 || fail "detected PHP command '$WH_PHP_CMD' is not installed on this server"

# Not fatal, but worth saying: wp-cli writes as whoever runs it (its own ~/.wp-cli cache, and any
# file a command generates), so running as an admin account can leave root/forge-owned files behind
# inside a site that the site's own user then cannot rewrite.
if [[ "${WH_USER_VALID:-false}" != true ]]; then
    echo "wh wp: WARNING: running as '$USER', not the site's user '${WH_USER:-?}' - anything wp-cli writes will be owned by $USER" >&2
fi

# ---- '--path' -----------------------------------------------------------------------------------
# Tell wp-cli where WordPress lives. Use the site's nginx webroot unless the caller supplied their
# own --path. (WordPress also looks one directory ABOVE the webroot for wp-config.php, which is how
# the older sites on this fleet are laid out - hence both are accepted as evidence of a WP install.)
inject_path=true
for arg in "$@"; do
    case "$arg" in
        --path|--path=*) inject_path=false; break ;;
    esac
done

# A site whose WordPress lives BELOW its webroot (attsurvey.adventist.org.au: the webroot serves a
# React front end, WordPress is htdocs/results) names the real path in its own user's wp-cli config.
# Injecting the webroot would override that file, so leave --path to wp-cli - but only for the
# site's own user, and only when that path lies inside THIS site's webroot: forge owns several
# sites, and a path meant for one must never send 'wh wp' at another (Kedson, 2026-10-27).
if [[ "$inject_path" == true && "${WH_USER_VALID:-false}" == true && -n "${WH_WEBROOT_DIR:-}" ]]; then
    cfg_path=$(sed -n 's/^path:[[:space:]]*//p' "${WP_CLI_CONFIG_PATH:-$HOME/.wp-cli/config.yml}" 2>/dev/null \
        | head -n1 | tr -d "\r\"'")
    [[ "$cfg_path" == "${WH_WEBROOT_DIR%/}/"* ]] && inject_path=false
fi

if [[ "$inject_path" == false ]]; then
    exec "$WH_PHP_CMD" "$WH_WP_PHAR" "$@"
fi

[[ -n "${WH_WEBROOT_DIR:-}" ]] || fail "site webroot not detected (WH_WEBROOT_DIR empty - check 'wh show-env') - pass --path=... yourself"
[[ -f "$WH_WEBROOT_DIR/wp-config.php" || -f "$WH_WEBROOT_DIR/../wp-config.php" ]] \
    || fail "'$WH_SITE' does not look like a WordPress site (no wp-config.php in or above '$WH_WEBROOT_DIR')"

exec "$WH_PHP_CMD" "$WH_WP_PHAR" --path="$WH_WEBROOT_DIR" "$@"
