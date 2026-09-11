#!/bin/bash
# Module: WARP Native

WARP_API_URL="127.0.0.1:3000"

warp_download_file() {
    local url="$1"
    local dest_file="$2"

    rm -f "$dest_file"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --speed-limit 1024 --speed-time 60 -o "$dest_file" "$url" 2>/dev/null || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=60 --tries=1 -O "$dest_file" "$url" 2>/dev/null || return 1
    else
        return 1
    fi

    [ -s "$dest_file" ]
}

warp_run_script() {
    local script_name="$1"
    local script_url="https://raw.githubusercontent.com/distillium/warp-native/main/${script_name}"
    local script_file="/tmp/warp-native-${script_name}"

    local download_prefixes=(
        ""
        "https://gh-proxy.com/"
        "https://ghfast.top/"
        "https://ghproxy.net/"
    )
    local mirror_prefix script_ok=false

    for mirror_prefix in "${download_prefixes[@]}"; do
        if warp_download_file "${mirror_prefix}${script_url}" "$script_file"; then
            if head -1 "$script_file" | grep -q "^#!/bin/bash"; then
                script_ok=true
                break
            fi
        fi
    done

    if [ "$script_ok" != "true" ]; then
        rm -f "$script_file"
        echo -e "${COLOR_RED}${LANG[WARP_SCRIPT_FAIL]}${COLOR_RESET}"
        return 1
    fi

    bash "$script_file"
    local run_rc=$?
    rm -f "$script_file"
    return "$run_rc"
}

warp_confirm_panel() {
    echo -e ""
    echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[WARP_CONFIRM_SERVER_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}${LANG[CONFIRM_PROMPT]}${COLOR_RESET}"
    local confirmed
    read_yn confirmed || { echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"; return 1; }
}

warp_load_profiles() {
    local config_response config_count

    get_panel_token || { echo -e "${COLOR_RED}${LANG[WARP_AUTH_FAIL]}${COLOR_RESET}"; return 1; }
    WARP_TOKEN=$(cat "$TOKEN_FILE")

    config_response=$(make_api_request "GET" "${WARP_API_URL}/api/config-profiles" "$WARP_TOKEN")
    if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    if ! echo "$config_response" | jq -e '.response.configProfiles | type == "array"' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Response does not contain configProfiles array${COLOR_RESET}"
        return 1
    fi

    config_count=$(echo "$config_response" | jq '.response.configProfiles | length')
    if [ "$config_count" -eq 0 ]; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Empty configuration list${COLOR_RESET}"
        return 1
    fi

    WARP_PROFILES_RESPONSE="$config_response"
}

warp_select_config() {
    local list_header="$1"
    local configs

    configs=$(echo "$WARP_PROFILES_RESPONSE" | jq -r '.response.configProfiles[] | select(.uuid and .name) | "\(.name)\t\(.uuid)"' 2>/dev/null)
    if [ -z "$configs" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: No valid configurations found in response${COLOR_RESET}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_YELLOW}${list_header}${COLOR_RESET}"
    echo -e ""
    local i=1 name uuid
    local -A config_map
    while IFS=$'\t' read -r name uuid; do
        echo -e "${COLOR_YELLOW}$i. $name${COLOR_RESET}"
        config_map[$i]="$uuid"
        ((i++))
    done <<< "$configs"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[WARP_PROMPT1]}" CONFIG_OPTION

    if [ "$CONFIG_OPTION" = "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 1
    fi

    if [ -z "${config_map[$CONFIG_OPTION]}" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_INVALID_CHOICE2]}${COLOR_RESET}"
        return 1
    fi

    WARP_SELECTED_UUID="${config_map[$CONFIG_OPTION]}"
}

