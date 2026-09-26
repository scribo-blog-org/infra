# Scribo

Публичный сайт блога. Четыре репозитория: этот (`infra`) описывает машину, на которой всё крутится. Код приложений живёт отдельно.

| Репозиторий | Что это |
| --- | --- |
| `frontend` | Next.js, страницы и браузерный клиент |
| `backend` | NestJS, HTTP API |
| `socket` | WebSocket: сообщения и присутствие |
| `infra` | Compose, nginx, сертификат, env на сервере |

Сайт: `https://scribo-blog.duckdns.org`. Один DNS-адрес, один IP. Снаружи открыты только порты 80 и 443.

## Как запрос доходит до сервиса

Браузер всегда ходит на один хост. Nginx смотрит на путь и отдаёт запрос контейнеру во внутренней сети Docker `scribo`. Имена `frontend`, `backend`, `socket` и `redis` — это DNS Docker, не публичные адреса.

| Путь | Куда |
| --- | --- |
| `/`, страницы, `/_next` | `frontend:3000`. Если фронт не отвечает, nginx отдаёт `errors/frontend.html` |
| `/status` | та же статичная страница, всегда с nginx. Скрипт на ней сам спрашивает `/`, `/health` и `/ws` |
| `/api`, `/api/...` | `backend:3001` |
| `/health` | `backend:3001` |
| `/ws` | `socket:3002` |
| `/.well-known/acme-challenge/` | файлы certbot, только по HTTP |

Порты 3000, 3001 и 3002 наружу не опубликованы. Проверить API снаружи можно только так: `https://scribo-blog.duckdns.org/api/...` и `https://scribo-blog.duckdns.org/health`.

Фронт не ходит на backend по локальному порту. В браузере `NEXT_PUBLIC_APP_API_URL` равен `https://scribo-blog.duckdns.org`, к нему дописывается `/api/...`, и запрос снова приходит на nginx. Сокет так же: `wss://scribo-blog.duckdns.org/ws`.

В `proxy_pass` адрес задан переменной, резолвер — Docker DNS `127.0.0.11`. После пересоздания контейнера nginx берёт новый IP без своего рестарта.

Журнал успешных запросов nginx выключен (`access_log off`). Ошибки пишутся в `error_log`. Файл конфига смонтирован в контейнер как один файл. Править его на хосте нужно так, чтобы inode не менялся, либо после правки пересоздать контейнер nginx. `sed -i` создаёт новый файл, и уже запущенный контейнер продолжает читать старый.

## Что где хранится

На виртуальной машине нет исходников и нет MongoDB. База — MongoDB Atlas. Файлы постов — S3. Redis живёт только в compose, без снимков и без AOF: после пересоздания контейнера очередь и присутствие пустые, это нормально.

| Сервис | Образ | Память |
| --- | --- | --- |
| nginx | `nginx:1.27-alpine` | 32 МБ |
| frontend | `ghcr.io/scribo-blog-org/frontend:latest` | 280 МБ |
| backend | `ghcr.io/scribo-blog-org/backend:latest` | 280 МБ |
| socket | `ghcr.io/scribo-blog-org/socket:latest` | 128 МБ |
| redis | `redis:7-alpine` | 160 МБ, из них 128 МБ на данные |

Каталог на сервере: `/opt/scribo`. Пользователь машины: `scribo`. Деплой из GitHub Actions заходит как `github-actions-deploy`. Он в группе `docker`. Секреты в `env/backend.env` и `env/socket.env` должны быть читаемы группой (`640`), каталог `env` — доступен этому пользователю.

`env/*.env` не коммитятся. У backend и socket разные файлы. Сокету нельзя отдавать `JWT_PRIVATE_KEY` и `JWT_REFRESH_KEY`: процесс при старте из-за этого завершается. Оба ходят в Redis по `redis://redis:6379`.

Публичные значения, которые уже стоят на сервере:

| Файл | Переменная | Значение |
| --- | --- | --- |
| `env/backend.env` | `FRONTEND_ORIGIN` | `https://scribo-blog.duckdns.org` |
| `env/backend.env` | `API_ORIGIN` | `https://scribo-blog.duckdns.org` |
| `env/frontend.env` | `NEXT_PUBLIC_APP_API_URL` | `https://scribo-blog.duckdns.org` |
| `env/frontend.env` | `NEXT_PUBLIC_APP_VERCEL_PROJECT_PRODUCTION_URL` | `scribo-blog.duckdns.org` |
| `env/frontend.env` | `NEXT_PUBLIC_SOCKET_URL` | `wss://scribo-blog.duckdns.org/ws` |
| `env/frontend.env` | `NEXT_PUBLIC_GOOGLE_CLIENT_ID` | id веб-клиента Google |

