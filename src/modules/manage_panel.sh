#!/bin/bash
# Module: Manage Panel

show_manage_panel_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_3]}${COLOR_RESET}"
    echo -e ""
    show_panel_upgrade_notice nohint
    echo -e "${COLOR_YELLOW}1. ${LANG[START_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[STOP_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[UPDATE_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[VIEW_LOGS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[REMNAWAVE_CLI]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. ${LANG[ACCESS_PANEL]}${COLOR_RESET}"

    # Both extra entries act on a panel, so a node-only box sees neither and its
    # menu stays exactly what it was. The upgrade entry additionally appears only
    # while there is something to upgrade, and the entry below it takes the freed
    # number rather than leaving a hole in the list.
    local last=6
    local opt_upgrade="__none__"
    local opt_minclientver="__none__"

    if panel_is_installed; then
        if panel_needs_v3_migration; then
            last=$((last + 1))
            opt_upgrade=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[UPGRADE_PANEL_V3]}${COLOR_RESET}"
        fi

        last=$((last + 1))
        opt_minclientver=$last
        echo -e "${COLOR_YELLOW}${last}. ${LANG[MINCLIENTVER_MENU]}${COLOR_RESET}"
    fi

    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" SUB_OPTION

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
        "$opt_upgrade")
            upgrade_panel_to_v3
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        "$opt_minclientver")
            set_reality_min_client_ver
            sleep 2
            log_clear
            show_manage_panel_menu
            ;;
        0)
            remnawave_reverse
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_manage_panel_menu
            ;;
    esac
}

remnawave_container_running() {
    docker ps --format '{{.Names}}' | grep -qE '^(remnawave|remnanode)$'
}

run_remnawave_cli() {
    if ! docker ps --format '{{.Names}}' | grep -q '^remnawave$'; then
        echo -e "${COLOR_YELLOW}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        return 1
    fi

    exec 3>&1 4>&2
    exec > /dev/tty 2>&1

    echo -e "${COLOR_YELLOW}${LANG[RUNNING_CLI]}${COLOR_RESET}"
    local cli_bin="remnawave"
    if docker exec remnawave sh -c 'command -v cli' > /dev/null 2>&1; then
        cli_bin="cli"
    fi
    if docker exec -it -e TERM=xterm-256color remnawave "$cli_bin"; then
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

    if remnawave_container_running; then
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
    if ! remnawave_container_running; then
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

    if [ "$dir" = "/opt/remnawave" ] && panel_needs_v3_migration "$dir"; then
        echo -e "${COLOR_YELLOW}${LANG[UPGRADE_REQUIRED_V3]}${COLOR_RESET}"
        return 1
    fi

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

# Read a single key from an .env-style file without sourcing it.
read_env_value() {
    local file="$1"
    local key="$2"
    [ -f "$file" ] || return 1
    sed -n "s/^${key}=//p" "$file" | head -n 1 | sed -e 's/^"//' -e 's/"$//'
}

# The first 3.x boot runs prisma migrations and seeders before the app listens,
# so a short health deadline is really a migration deadline: interrupting it can
# leave a failed row in _prisma_migrations that blocks every later deploy.
# Wait generously, and fail fast only on the two states that mean "it is dead":
# the container exited, or restart: always is looping it.
wait_for_container_health() {
    local name="$1"
    local timeout="${2:-300}"
    local waited=0
    local state=""
    local health=""
    local restarts=""

    while [ "$waited" -lt "$timeout" ]; do
        state=$(docker inspect --format '{{.State.Status}}' "$name" 2>/dev/null)
        case "$state" in
            exited|dead)
                return 1
                ;;
        esac

        restarts=$(docker inspect --format '{{.RestartCount}}' "$name" 2>/dev/null)
        if [ -n "$restarts" ] && [ "$restarts" -gt 2 ] 2>/dev/null; then
            return 1
        fi

        health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null)
        if [ "$health" = "healthy" ]; then
            return 0
        fi
        if [ "$health" = "none" ] && [ "$state" = "running" ]; then
            return 0
        fi

        sleep 5
        waited=$((waited + 5))
    done

    return 1
}

