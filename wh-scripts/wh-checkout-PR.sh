#!/bin/bash

# Designed to be use as a post-receive hook on a git repo.
#
# Usage:
#    wh checkout-PR [--MASTER-BRANCH-ONLY] [</path/to/working-tree-for-bare-repos>]
#
# When called by a git post-receive hook, this script will:
#   - Checkout the latest commit of any branch (Hard-reset allows deployment of force-pushes)

echo -e "\nDeploying code from post-receive script:\n"

# Check for --MASTER-BRANCH-ONLY argument and remove it from the argument list
if [[ "$1" == "--MASTER-BRANCH-ONLY" ]]; then
  echo "  --MASTER-BRANCH-ONLY argument was specified - restricting deployment to commits from 'master' branch."
  WH_MASTER_BRANCH_ONLY=true
  shift
fi

# Ensure that input exists on STDIN  (expected from git post-receive hook)
if ! read -t 0; then
  echo "ERROR: STDIN not detected.  This script is designed to be called by a git post-receive hook."
  exit 1
fi

# Checkout the latest commit (Hard-reset allows deployment of force-pushes)
echo -e "\nChecking out latest commit...\n"
while read oldrev newrev ref
do
  # Deploy commit IF this is the 'master' branch OR if the '--MASTER-BRANCH-ONLY' argument was not specified
  if [[ $ref =~ .*/master$ ]] || [[ "$WH_MASTER_BRANCH_ONLY" != "true" ]]; then
    echo "Ref $ref successfully received. Deploying..."
    wh git checkout -f $newrev
    wh git clean -f -d
  else
    echo "Ref $ref successfully received. Doing nothing: only the master branch may be deployed on this server."
  fi
done

echo ""
