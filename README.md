# Scribo infrastructure

Scribo is a public blog with accounts, posts, comments, search, support tickets and a messenger. It is split across four repositories; this one describes the machine everything runs on and holds the only files that are deployed to it.

| Repository | What it is |
| --- | --- |
| `frontend` | Next.js, pages and the browser client |
| `backend` | NestJS, the HTTP API and all persistent state |
| `socket` | WebSocket delivery for chat, typing and presence |
| `infra` | this repository: compose files, nginx, certificates, server scripts |

Site: `https://scribo.pp.ua`. Staging: `https://scribo-stage.pp.ua`. Both names point at the same IP. Only ports 80 and 443 are open to the internet.

The machine is an Oracle Cloud Free Tier `VM.Standard.A1.Flex`, 2 OCPU and 12 GB. The processor is Ampere, that is **aarch64**: application images are built on GitHub ARM runners, otherwise they will not start here.

## How the pieces fit together

The browser is the only thing that talks to more than one service. It loads pages from the frontend, calls the API directly over `/api`, and opens a WebSocket on `/ws`. The frontend process does not proxy either of them.

```
browser
  |  HTTPS / WSS
  v
edge-nginx ──┬── scribo.pp.ua       → prod-frontend / prod-backend / prod-socket
             └── scribo-stage.pp.ua → stage-frontend / stage-backend / stage-socket
                                                   |
                                                   |- MongoDB (Atlas or a container)
                                                   |- uploads directory on the host
                                                   |- mail
                                                   `- Redis pub/sub inside the stack
```

The backend owns the data. It writes to Mongo, writes images into the uploads directory, sends mail, and publishes `{ room, event, payload }` into the Redis channel `scribo:events`. The socket service subscribes to that channel, verifies access tokens with the RS256 **public** key, and reads conversation membership from the same Mongo so a client cannot join a chat it does not belong to. It never creates a message: creating one stays an HTTP call to the backend, and the socket event is only the notification that it happened. Typing indicators are the one thing that never reaches the backend — they live entirely in Redis between sockets, because they are not worth persisting.

Redis channel names are identical in both environments. That is safe: the processes connect to different containers on different networks and never see each other's traffic.

## Three stacks

The machine runs three independent Compose projects.

| Stack | Contents | Network |
| --- | --- | --- |
| `prod` | frontend, backend, socket, redis | `scribo-prod` |
| `stage` | the same | `scribo-stage` |
| `edge` | nginx with ports 80 and 443 and the certificates; `status` for the operator console | attached to both |

`prod` and `stage` are described by **one** `compose.yml`. It is brought up twice, from different directories and with different environment files. The environments do not overlap: separate containers, separate network, separate Redis, separate status page.

`edge` owns the ports and routes by domain. It has no dependency on the environments: the upstreams in the rendered configuration are variables resolved through the Docker DNS resolver, so nginx starts even when an environment is down, and in that case serves its status page.

## How a request reaches a service

nginx looks at `server_name` first, then at the path, and hands the request to the right container of the right environment.

| Path | Target |
| --- | --- |
| `/`, pages, `/_next` | `<stack>-frontend:3000`. If the frontend does not answer, nginx serves the status page |
| `/status` | the same page, always from nginx. Its script probes `/`, `/health` and `/ws`; the operator block calls `/status/api/` |
| `/api`, `/api/...` | `<stack>-backend:3001` |
| `/health` | `<stack>-backend:3001` |
| `/ws` | `<stack>-socket:3002` |
| `/uploads/` | the environment's uploads directory, read-only, straight from disk |
| `/.well-known/acme-challenge/` | certbot webroot, over HTTP only |

Ports 3000, 3001 and 3002 are not published. The API can only be reached from outside through the domain.

The frontend does not call the backend on a local port. In the browser `NEXT_PUBLIC_APP_API_URL` equals the site address, `/api/...` is appended, and the request arrives at nginx again. The socket works the same way through `wss://<domain>/ws`.

Successful requests are not logged (`access_log off`); errors go to `error_log`.

## Why container names carry a prefix

Containers are called `prod-backend`, `stage-backend` and so on. The prefix comes from the `STACK` variable and exists for exactly one reason: Docker's DNS has no notion of "the one on this network". nginx is attached to both networks, and if a container named `backend` answered on each of them, the resolver would return both addresses and spread requests across production and staging at random.

