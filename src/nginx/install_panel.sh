#!/bin/bash
# Module: Install Panel Only

install_panel_nginx() {
    mkdir -p /opt/remnawave && cd /opt/remnawave

    reading "${LANG[ENTER_PANEL_DOMAIN]}" PANEL_DOMAIN
    check_domain "$PANEL_DOMAIN" true true
    local panel_check_result=$?
    if [ $panel_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    if [ "$PANEL_WITH_SUB" != "false" ]; then
        reading "${LANG[ENTER_SUB_DOMAIN]}" SUB_DOMAIN
        check_domain "$SUB_DOMAIN" true true
        local sub_check_result=$?
        if [ $sub_check_result -eq 2 ]; then
            echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
            exit 1
        fi
    fi

    reading "${LANG[ENTER_NODE_DOMAIN]}" SELFSTEAL_DOMAIN

    if [ "$PANEL_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[DOMAINS_MUST_BE_UNIQUE]}${COLOR_RESET}"
        exit 1
    fi
    if [ "$PANEL_WITH_SUB" != "false" ] && { [ "$PANEL_DOMAIN" = "$SUB_DOMAIN" ] || [ "$SUB_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; }; then
        echo -e "${COLOR_RED}${LANG[DOMAINS_MUST_BE_UNIQUE]}${COLOR_RESET}"
        exit 1
    fi

    PANEL_BASE_DOMAIN=$(extract_domain "$PANEL_DOMAIN")

    unique_domains["$PANEL_BASE_DOMAIN"]=1
    if [ "$PANEL_WITH_SUB" != "false" ]; then
        SUB_BASE_DOMAIN=$(extract_domain "$SUB_DOMAIN")
        unique_domains["$SUB_BASE_DOMAIN"]=1
    fi

    PANEL_AUTH_MODE=cookie
    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[PANEL_AUTH_PROMPT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[PANEL_AUTH_OPT_COOKIE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[PANEL_AUTH_OPT_TINYAUTH]}${COLOR_RESET}"
        echo -e ""
        reading "${LANG[PANEL_AUTH_PROMPT_CHOOSE]}" auth_choice
        case "$auth_choice" in
            1) break ;;
            2) PANEL_AUTH_MODE=tinyauth; break ;;
            *) echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}" ;;
        esac
    done

    SUPERADMIN_USERNAME=$(generate_user)
    SUPERADMIN_PASSWORD=$(generate_password)

    cookies_random1=$(generate_user)
    cookies_random2=$(generate_user)

    METRICS_USER=$(generate_user)
    METRICS_PASS=$(generate_user)

    APP_SECRET=$(openssl rand -hex 64)

    if [ "$PANEL_AUTH_MODE" = "tinyauth" ]; then
        load_tinyauth_module
        tinyauth_setup "$PANEL_BASE_DOMAIN" "$PANEL_DOMAIN" "$SUB_DOMAIN" "$SELFSTEAL_DOMAIN"
    fi

    cat > .env <<EOL
### APP ###
APP_PORT=3000
METRICS_PORT=3001

### API ###
# Possible values: max (start instances on all cores), number (start instances on number of cores), -1 (start instances on all cores - 1)
# !!! Do not set this value more than physical cores count in your machine !!!
# Review documentation: https://remna.st/docs/install/environment-variables#scaling-api
API_INSTANCES=1

### DATABASE ###
# FORMAT: postgresql://{user}:{password}@{host}:{port}/{database}
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### REDIS ###
REDIS_SOCKET=/var/run/valkey/valkey.sock
# Alternative to REDIS_SOCKET
#REDIS_HOST=
#REDIS_PORT=

### SECRETS ###
### The single signing key of the panel: admin sessions, API tokens and the
### password pepper. Replacing it locks every admin out of the panel.
APP_SECRET=$APP_SECRET

# Set the session idle timeout in the panel to avoid daily logins.
# Value in hours: 12–168
JWT_AUTH_LIFETIME=168

### TELEGRAM NOTIFICATIONS ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
# is optional, only if you want to use proxy
# FORMAT: protocol://user:password@host:port, example: socks5://proxy:1080
# TELEGRAM_BOT_PROXY=change_me

### TELEGRAM CHAT IDs in format: "chat_id:thread_id"
# thread_id is optional, only if you want to use topics
# example: "-100123:80" - -100123 is chat_id, 80 is thread_id
# example: "-100123" - -100123 is chat_id, thread_id is not used
TELEGRAM_NOTIFY_USERS=change_me
TELEGRAM_NOTIFY_NODES=change_me
TELEGRAM_NOTIFY_CRM=change_me
TELEGRAM_NOTIFY_SERVICE=change_me
TELEGRAM_NOTIFY_TBLOCKER=change_me

### PANEL DOMAIN ###
### Used to build panel links in Telegram notifications.
PANEL_DOMAIN=$PANEL_DOMAIN

### FRONT_END ###
# Used by CORS, you can leave it as * or place your domain there
FRONT_END_DOMAIN=$PANEL_DOMAIN

### SUBSCRIPTION PUBLIC DOMAIN ###
### DOMAIN, WITHOUT HTTP/HTTPS, DO NOT ADD / AT THE END ###
### Used in "profile-web-page-url" response header and in UI/API ###
### Review documentation: https://remna.st/docs/install/environment-variables#domains
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN

### If CUSTOM_SUB_PREFIX is set in @remnawave/subscription-page, append the same path to SUB_PUBLIC_DOMAIN. Example: SUB_PUBLIC_DOMAIN=sub-page.example.com/sub ###

### PROMETHEUS ###
### Metrics are available at http://127.0.0.1:METRICS_PORT/metrics
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS

### Webhook configuration
### Enable webhook notifications (true/false, defaults to false if not set or empty)
WEBHOOK_ENABLED=false
### Webhook URL to send notifications to (can specify multiple URLs separated by commas if needed)
### Only http:// or https:// are allowed.
WEBHOOK_URL=https://your-webhook-url.com/endpoint
### This secret is used to sign the webhook payload, must be exact 64 characters. Only a-z, 0-9, A-Z are allowed.
WEBHOOK_SECRET_HEADER=vsmu67Kmg6R8FjIOF1WUY8LWBHie4scdEqrfsKmyf4IAf8dY3nFS0wwYHkhh6ZvQ

### Bandwidth usage reached notifications
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
# Only in ASC order (example: [60, 80]), must be valid array of integer(min: 25, max: 95) numbers. No more than 5 values.
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]

### Not connected users notification (webhook, telegram)
NOT_CONNECTED_USERS_NOTIFICATIONS_ENABLED=false
# Only in ASC order (example: [6, 12, 24]), must be valid array of integer(min: 1, max: 168) numbers. No more than 3 values.
# Each value represents HOURS passed after user creation (user.createdAt)
NOT_CONNECTED_USERS_NOTIFICATIONS_AFTER_HOURS=[6, 24, 48]

### Database ###
### For Postgres Docker container ###
# NOT USED BY THE APP ITSELF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOL

    cat > docker-compose.yml <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-networks: &networks
  networks:
    - remnawave-network

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

x-env: &env
  env_file: .env

services:
  remnawave-db:
    image: postgres:18.6
    container_name: 'remnawave-db'
    hostname: remnawave-db
    shm_size: 512mb
    <<: [*common, *logging, *env, *networks]
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3

  remnawave:
    image: remnawave/backend:3
    container_name: remnawave
    hostname: remnawave
    <<: [*common, *logging, *env, *networks]
    volumes:
      - valkey-socket:/var/run/valkey
    ports:
      - '127.0.0.1:3000:\${APP_PORT:-3000}'
      - '127.0.0.1:3001:\${METRICS_PORT:-3001}'
    healthcheck:
      test: ['CMD-SHELL', 'curl -f http://localhost:\${METRICS_PORT:-3001}/health']
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 30s
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy

  remnawave-redis:
    image: valkey/valkey:9.1.2-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    <<: [*common, *logging, *networks]
    volumes:
      - valkey-socket:/var/run/valkey
    command: >
      valkey-server
      --save ""
      --appendonly no
      --maxmemory-policy noeviction
      --loglevel warning
      --unixsocket /var/run/valkey/valkey.sock
      --unixsocketperm 777
      --port 0
    healthcheck:
      test: ['CMD', 'valkey-cli', '-s', '/var/run/valkey/valkey.sock', 'ping']
      interval: 3s
      timeout: 10s
      retries: 3

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

installation_panel() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_PANEL]}${COLOR_RESET}"
    sleep 1

    declare -A unique_domains
    install_panel_nginx

    declare -A domains_to_check
    domains_to_check["$PANEL_DOMAIN"]=1
    if [ "$PANEL_WITH_SUB" != "false" ]; then
        domains_to_check["$SUB_DOMAIN"]=1
    fi
    if [ "$PANEL_AUTH_MODE" = "tinyauth" ]; then
        domains_to_check["$TINYAUTH_DOMAIN"]=1
    fi

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL"

    if [ -z "$CERT_METHOD" ]; then
        local base_domain=$(extract_domain "$PANEL_DOMAIN")
        if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
            CERT_METHOD="1"
        else
            CERT_METHOD="2"
        fi
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        PANEL_CERT_DOMAIN="$(extract_domain "$PANEL_DOMAIN")"
        if [ "$PANEL_WITH_SUB" != "false" ]; then
            SUB_CERT_DOMAIN="$(extract_domain "$SUB_DOMAIN")"
        fi
        if [ "$PANEL_AUTH_MODE" = "tinyauth" ]; then
            TINYAUTH_CERT_DOMAIN="$(extract_domain "$TINYAUTH_DOMAIN")"
        fi
    else
        PANEL_CERT_DOMAIN="$PANEL_DOMAIN"
        if [ "$PANEL_WITH_SUB" != "false" ]; then
            SUB_CERT_DOMAIN="$SUB_DOMAIN"
        fi
        if [ "$PANEL_AUTH_MODE" = "tinyauth" ]; then
            TINYAUTH_CERT_DOMAIN="$TINYAUTH_DOMAIN"
        fi
    fi

    if [ "$PANEL_WITH_SUB" != "false" ]; then
        cat >> /opt/remnawave/docker-compose.yml <<EOL

  remnawave-subscription-page:
    image: remnawave/subscription-page:8.0.0
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    <<: [*common, *logging, *networks]
    depends_on:
      remnawave:
        condition: service_healthy
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - REMNAWAVE_API_TOKEN=\$api_token
    ports:
      - '127.0.0.1:3010:3010'
