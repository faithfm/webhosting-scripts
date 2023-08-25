#!/bin/bash

# Designed to be use as a post-receive hook on a bare git repo.
#   - Pass the project directory (working tree) argument to 'wh checkout-PR'


# check that an argument containg the project directory (working tree) was passed
if [ -z "$1" ]; then
  echo "Error: No project directory (working tree) specified."
  exit 1
fi

# set project directory and call the main checkout-PR script
export $WH_BARE=true
export $WH_PROJECT_DIR=$1
wh checkout-PR
