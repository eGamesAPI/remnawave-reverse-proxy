#!/bin/bash
# Module: Xray Checker — proxy monitoring through real connections
# (Xray Checker by kutovoys) with an optional Telegram-managed public status
# page (xray-checker-statuspage by Mrvibecodic).
#
# Both containers are loopback-only: checker metrics on 127.0.0.1:2112, the
# status page on :8080 and its /sub feed on :8081. The public side is served
# by the existing remnawave-nginx/remnawave-caddy when one is installed, or
# by a dedicated caddy sidecar in the same compose on a stand-alone box.
# Nothing here ever sits behind tinyauth/MFA: the panel's auth layers guard
# the panel domain only, while the checker consumes the sub domain, which is
# public by design (client apps cannot log into portals).

XCHK_DIR="/opt/xray-checker"
XCHK_CHECKER_IMAGE="kutovoys/xray-checker:latest"
XCHK_STATUSPAGE_IMAGE="ghcr.io/mrvibecodic/xray-checker-statuspage:go-build"
XCHK_SIDECAR_IMAGE="caddy:2"
XCHK_STATE_FILE="${DIR_REMNAWAVE}xray-checker.state"
XCHK_MONITOR_USER="xray-checker"
XCHK_PANEL_ENV="/opt/remnawave/.env"
XCHK_PANEL_HOST="127.0.0.1:3000"
XCHK_CHECK_INTERVAL_DEFAULT=300

# Marker pair around the site block this module adds to a live nginx.conf /
# Caddyfile, so uninstall removes exactly its own lines.
XCHK_MARK_BEGIN="# >>> reverse-xray-checker-status >>>"
XCHK_MARK_END="# <<< reverse-xray-checker-status <<<"

xchk_state_get() {
    [ -r "$XCHK_STATE_FILE" ] || return 0
    sed -n "s|^$1=||p" "$XCHK_STATE_FILE" | head -n1
}

xchk_state_set() {
    printf 'mode=%s\ndomain=%s\ncert_domain=%s\nmounts=%s\nwebserver=%s\n' \
        "$1" "$2" "$3" "${4:-0}" "${5:-none}" > "$XCHK_STATE_FILE"
    chmod 600 "$XCHK_STATE_FILE" 2>/dev/null
}

xchk_state_clear() {
    rm -f "$XCHK_STATE_FILE"
}

xchk_installed() {
    [ -f "$XCHK_DIR/docker-compose.yml" ]
}

xchk_with_statuspage() {
    xchk_installed && grep -q "xray-checker-statuspage" "$XCHK_DIR/docker-compose.yml"
}

xchk_container_up() {
    docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$1"
}

# Prints "<kind> <dir>" for the reverse proxy serving this box, or fails.
xchk_webserver() {
    local dir
    for dir in /opt/remnawave /opt/subscription; do
        [ -f "$dir/docker-compose.yml" ] || continue
        if grep -qE '^[[:space:]]*remnawave-nginx:' "$dir/docker-compose.yml" \
            && [ -f "$dir/nginx.conf" ]; then
            echo "nginx $dir"
            return 0
        fi
        if grep -qE '^[[:space:]]*remnawave-caddy:' "$dir/docker-compose.yml" \
            && [ -f "$dir/Caddyfile" ]; then
            echo "caddy $dir"
            return 0
        fi
    done
    return 1
}

xchk_port_busy() {
    ss -tln 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" { found = 1 } END { exit !found }'
}

xchk_env_get() {
    [ -r "$XCHK_PANEL_ENV" ] || return 1
    sed -n "s|^$1=||p" "$XCHK_PANEL_ENV" | head -n1
}

# Squads gate host visibility: on a panel with internal squads a user with
# an empty activeInternalSquads sees no hosts at all (the panel serves the
# "Check Internal Squads tab" placeholder), so the monitoring user joins
# every squad that exists.
xchk_assign_squads() {
    local response squads squads_json
    response=$(make_api_request "GET" "http://${XCHK_PANEL_HOST}/api/internal-squads?_=$(date +%s)" "$token")
    squads=$(echo "$response" | jq -r '[.response.internalSquads[]?.uuid] | join(" ")' 2>/dev/null)
    [ -z "$squads" ] && return 1
    squads_json=$(printf '%s\n' $squads | jq -R . | jq -s .)
    response=$(make_api_request "PATCH" "http://${XCHK_PANEL_HOST}/api/users" "$token" \
        "$(jq -n --arg u "$XCHK_MONITOR_USER" --argjson s "$squads_json" \
            '{username: $u, activeInternalSquads: $s}')")
    echo "$response" | jq -e '.response.username' >/dev/null 2>&1
}

# --- Monitoring user -----------------------------------------------------------
# A dedicated panel user whose subscription covers every enabled host — new
# nodes appear in the checker on the next subscription refresh, no manual
# steps. Sets XCHK_PANEL_SUB_URL; XCHK_MONITOR_USER_CREATED=1 on creation.

