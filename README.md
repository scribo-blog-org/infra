# Scribo

Публичный сайт блога. Четыре репозитория: этот (`infra`) описывает машину, на которой всё крутится. Код приложений живёт отдельно.

| Репозиторий | Что это |
| --- | --- |
| `frontend` | Next.js, страницы и браузерный клиент |
| `backend` | NestJS, HTTP API |
| `socket` | WebSocket: сообщения и присутствие |
| `infra` | Compose, nginx, сертификат, env на сервере |

Сайт: `https://scribo-blog.duckdns.org`. Стейдж: `https://scribo-blog-stage.duckdns.org`. Оба имени смотрят на один IP. Снаружи открыты только порты 80 и 443.

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

Пуш в `master` репозитория `frontend`, `backend` или `socket` запускает GitHub Actions: lint, test, сборка образа, push в ghcr.io тегов `latest` и sha коммита, затем SSH на машину. Пуш в `dev` делает то же с тегом `staging` и поднимает сервис в `docker-compose.stage.yml`.

На сервере для своего сервиса выполняется `docker compose pull` и `docker compose up -d`. Для `dev` файл compose другой, каталог тот же: `/opt/scribo`. После этого `docker image prune -f` удаляет безымянные образы, оставшиеся от прошлого тега. Образ `certbot/certbot` эта команда не трогает.

Сборки на машине нет. `docker compose build` здесь не используется.

Каждый деплой оставляет предыдущий образ без тега. Без `docker image prune -f` диск забивается слоями `node_modules`.

Pull request в `master` гоняет отдельный workflow: lint, test и локальный `docker build` без push. В комментарии к PR таблица шагов Lint, Test, Build. Пока проверка `Build` не зелёная, мерж закрыт правилом репозитория, если ruleset уже включён.

Пуш в `master` этого репозитория тоже выкладывается. На сервере в `/opt/scribo` выполняется `git pull --ff-only` и `docker compose up -d` без `pull`: образы приложений не качаются, пересоздаются только сервисы, у которых изменилось описание в compose. Если в коммите менялись `nginx.conf` или `errors/`, новый конфиг проверяется через `nginx -t` на боевом сертификате, и контейнер nginx пересоздаётся отдельно. Файлы `env/*.env` workflow не перезаписывает.

Pull request в `master` этого репозитория гоняет `nginx -t` на временном сертификате и `docker compose config`. На сервер он не заходит.

## Стейдж

Тот же сервер и тот же nginx. Второй compose не публикует порты и не поднимает свой nginx. Контейнеры стейджа входят в сеть Docker `scribo` под именами `stage-frontend`, `stage-backend`, `stage-socket` и `stage-redis`. Nginx прода выбирает их по `server_name scribo-blog-stage.duckdns.org`.

Снаружи по-прежнему только 80 и 443. Внутри контейнера фронт слушает 3000, backend 3001, сокет 3002 — и у прода, и у стейджа. Это порты разных контейнеров, они не занимают хост и друг с другом не спорят. Запрос на боевой хост идёт в проект `scribo`, на стейдж — в проект `scribo-stage`.

В `docker ps` два проекта. У `scribo`: nginx, frontend, backend, socket, redis. У `scribo-stage`: `scribo-stage-frontend`, `scribo-stage-backend`, `scribo-stage-socket`, `scribo-stage-redis`. Nginx один, в проде.

Образы: `ghcr.io/scribo-blog-org/<сервис>:staging`. По замерам фронт, backend и сокет стейджа — около 148 МБ, свой Redis ещё около 5 МБ. Потолок приложений: фронт и backend по 120 МБ, сокет 64 МБ. Redis как у прода: потолок 160 МБ, данные до 128 МБ. Свободных было 344 МБ, после запуска останется около 190 МБ. Swap уже занят на 121 МБ, поэтому одновременный деплой и трафик могут снова упереться в swap и замедлить прод.

Секреты копируются из прода в `env/stage/`. В git их нет, примеры лежат рядом как `*.env.example`. Меняются публичные адреса и имя базы: `DB_NAME=dev` у backend и socket. JWT, почта и бакет те же. Пользователь Atlas должен иметь право на базу `dev`.

Redis у стейджа свой, `redis://stage-redis:6379`. Каналы те же, что у прода (`scribo:events`, `scribo:presence`): процессы ходят в разные контейнеры и не видят чужие сообщения. Код приложений для этого не меняется.

