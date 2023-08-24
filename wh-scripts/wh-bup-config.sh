#!/usr/bin/env bash

# ensure the resticprofile configuration directory exists
mkdir -p ~/.config/resticprofile

# edit the backup configuration file
nano ~/.config/resticprofile/profiles.yaml

echo -e "\nReinstalling any schedules...\n"
wh bup-reschedule
