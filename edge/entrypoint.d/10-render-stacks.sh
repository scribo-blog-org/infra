#!/bin/sh
set -eu

template=/etc/nginx/stack.conf.template
out=/etc/nginx/conf.d

rm -f "$out"/default.conf

for entry in ${STACKS}; do
    STACK=${entry%%:*}
    DOMAIN=${entry#*:}

    if [ "$STACK" = "$entry" ] || [ -z "$DOMAIN" ]; then
        echo "10-render-stacks.sh: entry '$entry' is not in the <stack>:<domain> format" >&2
        exit 1
    fi

    export STACK DOMAIN
    envsubst '${STACK} ${DOMAIN}' < "$template" > "$out/$STACK.conf"
    echo "10-render-stacks.sh: $STACK -> $DOMAIN"
done
