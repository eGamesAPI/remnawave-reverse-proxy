#!/bin/bash
# Module: Node Plugins — Torrent Blocker, Ingress Filter and Egress Filter
# management via the panel API. Depends on the api module (make_api_request,
# get_panel_token) being loaded and on $token being set beforehand.

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
    # The ?_=<timestamp> cache-buster keeps the status line honest: the panel
    # caches this GET, and without it the menu showed a stale state right
    # after enabling/disabling.
    response=$(np_api "GET" "/api/node-plugins?_=$(date +%s)")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.nodePlugins' >/dev/null 2>&1; then
        return 1
    fi
    np_plugins_json=$(echo "$response" | jq -c '.response.nodePlugins')
    return 0
}

# The list endpoint serves pluginConfig as null on the real panel (the spec
# marks it nullable); the actual config only comes from the per-plugin
# endpoint. Fetch it by uuid after the plugin was picked from the list.
np_fetch_plugin_config() {
    local response
    response=$(np_api "GET" "/api/node-plugins/${np_uuid}")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response' >/dev/null 2>&1; then
        return 1
    fi
    np_config_json=$(echo "$response" | jq -c '.response.pluginConfig // {}')
    return 0
}

# Pick a plugin by its config section first, plugin name second — so a plugin
# renamed in the panel UI is still found. Sets np_uuid, np_name and
# np_config_json; np_uuid stays empty when there is no such plugin.
np_select_plugin() {
    local section="$1" fallback_name="$2"
    np_uuid=""
    np_name="$fallback_name"
    np_config_json="{}"
    local match list_cfg
    match=$(echo "$np_plugins_json" | jq -c --arg name "$fallback_name" --arg section "$section" \
        '[.[] | select(((.pluginConfig // {}) | has($section)) or .name == $name)][0] // empty' 2>/dev/null)
    if [ -n "$match" ]; then
        np_uuid=$(echo "$match" | jq -r '.uuid // empty')
        np_name=$(echo "$match" | jq -r --arg fallback "$fallback_name" '.name // $fallback')
        list_cfg=$(echo "$match" | jq -c '.pluginConfig // {}')
        np_config_json="$list_cfg"
        np_fetch_plugin_config || np_config_json="$list_cfg"
    fi
}

np_refresh_plugin() {
    np_fetch_plugins || return 1
    np_select_plugin "$1" "$2"
}

# Enabled either as a JSON boolean or as the string the panel may normalize to.
np_tb_is_on() {
    echo "$np_config_json" | jq -e '.torrentBlocker.enabled == true or .torrentBlocker.enabled == "true"' >/dev/null 2>&1
}

# Current torrentBlocker state: on | off | absent | unknown.
np_state() {
    if ! np_refresh_plugin "torrentBlocker" "$NP_PLUGIN_NAME"; then
        echo "unknown"
        return
    fi
    if [ -z "$np_uuid" ]; then
        echo "absent"
    elif np_tb_is_on; then
        echo "on"
    else
        echo "off"
    fi
}

np_ensure_plugin() {
    [ -n "$np_uuid" ] && return 0
    local response
    response=$(np_api "POST" "/api/node-plugins" "$(jq -n --arg name "$np_name" '{name: $name}')")
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
    body=$(jq -n --arg uuid "$np_uuid" --argjson cfg "$config" \
        '{uuid: $uuid, pluginConfig: $cfg}')
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

# Plain IPv4 or IPv4/prefix-length (ingressFilter blockedIps entry format).
np_valid_cidr4() {
    local entry="$1" ip prefix
    ip="${entry%%/*}"
    np_valid_ipv4 "$ip" || return 1
    case "$entry" in
        */*)
            prefix="${entry##*/}"
            [[ "$prefix" =~ ^[0-9]{1,2}$ ]] || return 1
            (( 8 <= 10#$prefix && 10#$prefix <= 32 )) || return 1
            ;;
    esac
    return 0
}

np_toggle() {
    local new_enabled="$1"
    if ! np_refresh_plugin "torrentBlocker" "$NP_PLUGIN_NAME"; then
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
    # Re-read what the panel now serves; if it still returns the previous
    # state, say so instead of silently showing a wrong status in the menu.
    local now_on="false"
    if np_refresh_plugin "torrentBlocker" "$NP_PLUGIN_NAME" && [ -n "$np_uuid" ] && np_tb_is_on; then
        now_on="true"
    fi
    if [ "$now_on" != "$new_enabled" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NP_STATUS_PENDING]}${COLOR_RESET}"
    fi
}

np_settings() {
    if ! np_refresh_plugin "torrentBlocker" "$NP_PLUGIN_NAME"; then
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

np_delete() {
    if ! np_refresh_plugin "torrentBlocker" "$NP_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    if [ -z "$np_uuid" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NP_NOTHING_TO_DELETE]}${COLOR_RESET}"
        return 0
    fi
    local confirm
    if ! reading_yn "${LANG[NP_DELETE_CONFIRM]}" confirm; then
        return 0
    fi
    step_do "${LANG[NP_DELETING]}"
    local response
    response=$(np_api "DELETE" "/api/node-plugins/${np_uuid}")
    if np_accepted "$response"; then
        step_ok "${LANG[NP_DELETED_OK]}"
    else
        echo -e "${COLOR_RED}$(printf "${LANG[NP_DELETE_FAIL]}" "$response")${COLOR_RESET}"
    fi
}

# --- Ingress Filter: permanent inbound blocking with list presets -----------

IG_PLUGIN_NAME="Ingress Filter"
IG_STATE_FILE="${DIR_REMNAWAVE}ingress-preset.state"

ig_is_on() {
    echo "$np_config_json" | jq -e '.ingressFilter.enabled == true or .ingressFilter.enabled == "true"' >/dev/null 2>&1
}

ig_state() {
    if ! np_refresh_plugin "ingressFilter" "$IG_PLUGIN_NAME"; then
        echo "unknown"
        return
    fi
    if [ -z "$np_uuid" ]; then
        echo "absent"
    elif ig_is_on; then
        echo "on"
    else
        echo "off"
    fi
}

ig_entry_count() {
    echo "$np_config_json" | jq -r '.ingressFilter.blockedIps // [] | length'
}

ig_current_entries() {
    echo "$np_config_json" | jq -r '.ingressFilter.blockedIps // [] | .[]'
}

ig_apply_entries() {
    local entries="$1" arr config
    arr=$(printf '%s\n' "$entries" | sed '/^$/d' | jq -R . | jq -s .)
    config=$(echo "$np_config_json" | jq -c --argjson ips "$arr" \
        '.ingressFilter = ((.ingressFilter // {enabled: false, blockedIps: []}) | .blockedIps = $ips)')
    np_apply_config "$config"
}

# Mirror prefixes for raw.githubusercontent.com — the same set the script uses
# for its own downloads; GitHub itself is often unreachable from RU networks.
ig_mirror_prefixes() {
    printf '%s\n' "" "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/"
}

# One URL over all mirrors -> body on stdout. Garbage pages (a mirror's error
# interstitial, the origin's 404 text) are dropped later by the CIDR filter.
ig_fetch_url() {
    local url="$1" prefix body
    while IFS= read -r prefix; do
        if command -v curl >/dev/null 2>&1; then
            body=$(curl -sL $CURL_IP_FLAGS --connect-timeout 10 --max-time 60 "${prefix}${url}" 2>/dev/null)
        else
            body=$(wget $WGET_IP_FLAGS -q -T 10 -t 1 -O- "${prefix}${url}" 2>/dev/null)
        fi
        if [ -n "$body" ]; then
            printf '%s\n' "$body"
            return 0
        fi
    done < <(ig_mirror_prefixes)
    return 1
}

ig_preset_sources() {
    local base="https://raw.githubusercontent.com/OpenFilters/internet-scanners/main/cidr"
    case "$1" in
        ru)
            echo "https://raw.githubusercontent.com/tread-lightly/CyberOK_Skipa_ips/main/lists/skipa_cidr.txt"
            ;;
        classic)
            printf '%s\n' \
                "$base/censys_v4.txt" "$base/shodan_v4.txt" "$base/paloaltonetworks_v4.txt" \
                "$base/shadowserver_v4.txt" "$base/driftnet_v4.txt" "$base/onyphe_v4.txt" \
                "$base/zoomeye_v4.txt" "$base/leakix_v4.txt" "$base/rapid7_v4.txt" \
                "$base/internetmeasurementresearch_v4.txt"
            ;;
        fofa)
            printf '%s\n' "$base/fofa_v4.txt" "$base/quake_v4.txt"
            ;;
    esac
}

