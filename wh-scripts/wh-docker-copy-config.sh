#!/usr/bin/env bash

# Load + validate the Docker project context
source $WH_SCRIPT_DIR/wh-docker-get-context.sh

# Copy docker configuration template files - based on .env file settings: DOCKERFILE_TEMPLATE + DOCKERCOMPOSE_TEMPLATE
cp "$DOCKERFILE_TEMPLATE_PATH" "$WH_PROJECT_DIR/Dockerfile"
cp "$DOCKERCOMPOSE_TEMPLATE_PATH" "$WH_PROJECT_DIR/docker-compose.yml"

