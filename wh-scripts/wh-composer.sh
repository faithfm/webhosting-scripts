#!/bin/bash

# Run composer using the PHP version targeted by the current site (WH_PHP_CMD) rather than the
# default command-line PHP version.
#
# Composer resolves platform requirements - and runs any composer scripts (ie: the
# 'post-autoload-dump' artisan hooks) - against whichever PHP version executes it, so calling it
# this way is what keeps the 'vendor/' folder matched to the PHP version the site actually runs.
#
# Accepts the same arguments as the normal 'composer' command - ie:
#   wh composer install --no-interaction --prefer-dist --optimize-autoloader
#   wh composer require some/package

composer_bin=$(command -v composer)
if [[ -z "$composer_bin" ]]; then
    echo "wh composer: ERROR: 'composer' not found in PATH" >&2
    exit 1
fi

if [[ -n "$WH_PHP_CMD" ]]; then
    if command -v "$WH_PHP_CMD" >/dev/null 2>&1; then
        exec "$WH_PHP_CMD" "$composer_bin" "$@"
    fi
    echo "wh composer: WARNING: detected PHP command '$WH_PHP_CMD' not found - falling back to the default composer/PHP" >&2
else
    echo "wh composer: WARNING: site PHP version not detected (check 'wh show-env') - falling back to the default composer/PHP" >&2
fi

exec "$composer_bin" "$@"
