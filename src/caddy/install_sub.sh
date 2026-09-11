#!/bin/bash
# Module: Install Subscription Page Only (Caddy)

install_sub_caddy() {
    mkdir -p /opt/subscription && cd /opt/subscription

    reading "${LANG[ENTER_SUB_DOMAIN]}" SUB_DOMAIN
    check_domain "$SUB_DOMAIN" true true
    local sub_check_result=$?
    if [ $sub_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    # The panel lives on another server, so its domain cannot be
    # validated against this server's IP — only checked for emptiness.
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

    # The panel is protected either by the cookie gate or by a TinyAuth
    # login page — ask which one and collect the matching pass-through
    # data the sub page will send with every panel request.
    local SUB_AUTH_ENV=""
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
                    reading "${LANG[ENTER_SUB_TINYAUTH_KEY]}" SUB_TINYAUTH_KEY
                    if [[ "$SUB_TINYAUTH_KEY" =~ ^Basic\ [A-Za-z0-9+/=]+$ ]]; then
                        break
                    fi
                    echo -e "${COLOR_RED}${LANG[INVALID_TINYAUTH_KEY]}${COLOR_RESET}"
                done
                SUB_AUTH_ENV=$(printf '\n      - CADDY_AUTH_API_TOKEN=%s' "$SUB_TINYAUTH_KEY")
                break
                ;;
            3)
                # API key issued by the caddy-security portal itself — a
                # single opaque token, so only "non-empty, no spaces" here.
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
  remnawave-caddy:
      image: caddy:2.11.4
      container_name: remnawave-caddy
      hostname: remnawave-caddy
      <<: [*common, *logging]
      network_mode: host
      volumes:
          - ./Caddyfile:/etc/caddy/Caddyfile
          - caddy_data:/data
      environment:
          - SUB_DOMAIN=${SUB_DOMAIN}
          - SUB_BACKEND_URL=127.0.0.1:3010
EOL
}

installation_sub_caddy() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_SUB]}${COLOR_RESET}"
    sleep 1

    install_sub_caddy

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

volumes:
  caddy_data:
    name: caddy_data
    driver: local
    external: false
EOL

    cat > /opt/subscription/Caddyfile <<EOL
{
    admin off
}

https://{\$SUB_DOMAIN} {
    encode
    handle {
        reverse_proxy {\$SUB_BACKEND_URL} {
            header_up X-Real-IP {remote}
            header_up Host {host}
        }
    }
}

:80 {
    bind 0.0.0.0
    respond 204
}
EOL

    ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
    ufw reload > /dev/null 2>&1

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