ig_preset_source_label() {
    case "$1" in
        ru) echo "github.com/tread-lightly/CyberOK_Skipa_ips" ;;
        *)  echo "github.com/OpenFilters/internet-scanners" ;;
    esac
}

ig_preset_state_get() {
    [ -r "$IG_STATE_FILE" ] || return 0
    awk -F'\t' -v id="$1" '$1 == id { print $2 }' "$IG_STATE_FILE"
}

ig_preset_state_set() {
    local id="$1" entries="$2" tmp entry
    tmp=$(mktemp)
    [ -r "$IG_STATE_FILE" ] && awk -F'\t' -v id="$id" '$1 != id' "$IG_STATE_FILE" > "$tmp"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        printf '%s\t%s\n' "$id" "$entry" >> "$tmp"
    done <<< "$entries"
    mv "$tmp" "$IG_STATE_FILE"
    chmod 600 "$IG_STATE_FILE" 2>/dev/null
}

# Download every file of a preset over mirrors (all-or-nothing) and keep only
# clean IPv4 / IPv4-CIDR lines.
ig_fetch_preset_entries() {
    local id="$1" url body entries=""
    while IFS= read -r url; do
        [ -z "$url" ] && continue
        body=$(ig_fetch_url "$url") || return 1
        entries+="$body"$'\n'
    done <<< "$(ig_preset_sources "$id")"
    IG_PRESET_ENTRIES=$(printf '%s' "$entries" | sed 's/\r//g' \
        | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$' | sort -u)
    IG_PRESET_COUNT=$(printf '%s\n' "$IG_PRESET_ENTRIES" | sed '/^$/d' | wc -l)
    [ "$IG_PRESET_COUNT" -gt 0 ] || return 1
    return 0
}

ig_preset_apply() {
    local id="$1"
    step_do "${LANG[IG_PRESET_DOWNLOADING]}"
    if ! ig_fetch_preset_entries "$id"; then
        echo -e "${COLOR_RED}${LANG[IG_PRESET_FETCH_FAIL]}${COLOR_RESET}"
        return 1
    fi
    if ! np_refresh_plugin "ingressFilter" "$IG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    local was_on="false"
    ig_is_on && was_on="true"

    echo -e " ${COLOR_GRAY}$(printf "${LANG[IG_PRESET_SOURCE_NOTE]}" "$(ig_preset_source_label "$id")")${COLOR_RESET}"
    local confirm
    if ! reading_yn "$(printf "${LANG[IG_PRESET_CONFIRM]}" "$IG_PRESET_COUNT")" confirm; then
        return 0
    fi

    # Replace only this preset's previous entries; manual entries and other
    # presets stay in place.
    local current old_preset merged
    current=$(ig_current_entries | sed '/^$/d' | sort -u)
    old_preset=$(ig_preset_state_get "$id" | sed '/^$/d' | sort -u)
    if [ -n "$old_preset" ]; then
        current=$(comm -23 <(printf '%s\n' "$current") <(printf '%s\n' "$old_preset"))
    fi
    merged=$(printf '%s\n%s\n' "$current" "$IG_PRESET_ENTRIES" | sed '/^$/d' | sort -u)

    if ! ig_apply_entries "$merged"; then
        return 1
    fi
    ig_preset_state_set "$id" "$IG_PRESET_ENTRIES"
    step_ok "$(printf "${LANG[IG_PRESET_APPLIED]}" "$IG_PRESET_COUNT")"
    if [ "$was_on" != "true" ]; then
        echo -e "${COLOR_YELLOW}${LANG[IG_PRESET_ENABLE_HINT]}${COLOR_RESET}"
    fi
}

ig_toggle() {
    local new_enabled="$1"
    if ! np_refresh_plugin "ingressFilter" "$IG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    if [ "$new_enabled" = "true" ]; then
        step_do "${LANG[IG_ENABLING]}"
    else
        step_do "${LANG[IG_DISABLING]}"
    fi
    local config
    config=$(echo "$np_config_json" | jq -c --argjson enabled "$new_enabled" \
        '.ingressFilter = ((.ingressFilter // {enabled: false, blockedIps: []}) | .enabled = $enabled)')
    if ! np_apply_config "$config"; then
        return 1
    fi
    if [ "$new_enabled" = "true" ]; then
        step_ok "${LANG[IG_ENABLED_OK]}"
        echo -e "${COLOR_YELLOW}${LANG[IG_NOTE]}${COLOR_RESET}"
    else
        step_ok "${LANG[IG_DISABLED_OK]}"
    fi
    local now_on="false"
    if np_refresh_plugin "ingressFilter" "$IG_PLUGIN_NAME" && [ -n "$np_uuid" ] && ig_is_on; then
        now_on="true"
    fi
    if [ "$now_on" != "$new_enabled" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NP_STATUS_PENDING]}${COLOR_RESET}"
    fi
}

