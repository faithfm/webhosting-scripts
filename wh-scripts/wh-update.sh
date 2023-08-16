#!/bin/bash

# This script will update the webhosting-scripts repo and reinstall the scripts, cron jobs, etc.

wh_script="wh.sh"
crond_script="wh.crond"
bash_completion_script="wh.bash_completion"
pyenv_profiled_script="wh.pyenv-profile.d"

# Check if the user has write access to the WH_BASE_DIR
if [ ! -w "$WH_BASE_DIR" ]; then
  echo "You don't have permission to update the scripts"
  exit 1
fi

# Perform a git pull to get the latest code
echo -e "\nAbout to update webhosting-scripts from git repo..."
cd $WH_BASE_DIR
git fetch origin master
git checkout -f master
git reset --hard origin/master

echo -e "\nReinstalling (symlinks, cron jobs, etc)..."

# Create a symlink to the wh.sh script
if [ -f "$WH_BASE_DIR/$wh_script" ]; then
  sudo ln -sfn "$WH_BASE_DIR/$wh_script" /usr/local/bin/wh
else
  echo "Error: $WH_BASE_DIR/$wh_script not found."
fi

# Create a symlink to the wh.bash_completion script
if [ -f "$WH_BASE_DIR/$bash_completion_script" ]; then
  sudo ln -sfn "$WH_BASE_DIR/$bash_completion_script" /etc/bash_completion.d/wh
else
  echo "Error: $WH_BASE_DIR/$bash_completion_script not found."
fi

# Install wh.crond
if [ -f "$WH_BASE_DIR/$crond_script" ]; then
  sudo cp "$WH_BASE_DIR/$crond_script" /etc/cron.d/wh
  sudo chown root:root /etc/cron.d/wh
  sudo chmod 644 /etc/cron.d/wh
else
  echo "Error: $WH_BASE_DIR/$crond_script not found."
fi

# Install wh.pyenv-profile.d
if [ -f "$WH_BASE_DIR/$pyenv_profiled_script" ]; then
  sudo cp "$WH_BASE_DIR/$pyenv_profiled_script" /etc/profile.d/pyenv.sh
else
  echo "Error: $WH_BASE_DIR/$pyenv_profiled_script not found."
fi

# Install python venv requirements
echo -e "\nInstalling python requirements...\n"
if [ -d "$WH_BASE_DIR/venv" ]; then
  cd $WH_BASE_DIR
  source venv/bin/activate
  pip install --upgrade pip
  pip install -r requirements.txt
  deactivate
else
  echo -e "\n Warning: Couldn't install python requirements - venv folder does not yet exist."
fi

# Most permissions come from the git repo, but ensure that "others" can't read the main repo folder, but they CAN read the script folder
chmod o=x $WH_BASE_DIR
chmod o=rx $WH_SCRIPT_DIR


# EXTRA SCRIPT-SPECIFIC INSTALLATION REQUIREMENTS

# For wh-nr-deploy-XXX scripts:  Ensure the /var/log/app-deploys folder exists
app_deploy_log_dir="/var/log/app-deploys"
if [ ! -d "$app_deploy_log_dir" ]; then
    echo -e "\nNew Relic app deploys log folder ($app_deploy_log_dir) does not exist - creating it..."
    sudo mkdir "$app_deploy_log_dir"
    sudo chmod 777 "$app_deploy_log_dir"
fi


echo -e "\nDone."