# Move an installed panel from the 2.x line to 3.x.
upgrade_panel_to_v3() {
    local dir="/opt/remnawave"

    if [ ! -f "$dir/docker-compose.yml" ] || [ ! -f "$dir/.env" ]; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_NOT_A_PANEL]}${COLOR_RESET}"
        return 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; return 1; }

    local current_tag
    current_tag=$(sed -n 's|^[[:space:]]*image:[[:space:]]*remnawave/backend:\([^[:space:]]*\).*|\1|p' docker-compose.yml | head -n 1)
    if [ -z "$current_tag" ]; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_NOT_A_PANEL]}${COLOR_RESET}"
        return 1
    fi

    if ! panel_needs_v3_migration "$dir"; then
        printf "${COLOR_GREEN}${LANG[UPGRADE_ALREADY_V3]}${COLOR_RESET}\n" "$current_tag"
        return 0
    fi

    # 3.x reads one APP_SECRET where 2.x accepted JWT_AUTH_SECRET as a deprecated
    # alias for the same value. It signs sessions and API tokens and is mixed into
    # every admin password hash, so it has to be carried over, never regenerated.
    # A box that already carries APP_SECRET (added by hand, or by a previous run
    # that stopped before the tag moved) keeps the value it has.
    local app_secret
    app_secret=$(read_env_value .env APP_SECRET)
    if [ -z "$app_secret" ]; then
        app_secret=$(read_env_value .env JWT_AUTH_SECRET)
    fi
    if [ -z "$app_secret" ]; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_NO_SECRET]}${COLOR_RESET}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[UPGRADE_WARNING]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[UPGRADE_CONFIRM_PROMPT]}" upgrade_confirm
    if [ "$upgrade_confirm" != "upgrade" ]; then
        echo -e "${COLOR_YELLOW}${LANG[UPGRADE_CANCELLED]}${COLOR_RESET}"
        return 1
    fi

    local ts backup_dir pg_user pg_db
    ts=$(date +%Y%m%d-%H%M%S)
    backup_dir="$dir/backup/$ts"
    if ! mkdir -p "$backup_dir"; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_BACKUP_FAILED]}${COLOR_RESET}"
        return 1
    fi

    pg_user=$(read_env_value .env POSTGRES_USER)
    pg_user="${pg_user:-postgres}"
    pg_db=$(read_env_value .env POSTGRES_DB)
    pg_db="${pg_db:-postgres}"

    cp -a .env docker-compose.yml "$backup_dir/"
    [ -f nginx.conf ] && cp -a nginx.conf "$backup_dir/"
    [ -f Caddyfile ] && cp -a Caddyfile "$backup_dir/"
    docker compose images > "$backup_dir/images-before.txt" 2>&1

    echo -e "${COLOR_YELLOW}${LANG[UPGRADE_BACKUP]}${COLOR_RESET}"
    docker compose up -d remnawave-db > /dev/null 2>&1
    if ! wait_for_container_health remnawave-db 120; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_BACKUP_FAILED]}${COLOR_RESET}"
        return 1
    fi
    # The 3.x migration chain rewrites tables, so it needs room for a second copy
    # of the data, and the dump below lands on disk too. Running out midway leaves
    # prisma with a failed migration row that blocks every later start, panel and
    # rollback alike.
    local db_bytes need_kb free_kb docker_root
    db_bytes=$(docker compose exec -T remnawave-db psql -U "$pg_user" -d "$pg_db" -tAc "SELECT pg_database_size('$pg_db')" 2>/dev/null | tr -dc '0-9')
    [ -n "$db_bytes" ] || db_bytes=0
    need_kb=$(( db_bytes / 1024 * 3 + 524288 ))
    docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)
    for fs in "$dir" "${docker_root:-$dir}"; do
        free_kb=$(df -Pk "$fs" 2>/dev/null | awk 'NR==2 {print $4}')
        [ -n "$free_kb" ] || continue
        if [ "$free_kb" -lt "$need_kb" ] 2>/dev/null; then
            printf "${COLOR_RED}${LANG[UPGRADE_NO_DISK_SPACE]}${COLOR_RESET}\n" \
                "$fs" "$((free_kb / 1024))" "$((need_kb / 1024))"
            return 1
        fi
    done

    if ! docker compose exec -T remnawave-db pg_dump -U "$pg_user" -d "$pg_db" -Fc --no-owner --no-privileges > "$backup_dir/remnawave-db.dump" 2> "$backup_dir/pg_dump.log"; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_BACKUP_FAILED]}${COLOR_RESET}"
        cat "$backup_dir/pg_dump.log"
        return 1
    fi
    if [ ! -s "$backup_dir/remnawave-db.dump" ]; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_BACKUP_FAILED]}${COLOR_RESET}"
        return 1
    fi
    printf "${COLOR_GREEN}${LANG[UPGRADE_BACKUP_OK]}${COLOR_RESET}\n" "$backup_dir"

    # Append only: the 2.x keys stay in place so the backed-up .env is a working
    # rollback, and 3.x silently ignores keys it does not know.
    if ! grep -q '^APP_SECRET=' .env; then
        {
            printf '\n### SECRETS ###\n'
            printf '# 3.x dropped the JWT_AUTH_SECRET alias. The value below is the same one\n'
            printf '# the panel already used, so admin logins and API tokens keep working.\n'
            printf 'APP_SECRET=%s\n' "$app_secret"
        } >> .env
    fi
    if ! grep -q '^PANEL_DOMAIN=' .env; then
        local front_end
        front_end=$(read_env_value .env FRONT_END_DOMAIN)
        if [ -n "$front_end" ] && [ "$front_end" != "*" ]; then
            printf 'PANEL_DOMAIN=%s\n' "$front_end" >> .env
        fi
    fi

    # :latest and :dev already resolve to a 3.x image, so only the pinned old
    # majors need the tag rewritten.
    case "$current_tag" in
        1|1.*|2|2.*)
            sed -i "s|image: remnawave/backend:${current_tag}|image: remnawave/backend:3|" docker-compose.yml
            if ! grep -qE '^[[:space:]]*image:[[:space:]]*remnawave/backend:3[[:space:]]*$' docker-compose.yml; then
                printf "${COLOR_RED}${LANG[UPGRADE_TAG_FAILED]}${COLOR_RESET}\n" "$backup_dir"
                return 1
            fi
            ;;
    esac

    echo -e "${COLOR_YELLOW}${LANG[UPGRADE_PULLING]}${COLOR_RESET}"
    if ! docker compose pull remnawave > "$backup_dir/pull.log" 2>&1; then
        # Nothing has been recreated yet, so put the compose file back rather
        # than leaving a :3 tag for the next unrelated "up" to apply.
        cp -a "$backup_dir/docker-compose.yml" ./docker-compose.yml
        printf "${COLOR_RED}${LANG[UPGRADE_PULL_FAILED]}${COLOR_RESET}\n" "$backup_dir"
        tail -n 10 "$backup_dir/pull.log"
        return 1
    fi

    # --no-deps keeps compose from walking the service_healthy dependencies of
    # the node and the subscription page while the first 3.x boot is still
    # migrating: it would declare the backend unhealthy after ~2 minutes and
    # abort, leaving both of them stopped.
    echo -e "${COLOR_YELLOW}${LANG[UPGRADE_STARTING]}${COLOR_RESET}"
    if ! docker compose up -d --no-deps --force-recreate remnawave > "$backup_dir/up.log" 2>&1; then
        printf "${COLOR_RED}${LANG[UPGRADE_FAILED]}${COLOR_RESET}\n"
        tail -n 20 "$backup_dir/up.log"
        rollback_panel_from_v3 "$backup_dir" "$pg_user" "$pg_db"
        return 1
    fi

    if ! wait_for_container_health remnawave 1800; then
        echo -e "${COLOR_RED}${LANG[UPGRADE_FAILED]}${COLOR_RESET}"
        docker compose logs --tail 60 remnawave
        rollback_panel_from_v3 "$backup_dir" "$pg_user" "$pg_db"
        return 1
    fi

    # Bring back whatever the recreate left behind: the subscription page and,
    # on a combined box, the node.
    docker compose up -d > "$backup_dir/up-rest.log" 2>&1

    local stopped
    stopped=$(docker compose ps --services --filter status=stopped 2>/dev/null | tr '\n' ' ')
    if [ -n "${stopped// /}" ]; then
        printf "${COLOR_RED}${LANG[UPGRADE_SERVICES_DOWN]}${COLOR_RESET}\n" "$stopped"
        tail -n 20 "$backup_dir/up-rest.log"
    fi

    local new_version
    new_version=$(docker exec remnawave cat /opt/app/package.json 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    printf "${COLOR_GREEN}${LANG[UPGRADE_SUCCESS]}${COLOR_RESET}\n" "${new_version:-3.x}"
    printf "${COLOR_YELLOW}${LANG[UPGRADE_NEXT_STEPS]}${COLOR_RESET}\n" "$backup_dir"
}

