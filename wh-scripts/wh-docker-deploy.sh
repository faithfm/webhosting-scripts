#!/usr/bin/env bash

# Deploy a docker container for the current project

# Copy docker configuration template files
wh docker-copy-config

# Build and start the docker container
docker compose up --build --detach