`FRONTEND_ORIGIN` — разрешённый CORS origin и базовый адрес ссылок в письмах, без завершающего слэша. В Google Cloud Console у этого client id в Authorized JavaScript origins должен быть `https://scribo-blog.duckdns.org`.

Фронт читает `NEXT_PUBLIC_*` при старте контейнера и отдаёт их в страницу как `window.__SCRIBO_ENV`. В образ они не зашиваются. После правки env контейнер нужно пересоздать.

## Как сервисы связаны

Backend пишет в Mongo и S3, шлёт почту и публикует события в Redis-канал `scribo:events`. Socket подписан на этот канал и на канал присутствия. Он проверяет access JWT публичным ключом RS256 и читает участников беседы из той же Mongo, но сам сообщения не создаёт: создание остаётся HTTP-запросом к backend.

Схема:

```
браузер
  │  HTTPS / WSS
  ▼
nginx
  ├─ /            → frontend
  ├─ /api /health → backend ── MongoDB Atlas
  │                    │       S3, почта
  │                    └── Redis pub/sub
  └─ /ws          → socket ───┘
                         └── MongoDB Atlas (только проверка участника)
```

## Сборка и выкладка

Пуш в `master` репозитория `frontend`, `backend` или `socket` запускает GitHub Actions: lint, test, сборка образа, push в ghcr.io тегов `latest` и sha коммита, затем SSH на машину.

На сервере для своего сервиса выполняется `docker compose pull` и `docker compose up -d`. После этого `docker image prune -f` удаляет безымянные образы, оставшиеся от прошлого `latest`. Образ `certbot/certbot` эта команда не трогает.

Сборки на машине нет. `docker compose build` здесь не используется.

Каждый деплой оставляет предыдущий образ без тега. Без `docker image prune -f` диск забивается слоями `node_modules`.

Pull request в `master` гоняет отдельный workflow: lint, test и локальный `docker build` без push. В комментарии к PR таблица шагов Lint, Test, Build. Пока проверка `Build` не зелёная, мерж закрыт правилом репозитория, если ruleset уже включён.

## Сертификат

Let's Encrypt, webroot. Сертификат на хосте в `/opt/scribo/certs`, в nginx он смонтирован как `/etc/letsencrypt` только для чтения. Проверка домена: nginx отдаёт `/opt/scribo/certbot-www` по `/.well-known/acme-challenge/` и по HTTP, этот путь не редиректится на HTTPS.

Контакт: `scribo.blog.dev@gmail.com`. Файлы: `/opt/scribo/certs/live/scribo-blog.duckdns.org/`.

Продление в crontab пользователя `scribo`, каждый день в 03:00. Certbot продлевает сертификат, когда до конца меньше месяца, и тогда перезапускает nginx. Сертификат живёт 90 дней.

```bash
crontab -l
```

Строка должна начинаться с `0 3 * * * docker run`. Образ certbot между запусками может быть удалён полной очисткой `docker system prune -a`. Следующий запуск скачает его снова. Данные в `/opt/scribo/certs` от этого не зависят.

Пока сертификата нет, nginx с `listen 443 ssl` не стартует.

## Что переживает перезагрузку

Сертификат, `nginx.conf` и env лежат на диске. Контейнеры поднимает Docker (`restart: unless-stopped`, `docker` и `cron` в systemd — `enabled`). Redis после пересоздания пустой.

```bash
systemctl is-enabled docker cron
```

## Команды

```bash
cd /opt/scribo
docker compose ps
docker compose logs --tail 50
curl -fsSI https://scribo-blog.duckdns.org/health
```

Пересоздать один сервис после правки его env:

```bash
docker compose up -d --force-recreate --no-deps frontend
```

Проверить nginx и перечитать конфиг, если файл не заменяли новым inode:

```bash
docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload
```

Если конфиг правили через `sed -i`, контейнер нужно пересоздать:

```bash
docker compose up -d --no-deps --force-recreate nginx
```

Чистые логи с нуля — это новые контейнеры, не рестарт демона:

```bash
docker compose down
docker compose up -d
```