Inside a stack there is no prefix: services reach each other by service name, the backend talks to `redis` as `redis`. That is why a single `compose.yml` serves both environments.

## Directories on the machine

```
/srv/scribo/
  infra/                  git clone; the only thing a deploy updates
  prod/
    stack.env             STACK, IMAGE_TAG, memory limits
    env/                  backend.env, frontend.env, socket.env
    uploads/              post images, avatars and group photos, mode 755
    backups/              archives (Mongo + uploads), mode 700
  stage/
    stack.env
    env/
    uploads/
    backups/
  edge/
    stack.env             environment and domain list
    certs/                Let's Encrypt
    certbot-www/          ACME webroot
```

The machine user is `scribo`; GitHub Actions connects as `github-actions-deploy`. Both are in the `docker` group, only the first has sudo. Everything under `/srv/scribo` is owned by `scribo:docker` with setgid, so new files inherit the group and a deploy can write without repairing permissions.

## Two kinds of environment file

This is the easiest thing in the setup to get wrong.

| File | Read by | Contents |
| --- | --- | --- |
| `<env>/stack.env` | `docker compose` itself, on the host | the `${...}` substitutions in `compose.yml`: `STACK`, `IMAGE_TAG`, `COMPOSE_PROJECT_NAME`, memory limits |
| `<env>/env/*.env` | the containers | `DB_HOST`, `JWT_PRIVATE_KEY`, `NEXT_PUBLIC_*` and the rest |

Compose never looks inside `env/*.env`, it only passes them through. A `${STACK}` substitution comes from `stack.env` and nowhere else.

Templates live in `env/*.example`, one set for both environments. The real files are not in git. Production and staging differ in values: `DB_NAME`, `FRONTEND_ORIGIN`, `API_ORIGIN`, every `NEXT_PUBLIC_*`, plus `IMAGE_TAG` and `STACK` in `stack.env`.

`PORT` and `REDIS_URL` do not belong in `env/*.env`: `compose.yml` sets them and overrides anything found there. The socket service must never receive `JWT_PRIVATE_KEY` or `JWT_REFRESH_KEY` — it exits at startup if it does.

`edge` has a single container environment file, `/srv/scribo/edge/env/status.env`, holding the operator login for `/status`. `stack.env` does not replace it.

`NEXT_PUBLIC_*` values are read when the frontend container starts and injected into the page as `window.__SCRIBO_ENV`; they are not baked into the image. After editing them the container must be recreated.

## The nginx configuration is rendered at startup

The repository holds one `edge/stack.conf.template` describing a single environment. When the container starts, `edge/entrypoint.d/10-render-stacks.sh` walks the `STACKS` list and writes one file per environment into `/etc/nginx/conf.d/`. `edge/nginx.conf` itself contains only the `http` block and the includes.

```
STACKS=prod:scribo.pp.ua stage:scribo-stage.pp.ua
```

Adding an environment or a domain is a change to that one line, not a copy of a hundred lines of configuration. The prefix before the colon must match the environment's `STACK`, otherwise nginx will look for containers that do not exist.

Two consequences are worth knowing. The configuration on disk is not the configuration in the container, so inspect the rendered one:

```bash
docker compose exec nginx cat /etc/nginx/conf.d/prod.conf
```

And `envsubst` is called with an explicit variable list. Without it, nginx's own variables — `$host`, `$remote_addr`, `$proxy_add_x_forwarded_for` — would be substituted with empty strings.

Rendering and syntax can be checked without starting anything:

```bash
./scribo check
```

## Commands on the server

Everything goes through `infra/scribo`, from any directory. The target is `prod`, `stage` or `edge`.

```bash
cd /srv/scribo/infra

./scribo up prod                # bring up an environment with fresh images from GHCR
./scribo up edge                # bring up nginx and the status service
./scribo up all                 # prod, then stage, then edge
./scribo down prod              # remove the containers; uploads and backups stay
./scribo up prod backend        # a single service
./scribo pull prod backend      # fetch one image
./scribo restart prod frontend  # after editing its env file
./scribo ps                     # state of all three stacks
./scribo logs prod --tail 50
./scribo config prod            # the compose file with substitutions applied
./scribo check                  # render the nginx config and run nginx -t
./scribo dc prod exec backend sh
```