ig_manual_add() {
    if ! np_refresh_plugin "ingressFilter" "$IG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    local ig_input entries=() entry merged total
    reading "${LANG[IG_ADD_PROMPT]}" ig_input || return 0
    [ "$ig_input" = "0" ] && return 0
    read -ra entries <<< "${ig_input//,/ }"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        if ! np_valid_cidr4 "$entry"; then
            echo -e "${COLOR_RED}$(printf "${LANG[IG_ADD_INVALID]}" "$entry")${COLOR_RESET}"
            return 1
        fi
    done
    merged=$(printf '%s\n%s\n' "$(ig_current_entries)" "$(printf '%s\n' "${entries[@]}")" | sed '/^$/d' | sort -u)
    total=$(printf '%s\n' "$merged" | sed '/^$/d' | wc -l)
    if ig_apply_entries "$merged"; then
        step_ok "$(printf "${LANG[IG_LIST_SAVED]}" "$total")"
    fi
}

ig_manual_remove() {
    if ! np_refresh_plugin "ingressFilter" "$IG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    local current
    current=$(ig_current_entries | sed '/^$/d')
    if [ -z "$current" ]; then
        echo -e "${COLOR_YELLOW}${LANG[IG_LIST_EMPTY]}${COLOR_RESET}"
        return 0
    fi
    echo -e " ${COLOR_GRAY}${LANG[IG_LIST_HEAD]}${COLOR_RESET}"
    printf '%s\n' "$current" | head -20 | while IFS= read -r entry; do
        echo -e "   ${COLOR_GRAY}${entry}${COLOR_RESET}"
    done
    local ig_input entries=() entry after before_count after_count removed
    reading "${LANG[IG_REMOVE_PROMPT]}" ig_input || return 0
    [ "$ig_input" = "0" ] && return 0
    read -ra entries <<< "${ig_input//,/ }"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        if ! np_valid_cidr4 "$entry"; then
            echo -e "${COLOR_RED}$(printf "${LANG[IG_ADD_INVALID]}" "$entry")${COLOR_RESET}"
            return 1
        fi
    done
    before_count=$(printf '%s\n' "$current" | sed '/^$/d' | wc -l)
    local remove_args=()
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        remove_args+=(-e "$entry")
    done
    after=$(printf '%s\n' "$current" | grep -Fxv "${remove_args[@]}" | sed '/^$/d')
    after_count=$(printf '%s\n' "$after" | sed '/^$/d' | wc -l)
    removed=$(( before_count - after_count ))
    if [ "$removed" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}${LANG[IG_NOT_REMOVED]}${COLOR_RESET}"
        return 0
    fi
    if ig_apply_entries "$after"; then
        step_ok "$(printf "${LANG[IG_LIST_SAVED]}" "$after_count")"
    fi
}

ig_delete() {
    if ! np_refresh_plugin "ingressFilter" "$IG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    if [ -z "$np_uuid" ]; then
        echo -e "${COLOR_YELLOW}${LANG[IG_NOTHING_TO_DELETE]}${COLOR_RESET}"
        return 0
    fi
    local confirm
    if ! reading_yn "${LANG[IG_DELETE_CONFIRM]}" confirm; then
        return 0
    fi
    step_do "${LANG[IG_DELETING]}"
    local response
    response=$(np_api "DELETE" "/api/node-plugins/${np_uuid}")
    if np_accepted "$response"; then
        step_ok "${LANG[IG_DELETED_OK]}"
        rm -f "$IG_STATE_FILE"
    else
        echo -e "${COLOR_RED}$(printf "${LANG[IG_DELETE_FAIL]}" "$response")${COLOR_RESET}"
    fi
}

show_ingress_presets_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[IG_PRESET_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    local id n i=1 key
    for id in ru classic fofa; do
        n=$(ig_preset_state_get "$id" | sed '/^$/d' | wc -l)
        if [ "$n" -gt 0 ]; then
            key="IG_PRESET_NAME_$id"
            echo -e "${COLOR_YELLOW}${i}. ${LANG[$key]} ${COLOR_GREEN}[${LANG[IG_PRESET_APPLIED_MARK]}: ${n}]${COLOR_RESET}"
        else
            key="IG_PRESET_NAME_$id"
            echo -e "${COLOR_YELLOW}${i}. ${LANG[$key]}${COLOR_RESET}"
        fi
        key="IG_PRESET_DESC_$id"
        echo -e "    ${COLOR_GRAY}${LANG[$key]}${COLOR_RESET}"
        i=$((i + 1))
    done
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=3 ig_preset_option
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" ig_preset_option

    case $ig_preset_option in
        1)
            ig_preset_apply "ru"
            sleep 2
            show_ingress_presets_menu
            ;;
        2)
            ig_preset_apply "classic"
            sleep 2
            show_ingress_presets_menu
            ;;
        3)
            ig_preset_apply "fofa"
            sleep 2
            show_ingress_presets_menu
            ;;
        0)
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_ingress_presets_menu
            ;;
    esac
}

show_ingress_filter_menu() {
    local state
    state=$(ig_state)
    np_status_strings "$state"

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[IG_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e " ${NP_STATUS_COLOR}${LANG[IG_MENU_TITLE]}: ${NP_STATUS_TEXT}${COLOR_RESET}"
    if [ "$state" = "on" ] || [ "$state" = "off" ]; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[IG_STATUS_ENTRIES]}" "$(ig_entry_count)")${COLOR_RESET}"
    fi
    echo -e ""

    if [ "$state" = "on" ]; then
        echo -e "${COLOR_YELLOW}1. ${LANG[IG_TOGGLE_OFF]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}1. ${LANG[IG_TOGGLE_ON]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_YELLOW}2. ${LANG[IG_PRESETS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[IG_MANUAL_ADD]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[IG_MANUAL_REMOVE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[IG_DELETE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=5 ig_option
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" ig_option

    case $ig_option in
        1)
            if [ "$state" = "on" ]; then
                ig_toggle "false"
            else
                ig_toggle "true"
            fi
            sleep 2
            show_ingress_filter_menu
            ;;
        2)
            show_ingress_presets_menu
            sleep 1
            show_ingress_filter_menu
            ;;
        3)
            ig_manual_add
            sleep 2
            show_ingress_filter_menu
            ;;
        4)
            ig_manual_remove
            sleep 2
            show_ingress_filter_menu
            ;;
        5)
            ig_delete
            sleep 2
            show_ingress_filter_menu
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_ingress_filter_menu
            ;;
    esac
}

# --- Egress Filter: outbound blocking by destination IP/port ---------------

EG_PLUGIN_NAME="Egress Filter"
EG_STATE_FILE="${DIR_REMNAWAVE}egress-preset.state"

eg_is_on() {
    echo "$np_config_json" | jq -e '.egressFilter.enabled == true or .egressFilter.enabled == "true"' >/dev/null 2>&1
}

eg_state() {
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo "unknown"
        return
    fi
    if [ -z "$np_uuid" ]; then
        echo "absent"
    elif eg_is_on; then
        echo "on"
    else
        echo "off"
    fi
}

