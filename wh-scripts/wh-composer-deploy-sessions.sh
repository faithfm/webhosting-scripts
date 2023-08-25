#!/bin/bash

# For Laravel PRODUCTION applications, we delete SESSION data during deployment

# delete session data (force logout all users during upgrade) 
find storage/framework/sessions/ -type f -delete

# Main composer deploy script
wh composer-deploy
