#!/bin/bash

# Run PHP using the version targeted by the current site (WH_PHP_CMD - detected from the site's
# nginx 'fastcgi_pass' directive) rather than the default command-line PHP version - which is
# frequently an older version on our multi-PHP servers.
#
# Accepts the same arguments as the normal 'php' command - ie:
#   wh php -v
#   wh php artisan queue:restart
#   wh php -r 'echo PHP_VERSION;'

if [[ -n "$WH_PHP_CMD" ]]; then
    if command -v "$WH_PHP_CMD" >/dev/null 2>&1; then
        exec "$WH_PHP_CMD" "$@"
    fi
    echo "wh php: WARNING: detected PHP command '$WH_PHP_CMD' not found - falling back to the default 'php'" >&2
else
    echo "wh php: WARNING: site PHP version not detected (check 'wh show-env') - falling back to the default 'php'" >&2
fi

exec php "$@"