eg_ip_count() {
    echo "$np_config_json" | jq -r '.egressFilter.blockedIps // [] | length'
}

eg_port_count() {
    echo "$np_config_json" | jq -r '.egressFilter.blockedPorts // [] | length'
}

eg_ip_entries() {
    echo "$np_config_json" | jq -r '.egressFilter.blockedIps // [] | .[]'
}

eg_port_entries() {
    echo "$np_config_json" | jq -r '.egressFilter.blockedPorts // [] | .[]'
}

eg_apply() {
    local ips="$1" ports="$2" ips_arr ports_arr config
    ips_arr=$(printf '%s\n' "$ips" | sed '/^$/d' | jq -R . | jq -s .)
    ports_arr=$(printf '%s\n' "$ports" | sed '/^$/d' | jq -R 'tonumber' | jq -s .)
    config=$(echo "$np_config_json" | jq -c --argjson ips "$ips_arr" --argjson ports "$ports_arr" \
        '.egressFilter = ((.egressFilter // {enabled: false, blockedIps: [], blockedPorts: []})
            | .blockedIps = $ips | .blockedPorts = $ports)')
    np_apply_config "$config"
}

eg_preset_state_get() {
    [ -r "$EG_STATE_FILE" ] || return 0
    awk -F'\t' -v id="$1" '$1 == id { print $2 }' "$EG_STATE_FILE"
}

eg_preset_state_set() {
    local id="$1" entries="$2" tmp entry
    tmp=$(mktemp)
    [ -r "$EG_STATE_FILE" ] && awk -F'\t' -v id="$id" '$1 != id' "$EG_STATE_FILE" > "$tmp"
    while IFS= read -r entry; do
        [ -z "$entry" ] && continue
        printf '%s\t%s\n' "$id" "$entry" >> "$tmp"
    done <<< "$entries"
    mv "$tmp" "$EG_STATE_FILE"
    chmod 600 "$EG_STATE_FILE" 2>/dev/null
}

# --- private-ranges preset machinery ---

eg_v4_to_int() {
    local IFS=.
    local o=($1)
    echo $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))
}

# True when one CIDR contains the other (or they are equal) — enough for
# candidate-vs-host-route checks, partial overlaps are impossible here.
eg_cidr_overlaps() {
    local a="$1" b="$2"
    local an am bn bm ip mask
    ip="${a%%/*}"; mask="${a##*/}"
    an=$(eg_v4_to_int "$ip"); am=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    ip="${b%%/*}"; mask="${b##*/}"
    bn=$(eg_v4_to_int "$ip"); bm=$(( (0xFFFFFFFF << (32 - mask)) & 0xFFFFFFFF ))
    [ $(( an & bm )) -eq $(( bn & am )) ]
}

# Every IPv4 prefix the host actually routes to or owns: connected routes,
# interface addresses. These must never land in the egress blocklist.
eg_host_v4_ranges() {
    {
        ip -4 route show 2>/dev/null | awk '$1 != "default" && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\/[0-9]+$/ { print $1 }'
        ip -4 addr show 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)\/.*/\1\/32/p'
    } | sort -u
}

eg_is_port_entry() {
    [[ "$1" =~ ^[0-9]{1,5}$ ]] || return 1
    (( $1 >= 1 && $1 <= 65535 ))
}

# IPv4 (plain or CIDR, octets checked) or loose IPv6 / IPv6-CIDR.
eg_valid_ip_entry() {
    np_valid_cidr4 "$1" && return 0
    local addr="${1%%/*}"
    [[ "$addr" == *:* && "$addr" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    [[ "$(echo "$addr" | tr -cd ':')" == *:*:* ]] || return 1
    case "$1" in
        */*) [[ "${1##*/}" =~ ^[0-9]{1,3}$ ]] || return 1 ;;
    esac
    return 0
}

# Compute the private-ranges preset against the live host state: candidates
# that overlap any route/address in use are reported as skipped.
eg_private_compute() {
    EG_PRIVATE_BLOCKED=""
    EG_PRIVATE_SKIPPED=""
    local cand hr skip reason
    local host_ranges
    host_ranges=$(eg_host_v4_ranges)
    for cand in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16; do
        skip=""
        while IFS= read -r hr; do
            [ -z "$hr" ] && continue
            if eg_cidr_overlaps "$cand" "$hr"; then
                skip="$hr"
                break
            fi
        done <<< "$host_ranges"
        if [ -n "$skip" ]; then
            EG_PRIVATE_SKIPPED+="${cand} ← ${skip}"$'\n'
        else
            EG_PRIVATE_BLOCKED+="$cand"$'\n'
        fi
    done
    # IPv6 ULA (fc00::/7): tailscale/netbird meshes live in fd00::/8 — skip
    # the whole candidate as soon as the host owns any fd-address.
    if ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 fd[0-9a-fA-F][0-9a-fA-F]:'; then
        EG_PRIVATE_SKIPPED+="fc00::/7 ← fd00::/8"$'\n'
    else
        EG_PRIVATE_BLOCKED+="fc00::/7"$'\n'
    fi
    EG_PRIVATE_BLOCKED=$(printf '%s' "$EG_PRIVATE_BLOCKED" | sed '/^$/d')
    EG_PRIVATE_SKIPPED=$(printf '%s' "$EG_PRIVATE_SKIPPED" | sed '/^$/d')
    return 0
}

eg_preset_apply_private() {
    eg_private_compute
    local blocked_n skipped_n
    blocked_n=$(printf '%s\n' "$EG_PRIVATE_BLOCKED" | sed '/^$/d' | wc -l)
    skipped_n=$(printf '%s\n' "$EG_PRIVATE_SKIPPED" | sed '/^$/d' | wc -l)

    if [ "$blocked_n" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}${LANG[EG_PRESET_EMPTY]}${COLOR_RESET}"
        return 0
    fi

    echo -e ""
    echo -e " ${COLOR_GRAY}$(printf "${LANG[EG_PRESET_BLOCKED_HEAD]}" "$blocked_n")${COLOR_RESET}"
    printf '%s\n' "$EG_PRIVATE_BLOCKED" | while IFS= read -r line; do
        echo -e "   ${COLOR_RED}${line}${COLOR_RESET}"
    done
    if [ "$skipped_n" -gt 0 ]; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[EG_PRESET_SKIPPED_HEAD]}" "$skipped_n")${COLOR_RESET}"
        printf '%s\n' "$EG_PRIVATE_SKIPPED" | while IFS= read -r line; do
            echo -e "   ${COLOR_GREEN}${line}${COLOR_RESET}"
        done
    fi
    echo ""

    local confirm
    if ! reading_yn "${LANG[EG_PRESET_PRIVATE_CONFIRM]}" confirm; then
        return 0
    fi
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    local was_on="false"
    eg_is_on && was_on="true"

    local old_private merged
    old_private=$(eg_preset_state_get "private" | sed '/^$/d' | sort -u)
    merged=$(printf '%s\n%s\n' "$(eg_ip_entries | sed '/^$/d' | sort -u)" \
        <(printf '%s\n' "$EG_PRIVATE_BLOCKED" | sed '/^$/d' | sort -u) | sed '/^$/d' | sort -u)
    if [ -n "$old_private" ]; then
        merged=$(comm -23 <(printf '%s\n' "$merged" | sort -u) <(printf '%s\n' "$old_private" | sort -u))
    fi

    if ! eg_apply "$merged" "$(eg_port_entries | sed '/^$/d' | sort -n -u)"; then
        return 1
    fi
    eg_preset_state_set "private" "$(printf '%s\n' "$EG_PRIVATE_BLOCKED" | sed '/^$/d')"
    step_ok "$(printf "${LANG[EG_PRESET_PRIVATE_APPLIED]}" "$blocked_n")"
    if [ "$was_on" != "true" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EG_PRESET_ENABLE_HINT]}${COLOR_RESET}"
    fi
}

