#!/bin/bash
# Module: Install Subscription Page Only (nginx)

install_sub_nginx() {
    mkdir -p /opt/subscription && cd /opt/subscription

    reading "${LANG[ENTER_SUB_DOMAIN]}" SUB_DOMAIN
    check_domain "$SUB_DOMAIN" true true
    local sub_check_result=$?
    if [ $sub_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    reading "${LANG[ENTER_PANEL_DOMAIN]}" PANEL_DOMAIN
    if [ -z "$PANEL_DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    reading "${LANG[ENTER_SUB_API_TOKEN]}" SUB_API_TOKEN
    if [ -z "$SUB_API_TOKEN" ]; then
        echo -e "${COLOR_RED}${LANG[EMPTY_TOKEN_ERROR]}${COLOR_RESET}"
        exit 1
    fi

    SUB_AUTH_ENV=""
    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[PANEL_AUTH_PROMPT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[PANEL_AUTH_OPT_COOKIE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[PANEL_AUTH_OPT_TINYAUTH]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[PANEL_AUTH_OPT_CADDY_MFA]}${COLOR_RESET}"
        echo -e ""
        reading "${LANG[SUB_PANEL_AUTH_CHOOSE]}" sub_auth_choice
        case "$sub_auth_choice" in
            1)
                while true; do
                    reading "${LANG[ENTER_SUB_PANEL_COOKIE]}" SUB_EGAMES_COOKIE
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
                    reading "${LANG[ENTER_TINYAUTH_LOGIN]}" SUB_TINYAUTH_LOGIN
                    reading "${LANG[ENTER_TINYAUTH_PASSWORD]}" SUB_TINYAUTH_PASSWORD
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
                    reading "${LANG[ENTER_SUB_CADDY_KEY]}" SUB_CADDY_KEY
                    if [[ -n "$SUB_CADDY_KEY" && ! "$SUB_CADDY_KEY" =~ [[:space:]] ]]; then
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

    cat > docker-compose.yml <<EOL
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
EOL
}

installation_sub() {
    check_sub_not_running
    load_certificates_module
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_SUB]}${COLOR_RESET}"
    sleep 1

    install_sub_nginx

    declare -A domains_to_check
    domains_to_check["$SUB_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL" "/opt/subscription"

    if [ -z "$CERT_METHOD" ]; then
        local base_domain=$(extract_domain "$SUB_DOMAIN")
        if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
            CERT_METHOD="1"
        else
            CERT_METHOD="2"
        fi
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        SUB_CERT_DOMAIN="$(extract_domain "$SUB_DOMAIN")"
    else
        SUB_CERT_DOMAIN="$SUB_DOMAIN"
    fi

    cat >> /opt/subscription/docker-compose.yml <<EOL

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    <<: [*common, *logging]
    environment:
      - REMNAWAVE_PANEL_URL=https://$PANEL_DOMAIN
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=$SUB_API_TOKEN${SUB_AUTH_ENV}
    ports:
      - '127.0.0.1:3010:3010'
EOL

    cat > /opt/subscription/nginx.conf <<EOL
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
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384;
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

    echo -e "${COLOR_YELLOW}${LANG[STARTING_SUB]}${COLOR_RESET}"
    sleep 3
    cd /opt/subscription
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    printf "${COLOR_YELLOW}${LANG[SUB_CHECK]}${COLOR_RESET}\n" "$SUB_DOMAIN"
    local max_attempts=5
    local attempt=1
    local delay=15

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}${LANG[SUB_ATTEMPT]}${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if curl -s -o /dev/null --max-time 10 "https://$SUB_DOMAIN"; then
            step_ok "${LANG[SUB_LAUNCHED]}"
            break
        else
            printf "${COLOR_RED}${LANG[SUB_UNAVAILABLE]}${COLOR_RESET}\n" "$attempt"
            if [ $attempt -eq $max_attempts ]; then
                printf "${COLOR_RED}${LANG[SUB_NOT_CONNECTED]}${COLOR_RESET}\n" "$max_attempts"
                exit 1
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