xchk_ensure_monitor_user() {
    XCHK_PANEL_SUB_URL=""
    XCHK_MONITOR_USER_CREATED=0

    load_api_module
    if [ -z "$PANEL_DOMAIN" ]; then
        PANEL_DOMAIN=$(grep -h '^PANEL_DOMAIN=' /opt/remnawave/.env /opt/remnawave/docker-compose.yml 2>/dev/null | head -n1 \
            | sed -e 's/^PANEL_DOMAIN=//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" -e 's/[[:space:]]*$//')
    fi
    if ! get_panel_token; then
        echo -e "${COLOR_RED}${LANG[XCHK_TOKEN_FAIL]}${COLOR_RESET}"
        return 1
    fi

    local response sub_url
    response=$(make_api_request "GET" "http://${XCHK_PANEL_HOST}/api/users/by-username/${XCHK_MONITOR_USER}?_=$(date +%s)" "$token")
    sub_url=$(echo "$response" | jq -r '.response.subscriptionUrl // empty' 2>/dev/null)
    if [ -n "$sub_url" ]; then
        echo -e "${COLOR_GREEN}$(printf "${LANG[XCHK_USER_REUSED]}" "$XCHK_MONITOR_USER")${COLOR_RESET}"
        XCHK_PANEL_SUB_URL="$sub_url"
        if [ "$(echo "$response" | jq -r '(.response.activeInternalSquads // []) | length' 2>/dev/null)" = "0" ]; then
            step_do "${LANG[XCHK_SQUADS_ASSIGN]}"
            xchk_assign_squads || echo -e "${COLOR_YELLOW}${LANG[XCHK_SQUADS_FAIL]}${COLOR_RESET}"
        fi
        return 0
    fi

    step_do "$(printf "${LANG[XCHK_USER_CREATING]}" "$XCHK_MONITOR_USER")"
    local expire_at
    expire_at=$(date -u -d "+10 years" +%Y-%m-%dT%H:%M:%S.000Z)
    response=$(make_api_request "POST" "http://${XCHK_PANEL_HOST}/api/users" "$token" \
        "$(jq -n --arg u "$XCHK_MONITOR_USER" \
            --arg d "Monitoring user for Xray Checker (created by remnawave-reverse-proxy)" \
            --arg e "$expire_at" \
            '{username: $u, description: $d, expireAt: $e}')")
    sub_url=$(echo "$response" | jq -r '.response.subscriptionUrl // empty' 2>/dev/null)
    if [ -z "$sub_url" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[XCHK_USER_FAIL]}" "$response")${COLOR_RESET}"
        return 1
    fi
    echo -e "${COLOR_GREEN}$(printf "${LANG[XCHK_USER_CREATED]}" "$XCHK_MONITOR_USER")${COLOR_RESET}"
    step_do "${LANG[XCHK_SQUADS_ASSIGN]}"
    xchk_assign_squads || echo -e "${COLOR_YELLOW}${LANG[XCHK_SQUADS_FAIL]}${COLOR_RESET}"
    XCHK_PANEL_SUB_URL="$sub_url"
    XCHK_MONITOR_USER_CREATED=1
    return 0
}

# --- Telegram bot --------------------------------------------------------------

xchk_tg_show_error() {
    local desc
    desc=$(printf '%s' "${XCHK_TG_RESPONSE:-}" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')
    if [ -n "$desc" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[CERT_TG_FAIL_DESC]}" "$desc")${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CERT_TG_FAIL]}${COLOR_RESET}"
    fi
}

xchk_tg_test() {
    local proxy_args=()
    [ -n "$XCHK_TG_PROXY_VAL" ] && proxy_args=(--proxy "$XCHK_TG_PROXY_VAL")
    XCHK_TG_RESPONSE=$(curl -s -m 20 "${proxy_args[@]}" \
        "https://api.telegram.org/bot${XCHK_TG_TOKEN_VAL}/getMe" 2>/dev/null)
    XCHK_TG_RC=$?
    printf '%s' "$XCHK_TG_RESPONSE" | grep -q '"ok":true'
}

# Best-effort message to the first admin chat: a bot may only write into a
# chat the user has opened first, so a failure here is a hint, not an error.
xchk_tg_send_test() {
    local chat_id="$1"
    local proxy_args=()
    [ -n "$XCHK_TG_PROXY_VAL" ] && proxy_args=(--proxy "$XCHK_TG_PROXY_VAL")
    XCHK_TG_RESPONSE=$(curl -s -m 20 "${proxy_args[@]}" \
        "https://api.telegram.org/bot${XCHK_TG_TOKEN_VAL}/sendMessage" \
        --data-urlencode "chat_id=${chat_id}" \
        --data-urlencode "text=✅ ${LANG[XCHK_TG_TEST_TEXT]}" 2>/dev/null)
    XCHK_TG_RC=$?
    printf '%s' "$XCHK_TG_RESPONSE" | grep -q '"ok":true'
}

xchk_tg_confirm_send() {
    local first_admin="${XCHK_TG_ADMINS_VAL%%,*}"
    echo -e "${COLOR_YELLOW}${LANG[XCHK_TG_SENDING]}${COLOR_RESET}"
    if xchk_tg_send_test "$first_admin"; then
        echo -e "${COLOR_GREEN}${LANG[XCHK_TG_OK]}${COLOR_RESET}"
    else
        # getMe already proved the token works — an unsent message means the
        # admin has not started the chat with the bot yet.
        echo -e "${COLOR_GREEN}${LANG[XCHK_TG_OK]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[XCHK_TG_START_HINT]}${COLOR_RESET}"
    fi
    return 0
}

# Bot token + admin ids (and optional alert chats). Sets XCHK_TG_TOKEN_VAL,
# XCHK_TG_ADMINS_VAL, XCHK_TG_NOTIFY_VAL, XCHK_TG_PROXY_VAL.
xchk_ask_tg() {
    XCHK_TG_TOKEN_VAL=""
    XCHK_TG_ADMINS_VAL=""
    XCHK_TG_NOTIFY_VAL=""
    XCHK_TG_PROXY_VAL=""

    local token_input admins_input notify_input
    reading "${LANG[XCHK_TG_TOKEN_PROMPT]}" token_input || return 0
    [ -z "$token_input" ] && return 0

    while true; do
        reading "${LANG[XCHK_TG_ADMINS_PROMPT]}" admins_input || return 0
        local admins_re='^[0-9]+(,[[:space:]]*[0-9]+)*$'
        if [ -n "$admins_input" ] && [[ "$admins_input" =~ $admins_re ]]; then
            admins_input=$(echo "$admins_input" | tr -d ' ')
            break
        fi
        echo -e "${COLOR_RED}${LANG[XCHK_TG_ADMINS_INVALID]}${COLOR_RESET}"
    done

    reading "${LANG[XCHK_TG_NOTIFY_PROMPT]}" notify_input || return 0
    if [ -n "$notify_input" ]; then
        notify_input=$(echo "$notify_input" | tr -d ' ')
    fi

    XCHK_TG_TOKEN_VAL="$token_input"
    XCHK_TG_ADMINS_VAL="$admins_input"
    XCHK_TG_NOTIFY_VAL="$notify_input"

    echo -e "${COLOR_YELLOW}${LANG[XCHK_TG_CHECKING]}${COLOR_RESET}"
    if xchk_tg_test; then
        xchk_tg_confirm_send
        return 0
    fi

    # Empty reply with a curl error means api.telegram.org is unreachable —
    # offer a SOCKS5 proxy for the bot API (statuspage's TELEGRAM_PROXY).
    if [ -z "$XCHK_TG_RESPONSE" ] && [ "${XCHK_TG_RC:-0}" -ne 0 ]; then
        echo -e "${COLOR_YELLOW}${LANG[CERT_TG_BLOCKED]}${COLOR_RESET}"
        local use_proxy proxy_url proxy_re='^(https?|socks5h?)://[A-Za-z0-9.:_%@/?=-]+$'
        printf "${COLOR_YELLOW}${LANG[CERT_TG_PROXY]}${COLOR_RESET}\n"
        read_yn use_proxy || return 1
        reading "${LANG[CERT_TG_PROXY_URL]}" proxy_url || proxy_url=""
        if [ -n "$proxy_url" ] && [[ "$proxy_url" =~ $proxy_re ]]; then
            XCHK_TG_PROXY_VAL="$proxy_url"
            echo -e "${COLOR_YELLOW}${LANG[XCHK_TG_CHECKING]}${COLOR_RESET}"
            if xchk_tg_test; then
                xchk_tg_confirm_send
                return 0
            fi
        fi
    fi
    xchk_tg_show_error
    return 1
}

# --- Webserver wiring ----------------------------------------------------------

# Cert mounts are inserted right after the nginx.conf mount of the
# remnawave-nginx service — the one anchor every our nginx install shares.
xchk_add_cert_mounts() {
    local compose="$1" cert_domain="$2" tmp
    grep -q "/etc/letsencrypt/live/$cert_domain/fullchain.pem" "$compose" && return 0
    tmp=$(mktemp) || return 1
    awk -v cert="$cert_domain" '
        { print }
        !done && $0 ~ /- \.\/nginx\.conf:\/etc\/nginx\/conf\.d\/default\.conf:ro/ {
            match($0, /^[[:space:]]*/)
            pad = substr($0, RSTART, RLENGTH)
            print pad "- /etc/letsencrypt/live/" cert "/fullchain.pem:/etc/nginx/ssl/" cert "/fullchain.pem:ro"
            print pad "- /etc/letsencrypt/live/" cert "/privkey.pem:/etc/nginx/ssl/" cert "/privkey.pem:ro"
            done = 1
        }
    ' "$compose" > "$tmp"
    if ! grep -q "/etc/letsencrypt/live/$cert_domain/fullchain.pem" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$compose"
    return 0
}

xchk_remove_cert_mounts() {
    local compose="$1" cert_domain="$2"
    [ -n "$cert_domain" ] || return 0
    sed -i "\|/etc/letsencrypt/live/$cert_domain/|d" "$compose"
}

# Issue (or reuse) a certificate and add the site block to the live nginx.
# Sets XCHK_CERT_DOMAIN and XCHK_MOUNTS_ADDED.
xchk_wire_nginx() {
    local dir="$1" domain="$2"
    local compose="$dir/docker-compose.yml" conf="$dir/nginx.conf"
    load_certificates_module

    local cert_domain="$domain"
    local base_domain
    base_domain=$(extract_domain "$domain")
    if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
        cert_domain="$base_domain"
        echo -e "${COLOR_GREEN}$(printf "${LANG[XCHK_CERT_WILDCARD]}" "$cert_domain")${COLOR_RESET}"
    else
        local method email
        echo -e "${COLOR_YELLOW}${LANG[CERT_METHOD_PROMPT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[CERT_METHOD_CF]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[CERT_METHOD_ACME]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[CERT_METHOD_GCORE]}${COLOR_RESET}"
        echo -e ""
        while true; do
            reading "${LANG[CERT_METHOD_CHOOSE]}" method
            case "$method" in
                1|2|3) break ;;
                *) echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}" ;;
            esac
        done
        email=""
        if [ "$method" = "2" ] || [ "$method" = "3" ]; then
            reading "${LANG[EMAIL_PROMPT]}" email
        fi
        get_certificates "$domain" "$method" "$email" || return 1
        check_certificates "$domain" >/dev/null 2>&1 || return 1
        if [ "$method" = "1" ] || [ "$method" = "3" ]; then
            cert_domain="$base_domain"
        fi
    fi
    XCHK_CERT_DOMAIN="$cert_domain"

    # compose edit with validation + rollback: a broken compose would take
    # the whole panel stack down on the next up. The conf gets its own
    # backup too — the marker block is appended before nginx -t runs.
    local backup="${compose}.xchkbak"
    local conf_backup="${conf}.xchkbak"
    cp -p "$compose" "$backup"
    cp -p "$conf" "$conf_backup"

    # Rollback restores both files; a re-up plus a graceful reload bring the
    # running nginx back to the pre-edit configuration.
    xchk_nginx_rollback() {
        cp -p "$conf_backup" "$conf"
        cp -p "$backup" "$compose"
        rm -f "$backup" "$conf_backup"
        (cd "$dir" && docker compose up -d remnawave-nginx) >/dev/null 2>&1
        docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1
    }

    XCHK_MOUNTS_ADDED=0
    if ! grep -q "/etc/letsencrypt/live/$cert_domain/fullchain.pem" "$compose"; then
        step_do "${LANG[XCHK_MOUNTS_ADDED]}"
        if ! xchk_add_cert_mounts "$compose" "$cert_domain"; then
            xchk_nginx_rollback
            echo -e "${COLOR_RED}$(printf "${LANG[XCHK_MOUNT_FAIL]}" "anchor not found")${COLOR_RESET}"
            return 1
        fi
        XCHK_MOUNTS_ADDED=1
        if ! (cd "$dir" && docker compose config -q) >/dev/null 2>&1; then
            xchk_nginx_rollback
            echo -e "${COLOR_RED}$(printf "${LANG[XCHK_MOUNT_FAIL]}" "docker compose config")${COLOR_RESET}"
            return 1
        fi
    fi

    # Site block, marker-wrapped for a clean uninstall. On a panel+node box
    # TCP 443 belongs to Xray (Reality) and nginx serves behind it on a unix
    # socket with proxy_protocol — there the block joins that socket and
    # arrives via Reality's fallback, exactly like the panel's own domain.
    # A pure panel install has nginx on 443 directly.
    local listen_line="listen 443 ssl"
    local real_ip="\$remote_addr"
    if grep -q "listen unix:/dev/shm/nginx.sock" "$conf"; then
        listen_line="listen unix:/dev/shm/nginx.sock ssl proxy_protocol"
        real_ip="\$proxy_protocol_addr"
    fi

    cat >> "$conf" <<EOL