eg_preset_apply_mail() {
    local confirm
    if ! reading_yn "${LANG[EG_PRESET_MAIL_CONFIRM]}" confirm; then
        return 0
    fi
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    local was_on="false"
    eg_is_on && was_on="true"

    local old_mail merged
    old_mail=$(eg_preset_state_get "mail" | sed '/^$/d' | sort -u)
    merged=$(printf '25\n465\n587\n' | sort -n -u)
    local current_ports
    current_ports=$(eg_port_entries | sed '/^$/d' | sort -n -u)
    if [ -n "$old_mail" ]; then
        current_ports=$(comm -23 <(printf '%s\n' "$current_ports") <(printf '%s\n' "$old_mail" | sort -n))
    fi
    merged=$(printf '%s\n%s\n' "$current_ports" "$merged" | sed '/^$/d' | sort -n -u)

    if ! eg_apply "$(eg_ip_entries | sed '/^$/d' | sort -u)" "$merged"; then
        return 1
    fi
    eg_preset_state_set "mail" "$(printf '25\n465\n587\n')"
    step_ok "$(printf "${LANG[EG_PRESET_MAIL_APPLIED]}" "25, 465, 587")"
    if [ "$was_on" != "true" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EG_PRESET_ENABLE_HINT]}${COLOR_RESET}"
    fi
}

eg_toggle() {
    local new_enabled="$1"
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    if [ "$new_enabled" = "true" ]; then
        step_do "${LANG[EG_ENABLING]}"
    else
        step_do "${LANG[EG_DISABLING]}"
    fi
    local config
    config=$(echo "$np_config_json" | jq -c --argjson enabled "$new_enabled" \
        '.egressFilter = ((.egressFilter // {enabled: false, blockedIps: [], blockedPorts: []}) | .enabled = $enabled)')
    if ! np_apply_config "$config"; then
        return 1
    fi
    if [ "$new_enabled" = "true" ]; then
        step_ok "${LANG[EG_ENABLED_OK]}"
        echo -e "${COLOR_YELLOW}${LANG[EG_NOTE]}${COLOR_RESET}"
    else
        step_ok "${LANG[EG_DISABLED_OK]}"
    fi
    local now_on="false"
    if np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME" && [ -n "$np_uuid" ] && eg_is_on; then
        now_on="true"
    fi
    if [ "$now_on" != "$new_enabled" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NP_STATUS_PENDING]}${COLOR_RESET}"
    fi
}

eg_manual_add_ip() {
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    local eg_input entries=() entry merged
    reading "${LANG[EG_ADD_IP_PROMPT]}" eg_input || return 0
    [ "$eg_input" = "0" ] && return 0
    read -ra entries <<< "${eg_input//,/ }"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        if ! eg_valid_ip_entry "$entry"; then
            echo -e "${COLOR_RED}$(printf "${LANG[EG_INVALID_IP]}" "$entry")${COLOR_RESET}"
            return 1
        fi
    done
    merged=$(printf '%s\n%s\n' "$(eg_ip_entries)" "$(printf '%s\n' "${entries[@]}")" | sed '/^$/d' | sort -u)
    if eg_apply "$merged" "$(eg_port_entries | sed '/^$/d' | sort -n -u)"; then
        step_ok "$(printf "${LANG[EG_LIST_SAVED]}" "$(printf '%s\n' "$merged" | sed '/^$/d' | wc -l)" "$(eg_port_count)")"
    fi
}

eg_manual_add_port() {
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    np_ensure_plugin || return 1
    local eg_input entries=() entry merged
    reading "${LANG[EG_ADD_PORT_PROMPT]}" eg_input || return 0
    [ "$eg_input" = "0" ] && return 0
    read -ra entries <<< "${eg_input//,/ }"
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        if ! eg_is_port_entry "$entry"; then
            echo -e "${COLOR_RED}$(printf "${LANG[EG_INVALID_PORT]}" "$entry")${COLOR_RESET}"
            return 1
        fi
    done
    merged=$(printf '%s\n%s\n' "$(eg_port_entries)" "$(printf '%s\n' "${entries[@]}")" | sed '/^$/d' | sort -n -u)
    if eg_apply "$(eg_ip_entries | sed '/^$/d' | sort -u)" "$merged"; then
        step_ok "$(printf "${LANG[EG_LIST_SAVED]}" "$(eg_ip_count)" "$(printf '%s\n' "$merged" | sed '/^$/d' | wc -l)")"
    fi
}

