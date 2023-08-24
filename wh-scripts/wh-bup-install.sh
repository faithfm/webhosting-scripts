#!/usr/bin/env bash

# install restic + resticprofile
# Note: using a simplified version of the resticprofile install script - to install latest binaries of both restic + resticprofile from GitHub

# DETECT ARCHITECTHURE
ARCH=$(uname -m)
case $ARCH in
  x86_64) ARCH="amd64" ;;
  x86) ARCH="386" ;;
  i686) ARCH="386" ;;
  i386) ARCH="386" ;;
  aarch64) ARCH="arm64" ;;
  armv5*) ARCH="armv5" ;;
  armv6*) ARCH="armv6" ;;
  armv7*) ARCH="armv7" ;;
esac

# Get the restic download URL... after determining the latest release from GitHub API
REDIRECT_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/restic/restic/releases/latest)
LATEST_RELEASE=$(basename $REDIRECT_URL | sed 's/^v//')
RESTIC_URL=https://github.com/restic/restic/releases/download/v$LATEST_RELEASE/restic_${LATEST_RELEASE}_linux_$ARCH.bz2

# Get the resticprofile download URL... after determining the latest release from GitHub API
REDIRECT_URL=$(curl -Ls -o /dev/null -w %{url_effective} https://github.com/creativeprojects/resticprofile/releases/latest)
LATEST_RELEASE=$(basename $REDIRECT_URL | sed 's/^v//')
RESTICPROFILE_URL=https://github.com/creativeprojects/resticprofile/releases/download/v$LATEST_RELEASE/resticprofile_${LATEST_RELEASE}_linux_$ARCH.tar.gz


# Download and install restic and resticprofile
echo -e "\nDownloading restic from $RESTIC_URL ..."
curl -Ls $RESTIC_URL | bunzip2 > ~/restic
echo -e "\nDownloading resticprofile from $RESTICPROFILE_URL ..."
curl -Ls $RESTICPROFILE_URL | tar -xz > ~/resticprofile
sudo mv ~/restic /usr/local/bin
sudo mv ~/resticprofile /usr/local/bin
sudo chown root:root /usr/local/bin/restic
sudo chown root:root /usr/local/bin/resticprofile
sudo chmod 755 /usr/local/bin/restic
sudo chmod 755 /usr/local/bin/resticprofile

echo -e "\nAdding a sudoers profile...  (to allow 'sudo -E resticprofile ...' to work correctly)\n"
echo "forge ALL=NOPASSWD:SETENV: /usr/local/bin/resticprofile" | sudo tee /etc/sudoers.d/resticprofile

# Allow a visual check of the installed binaries
echo -e "\nConfirming installed binaries in /usr/local/bin/ folder:\n"
ls -l /usr/local/bin/restic*

echo -e "\n...now run 'wh bup-config' to configure resticprofile.  (Suggest cloning/modifying configuration from another server)\n"

# Note - sample URLs:
# https://github.com/restic/restic/releases/download/v0.16.0/restic_0.16.0_linux_arm64.bz2
# https://github.com/creativeprojects/resticprofile/releases/download/v0.23.0/resticprofile_0.23.0_linux_arm64.tar.gz
