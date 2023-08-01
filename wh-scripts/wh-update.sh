#!/bin/bash

# Get the parent directory of the script
script_dir="$(dirname "$0")"
repo_dir=$(realpath "$script_dir/..")

wh_script="wh.sh"
bash_completion_script="wh.bash_completion"

# Check if the user has write access to the repo_dir
if [ ! -w "$repo_dir" ]; then
  echo "You don't have permission to update the scripts"
  exit 1
fi

# Perform a git pull to get the latest code
echo -e "\nAbout to update webhosting-scripts from git repo..."
cd $repo_dir
git fetch origin master
git checkout -f master
git reset --hard origin/master

echo -e "\nReinstalling (symlinks, cron jobs, etc)..."

# Create a symlink to the wh.sh script if it exists
if [ -f "$repo_dir/$wh_script" ]; then
  sudo ln -sfn "$repo_dir/$wh_script" /usr/local/bin/wh
else
  echo "Error: $repo_dir/$wh_script not found."
fi

# Create a symlink to the wh.bash_completion script if it exists
if [ -f "$repo_dir/$bash_completion_script" ]; then
  sudo ln -sfn "$repo_dir/$bash_completion_script" /etc/bash_completion.d/wh
else
  echo "Error: $repo_dir/$bash_completion_script not found."
fi

# Most permissions come from the git repo, but ensure that "others" can't read the main repo folder, but they CAN read the script folder
chmod o=x $repo_dir
chmod o=rx $script_dir

echo -e "\nDone."