eg_manual_remove() {
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    local ips ports
    ips=$(eg_ip_entries | sed '/^$/d')
    ports=$(eg_port_entries | sed '/^$/d')
    if [ -z "$ips" ] && [ -z "$ports" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EG_LIST_EMPTY]}${COLOR_RESET}"
        return 0
    fi
    [ -n "$ips" ] && {
        echo -e " ${COLOR_GRAY}${LANG[EG_LIST_HEAD_IP]}${COLOR_RESET}"
        printf '%s\n' "$ips" | head -20 | while IFS= read -r entry; do
            echo -e "   ${COLOR_GRAY}${entry}${COLOR_RESET}"
        done
    }
    [ -n "$ports" ] && {
        echo -e " ${COLOR_GRAY}${LANG[EG_LIST_HEAD_PORT]}${COLOR_RESET}"
        printf '%s\n' "$ports" | head -20 | while IFS= read -r entry; do
            echo -e "   ${COLOR_GRAY}${entry}${COLOR_RESET}"
        done
    }

    local eg_input entries=() entry
    reading "${LANG[EG_REMOVE_PROMPT]}" eg_input || return 0
    [ "$eg_input" = "0" ] && return 0
    read -ra entries <<< "${eg_input//,/ }"
    local ip_args=() port_args=()
    for entry in "${entries[@]}"; do
        [ -z "$entry" ] && continue
        if eg_is_port_entry "$entry"; then
            port_args+=(-e "$entry")
        elif eg_valid_ip_entry "$entry"; then
            ip_args+=(-e "$entry")
        else
            echo -e "${COLOR_RED}$(printf "${LANG[EG_INVALID_IP]}" "$entry")${COLOR_RESET}"
            return 1
        fi
    done

    local new_ips="$ips" new_ports="$ports"
    [ "${#ip_args[@]}" -gt 0 ] && new_ips=$(printf '%s\n' "$ips" | grep -Fxv "${ip_args[@]}" | sed '/^$/d')
    [ "${#port_args[@]}" -gt 0 ] && new_ports=$(printf '%s\n' "$ports" | grep -Fxv "${port_args[@]}" | sed '/^$/d')

    local removed_ips=$(( $(printf '%s\n' "$ips" | sed '/^$/d' | wc -l) - $(printf '%s\n' "$new_ips" | sed '/^$/d' | wc -l) ))
    local removed_ports=$(( $(printf '%s\n' "$ports" | sed '/^$/d' | wc -l) - $(printf '%s\n' "$new_ports" | sed '/^$/d' | wc -l) ))
    if [ "$removed_ips" -eq 0 ] && [ "$removed_ports" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}${LANG[EG_NOT_REMOVED]}${COLOR_RESET}"
        return 0
    fi
    if eg_apply "$new_ips" "$new_ports"; then
        step_ok "$(printf "${LANG[EG_LIST_SAVED]}" "$(printf '%s\n' "$new_ips" | sed '/^$/d' | wc -l)" "$(printf '%s\n' "$new_ports" | sed '/^$/d' | wc -l)")"
    fi
}

eg_delete() {
    if ! np_refresh_plugin "egressFilter" "$EG_PLUGIN_NAME"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NP_API_FAIL]}" "")${COLOR_RESET}"
        return 1
    fi
    if [ -z "$np_uuid" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EG_NOTHING_TO_DELETE]}${COLOR_RESET}"
        return 0
    fi
    local confirm
    if ! reading_yn "${LANG[EG_DELETE_CONFIRM]}" confirm; then
        return 0
    fi
    step_do "${LANG[EG_DELETING]}"
    local response
    response=$(np_api "DELETE" "/api/node-plugins/${np_uuid}")
    if np_accepted "$response"; then
        step_ok "${LANG[EG_DELETED_OK]}"
        rm -f "$EG_STATE_FILE"
    else
        echo -e "${COLOR_RED}$(printf "${LANG[EG_DELETE_FAIL]}" "$response")${COLOR_RESET}"
    fi
}

show_egress_presets_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[EG_PRESET_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    local n
    n=$(eg_preset_state_get "private" | sed '/^$/d' | wc -l)
    if [ "$n" -gt 0 ]; then
        echo -e "${COLOR_YELLOW}1. ${LANG[EG_PRESET_NAME_PRIVATE]} ${COLOR_GREEN}[${LANG[IG_PRESET_APPLIED_MARK]}: ${n}]${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}1. ${LANG[EG_PRESET_NAME_PRIVATE]}${COLOR_RESET}"
    fi
    echo -e "    ${COLOR_GRAY}${LANG[EG_PRESET_DESC_PRIVATE]}${COLOR_RESET}"
    n=$(eg_preset_state_get "mail" | sed '/^$/d' | wc -l)
    if [ "$n" -gt 0 ]; then
        echo -e "${COLOR_YELLOW}2. ${LANG[EG_PRESET_NAME_MAIL]} ${COLOR_GREEN}[${LANG[IG_PRESET_APPLIED_MARK]}: ${n}]${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}2. ${LANG[EG_PRESET_NAME_MAIL]}${COLOR_RESET}"
    fi
    echo -e "    ${COLOR_GRAY}${LANG[EG_PRESET_DESC_MAIL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=2 eg_preset_option
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" eg_preset_option

    case $eg_preset_option in
        1)
            eg_preset_apply_private
            sleep 2
            show_egress_presets_menu
            ;;
        2)
            eg_preset_apply_mail
            sleep 2
            show_egress_presets_menu
            ;;
        0)
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_egress_presets_menu
            ;;
    esac
}

show_egress_filter_menu() {
    local state
    state=$(eg_state)
    np_status_strings "$state"

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[EG_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e " ${NP_STATUS_COLOR}${LANG[EG_MENU_TITLE]}: ${NP_STATUS_TEXT}${COLOR_RESET}"
    if [ "$state" = "on" ] || [ "$state" = "off" ]; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[EG_STATUS_IPS]}" "$(eg_ip_count)") | $(printf "${LANG[EG_STATUS_PORTS]}" "$(eg_port_count)")${COLOR_RESET}"
    fi
    echo -e ""

    if [ "$state" = "on" ]; then
        echo -e "${COLOR_YELLOW}1. ${LANG[EG_TOGGLE_OFF]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}1. ${LANG[EG_TOGGLE_ON]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_YELLOW}2. ${LANG[EG_PRESETS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[EG_MANUAL_ADD_IP]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[EG_MANUAL_ADD_PORT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[EG_MANUAL_REMOVE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. ${LANG[EG_DELETE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=6 eg_option
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" eg_option

    case $eg_option in
        1)
            if [ "$state" = "on" ]; then
                eg_toggle "false"
            else
                eg_toggle "true"
            fi
            sleep 2
            show_egress_filter_menu
            ;;
        2)
            show_egress_presets_menu
            sleep 1
            show_egress_filter_menu
            ;;
        3)
            eg_manual_add_ip
            sleep 2
            show_egress_filter_menu
            ;;
        4)
            eg_manual_add_port
            sleep 2
            show_egress_filter_menu
            ;;
        5)
            eg_manual_remove
            sleep 2
            show_egress_filter_menu
            ;;
        6)
            eg_delete
            sleep 2
            show_egress_filter_menu
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_egress_filter_menu
            ;;
    esac
}

# --- Telegram notifications via the panel .env -------------------------------
# The panel sends TB reports itself once the env vars below are set; the docs
# require recreating the stack (down + up), a plain restart is not enough.

NP_PANEL_ENV="/opt/remnawave/.env"

np_env_get() {
    [ -r "$NP_PANEL_ENV" ] || return 1
    sed -n "s|^$1=||p" "$NP_PANEL_ENV" | head -n1
}

np_env_set() {
    local var="$1" val="$2"
    local escaped="${val//&/\\&}"
    if grep -q "^$var=" "$NP_PANEL_ENV"; then
        sed -i "s|^$var=.*|$var=$escaped|" "$NP_PANEL_ENV"
    else
        printf '%s=%s\n' "$var" "$val" >> "$NP_PANEL_ENV"
    fi
}

