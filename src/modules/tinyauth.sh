#!/bin/bash
# Module: TinyAuth login portal for the panel (nginx flows)
# https://docs.rw/security/tinyauth-for-nginx

tinyauth_setup() {
    local base_domain="$1"
    shift

    while true; do
        reading "$(printf "${LANG[ENTER_TINYAUTH_NAME]}" "$base_domain")" TINYAUTH_NAME
        if [[ "$TINYAUTH_NAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?$ ]]; then
            break
        fi
        echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
    done

    TINYAUTH_DOMAIN="${TINYAUTH_NAME}.${base_domain}"

    local forbidden
    for forbidden in "$@"; do
        if [ -n "$forbidden" ] && [ "$TINYAUTH_DOMAIN" = "$forbidden" ]; then
            echo -e "${COLOR_RED}${LANG[DOMAINS_MUST_BE_UNIQUE]}${COLOR_RESET}"
            exit 1
        fi
    done

    load_dns_records_module
    ensure_dns_record "$TINYAUTH_DOMAIN" || true

    TINYAUTH_USER="$SUPERADMIN_USERNAME"
    TINYAUTH_PASSWORD=$(generate_password)

    # The remnawave fork image per docs.rw, pinned to the v5 tag — its
    # "latest" was a broken transitional build. The fork adds X-Api-Key
    # auth (tinyauth creds in a separate header, Authorization passes
    # through to the panel), which our nginx config already speaks.
    local tinyauth_image="ghcr.io/maposia/remnawave-tinyauth:v5"
    local run_out hash_out
    run_out=$(docker run --rm "$tinyauth_image" user create \
        --username "$TINYAUTH_USER" --password "$TINYAUTH_PASSWORD" 2>&1 \
        | sed $'s/\x1b\\[[0-9;]*m//g')
    hash_out=$(echo "$run_out" | grep -oE "${TINYAUTH_USER}"':\$2[aby]\$[^[:space:]]+' | head -n 1)

    if [ -n "$hash_out" ] && echo "$hash_out" | grep -qE '^[^[:cntrl:][:space:]]+:\$2[aby]\$[^[:cntrl:][:space:]]+$'; then

        TINYAUTH_USERS=$(echo "$hash_out" | sed 's/\$/\$\$/g')
    else
        echo -e "${COLOR_RED}${LANG[TINYAUTH_CREATE_FAIL]}${COLOR_RESET}"
        echo "$run_out" | tail -n 3 | sed 's/^/'"${COLOR_RED}"'/' | sed 's/$/'"${COLOR_RESET}"'/'
        PANEL_AUTH_MODE=cookie
    fi
}

tinyauth_compose_service() {
    local dir="$1"
    cat >> "$dir/docker-compose.yml" <<EOL

  tinyauth:
    image: ghcr.io/maposia/remnawave-tinyauth:v5
    container_name: tinyauth
    hostname: tinyauth
    restart: always
    ports:
      - '127.0.0.1:3002:3002'
    environment:
      - TINYAUTH_SERVER_PORT=3002
      - TINYAUTH_APPURL=https://$TINYAUTH_DOMAIN
      - TINYAUTH_AUTH_USERS=$TINYAUTH_USERS
      - TINYAUTH_AUTH_SECURECOOKIE=true
      - TINYAUTH_DATABASE_PATH=/data/tinyauth.db
    volumes:
      - ./data:/data
EOL
}

tinyauth_nginx_sites() {
    local listener="$1"
    local panel_domain="$2"
    local panel_cert="$3"
    local tinyauth_cert="$4"
    local backend="$5"

    cat <<EOL

upstream tinyauth {
    server 127.0.0.1:3002;
    keepalive 16;
}

server {
    server_name $TINYAUTH_DOMAIN;
    listen $listener;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$tinyauth_cert/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$tinyauth_cert/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$tinyauth_cert/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://tinyauth;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    server_name $panel_domain;
    listen $listener;
    http2 on;
    gzip on;

    ssl_certificate "/etc/nginx/ssl/$panel_cert/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$panel_cert/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$panel_cert/fullchain.pem";

    # The panel API carries its own Bearer-token auth and Telegram OAuth
    # callbacks must reach the backend untouched — both stay open.
    location /api/ {
        proxy_http_version 1.1;
        proxy_pass http://$backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location /oauth2/ {
        proxy_http_version 1.1;
        proxy_pass http://$backend;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location = /tinyauth_check {
        internal;
        proxy_pass http://tinyauth/api/auth/nginx;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Uri \$request_uri;

        # X-Api-Key authenticates the request in TinyAuth while the original
        # Authorization header remains available to the protected application.
        proxy_set_header X-Api-Key \$http_x_api_key;
        proxy_set_header Authorization \$http_authorization;
    }

    location / {
        auth_request /tinyauth_check;
        auth_request_set \$tinyauth_location \$upstream_http_x_tinyauth_location;
        error_page 401 403 =302 \$tinyauth_location;

        proxy_http_version 1.1;
        proxy_pass http://$backend;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;

        # Preserve credentials intended for the protected application, strip
        # the TinyAuth ones.
        proxy_set_header Authorization \$http_authorization;
        proxy_set_header X-Api-Key "";

        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOL
}

tinyauth_banner() {
    local panel_domain="${1:-$PANEL_DOMAIN}"
    echo -e "${COLOR_YELLOW}${LANG[PORTAL_ACCESS]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}https://${panel_domain}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PORTAL_CREDS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[USERNAME]} ${COLOR_WHITE}$TINYAUTH_USER${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PASSWORD]} ${COLOR_WHITE}$TINYAUTH_PASSWORD${COLOR_RESET}"
}
