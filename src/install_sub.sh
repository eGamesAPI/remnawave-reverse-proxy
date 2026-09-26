#!/bin/bash
# Module: Install Subscription Page Only (nginx)
#
# Structure: collect → render → apply. The render half is pure (stdout
# only, no stdin, no disk). Pre-setting SUB_DOMAIN, PANEL_DOMAIN,
# SUB_API_TOKEN and SUB_AUTH_ENV with SUB_NONINTERACTIVE=1 yields a fully
# non-interactive install for remote drivers; SUB_PANEL_URL overrides the
# panel address (an overlay listener URL instead of https://PANEL_DOMAIN).

# Interactive parameter collection. Aborts return to the caller's menu —
# never exit: this module runs inside the main script's process.
install_sub_collect() {
    if [ "${SUB_NONINTERACTIVE:-0}" = "1" ]; then
        if [ -z "${SUB_DOMAIN:-}" ] || [ -z "${SUB_API_TOKEN:-}" ] \
           || { [ -z "${PANEL_DOMAIN:-}" ] && [ -z "${SUB_PANEL_URL:-}" ]; }; then
            echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
            return 1
        fi
        SUB_AUTH_ENV="${SUB_AUTH_ENV:-}"
        return 0
    fi

    reading "${LANG[ENTER_SUB_DOMAIN]}" SUB_DOMAIN || return 1
    check_domain "$SUB_DOMAIN" true true
    local sub_check_result=$?
    if [ $sub_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        return 1
    fi

    reading "${LANG[ENTER_PANEL_DOMAIN]}" PANEL_DOMAIN || return 1
    if [ -z "$PANEL_DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        return 1
    fi

    reading "${LANG[ENTER_SUB_API_TOKEN]}" SUB_API_TOKEN || return 1
    if [ -z "$SUB_API_TOKEN" ]; then
        echo -e "${COLOR_RED}${LANG[EMPTY_TOKEN_ERROR]}${COLOR_RESET}"
        return 1
    fi

    SUB_AUTH_ENV=""
    local sub_auth_choice
    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[PANEL_AUTH_PROMPT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[PANEL_AUTH_OPT_COOKIE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[PANEL_AUTH_OPT_TINYAUTH]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[PANEL_AUTH_OPT_CADDY_MFA]}${COLOR_RESET}"
        echo -e ""
        reading "${LANG[SUB_PANEL_AUTH_CHOOSE]}" sub_auth_choice || return 1
        case "$sub_auth_choice" in
            1)
                while true; do
                    reading "${LANG[ENTER_SUB_PANEL_COOKIE]}" SUB_EGAMES_COOKIE || return 1
                    if [[ "$SUB_EGAMES_COOKIE" =~ ^[A-Za-z0-9_]+=[A-Za-z0-9_]+$ ]]; then
                        break
                    fi
                    echo -e "${COLOR_RED}${LANG[INVALID_COOKIE_FORMAT]}${COLOR_RESET}"
                done
                SUB_AUTH_ENV=$(printf '\n      - EGAMES_COOKIE=%s' "$SUB_EGAMES_COOKIE")
                break
                ;;
            2)
                while true; do
                    reading "${LANG[ENTER_TINYAUTH_LOGIN]}" SUB_TINYAUTH_LOGIN || return 1
                    reading "${LANG[ENTER_TINYAUTH_PASSWORD]}" SUB_TINYAUTH_PASSWORD || return 1
                    if [ -n "$SUB_TINYAUTH_LOGIN" ] && [ -n "$SUB_TINYAUTH_PASSWORD" ]; then
                        break
                    fi
                    echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
                done
                SUB_AUTH_ENV=$(printf '\n      - CADDY_AUTH_API_TOKEN=Basic %s' "$(printf '%s:%s' "$SUB_TINYAUTH_LOGIN" "$SUB_TINYAUTH_PASSWORD" | base64 | tr -d '\n')")
                break
                ;;
            3)
                while true; do
                    reading "${LANG[ENTER_SUB_CADDY_KEY]}" SUB_CADDY_KEY || return 1
                    if [ -n "$SUB_CADDY_KEY" ] && [[ ! "$SUB_CADDY_KEY" =~ [[:space:]] ]]; then
                        break
                    fi
                    echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
                done
                SUB_AUTH_ENV=$(printf '\n      - CADDY_AUTH_API_TOKEN=%s' "$SUB_CADDY_KEY")
                break
                ;;
            *) echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}" ;;
        esac
    done
}

