#!/bin/bash

# When called by a git post-receive hook, this script will:
#   - Checkout the latest commit of any branch (Hard-reset allows deployment of force-pushes)


# Ensure project directory is detected, and make it the current working directory
if [[ -z "$WH_PROJECT_DIR" ]]; then
  echo "ERROR: project directory not detected"
  exit 1
fi

# Change to the appropriate directory to call git from:
#  - for NORMAL repos this is the project (parent) directory
#  - for BARE repos this is the current directory already
if [[ -z "$WH_BARE" ]] || [[ "$WH_BARE" != "true" ]]; then
  # NORMAL repo
  cd "$WH_PROJECT_DIR"
fi


# Allow the correct GIT working tree to be detected when called from a git post-receive hook
#    Prevent "remote: fatal: Not a git repository: '.'" errors.
#    See: https://stackoverflow.com/questions/6394366/problem-with-git-hook-for-updating-site
unset $(git rev-parse --local-env-vars)

# ensure that input exists on STDIN  (expected from git post-receive hook)
if ! read -t 0; then
  echo "ERROR: STDIN not detected.  This script is designed to be called by a git post-receive hook."
  exit 1
fi

# Checkout the latest commit of any branch (Hard-reset allows deployment of force-pushes)
echo -e "\nChecking out latest commit...\n"
while read oldrev newrev ref
do
  echo "Ref $ref sucessfully received. Deploying to staging..."
  git checkout -f $newrev
  git clean -f -d
done