The script assembles the `docker compose` invocation with the right `--project-directory` and `--env-file`. State is looked up in `/srv/scribo`, overridable through `SCRIBO_ROOT` — that is how the local checks and CI run against a fake machine.

```bash
curl -fsSI https://scribo.pp.ua/health
```

## Running the whole system locally

From `infra/local`, with ordinary compose commands. Images are built from the sibling `backend`, `socket` and `frontend` directories.

```bash
docker compose up -d --build      # everything
docker compose down               # stop; Mongo data survives
docker compose up -d redis mongo  # only the datastores
docker compose down -v            # stop and erase the data
```

`down` does not touch host directories, so images and backups survive a restart. An environment without `edge` works, it is simply not reachable from outside.

## The status page

`edge/errors/prod/frontend.html` and `edge/errors/stage/frontend.html` are one page per environment, so two browser tabs cannot be confused. nginx serves it at `/status` and substitutes it for the frontend response on 502, 503 and 504.

Its probes use relative paths (`/`, `/health`, `/ws`), which means the same domain and the upstreams of the same environment. The staging page therefore cannot report on production.

The limitation that follows: the page lives in nginx. If `edge` is down there is no status at all. And the backend's `/health` is a static answer that does not ping the database, so an Atlas outage at runtime will not show up there.

Below the public probes there is an operator login, served by a separate `edge-status` container in the same stack: nginx has neither the Docker socket nor the host `/proc`, so a static page cannot start containers or read machine memory. It comes up together with nginx:

```bash
./scribo up edge
```

Credentials live in `/srv/scribo/edge/env/status.env` (template `env/status.env.example`): `STATUS_USER`, `STATUS_PASSWORD` and `STATUS_SECRET`, the last at least 16 characters. While the file is empty the status page works as before and the login button reports that it is not configured. After editing it, recreate the container with `./scribo up edge`.

The session is a 12 hour cookie scoped to `https://<domain>/status`. Production and staging do not share it. A request from another site cannot use it: the cookie is `SameSite=Strict` and a header set only by the page's own script is required. After eight failed attempts from one address, logins are blocked for ten minutes.

Once signed in, the page for that domain can:

- start, stop and restart `frontend`, `backend`, `socket`, `redis` and `mongo` of **its own** environment;
- report disk total, used and free;
- report RAM total, used and free, using `MemAvailable`, that is what the system can actually hand out;
- list the five processes with the largest RSS, in GB and as a share of RAM;
- list the ten processes with the largest CPU share measured over half a second.

Stopping does not remove a container, the next start brings it back. If the container does not exist at all (`./scribo down` removes it), the button says so and the fix is `./scribo up <env> <service>` on the server. nginx cannot be stopped from this page, since that would also remove the way back in.

## What is stored where

No application source exists on the machine. The database is MongoDB Atlas, or a container when the environment enables the `mongo` profile. Uploaded files live in `/srv/scribo/<env>/uploads` and are served by the edge nginx directly, read-only, bypassing Node. Both environments currently share one cluster and differ only by `DB_NAME`; their uploads are separate. Redis exists only inside compose, without snapshots and without AOF: after the container is recreated the queue, presence and typing state are empty, which is expected.

| Service | Image |
| --- | --- |
| nginx | `nginx:1.27-alpine` |
| status | `python:3.12-alpine` |
| frontend | `ghcr.io/scribo-blog-org/frontend:${IMAGE_TAG}` |
| backend | `ghcr.io/scribo-blog-org/backend:${IMAGE_TAG}` |
| socket | `ghcr.io/scribo-blog-org/socket:${IMAGE_TAG}` |
| redis | `redis:7-alpine` |

`IMAGE_TAG` is `latest` for production and `staging` for staging. Commit-sha tags are published as well, so a rollback is one line in `stack.env` followed by `./scribo up`.

## Data directories and backups

Environment data lives in plain host directories rather than named Docker volumes. Compose bind-mounts them into the backend:

| Host directory | Path in the backend | Also read by |
| --- | --- | --- |
| `/srv/scribo/<env>/uploads` | `/app/uploads` | edge nginx at `/srv/uploads/<env>`, read-only |
| `/srv/scribo/<env>/backups` | `/app/backups` | nothing; never exposed |