${XCHK_MARK_BEGIN}
server {
    server_name $domain;
    $listen_line;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$cert_domain/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$cert_domain/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$cert_domain/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $real_ip;
        proxy_set_header X-Forwarded-For $real_ip;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
${XCHK_MARK_END}
EOL

    # nginx -t validates syntax and certificate paths before anything is
    # applied. One caveat on a live panel+node box: the running master
    # already holds /dev/shm/nginx.sock, and a config test re-listening it
    # fails with EADDRINUSE — by then the whole config was already parsed,
    # so that specific conflict with ourselves is expected and passes;
    # every other failure is real and rolls both edits back.
    local test_out test_rc=0
    test_out=$(docker exec remnawave-nginx nginx -t 2>&1) || test_rc=$?
    if [ "$test_rc" -ne 0 ]; then
        if ! printf '%s' "$test_out" | grep -q "unix:/dev/shm/nginx.sock" \
            || ! printf '%s' "$test_out" | grep -q "Address already in use"; then
            xchk_nginx_rollback
            echo -e "${COLOR_RED}${LANG[XCHK_NGINX_TEST_FAIL]}${COLOR_RESET}"
            printf '%s\n' "$test_out" | tail -n 5 | sed 's/^/  /'
            return 1
        fi
    fi

    step_do "${LANG[XCHK_APPLYING_WEBSERVER]}"
    # compose recreates only on compose-level changes; the bind-mounted conf
    # needs an explicit graceful reload to reach the running nginx.
    (cd "$dir" && docker compose up -d remnawave-nginx) >/dev/null 2>&1
    docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1
    if ! xchk_container_up remnawave-nginx; then
        xchk_nginx_rollback
        echo -e "${COLOR_RED}${LANG[XCHK_WEB_APPLY_FAIL]}${COLOR_RESET}"
        return 1
    fi
    rm -f "$backup" "$conf_backup"
    return 0
}

