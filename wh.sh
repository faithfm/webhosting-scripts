#!/bin/bash


###  Determine the key environment variables that can be expected/used in any webhosting script  ###

export WH_BASE_DIR=$(dirname $(readlink -f "$0"))
export WH_SCRIPT_DIR="$WH_BASE_DIR/wh-scripts"
export WH_CURRENT_DIR=$(pwd)
export PYENV_VERSION=$(cat $WH_BASE_DIR/.python-version)
export PYENV_DIR="/home/shared/.pyenv"

# Extract WH_USER + WH_SITE from WH_CURRENT_DIR if possible
export WH_USER=""
export WH_SITE=""
if [[ "$WH_CURRENT_DIR" =~ ^/home/([^/]*)/?([^/]*)? ]]; then
    WH_USER="${BASH_REMATCH[1]}"
    WH_SITE="${BASH_REMATCH[2]}"
fi

# Check WH_USER validity
if [[ "$WH_USER" == "$USER" ]]; then
    export WH_USER_VALID=true
else
    export WH_USER_VALID=false
fi

# Check WH_SITE validity
if [[ -f "/etc/nginx/sites-available/$WH_SITE" ]]; then
    export WH_SITE_VALID=true
    export WH_WEBROOT_DIR=$(grep '^\s*root\s' "/etc/nginx/sites-available/$WH_SITE" | awk '{ print $2 }' | tr -d ';')
else
    export WH_SITE_VALID=false
fi

# Find the project directory   (highest-level directory in the WH_CURRENT_DIR path containing a .git subfolder)
SEARCH_DIR="$WH_CURRENT_DIR"
export WH_PROJECT_DIR=""
export WH_PROJECT_ENV=""
export WH_APP_NAME=""
export WH_LARAVEL_DETECTED=false
while [[ "$SEARCH_DIR" != "/" && "$SEARCH_DIR" != "." ]]; do
    if [[ -d "$SEARCH_DIR/.git" ]]; then
        export WH_PROJECT_DIR="$SEARCH_DIR"
        export WH_PROJECT_ENV="$SEARCH_DIR/.env"
        if [[ -f "$WH_PROJECT_ENV" ]]; then
            export WH_APP_NAME=$(grep '^APP_NAME=' "$WH_PROJECT_ENV" | sed 's/.*=//' | sed 's/"//g')
        fi
        if [[ -f "$WH_PROJECT_DIR/artisan" ]]; then
            export WH_LARAVEL_DETECTED=true
        fi
    fi
    SEARCH_DIR=$(dirname "$SEARCH_DIR")
done


###  Detect command-line parameters and show script usage as required  ###

# Function to print usage information
print_usage() {
    echo "Faith FM web hosting scripts"
    echo "Usage: wh <command>"
    echo
    echo "Available commands:"
    # List every file in the commands directory
    cmd_list=$(ls -I wh $WH_SCRIPT_DIR/wh-* | xargs -n1 basename | sed 's/wh-//; s/\..*$//')
    for command in $cmd_list; do
        echo "  $command"
    done
    echo
    exit 0
}

# If no parameters have been provided or the command doesn't exist
if [ $# -eq 0 ]; then
    print_usage
    exit 1
fi

command=$1
shift


###  Final code block for script detection and execution  ###

# Define the paths to the bash and python scripts
bash_script="$WH_SCRIPT_DIR/wh-${command}.sh"
python_script="$WH_SCRIPT_DIR/wh-${command}.py"

# If the bash script exists, execute it
if [ -f $bash_script ]; then
    bash $bash_script $@
# Else, if the python script exists, execute it
elif [ -f $python_script ]; then
    source $WH_BASE_DIR/venv/bin/activate
    python3 $python_script $@
else
    echo "Invalid command '$command': (No such script wh-${command}.sh or wh-${command}.py)"
    echo
    print_usage
    exit 1
fi
