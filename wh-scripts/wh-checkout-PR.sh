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

# Check for optional working tree argument
if [[ -n "$1" ]]; then
  echo "  Repo type = BARE  (working tree was specified)..."

  # If a working tree argument was passed, then this is a BARE repo - set project directory and worktree prefix
  WH_PROJECT_DIR=$1
  WH_WORKTREE_PREFIX=" --work-tree=$1 "
  shift

  # BARE repos should call git from the current (git repo) directory - so don't change directory
  # (since post-receive hooks for BARE repos are called from the XXX.git repo directory)

else
  echo "  Repo type = NORMAL  (working tree was not specified)..."

  # WORKAROUND: since git doesn't automatically detect the correct working tree when called from a git post-receive hook.
  #    Prevent "remote: fatal: Not a git repository: '.'" errors.
  #    See: https://stackoverflow.com/questions/6394366/problem-with-git-hook-for-updating-site
  unset $(git rev-parse --local-env-vars)

  # NORMAL repos should call git from the parent (project) directory - so change directory
  # (since post-receive hooks for NORMAL repos are called from the .git repo directory)
  cd "$WH_PROJECT_DIR"

fi


# Ensure project directory is detected
if [[ -n "$WH_PROJECT_DIR" ]]; then
  echo "  Current directory = $(pwd)"
  echo "  Project / working directory = $WH_PROJECT_DIR"
  echo ""
else
  echo "ERROR: project directory not detected.  This script is designed to be called by a git post-receive hook."
  exit 1
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
    git checkout $WH_WORKTREE_PREFIX -f $newrev
    git clean $WH_WORKTREE_PREFIX -f -d
  else
    echo "Ref $ref successfully received. Doing nothing: only the master branch may be deployed on this server."
  fi
done

echo ""
