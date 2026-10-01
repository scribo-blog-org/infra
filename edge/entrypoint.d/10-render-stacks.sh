#!/bin/sh
# Пишет по одному конфигу на окружение из stack.conf.template.
# Запускается штатным entrypoint образа nginx до старта самого nginx.
#
# STACKS="prod:scribo.pp.ua stage:scribo-stage.pp.ua"
set -eu

template=/etc/nginx/stack.conf.template
out=/etc/nginx/conf.d

# Образ приносит свой default.conf с listen 80 default_server. Он попал бы в
# include рядом с нашими блоками и перехватывал запросы с неизвестным Host.
rm -f "$out"/default.conf

for entry in ${STACKS}; do
    STACK=${entry%%:*}
    DOMAIN=${entry#*:}

    if [ "$STACK" = "$entry" ] || [ -z "$DOMAIN" ]; then
        echo "10-render-stacks.sh: запись '$entry' не в формате <stack>:<domain>" >&2
        exit 1
    fi

    export STACK DOMAIN
    # Список переменных обязателен: без него envsubst подставит пустоту в
    # $host, $remote_addr и $proxy_add_x_forwarded_for.
    envsubst '${STACK} ${DOMAIN}' < "$template" > "$out/$STACK.conf"
    echo "10-render-stacks.sh: $STACK -> $DOMAIN"
done
