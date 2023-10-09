#!/bin/bash

echo ""
echo "Run this git configuration command - usually once per project."
echo ""
echo "About to apply the following git configuration commands:"
echo "  git config --global user.email \"$USER@$HOSTNAME\""
echo "  git config --global user.name \"$USER\""
echo "  git config --global advice.detachedHead false"
echo ""

# confirm before proceeding
read -p "Proceed? (y/n) " -n 1 -r
echo ""

# configure git user (to enable local commits)
git config --global user.email "$USER@$HOSTNAME"
git config --global user.name "$USER"

# configure git to not warn about detached HEAD
git config --global advice.detachedHead false

echo "DONE."