# Same helper as in the certificates module: the user types the proxy password
# as is, it goes into the URL percent-encoded (safe for .env and for the panel).
percent_encode_proxy_auth() {
    local url="$1"
    local scheme rest hostpart userinfo user pass
    local c octet out_user="" out_pass=""

    case "$url" in
        *://*) scheme="${url%%://*}"; rest="${url#*://}" ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    case "$rest" in
        *@*)
            hostpart="${rest##*@}"
            userinfo="${rest%@${hostpart}}"
            ;;
        *) printf '%s\n' "$url"; return 0 ;;
    esac

    user="${userinfo%%:*}"
    if [[ "$userinfo" == *:* ]]; then
        pass="${userinfo#*:}"
    else
        pass=""
    fi

    while IFS= read -r -n 1 c; do
        case "$c" in
            [A-Za-z0-9.-_~]) out_user+="$c" ;;
            *) printf -v octet '%%%02X' "'$c"; out_user+="$octet" ;;
        esac
    done <<< "$user"

    while IFS= read -r -n 1 c; do
        case "$c" in
            [A-Za-z0-9.-_~]) out_pass+="$c" ;;
            *) printf -v octet '%%%02X' "'$c"; out_pass+="$octet" ;;
        esac
    done <<< "$pass"

    if [ -n "$out_pass" ]; then
        printf '%s://%s:%s@%s\n' "$scheme" "$out_user" "$out_pass" "$hostpart"
    else
        printf '%s://%s@%s\n' "$scheme" "$out_user" "$hostpart"
    fi
}

# Split "chat_id[:thread_id]" into NP_TG_CHAT_VAL / NP_TG_THREAD_VAL.
np_tg_parse_chat() {
    local input="$1"
    NP_TG_THREAD_VAL=""
    case "$input" in
        *:*) NP_TG_CHAT_VAL="${input%%:*}"; NP_TG_THREAD_VAL="${input##*:}" ;;
        *)   NP_TG_CHAT_VAL="$input" ;;
    esac
    [[ "$NP_TG_CHAT_VAL" =~ ^-?[0-9]+$ ]] || return 1
    if [ -n "$NP_TG_THREAD_VAL" ] && ! [[ "$NP_TG_THREAD_VAL" =~ ^-?[0-9]+$ ]]; then
        return 1
    fi
    return 0
}

np_tg_send_test() {
    local curl_proxy=() thread_args=()
    [ -n "$NP_TG_PROXY_VAL" ] && curl_proxy=(--proxy "$NP_TG_PROXY_VAL")
    [ -n "$NP_TG_THREAD_VAL" ] && thread_args=(--data-urlencode "message_thread_id=${NP_TG_THREAD_VAL}")
    NP_TG_RESPONSE=$(curl -s -m 20 "${curl_proxy[@]}" "https://api.telegram.org/bot${NP_TG_TOKEN_VAL}/sendMessage" \
        --data-urlencode "chat_id=${NP_TG_CHAT_VAL}" \
        "${thread_args[@]}" \
        --data-urlencode "text=✅ ${LANG[NP_TG_TEST_TEXT]}" 2>/dev/null)
    NP_TG_CURL_RC=$?
    printf '%s' "$NP_TG_RESPONSE" | grep -q '"ok":true'
}

np_tg_show_error() {
    local desc
    desc=$(printf '%s' "$NP_TG_RESPONSE" | sed -n 's/.*"description":"\([^"]*\)".*/\1/p')
    if [ -n "$desc" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[CERT_TG_FAIL_DESC]}" "$desc")${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CERT_TG_FAIL]}${COLOR_RESET}"
    fi
}

np_tg_recreate_stack() {
    (
        cd /opt/remnawave || exit 1
        docker compose down > /dev/null 2>&1
        docker compose up -d > /dev/null 2>&1
    ) &
    spinner $! "${LANG[WAITING]}"
}

np_tg_disable() {
    local confirm
    if ! reading_yn "${LANG[NP_TG_DISABLE_CONFIRM]}" confirm; then
        return 0
    fi
    step_do "${LANG[NP_TG_RECREATING]}"
    np_env_set "TELEGRAM_NOTIFY_TBLOCKER" "change_me"
    # Keep the global switch on while other categories still carry a real chat.
    local other others_left=0 v
    for v in TELEGRAM_NOTIFY_USERS TELEGRAM_NOTIFY_NODES TELEGRAM_NOTIFY_CRM TELEGRAM_NOTIFY_SERVICE; do
        other=$(np_env_get "$v")
        if [ -n "$other" ] && [ "$other" != "change_me" ]; then
            others_left=1
            break
        fi
    done
    [ "$others_left" = "0" ] && np_env_set "IS_TELEGRAM_NOTIFICATIONS_ENABLED" "false"
    np_tg_recreate_stack
    step_ok "${LANG[NP_TG_DISABLED_OK]}"
}

