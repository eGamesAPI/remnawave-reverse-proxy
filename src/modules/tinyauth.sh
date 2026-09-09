#!/bin/bash
# Module: TinyAuth login portal for the panel (nginx flows)
# https://docs.rw/security/tinyauth-for-nginx
#
# Usage from an install flow:
#   1. tinyauth_setup <base_domain> [forbidden domains...] — after the
#      superadmin credentials exist; asks for the portal name, checks/creates
#      the DNS record and sets TINYAUTH_* globals. Downgrades PANEL_AUTH_MODE
#      to cookie when the user hash cannot be created.
#   2. tinyauth_compose_service <dir> — append the service to a compose file.
#   3. tinyauth_nginx_sites <listener> <panel_domain> <panel_cert> \
#        <tinyauth_cert> <backend_upstream> >> nginx.conf
#   4. tinyauth_banner — portal credentials for the final banner.

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

    ensure_dns_record "$TINYAUTH_DOMAIN" || true

    TINYAUTH_USER="$SUPERADMIN_USERNAME"
    TINYAUTH_PASSWORD=$(generate_password)
    TINYAUTH_SECRET=$(openssl rand -base64 32 | tr -dc 'a-zA-Z0-9' | head -c 32)

    # bcrypt hash straight from the upstream CLI. The CLI reports the
    # result as a colored structured log line ("... User created ...
    # user=NAME:$2a$.."), so ANSI colors are stripped first, the pair is
    # pulled out of the combined output and the dollars are escaped for
    # docker compose here.
    local tinyauth_image="ghcr.io/maposia/remnawave-tinyauth:latest"
    local run_out hash_out
    run_out=$(docker run --rm "$tinyauth_image" user create \
        --username "$TINYAUTH_USER" --password "$TINYAUTH_PASSWORD" 2>&1 \
        | sed $'s/\x1b\\[[0-9;]*m//g')
    hash_out=$(echo "$run_out" | grep -oE 'user=[^[:space:]]+:\$2[aby]\$[^[:space:]]*' | tail -n 1 | sed 's/^user=//')

    # Only a printable username:hash pair may reach the compose file —
    # a stray control character would break YAML parsing.
    if [ -n "$hash_out" ] && echo "$hash_out" | grep -qE '^[^[:cntrl:][:space:]]+:\$2[aby]\$[^[:cntrl:][:space:]]+$'; then
        # plain bcrypt → docker compose escaped form
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
    image: ghcr.io/maposia/remnawave-tinyauth:latest
    container_name: tinyauth
    hostname: tinyauth
    restart: always
    ports:
      - '127.0.0.1:3002:3002'
    environment:
      - PORT=3002
      - APP_URL=https://$TINYAUTH_DOMAIN
      - USERS=$TINYAUTH_USERS
      - SECRET=$TINYAUTH_SECRET
    volumes:
      - ./data:/data
EOL
}

# Emit the upstream, the portal site and the protected panel site.
# The listener argument differs between flows: "443 ssl" for a plain TCP
# install or "unix:/dev/shm/nginx.sock ssl proxy_protocol" behind Xray.
tinyauth_nginx_sites() {
    local listener="$1"
    local panel_domain="$2"
    local panel_cert="$3"
    local tinyauth_cert="$4"
    local backend="$5"

    cat <<EOL

upstream tinyauth {
    server 127.0.0.1:3002;
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
        proxy_set_header x-forwarded-proto \$scheme;
        proxy_set_header x-forwarded-host \$http_host;
        proxy_set_header x-forwarded-uri \$request_uri;
    }

    location @tinyauth_login {
        return 302 https://$TINYAUTH_DOMAIN/login?redirect_uri=\$scheme://\$http_host\$request_uri;
    }

    location / {
        auth_request /tinyauth_check;
        error_page 401 = @tinyauth_login;

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
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOL
}

tinyauth_banner() {
    echo -e "${COLOR_YELLOW}${LANG[PORTAL_ACCESS]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}https://${TINYAUTH_DOMAIN}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PORTAL_CREDS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[USERNAME]} ${COLOR_WHITE}$TINYAUTH_USER${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PASSWORD]} ${COLOR_WHITE}$TINYAUTH_PASSWORD${COLOR_RESET}"
}
