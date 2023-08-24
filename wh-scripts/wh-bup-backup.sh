#!/usr/bin/env bash

# perform a manual system backup (normally run by a schedule)
sudo -E resticprofile -v backup

# restore the ownership of files in the restic cache directory
sudo chown -R $USER ~/.cache/restic