EOL
    fi

    if [ "$PANEL_AUTH_MODE" = "tinyauth" ]; then
        tinyauth_compose_service /opt/remnawave "$PANEL_DOMAIN"
    fi

    cat >> /opt/remnawave/docker-compose.yml <<EOL

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    external: false
    name: remnawave-db-data
  valkey-socket:
    name: valkey-socket
    driver: local
    external: false
EOL

    cat > /opt/remnawave/nginx.conf <<EOL
server_names_hash_bucket_size 64;

# Gzip Compression
# Remnawave 3.x does not compress response bodies itself, so the reverse proxy
# has to. https://f.docs.rw/t/topic/354/3
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

upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
EOL

    if [ "$PANEL_AUTH_MODE" = "tinyauth" ]; then
        tinyauth_nginx_sites "443 ssl" "$PANEL_DOMAIN" "$PANEL_CERT_DOMAIN" "$TINYAUTH_CERT_DOMAIN" "remnawave" >> /opt/remnawave/nginx.conf
    else
        cat >> /opt/remnawave/nginx.conf <<EOL

map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

server {
    server_name $PANEL_DOMAIN;
    listen 443 ssl;
    http2 on;
    gzip on;

    ssl_certificate "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/fullchain.pem";

    add_header Set-Cookie \$set_cookie_header;

    location / {
        if (\$authorized = 0) {
            return 444;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
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
    
    # OAuth2 Telegram login
    location ^~ /oauth2/ {
        
        if (\$http_referer !~ "^https://oauth\.telegram\.org/") {
            return 444;
        }
        
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
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
    fi

    if [ "$PANEL_WITH_SUB" != "false" ]; then
        cat >> /opt/remnawave/nginx.conf <<EOL

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
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 444;
    }
}
EOL
    fi

    cat >> /opt/remnawave/nginx.conf <<EOL

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL

    echo -e "${COLOR_YELLOW}${LANG[STARTING_PANEL]}${COLOR_RESET}"
    sleep 1
    cd /opt/remnawave
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    local domain_url="127.0.0.1:3000"
    local target_dir="/opt/remnawave"

    sleep 20

    step_do "${LANG[CHECK_CONTAINERS]}"
    local attempts=0
    local max_attempts=5
    until curl -s -f --max-time 30 "http://$domain_url/api/auth/status" \
        --header 'X-Forwarded-For: 127.0.0.1' \
        --header 'X-Forwarded-Proto: https' \
        > /dev/null; do
        attempts=$((attempts + 1))
        if [ "$attempts" -ge "$max_attempts" ]; then
            error "$(printf "${LANG[CONTAINERS_TIMEOUT]}" $max_attempts)"
        fi
        echo -e "${COLOR_RED}$(printf "${LANG[CONTAINERS_NOT_READY_ATTEMPT]}" $attempts $max_attempts)${COLOR_RESET}"
        sleep 60
    done

    # Register Remnawave
    local token=$(register_remnawave "$domain_url" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD")
    case "$token" in
        ey*) ;;
        *) abort_with_credentials "${LANG[ERROR_REGISTER]}: $token" ;;
    esac

    # Generate Xray keys
    sleep 1
    local private_key=$(generate_xray_keys "$domain_url" "$token")

    # Delete default config profile
    delete_config_profile "$domain_url" "$token"

    # Create config profile
    read config_profile_uuid inbound_uuid <<< $(create_config_profile "$domain_url" "$token" "StealConfig" "$SELFSTEAL_DOMAIN" "$private_key")

    # Create node with config profile binding
    create_node "$domain_url" "$token" "$config_profile_uuid" "$inbound_uuid" "$SELFSTEAL_DOMAIN"

    # Create host
    create_host "$domain_url" "$token" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$config_profile_uuid"

    # Get UUID default squad
    local squad_uuid=$(get_default_squad "$domain_url" "$token")

    # Update squad
    update_squad "$domain_url" "$token" "$squad_uuid" "$inbound_uuid"

    if [ "$PANEL_WITH_SUB" != "false" ]; then
        # Create API token for subscription page
        create_api_token "$domain_url" "$token" "$target_dir"

        # Stop and start Remnawave Subscription Page
        step_do "${LANG[STOPPING_REMNAWAVE_SUBSCRIPTION_PAGE]}"
        sleep 1
        docker compose down remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        step_do "${LANG[STARTING_REMNAWAVE_SUBSCRIPTION_PAGE]}"
        sleep 1
        docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
    fi

    clear

    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${LANG[INSTALL_COMPLETE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    if [ "$PANEL_AUTH_MODE" = "tinyauth" ]; then
        tinyauth_banner
        echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[ADMIN_CREDS]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[PANEL_ACCESS]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}https://${PANEL_DOMAIN}/auth/login?${cookies_random1}=${cookies_random2}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[ADMIN_CREDS]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_YELLOW}${LANG[USERNAME]} ${COLOR_WHITE}$SUPERADMIN_USERNAME${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PASSWORD]} ${COLOR_WHITE}$SUPERADMIN_PASSWORD${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_RESET}"
    echo -e "${COLOR_GREEN}remnawave_reverse${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_RED}${LANG[POST_PANEL_INSTRUCTION]}${COLOR_RESET}"
}
