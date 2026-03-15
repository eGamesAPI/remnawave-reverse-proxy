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
            sleep 2
            log_clear
            manage_panel_access
            ;;
        2)
            close_panel_access
            sleep 2
            log_clear
            manage_panel_access
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_panel_access
            ;;
    esac
}

open_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    # Determine web server type
    local webserver=""
    if [ -f "nginx.conf" ]; then
        webserver="nginx"
    elif [ -f "Caddyfile" ]; then
        webserver="caddy"
    else
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_NOT_FOUND]} $dir${COLOR_RESET}"
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

    if [ "$webserver" = "nginx" ]; then
        # Nginx handling
        PANEL_DOMAIN=$(grep -B 20 "proxy_pass http://remnawave" "$dir/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)

        cookie_line=$(grep -A 2 "map \$http_cookie \$auth_cookie" "$dir/nginx.conf" | grep "~*\w\+.*=")
        cookies_random1=$(echo "$cookie_line" | grep -oP '~*\K\w+(?==)')
        cookies_random2=$(echo "$cookie_line" | grep -oP '=\K\w+(?=")')

        if [ -z "$PANEL_DOMAIN" ] || [ -z "$cookies_random1" ] || [ -z "$cookies_random2" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
        sed -i "/server_name $PANEL_DOMAIN;/a \    listen 8443 ssl;" "$dir/nginx.conf"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        docker compose restart remnawave-nginx > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        echo -e ""
        echo -e "${COLOR_GREEN}=================================================${COLOR_RESET}"
        echo -e "${COLOR_GREEN}${LANG[PORT_8443_OPENED]}${COLOR_RESET}"
        echo -e "${COLOR_GREEN}=================================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[PANEL_ACCESS]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}https://${PANEL_DOMAIN}:8443/auth/login?${cookies_random1}=${cookies_random2}${COLOR_RESET}"
        echo -e "${COLOR_GREEN}=================================================${COLOR_RESET}"
    elif [ "$webserver" = "caddy" ]; then
        # Caddy handling
        PANEL_DOMAIN=$(grep -oP 'https://\{\$PANEL_DOMAIN\}' "$dir/Caddyfile" | head -1 | sed 's/https:\/\///;s/{\$PANEL_DOMAIN}//')
        
        if [ -z "$PANEL_DOMAIN" ]; then
            PANEL_DOMAIN=$(grep "PANEL_DOMAIN=" "$dir/.env" 2>/dev/null | cut -d'=' -f2)
        fi

        if [ -z "$PANEL_DOMAIN" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        # Get cookies from Caddyfile
        cookie_line=$(grep -A 2 "query \$cookies_random1=\$cookies_random2" "$dir/Caddyfile" | head -1)
        cookies_random1=$(echo "$cookie_line" | grep -oP 'cookies_random1' | head -1)
        cookies_random2=$(echo "$cookie_line" | grep -oP 'cookies_random2' | head -1)
        
        # If not found in Caddyfile, try to extract from set-cookie line
        if [ -z "$cookies_random1" ] || [ -z "$cookies_random2" ]; then
            cookie_line=$(grep "Set-Cookie" "$dir/Caddyfile" | head -1)
            cookies_random1=$(echo "$cookie_line" | grep -oP '\K\w+(?==)' | head -1)
            cookies_random2=$(echo "$cookie_line" | grep -oP '=\K\w+(?=;)' | head -1)
        fi

        # Check if port 8443 already exists in Caddyfile
        if grep -q "bind unix:.*:8443" "$dir/Caddyfile" || grep -q "listen.*8443" "$dir/Caddyfile"; then
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_OPEN]}${COLOR_RESET}"
            return 0
        fi

        # Add port 8443 to Caddyfile - modify the https block to also listen on 8443
        # Find the https://{$PANEL_DOMAIN} block and add a new server block for 8443
        sed -i "/^https:\/\/{\$PANEL_DOMAIN} {/a \\\nhttps:\/\/{\$PANEL_DOMAIN}:8443 {\\n    bind 0.0.0.0\\n    @has_token_param {\\n        query \\$cookies_random1=\\$cookies_random2\\n    }\\n\\n    handle @has_token_param {\\n        header +Set-Cookie \"\\$cookies_random1=\\$cookies_random2; Path=\/; HttpOnly; Secure; SameSite=Strict; Max-Age=2592000\"\\n    }\\n\\n    @unauthorized {\\n        not header Cookie *\\$cookies_random1=\\$cookies_random2*\\n        not query \\$cookies_random1=\\$cookies_random2\\n    }\\n\\n    handle @unauthorized {\\n        root * \/var\/www\/html\\n        try_files {path} \/index.html\\n        file_server\\n    }\\n\\n    reverse_proxy {\$BACKEND_URL} {\\n        header_up X-Real-IP {remote}\\n        header_up Host {host}\\n    }\\n}" "$dir/Caddyfile"

        docker compose restart caddy-remnawave > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        sleep 1

        echo -e ""
        echo -e "${COLOR_GREEN}=================================================${COLOR_RESET}"
        echo -e "${COLOR_GREEN}${LANG[PORT_8443_OPENED]}${COLOR_RESET}"
        echo -e "${COLOR_GREEN}=================================================${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[PANEL_ACCESS]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}https://${PANEL_DOMAIN}:8443/auth/login?${cookies_random1}=${cookies_random2}${COLOR_RESET}"
        echo -e "${COLOR_GREEN}=================================================${COLOR_RESET}"
    fi
}

close_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    # Determine web server type
    local webserver=""
    if [ -f "nginx.conf" ]; then
        webserver="nginx"
    elif [ -f "Caddyfile" ]; then
        webserver="caddy"
    else
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_NOT_FOUND]} $dir${COLOR_RESET}"
        exit 1
    fi

    PANEL_DOMAIN=$(grep "PANEL_DOMAIN=" "$dir/.env" 2>/dev/null | cut -d'=' -f2)

    if [ -z "$PANEL_DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
        exit 1
    fi

    if command -v ss >/dev/null 2>&1; then
        if ! ss -tuln | grep -q ":8443"; then
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_NOT_OPEN]}${COLOR_RESET}"
            return 0
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if ! netstat -tuln | grep -q ":8443"; then
            echo -e "${COLOR_YELLOW}${LANG[PORT_8443_NOT_OPEN]}${COLOR_RESET}"
            return 0
        fi
    else
        echo -e "${COLOR_RED}${LANG[NO_PORT_CHECK_TOOLS]}${COLOR_RESET}"
        exit 1
    fi

    if [ "$webserver" = "nginx" ]; then
        # Nginx handling
        if [ ! -f "nginx.conf" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_NOT_FOUND]} $dir${COLOR_RESET}"
            exit 1
        fi

        sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
            exit 1
        fi

        docker compose restart remnawave-nginx > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        echo -e "${COLOR_GREEN}${LANG[PORT_8443_CLOSED]}${COLOR_RESET}"
    elif [ "$webserver" = "caddy" ]; then
        # Caddy handling
        if [ ! -f "Caddyfile" ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_NOT_FOUND]} $dir${COLOR_RESET}"
            exit 1
        fi

        # Remove the 8443 server block from Caddyfile
        sed -i '/^https:\/\/{\$PANEL_DOMAIN}:8443 {/,/^}/d' "$dir/Caddyfile"

        docker compose restart caddy-remnawave > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"

        # Remove UFW rule
        if ufw status | grep -q "8443.*ALLOW"; then
            ufw delete allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
        fi

        echo -e "${COLOR_GREEN}${LANG[PORT_8443_CLOSED]}${COLOR_RESET}"
    fi
}