rollback_panel_from_v3() {
    local backup_dir="$1"
    local pg_user="$2"
    local pg_db="$3"
    local dir="/opt/remnawave"

    echo -e "${COLOR_YELLOW}${LANG[ROLLBACK_START]}${COLOR_RESET}"
    cd "$dir" || return 1

    docker compose down > "$backup_dir/rollback-down.log" 2>&1
    cp -a "$backup_dir/docker-compose.yml" "$backup_dir/.env" "$dir/"

    # The 3.x migrations are one-way. Putting 2.x code back on a migrated schema
    # is not a rollback, so restoring the dump is the default and declining it
    # leaves the stack down rather than half-restored.
    local restore_db=""
    reading "${LANG[ROLLBACK_DB_PROMPT]}" restore_db
    if [[ "$restore_db" =~ ^[nN] ]]; then
        printf "${COLOR_RED}${LANG[ROLLBACK_DB_SKIPPED]}${COLOR_RESET}\n" "$backup_dir"
        return 1
    fi

    docker compose up -d remnawave-db > /dev/null 2>&1
    if ! wait_for_container_health remnawave-db 120; then
        printf "${COLOR_RED}${LANG[ROLLBACK_FAILED]}${COLOR_RESET}\n" "$backup_dir"
        return 1
    fi

    # 3.x creates tables and types 2.x never knew about; dropping the schema is
    # the only way --clean cannot leave them behind.
    if ! docker compose exec -T remnawave-db psql -U "$pg_user" -d "$pg_db" -v ON_ERROR_STOP=1 -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;' > "$backup_dir/rollback-schema.log" 2>&1; then
        printf "${COLOR_RED}${LANG[ROLLBACK_FAILED]}${COLOR_RESET}\n" "$backup_dir"
        tail -n 20 "$backup_dir/rollback-schema.log"
        return 1
    fi
    if ! docker compose exec -T remnawave-db pg_restore -U "$pg_user" -d "$pg_db" --no-owner --no-privileges --exit-on-error < "$backup_dir/remnawave-db.dump" > "$backup_dir/pg_restore.log" 2>&1; then
        printf "${COLOR_RED}${LANG[ROLLBACK_FAILED]}${COLOR_RESET}\n" "$backup_dir"
        tail -n 20 "$backup_dir/pg_restore.log"
        return 1
    fi

    docker compose up -d > "$backup_dir/rollback-up.log" 2>&1
    if wait_for_container_health remnawave 300; then
        printf "${COLOR_GREEN}${LANG[ROLLBACK_DONE]}${COLOR_RESET}\n" "$backup_dir"
    else
        printf "${COLOR_RED}${LANG[ROLLBACK_FAILED]}${COLOR_RESET}\n" "$backup_dir"
    fi
}