# Remove the marker block and the cert mounts this module added.
xchk_unwire_nginx() {
    local dir="$1"
    local compose="$dir/docker-compose.yml" conf="$dir/nginx.conf"
    [ -f "$conf" ] && sed -i "/^${XCHK_MARK_BEGIN}\$/,/^${XCHK_MARK_END}\$/d" "$conf"
    local cert_domain
    cert_domain=$(xchk_state_get "cert_domain")
    if [ "$(xchk_state_get "mounts")" = "1" ] && [ -n "$cert_domain" ] && [ -f "$compose" ]; then
        xchk_remove_cert_mounts "$compose" "$cert_domain"
        (cd "$dir" && docker compose up -d remnawave-nginx) >/dev/null 2>&1
        docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1
    elif [ -f "$conf" ]; then
        docker restart remnawave-nginx >/dev/null 2>&1
    fi
}

xchk_wire_caddy() {
    local dir="$1" domain="$2"
    local caddyfile="$dir/Caddyfile"

    # Caddy manages its own certificates via ACME on :80 (renewals live in
    # caddy_data) — no cert mounts are involved. On a panel+node box it
    # serves behind Xray on a unix socket and the status site joins that
    # socket exactly like the panel's own block; on a pure panel install
    # caddy owns 443 directly and the bind line is omitted.
    local bind_line=""
    if grep -q "bind unix/" "$caddyfile"; then
        bind_line="    bind unix/{\$CADDY_SOCKET_PATH}"
    fi

    cat >> "$caddyfile" <<EOL

${XCHK_MARK_BEGIN}
https://$domain {
${bind_line}
    auto_https disable_redirects
    encode
    handle {
        reverse_proxy 127.0.0.1:8080 {
            header_up X-Real-IP {remote}
            header_up Host {host}
        }
    }
}
${XCHK_MARK_END}
EOL

    step_do "${LANG[XCHK_APPLYING_WEBSERVER]}"
    docker restart remnawave-caddy >/dev/null 2>&1
    if ! xchk_container_up remnawave-caddy; then
        sed -i "/^${XCHK_MARK_BEGIN}\$/,/^${XCHK_MARK_END}\$/d" "$caddyfile"
        docker restart remnawave-caddy >/dev/null 2>&1
        echo -e "${COLOR_RED}${LANG[XCHK_WEB_APPLY_FAIL]}${COLOR_RESET}"
        return 1
    fi
    return 0
}

xchk_unwire_caddy() {
    local dir="$1"
    local caddyfile="$dir/Caddyfile"
    [ -f "$caddyfile" ] || return 0
    sed -i "/^${XCHK_MARK_BEGIN}\$/,/^${XCHK_MARK_END}\$/d" "$caddyfile"
    docker restart remnawave-caddy >/dev/null 2>&1
}

