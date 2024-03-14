#!/bin/bash

# This script is used to deploy a PHP (with composer) project - after the code has checked-out/updated.

# Ensure project directory is detected, and make it the current working directory
if [[ -z "$WH_PROJECT_DIR" ]]; then
  echo "ERROR: project directory not detected"
  exit 1
fi
cd "$WH_PROJECT_DIR"


# Install composer dependencies
echo -e "\nInstalling composer dependencies...\n"
composer install --no-interaction --prefer-dist --optimize-autoloader

# Restart detected php-fpm services
wh fpm-reload

# Restart queue workers and clear cache (for Laravel projects)
if [[ "$WH_LARAVEL_DETECTED" == "true" ]]; then
    echo -e "\nLaravel detected - execute php artisan commands...\n"

    # Restart queue workers (only required for some projects, but doesn't hurt to run it anyway)
    echo -e "\n Restarting queue workers (if any)...\n"
    $WH_PHP_CMD artisan queue:restart
    
    # Clear laravel cache (fixes problem with job workers not being called - https://github.com/laravel/framework/issues/16476#issuecomment-476036660)
    echo -e "\n Clearing Laravel cache...\n"
    $WH_PHP_CMD artisan cache:clear
else
    echo -e "\nLaravel not detected.\n"
fi

# Build npm if Vite detected
if [[ "$WH_VITE_DETECTED" == "true" ]]; then
    echo -e "\nVite detected - execute npm commands...\n"
    wh update-nvm --if-missing
    nvm install
    nvm use
    npm ci
    npm run build
fi

# RECOMMENDED BY LARAVEL, BUT UNSAFE BECAUSE WE USE SAME TABLES FOR DEV+STAGING+PRODUCTION!  -  REMOVED
# if [ -f artisan ]; then
#     php artisan migrate --force
# fi

# Send deployment event to New Relic
wh nr-deployment-capture