The backend reads `/app/uploads` and copies it into every archive, so a backup contains the files as well as the database.

In `compose.yml` the paths are written as `./uploads` and `./backups`. The `scribo` script runs compose with `--project-directory /srv/scribo/<env>`, so `./` resolves to that environment's directory and neither a prefix nor volume names are needed. The directories are created by `scripts/vm-setup.sh` with owner uid 1000, the user the backend image runs as. If a directory is missing, Docker creates it as root and the backend cannot write into it.

Subdirectories inside `uploads` are created by the backend on first write (`src/avatar`, `src/featured_image`, `src/group`), and nginx serves the whole tree through one `alias`, so a new image kind needs no change here.

Backups are produced by the backend itself; there is no separate service and no cron entry. One file `scribo-YYYYMMDD-HHMMSS.tar` holds the Mongo dump and the entire uploads directory. `BACKUP_ENABLED=true|false` in `env/backend.env` controls it: `true` in production, `false` on staging. Every run, including manual ones, is a new file. All of today's are kept, then one per day for the past week, then one per month for a year. Schedule, manual runs, history and download live in the Backups tab of the admin panel, visible only to `tech_admin`. Uploading an archive requires `BACKUP_RESTORE_ENABLED=true`; the `/api/backups/upload` route has its own nginx location with a 4 GB body limit, so changing it means reloading nginx. Retention and restore are documented in full in the backend repository.

Archives sit on the same machine as the application. If the disk is lost they are lost with it, so a recent archive should be downloaded from the admin panel from time to time.

To read the files on the host: `sudo ls /srv/scribo/prod/backups`. The directory is owned by uid 1000 and is mode 700.

## Building and deploying

A push to `master` in `frontend`, `backend` or `socket` triggers GitHub Actions: lint, test, an image build on an ARM runner, a push to ghcr.io tagged `latest` and the commit sha, then SSH to the machine where `./scribo pull prod <service>` and `./scribo up prod <service>` run.

A push to `dev` does the same with the `staging` tag against the `stage` stack. Merging `dev` into `master` is blocked until the `Build` check on the pull request is green. Pull requests run lint, test and a local `docker build` without pushing, also on ARM.

After a deploy, `docker image prune -f` runs: each deploy leaves the previous image untagged, and without this the disk fills with `node_modules` layers. It does not touch the `certbot/certbot` image.

Nothing is built on the machine; `docker compose build` is not used here.

A push to `master` in this repository connects to the machine, runs `git pull --ff-only` in `/srv/scribo/infra` and brings both environments up. If the commit touched anything under `edge/`, it additionally runs `./scribo check` against the real certificates and recreates nginx. `stack.env` and `env/*.env` are never touched by the workflow; they live outside the repository.

A pull request in this repository does not touch the server. It assembles a fake machine state in a temporary directory — example env files instead of secrets, self-signed certificates instead of the real ones — and runs `./scribo config` for all three targets plus `./scribo check`.

### Release order

The three applications are versioned independently but deployed from the same branch. When a change spans more than one of them — a new API endpoint plus the screen that calls it, or a new socket event plus its consumer — deploy the backend and the socket service before or together with the frontend. The frontend is the only component that will visibly break if it is newer than what it calls.

## Certificates

Let's Encrypt, one certificate per domain, both in `/srv/scribo/edge/certs`, mounted into nginx as `/etc/letsencrypt` read-only. Contact address: `scribo.blog.dev@gmail.com`.

The first issuance and the renewals work differently, and that matters. Until a certificate exists, nginx with `listen 443 ssl` will not start at all, so there is nothing to issue through. The first time, certbot runs its own server on port 80 and `edge` must be down:

```bash
./scribo down edge
./scribo certs
./scribo up edge
```

Renewal goes through the webroot and needs no downtime: nginx serves `/.well-known/acme-challenge/` over HTTP and that path is not redirected to HTTPS.

```bash
./scribo renew
```

This is already in the `scribo` user's crontab at 03:00. Certbot renews when less than a month remains and reloads nginx afterwards. Certificates are valid for 90 days.

## MongoDB in a container

