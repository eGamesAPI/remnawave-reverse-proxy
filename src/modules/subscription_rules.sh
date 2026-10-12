#!/bin/bash
# Module: subscription_rules — panel-side subscription response rules and
# the HWID device limit (Remnawave Subscription Settings), per
# https://docs.rw/learn-en/routing-rules/ and
# https://docs.rw/features/hwid-device-limit.
#
# Response Rules decide WHAT the panel answers to a subscription request:
# every rule matches request headers (user-agent, x-hwid, ...) and the
# first match picks the response — a config format, the browser page, or a
# rejection (403/404/451/socket drop). The HWID limit binds a subscription
# to N devices (Happ/INCY send the x-hwid header). Both live in the panel
# database: this module only reads and writes them through the panel API,
# keeping timestamped backups before every replacement.

SRR_PANEL_HOST="127.0.0.1:3000"
SRR_BACKUP_DIR="${DIR_REMNAWAVE}subscription-rules"
SRR_SETTINGS_JSON=""

srr_api() {
    local method="$1" path="$2" data="${3:-}"
    make_api_request "$method" "http://${SRR_PANEL_HOST}${path}" "$token" "$data"
}

# The full settings object (.response of the endpoint) into SRR_SETTINGS_JSON.
srr_fetch_settings() {
    local response
    response=$(srr_api "GET" "/api/subscription-settings?_=$(date +%s)")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SRR_API_FAIL]}" "$response")"
        return 1
    fi
    SRR_SETTINGS_JSON=$(echo "$response" | jq -c '.response')
}

# Send an already-built PATCH body and refresh the local settings snapshot.
# The panel echoes the stored settings back — a missing uuid in the echo
# means the write never landed.
srr_api_patch_body() {
    local response
    response=$(srr_api "PATCH" "/api/subscription-settings" "$1")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SRR_API_FAIL]}" "$response")"
        return 1
    fi
    SRR_SETTINGS_JSON=$(echo "$response" | jq -c '.response')
}

# --- state accessors ------------------------------------------------------------------

srr_setting() { # $1 = jq path, e.g. .hwidSettings.enabled
    echo "$SRR_SETTINGS_JSON" | jq -r "$1 // empty" 2>/dev/null
}

srr_rules_count() {
    echo "$SRR_SETTINGS_JSON" | jq -r '.responseRules.rules | length' 2>/dev/null
}

srr_hwid_enabled() { [ "$(srr_setting '.hwidSettings.enabled')" = "true" ]; }

# Short localized label for a responseType enum value.
srr_type_label() {
    case "$1" in
        XRAY_JSON)       echo "${LANG[SRR_TYPE_XRAYJSON]}" ;;
        XRAY_BASE64)     echo "${LANG[SRR_TYPE_BASE64]}" ;;
        MIHOMO)          echo "Mihomo" ;;
        STASH)           echo "Stash" ;;
        CLASH)           echo "Clash" ;;
        SINGBOX)         echo "Sing-box" ;;
        BROWSER)         echo "${LANG[SRR_TYPE_BROWSER]}" ;;
        BLOCK)           echo "${LANG[SRR_TYPE_403]}" ;;
        STATUS_CODE_404) echo "${LANG[SRR_TYPE_404]}" ;;
        STATUS_CODE_451) echo "${LANG[SRR_TYPE_451]}" ;;
        SOCKET_DROP)     echo "${LANG[SRR_TYPE_DROP]}" ;;
        *)               echo "$1" ;;
    esac
}

# --- state display --------------------------------------------------------------------

