#!/bin/sh
# Первичная настройка чистой Oracle Cloud VM (Ubuntu, ARM/aarch64).
# Запускать от root: sudo sh scripts/vm-setup.sh
#
# Делает: docker с плагином compose, пользователей scribo и github-actions-deploy,
# каталоги /srv/scribo, правила iptables для 80 и 443, крон продления сертификата.
# Повторный запуск безопасен.
#
# Что остаётся руками после скрипта:
#   - публичный ключ в /home/scribo/.ssh/authorized_keys
#   - публичный ключ деплоя в /home/github-actions-deploy/.ssh/authorized_keys
#   - секреты в /srv/scribo/{prod,stage}/env/ и stack.env по образцам из env/
#   - ./scribo certs, затем ./scribo up prod stage edge
set -eu

[ "$(id -u)" = 0 ] || {
    echo "vm-setup.sh: нужен root" >&2
    exit 1
}

ROOT=/srv/scribo
REPO_URL=https://github.com/scribo-blog-org/infra.git
ADMIN_USER=scribo
DEPLOY_USER=github-actions-deploy

say() {
    echo
    echo "== $1"
}

say "Пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq ca-certificates curl git rsync iptables-persistent

say "Docker"
if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
        "$(dpkg --print-architecture)" \
        "$(. /etc/os-release && echo "$VERSION_CODENAME")" \
        >/etc/apt/sources.list.d/docker.list
    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
        docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker
docker --version
docker compose version

say "Пользователи"
# Админ: sudo и docker. Деплой-юзер: только docker, без sudo.
for user in "$ADMIN_USER" "$DEPLOY_USER"; do
    if ! id -u "$user" >/dev/null 2>&1; then
        adduser --disabled-password --gecos "" "$user"
    fi
    install -d -m 700 -o "$user" -g "$user" "/home/$user/.ssh"
    touch "/home/$user/.ssh/authorized_keys"
    chown "$user:$user" "/home/$user/.ssh/authorized_keys"
    chmod 600 "/home/$user/.ssh/authorized_keys"
    usermod -aG docker "$user"
done
usermod -aG sudo "$ADMIN_USER"

say "Каталоги $ROOT"
# Группа docker и setgid: и админ, и деплой-юзер пишут в одни каталоги, а новые
# файлы наследуют группу. Без этого деплою пришлось бы чинить права каждый раз.
install -d -m 2775 -o "$ADMIN_USER" -g docker "$ROOT"
for dir in prod stage edge; do
    install -d -m 2775 -o "$ADMIN_USER" -g docker "$ROOT/$dir"
done
# Секреты: группа читает, остальные нет.
for dir in prod stage; do
    install -d -m 2750 -o "$ADMIN_USER" -g docker "$ROOT/$dir/env"
done
# Загрузки и бекапы монтируются в backend как папки хоста. Пишет туда процесс
# внутри контейнера, пользователь node с uid 1000, поэтому владелец числовой,
# а не scribo. Загрузки читает nginx из edge, ему нужно 755. Архивы бекапов
# содержат всю базу, поэтому 700: прочитать их с хоста можно только через sudo
# или скачав из админки.
NODE_UID=1000
for dir in prod stage; do
    install -d -m 755 -o "$NODE_UID" -g "$NODE_UID" "$ROOT/$dir/uploads"
    install -d -m 700 -o "$NODE_UID" -g "$NODE_UID" "$ROOT/$dir/backups"
done
# Данные Mongo (нужны окружениям с COMPOSE_PROFILES=mongo). Пишет процесс mongod
# внутри контейнера, пользователь mongodb с uid 999, поэтому владелец числовой.
# Папку читать с хоста нельзя никому, кроме root: в ней вся база.
MONGO_UID=999
for dir in prod stage; do
    install -d -m 700 -o "$MONGO_UID" -g "$MONGO_UID" "$ROOT/$dir/mongo"
done
install -d -m 2775 -o "$ADMIN_USER" -g docker "$ROOT/edge/certs" "$ROOT/edge/certbot-www"

say "Репозиторий"
if [ ! -d "$ROOT/infra/.git" ]; then
    sudo -u "$ADMIN_USER" git clone --quiet "$REPO_URL" "$ROOT/infra"
fi
# В репозиторий пишут два пользователя: админ руками и деплой из Actions.
# sharedRepository заставляет git создавать файлы с правом записи для группы,
# а safe.directory снимает отказ git работать в каталоге чужого владельца.
git -C "$ROOT/infra" config core.sharedRepository group
chgrp -R docker "$ROOT/infra"
chmod -R g+rwX "$ROOT/infra"
for user in "$ADMIN_USER" "$DEPLOY_USER"; do
    sudo -u "$user" git config --global --add safe.directory "$ROOT/infra"
done
git -C "$ROOT/infra" log --oneline -1

say "Порты 80 и 443"
# В образах Oracle в цепочке INPUT уже есть REJECT, и правило, добавленное
# через -A, окажется после него и не сработает. Вставляем перед REJECT.
allow_port() {
    port=$1
    if iptables -C INPUT -p tcp --dport "$port" -j ACCEPT 2>/dev/null; then
        return
    fi
    line=$(iptables -L INPUT --line-numbers -n | awk '$2 == "REJECT" { print $1; exit }')
    if [ -n "$line" ]; then
        iptables -I INPUT "$line" -p tcp --dport "$port" -j ACCEPT
    else
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
    fi
}
allow_port 80
allow_port 443
netfilter-persistent save
iptables -L INPUT -n | grep -E 'dpt:(80|443)' || true

say "Крон"
add_cron() {
    marker=$1
    line=$2
    if ! crontab -u "$ADMIN_USER" -l 2>/dev/null | grep -qF "$marker"; then
        {
            crontab -u "$ADMIN_USER" -l 2>/dev/null || true
            echo "$line"
        } | crontab -u "$ADMIN_USER" -
    fi
}
add_cron "scribo renew" "0 3 * * * $ROOT/infra/scribo renew"
crontab -u "$ADMIN_USER" -l

say "Готово"
cat <<TEXT
Осталось:
  1. Ключи в /home/$ADMIN_USER/.ssh/authorized_keys и
     /home/$DEPLOY_USER/.ssh/authorized_keys
  2. Секреты: cp $ROOT/infra/env/*.example и заполнить
       $ROOT/prod/stack.env, $ROOT/prod/env/*.env
       $ROOT/stage/stack.env, $ROOT/stage/env/*.env
       $ROOT/edge/stack.env
       $ROOT/edge/env/status.env
  3. Открыть 80 и 443 в Security List у VCN — iptables на хосте этого не делает
  4. Если окружение на внешней базе (Atlas), добавить исходящий IP этой машины в её IP Access List.
     Окружениям со своим Mongo (COMPOSE_PROFILES=mongo) это не нужно.
  5. cd $ROOT/infra && ./scribo certs && ./scribo up prod && ./scribo up stage && ./scribo up edge
TEXT
