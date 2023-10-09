#!/usr/bin/env python3

"""
wh-git - Git Wrapper Script
---------------------------

Usage: wh git <git-command> [arguments]

This script enhances the functionality of the standard git command by introducing additional repo + work directory detection mechanisms:

1. The script looks for a configuration file named "wh-git-repos.yml" in the home directory.
   This file contains pairs of directories: bare git repositories and their associated working directories - ie:
   
      - bare: /home/user/site.com.au/git/plugins/my-plugin.git
        work: /home/user/site.com.au/htdocs/wp-content/plugins/my-plugin

      - bare: /home/user/site.com.au/git/themes/my-theme.git
        work: /home/user/site.com.au/htdocs/wp-content/themes/my-theme

2. When executed, the script checks the current working directory against the directories listed in the configuration file.
   If a match is found, the associated git repository and work tree are used.

3. Otherwise, the script looks for a .git directory recursively up from the current directory.
   Note: if called from home directory, the script will check for a site subdirectory resembling a web domain format
   - ie: "mywebsite.com.au" - and will search this folder instead.

4. Finally, the git command is executed with the appropriate git directory and working tree.

Note: all comments relating to the 'home' directory refer to a home folder relative to the current directory, 
rather than the home folder of the current user.
"""

import os
import sys
import subprocess
import yaml
import re

def get_home_dir(folder):
    """
    Return the '/home/username' (home) directory for the given folder.
    Return None if the specified folder is not a subfolder of a home directory.
        Ie: /home/user/site.com.au/htdocs -> /home/user
        Ie: /etc/abc                      -> None
    """
    path = os.path.abspath(folder)
    if not path.startswith("/home/"):
        return None
    return os.path.join(os.path.sep, *path.split(os.path.sep)[1:3])    

def find_matching_git_config(cwd):
    """
    Check the current directory against the list of git repo configurations in 'wh-git-repos.yml'.
    Return the matching configuration [git-dir, work-tree] pair if found, otherwise return None.
    Note: a match is detected when the current directory matches (or is a subdirectory of) the 'bare' OR 'work' directory in the configuration.
    """
    home = get_home_dir(cwd)
    if not home:
        return None
    
    # Check existence of the configuration file path
    config_path = os.path.join(home, "wh-git-repos.yml")
    if not os.path.exists(config_path):
        return None
    
    # Load configuration file
    with open(config_path, 'r') as f:
        configs = yaml.safe_load(f)

    # Check if the current directory matches a configured directory
    for config in configs:
        if cwd.startswith(config['bare']) or cwd.startswith(config['work']):
            return [config['bare'], config['work']]
    
    # No match found
    return None

def find_git_dir(start_path="."):
    """
    Recursively search for the .git directory starting from the given path and moving upwards.
    """
    path = os.path.abspath(start_path)
    while path != os.path.dirname(path):
        if ".git" in os.listdir(path):
            return os.path.join(path, ".git")
        path = os.path.dirname(path)
    return None

def switch_home_to_site_folder(cwd):
    """
    If in a home directory, return first subdirectory matching a website-like format - ie: "/home/user/mywebsite.com.au"
    """
    home = get_home_dir(cwd)
    if cwd == home:
        # Find a subdirectory in the home folder that matches the URL hostname pattern.
        pattern = re.compile(r"^[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$")
        for subdir in os.listdir(home):
            if pattern.match(subdir) and os.path.isdir(os.path.join(home, subdir)):
                cwd = os.path.join(home, subdir)
    return cwd

def main():
    # Determine the current working directory.
    cwd = os.getcwd()
    
    # Print the script name and current working directory.
    print("\nwh-git - Git Wrapper Script:")
    print(f"   CWD:       {cwd}")

    # Check if the current directory matches a configured directory in 'wh-git-repos.yml'
    config = find_matching_git_config(cwd)
    if config:
        print(f"   CWD matched a git repo configured in 'wh-git-repos.yml'.")
        [git_dir, work_tree] = config

    # Otherwise, search for a .git directory.
    else:
        # Special case for home directories: check for (and switch to) first subdirectory matching a website-like format - ie: "/home/user/mywebsite.com.au"
        search_folder = switch_home_to_site_folder(cwd)
        if search_folder != cwd:
            print(f"   CWD was a home folder - searching instead within detected site subfolder: {search_folder}.")

        # Search for .git directory
        git_dir = find_git_dir(search_folder)
        if git_dir:
            work_tree = os.path.dirname(git_dir)

        else:
            print(f"   ERROR: No valid git repositories (or 'wh-git-repos.yml' repo matches) found for this folder.")
            sys.exit(1)

    # Print the git directory and work tree.
    print(f"   GIT DIR:   {git_dir}")
    print(f"   WORK TREE: {work_tree}\n")
    
    # If no arguments were passed, print the usage information.
    if len(sys.argv) == 1:
        print(__doc__)

    # Construct the git command, and pass along additional arguments.
    cmd = ["git", "--git-dir=" + git_dir, "--work-tree=" + work_tree] + sys.argv[1:]

    # Execute the git command and exit with its return code.
    result = subprocess.run(cmd)
    sys.exit(result.returncode)

if __name__ == "__main__":
    # If the script is run directly, invoke the main function.
    main()