# Pure renderer: the whole compose, both services in one document.
sub_ng_render_compose() {
    local panel_url="${SUB_PANEL_URL:-https://$PANEL_DOMAIN}"
    cat <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  remnawave-nginx:
    image: nginx:1.30
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    <<: [*common, *logging]
    environment:
      - REMNAWAVE_PANEL_URL=$panel_url
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=$SUB_API_TOKEN${SUB_AUTH_ENV}
    ports:
      - '127.0.0.1:3010:3010'
EOL
}

# Pure renderer: the site config.
sub_ng_render_conf() {
    cat <<EOL
server_names_hash_bucket_size 64;

# Gzip Compression
gzip_vary on;
gzip_proxied any;
gzip_comp_level 6;
gzip_min_length 1024;
gzip_types
    application/javascript
    application/json
    application/manifest+json
    application/xml
    application/wasm
    font/opentype
    font/eot
    font/otf
    font/ttf
    image/svg+xml
    text/css
    text/javascript
    text/plain
    text/xml;

upstream json {
    server 127.0.0.1:3010;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305';
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;

server {
    server_name $SUB_DOMAIN;
    listen 443 ssl;
    http2 on;
    gzip on;

    ssl_certificate "/etc/nginx/ssl/$SUB_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$SUB_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$SUB_CERT_DOMAIN/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
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

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL
}

installation_sub() {
    check_sub_not_running
    check_port_443_free
    load_certificates_module
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_SUB]}${COLOR_RESET}"
    sleep 1

    install_sub_collect || return 1

    declare -A domains_to_check
    domains_to_check["$SUB_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL" "/opt/subscription" || return 1

    # The certificate directory is the lineage that actually covers the
    # domain — a wildcard base or a -0001 renewal suffix, not a guess from
    # the issuance method
    SUB_CERT_DOMAIN=$(resolve_certificate_domain "$SUB_DOMAIN") || return 1

    # Secrets land in both files — root-only from the first byte on.
    mkdir -p /opt/subscription
    umask 077
    sub_ng_render_compose > /opt/subscription/docker-compose.yml
    sub_ng_render_conf > /opt/subscription/nginx.conf
    chmod 600 /opt/subscription/docker-compose.yml /opt/subscription/nginx.conf 2>/dev/null

    echo -e "${COLOR_YELLOW}${LANG[STARTING_SUB]}${COLOR_RESET}"
    sleep 3
    (cd /opt/subscription && docker compose up -d) > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    # https://DOMAIN proves nginx + TLS + DNS (the app itself 502s on / even
    # when healthy); the container list is the app-side proof (B-12).
    printf "${COLOR_YELLOW}${LANG[SUB_CHECK]}${COLOR_RESET}\n" "$SUB_DOMAIN"
    local max_attempts=5
    local attempt=1
    local delay=15

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}${LANG[SUB_ATTEMPT]}${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if curl -s -o /dev/null --max-time 10 "https://$SUB_DOMAIN" \
           && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-subscription-page; then
            step_ok "${LANG[SUB_LAUNCHED]}"
            break
        else
            printf "${COLOR_RED}${LANG[SUB_UNAVAILABLE]}${COLOR_RESET}\n" "$attempt"
            if [ $attempt -eq $max_attempts ]; then
                printf "${COLOR_RED}${LANG[SUB_NOT_CONNECTED]}${COLOR_RESET}\n" "$max_attempts"
                return 1
            fi
            sleep $delay
        fi
        ((attempt++))
    done

    clear

    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${LANG[SUB_INSTALL_COMPLETE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[SUB_ACCESS]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}https://${SUB_DOMAIN}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[SUB_PANEL_REMINDER]}${COLOR_RESET}"
    echo -e "${COLOR_RED}${LANG[SUB_PANEL_GATE_WARNING]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_RESET}"
    echo -e "${COLOR_GREEN}remnawave_reverse${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
}
