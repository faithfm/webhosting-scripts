#!/bin/bash

# This script will install/update the NVM (Node Version Manager)... 
# ...and update the default node version to the latest LTS version.

cd $HOME

# If --if-missing flag is used, then check if NVM is already installed
if [ "$1" == "--if-missing" ] && [ -d "$HOME/.nvm" ]; then
  echo -e "\nNVM (Node Version Manager) is already installed. Skipping...\n"
  exit 0
fi

# Install NVM
echo -e "\nInstalling/updating the NVM (Node Version Manager)...\n"
latest_nvm_version=$(curl -s https://api.github.com/repos/nvm-sh/nvm/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/$latest_nvm_version/install.sh | bash

# Load NVM
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"  # This loads nvm
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"  # This loads nvm bash_completion

# Update the default node version to the latest LTS version
echo -e "\nUpdating the default node version to the latest LTS version...\n"
nvm install --lts
nvm alias default lts/*
nvm use default

echo -e "\nNVM (Node Version Manager) installation/update complete.\n"
