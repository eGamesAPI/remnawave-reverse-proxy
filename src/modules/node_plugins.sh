#!/bin/bash
# Module: Node Plugins — Torrent Blocker management via the panel API.

NP_PLUGIN_NAME="Torrent Blocker"
NP_PANEL_HOST="127.0.0.1:3000"
NP_DEFAULT_DURATION=3600

np_api() {
    local method="$1" path="$2" data="${3:-}"
    make_api_request "$method" "http://${NP_PANEL_HOST}${path}" "$token" "$data"
}

# Sync/executor return 202 with an empty body; anything JSON-shaped carrying
# statusCode/message at the top level is an API error.
np_accepted() {
    local body="${1:-}"
    [ -z "$body" ] && return 0
    if echo "$body" | jq -e 'has("statusCode") or has("message")' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

np_fetch_plugins() {
    np_plugins_json=""
    local response
    response=$(np_api "GET" "/api/node-plugins")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.nodePlugins' >/dev/null 2>&1; then
        return 1
    fi
    np_plugins_json=$(echo "$response" | jq -c '.response.nodePlugins')
    return 0
}

# The plugin that owns torrentBlocker — matched by config section first, name
# second, so a plugin renamed in the panel UI is still found. Sets np_uuid,
# np_name and np_config_json; np_uuid stays empty when there is no such plugin.
np_select_tb_plugin() {
    np_uuid=""
    np_name="$NP_PLUGIN_NAME"
    np_config_json="{}"
    local match
    match=$(echo "$np_plugins_json" | jq -c --arg name "$NP_PLUGIN_NAME" \
        '[.[] | select(((.pluginConfig // {}) | has("torrentBlocker")) or .name == $name)][0] // empty' 2>/dev/null)
    if [ -n "$match" ]; then
        np_uuid=$(echo "$match" | jq -r '.uuid // empty')
        np_name=$(echo "$match" | jq -r --arg fallback "$NP_PLUGIN_NAME" '.name // $fallback')
        np_config_json=$(echo "$match" | jq -c '.pluginConfig // {}')
    fi
}

np_refresh_tb_plugin() {
    np_fetch_plugins || return 1
    np_select_tb_plugin
}

# Current torrentBlocker state: on | off | absent | unknown.
np_state() {
    if ! np_fetch_plugins; then
        echo "unknown"
        return
    fi
    np_select_tb_plugin
    if [ -z "$np_uuid" ]; then
        echo "absent"
    elif echo "$np_config_json" | jq -e '.torrentBlocker.enabled == true' >/dev/null 2>&1; then
        echo "on"
    else
        echo "off"
    fi
}

np_ensure_plugin() {
    [ -n "$np_uuid" ] && return 0
    local response
    response=$(np_api "POST" "/api/node-plugins" "$(jq -n --arg name "$NP_PLUGIN_NAME" '{name: $name}')")
    np_uuid=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -z "$np_uuid" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_CREATE_FAIL]}" "$response")${COLOR_RESET}"
        return 1
    fi
    np_config_json="{}"
    return 0
}

# PATCH the full pluginConfig and push it to the connected nodes.
np_apply_config() {
    local config="$1"
    local body response sync_response
    body=$(jq -n --arg uuid "$np_uuid" --arg name "$np_name" --argjson cfg "$config" \
        '{uuid: $uuid, name: $name, pluginConfig: $cfg}')
    response=$(np_api "PATCH" "/api/node-plugins" "$body")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_UPDATE_FAIL]}" "$response")${COLOR_RESET}"
        return 1
    fi
    sync_response=$(np_api "POST" "/api/node-plugins/actions/sync" "$(jq -n --arg uuid "$np_uuid" '{uuid: $uuid}')")
    if ! np_accepted "$sync_response"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_SYNC_FAIL]}" "$sync_response")${COLOR_RESET}"
        return 1
    fi
    return 0
}

np_current_duration() {
    echo "$np_config_json" | jq -r ".torrentBlocker.blockDuration // $NP_DEFAULT_DURATION"
}

np_current_ips() {
    echo "$np_config_json" | jq -r '(.torrentBlocker.ignoreLists.ip // []) | join(", ")'
}

np_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local octet
    for octet in "${BASH_REMATCH[@]:1}"; do
        (( octet <= 255 )) || return 1
    done
}

np_valid_ip() {
    np_valid_ipv4 "$1" && return 0
    # Loose IPv6 check: hex digits and colons only, at least two colons.
    [[ "$1" == *:* && "$1" =~ ^[0-9a-fA-F:]+$ ]] && [[ "$(echo "$1" | tr -cd ':')" == *:*:* ]]
}

