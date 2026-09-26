# Scribo на VM

Один compose на машине Google Cloud. Сайт: `https://scribo-blog.duckdns.org`. Каталог на сервере: `/opt/scribo`, пользователь `scribo`. Исходники приложений на сервер не кладутся. Сервер только скачивает готовые образы из ghcr.io.

MongoDB на этой машине нет, база снаружи. Redis только во внутренней сети Docker.

## Что слушает наружу

Наружу открыты только 80 и 443 у nginx. Остальные порты — `expose` внутри сети `scribo`, с хоста они не доступны.

| Снаружи | Куда |
| --- | --- |
| `443` | nginx, основной трафик |
| `80` | nginx: `/.well-known/acme-challenge/` для Let's Encrypt, всё остальное редирект на HTTPS |

| Путь | Контейнер |
| --- | --- |
| `/` | `frontend:3000` |
| `/api`, `/health` | `backend:3001` |
| `/ws` | `socket:3002` |

| Сервис | Образ | Память |
| --- | --- | --- |
| nginx | `nginx:1.27-alpine` | 32 МБ |
| frontend | `ghcr.io/scribo-blog-org/frontend:latest` | 280 МБ |
| backend | `ghcr.io/scribo-blog-org/backend:latest` | 280 МБ |
| socket | `ghcr.io/scribo-blog-org/socket:latest` | 128 МБ |
| redis | `redis:7-alpine` | 160 МБ, из них 128 МБ на данные |

У всех сервисов `restart: unless-stopped`. После перезагрузки VM Docker поднимает контейнеры сам. `docker` и `cron` должны быть `enabled` в systemd.

Nginx резолвит имена контейнеров через Docker DNS `127.0.0.11`. В `proxy_pass` адрес задан переменной, поэтому пересоздание одного контейнера не оставляет nginx на старом IP.

Сокет не получает `JWT_PRIVATE_KEY` и `JWT_REFRESH_KEY`. У backend и socket разные env-файлы. Оба ходят в Redis по `redis://redis:6379`.

## Публичные адреса

Файлы `env/*.env` на сервере не коммитятся. Фронт читает `NEXT_PUBLIC_*` при старте контейнера и отдаёт их в страницу как `window.__SCRIBO_ENV`. В образ они не зашиваются. После правки env контейнер нужно пересоздать: обычный restart подхватит файл только если контейнер создаётся заново.

| Файл | Переменная | Значение |
| --- | --- | --- |
| `env/backend.env` | `FRONTEND_ORIGIN` | `https://scribo-blog.duckdns.org` |
| `env/backend.env` | `API_ORIGIN` | `https://scribo-blog.duckdns.org` |
| `env/frontend.env` | `NEXT_PUBLIC_APP_API_URL` | `https://scribo-blog.duckdns.org` |
| `env/frontend.env` | `NEXT_PUBLIC_APP_VERCEL_PROJECT_PRODUCTION_URL` | `scribo-blog.duckdns.org` |
| `env/frontend.env` | `NEXT_PUBLIC_SOCKET_URL` | `wss://scribo-blog.duckdns.org/ws` |
| `env/frontend.env` | `NEXT_PUBLIC_GOOGLE_CLIENT_ID` | id веб-клиента Google |

`FRONTEND_ORIGIN` — разрешённый CORS origin и базовый адрес ссылок в письмах. Без завершающего слэша.

В Google Cloud Console у этого client id в Authorized JavaScript origins должен быть `https://scribo-blog.duckdns.org`.

## Образы: сборка и выкладка

Пуш в `master` репозитория `frontend`, `backend` или `socket` запускает GitHub Actions. Actions собирает образ и пушит в ghcr.io два тега: `latest` и короткий sha коммита.

| Репозиторий | Образ |
| --- | --- |
| `frontend` | `ghcr.io/scribo-blog-org/frontend` |
| `backend` | `ghcr.io/scribo-blog-org/backend` |
| `socket` | `ghcr.io/scribo-blog-org/socket` |

Автоматический заход на сервер по SSH сейчас выключен: секрет `SSH_PRIVATE_KEY` в Actions пустой, шаг Deploy via SSH пропускается. Образ в реестре появляется, на VM сам не встаёт.

После успешного Actions на сервере:

```bash
cd /opt/scribo
docker compose pull frontend
docker compose up -d --no-deps frontend
```

Имя сервиса то же, что в compose: `frontend`, `backend` или `socket`. `--no-deps` не перезапускает соседей. Nginx из-за переменной в `proxy_pass` подхватывает новый IP контейнера без своего рестарта.

Сборки на VM нет. `docker compose build` здесь не используется.

## Сертификат

Let's Encrypt, webroot. Сертификат лежит на хосте в `/opt/scribo/certs` и смонтирован в nginx как `/etc/letsencrypt` только для чтения. Проверка владения доменом: nginx отдаёт `/opt/scribo/certbot-www` по `/.well-known/acme-challenge/` и по HTTP, и этот путь не редиректится на HTTPS.

Контакт сертификата: `scribo.blog.dev@gmail.com`. Файлы: `/opt/scribo/certs/live/scribo-blog.duckdns.org/`.

Продление один раз прописано в crontab пользователя `scribo`. Каждый день в 03:00 certbot проверяет срок. Продлевает, когда до конца меньше месяца, и тогда перезапускает nginx. Сертификат живёт 90 дней. Задание переживает перезагрузку машины.

```bash
crontab -l
```

Строка должна начинаться с `0 3 * * * docker run`.

Пока сертификата нет, nginx с блоком `listen 443 ssl` не стартует: файлов ключа ещё нет. Сначала конфиг только на порту 80 с location для ACME, потом `certbot certonly`, потом текущий `nginx.conf`.

## Что переживёт перезагрузку

- сертификат и `nginx.conf` — файлы на диске;
- контейнеры — политика `unless-stopped` и включённый Docker;
- продление — crontab, cron запускается без логина на сервер.

Проверка автозагрузки:

```bash
systemctl is-enabled docker cron
```

Ожидается `enabled` в обеих строках.

## Обычные команды

```bash
cd /opt/scribo
docker compose ps
docker compose logs --tail 50 nginx
curl -fsSI https://scribo-blog.duckdns.org/health
```

Пересоздать один сервис после правки его env:

```bash
docker compose up -d --force-recreate --no-deps frontend
```

Проверка конфига nginx до рестарта:

```bash
docker compose exec nginx nginx -t && docker compose restart nginx
```