`NEXT_PUBLIC_*` читаются при старте контейнера. В Google Cloud Console у того же client id в Authorized JavaScript origins добавляется `https://scribo-blog-stage.duckdns.org`.

Пока нет ветки `dev`, тег `staging` один раз ставится с текущего `latest`. Дальше его обновляет push в `dev`.

Сначала в DuckDNS имя `scribo-blog-stage` указывает на тот же IP, что и прод. Сертификат выпускается до выкладки нового `nginx.conf`. Иначе `nginx -t` не проходит, и боевой nginx не пересоздаётся. Проверка ACME уже обслуживается текущим сервером на порту 80.

```bash
cd /opt/scribo

docker run --rm \
  -v /opt/scribo/certs:/etc/letsencrypt \
  -v /opt/scribo/certbot-www:/var/www/certbot \
  certbot/certbot certonly --webroot -w /var/www/certbot \
  -d scribo-blog-stage.duckdns.org \
  --email scribo.blog.dev@gmail.com --agree-tos --non-interactive

cp env/stage/backend.env.example env/stage/backend.env
cp env/stage/frontend.env.example env/stage/frontend.env
cp env/stage/socket.env.example env/stage/socket.env
chgrp docker env/stage/backend.env env/stage/frontend.env env/stage/socket.env
chmod 640 env/stage/backend.env env/stage/frontend.env env/stage/socket.env

for s in frontend backend socket; do
  docker pull "ghcr.io/scribo-blog-org/$s:latest"
  docker tag "ghcr.io/scribo-blog-org/$s:latest" "ghcr.io/scribo-blog-org/$s:staging"
done
```

В `env/stage/backend.env` и `env/stage/socket.env` вписываются те же секреты, что в проде, с `DB_NAME=dev`. В `env/stage/frontend.env` копируется `NEXT_PUBLIC_GOOGLE_CLIENT_ID`. После этого:

```bash
docker compose -f docker-compose.stage.yml up -d
```

Продление уже в crontab: `certbot renew` подхватывает второй сертификат в том же каталоге.

Проверка:

```bash
docker compose -f docker-compose.stage.yml ps
curl -fsSI https://scribo-blog-stage.duckdns.org/health
```

## Сертификат

Let's Encrypt, webroot. Сертификат на хосте в `/opt/scribo/certs`, в nginx он смонтирован как `/etc/letsencrypt` только для чтения. Проверка домена: nginx отдаёт `/opt/scribo/certbot-www` по `/.well-known/acme-challenge/` и по HTTP, этот путь не редиректится на HTTPS.

Контакт: `scribo.blog.dev@gmail.com`. Файлы прода: `/opt/scribo/certs/live/scribo-blog.duckdns.org/`. Файлы стейджа: `/opt/scribo/certs/live/scribo-blog-stage.duckdns.org/`.

Продление в crontab пользователя `scribo`, каждый день в 03:00. Certbot продлевает сертификат, когда до конца меньше месяца, и тогда перезапускает nginx. Сертификат живёт 90 дней.

```bash
crontab -l
```

Строка должна начинаться с `0 3 * * * docker run`. Образ certbot между запусками может быть удалён полной очисткой `docker system prune -a`. Следующий запуск скачает его снова. Данные в `/opt/scribo/certs` от этого не зависят.

Пока сертификата нет, nginx с `listen 443 ssl` не стартует.

## Бэкапы Mongo

`backup-mongo.sh` читает базу из `env/backend.env` (`DB_USER`, `DB_PASSWORD`, `DB_HOST`, `DB_NAME`) и снимает дамп одноразовым контейнером `mongo:7`. Compose и сайт не перезапускаются. Пароль не печатается в лог и не передаётся аргументом процесса.

| Каталог | Что хранится |
| --- | --- |
| `backups/daily/` | `ГГГГ-ММ-ДД.archive.gz`, каждый запуск. Старше 30 дней удаляются |
| `backups/weekly/` | По воскресеньям копия того же файла. Старше года удаляются |

Каталог `backups` доступен только пользователю `scribo` (`700`). Архивы в git не коммитятся.

Ручной запуск из `/opt/scribo`: `./backup-mongo.sh`.

Cron пользователя `scribo`, в 04:15, после certbot в 03:00:

```bash
15 4 * * * /opt/scribo/backup-mongo.sh
```

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