np_setup_tg() {
    if [ ! -r "$NP_PANEL_ENV" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NP_TG_NO_ENV]}${COLOR_RESET}"
        return 1
    fi

    local cur_enabled cur_token cur_chat
    cur_enabled=$(np_env_get "IS_TELEGRAM_NOTIFICATIONS_ENABLED")
    cur_token=$(np_env_get "TELEGRAM_BOT_TOKEN")
    cur_chat=$(np_env_get "TELEGRAM_NOTIFY_TBLOCKER")

    local state_txt="${LANG[NP_TG_STATE_OFF]}"
    [ "$cur_enabled" = "true" ] && state_txt="${LANG[NP_TG_STATE_ON]}"
    local chat_txt="—"
    { [ -n "$cur_chat" ] && [ "$cur_chat" != "change_me" ]; } && chat_txt="$cur_chat"
    echo -e " ${COLOR_GRAY}$(printf "${LANG[NP_TG_CURRENT]}" "$state_txt" "$chat_txt")${COLOR_RESET}"

    if [ "$cur_enabled" = "true" ] && [ "$chat_txt" != "—" ]; then
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[NP_TG_MENU_RECONFIG]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[NP_TG_MENU_DISABLE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        local tg_action
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "2")" tg_action
        case $tg_action in
            2) np_tg_disable ;;
            1) ;;
            *) return 0 ;;
        esac
    fi

    local token_val="" proxy_val="" token_input chat_input chat_full
    while true; do
        local token_def="—"
        { [ -n "$cur_token" ] && [ "$cur_token" != "change_me" ]; } && token_def="$cur_token"
        reading "$(printf "${LANG[NP_TG_TOKEN_PROMPT]}" "$token_def")" token_input || return 0
        [ "$token_input" = "0" ] && return 0

        local chat_def="—"
        { [ -n "$cur_chat" ] && [ "$cur_chat" != "change_me" ]; } && chat_def="$cur_chat"
        reading "$(printf "${LANG[NP_TG_CHAT_PROMPT]}" "$chat_def")" chat_input || return 0
        [ "$chat_input" = "0" ] && return 0

        if [ -n "$token_input" ]; then
            token_val="$token_input"
        elif [ "$token_def" != "—" ]; then
            token_val="$cur_token"
        fi
        if [ -n "$chat_input" ]; then
            chat_full="$chat_input"
        elif [ "$chat_def" != "—" ]; then
            chat_full="$cur_chat"
        fi

        if ! [[ "$token_val" =~ ^[0-9A-Za-z:_-]+$ ]] || ! np_tg_parse_chat "$chat_full"; then
            echo -e "${COLOR_RED}${LANG[NP_TG_INVALID]}${COLOR_RESET}"
            continue
        fi

        NP_TG_TOKEN_VAL="$token_val"
        NP_TG_PROXY_VAL=""
        echo -e "${COLOR_YELLOW}${LANG[CERT_TG_TESTING]}${COLOR_RESET}"
        np_tg_send_test && break

        # Empty reply with a curl error = api.telegram.org unreachable
        if [ -z "$NP_TG_RESPONSE" ] && [ "$NP_TG_CURL_RC" -ne 0 ]; then
            echo -e "${COLOR_YELLOW}${LANG[CERT_TG_BLOCKED]}${COLOR_RESET}"
            local use_proxy proxy_url
            printf "${COLOR_YELLOW}${LANG[CERT_TG_PROXY]}${COLOR_RESET}\n"
            read_yn use_proxy || { echo -e "${COLOR_RED}${LANG[CERT_TG_FAIL]}${COLOR_RESET}"; continue; }
            reading "${LANG[CERT_TG_PROXY_URL]}" proxy_url || proxy_url=""
            proxy_url=$(percent_encode_proxy_auth "$proxy_url")
            if [ -n "$proxy_url" ] && [[ "$proxy_url" =~ ^(https?|socks5h?)://[A-Za-z0-9.:_%@/?=-]+$ ]]; then
                NP_TG_PROXY_VAL="$proxy_url"
                echo -e "${COLOR_YELLOW}${LANG[CERT_TG_TESTING]}${COLOR_RESET}"
                np_tg_send_test && { proxy_val="$proxy_url"; break; }
            fi
        fi
        np_tg_show_error
    done

    echo ""
    local tg_apply
    if ! reading_yn "${LANG[NP_TG_APPLY_CONFIRM]}" tg_apply; then
        return 0
    fi
    step_do "${LANG[NP_TG_SAVING]}"
    np_env_set "IS_TELEGRAM_NOTIFICATIONS_ENABLED" "true"
    np_env_set "TELEGRAM_BOT_TOKEN" "$token_val"
    np_env_set "TELEGRAM_NOTIFY_TBLOCKER" "$chat_full"
    if [ -n "$proxy_val" ]; then
        np_env_set "TELEGRAM_BOT_PROXY" "$proxy_val"
    elif grep -q "^TELEGRAM_BOT_PROXY=" "$NP_PANEL_ENV"; then
        sed -i "s|^TELEGRAM_BOT_PROXY=|# TELEGRAM_BOT_PROXY=|" "$NP_PANEL_ENV"
    fi
    step_do "${LANG[NP_TG_RECREATING]}"
    np_tg_recreate_stack
    step_ok "${LANG[NP_TG_DONE]}"
}

# Sets NP_STATUS_COLOR / NP_STATUS_TEXT for a plugin state.
np_status_strings() {
    local state="$1"
    NP_STATUS_COLOR="$COLOR_RED"
    NP_STATUS_TEXT="${LANG[NP_STATUS_UNKNOWN]}"
    case $state in
        on)     NP_STATUS_COLOR="$COLOR_GREEN"; NP_STATUS_TEXT="${LANG[NP_STATUS_ON]}" ;;
        off)    NP_STATUS_COLOR="$COLOR_YELLOW"; NP_STATUS_TEXT="${LANG[NP_STATUS_OFF]}" ;;
        absent) NP_STATUS_COLOR="$COLOR_GRAY"; NP_STATUS_TEXT="${LANG[NP_STATUS_ABSENT]}" ;;
    esac
}

# Plugin chooser: each plugin gets its own submenu, so a new plugin later is
# just one more entry here.
show_node_plugins_menu() {
    local state
    state=$(np_state)
    np_status_strings "$state"

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NP_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[NP_TB_LABEL]}: ${NP_STATUS_COLOR}${NP_STATUS_TEXT}${COLOR_RESET}"
    state=$(ig_state)
    np_status_strings "$state"
    echo -e "${COLOR_YELLOW}2. ${LANG[IG_MENU_TITLE]}: ${NP_STATUS_COLOR}${NP_STATUS_TEXT}${COLOR_RESET}"
    state=$(eg_state)
    np_status_strings "$state"
    echo -e "${COLOR_YELLOW}3. ${LANG[EG_MENU_TITLE]}: ${NP_STATUS_COLOR}${NP_STATUS_TEXT}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=3
    reading "$(printf "${LANG[NP_SELECT_PLUGIN]}" "$last")" NP_OPTION

    case $NP_OPTION in
        1)
            show_torrent_blocker_menu
            sleep 1
            show_node_plugins_menu
            ;;
        2)
            show_ingress_filter_menu
            sleep 1
            show_node_plugins_menu
            ;;
        3)
            show_egress_filter_menu
            sleep 1
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

show_torrent_blocker_menu() {
    local state
    state=$(np_state)
    np_status_strings "$state"

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NP_TB_LABEL]}${COLOR_RESET}"
    echo -e ""
    echo -e " ${NP_STATUS_COLOR}${LANG[NP_TB_LABEL]}: ${NP_STATUS_TEXT}${COLOR_RESET}"
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
    echo -e "${COLOR_YELLOW}6. ${LANG[NP_DELETE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}7. ${LANG[NP_TG_MENU]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=7
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" NP_OPTION

    case $NP_OPTION in
        1)
            if [ "$state" = "on" ]; then
                np_toggle "false"
            else
                np_toggle "true"
            fi
            sleep 2
            show_torrent_blocker_menu
            ;;
        2)
            np_settings
            sleep 2
            show_torrent_blocker_menu
            ;;
        3)
            np_stats
            sleep 3
            show_torrent_blocker_menu
            ;;
        4)
            np_unblock_ip
            sleep 2
            show_torrent_blocker_menu
            ;;
        5)
            np_recreate_tables
            sleep 2
            show_torrent_blocker_menu
            ;;
        6)
            np_delete
            sleep 2
            show_torrent_blocker_menu
            ;;
        7)
            np_setup_tg
            sleep 2
            show_torrent_blocker_menu
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_torrent_blocker_menu
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
