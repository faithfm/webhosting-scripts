#!/usr/bin/env bash

# show list of backup snapshots
# Explicit absolute --config, not "sudo -E" (see wh-bup-backup.sh).
CFG="$(getent passwd "$(id -un)" | cut -d: -f6)/.config/resticprofile/profiles.yaml"
sudo resticprofile --config "$CFG" unschedule
sudo resticprofile --config "$CFG" schedule
