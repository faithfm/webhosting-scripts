#!/bin/bash

# When called by a Laravel Forge application deploy script, this script will:
#   - Checkout the latest commit of the specified branch (Hard-reset allows deployment of force-pushes)
#
# Usage:
#    wh checkout-github [branch]        # 'master' if no branch is specified
#
# The Forge application deploy script should typically contain the following three simple lines:
#   cd /home/username/site.com.au
#   wh checkout-github
#   wh composer-deploy-sessions
#
# Note: the 'cd' line matters - Forge deploy scripts start in the home folder, which isn't
# specific enough to identify the site when a user hosts more than one.

# BRANCH is 'master' if not specified as first argument
BRANCH=${1:-master}

# Checkout the latest commit of the specified branch (Hard-reset allows deployment of force-pushes)
wh git fetch origin $BRANCH 2>&1
wh git checkout -f $BRANCH 2>&1
wh git reset --hard origin/$BRANCH 2>&1
