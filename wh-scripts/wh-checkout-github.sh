#!/bin/bash

# When called by a Laravel Forge application deploy script, this script will:
#   - Checkout the latest commit of master branch (Hard-reset allows deployment of force-pushes)
#
# The Forge application deploy script should typically contain the following two simple lines:
#   cd /home/username/site.com.au
#   wh deploy-forge-production

# BRANCH is 'master' if not specified as first argument
BRANCH=${1:-master}

# Checkout the latest commit of the specified branch (Hard-reset allows deployment of force-pushes)
wh git fetch origin $BRANCH 2>&1
wh git checkout -f $BRANCH 2>&1
wh git reset --hard origin/$BRANCH 2>&1
