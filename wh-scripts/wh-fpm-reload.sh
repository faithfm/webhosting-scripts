#!/bin/bash

# Restart detected php-fpm services
echo -e "\nRestarting FPM:"
php_services=$(ls /etc/init.d/ | grep php | grep fpm)
for php_service in $php_services
do
  ( flock -w 10 9 || exit 1
    echo "   (${php_service})..."; sudo -S service ${php_service} reload ) 9>/tmp/fpmlock
done
echo ""

# Allow anyone to delete/modify the lock file
chmod 666 /tmp/fpmlock 2>/dev/null  