# Ask for the status domain (optional) and wire TLS. Sets XCHK_DOMAIN,
# XCHK_SIDECAR, XCHK_WS_KIND, XCHK_WS_DIR, XCHK_CERT_DOMAIN, XCHK_MOUNTS_ADDED.
xchk_prepare_domain() {
    XCHK_DOMAIN=""
    XCHK_SIDECAR=0
    XCHK_WS_KIND="none"
    XCHK_WS_DIR=""

    local domain_input
    reading "${LANG[XCHK_DOMAIN_PROMPT]}" domain_input || return 0
    [ -z "$domain_input" ] || [ "$domain_input" = "0" ] && {
        echo -e "${COLOR_YELLOW}${LANG[XCHK_DOMAIN_NONE]}${COLOR_RESET}"
        return 0
    }
    local domain_re='^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$'
    if ! [[ "$domain_input" =~ $domain_re ]]; then
        echo -e "${COLOR_RED}${LANG[XCHK_DOMAIN_INVALID]}${COLOR_RESET}"
        return 1
    fi

    load_dns_records_module
    ensure_dns_record "$domain_input" || true

    local ws kind dir
    if ws=$(xchk_webserver); then
        kind="${ws%% *}"
        dir="${ws#* }"
        if [ "$kind" = "nginx" ]; then
            xchk_wire_nginx "$dir" "$domain_input" || return 1
        else
            XCHK_CERT_DOMAIN=""
            XCHK_MOUNTS_ADDED=0
            xchk_wire_caddy "$dir" "$domain_input" || return 1
        fi
        XCHK_DOMAIN="$domain_input"
        XCHK_WS_KIND="$kind"
        XCHK_WS_DIR="$dir"
        return 0
    fi

    # No shared webserver: a stand-alone box can host its own caddy sidecar
    # with automatic TLS — needs 80/443 free.
    if xchk_port_busy 80 || xchk_port_busy 443; then
        echo -e "${COLOR_YELLOW}${LANG[XCHK_DOMAIN_NONE]}${COLOR_RESET}"
        return 0
    fi
    local use_sidecar
    if reading_yn "$(printf "${LANG[XCHK_SIDECAR_CONFIRM]}" "$domain_input")" use_sidecar; then
        XCHK_DOMAIN="$domain_input"
        XCHK_SIDECAR=1
        XCHK_WS_KIND="sidecar"
        ufw allow 80/tcp comment 'ACME' >/dev/null 2>&1
        ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1
    else
        echo -e "${COLOR_YELLOW}${LANG[XCHK_DOMAIN_NONE]}${COLOR_RESET}"
    fi
    return 0
}

# --- Stack files ---------------------------------------------------------------

xchk_write_stack() {
    local mode="$1" sub_url="$2" interval="$3" method="$4"

    # In bundle mode the checker reads the statuspage's /sub feed, and the
    # real subscription goes to the statuspage itself as its env fallback:
    # /sub answers 404 "subscription not configured" until either a bot-fed
    # subscription or that fallback exists, and the checker treats the 404
    # as fatal. With the fallback set, the checker boots from the very
    # first start; bot-fed subscriptions later take priority over it.
    local checker_sub="$sub_url"
    [ "$mode" = "bundle" ] && checker_sub="http://127.0.0.1:8081/sub"

    mkdir -p "$XCHK_DIR"

    local tz
    tz=$(cat /etc/timezone 2>/dev/null || echo "Europe/Moscow")

    # The .env carries every secret (sub URL with its token, bot token) and
    # feeds compose variable substitution; compose reads it automatically.
    cat > "$XCHK_DIR/.env" <<EOL
XCHK_SUBSCRIPTION_URL=$sub_url
XCHK_CHECK_INTERVAL=$interval
XCHK_CHECK_METHOD=$method
XCHK_TZ=$tz
XCHK_BOT_TOKEN=${XCHK_TG_TOKEN_VAL:-}
XCHK_BOT_ADMIN_IDS=${XCHK_TG_ADMINS_VAL:-}
XCHK_NOTIFY_CHAT_IDS=${XCHK_TG_NOTIFY_VAL:-}
XCHK_TG_PROXY=${XCHK_TG_PROXY_VAL:-}
EOL
    chmod 600 "$XCHK_DIR/.env"

    step_do "${LANG[XCHK_WRITING]}"

    cat > "$XCHK_DIR/docker-compose.yml" <<EOL
services:
  xray-checker:
    image: ${XCHK_CHECKER_IMAGE}
    container_name: xray-checker
    hostname: xray-checker
    restart: unless-stopped
    network_mode: host
    environment:
      - SUBSCRIPTION_URL=$checker_sub
      - SUBSCRIPTION_UPDATE=true
      - SUBSCRIPTION_UPDATE_INTERVAL=300
      - PROXY_CHECK_INTERVAL=\${XCHK_CHECK_INTERVAL}
      - PROXY_CHECK_METHOD=\${XCHK_CHECK_METHOD}
      - PROXY_TIMEOUT=30
      - METRICS_HOST=127.0.0.1
      - METRICS_PORT=2112
      - XRAY_LOG_LEVEL=none
      - LOG_LEVEL=info
EOL

    if [ "$mode" = "bundle" ]; then
        # depends_on mirrors the upstream example: the checker's subscription
        # source is the statuspage's /sub feed, so it starts after the page.
        cat >> "$XCHK_DIR/docker-compose.yml" <<EOL
    depends_on:
      - xray-checker-statuspage
EOL
        cat >> "$XCHK_DIR/docker-compose.yml" <<EOL

  xray-checker-statuspage:
    image: ${XCHK_STATUSPAGE_IMAGE}
    container_name: xray-checker-statuspage
    hostname: xray-checker-statuspage
    restart: unless-stopped
    network_mode: host
    environment:
      - CHECKER_URL=http://127.0.0.1:2112
      - PORT=8080
      - TLS_MODE=off
      - INTERNAL_PORT=8081
      - PROXY_CHECK_INTERVAL=\${XCHK_CHECK_INTERVAL}
      - SUBSCRIPTION_URL=\${XCHK_SUBSCRIPTION_URL}
      - BOT_TOKEN=\${XCHK_BOT_TOKEN}
      - BOT_ADMIN_IDS=\${XCHK_BOT_ADMIN_IDS}
      - NOTIFY_CHAT_IDS=\${XCHK_NOTIFY_CHAT_IDS}
      - TELEGRAM_PROXY=\${XCHK_TG_PROXY}
      - TZ=\${XCHK_TZ}
    volumes:
      - status-data:/data
EOL
    fi

    if [ "$XCHK_SIDECAR" = "1" ] && [ -n "$XCHK_DOMAIN" ]; then
        cat >> "$XCHK_DIR/docker-compose.yml" <<EOL

  xray-checker-caddy:
    image: ${XCHK_SIDECAR_IMAGE}
    container_name: xray-checker-caddy
    hostname: xray-checker-caddy
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - xchk-caddy-data:/data
      - xchk-caddy-config:/config
EOL
        cat > "$XCHK_DIR/Caddyfile" <<EOL
$XCHK_DOMAIN {
    reverse_proxy 127.0.0.1:8080
}
EOL
    fi

    if grep -q "xchk-caddy-data" "$XCHK_DIR/docker-compose.yml"; then
        cat >> "$XCHK_DIR/docker-compose.yml" <<EOL

volumes:
  status-data:
  xchk-caddy-data:
  xchk-caddy-config:
EOL
    elif [ "$mode" = "bundle" ]; then
        cat >> "$XCHK_DIR/docker-compose.yml" <<EOL

volumes:
  status-data:
EOL
    fi

    chmod 600 "$XCHK_DIR/docker-compose.yml"
}