warp_fetch_config_json() {
    local selected_uuid="$1"
    local config_data

    config_data=$(make_api_request "GET" "${WARP_API_URL}/api/config-profiles/$selected_uuid" "$WARP_TOKEN")
    if [ -z "$config_data" ] || ! echo "$config_data" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    if echo "$config_data" | jq -e '.response.config' > /dev/null 2>&1; then
        WARP_CONFIG_JSON=$(echo "$config_data" | jq -r '.response.config')
    else
        WARP_CONFIG_JSON=$(echo "$config_data" | jq -r '.config // ""')
    fi

    if [ -z "$WARP_CONFIG_JSON" ] || [ "$WARP_CONFIG_JSON" == "null" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: No config found in response${COLOR_RESET}"
        return 1
    fi
}

warp_patch_config() {
    local selected_uuid="$1"
    local config_json="$2"
    local update_response

    update_response=$(make_api_request "PATCH" "${WARP_API_URL}/api/config-profiles" "$WARP_TOKEN" "{\"uuid\": \"$selected_uuid\", \"config\": $config_json}")
    if [ -z "$update_response" ] || ! echo "$update_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
        return 1
    fi
}

manage_warp_native() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[WARP_NATIVE_MENU]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[WARP_INSTALL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[WARP_UNINSTALL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}3. ${LANG[WARP_ADD_CONFIG]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[WARP_DELETE_WARP_SETTINGS]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[WARP_PROMPT]}" WARP_OPTION

    case $WARP_OPTION in
        1)
            if ! grep -q "remnanode:" /opt/remnawave/docker-compose.yml 2>/dev/null && \
               ! grep -q "remnanode:" /opt/remnanode/docker-compose.yml 2>/dev/null; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_NODE]}${COLOR_RESET}"
                sleep 2
                log_clear
                manage_warp_native
                return
            fi
            warp_run_script "install.sh"
            sleep 2
            log_clear
            manage_warp_native
            ;;
        2)
            warp_run_script "uninstall.sh"
            sleep 2
            log_clear
            manage_warp_native
            ;;
        3)
            manage_warp_add_config
            sleep 2
            log_clear
            manage_warp_native
            ;;
        4)
            manage_warp_delete_settings
            sleep 2
            log_clear
            manage_warp_native
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_RED}${LANG[WARP_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_warp_native
            ;;
    esac
}

manage_warp_add_config() {
    load_api_module

    warp_confirm_panel || return 0
    warp_load_profiles || return 1
    warp_select_config "${LANG[WARP_SELECT_CONFIG]}" || return 1
    warp_fetch_config_json "$WARP_SELECTED_UUID" || return 1

    local config_json="$WARP_CONFIG_JSON"

    if echo "$config_json" | jq -e '.outbounds[] | select(.tag == "warp-out")' > /dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}${LANG[WARP_WARNING]}${COLOR_RESET}"
    else
        local warp_outbound='{
            "tag": "warp-out",
            "protocol": "freedom",
            "settings": {
				    "domainStrategy": "UseIP"
				},
            "streamSettings": {
                "sockopt": {
                    "interface": "warp",
                    "tcpFastOpen": true
                }
            }
        }'
        config_json=$(echo "$config_json" | jq --argjson warp_out "$warp_outbound" '.outbounds += [$warp_out]' 2>/dev/null)
    fi

    if echo "$config_json" | jq -e '.routing.rules[] | select(.outboundTag == "warp-out")' > /dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}${LANG[WARP_WARNING2]}${COLOR_RESET}"
    else
        local warp_rule='{
            "domain": ["whoer.net", "browserleaks.com", "2ip.io", "2ip.ru"],
            "outboundTag": "warp-out"
        }'
        config_json=$(echo "$config_json" | jq --argjson warp_rule "$warp_rule" '.routing.rules += [$warp_rule]' 2>/dev/null)
    fi

    warp_patch_config "$WARP_SELECTED_UUID" "$config_json" || return 1

    echo -e "${COLOR_GREEN}${LANG[WARP_UPDATE_SUCCESS]}${COLOR_RESET}"
}

manage_warp_delete_settings() {
    load_api_module

    warp_confirm_panel || return 0
    warp_load_profiles || return 1
    warp_select_config "${LANG[WARP_SELECT_CONFIG_DELETE]}" || return 1
    warp_fetch_config_json "$WARP_SELECTED_UUID" || return 1

    local config_json="$WARP_CONFIG_JSON"

    if echo "$config_json" | jq -e '.outbounds[] | select(.tag == "warp-out")' > /dev/null 2>&1; then
        config_json=$(echo "$config_json" | jq 'del(.outbounds[] | select(.tag == "warp-out"))' 2>/dev/null)
        echo -e "${COLOR_YELLOW}${LANG[WARP_REMOVED_WARP_SETTINGS1]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[WARP_NO_WARP_SETTINGS1]}${COLOR_RESET}"
    fi

    if echo "$config_json" | jq -e '.routing.rules[] | select(.outboundTag == "warp-out")' > /dev/null 2>&1; then
        config_json=$(echo "$config_json" | jq 'del(.routing.rules[] | select(.outboundTag == "warp-out"))' 2>/dev/null)
        echo -e "${COLOR_YELLOW}${LANG[WARP_REMOVED_WARP_SETTINGS2]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[WARP_NO_WARP_SETTINGS2]}${COLOR_RESET}"
    fi

    warp_patch_config "$WARP_SELECTED_UUID" "$config_json" || return 1

    echo -e "${COLOR_GREEN}${LANG[WARP_DELETE_SUCCESS]}${COLOR_RESET}"
}
