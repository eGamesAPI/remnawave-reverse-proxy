#!/bin/bash
# Module: Add Node to Panel

#Add Node to Panel
add_node_to_panel() {
    local domain_url="127.0.0.1:3000"

    echo -e ""
    echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[WARNING_NODE_PANEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[CONFIRM_SERVER_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}${LANG[CONFIRM_PROMPT]}${COLOR_RESET}"
    local confirmed
    read_yn confirmed || { echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"; return 0; }

    echo -e "${COLOR_YELLOW}${LANG[ADD_NODE_TO_PANEL]}${COLOR_RESET}"
    sleep 1

    get_panel_token || { echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"; return 1; }
    local token
    token=$(cat "$TOKEN_FILE")

    while true; do
        reading "${LANG[ENTER_NODE_DOMAIN]}" SELFSTEAL_DOMAIN
        if [ "$SELFSTEAL_DOMAIN" = "0" ]; then
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
        fi
        if check_node_domain "$domain_url" "$token" "$SELFSTEAL_DOMAIN"; then
            break
        fi
        echo -e "${COLOR_YELLOW}${LANG[TRY_ANOTHER_DOMAIN]}${COLOR_RESET}"
    done

    while true; do
        reading "${LANG[ENTER_NODE_NAME]}" entity_name
        if [[ ! "$entity_name" =~ ^[a-zA-Z0-9-]+$ ]]; then
            echo -e "${COLOR_RED}${LANG[CF_INVALID_CHARS]}${COLOR_RESET}"
            continue
        fi
        if [ ${#entity_name} -lt 3 ] || [ ${#entity_name} -gt 20 ]; then
            echo -e "${COLOR_RED}${LANG[CF_INVALID_LENGTH]}${COLOR_RESET}"
            continue
        fi

        local response
        response=$(make_api_request "GET" "http://$domain_url/api/config-profiles" "$token")
        if echo "$response" | jq -e ".response.configProfiles[] | select(.name == \"$entity_name\")" > /dev/null 2>&1; then
            echo -e "${COLOR_RED}$(printf "${LANG[CF_INVALID_NAME]}" "$entity_name")${COLOR_RESET}"
        else
            break
        fi
    done

    local private_key
    private_key=$(generate_xray_keys "$domain_url" "$token") || return 1

    local profile_output
    profile_output=$(create_config_profile "$domain_url" "$token" "$entity_name" "$SELFSTEAL_DOMAIN" "$private_key" "$entity_name") || return 1
    local config_profile_uuid inbound_uuid
    read -r config_profile_uuid inbound_uuid <<< "$profile_output"
    if [ -z "$config_profile_uuid" ] || [ -z "$inbound_uuid" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_CONFIG_PROFILE]}${COLOR_RESET}"
        return 1
    fi

    create_node "$domain_url" "$token" "$config_profile_uuid" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$entity_name" || return 1

    create_host "$domain_url" "$token" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$config_profile_uuid" "$entity_name" || return 1

    local squad_uuids
    if ! squad_uuids=$(get_default_squad "$domain_url" "$token"); then
        echo -e "${COLOR_RED}${LANG[ERROR_GET_SQUAD_LIST]}${COLOR_RESET}"
    elif [ -z "$squad_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_SQUADS_TO_UPDATE]}${COLOR_RESET}"
    else
        for squad_uuid in $squad_uuids; do
            update_squad "$domain_url" "$token" "$squad_uuid" "$inbound_uuid"
        done
    fi

    echo -e "${COLOR_GREEN}${LANG[NODE_ADDED_SUCCESS]}${COLOR_RESET}"
    echo -e "${COLOR_RED}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_RED}${LANG[POST_PANEL_INSTRUCTION]}${COLOR_RESET}"
    echo -e "${COLOR_RED}-------------------------------------------------${COLOR_RESET}"
}
