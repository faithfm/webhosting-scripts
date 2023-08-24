#!/usr/bin/env bash

# perform a self-update of restic + resticprofile

echo -e "\nPerforming a self-update of restic...\n"
sudo restic self-update

echo -e "\nPerforming a self-update of resticprofile...\n"
sudo -E resticprofile self-update