# --- Install / manage ----------------------------------------------------------

xchk_install() {
    if xchk_installed; then
        echo -e "${COLOR_YELLOW}${LANG[XCHK_ALREADY]}${COLOR_RESET}"
        return 1
    fi
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[XCHK_NO_DOCKER]}${COLOR_RESET}"
        return 1
    fi

    local port
    for port in 2112 8080 8081; do
        if xchk_port_busy "$port"; then
            echo -e "${COLOR_RED}$(printf "${LANG[XCHK_PORT_BUSY]}" "$port")${COLOR_RESET}"
            return 1
        fi
    done

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[XCHK_INSTALL_TITLE]}${COLOR_RESET}"
    echo -e ""

    # 1) bundle or checker-only
    local mode
    echo -e "${COLOR_GREEN}${LANG[XCHK_MODE_PROMPT_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[XCHK_MODE_BUNDLE]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[XCHK_MODE_BUNDLE_DESC]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[XCHK_MODE_CHECKER]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[XCHK_MODE_CHECKER_DESC]}${COLOR_RESET}"
    echo -e ""
    while true; do
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "2")" mode
        case "$mode" in
            1) mode="bundle"; break ;;
            2) mode="checker"; break ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "2" ;;
        esac
    done
    if [ "$mode" = "bundle" ]; then
        echo -e "${COLOR_GRAY}${LANG[XCHK_CREDITS_BUNDLE]}${COLOR_RESET}"
    else
        echo -e "${COLOR_GRAY}${LANG[XCHK_CREDITS_CHECKER]}${COLOR_RESET}"
    fi

    # 2) subscription source
    local panel_sub_url=""
    if panel_is_installed; then
        local sub_choice
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[XCHK_SUB_SOURCE_TITLE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. $(printf "${LANG[XCHK_SUB_AUTO]}" "$XCHK_MONITOR_USER")${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[XCHK_SUB_MANUAL]}${COLOR_RESET}"
        echo -e ""
        while true; do
            reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "2")" sub_choice
            case "$sub_choice" in
                1|2) break ;;
                *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "2" ;;
            esac
        done
        if [ "$sub_choice" = "1" ]; then
            xchk_ensure_monitor_user || return 1
            panel_sub_url="$XCHK_PANEL_SUB_URL"
        fi
    fi

    local sub_url
    if [ -n "$panel_sub_url" ]; then
        sub_url="$panel_sub_url"
    else
        local url_re='^https?://[A-Za-z0-9.:_~/?#%@&=+,-]+$'
        while true; do
            reading "${LANG[XCHK_SUB_URL_PROMPT]}" sub_url || return 0
            if [[ "$sub_url" =~ $url_re ]]; then
                break
            fi
            echo -e "${COLOR_RED}${LANG[XCHK_SUB_URL_INVALID]}${COLOR_RESET}"
        done
    fi

    # 3) Telegram bot (bundle only)
    if [ "$mode" = "bundle" ]; then
        echo -e ""
        while ! xchk_ask_tg; do
            local retry
            reading_yn "${LANG[XCHK_TG_RETRY]}" retry || return 1
        done
    fi

    # 4) interval + method
    local interval_input interval
    interval="$XCHK_CHECK_INTERVAL_DEFAULT"
    reading "$(printf "${LANG[XCHK_INTERVAL_PROMPT]}" "$XCHK_CHECK_INTERVAL_DEFAULT")" interval_input || return 0
    if [ -n "$interval_input" ]; then
        if ! [[ "$interval_input" =~ ^[0-9]+$ ]] || [ "$interval_input" -lt 30 ] || [ "$interval_input" -gt 86400 ]; then
            echo -e "${COLOR_RED}${LANG[XCHK_INTERVAL_INVALID]}${COLOR_RESET}"
            return 1
        fi
        interval="$interval_input"
    fi

    local method method_same_box=""
    # The ip method requires the proxy to CHANGE the exit IP — on a box that
    # also runs the node the exit is this very server, so every check would
    # fail by definition. Status checks fit both layouts.
    if { [ -f /opt/remnanode/docker-compose.yml ] && grep -q "^[[:space:]]*remnanode:" /opt/remnanode/docker-compose.yml; } || \
       { [ -f /opt/remnawave/docker-compose.yml ] && grep -q "^[[:space:]]*remnanode:" /opt/remnawave/docker-compose.yml; }; then
        method_same_box=1
    fi
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[XCHK_METHOD_TITLE]}${COLOR_RESET}"
    if [ -n "$method_same_box" ]; then
        echo -e "${COLOR_YELLOW}${LANG[XCHK_METHOD_SAMEBOX_NOTE]}${COLOR_RESET}"
    fi
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[XCHK_METHOD_IP]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[XCHK_METHOD_STATUS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[XCHK_METHOD_DOWNLOAD]}${COLOR_RESET}"
    echo -e ""
    local method_default=1
    [ -n "$method_same_box" ] && method_default=2
    while true; do
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "3")" method
        [ -z "$method" ] && method=$method_default
        case "$method" in
            1) method="ip"
               [ -n "$method_same_box" ] && echo -e "${COLOR_YELLOW}${LANG[XCHK_METHOD_SAMEBOX_WARN]}${COLOR_RESET}"
               break ;;
            2) method="status"; break ;;
            3) method="download"
               echo -e "${COLOR_YELLOW}${LANG[XCHK_METHOD_DOWNLOAD_WARN]}${COLOR_RESET}"
               break ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "3" ;;
        esac
    done

    # 5) status domain (bundle only — the page is the public part)
    XCHK_SIDECAR=0
    XCHK_DOMAIN=""
    if [ "$mode" = "bundle" ]; then
        echo -e ""
        xchk_prepare_domain || return 1
    else
        echo -e "${COLOR_YELLOW}${LANG[XCHK_METRICS_LOCAL]}${COLOR_RESET}"
    fi

    # 6) write + start
    xchk_write_stack "$mode" "$sub_url" "$interval" "$method" || return 1

    step_do "${LANG[XCHK_PULLING]}"
    (cd "$XCHK_DIR" && docker compose pull) >/dev/null 2>&1 &
    local pull_pid=$!
    spinner "$pull_pid" "${LANG[XCHK_PULLING]}"
    wait "$pull_pid"
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}${LANG[XCHK_PULL_FAIL]}${COLOR_RESET}"
        return 1
    fi

    step_do "${LANG[XCHK_STARTING]}"
    (cd "$XCHK_DIR" && docker compose up -d) >/dev/null 2>&1 &
    spinner $! "${LANG[XCHK_STARTING]}"

    # The stack exists from here on — record the state before any health
    # verdict, so uninstall can always undo the webserver edits even when
    # a container later turns out to be slow or broken.
    xchk_state_set "$mode" "$XCHK_DOMAIN" "${XCHK_CERT_DOMAIN:-}" "${XCHK_MOUNTS_ADDED:-0}" "$XCHK_WS_KIND"

    # Checker and page get separate verdicts: a slow page must not fail the
    # whole install — the checker (the monitoring itself) may already be
    # fully functional. The wait runs behind a spinner so the install does
    # not look dead for the full window.
    local health_pid health_rc=0
    (
        i_checker_ok=false
        i_page_ok=false
        for i_iter in $(seq 1 60); do
            sleep 2
            if ! $i_checker_ok && curl -s -o /dev/null --max-time 3 http://127.0.0.1:2112/metrics 2>/dev/null; then
                i_checker_ok=true
            fi
            if [ "$mode" = "bundle" ]; then
                if ! $i_page_ok && curl -s -o /dev/null --max-time 3 http://127.0.0.1:8080 2>/dev/null; then
                    i_page_ok=true
                fi
                $i_checker_ok && $i_page_ok && break
            else
                $i_checker_ok && break
            fi
        done
        $i_checker_ok || exit 1
        { [ "$mode" = "bundle" ] && ! $i_page_ok; } && exit 2
        exit 0
    ) &
    health_pid=$!
    spinner "$health_pid" "${LANG[XCHK_HEALTH_WAITING]}"
    wait "$health_pid" || health_rc=$?
    if [ "$health_rc" -eq 1 ]; then
        echo -e "${COLOR_RED}${LANG[XCHK_HEALTH_FAIL]}${COLOR_RESET}"
        docker logs --tail 20 xray-checker 2>&1 | sed 's/^/  /'
        return 1
    fi
    step_ok "${LANG[XCHK_HEALTH_OK]}"
    if [ "$health_rc" -eq 2 ]; then
        echo -e "${COLOR_YELLOW}${LANG[XCHK_HEALTH_PAGE_SLOW]}${COLOR_RESET}"
        docker logs --tail 20 xray-checker-statuspage 2>&1 | sed 's/^/  /'
    fi

    # 8) final banner
    echo -e ""
    echo -e "${COLOR_GREEN}=== ${LANG[XCHK_DONE_TITLE]} ===${COLOR_RESET}"
    echo -e ""
    if [ "$mode" = "bundle" ]; then
        if [ -n "$XCHK_DOMAIN" ]; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[XCHK_DONE_PUBLIC]}" "$XCHK_DOMAIN")${COLOR_RESET}"
            echo -e "${COLOR_WHITE}https://${XCHK_DOMAIN}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[XCHK_DOMAIN_NONE]}${COLOR_RESET}"
        fi
        if [ -n "$panel_sub_url" ]; then
            echo -e ""
            echo -e "${COLOR_YELLOW}$(printf "${LANG[XCHK_DONE_SUB_NOTE]}" "$XCHK_MONITOR_USER")${COLOR_RESET}"
            echo -e "${COLOR_WHITE}$panel_sub_url${COLOR_RESET}"
        fi
        if [ -n "$XCHK_TG_TOKEN_VAL" ]; then
            echo -e ""
            echo -e "${COLOR_YELLOW}${LANG[XCHK_DONE_TG_NOTE]}${COLOR_RESET}"
        fi
    else
        echo -e "${COLOR_YELLOW}${LANG[XCHK_METRICS_LOCAL]}${COLOR_RESET}"
    fi
    echo -e ""
    echo -e "${COLOR_GRAY}${LANG[XCHK_CREDITS]}${COLOR_RESET}"
    echo -e ""
}