# Write realitySettings.minClientVer = 0.0.0 into REALITY inbounds that do not
# define it. Xray-core >= 26.7.11 otherwise applies a default floor of 26.3.27
# and refuses any client below it, which covers mihomo, sing-box and older Happ.
# Note this lowers a floor rather than repairing anything: an operator who wants
# the floor should leave it alone, or set a version of their own.
set_reality_min_client_ver() {
    local domain_url="127.0.0.1:3000"

    echo -e "${COLOR_YELLOW}${LANG[MINCLIENTVER_EXPLAIN]}${COLOR_RESET}"
    echo -e ""

    if ! declare -F make_api_request > /dev/null 2>&1; then
        load_api_module || return 1
    fi

    if ! docker ps --format '{{.Names}}' | grep -q '^remnawave$'; then
        echo -e "${COLOR_RED}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        return 1
    fi

    get_panel_token || return 1
    local token
    token=$(cat "$TOKEN_FILE" 2>/dev/null)
    if [ -z "$token" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"
        return 1
    fi

    local profiles uuids
    profiles=$(make_api_request "GET" "http://$domain_url/api/config-profiles" "$token")
    if ! echo "$profiles" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[MINCLIENTVER_FAILED]}${COLOR_RESET}"
        return 1
    fi
    uuids=$(echo "$profiles" | jq -r '.response.configProfiles[] | .uuid')
    if [ -z "$uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[MINCLIENTVER_NONE]}${COLOR_RESET}"
        return 0
    fi

    local uuid profile missing preset config body response
    local patched=0
    local untouched=0
    local failed=0
    local custom=0

    while IFS= read -r uuid; do
        [ -n "$uuid" ] || continue

        profile=$(make_api_request "GET" "http://$domain_url/api/config-profiles/$uuid" "$token")
        if ! echo "$profile" | jq -e '.response.config' > /dev/null 2>&1; then
            failed=$((failed + 1))
            printf "${COLOR_RED}${LANG[MINCLIENTVER_PROFILE_FAILED]}${COLOR_RESET}\n" "$uuid"
            continue
        fi

        missing=$(echo "$profile" | jq '[.response.config.inbounds[]? | select(.streamSettings.security? == "reality") | select((.streamSettings.realitySettings | type) == "object") | select(.streamSettings.realitySettings | has("minClientVer") | not)] | length')
        preset=$(echo "$profile" | jq '[.response.config.inbounds[]? | select(.streamSettings.security? == "reality") | select((.streamSettings.realitySettings.minClientVer? // "0.0.0") != "0.0.0")] | length')
        [ -n "$preset" ] && [ "$preset" != "0" ] && custom=$((custom + 1))

        if [ -z "$missing" ] || [ "$missing" = "0" ]; then
            untouched=$((untouched + 1))
            continue
        fi

        config=$(echo "$profile" | jq '.response.config | .inbounds |= map(if (.streamSettings.security? == "reality") and ((.streamSettings.realitySettings | type) == "object") then (.streamSettings.realitySettings.minClientVer //= "0.0.0") else . end)')
        if [ -z "$config" ]; then
            failed=$((failed + 1))
            printf "${COLOR_RED}${LANG[MINCLIENTVER_PROFILE_FAILED]}${COLOR_RESET}\n" "$uuid"
            continue
        fi

        body=$(jq -n --arg uuid "$uuid" --argjson config "$config" '{uuid: $uuid, config: $config}')
        response=$(make_api_request "PATCH" "http://$domain_url/api/config-profiles" "$token" "$body")
        if echo "$response" | jq -e '.response.uuid' > /dev/null 2>&1; then
            patched=$((patched + 1))
        else
            failed=$((failed + 1))
            printf "${COLOR_RED}${LANG[MINCLIENTVER_PROFILE_FAILED]}${COLOR_RESET}\n" "$uuid"
        fi
    done <<< "$uuids"

    printf "${COLOR_GREEN}${LANG[MINCLIENTVER_DONE]}${COLOR_RESET}\n" "$patched" "$untouched" "$failed"
    if [ "$custom" -gt 0 ]; then
        printf "${COLOR_YELLOW}${LANG[MINCLIENTVER_CUSTOM]}${COLOR_RESET}\n" "$custom"
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

    if ! remnawave_container_running; then
        echo -e "${COLOR_RED}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        return 1
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
