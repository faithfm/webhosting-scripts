#!/usr/bin/env bash

# show list of backup snapshots
sudo -E resticprofile unschedule
sudo -E resticprofile schedule
