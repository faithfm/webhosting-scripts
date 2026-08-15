#!/usr/bin/env python3

# Show a summary of the docker projects and their nginx port mappings

import os
import glob
import re
from tabulate import tabulate


# Folder paths
dockerprojects_folder = '/home/forge/dockerprojects/'
nginx_folder = '/etc/nginx/sites-available/'


def get_proxy_pass_port(filename):
    """Get the port number from specified nginx config file"""
    
    port = None
    try:
        with open(filename, 'r') as file:
            for line in file:
                # match the proxy_pass line and extract the port number
                match = re.search(r'proxy_pass http://[^:]*:(\d+);', line)
                if match:
                    port = int(match.group(1))
                    break
    except OSError:
        pass        # no readable nginx config for this folder - reported as '-' below

    if port is None:
        port = '-'

    return port


def search_env_files(folder):
    """Get key settings from .env files in dockerprojects folder, and combine with nginx_port from related nginx config file"""
    
    env_files = glob.glob(os.path.join(folder, '*', '.env'))
    env_data = []

    # iterate through the .env files
    for env_file in env_files:
        folder_path = os.path.dirname(env_file)
        folder_name = os.path.basename(folder_path)
        
        # set initial values for the env_settings dict. Unknown '-' values will be replaced from .env file
        env_settings = {
            'folder': folder_name,
            'nginx_port': get_proxy_pass_port(os.path.join(nginx_folder, folder_name)),
            'DOCKER_PORT': '-',
            'APP_IMAGE_NAME': '-',
            'APP_ENV': '-',
            'APP_DEBUG': '-',
            'DOCKERFILE_TEMPLATE': '-',
            'DOCKERCOMPOSE_TEMPLATE': '-'
        }

        # update the env_settings dict with any values found in the .env file
        #   Keys/values are tidied up the same way bash would when 'source'ing the same file
        #   (ie: as wh-docker-get-context.sh does), so both scripts report identical settings.
        with open(env_file, 'r') as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith('#') or '=' not in line:
                    continue
                key, value = line.split('=', 1)
                key = key.strip().removeprefix('export ').strip()
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in ('"', "'"):
                    value = value[1:-1]                     # quoted value - use it as-is
                elif '#' in value:
                    value = value.split('#', 1)[0].strip()  # unquoted value - drop trailing comment
                if key in env_settings:
                    env_settings[key] = value

        # add the env_settings for this file to the env_data list
        env_data.append(env_settings)

    return env_data


def sort_env_data(env_data):
    """Sort the env_data list by the port number  (projects without a usable port are listed last)"""
    def port_key(env_settings):
        digits = re.findall(r'\d+', env_settings['DOCKER_PORT'])
        return (0, int(digits[0])) if digits else (1, 0)

    return sorted(env_data, key=port_key)


def format_env_data(env_data, headers):
    """Format the env_data list into a table"""
    table = []

    for env_settings in env_data:
        row = [env_settings[header] for header in headers]
        table.append(row)

    return table


### Main ###
if __name__ == '__main__':
    
    # get env data from the .env files and nginx config
    env_data = search_env_files(dockerprojects_folder)
    
    # sort env data by the port number
    sorted_env_data = sort_env_data(env_data)
    
    # format env data into a table
    headers = ['folder', 'DOCKER_PORT', 'nginx_port', 'APP_IMAGE_NAME', 'APP_ENV', 'APP_DEBUG', 'DOCKERFILE_TEMPLATE', 'DOCKERCOMPOSE_TEMPLATE']
    formatted_env_data = format_env_data(sorted_env_data, headers)
    table = tabulate(formatted_env_data, headers, tablefmt='grid')

    # print the table
    print(f"\nDocker projects folder: {dockerprojects_folder}\n")
    print("Docker project vs nginx port mapping summary:")
    print(table)
