#!/usr/bin/env python3

"""
This script is designed to be run as a cron job on the webhook server. It will
used to forward deployment events from the webhook server to New Relic.

"""

import glob
import json
import os
import requests
import sys
from dotenv import load_dotenv

debug = False
app_deploy_log_dir = "/var/log/app-deploys/*.log"
nr_env_file_path = "/home/forge/.env.wh-nr"


def syslogged_message(message):
    """Print a message to the console and send it to syslog"""
    print(message)
    scriptname = os.path.basename(__file__)
    os.system(f'logger -t {scriptname} "{message}"')

# Ensure the New Relic ENV file exists
if not os.path.exists(nr_env_file_path):
    syslogged_message(f"Error: New Relic ENV file not found: {nr_env_file_path}")
    sys.exit(1)

# load the New Relic API key from the .env file
try:
    load_dotenv(nr_env_file_path)
    nr_api_key = os.environ['NR_API_KEY']
except KeyError:
    syslogged_message(f"Error: New Relic API key (NR_API_KEY) not found.  (Should be defined in: {nr_env_file_path})")


def main():
    # Iterate through all the .log files in the directory
    filecount = 0
    for filename in glob.glob(app_deploy_log_dir):
        try:
            filecount += 1
            with open(filename, 'r') as file:
                commit_details = json.load(file)

            # Send the deployment marker event to New Relic
            create_deployment(commit_details)

            # Delete the log file after it has been processed
            os.remove(filename)
            
        except Exception as e:
            syslogged_message(f"An error occurred while processing the file {filename}: {e}")
            
    # If no files were processed, print a message
    if filecount == 0:
        print(f"No NewRelic deployments found.")


def nr_query(query, variables):
    """Execute a GraphQL query against the New Relic API"""
    
    # API endpoint
    url = 'https://api.newrelic.com/graphql'

    # Headers
    headers = {
        'Content-Type': 'application/json',
        'API-Key': nr_api_key
    }

    # The data to be sent to the API for the mutation
    data = {'query': query, 'variables': variables}

    # Send a post request to the API
    response = requests.post(url, headers=headers, json=data)

    # Print the response if debug is enabled
    global debug
    if debug:
        print(json.dumps(response.json(), indent=4))

    return response


def get_entity_guid(app_name=''):
    """Get the NR entity GUID for the given NR APM app name"""

    # The GraphQL query to find the entity GUID
    query = '''
    query ($query: String!) {
    actor {
        entitySearch(query: $query) {
        results {
            entities {
            name
            guid
            }
        }
        }
    }
    }
    '''

    # The GraphQL variables
    variables = {
        'query': f"name = '{app_name}' AND type = 'APPLICATION' AND domain = 'APM'"
    }

    # Execute the query
    response = nr_query(query, variables)

    # Extract the entity GUID from the response
    entity_guid = response.json()['data']['actor']['entitySearch']['results']['entities'][0]['guid']

    return entity_guid


def create_deployment(commit_details):
    """Send a code deployment marker event to New Relic"""
    
    # The GraphQL mutation to create a deployment
    mutation = '''
        mutation ($entityGuid: EntityGuid!, $timestamp: EpochMilliseconds, $version: String!, $user: String!, $changelog: String!, $description: String!, $commit: String!, $deepLink: String!) {
            changeTrackingCreateDeployment(
                deployment: {entityGuid: $entityGuid, timestamp: $timestamp, user: $user, changelog: $changelog, description: $description, version: $version, commit: $commit, deepLink: $deepLink}
            ) {
                description
                changelog
                commit
                deepLink
                deploymentId
                deploymentType
                entityGuid
                groupId
                timestamp
                user
                version
            }
        }
    '''

    # Add "PHP-H" / "PHP-N" prefix to the app name  (for Laravel / non-Laravel apps)
    app_name = commit_details['app_name']
    nr_helper_detected = commit_details['nr_helper_detected']
    if nr_helper_detected:
        prefixed_app_name = f"PHP-H {app_name}"
    else:
        prefixed_app_name = f"PHP-N {app_name}"

    # Get the entity GUID
    entity_guid = get_entity_guid(prefixed_app_name)

    # The GraphQL variables for the mutation
    hash = commit_details['commit_hash']
    variables = {
        "entityGuid": entity_guid,
        "timestamp": commit_details['deployment_timestamp'] * 1000,
        "version": hash[0:7],
        "user": commit_details['commit_author'],
        "description": commit_details['commit_message'].split('\n')[0],
        "changelog": commit_details['commit_message'],
        "commit": hash,
        "deepLink": f"https://github.com/faithfm/faithassets-v1/commit/{hash}"
    }

    # Execute the mutation
    response = nr_query(mutation, variables)

    # Success message
    app_name = commit_details['app_name']
    syslogged_message(f"Deployment {hash[0:7]} forwarded to New Relic: {prefixed_app_name}")

    return response


if __name__ == "__main__":
    main()
