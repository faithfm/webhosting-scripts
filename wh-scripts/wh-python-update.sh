#!/bin/bash

echo "This script is used to occasionally update pyenv, python, and the python venv for our web-hosting scripts"
echo ""

# Ensure suggested build environment is met - ie: https://github.com/pyenv/pyenv/wiki#suggested-build-environment
echo -e "\nInstalling recommended dependencies for pyenv build environment...\n"
sudo apt update && sudo apt -y install build-essential libssl-dev zlib1g-dev \
  libbz2-dev libreadline-dev libsqlite3-dev curl \
  libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev

# Install/update pyenv
if [ -d "$PYENV_DIR" ]; then
  echo -e "\nUpdating pyenv...\n"
  cd $PYENV_DIR
  git pull
else
  echo -e "\nInstalling pyenv...\n"
  git clone https://github.com/pyenv/pyenv.git $PYENV_DIR
  cd $PYENV_DIR
fi
src/configure && make -C src

# install required version of python
echo -e "\nInstalling python $PYENV_VERSION (via pyenv)...\n"
pyenv install -s $PYENV_VERSION:latest

# ensure the correct version of python is installed (won't work first time until shell has been restarted)
detected_version=$(python3 --version)
detected_version="${detected_version#* }"   # remove "Python " from the start of the string
if [[ ! "$detected_version" == "$PYENV_VERSION"* ]]; then
  echo -e "\nWARNING: Python version doesn't match ($detected_version <> $PYENV_VERSION).  You probably need to restart the shell.\n"
  exit 1
fi

# recreate the venv folder (for web hosting scripts) using this version of python
echo -e "\nRecreating venv using this version of python...\n"
rm -r $WH_BASE_DIR/venv  2> /dev/null
python3 -m venv $WH_BASE_DIR/venv

# Install python venv requirements
cd $WH_BASE_DIR
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

echo -e "\nDone."