np_toggle() {
    local new_enabled="$1"
    if ! np_refresh_tb_plugin; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    if [ "$new_enabled" = "true" ]; then
        step_do "${LANG[NP_ENABLING]}"
    else
        step_do "${LANG[NP_DISABLING]}"
    fi
    local config
    config=$(echo "$np_config_json" | jq -c --argjson enabled "$new_enabled" '
        .torrentBlocker = ((.torrentBlocker // {enabled: false, ignoreLists: {ip: [], userId: []}, blockDuration: 3600})
            | .enabled = $enabled)')
    if ! np_apply_config "$config"; then
        return 1
    fi
    if [ "$new_enabled" = "true" ]; then
        step_ok "${LANG[NP_ENABLED_OK]}"
        echo -e "${COLOR_YELLOW}${LANG[NP_REQUIREMENTS_NOTE]}${COLOR_RESET}"
    else
        step_ok "${LANG[NP_DISABLED_OK]}"
    fi
}

np_settings() {
    if ! np_refresh_tb_plugin; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1

    local duration=$(np_current_duration)
    local ips=$(np_current_ips)
    local ips_display="$ips"
    [ -z "$ips_display" ] && ips_display="${LANG[NP_NO_IPS]}"

    step_do "${LANG[NP_SETTINGS_TITLE]}"

    local duration_input
    reading "$(printf "${LANG[NP_DURATION_PROMPT]}" "$duration")" duration_input
    if [ -n "$duration_input" ]; then
        if ! [[ "$duration_input" =~ ^[0-9]+$ ]] || [ "$duration_input" -le 0 ]; then
            echo -e "${COLOR_RED}${LANG[NP_INVALID_DURATION]}${COLOR_RESET}"
            return 1
        fi
        duration=$duration_input
    fi

    local ips_input ips_json
    reading "$(printf "${LANG[NP_IPS_PROMPT]}" "$ips_display")" ips_input
    if [ -z "$ips_input" ]; then
        ips_json=$(echo "$np_config_json" | jq -c '.torrentBlocker.ignoreLists.ip // []')
    elif [ "$ips_input" = "-" ]; then
        ips_json="[]"
    else
        local ips=() entry
        read -ra ips <<< "${ips_input//,/ }"
        local valid_ips=()
        for entry in "${ips[@]}"; do
            [ -z "$entry" ] && continue
            if ! np_valid_ip "$entry"; then
                echo -e "${COLOR_RED}$(printf "${LANG[NP_INVALID_IP]}" "$entry")${COLOR_RESET}"
                return 1
            fi
            valid_ips+=("$entry")
        done
        if [ "${#valid_ips[@]}" -eq 0 ]; then
            ips_json="[]"
        else
            ips_json=$(printf '%s\n' "${valid_ips[@]}" | jq -R . | jq -s .)
        fi
    fi

    local config
    config=$(echo "$np_config_json" | jq -c --argjson duration "$duration" --argjson ips "$ips_json" '
        .torrentBlocker = ((.torrentBlocker // {enabled: false, ignoreLists: {ip: [], userId: []}, blockDuration: 3600})
            | .blockDuration = $duration | .ignoreLists.ip = $ips)')
    if np_apply_config "$config"; then
        step_ok "${LANG[NP_SETTINGS_SAVED]}"
    fi
}

np_stats() {
    step_do "${LANG[NP_STATS_TITLE]}"
    local response
    response=$(np_api "GET" "/api/node-plugins/torrent-blocker/stats")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.stats' >/dev/null 2>&1; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "$response")${COLOR_RESET}"
        return 1
    fi

    local total last24 users nodes top_users top_nodes
    total=$(echo "$response" | jq -r '.response.stats.totalReports')
    last24=$(echo "$response" | jq -r '.response.stats.reportsLast24Hours')
    users=$(echo "$response" | jq -r '.response.stats.distinctUsers')
    nodes=$(echo "$response" | jq -r '.response.stats.distinctNodes')
    echo -e " ${LANG[NP_TOTAL_REPORTS]} ${COLOR_GREEN}${total}${COLOR_RESET}   ${LANG[NP_LAST24]} ${COLOR_GREEN}${last24}${COLOR_RESET}   ${LANG[NP_DISTINCT_USERS]} ${COLOR_GREEN}${users}${COLOR_RESET}   ${LANG[NP_DISTINCT_NODES]} ${COLOR_GREEN}${nodes}${COLOR_RESET}"

    top_users=$(echo "$response" | jq -r '.response.topUsers[:5][]? | "\(.username) - \(.total)"')
    if [ -n "$top_users" ]; then
        echo -e ""
        echo -e " ${LANG[NP_TOP_USERS]}"
        while IFS= read -r line; do
            echo -e "   ${COLOR_YELLOW}${line}${COLOR_RESET}"
        done <<< "$top_users"
    fi
    top_nodes=$(echo "$response" | jq -r '.response.topNodes[:5][]? | "\(.name) - \(.total)"')
    if [ -n "$top_nodes" ]; then
        echo -e ""
        echo -e " ${LANG[NP_TOP_NODES]}"
        while IFS= read -r line; do
            echo -e "   ${COLOR_YELLOW}${line}${COLOR_RESET}"
        done <<< "$top_nodes"
    fi

    local reports
    reports=$(np_api "GET" "/api/node-plugins/torrent-blocker?start=0&size=15")
    if [ -n "$reports" ] && echo "$reports" | jq -e '.response.records' >/dev/null 2>&1; then
        local records_total
        records_total=$(echo "$reports" | jq -r '.response.total // 0')
        echo -e ""
        if [ "$records_total" = "0" ]; then
            echo -e " ${LANG[NP_NO_REPORTS]}"
        else
            echo -e " ${LANG[NP_RECENT_TITLE]}"
            echo -e "   ${COLOR_GRAY}$(printf "    %-17s %-16s %-41s %s" "${LANG[NP_TH_DATE]}" "${LANG[NP_TH_USER]}" "${LANG[NP_TH_IP]}" "${LANG[NP_TH_NODE]}")${COLOR_RESET}"
            echo "$reports" | jq -r '.response.records[] | [.createdAt, .user.username, .report.actionReport.ip, .node.name] | @tsv' |
                while IFS=$'\t' read -r created user ip node_name; do
                    printf "    %-17s %-16s %-41s %s\n" "${created:0:16}" "$user" "$ip" "$node_name"
                done
        fi
    fi
}

np_unblock_ip() {
    local unblock_ip
    reading "${LANG[NP_UNBLOCK_PROMPT]}" unblock_ip
    [ -z "$unblock_ip" ] && return 0
    if ! np_valid_ip "$unblock_ip"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_INVALID_IP]}" "$unblock_ip")${COLOR_RESET}"
        return 1
    fi
    step_do "$(printf "${LANG[NP_UNBLOCKING]}" "$unblock_ip")"
    local body response
    body=$(jq -n --arg ip "$unblock_ip" \
        '{command: {command: "unblockIps", ips: [$ip]}, targetNodes: {target: "allNodes"}}')
    response=$(np_api "POST" "/api/node-plugins/executor" "$body")
    if np_accepted "$response"; then
        step_ok "$(printf "${LANG[NP_UNBLOCK_OK]}" "$unblock_ip")"
    else
        echo -e "${COLOR_RED}$(printf "${LANG[NP_EXEC_FAIL]}" "$response")${COLOR_RESET}"
    fi
}

np_recreate_tables() {
    local confirm
    if ! reading_yn "${LANG[NP_RECREATE_CONFIRM]}" confirm; then
        return 0
    fi
    step_do "${LANG[NP_RECREATING]}"
    local body response
    body=$(jq -n '{command: {command: "recreateTables"}, targetNodes: {target: "allNodes"}}')
    response=$(np_api "POST" "/api/node-plugins/executor" "$body")
    if np_accepted "$response"; then
        step_ok "${LANG[NP_RECREATE_OK]}"
    else
        echo -e "${COLOR_RED}$(printf "${LANG[NP_EXEC_FAIL]}" "$response")${COLOR_RESET}"
    fi
}

show_node_plugins_menu() {
    local state
    state=$(np_state)

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NP_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    local status_color="$COLOR_RED" status_text="${LANG[NP_STATUS_UNKNOWN]}"
    case $state in
        on)     status_color="$COLOR_GREEN"; status_text="${LANG[NP_STATUS_ON]}" ;;
        off)    status_color="$COLOR_YELLOW"; status_text="${LANG[NP_STATUS_OFF]}" ;;
        absent) status_color="$COLOR_GRAY"; status_text="${LANG[NP_STATUS_ABSENT]}" ;;
    esac
    echo -e " ${status_color}${LANG[NP_TB_LABEL]}: ${status_text}${COLOR_RESET}"
    echo -e ""

    if [ "$state" = "on" ]; then
        echo -e "${COLOR_YELLOW}1. ${LANG[NP_TOGGLE_OFF]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}1. ${LANG[NP_TOGGLE_ON]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_YELLOW}2. ${LANG[NP_SETTINGS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[NP_STATS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[NP_UNBLOCK]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[NP_RECREATE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=5
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" NP_OPTION

    case $NP_OPTION in
        1)
            if [ "$state" = "on" ]; then
                np_toggle "false"
            else
                np_toggle "true"
            fi
            sleep 2
            show_node_plugins_menu
            ;;
        2)
            np_settings
            sleep 2
            show_node_plugins_menu
            ;;
        3)
            np_stats
            sleep 3
            show_node_plugins_menu
            ;;
        4)
            np_unblock_ip
            sleep 2
            show_node_plugins_menu
            ;;
        5)
            np_recreate_tables
            sleep 2
            show_node_plugins_menu
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_node_plugins_menu
            ;;
    esac
}

manage_node_plugins() {
    if ! panel_is_installed; then
        echo -e "${COLOR_YELLOW}${LANG[NP_PANEL_REQUIRED]}${COLOR_RESET}"
        sleep 2
        return
    fi
    # get_panel_token mentions the panel domain in its OAuth instructions.
    if [ -z "$PANEL_DOMAIN" ]; then
        PANEL_DOMAIN=$(grep -h '^PANEL_DOMAIN=' /opt/remnawave/.env /opt/remnawave/docker-compose.yml 2>/dev/null | head -n1 \
            | sed -e 's/^PANEL_DOMAIN=//' -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" -e 's/[[:space:]]*$//')
    fi
    if ! get_panel_token; then
        echo -e "${COLOR_RED}${LANG[NP_TOKEN_FAIL]}${COLOR_RESET}"
        sleep 2
        return
    fi
    show_node_plugins_menu
}
