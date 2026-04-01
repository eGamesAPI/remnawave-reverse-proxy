#!/bin/bash
# Module: Manage Panel

show_manage_panel_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_3]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[START_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[STOP_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[UPDATE_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[VIEW_LOGS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[REMNAWAVE_CLI]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. ${LANG[ACCESS_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[MANAGE_PANEL_NODE_PROMPT]}" SUB_OPTION

    case $SUB_OPTION in
        1)
            start_panel_node
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        2)
            stop_panel_node
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        3)
            update_panel_node
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        4)
            view_logs
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        5)
            run_remnawave_cli
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        6)
            manage_panel_access
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        0)
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 1
            show_manage_panel_menu
            ;;
    esac
}

run_remnawave_cli() {
    if ! docker ps --format '{{.Names}}' | grep -q '^remnawave$'; then
        echo -e "${COLOR_YELLOW}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        return 1
    fi

    exec 3>&1 4>&2
    exec > /dev/tty 2>&1

    echo -e "${COLOR_YELLOW}${LANG[RUNNING_CLI]}${COLOR_RESET}"
    if docker exec -it -e TERM=xterm-256color remnawave remnawave; then
        echo -e "${COLOR_GREEN}${LANG[CLI_SUCCESS]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CLI_FAILED]}${COLOR_RESET}"
        exec 1>&3 2>&4
        return 1
    fi

    exec 1>&3 2>&4
}

start_panel_node() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    if docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . || docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q . || docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
        echo -e "${COLOR_GREEN}${LANG[PANEL_RUNNING]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[STARTING_PANEL_NODE]}...${COLOR_RESET}"
        sleep 1
        docker compose up -d > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        echo -e "${COLOR_GREEN}${LANG[PANEL_RUN]}${COLOR_RESET}"
    fi
}

stop_panel_node() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }
    if ! docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
        echo -e "${COLOR_GREEN}${LANG[PANEL_STOPPED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[STOPPING_REMNAWAVE]}...${COLOR_RESET}"
        sleep 1
        docker compose down > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        echo -e "${COLOR_GREEN}${LANG[PANEL_STOP]}${COLOR_RESET}"
    fi
}

update_panel_node() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }
    echo -e "${COLOR_YELLOW}${LANG[UPDATING]}${COLOR_RESET}"
    sleep 1

    images_before=$(docker compose config --images | sort -u)
    if [ -n "$images_before" ]; then
        before=$(echo "$images_before" | xargs -I {} docker images -q {} | sort -u)
    else
        before=""
    fi

    tmpfile=$(mktemp)
    docker compose pull > "$tmpfile" 2>&1 &
    spinner $! "${LANG[WAITING]}"
    pull_output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    images_after=$(docker compose config --images | sort -u)
    if [ -n "$images_after" ]; then
        after=$(echo "$images_after" | xargs -I {} docker images -q {} | sort -u)
    else
        after=""
    fi

    if [ "$before" != "$after" ] || echo "$pull_output" | grep -q "Pull complete"; then
        echo -e ""
	echo -e "${COLOR_YELLOW}${LANG[IMAGES_DETECTED]}${COLOR_RESET}"
        docker compose down > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        sleep 5
        docker compose up -d > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        sleep 1
        docker image prune -f > /dev/null 2>&1
        echo -e "${COLOR_GREEN}${LANG[UPDATE_SUCCESS1]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[NO_UPDATE]}${COLOR_RESET}"
    fi
}

view_logs() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    if ! docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
        echo -e "${COLOR_RED}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        exit 1
    fi

    echo -e "${COLOR_YELLOW}${LANG[VIEW_LOGS]}${COLOR_RESET}"
    docker compose logs -f -t
}

#Manage Panel Access
show_panel_access() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_9]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[PORT_8443_OPEN]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[PORT_8443_CLOSE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_panel_access() {
    show_panel_access
    reading "${LANG[IPV6_PROMPT]}" ACCESS_OPTION
    case $ACCESS_OPTION in
        1)
            open_panel_access
            ;;
        2)
            close_panel_access
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            sleep 2
            log_clear
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            ;;
    esac
    sleep 2
    log_clear
    manage_panel_access
}

