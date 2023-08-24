#!/bin/bash

# This script loads and validates the context of the current docker project (from the .env file)
#
#   It should be 'sourced' by other docker scripts
#       ie: source $WH_SCRIPT_DIR/wh-docker-get-context.sh
#
#   It will set the following variables:
#       VARIABLE                     DESCRIPTION                                                EXAMPLE
#       ---------------------------- ---------------------------------------------------------  ---------------------
#       DOCKER_TEMPLATE_DIR          Folder containing the Docker template files                $WH_BASE_DIR/docker
#       DOCKERFILE_TEMPLATE          Dockerfile template (specified in the .env file)           express03
#       DOCKERCOMPOSE_TEMPLATE       docker-compose.yml template (specified in the .env file)   express05
#       DOCKERFILE_TEMPLATE_PATH     Expanded path to Dockerfile template                       $WH_PROJECT_DIR/docker/template express03 Dockerfile.yml
#       DOCKERCOMPOSE_TEMPLATE_PATH  Expanded path to docker-compose.yml template               $WH_PROJECT_DIR/docker/template express05 docker-compose.yml
#
#   The script will exit with an error if any of the following are true:
#     - The .env file does not exist
#     - The DOCKERFILE_TEMPLATE variable is not set in the .env file
#     - The DOCKERCOMPOSE_TEMPLATE variable is not set in the .env file
#     - The DOCKERFILE_TEMPLATE_PATH file does not exist
#     - The DOCKERCOMPOSE_TEMPLATE_PATH file does not exist

# Set the Docker template directory
export DOCKER_TEMPLATE_DIR="$WH_BASE_DIR/docker"

# Confirm and import the Docker project .env file
if [[ ! -f "$WH_PROJECT_ENV" ]]; then
    echo "Error: Docker project .env file ($WH_PROJECT_ENV) not found"
    exit 1
fi
source "$WH_PROJECT_ENV"

# Confirm the $DOCKERFILE_TEMPLATE variable exists, and that the template file exists
if [[ -z "$DOCKERFILE_TEMPLATE" ]]; then
    echo "Error: DOCKERFILE_TEMPLATE not set in .env file"
    exit 1
else
    export DOCKERFILE_TEMPLATE_PATH="$DOCKER_TEMPLATE_DIR/template $DOCKERFILE_TEMPLATE Dockerfile"
    if [[ ! -f "$DOCKERFILE_TEMPLATE_PATH" ]]; then
        echo "Error: Dockerfile template not found: '$DOCKERFILE_TEMPLATE_PATH'"
        exit 1
    fi
fi

# Confirm the $DOCKERCOMPOSE_TEMPLATE variable exists, and that the template file exists
if [[ -z "$DOCKERCOMPOSE_TEMPLATE" ]]; then
    echo "Error: DOCKERCOMPOSE_TEMPLATE not set in .env file"
    exit 1
else
    export DOCKERCOMPOSE_TEMPLATE_PATH="$DOCKER_TEMPLATE_DIR/template $DOCKERCOMPOSE_TEMPLATE docker-compose.yml"
    if [[ ! -f "$DOCKERCOMPOSE_TEMPLATE_PATH" ]]; then
        echo "Error: docker-compose.yml template not found: '$DOCKERCOMPOSE_TEMPLATE_PATH)'"
        exit 1
    fi
fi

