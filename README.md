# webhosting-scripts - Faith FM web hosting scripts

An easy-to-maintain set of scripts for our web-hosting servers.  

> Instructions below are designed for our Laravel Forge server environment, but should be fairly useful for other LEMP environments.

## Usage

Usage is simple:

```bash
# basics
wh                                # list available wh-script commands
wh hello                          # basic hello world bash script
wh hello-python                   # ditto  (python version)
wh show-env                       # show key environment variables that can be expected/used in all webhosting scripts
wh update                         # update all scripts (ie: pull updates + re-install symlinks)
wh python-update                  # occasionally update pyenv, python, and the python venv for our web-hosting scripts

# project checkout/update commands
#   [NOTE 1] below - Deployment README - additional info
wh checkout-github                # checkout project from GitHub master
wh checkout-PR                    # checkout project from a pull request

# PHP/composer deployment
#   [NOTE 1] below - Deployment README - additional info
wh composer-deploy                # deploy composer dependencies... (including extra steps for Forge projects)
wh composer-deploy-sessions       # ditto - ...and delete SESSION data (for Laravel PRODUCTION projects)
wh fpm-reload                     # restart PHP-FPM server - useful for command-line too
wh nr-deployment-capture          # capture git commit info and write it to a JSON log file
wh nr-deployment-forward          # forward deployment events from the webhook server to New Relic (forge crontab task)

# Docker deployment framework
#   [NOTE 1] below - Deployment README - additional info
#   [NOTE 2] below - How to deploy a containerised Express / Apollo GraphQL server site
wh docker-summary                 # Show a summary of the docker projects and their nginx port mappings
wh docker-deploy                  # Deploy (build + run) a docker container for current project
wh docker-down                    # Stop the docker container for current project
wh docker-get-context             # HELPER:  load and validate context of the current docker project (from the .env file)
wh docker-copy-config             # HELPER:  copy docker configuration templates to current project
wh docker-install                 # install or update docker

# backup framework (using restic + resticprofile)
wh bup                            # show list of backup snapshots
wh bup-config                     # edit the backup configuration file
wh bup-backup                     # perform a manual system backup (...but usually executed on a schudule)
wh bup-reschedule                 # update the scheduler (after editing schedule times in the config file)
wh bup-unlock                     # unlock a 'locked' resticprofile repository
wh bup-install                    # install restic + resticprofile
wh bup-selfupdate                 # perform a self-update of restic + resticprofile
```

Many of these  web-hosting scripts are focused on deploying code updates to websites:

> NOTE 1: For more details regarding code deployments see:  [README - deployment (checkout, composer, fpm-reload).md](<README - deployment (checkout, composer, fpm-reload).md>)

> NOTE 2: How to deploy a containerised Express / Apollo GraphQL server site see: [docker project deployment HOWTO.md](<docker/docker project deployment HOWTO.md>)


Bash completion is also included - ie type:

```bash
  wh + [space] + [tab]            # will show available commands
  wh hel + [tab]                  # will probably auto-complete the `wh hello` command
  wh + [enter]                    # will show list of available commands
```

## Installation

```bash
# Create a folder for shared scripts
# Ideally would use the forge home folder - except that the 'isolated' group is normally disabled from ALL access to home folders (other than their own) using 'setfacl'.  Safer to use an independent folder.
sudo mkdir /home/shared
sudo chown forge:forge /home/shared         # owned by admin account
chmod 751 /home/shared/                     # other users get execute rights, but no read/visibility rights (ie: can't list this folder)

# Clone repo
cd /home/shared
git clone https://github.com/faithfm/webhosting-scripts.git

# First time Run the updater (to perform the initial installation of symlinks, etc)
/home/shared/webhosting-scripts/wh.sh update

# NOTE: Disregard the warning: "Couldn't install python requirements - venv folder does not yet exist."

# Restart your bash session  (to enable pyenv and code completion)

# Install required pyenv, Python, and venv environment
wh python-update

# Restart your bash session (as per warning to enable installed pyenv version)

# Now re-run the updaters once more  (should be no more warnings)
wh python-update
wh update

# Optionally, set the global pyenv version
pyenv versions
pyenv global 3.11   # (see current version in .python-version file)

# EXTRA INSTALL STEP FOR NEW-RELIC DEPLOY SCRIPT
nano /home/forge/.env.wh-nr
  NR_API_KEY=XXXXXXXXXXX

```

## Developing scripts

The `wh xyz` command is created by creating scripts in the `wh-scripts/` folder - either:

* `wh-xyz.sh` (bash) OR...
* `wh-xyz.py` (Python)

Be sure to set file permissions appropriately on development machine before pushing script to the repo - ie:

```bash
chmod 755 wh-scripts/wh-xyz.sh
```

To add python packages to our local venv environment (to be installed in our production environments:

```bash
source venv/bin/activate
pip install mypackage
pip freeze > requirements.txt
```
