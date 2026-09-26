# Scribo on the VM

Production compose for one machine. Images are built by GitHub Actions on `master` and stored in ghcr.io. This repository does not build them. Nginx publishes port 80 and routes:

| Path | Service |
| --- | --- |
| `/` | frontend:3000 |
| `/api`, `/health` | backend:3001 |
| `/ws` | socket:3002 |

Redis stays on the docker network. The socket must not receive `JWT_PRIVATE_KEY` or `JWT_REFRESH_KEY`, so backend and socket have separate env files.

## First boot

```bash
sudo mkdir -p /opt/scribo
sudo chown "$USER" /opt/scribo
git clone git@github.com:scribo-blog-org/infra.git /opt/scribo
cd /opt/scribo
cp env/backend.env.example env/backend.env
cp env/socket.env.example env/socket.env
cp env/frontend.env.example env/frontend.env
```

Fill the env files. `FRONTEND_ORIGIN`, `API_ORIGIN`, and the frontend public URLs are the public origin, for example `http://203.0.113.10`. The frontend image does not bake these in. The container reads `env/frontend.env` when it starts:

| Variable | Example |
| --- | --- |
| `NEXT_PUBLIC_APP_API_URL` | `http://203.0.113.10` |
| `NEXT_PUBLIC_SOCKET_URL` | `ws://203.0.113.10/ws` |
| `NEXT_PUBLIC_APP_VERCEL_PROJECT_PRODUCTION_URL` | `203.0.113.10` |
| `NEXT_PUBLIC_GOOGLE_CLIENT_ID` | Google web client id |

In `frontend`, `backend`, and `socket`, add Actions secrets:

| Secret | Value |
| --- | --- |
| `SSH_PRIVATE_KEY` | private deploy key |
| `SERVER_HOST` | VM address |
| `SERVER_USER` | SSH user |
| `GHCR_USER` | GitHub user that can pull packages |
| `GHCR_PULL_TOKEN` | PAT with `read:packages`, only if the packages stay private |

Put the matching public key in `~/.ssh/authorized_keys` on the VM.

```bash
docker compose pull
docker compose up -d
```

After that, a push to `master` in a service repository builds its image and runs `docker compose pull <service> && docker compose up -d --no-deps <service>` in `/opt/scribo`.
