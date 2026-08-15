#!/usr/bin/env python3

"""
This script is designed to be run as a cron job on the webhook server. It will
used to forward deployment events from the webhook server to New Relic.

"""

import glob
import json
import os
import re
import requests
import subprocess
import sys
import time
from dotenv import load_dotenv

debug = False
app_deploy_log_dir = "/var/log/app-deploys/*.log"
nr_env_file_path = "/home/forge/.env.wh-nr"

# How long a failed log file is retried before being moved to the errors subfolder.
#   Parse failures are permanent, but log files are written non-atomically, so a very recent
#   file may simply have been caught mid-write - give it a moment before giving up on it.
#   API failures are usually transient (New Relic outages, rate limits, network errors), so
#   these files are retried for much longer before we accept that they will never be sent.
parse_retry_seconds = 60
api_retry_seconds = 7 * 24 * 60 * 60

# Fallback repo used to build the deployment 'deepLink' when a log file doesn't name one
fallback_repo_url = "https://github.com/faithfm/faithassets-v1"


def syslogged_message(message):
    """Print a message to the console and send it to syslog"""
    print(message)
    scriptname = os.path.basename(__file__)
    subprocess.run(['logger', '-t', scriptname, message])

# Ensure the New Relic ENV file exists
if not os.path.exists(nr_env_file_path):
    syslogged_message(f"Error: New Relic ENV file not found: {nr_env_file_path}")
    sys.exit(1)

# load the New Relic API key from the .env file  (an empty value is treated as missing)
load_dotenv(nr_env_file_path)
nr_api_key = os.environ.get('NR_API_KEY', '').strip()
if not nr_api_key:
    syslogged_message(f"Error: New Relic API key (NR_API_KEY) not found.  (Should be defined in: {nr_env_file_path})")
    sys.exit(1)


def move_to_errors(filename):
    """Move a failed log file to the errors subfolder. Returns dest path, or None if file no longer exists."""
    errors_dir = os.path.join(os.path.dirname(filename), "errors")
    os.makedirs(errors_dir, exist_ok=True)
    dest = os.path.join(errors_dir, os.path.basename(filename))
    try:
        os.rename(filename, dest)
    except FileNotFoundError:
        return None
    return dest


def quarantine_or_retry(filename, retry_seconds, description, error):
    """Handle a failed log file: move it to the errors subfolder if it is old enough that
    retrying is pointless, otherwise leave it in place to be retried next time.
    Returns True if the file was quarantined, False if it will be retried."""
    try:
        age = time.time() - os.path.getmtime(filename)
    except OSError:
        return False                    # file has already gone - nothing to do

    # Too recent to give up on - leave it for the next run
    if age < retry_seconds:
        return False

    dest = move_to_errors(filename)
    location = f"moved to {dest}" if dest else "file already gone"
    syslogged_message(f"ERROR: {description} — {location}: {type(error).__name__}: {error}")
    return True


def main():
    # Iterate through all the .log files in the directory
    filecount = 0
    retrycount = 0
    for filename in glob.glob(app_deploy_log_dir):
        filecount += 1
        basename = os.path.basename(filename)

        # Read the log file  (a parse failure is permanent unless the file was caught mid-write)
        try:
            with open(filename, 'r') as file:
                commit_details = json.load(file)
        except Exception as e:
            if not quarantine_or_retry(filename, parse_retry_seconds, f"Invalid deployment log {basename}", e):
                retrycount += 1
            continue

        # Send the deployment marker event to New Relic  (failures here are usually transient)
        try:
            create_deployment(commit_details)
        except Exception as e:
            if not quarantine_or_retry(filename, api_retry_seconds, f"Could not forward {basename}", e):
                retrycount += 1
            continue

        # Delete the log file after it has been processed
        os.remove(filename)

    # Summarise any files left behind, so a persistent problem is visible without logging
    # a separate message for every file on every run
    if retrycount:
        syslogged_message(f"WARNING: {retrycount} deployment log file(s) could not be forwarded - will retry.")

    # If no files were processed, print a message
    if filecount == 0:
        print("No NewRelic deployments found.")


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
    entities = response.json()['data']['actor']['entitySearch']['results']['entities']
    if not entities:
        raise ValueError(f"No New Relic entity found for app: '{app_name}'")
    entity_guid = entities[0]['guid']

    return entity_guid


def build_deep_link(remote_url, commit_hash):
    """Build the GitHub commit URL for the deployment marker's 'deepLink'.
    Falls back to the original hardcoded repo when the log file doesn't name a GitHub remote
    (ie: older log files, or projects deployed from a bare repo on the server)."""
    repo_url = fallback_repo_url
    if remote_url:
        # ie: 'git@github.com:faithfm/my-project.git' or 'https://github.com/faithfm/my-project'
        match = re.match(r'^(?:git@github\.com:|https://github\.com/)(.+?)(?:\.git)?/?$', remote_url.strip())
        if match:
            repo_url = f"https://github.com/{match.group(1)}"

    return f"{repo_url}/commit/{commit_hash}"


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
        "deepLink": build_deep_link(commit_details.get('remote_url'), hash)
    }

    # Execute the mutation
    response = nr_query(mutation, variables)

    # Success message
    app_name = commit_details['app_name']
    syslogged_message(f"Deployment {hash[0:7]} forwarded to New Relic: {prefixed_app_name}")

    return response


if __name__ == "__main__":
    main()
