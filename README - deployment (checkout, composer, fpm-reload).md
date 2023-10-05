# Deployment Notes (checkout / composer / fpm-reload / etc)

Code deployments / updates for Faith FM websites are usually via two types of **git hooks**:

* For Laravel (& Docker) **production** sites, the changes are **pushed to GitHub**, which triggers a Laravel **Forge deployment script** (via GitHub webhooks).

* For Laravel **staging** sites (and all other sites including prod+staging WordPress plugins & themes) the changes are pushed to a **git repo on the server**, which trigger deployment scripts via **post-receive hooks**.

## Deployment Scripts

Our *webhosting scripts* have allowed for much simpler deploymnent scripts - in many cases just two or three lines:

| Deployment Type | Environment | Script Type | Line 1 | Line 2 | Line 3 |
|---|---|---|---|---|---|
| Laravel | staging | PR hook |  |  wh checkout-PR | wh composer-deploy |
| Laravel | production | GH/Forge | cd /home/user/site |  wh checkout-github | wh composer-deploy-sessions |
| WordPress | staging | PR hook |  | wh checkout-PR /path/to/working-tree | wh fpm-reload |
| WordPress | production | PR hook |  | wh checkout-PR --MASTER-BRANCH-ONLY /path/to/working-tree | wh fpm-reload |
| Docker* | staging | PR hook |  |  wh checkout-PR | wh docker-deploy |
| Docker* | production | GH/Forge | cd /home/user/site |  wh checkout-github | wh docker-deploy |


> NOTE*: For more specific information regarding the special process required to deploy a containerised Express / Apollo GraphQL server site using **Docker** see: [docker project deployment HOWTO.md](<docker/docker project deployment HOWTO.md>)

.

## Detailed Notes:

* The project directory is automatically detected in most cases - as long as the current directory includes the site folder.  Laravel Forge deployment scripts default to the user folder which is not deep enough, and in these cases it's important to change to the site folder first as shown.

* Production sites should only allow deployment from the **master** branch:
  
  * `wh checkout-github` simply deploys the HEAD commit on the 'master' branch (fetched from GitHub)
  
  * `wh checkout-PR` deploys the most-recently pushed commit, but can be instructed to only deploy commits from 'master' branch with the `--MASTER-BRANCH-ONLY` option.

* Laravel **production** sites should clear user sessions after deployment.  Use `wh composer-deploy`**`-sessions`**.

* For Laravel **staging** sites, the project folder is a **normal git repo** and is checked-out in-place.  (The web root is the 'public/' subfolder of the project folder).

* The legacy brightangel7.com site is a special case, but is detected automatically.  It has a **normal git repo** in the `public/radio/` folder and is checked-out in-place.

* For **WordPress** custom plugins and themes, the git repos on the server are **bare git repos** under the `git/plugins/` or `git/themes` folders, and are checked-out to working folders located under the `htdocs/wp-content/plugins/` or `htdocs/wp-content/themes/` folders.

  * The project/working folder must be specified as shown when deploying **bare repos**.
  
  * Note: The main WordPress folder is deployed manually and updated by WordPress itself - ie: not using git.

* `wh-composer-deploy` also sends a deployment event to New Relic