open_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    local webserver=""
    if [ -f "nginx.conf" ]; then
        webserver="nginx"
    elif [ -f "Caddyfile" ]; then
        webserver="caddy"
    else
        echo -e "${COLOR_RED}${LANG[CONFIG_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    if [ "$webserver" = "nginx" ]; then
        PANEL_DOMAIN=$(grep -B 20 "proxy_pass http://remnawave" "$dir/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)

        cookie_line=$(grep -A 2 "map \$http_cookie \$auth_cookie" "$dir/nginx.conf" | grep "~*\w\+.*=")
        cookies_random1=$(echo "$cookie_line" | grep -oP '~*\K\w+(?==)')
        cookies_random2=$(echo "$cookie_line" | grep -oP '=\K\w+(?=")')

        if [ -z "$PANEL_DOMAIN" ] || [ -z "$cookies_random1" ] || [ -z "$cookies_random2" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        else
            echo -e "${COLOR_RED}${LANG[NO_PORT_CHECK_TOOLS]}${COLOR_RESET}"
            exit 1
        fi

        sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
        sed -i "/server_name $PANEL_DOMAIN;/a \    listen 8443 ssl;" "$dir/nginx.conf"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_MODIFY_FAILED]}${COLOR_RESET}"
            exit 1
        fi

        docker compose down remnawave-nginx > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        docker compose up -d remnawave-nginx > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        sleep 1

        local panel_link="https://${PANEL_DOMAIN}:8443/auth/login?${cookies_random1}=${cookies_random2}"
        echo -e "${COLOR_YELLOW}${LANG[OPEN_PANEL_LINK]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}${panel_link}${COLOR_RESET}"
        echo -e "${COLOR_RED}${LANG[PORT_8443_WARNING]}${COLOR_RESET}"
    elif [ "$webserver" = "caddy" ]; then
        PANEL_DOMAIN=$(grep 'PANEL_DOMAIN=' "$dir/docker-compose.yml" | head -n 1 | sed 's/.*PANEL_DOMAIN=//; s/[[:space:]]*$//')

        if [ -z "$PANEL_DOMAIN" ]; then
            echo -e "${COLOR_RED}${LANG[CADDY_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if grep -q "https://{\$PANEL_DOMAIN}:8443 {" "$dir/Caddyfile"; then
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_CONFIGURED]}${COLOR_RESET}"
            return 0
        fi

        if command -v ss >/dev/null 2>&1; then
            if ss -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        elif command -v netstat >/dev/null 2>&1; then
            if netstat -tuln | grep -q ":8443"; then
                echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
                exit 1
            fi
        else
            echo -e "${COLOR_RED}${LANG[NO_PORT_CHECK_TOOLS]}${COLOR_RESET}"
            exit 1
        fi

        sed -i "s|redir https://{\$PANEL_DOMAIN}{uri} permanent|redir https://{\$PANEL_DOMAIN}:8443{uri} permanent|g" "$dir/Caddyfile"

        sed -i "s|https://{\$PANEL_DOMAIN} {|https://{\$PANEL_DOMAIN}:8443 {|g" "$dir/Caddyfile"
        sed -i "/https:\/\/{\$PANEL_DOMAIN}:8443 {/,/^}/ { /bind unix\/{\$CADDY_SOCKET_PATH}/d }" "$dir/Caddyfile"

        docker compose down remnawave-caddy > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        docker compose up -d remnawave-caddy > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        sleep 1

        local cookie_line=$(grep 'header +Set-Cookie' "$dir/Caddyfile" | head -n 1)
        local cookies_random1=$(echo "$cookie_line" | grep -oP 'Set-Cookie "\K[^=]+')
        local cookies_random2=$(echo "$cookie_line" | grep -oP 'Set-Cookie "[^=]+=\K[^;]+')

        local panel_link="https://${PANEL_DOMAIN}:8443/auth/login"
        if [ -n "$cookies_random1" ] && [ -n "$cookies_random2" ]; then
            panel_link="${panel_link}?${cookies_random1}=${cookies_random2}"
        fi
        echo -e "${COLOR_YELLOW}${LANG[OPEN_PANEL_LINK]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}${panel_link}${COLOR_RESET}"
        echo -e "${COLOR_RED}${LANG[PORT_8443_WARNING]}${COLOR_RESET}"
    fi
}

close_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    elif [ -d "/opt/remnanode" ]; then
        dir="/opt/remnanode"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    echo -e "${COLOR_YELLOW}${LANG[PORT_8443_CLOSE]}${COLOR_RESET}"

    local webserver=""
    if [ -f "nginx.conf" ]; then
        webserver="nginx"
    elif [ -f "Caddyfile" ]; then
        webserver="caddy"
    else
        echo -e "${COLOR_RED}${LANG[CONFIG_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    if [ "$webserver" = "nginx" ]; then
        PANEL_DOMAIN=$(grep -B 20 "proxy_pass http://remnawave" "$dir/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)

        if [ -z "$PANEL_DOMAIN" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if grep -A 10 "server_name $PANEL_DOMAIN;" "$dir/nginx.conf" | grep -q "listen 8443 ssl;"; then
            sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[NGINX_CONF_MODIFY_FAILED]}${COLOR_RESET}"
                exit 1
            fi

            docker compose down remnawave-nginx > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
            docker compose up -d remnawave-nginx > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_NOT_CONFIGURED]}${COLOR_RESET}"
        fi

        if ufw status | grep -q "8443.*ALLOW"; then
            ufw delete allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[UFW_RELOAD_FAILED]}${COLOR_RESET}"
                exit 1
            fi
            echo -e "${COLOR_GREEN}${LANG[PORT_8443_CLOSED]}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_CLOSED]}${COLOR_RESET}"
        fi
    elif [ "$webserver" = "caddy" ]; then
        PANEL_DOMAIN=$(grep 'PANEL_DOMAIN=' "$dir/docker-compose.yml" | head -n 1 | sed 's/.*PANEL_DOMAIN=//; s/[[:space:]]*$//')

        if [ -z "$PANEL_DOMAIN" ]; then
            echo -e "${COLOR_RED}${LANG[CADDY_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        if grep -q "https://{\$PANEL_DOMAIN}:8443 {" "$dir/Caddyfile"; then
            sed -i "s|https://{\$PANEL_DOMAIN}:8443 {|https://{\$PANEL_DOMAIN} {|g" "$dir/Caddyfile"

            sed -i "/https:\/\/{\$PANEL_DOMAIN} {/a \    bind unix/{\$CADDY_SOCKET_PATH}" "$dir/Caddyfile"

            sed -i "s|redir https://{\$PANEL_DOMAIN}:8443{uri} permanent|redir https://{\$PANEL_DOMAIN}{uri} permanent|g" "$dir/Caddyfile"

            docker compose down remnawave-caddy > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
            docker compose up -d remnawave-caddy > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_NOT_CONFIGURED]}${COLOR_RESET}"
        fi

        if ufw status | grep -q "8443.*ALLOW"; then
            ufw delete allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[UFW_RELOAD_FAILED]}${COLOR_RESET}"
                exit 1
            fi
            echo -e "${COLOR_GREEN}${LANG[PORT_8443_CLOSED]}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_CLOSED]}${COLOR_RESET}"
        fi
    fi
}
