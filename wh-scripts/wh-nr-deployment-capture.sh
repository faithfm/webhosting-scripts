#!/bin/bash

# This script is designed to be run as a post-deploy hook in a PHP application.
#    It captures the Git commit information and write it to a JSON log file.
#    The location of this file is specified by the $app_deploy_log_dir variable.
#
# These log files are forwarded to New Relic by a script executed by the forge user every minute.

app_deploy_log_dir="/var/log/app-deploys"

# Ensure project directory is detected, and make it the current working directory
if [[ -z "$WH_PROJECT_DIR" ]]; then
  echo "ERROR: project directory not detected"
  exit 1
fi
cd "$WH_PROJECT_DIR"

# Allow the correct GIT working tree to be detected when called from a git post-receive hook
#    Prevent "remote: fatal: Not a git repository: '.'" errors.
#    See: https://stackoverflow.com/questions/6394366/problem-with-git-hook-for-updating-site
unset $(git rev-parse --local-env-vars)


# Get Git commit information
commit_hash=$(git rev-parse HEAD)
commit_author=$(git log -1 --pretty=format:'%an')
commit_date=$(git log -1 --format="%ad" --date=format:'%Y-%m-%dT%H:%M:%S%z')
commit_message=$(git log -1 --format="%B")
commit_message="${commit_message//$'\n'/\\n}"
commit_timestamp=$(git log -1 --format=%ct "$commit_hash")
deployment_timestamp=$(date +%s)

# Variables
log_file_path="$app_deploy_log_dir/${deployment_timestamp}-$USER.log"

# Detect New Relic helper package
  if [[ -d "$WH_PROJECT_DIR//vendor/faithfm/new-relic-helper" ]]; then
    NR_HELPER_DETECTED=true
  else
    NR_HELPER_DETECTED=false
  fi

# Construct the JSON payload
json_data=$(cat <<EOF
{
  "commit_hash": "$commit_hash",
  "commit_author": "$commit_author",
  "commit_date": "$commit_date",
  "commit_message": "$commit_message",
  "commit_timestamp": $commit_timestamp,
  "deployment_timestamp": $deployment_timestamp,
  "app_name": "$WH_APP_NAME",
  "nr_helper_detected": $NR_HELPER_DETECTED
}
EOF
)

# Write the JSON payload to the log file
echo "$json_data" > "$log_file_path"

chmod 666 "$log_file_path"

echo "JSON log has been written to: $log_file_path"