xchk_status() {
    echo -e "${COLOR_GREEN}=== ${LANG[XCHK_STATUS_TITLE]} ===${COLOR_RESET}"
    echo -e ""

    local mode domain
    mode=$(xchk_state_get "mode")
    domain=$(xchk_state_get "domain")

    if xchk_container_up xray-checker; then
        echo -e " Xray Checker: ${COLOR_GREEN}${LANG[XCHK_RUNNING]}${COLOR_RESET} (127.0.0.1:2112)"
    else
        echo -e " Xray Checker: ${COLOR_RED}${LANG[XCHK_STOPPED]}${COLOR_RESET}"
    fi
    if [ "$mode" = "bundle" ]; then
        echo -e " ${LANG[XCHK_STATUS_MODE]}: ${LANG[XCHK_MODE_BUNDLE]}"
        if xchk_container_up xray-checker-statuspage; then
            echo -e " ${LANG[XCHK_STATUS_PAGE]}: ${COLOR_GREEN}${LANG[XCHK_RUNNING]}${COLOR_RESET} (127.0.0.1:8080)"
        else
            echo -e " ${LANG[XCHK_STATUS_PAGE]}: ${COLOR_RED}${LANG[XCHK_STOPPED]}${COLOR_RESET}"
        fi
        if [ -n "$domain" ]; then
            echo -e " ${LANG[XCHK_STATUS_DOMAIN]}: ${COLOR_WHITE}https://$domain${COLOR_RESET}"
        else
            echo -e " ${COLOR_GRAY}${LANG[XCHK_STATUS_LOCAL]}${COLOR_RESET}"
        fi
    elif [ "$mode" = "checker" ]; then
        echo -e " ${LANG[XCHK_STATUS_MODE]}: ${LANG[XCHK_MODE_CHECKER]}"
    fi

    echo -e ""
    echo -e "${COLOR_GRAY}${LANG[XCHK_STATUS_LOGS_HEAD]}${COLOR_RESET}"
    docker logs --tail 15 xray-checker 2>&1 | sed 's/^/  /'
    echo -e ""
}

