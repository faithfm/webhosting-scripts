#!/bin/bash

# When called by a Forge application deploy script, this script will:
#   - Checkout the latest commit of master branch (Hard-reset allows deployment of force-pushes)
#   - Perform deployment tasks - ie: composer install, fpm reload, etc
#
# The Forge application deploy script should typically contain the following two simple lines:
#   cd /home/username/site.com.au
#   wh deploy-forge-production

# BRANCH is 'master' if not specified as first argument
BRANCH=${1:-master}

# Ensure project directory is detected
if [[ -z "$WH_PROJECT_DIR" ]]; then
  echo "ERROR: project directory not detected"
  exit 1
fi

# Ensure current directory is the project directory
if [[ "$WH_CURRENT_DIR" != "$WH_PROJECT_DIR" ]]; then
  echo "ERROR: project directory must match current directory"
  exit 1
fi


# Checkout the latest commit of the specified branch (Hard-reset allows deployment of force-pushes)
git fetch origin $BRANCH 2>&1
git checkout -f $BRANCH 2>&1
git reset --hard origin/$BRANCH 2>&1