srr_show_state() {
    # Character counting for the name column must not depend on the SSH
    # session locale: C.UTF-8 exists everywhere Debian does (the spinner
    # relies on it too)
    local LC_ALL=C.UTF-8
    local count hwid_limit json_base paths_blocked i enabled type label
    count=$(srr_rules_count)
    if [ -n "$count" ] && [ "$count" != "null" ] && [ "$count" -gt 0 ] 2>/dev/null; then
        echo -e " ${COLOR_WHITE}$(printf "${LANG[SRR_STATE_RULES_COUNT]}" "$count")${COLOR_RESET}"
        local mark
        i=1
        while IFS=$'\t' read -r enabled type label; do
            if [ "$enabled" = "true" ]; then
                mark="${COLOR_GREEN}✓${COLOR_RESET}"
            else
                mark="${COLOR_RED}✗${COLOR_RESET}"
            fi
            # %b interprets the escapes inside the colored mark, %s would
            # print them raw
            printf "   ${COLOR_YELLOW}%s.${COLOR_RESET} %b ${COLOR_WHITE}%s%s${COLOR_RESET} ${COLOR_GRAY}→${COLOR_RESET} ${COLOR_WHITE}%s${COLOR_RESET}\n" \
                "$i" "$mark" "$label" \
                "$(printf '%*s' $(( 32 - ${#label} > 0 ? 32 - ${#label} : 1 )) '')" \
                "$(srr_type_label "$type")"
            i=$((i + 1))
        done < <(echo "$SRR_SETTINGS_JSON" | jq -r '.responseRules.rules[] | [(.enabled|tostring), .responseType, (.name|tostring)] | @tsv')
    else
        echo -e " ${COLOR_WHITE}${LANG[SRR_STATE_RULES_NONE]}${COLOR_RESET}"
        echo -e "   ${COLOR_GRAY}${LANG[SRR_STATE_RULES_NONE_HINT]}${COLOR_RESET}"
    fi

    if srr_hwid_enabled; then
        hwid_limit=$(srr_setting '.hwidSettings.fallbackDeviceLimit')
        echo -e " ${COLOR_GREEN}✓${COLOR_RESET} ${COLOR_WHITE}$(printf "${LANG[SRR_STATE_HWID_ON]}" "${hwid_limit:-3}")${COLOR_RESET}"
    else
        echo -e " ${COLOR_RED}✗${COLOR_RESET} ${COLOR_WHITE}${LANG[SRR_STATE_HWID_OFF]}${COLOR_RESET}"
    fi

    json_base=$(srr_setting '.serveJsonAtBaseSubscription')
    if [ "$json_base" = "true" ]; then
        echo -e " ${COLOR_WHITE}${LANG[SRR_STATE_JSON_ON]}${COLOR_RESET}"
    else
        echo -e " ${COLOR_WHITE}${LANG[SRR_STATE_JSON_OFF]}${COLOR_RESET}"
    fi

    paths_blocked=$(srr_setting '.responseRules.settings.disableSubscriptionAccessByPath')
    if [ "$paths_blocked" = "true" ]; then
        echo -e " ${COLOR_WHITE}${LANG[SRR_STATE_PATHS_BLOCKED]}${COLOR_RESET}"
    else
        echo -e " ${COLOR_WHITE}${LANG[SRR_STATE_PATHS_ALLOWED]}${COLOR_RESET}"
    fi
}

