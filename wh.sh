#!/bin/bash
real_path=$(dirname $(readlink -f "$0"))
script_dir="$real_path/wh-scripts"

# Function to print usage information
print_usage() {
    echo "Faith FM web hosting scripts"
    echo "Usage: wh <command>"
    echo
    echo "Available commands:"
    # List every file in the commands directory
    cmd_list=$(ls -I wh $script_dir/wh-* | xargs -n1 basename | sed 's/wh-//; s/\..*$//')
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

# Define the paths to the bash and python scripts
bash_script="$script_dir/wh-${command}.sh"
python_script="$script_dir/wh-${command}.py"

# If the bash script exists, execute it
if [ -f $bash_script ]; then
    bash $bash_script $@
# Else, if the python script exists, execute it
elif [ -f $python_script ]; then
    python3 $python_script $@
else
    echo "Invalid command '$command': (No such script wh-${command}.sh or wh-${command}.py)"
    echo
    print_usage
    exit 1
fi
