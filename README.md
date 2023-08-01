# webhosting-scripts - Faith FM web hosting scripts

An easy-to-maintain set of scripts for our web-hosting servers.  

> Instructions below are designed for our Laravel Forge server environment, but should be fairly useful for other LEMP environments.

## Usage:

Usage is simple:

```bash
wh          # list available wh-script commands
wh hello    # runs the demo script
wh update   # update all scripts (ie: pull updates + re-install symlinks)
```

Bash completion is also included - ie type:

```bash
  wh + [space] + [tab]  # will show available commands
  wh hel + [tab]        # will probably auto-complete the `wh hello` command
```

## Installation:

```bash
# Create a folder for shared scripts
# Ideally would use the forge home folder - except that the 'isolated' group is normally disabled from ALL access to home folders (other than their own) using 'setfacl'.  Safer to use an independent folder.
sudo mkdir /home/shared
sudo chown forge:forge /home/shared         # owned by admin account
chmod 751 /home/shared/                     # other users get execute rights, but no read/visibility rights (ie: can't list this folder)

# Clone repo
cd /home/shared
git clone https://github.com/faithfm/webhosting-scripts.git
chmod 755 /home/shared/webhosting-scripts   # other users additionally get read/visiblity rights (needed for command-listings to work)

# First time Run the updater (to perform the initial installation of symlinks, etc)
/home/shared/webhosting-scripts/wh-scripts/wh-update.sh
```

## Developing scripts:

The `wh xyz` command is created by creating scripts in the `wh-scripts/` folder - either:
 * `wh-xyz.sh` (bash) OR...
 * `wh-xyz.py` (Python) 

Be sure to set file permissions appropriately on development machine before pushing script to the repo - ie:
```bash
chmod 755 wh-scripts/wh-xyz.sh
```