# Every rule with its conditions and modifications, for the detail view.
srr_rules_detail() {
    local count
    count=$(srr_rules_count)
    { [ -n "$count" ] && [ "$count" != "null" ] && [ "$count" -gt 0 ] 2>/dev/null; } || {
        echo -e " ${COLOR_GRAY}${LANG[SRR_STATE_RULES_NONE]}${COLOR_RESET}"
        return 0
    }

    local idx name enabled operator rtype cond_count
    while IFS=$'\t' read -r idx name enabled operator rtype; do
        echo -e ""
        if [ "$enabled" = "true" ]; then
            printf " ${COLOR_GREEN}✓${COLOR_RESET} ${COLOR_WHITE}%s. %s${COLOR_RESET} ${COLOR_GRAY}[%s → %s]${COLOR_RESET}\n" \
                "$idx" "$name" "$operator" "$(srr_type_label "$rtype")"
        else
            printf " ${COLOR_RED}✗${COLOR_RESET} ${COLOR_WHITE}%s. %s${COLOR_RESET} ${COLOR_GRAY}[%s → %s, %s]${COLOR_RESET}\n" \
                "$idx" "$name" "$operator" "$(srr_type_label "$rtype")" "${LANG[SRR_RULE_DISABLED]}"
        fi
        echo "$SRR_SETTINGS_JSON" | jq -r --argjson i "$idx" --arg ci "${LANG[SRR_RULE_CASE_INSENSITIVE]}" \
            '.responseRules.rules[($i - 1)].conditions // [] | .[] |
             "   \(.headerName) \(.operator) \"\(.value)\"\(if .caseSensitive then "" else "  (" + $ci + ")" end)"'
        cond_count=$(echo "$SRR_SETTINGS_JSON" | jq -r --argjson i "$idx" '.responseRules.rules[($i - 1)].conditions | length')
        [ "$cond_count" = "0" ] && echo -e "   ${COLOR_GRAY}${LANG[SRR_RULE_NO_CONDITIONS]}${COLOR_RESET}"
    done < <(echo "$SRR_SETTINGS_JSON" | jq -r '.responseRules.rules | to_entries[] |
        [(.key + 1 | tostring), .value.name, (.value.enabled | tostring), (.value.operator // "AND"), (.value.responseType // "")] | @tsv')
}

# --- presets --------------------------------------------------------------------------

# The browser rule and the catch-all ride in every preset, only the client
# tiers differ (allow_all is the bare catch-all — the honest "rules off").
# disableSubscriptionAccessByPath is the user's own setting — presets never
# touch it (read back from the current config).
srr_build_preset() { # $1 = strict|standard|allow_all
    local mode="$1"
    local paths_flag
    paths_flag=$(srr_setting '.responseRules.settings.disableSubscriptionAccessByPath')
    [ "$paths_flag" = "true" ] || paths_flag="false"

    local strict_tier="" allow_all="false"
    if [ "$mode" = "strict" ]; then
        # jq emits a STREAM for a top-level "{...},{...}" — an array keeps
        # the whole tier one JSON document for --argjson below. Tier order
        # matters: HWID-capable Xray clients, then HWID-capable Clash-family
        # clients (FlClashX/Koala Clash get the Mihomo format their core
        # speaks), then the rest of the known apps.
        strict_tier=$(jq -nc \
            --arg n1 "${LANG[SRR_PRESET_STRICT_HAPP_NAME]}" \
            --arg d1 "${LANG[SRR_PRESET_STRICT_HAPP_DESC]}" \
            --arg n2 "${LANG[SRR_PRESET_STRICT_CLASH_NAME]}" \
            --arg d2 "${LANG[SRR_PRESET_STRICT_CLASH_DESC]}" \
            --arg n3 "${LANG[SRR_PRESET_STRICT_SINGBOX_NAME]}" \
            --arg d3 "${LANG[SRR_PRESET_STRICT_SINGBOX_DESC]}" \
            --arg n4 "${LANG[SRR_PRESET_STRICT_CLIENTS_NAME]}" \
            --arg d4 "${LANG[SRR_PRESET_STRICT_CLIENTS_DESC]}" \
            '[{name: $n1, description: $d1, enabled: true, operator: "AND",
               conditions: [
                 {headerName: "user-agent", operator: "REGEX", value: "^(Happ|INCY|RenoarX)/", caseSensitive: false},
                 {headerName: "x-hwid", operator: "REGEX", value: "^[a-zA-Z0-9=-]{10,64}$", caseSensitive: true}
               ],
               responseType: "XRAY_JSON"},
              {name: $n2, description: $d2, enabled: true, operator: "AND",
               conditions: [
                 {headerName: "user-agent", operator: "REGEX", value: "^(FlClash ?X|koala-clash|prizrak-box|rabbit(hole)?|clash-?mi|Flowvy|ClodClash)/", caseSensitive: false},
                 {headerName: "x-hwid", operator: "REGEX", value: "^[a-zA-Z0-9=-]{10,64}$", caseSensitive: true}
               ],
               responseType: "MIHOMO"},
              {name: $n3, description: $d3, enabled: true, operator: "AND",
               conditions: [
                 {headerName: "user-agent", operator: "REGEX", value: "^(karing|inhive|throne|deskbox)/", caseSensitive: false},
                 {headerName: "x-hwid", operator: "REGEX", value: "^[a-zA-Z0-9=-]{10,64}$", caseSensitive: true}
               ],
               responseType: "SINGBOX"},
              {name: $n4, description: $d4, enabled: true, operator: "AND",
               conditions: [
                 {headerName: "user-agent", operator: "REGEX",
                  value: "^(v2rayN|v2rayNG|v2raytun|V2Box|Streisand|Shadowrocket|sing-box|Karing|FlClash|Flowvy|prizrak-box|koala-clash|rabbit|clash-?mi|inhive|renoarx|throne|deskbox|sfa|sfi|sfm|sft|ktor-client|ClodClash)",
                  caseSensitive: false}
               ],
               responseType: "XRAY_BASE64"}]')
    elif [ "$mode" = "allow_all" ]; then
        allow_all="true"
    fi

    jq -nc \
        --arg paths "$paths_flag" \
        --arg allow_all "$allow_all" \
        --argjson strict "${strict_tier:-[]}" \
        --arg bn "${LANG[SRR_PRESET_BROWSER_NAME]}" \
        --arg bd "${LANG[SRR_PRESET_BROWSER_DESC]}" \
        --arg fn "${LANG[SRR_PRESET_FALLBACK_NAME]}" \
        --arg fd "${LANG[SRR_PRESET_FALLBACK_DESC]}" \
        --arg fd404 "${LANG[SRR_PRESET_FALLBACK_404_DESC]}" \
        '{version: "1",
          settings: {disableSubscriptionAccessByPath: ($paths == "true")},
          rules: ($strict +
            (if $allow_all == "true" then [] else [
              {name: $bn, description: $bd, enabled: true, operator: "AND",
               conditions: [{headerName: "user-agent", operator: "CONTAINS", value: "Mozilla", caseSensitive: false}],
               responseType: "BROWSER"}
            ] end) +
            [
              {name: $fn,
               description: (if ($strict | length) > 0 then $fd404 else $fd end),
               enabled: true, operator: "AND", conditions: [],
               responseType: (if ($strict | length) > 0 then "STATUS_CODE_404" else "XRAY_BASE64" end)}
            ])}'
}

srr_backup_current() {
    local count target
    count=$(srr_rules_count)
    { [ -n "$count" ] && [ "$count" != "null" ] && [ "$count" -gt 0 ] 2>/dev/null; } || return 0
    mkdir -p "$SRR_BACKUP_DIR"
    target="$SRR_BACKUP_DIR/rules-$(date +%Y%m%d-%H%M%S).json"
    echo "$SRR_SETTINGS_JSON" | jq '.responseRules' > "$target"
    # Keep the ten freshest copies only.
    ls -1t "$SRR_BACKUP_DIR"/rules-*.json 2>/dev/null | tail -n +11 | while IFS= read -r old; do rm -f "$old"; done
    echo -e "${COLOR_YELLOW}$(printf "${LANG[SRR_BACKUP_SAVED]}" "$(basename "$target")")${COLOR_RESET}"
}

srr_apply_preset() { # $1 = strict|standard|allow_all
    local mode="$1" preset_title new_rules old_count new_count rules
    case "$mode" in
        strict)    preset_title="${LANG[SRR_PRESET_STRICT_TITLE]}" ;;
        standard)  preset_title="${LANG[SRR_PRESET_STD_TITLE]}" ;;
        allow_all) preset_title="${LANG[SRR_PRESET_ALLOW_TITLE]}" ;;
    esac

    rules=$(srr_build_preset "$mode") || return 1
    old_count=$(srr_rules_count); [ -n "$old_count" ] && [ "$old_count" != "null" ] || old_count=0
    new_count=$(echo "$rules" | jq -r '.rules | length')

    echo -e ""
    if ! reading_yn "$(printf "${LANG[SRR_PRESET_CONFIRM]}" "$old_count" "$preset_title" "$new_count")" confirm; then
        echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"
        return 1
    fi

    srr_backup_current
    local body
    body=$(jq -nc --argjson s "$SRR_SETTINGS_JSON" --argjson rules "$rules" \
        '{uuid: $s.uuid, responseRules: $rules}')
    if ! srr_api_patch_body "$body"; then
        return 1
    fi

    echo -e "${COLOR_GREEN}${LANG[SRR_PRESET_APPLIED]}${COLOR_RESET}"
    if [ "$mode" = "strict" ]; then
        echo -e "${COLOR_YELLOW}${LANG[SRR_PRESET_STRICT_WARN]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_GRAY}${LANG[SRR_CHANGED_HINT]}${COLOR_RESET}"
}

