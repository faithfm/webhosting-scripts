# webhosting-scripts - Faith FM web hosting scripts

An easy-to-maintain set of scripts for our web-hosting servers.  

> Instructions below are designed for our Laravel Forge server environment, but should be fairly useful for other LEMP environments.

## Usage

Usage is simple:

```bash
wh                                 # list available wh-script commands
wh hello                           # runs the demo script
wh update                          # update all scripts (ie: pull updates + re-install symlinks)
wh show-env                        # show key environment variables that can be expected/used in all webhosting scripts
wh fpm-reload                      # restart PHP-FPM server
wh deploy-script-forge-production  # runs script for production servers
wh fpm-reload                      # restart detected php-fpm services
wh hello-python                    # runs python test script
wh nr-deploy-capture               # captures the Git commit information and write it to a JSON log file
wh nr-deploy-forward               # forward deployment events from the webhook server to New Relic
wh post-receive-forge-staging      # runs script for staging servers
wh python-update                   # occasionally update pyenv, python, and the python venv for our web-hosting scripts
```

Bash completion is also included - ie type:

```bash
  wh + [space] + [tab]  # will show available commands
  wh hel + [tab]        # will probably auto-complete the `wh hello` command
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
