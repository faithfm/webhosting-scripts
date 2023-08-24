# How to deploy a containerised Express / Apollo GraphQL server site:

Firstly, ensure that Docker has been installed:

```bash
wh docker-update
# ...and restart shell
```

Note:
> For this HOWTO, we're using **auth-staging.advent.services** as an example

## Create initial site:

* Point DNS to the Forge server IP
* Create a **non-isolated** site in Forge (accept defaults)
  * Note - creates default PHP deployment folder: /home/**forge**/auth-staging.advent.services/public/ folder.
* Enable SSL in Forge
* (Confirm that the default Forge site is alive with SSL)

## Choose a port:
* Run `wh docker-summary` to show existing docker projects + port mappings
* Choose a suitable unused docker port - in this case **4001** 
  > Let's use ports 3001, 3002, 30xx for production and 4001, 4002, 40xx for staging equivalents sites

## Edit NGINX File:
* Replace the main "/" location section with:

```nginx
    location / {
        proxy_pass http://localhost:4001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_cache_bypass $http_upgrade;
    }
```

* Delete the following sections:

```nginx
    ...
    root /home/forge/auth-staging.advent.services/public;
    ...
    index index.html index.htm index.php;
    ...
    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }
    ...
    error_page 404 /index.php;

    location ~ \.php$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)$;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
    }
    ...
```

## Docker Project Installation

* Note: for PRODUCTION sites, during the initial configuration of Forge's automatic app deployment from GitHub, Forge expects the project folder in its default location (not under `~/dockerprojects/`).  To overcome this for PRODUCTION sites we perform the initial deployment in the old location then move the folder.

### SAMPLE .env FILE  (needed later):

```env
APP_NAME="Advent Auth (STAGING)"
APP_IMAGE_NAME=auth-staging.advent
APP_ENV=staging   
APP_DEBUG=false
APP_URL=https://auth-staging.advent.services

DOCKER_PORT=4001
DOCKERFILE_TEMPLATE=express01
DOCKERCOMPOSE_TEMPLATE=express01  

TWILIO_SID=XXXXXXX
TWILIO_TOKEN=XXXXXXX
TWILIO_SERVICE_NUMBER=+614xxxxxxx

DB_URL=mongodb+srv://xxxxx
```

### FOR STAGING PROJECTS:

Server configuration (forge user):

```bash
# initialise the new dockerprojects folder
mv auth-staging.advent.services ~/dockerprojects/
cd ~/dockerprojects/auth-staging.advent.services
git init
git config receive.denyCurrentBranch ignore

# post-receive hook
cat <<EOF > .git/hooks/post-receive
#!/bin/bash
wh checkout-PR
wh docker-deploy
EOF
chmod +x .git/hooks/post-receive

# .env file
nano .env
  # paste from .env sample and modify
  # be sure to apply the correct PORT
```

Local dev machine configuration - add "STAGING" remote (ie: using Fork): 
  > ssh://forge@[WEBHOST]:[SSH-PORT]/home/forge/dockerprojects/auth-staging.advent.services

Test deployment by pushing to STAGING remote and checking output for errors.

### FOR PRODUCTION PROJECTS:

* Local dev machine configuration - ensure "github-PROD" remote has been configured (ie: using Fork): 

  > https://github.com/faithfm/advent-auth.git

* Forge UI / Application / Install Repository:

  * GitHub
  * Repository = [SAME GITHUB URL]
  * Branch = main
  * Install Composer Dependencies = FALSE
  * Click "Install Repository" (button)

* Server configuration (forge user):

```bash
# confirm that docker project has been deployed from GitHub repo
ll auth-staging.advent.services

# move to dockerprojects folder

# initialise the new dockerprojects folder
mv ~/auth-staging.advent.services ~/dockerprojects/
cd ~/dockerprojects/auth-staging.advent.services

# create .env file
nano .env
  # paste from .env sample and modify
  # be sure to apply the correct PORT
```

* Forge UI / Application / edit Deploy Script:

>  Note the new `dockerprojects` path
> 
```bash
cd /home/forge/dockerprojects/auth.advent.services
wh checkout-github main
wh docker-deploy
```

* Forge UI / Application / Enable Quick Deploy (button)

* Test deployment by pushing to github-PROD remote and checking output for errors.

.

.
## Capture initial sw-config:
  * Ensure `/home/forge/dockerprojects/auth-staging.advent.services/.env` file is captured


