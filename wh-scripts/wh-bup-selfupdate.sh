#!/usr/bin/env bash

# perform a self-update of restic + resticprofile

echo -e "\nPerforming a self-update of restic...\n"
sudo restic self-update

echo -e "\nPerforming a self-update of resticprofile...\n"
# Explicit absolute --config, not "sudo -E" (see wh-bup-backup.sh).
CFG="$(getent passwd "$(id -un)" | cut -d: -f6)/.config/resticprofile/profiles.yaml"
sudo resticprofile --config "$CFG" self-update
