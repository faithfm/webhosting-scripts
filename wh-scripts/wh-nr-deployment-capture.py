#!/usr/bin/env python3

# Captures Git commit information and writes it to a JSON log file.
# Log files are forwarded to New Relic by wh-nr-deployment-forward.py (runs every minute via cron).

import json
import os
import subprocess
import sys
from datetime import datetime

LOG_DIR = "/var/log/app-deploys"


def git(*args, cwd, env):
    result = subprocess.run(["git"] + list(args), cwd=cwd, env=env, capture_output=True, text=True)
    if result.returncode != 0:
        print(f"ERROR: git {' '.join(args)} failed: {result.stderr.strip()}", file=sys.stderr)
        sys.exit(1)
    return result.stdout.strip()


def git_optional(*args, cwd, env):
    """As per git(), but returns an empty string instead of exiting when the command fails.
    (Used for information we can do without - ie: projects with no 'origin' remote.)"""
    result = subprocess.run(["git"] + list(args), cwd=cwd, env=env, capture_output=True, text=True)
    return result.stdout.strip() if result.returncode == 0 else ""


def main():
    project_dir = os.environ.get("WH_PROJECT_DIR")
    if not project_dir:
        print("ERROR: project directory not detected", file=sys.stderr)
        sys.exit(1)

    app_name = os.environ.get("WH_APP_NAME", "")

    # Remove git local env vars so the correct working tree is detected when called
    # from a git post-receive hook (prevents "Not a git repository: '.'" errors)
    local_vars = subprocess.run(
        ["git", "rev-parse", "--local-env-vars"], capture_output=True, text=True
    ).stdout.strip().splitlines()
    env = {k: v for k, v in os.environ.items() if k not in local_vars}

    commit_hash      = git("rev-parse", "HEAD", cwd=project_dir, env=env)
    commit_author    = git("log", "-1", "--pretty=format:%an", cwd=project_dir, env=env)
    commit_date      = git("log", "-1", "--format=%ad", "--date=format:%Y-%m-%dT%H:%M:%S%z", cwd=project_dir, env=env)
    commit_message   = git("log", "-1", "--format=%B", cwd=project_dir, env=env)
    commit_timestamp = int(git("log", "-1", "--format=%ct", commit_hash, cwd=project_dir, env=env))

    # Used to build the deployment marker's 'deepLink' - empty when there is no 'origin' remote
    remote_url = git_optional("config", "--get", "remote.origin.url", cwd=project_dir, env=env)

    deployment_timestamp = int(datetime.now().timestamp())
    log_file = os.path.join(LOG_DIR, f"{deployment_timestamp}-{os.environ.get('USER', 'unknown')}.log")

    nr_helper_detected = os.path.isdir(os.path.join(project_dir, "vendor/faithfm/new-relic-helper"))

    data = {
        "commit_hash":          commit_hash,
        "commit_author":        commit_author,
        "commit_date":          commit_date,
        "commit_message":       commit_message,
        "commit_timestamp":     commit_timestamp,
        "deployment_timestamp": deployment_timestamp,
        "app_name":             app_name,
        "nr_helper_detected":   nr_helper_detected,
        "remote_url":           remote_url,
    }

    with open(log_file, "w") as f:
        json.dump(data, f, indent=2)

    # World-readable so the forge user can forward it, but not world-writable
    os.chmod(log_file, 0o644)
    print(f"JSON log has been written to: {log_file}")


if __name__ == "__main__":
    main()
