#!/bin/bash

# Restart detected php-fpm services
echo -e "\nRestarting FPM:"
php_services=$(ls /etc/init.d/ | grep php | grep fpm)
for php_service in $php_services
do
    # refer to this page for info about directory/file locking - https://laracasts.com/discuss/channels/forge/deploy-script-issue-with-tmpfpmlock
    if mkdir /tmp/fpmlockdir 2>/dev/null; then
        echo "   (${php_service})..."
        sudo -S service ${php_service} reload
        rmdir /tmp/fpmlockdir
    else
        echo "Failed to acquire lock for ${php_service}. Skipping..."
        exit 1
    fi
done
echo ""
