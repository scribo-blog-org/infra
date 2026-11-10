#!/bin/sh
set -eu

template=/etc/nginx/stack.conf.template
out=/etc/nginx/conf.d

# Body allowance on top of the media limit for the text fields and multipart framing.
overhead_mb=2

rm -f "$out"/default.conf

for entry in ${STACKS}; do
    STACK=${entry%%:*}
    DOMAIN=${entry#*:}

    if [ "$STACK" = "$entry" ] || [ -z "$DOMAIN" ]; then
        echo "10-render-stacks.sh: entry '$entry' is not in the <stack>:<domain> format" >&2
        exit 1
    fi

    media_mb=${POST_MEDIA_MAX_MB:-100}

    case "$media_mb" in
        '' | *[!0-9.]* | *.*.* | . | 0 | 0.* )
            echo "10-render-stacks.sh: POST_MEDIA_MAX_MB for '$STACK' must be a positive number, got '$media_mb'" >&2
            exit 1
            ;;
    esac

    # Round up to whole MB (nginx takes integer sizes in m) and add the overhead.
    POST_BODY_MAX_MB=$(awk -v m="$media_mb" -v o="$overhead_mb" 'BEGIN { c = int(m); if (c < m) c++; print c + o }')

    export STACK DOMAIN POST_BODY_MAX_MB
    envsubst '${STACK} ${DOMAIN} ${POST_BODY_MAX_MB}' < "$template" > "$out/$STACK.conf"
    echo "10-render-stacks.sh: $STACK -> $DOMAIN (posts body limit ${POST_BODY_MAX_MB}m)"
done
