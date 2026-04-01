#!/bin/bash
# Module: WARP Native

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
            bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh)
            sleep 2
            log_clear
            manage_warp_native
            ;;
        2)
            bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh)
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
            echo -e "${COLOR_RED}${LANG[EXTENSIONS_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_warp_native
            ;;
    esac
}

manage_warp_add_config() {
    load_api_module

    local domain_url="127.0.0.1:3000"

    echo -e ""
    echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[WARP_CONFIRM_SERVER_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}${LANG[CONFIRM_PROMPT]}${COLOR_RESET}"
    read confirm
    echo

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi

    get_panel_token
    token=$(cat "$TOKEN_FILE")

    local config_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
    if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    if ! echo "$config_response" | jq -e '.response.configProfiles | type == "array"' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Response does not contain configProfiles array${COLOR_RESET}"
        return 1
    fi

    local config_count=$(echo "$config_response" | jq '.response.configProfiles | length')
    if [ "$config_count" -eq 0 ]; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Empty configuration list${COLOR_RESET}"
        return 1
    fi
    local configs=$(echo "$config_response" | jq -r '.response.configProfiles[] | select(.uuid and .name) | "\(.name) \(.uuid)"' 2>/dev/null)
    if [ -z "$configs" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: No valid configurations found in response${COLOR_RESET}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_YELLOW}${LANG[WARP_SELECT_CONFIG]}${COLOR_RESET}"
    echo -e ""
    local i=1
    declare -A config_map
    while IFS=' ' read -r name uuid; do
        echo -e "${COLOR_YELLOW}$i. $name${COLOR_RESET}"
        config_map[$i]="$uuid"
        ((i++))
    done <<< "$configs"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[WARP_PROMPT1]}" CONFIG_OPTION

    if [ "$CONFIG_OPTION" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi

    if [ -z "${config_map[$CONFIG_OPTION]}" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_INVALID_CHOICE2]}${COLOR_RESET}"
        return 1
    fi

    local selected_uuid=${config_map[$CONFIG_OPTION]}

    local config_data=$(make_api_request "GET" "${domain_url}/api/config-profiles/$selected_uuid" "$token")
    if [ -z "$config_data" ] || ! echo "$config_data" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    local config_json
    if echo "$config_data" | jq -e '.response.config' > /dev/null 2>&1; then
        config_json=$(echo "$config_data" | jq -r '.response.config')
    else
        config_json=$(echo "$config_data" | jq -r '.config // ""')
    fi

    if [ -z "$config_json" ] || [ "$config_json" == "null" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: No config found in response${COLOR_RESET}"
        return 1
    fi

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
            "type": "field",
            "domain": ["whoer.net", "browserleaks.com", "2ip.io", "2ip.ru"],
            "outboundTag": "warp-out"
        }'
        config_json=$(echo "$config_json" | jq --argjson warp_rule "$warp_rule" '.routing.rules += [$warp_rule]' 2>/dev/null)
    fi

    local update_response=$(make_api_request "PATCH" "${domain_url}/api/config-profiles" "$token" "{\"uuid\": \"$selected_uuid\", \"config\": $config_json}")
    if [ -z "$update_response" ] || ! echo "$update_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_GREEN}${LANG[WARP_UPDATE_SUCCESS]}${COLOR_RESET}"
}

manage_warp_delete_settings() {
    load_api_module

    local domain_url="127.0.0.1:3000"

    echo -e ""
    echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[WARP_CONFIRM_SERVER_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}${LANG[CONFIRM_PROMPT]}${COLOR_RESET}"
    read confirm
    echo

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi

    get_panel_token
    token=$(cat "$TOKEN_FILE")

    local config_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
    if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    if ! echo "$config_response" | jq -e '.response.configProfiles | type == "array"' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Response does not contain configProfiles array${COLOR_RESET}"
        return 1
    fi

    local config_count=$(echo "$config_response" | jq '.response.configProfiles | length')
    if [ "$config_count" -eq 0 ]; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Empty configuration list${COLOR_RESET}"
        return 1
    fi

    local configs=$(echo "$config_response" | jq -r '.response.configProfiles[] | select(.uuid and .name) | "\(.name) \(.uuid)"' 2>/dev/null)
    if [ -z "$configs" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: No valid configurations found in response${COLOR_RESET}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_YELLOW}${LANG[WARP_SELECT_CONFIG_DELETE]}${COLOR_RESET}"
    echo -e ""
    local i=1
    declare -A config_map
    while IFS=' ' read -r name uuid; do
        echo -e "${COLOR_YELLOW}$i. $name${COLOR_RESET}"
        config_map[$i]="$uuid"
        ((i++))
    done <<< "$configs"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[WARP_PROMPT1]}" CONFIG_OPTION

    if [ "$CONFIG_OPTION" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi

    if [ -z "${config_map[$CONFIG_OPTION]}" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_INVALID_CHOICE2]}${COLOR_RESET}"
        return 1
    fi

    local selected_uuid=${config_map[$CONFIG_OPTION]}

    local config_data=$(make_api_request "GET" "${domain_url}/api/config-profiles/$selected_uuid" "$token")
    if [ -z "$config_data" ] || ! echo "$config_data" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    local config_json
    if echo "$config_data" | jq -e '.response.config' > /dev/null 2>&1; then
        config_json=$(echo "$config_data" | jq -r '.response.config')
    else
        config_json=$(echo "$config_data" | jq -r '.config // ""')
    fi

    if [ -z "$config_json" ] || [ "$config_json" == "null" ]; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: No config found in response${COLOR_RESET}"
        return 1
    fi

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

    local update_response=$(make_api_request "PATCH" "${domain_url}/api/config-profiles" "$token" "{\"uuid\": \"$selected_uuid\", \"config\": $config_json}")
    if [ -z "$update_response" ] || ! echo "$update_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_GREEN}${LANG[WARP_DELETE_SUCCESS]}${COLOR_RESET}"
}
