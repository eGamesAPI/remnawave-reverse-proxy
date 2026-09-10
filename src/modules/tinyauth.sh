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

    # bcrypt hash straight from the upstream CLI. Builds print the pair in
    # different shapes (bare "name:hash", inside a log line, or as a ready
    # "--auth.users=name:hash" flag), so the extraction anchors on the known
    # username instead of the line format; ANSI colors are stripped and the
    # dollars are escaped for docker compose.
    local tinyauth_image="ghcr.io/tinyauthapp/tinyauth:latest"
    local run_out hash_out
    run_out=$(docker run --rm "$tinyauth_image" user create \
        --username "$TINYAUTH_USER" --password "$TINYAUTH_PASSWORD" 2>&1 \
        | sed $'s/\x1b\\[[0-9;]*m//g')
    hash_out=$(echo "$run_out" | grep -oE "${TINYAUTH_USER}"':\$2[aby]\$[^[:space:]]+' | head -n 1)

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

# Append the tinyauth service to the compose file in $1.
# TINYAUTH_APPURL is the portal's OWN canonical URL — tinyauth checks
# incoming requests against it (a mismatch shows the "wrong domain"
# warning) and builds login links on it. The redirect target after login
# comes from the X-Forwarded-Host of the nginx auth subrequest, i.e. the
# panel domain — it must NOT go here, or the login link lands on the
# protected site and loops.
# Env names per the v5 guide (remnawave/panel#496): TINYAUTH_APPURL and
# TINYAUTH_SERVER_PORT — no underscores inside APPURL; SECRET is gone,
# sessions live in SQLite under /data.
tinyauth_compose_service() {
    local dir="$1"
    cat >> "$dir/docker-compose.yml" <<EOL

  tinyauth:
    image: ghcr.io/tinyauthapp/tinyauth:latest
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

# Portal credentials for the final banner. The link shown is the PANEL
# domain, not the portal one: opening the panel is what triggers the auth
# redirect with a proper return URL, while the bare portal URL logs in
# with nowhere to return to.
tinyauth_banner() {
    local panel_domain="${1:-$PANEL_DOMAIN}"
    echo -e "${COLOR_YELLOW}${LANG[PORTAL_ACCESS]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}https://${panel_domain}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PORTAL_CREDS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[USERNAME]} ${COLOR_WHITE}$TINYAUTH_USER${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PASSWORD]} ${COLOR_WHITE}$TINYAUTH_PASSWORD${COLOR_RESET}"
}
