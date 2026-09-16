#!/bin/bash
# Module: Custom extensions by legiz (subscription page templates)

show_custom_legiz_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_5]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SELECT_SUB_PAGE_CUSTOM1]}${COLOR_RESET}" # Custom sub page
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_custom_legiz() {
    show_custom_legiz_menu
    reading "${LANG[LEGIZ_EXTENSIONS_PROMPT]}" LEGIZ_OPTION
    case $LEGIZ_OPTION in
        1)
            if ! command -v yq >/dev/null 2>&1; then
                echo -e "${COLOR_YELLOW}${LANG[INSTALLING_YQ]}${COLOR_RESET}"

                if ! wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq >/dev/null 2>&1; then
                    echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOADING_YQ]}${COLOR_RESET}"
                    sleep 2
                    log_clear
                    manage_custom_legiz
                    return 1
                fi

                if ! chmod +x /usr/bin/yq; then
                    echo -e "${COLOR_RED}${LANG[ERROR_SETTING_YQ_PERMISSIONS]}${COLOR_RESET}"
                    sleep 2
                    log_clear
                    manage_custom_legiz
                    return 1
                fi

                echo -e "${COLOR_GREEN}${LANG[YQ_SUCCESSFULLY_INSTALLED]}${COLOR_RESET}"
                sleep 1
            fi

            if ! /usr/bin/yq --version >/dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[YQ_DOESNT_WORK_AFTER_INSTALLATION]}${COLOR_RESET}"
                sleep 2
                log_clear
                manage_custom_legiz
                return 1
            fi

            manage_sub_page_upload
            log_clear
            manage_custom_legiz
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_custom_legiz
            ;;
    esac
}

show_sub_page_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SELECT_SUB_PAGE_CUSTOM2]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. Orion web page template (support custom app list)${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}2. ${LANG[RESTORE_SUB_PAGE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

download_with_fallback() {
    local file_url="$1"
    local dest_file="$2"

    # Mirror prefixes in the repo-wide order: direct, then GitHub proxies
    local mirror_prefixes=(
        ""
        "https://gh-proxy.com/"
        "https://ghfast.top/"
        "https://ghproxy.net/"
    )

    local temp_file="${dest_file}.tmp"
    local download_success=false
    local first_attempt=true

    for mirror_prefix in "${mirror_prefixes[@]}"; do
        if [ "$first_attempt" = "false" ]; then
            echo -e "${COLOR_YELLOW}${LANG[DOWNLOAD_FALLBACK]}${COLOR_RESET}"
        fi
        first_attempt=false

        local mirror_url="${mirror_prefix}${file_url}"
        if command -v curl &> /dev/null; then
            local http_code
            http_code=$(curl -sL -w "%{http_code}" --connect-timeout 10 --max-time 30 "$mirror_url" -o "$temp_file" 2>/dev/null)
            if [ "$http_code" = "200" ] && [ -s "$temp_file" ]; then
                download_success=true
                break
            fi
        elif command -v wget &> /dev/null; then
            if wget -q --timeout=10 --tries=1 "$mirror_url" -O "$temp_file" 2>/dev/null && [ -s "$temp_file" ]; then
                download_success=true
                break
            fi
        fi
    done

    if [ "$download_success" = "true" ]; then
        mv "$temp_file" "$dest_file"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

manage_sub_page_upload() {
    if [ -d "/opt/remnawave/index.html" ] || [ -d "/opt/remnawave/app-config.json" ]; then
        rm -rf "/opt/remnawave/index.html" "/opt/remnawave/app-config.json"
    fi

    if ! docker ps -a --filter "name=remnawave-subscription-page" --format '{{.Names}}' | grep -q "^remnawave-subscription-page$"; then
        printf "${COLOR_RED}${LANG[CONTAINER_NOT_FOUND]}${COLOR_RESET}\n" "remnawave-subscription-page"
        sleep 2
        log_clear
        exit 1
    fi

    show_sub_page_menu
    reading "${LANG[SELECT_SUB_PAGE_CUSTOM]}" SUB_PAGE_OPTION

    local index_file="/opt/remnawave/index.html"
    local docker_compose_file="/opt/remnawave/docker-compose.yml"

    # yq >= 4.41 warns (and merges anchors off-spec) unless this flag is set;
    # older yq builds don't know it, so pass it only when supported
    local yq_flags=""
    if /usr/bin/yq --help 2>/dev/null | grep -q -- '--yaml-fix-merge-anchor-to-spec'; then
        yq_flags="--yaml-fix-merge-anchor-to-spec"
    fi

    case $SUB_PAGE_OPTION in
        1)
            [ -f "$index_file" ] && rm -f "$index_file"

            echo -e "${COLOR_YELLOW}${LANG[UPLOADING_SUB_PAGE]}${COLOR_RESET}"
            echo -e ""
            local index_url="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
            if ! download_with_fallback "$index_url" "$index_file"; then
                echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                sleep 2
                log_clear
                return 1
            fi

            /usr/bin/yq $yq_flags eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            /usr/bin/yq $yq_flags eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"
            ;;

        2)
            [ -f "$index_file" ] && rm -f "$index_file"

            /usr/bin/yq $yq_flags eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            ;;

        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            manage_custom_legiz
            ;;

        *)
            echo -e "${COLOR_YELLOW}${LANG[SUB_PAGE_SELECT_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_sub_page_upload
            return 1
            ;;
    esac

    /usr/bin/yq $yq_flags eval -i '... comments=""' "$docker_compose_file"

    sed -i -e '/^  [a-zA-Z-]\+:$/ { x; p; x; }' "$docker_compose_file"

    sed -i '/./,$!d' "$docker_compose_file"

    sed -i -e '/^networks:/i\' -e '' "$docker_compose_file"
    sed -i -e '/^volumes:/i\' -e '' "$docker_compose_file"

    cd /opt/remnawave || return 1
    docker compose down remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    echo -e "${COLOR_GREEN}${LANG[SUB_PAGE_UPDATED_SUCCESS]}${COLOR_RESET}"
}
