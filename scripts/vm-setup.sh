#!/bin/sh
set -eu

[ "$(id -u)" = 0 ] || {
    echo "vm-setup.sh: root is required" >&2
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

say "Packages"
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

say "Users"
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

say "Directories $ROOT"
install -d -m 2775 -o "$ADMIN_USER" -g docker "$ROOT"
for dir in prod stage edge; do
    install -d -m 2775 -o "$ADMIN_USER" -g docker "$ROOT/$dir"
done
for dir in prod stage; do
    install -d -m 2750 -o "$ADMIN_USER" -g docker "$ROOT/$dir/env"
done
NODE_UID=1000
for dir in prod stage; do
    install -d -m 755 -o "$NODE_UID" -g "$NODE_UID" "$ROOT/$dir/uploads"
    install -d -m 700 -o "$NODE_UID" -g "$NODE_UID" "$ROOT/$dir/backups"
done
MONGO_UID=999
for dir in prod stage; do
    install -d -m 700 -o "$MONGO_UID" -g "$MONGO_UID" "$ROOT/$dir/mongo"
done
install -d -m 2775 -o "$ADMIN_USER" -g docker "$ROOT/edge/certs" "$ROOT/edge/certbot-www"

say "Repository"
if [ ! -d "$ROOT/infra/.git" ]; then
    sudo -u "$ADMIN_USER" git clone --quiet "$REPO_URL" "$ROOT/infra"
fi
git -C "$ROOT/infra" config core.sharedRepository group
chgrp -R docker "$ROOT/infra"
chmod -R g+rwX "$ROOT/infra"
for user in "$ADMIN_USER" "$DEPLOY_USER"; do
    sudo -u "$user" git config --global --add safe.directory "$ROOT/infra"
done
git -C "$ROOT/infra" log --oneline -1

say "Ports 80 and 443"
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

say "Cron"
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

say "Done"
cat <<TEXT
Still to do:
  1. Keys in /home/$ADMIN_USER/.ssh/authorized_keys and
     /home/$DEPLOY_USER/.ssh/authorized_keys
  2. Secrets: cp $ROOT/infra/env/*.example and fill in
       $ROOT/prod/stack.env, $ROOT/prod/env/*.env
       $ROOT/stage/stack.env, $ROOT/stage/env/*.env
       $ROOT/edge/stack.env
       $ROOT/edge/env/status.env
  3. Open 80 and 443 in the VCN security list — host iptables does not do that
  4. If an environment uses an external database (Atlas), add this machine's outbound IP to its IP access list.
     Environments with their own Mongo (COMPOSE_PROFILES=mongo) do not need that.
  5. cd $ROOT/infra && ./scribo certs && ./scribo up prod && ./scribo up stage && ./scribo up edge
TEXT