xchk_restart() {
    step_do "${LANG[XCHK_RESTARTING]}"
    (cd "$XCHK_DIR" && docker compose up -d) >/dev/null 2>&1 &
    spinner $! "${LANG[XCHK_RESTARTING]}"
    xchk_container_up xray-checker \
        && step_ok "${LANG[XCHK_RESTARTED]}" \
        || echo -e "${COLOR_RED}${LANG[XCHK_HEALTH_FAIL]}${COLOR_RESET}"
}

xchk_update() {
    step_do "${LANG[XCHK_UPDATING]}"
    (cd "$XCHK_DIR" && docker compose pull) >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[XCHK_UPDATE_FAIL]}" "docker compose pull")${COLOR_RESET}"
        return 1
    fi
    (cd "$XCHK_DIR" && docker compose up -d) >/dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    step_ok "${LANG[XCHK_UPDATED]}"
}

xchk_uninstall() {
    local confirm
    if ! reading_yn "$(printf "${LANG[XCHK_UNINSTALL_CONFIRM]}" "$XCHK_MONITOR_USER")" confirm; then
        return 0
    fi
    step_do "${LANG[XCHK_UNINSTALLING]}"

    local ws kind dir
    if ws=$(xchk_webserver); then
        kind="${ws%% *}"
        dir="${ws#* }"
        if [ "$kind" = "nginx" ]; then
            xchk_unwire_nginx "$dir"
        else
            xchk_unwire_caddy "$dir"
        fi
    fi

    (cd "$XCHK_DIR" 2>/dev/null && docker compose down -v --remove-orphans) >/dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    rm -rf "$XCHK_DIR"
    xchk_state_clear
    step_ok "${LANG[XCHK_UNINSTALLED]}"
}

show_xray_checker_menu() {
    local mode_label domain
    if xchk_installed; then
        if xchk_container_up xray-checker; then
            status_color="$COLOR_GREEN"; status_text="${LANG[XCHK_RUNNING]}"
        else
            status_color="$COLOR_RED"; status_text="${LANG[XCHK_STOPPED]}"
        fi
    else
        status_color="$COLOR_GRAY"; status_text="${LANG[XCHK_NOT_INSTALLED]}"
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[XCHK_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e " ${status_color}${LANG[XCHK_MENU_TITLE]}: ${status_text}${COLOR_RESET}"
    # Authors ride along in the menu itself — the About entry is gone, and
    # the credit must survive whatever subset is installed.
    if xchk_with_statuspage; then
        echo -e " ${COLOR_GRAY}${LANG[XCHK_CREDITS_BUNDLE]}${COLOR_RESET}"
    elif xchk_installed; then
        echo -e " ${COLOR_GRAY}${LANG[XCHK_CREDITS_CHECKER]}${COLOR_RESET}"
    fi
    echo -e ""

    local last=1
    if xchk_installed; then
        echo -e "${COLOR_YELLOW}1. ${LANG[XCHK_MENU_STATUS]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[XCHK_MENU_RESTART]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[XCHK_MENU_UPDATE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}4. ${LANG[XCHK_MENU_UNINSTALL]}${COLOR_RESET}"
        last=4
    else
        echo -e "${COLOR_YELLOW}1. ${LANG[XCHK_MENU_INSTALL]}${COLOR_RESET}"
    fi
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""

    local xchk_option
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" xchk_option

    if xchk_installed; then
        case $xchk_option in
            1) xchk_status; sleep 2; show_xray_checker_menu ;;
            2) xchk_restart; sleep 2; show_xray_checker_menu ;;
            3) xchk_update; sleep 2; show_xray_checker_menu ;;
            4) xchk_uninstall; sleep 2; show_xray_checker_menu ;;
            0) echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}" ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
               sleep 1
               show_xray_checker_menu ;;
        esac
    else
        case $xchk_option in
            1) xchk_install; sleep 2; show_xray_checker_menu ;;
            0) echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}" ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
               sleep 1
               show_xray_checker_menu ;;
        esac
    fi
}

manage_xray_checker() {
    # The single entry point: on a Docker-less box (a fresh monitoring VPS)
    # it offers to bring the base components up first, absorbing what the
    # removed install-menu role used to do.
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        local setup
        echo -e "${COLOR_YELLOW}${LANG[XCHK_NO_DOCKER]}${COLOR_RESET}"
        if ! reading_yn "${LANG[XCHK_DOCKER_INSTALL]}" setup; then
            return 0
        fi
        install_packages || {
            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
            return 1
        }
    fi
    show_xray_checker_menu
}
