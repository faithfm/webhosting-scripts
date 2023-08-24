# Useful docker commands:

```bash

# show all docker containers (running or not)
docker container ls -a

# cleanup all stopped containers, etc:
docker system prune --all

# useful info
docker info

# show container capabilities
docker ps
docker inspect <container_id_or_name>   #...and look for CapAdd / CapDrop

# Docker container security page:
https://turme.gitbook.io/blog/container-security/container-breakouts

```