The `mongo` service is declared in `compose.yml` under the `mongo` profile and **does not start by default**: the environment stays on the external database and notices nothing. It is enabled per environment with one line in `stack.env`:

```
COMPOSE_PROFILES=mongo
```

What that gives: a `<prefix>-mongo` container (image `mongo:7.0`, version set by `MONGO_VERSION`; 8.0 and newer fail to start on Linux kernel 6.19+ with SERVER-121912, hence the 7.0 default), data in `/srv/scribo/<env>/mongo` on the host, no published ports, reachable only by the containers of that environment under the name `mongo`. Each environment gets its own database and its own passwords. The backend and the socket depend on it with `required: false`, so without the profile the stacks come up exactly as before. Limits: `MEM_MONGO` (1g) and `MONGO_CACHE_GB` (0.5), because the WiredTiger cache does not account for the container limit by itself.

**Enabling it, for example on staging:**

1. Create the data directory. `vm-setup.sh` does this on new machines; on an existing one:
   ```bash
   sudo install -d -m 700 -o 999 -g 999 /srv/scribo/stage/mongo
   ```
   uid 999 is the `mongodb` user inside the image.
2. Write `env/mongo.env` from `env/mongo.env.example`: the admin and application passwords. They are read once, on the first start against an empty directory, when `mongo/init-app-user.js` creates the application user with `readWrite` on its own database only.
3. In `env/backend.env` and `env/socket.env` set `MONGODB_URI=mongodb://scribo:<app password>@mongo:27017/scribo?authSource=admin`. It takes precedence over `DB_USER`, `DB_PASSWORD` and `DB_HOST`, which can be left in place: going back to the external database means commenting out `MONGODB_URI`. **`socket.env` additionally needs `DB_NAME=scribo`** (the same value as `MONGO_APP_DB`); the socket service takes the database name only from there and will not start without it.
4. Add `COMPOSE_PROFILES=mongo` to `stack.env` and run `./scribo up stage`. Compose starts `mongo` first and waits for its healthcheck.

The database starts empty. Data is moved by the backend's own backup mechanism:

1. **Before switching**, while the environment is still on the external database, take a backup from the Backups tab and download the file. This needs `BACKUP_ENABLED=true` and `BACKUP_RESTORE_ENABLED=true` in `backend.env`.
2. Switch the environment to the container database as above. Register a user through the site and grant a role so the Backups tab appears:
   ```bash
   docker exec stage-mongo sh -c 'mongosh -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" --authenticationDatabase admin scribo --quiet --eval "db.users.updateOne({email: \"you@example.com\"}, {\$set: {role: \"tech_admin\"}})"'
   ```
3. Upload the downloaded file with Upload backup and press Restore. The database name inside the archive does not matter, it is rewritten on install. The uploads directory comes with it.

One thing to watch: `avatar`, `featured_image` and group photos must hold the path `/uploads/src/...` without a domain. The browser prepends the origin of its own environment. Absolute links to S3 or another host will not resolve this way.

**Backing up the container database** is the same application backup: `mongodump` inside the backend image connects to the container through `MONGODB_URI`. Do not copy `/srv/scribo/<env>/mongo` while it is running; a live database yields a corrupt copy.

## First-time machine setup

```bash
sudo sh scripts/vm-setup.sh
```

The script installs Docker with the compose plugin, creates the users and directories, opens 80 and 443 in `iptables` and installs the cron entry. Running it again is safe.

The rest is manual: keys in `authorized_keys` for both users, secrets from the templates in `env/`, then `./scribo certs` and `./scribo up`.

Three things the script cannot do, without which nothing will come up:

- Open 80 and 443 in the VCN Security List. Host `iptables` rules do not replace this; both levels are required.
- **Reserve the public IP.** By default the address is ephemeral and changes on instance stop/start, and both the DNS records and the Atlas access list depend on it.
- Add the machine's egress IP to the MongoDB Atlas IP Access List. The backend pings the database at startup and exits with code 1 on failure, which means it restarts forever and never becomes healthy.

## What survives a reboot

Certificates, `stack.env`, `env/*.env` and the repository clone are on disk. Containers are brought back by Docker (`restart: unless-stopped`; `docker` and `cron` are enabled in systemd). Redis comes back empty.

```bash
systemctl is-enabled docker cron
```