# --- toggles --------------------------------------------------------------------------

srr_hwid_toggle() {
    local enabled limit announce body
    if srr_hwid_enabled; then
        if ! reading_yn "${LANG[SRR_HWID_OFF_CONFIRM]}" confirm; then
            echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"
            return 1
        fi
        body=$(jq -nc --argjson s "$SRR_SETTINGS_JSON" \
            '{uuid: $s.uuid,
              hwidSettings: {enabled: false,
                             fallbackDeviceLimit: ($s.hwidSettings.fallbackDeviceLimit // 3),
                             maxDevicesAnnounce: ($s.hwidSettings.maxDevicesAnnounce // null)}}')
        if srr_api_patch_body "$body"; then
            echo -e "${COLOR_GREEN}${LANG[SRR_HWID_DISABLED]}${COLOR_RESET}"
        fi
        return 0
    fi

    limit=$(srr_setting '.hwidSettings.fallbackDeviceLimit')
    [ -n "$limit" ] || limit=3
    while true; do
        reading "$(printf "${LANG[SRR_HWID_LIMIT_PROMPT]}" "$limit")" answer || return 1
        if [ -z "$answer" ]; then
            answer="$limit"
            break
        fi
        if [[ "$answer" =~ ^[0-9]+$ ]] && [ "$answer" -ge 1 ] && [ "$answer" -le 20 ]; then
            limit="$answer"
            break
        fi
        echo -e "${COLOR_RED}${LANG[SRR_HWID_LIMIT_INVALID]}${COLOR_RESET}"
    done

    echo -e "${COLOR_YELLOW}${LANG[SRR_HWID_WARN]}${COLOR_RESET}"
    if ! reading_yn "$(printf "${LANG[SRR_HWID_ON_CONFIRM]}" "$limit")" confirm; then
        echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"
        return 1
    fi
    announce=$(srr_setting '.hwidSettings.maxDevicesAnnounce')
    body=$(jq -nc --argjson s "$SRR_SETTINGS_JSON" --argjson lim "$limit" --arg ann "${announce:-null}" \
        '{uuid: $s.uuid,
          hwidSettings: {enabled: true,
                         fallbackDeviceLimit: $lim,
                         maxDevicesAnnounce: (try ($ann | if . == "null" then null else . end) catch null)}}')
    if srr_api_patch_body "$body"; then
        echo -e "${COLOR_GREEN}$(printf "${LANG[SRR_HWID_ENABLED]}" "$limit")${COLOR_RESET}"
        echo -e "${COLOR_GRAY}${LANG[SRR_CHANGED_HINT]}${COLOR_RESET}"
    fi
}

srr_json_base_toggle() {
    local current body
    current=$(srr_setting '.serveJsonAtBaseSubscription')
    [ "$current" = "true" ] && current=true || current=false
    body=$(jq -nc --argjson s "$SRR_SETTINGS_JSON" --argjson v "$([ "$current" = true ] && echo false || echo true)" \
        '{uuid: $s.uuid, serveJsonAtBaseSubscription: $v}')
    if srr_api_patch_body "$body"; then
        if [ "$current" = "true" ]; then
            echo -e "${COLOR_GREEN}${LANG[SRR_JSON_DISABLED_MSG]}${COLOR_RESET}"
        else
            echo -e "${COLOR_GREEN}${LANG[SRR_JSON_ENABLED_MSG]}${COLOR_RESET}"
        fi
        echo -e "${COLOR_GRAY}${LANG[SRR_CHANGED_HINT]}${COLOR_RESET}"
    fi
}

srr_paths_toggle() {
    local count current body
    count=$(srr_rules_count)
    { [ -n "$count" ] && [ "$count" != "null" ] && [ "$count" -gt 0 ] 2>/dev/null; } || {
        echo -e "${COLOR_YELLOW}${LANG[SRR_PATHS_NEED_RULES]}${COLOR_RESET}"
        return 1
    }
    current=$(srr_setting '.responseRules.settings.disableSubscriptionAccessByPath')
    [ "$current" = "true" ] && current=true || current=false
    body=$(jq -nc --argjson s "$SRR_SETTINGS_JSON" --argjson v "$([ "$current" = true ] && echo false || echo true)" \
        '{uuid: $s.uuid,
          responseRules: ($s.responseRules | .settings.disableSubscriptionAccessByPath = $v)}')
    if srr_api_patch_body "$body"; then
        if [ "$current" = "true" ]; then
            echo -e "${COLOR_GREEN}${LANG[SRR_PATHS_ALLOWED_MSG]}${COLOR_RESET}"
        else
            echo -e "${COLOR_GREEN}${LANG[SRR_PATHS_BLOCKED_MSG]}${COLOR_RESET}"
        fi
        echo -e "${COLOR_GRAY}${LANG[SRR_CHANGED_HINT]}${COLOR_RESET}"
    fi
}

srr_restore() {
    local backups=() pick i file count ts body
    while IFS= read -r file; do
        [ -n "$file" ] && backups+=("$file")
    done < <(ls -1t "$SRR_BACKUP_DIR"/rules-*.json 2>/dev/null)
    if [ "${#backups[@]}" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}${LANG[SRR_RESTORE_NONE]}${COLOR_RESET}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SRR_RESTORE_TITLE]}${COLOR_RESET}"
    echo -e ""
    i=1
    for file in "${backups[@]}"; do
        count=$(jq -r '.rules | length' "$file" 2>/dev/null)
        ts=$(basename "$file" | sed 's/^rules-//; s/\.json$//; s/\(^[0-9]\{4\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)-\([0-9]\{2\}\)\([0-9]\{2\}\)\([0-9]\{2\}\)$/\1-\2-\3 \4:\5:\6/')
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${ts}${COLOR_RESET} ${COLOR_GRAY}· $(printf "${LANG[SRR_RESTORE_COUNT]}" "${count:-?}")${COLOR_RESET}"
        i=$((i + 1))
    done
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""

    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$((i - 1))")" pick || return 1
    [ "$pick" = "0" ] && return 1
    if ! [[ "$pick" =~ ^[0-9]+$ ]] || [ "$pick" -lt 1 ] || [ "$pick" -gt "${#backups[@]}" ]; then
        printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$((i - 1))"
        return 1
    fi
    file="${backups[$((pick - 1))]}"
    count=$(jq -r '.rules | length' "$file" 2>/dev/null)

    if ! reading_yn "$(printf "${LANG[SRR_RESTORE_CONFIRM]}" "$(basename "$file")" "$count")" confirm; then
        echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"
        return 1
    fi
    # The current state gets its own copy too, so a wrong restore can be
    # undone by restoring right back.
    srr_backup_current
    body=$(jq -nc --argjson s "$SRR_SETTINGS_JSON" --slurpfile r "$file" \
        '{uuid: $s.uuid, responseRules: $r[0]}')
    if srr_api_patch_body "$body"; then
        echo -e "${COLOR_GREEN}${LANG[SRR_RESTORE_DONE]}${COLOR_RESET}"
    fi
}

# --- menu -----------------------------------------------------------------------------

show_subscription_rules_menu() {
    get_panel_token || return 1
    srr_fetch_settings || return 1

    local hwid_on json_on paths_blocked
    srr_hwid_enabled && hwid_on=true || hwid_on=false
    [ "$(srr_setting '.serveJsonAtBaseSubscription')" = "true" ] && json_on=true || json_on=false
    [ "$(srr_setting '.responseRules.settings.disableSubscriptionAccessByPath')" = "true" ] && paths_blocked=true || paths_blocked=false
    local hwid_limit
    hwid_limit=$(srr_setting '.hwidSettings.fallbackDeviceLimit'); [ -n "$hwid_limit" ] || hwid_limit=3

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SRR_MENU_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SRR_DOC_LINK]}${COLOR_RESET}"
    echo -e ""
    srr_show_state
    echo -e ""

    echo -e "${COLOR_YELLOW}1. ${COLOR_WHITE}${LANG[SRR_MENU_SHOW]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}2. ${COLOR_WHITE}${LANG[SRR_MENU_PRESET_STD]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SRR_MENU_PRESET_STD_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${COLOR_WHITE}${LANG[SRR_MENU_PRESET_STRICT]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SRR_MENU_PRESET_STRICT_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${COLOR_WHITE}${LANG[SRR_MENU_ALLOW_ALL]}${COLOR_RESET}"
    echo -e ""
    if [ "$hwid_on" = true ]; then
        echo -e "${COLOR_YELLOW}5. ${COLOR_WHITE}$(printf "${LANG[SRR_MENU_HWID_OFF]}" "$hwid_limit")${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}5. ${COLOR_WHITE}${LANG[SRR_MENU_HWID_ON]}${COLOR_RESET}"
    fi
    if [ "$json_on" = true ]; then
        echo -e "${COLOR_YELLOW}6. ${COLOR_WHITE}${LANG[SRR_MENU_JSON_OFF]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}6. ${COLOR_WHITE}${LANG[SRR_MENU_JSON_ON]}${COLOR_RESET}"
    fi
    if [ "$paths_blocked" = true ]; then
        echo -e "${COLOR_YELLOW}7. ${COLOR_WHITE}${LANG[SRR_MENU_PATHS_ON]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}7. ${COLOR_WHITE}${LANG[SRR_MENU_PATHS_OFF]}${COLOR_RESET}"
    fi
    echo -e "${COLOR_YELLOW}8. ${COLOR_WHITE}${LANG[SRR_MENU_RESTORE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""

    local pick
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 8)" pick || return 0
    case "$pick" in
        1)
            srr_rules_detail
            echo -e ""
            echo -e "${COLOR_GRAY}${LANG[SRR_ANY_KEY_HINT]}${COLOR_RESET}"
            read -r -n 1 -s _ || true
            ;;
        2)
            srr_apply_preset "standard"
            sleep 2
            ;;
        3)
            srr_apply_preset "strict"
            sleep 2
            ;;
        4)
            srr_apply_preset "allow_all"
            sleep 2
            ;;
        5)
            srr_hwid_toggle
            sleep 2
            ;;
        6)
            srr_json_base_toggle
            sleep 2
            ;;
        7)
            srr_paths_toggle
            sleep 2
            ;;
        8)
            srr_restore
            sleep 2
            ;;
        0) return 0 ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 8
            sleep 1
            ;;
    esac
    show_subscription_rules_menu
}

manage_subscription_rules() {
    # The state block and every action talk to the panel API right away.
    load_api_module || return 1
    if ! panel_is_installed; then
        echo -e "${COLOR_RED}${LANG[SRR_NO_PANEL]}${COLOR_RESET}"
        return 1
    fi
    show_subscription_rules_menu
}
