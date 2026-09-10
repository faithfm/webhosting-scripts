#!/usr/bin/env bash

# perform a manual system backup (normally run by a schedule)
# Explicit absolute --config, not "sudo -E": sudo resets HOME, and preserving forge's env
# into a root process is the LD_PRELOAD vector. Resolved from passwd, NOT from $HOME --
# $HOME is caller-controlled ("HOME=/tmp/x wh bup-backup" would pick an attacker config).
# This does NOT stop forge planting a run-before hook in its own config; only a
# root-owned config does (see wh-bup-install.sh).
CFG="$(getent passwd "$(id -un)" | cut -d: -f6)/.config/resticprofile/profiles.yaml"
sudo resticprofile --config "$CFG" -v backup

# restore the ownership of files in the restic cache directory
sudo chown -R $USER ~/.cache/restic
