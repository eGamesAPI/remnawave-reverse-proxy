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
    # EOF on stdin leaves the menu instead of re-entering it forever.
    reading "${LANG[LEGIZ_EXTENSIONS_PROMPT]}" LEGIZ_OPTION || return 0
    case $LEGIZ_OPTION in
        1)
            # The code below calls /usr/bin/yq itself, so that binary has to
            # work — a yq elsewhere in PATH or a broken leftover (a wrong
            # architecture) does not count and gets replaced.
            if ! /usr/bin/yq --version >/dev/null 2>&1; then
                echo -e "${COLOR_YELLOW}${LANG[INSTALLING_YQ]}${COLOR_RESET}"

                local yq_arch
                case "$(uname -m)" in
                    x86_64|amd64) yq_arch="amd64" ;;
                    aarch64|arm64) yq_arch="arm64" ;;
                    *)
                        echo -e "${COLOR_RED}$(printf "${LANG[XC_ARCH_UNSUPPORTED]}" "$(uname -m)")${COLOR_RESET}"
                        sleep 2
                        manage_custom_legiz
                        return 1
                        ;;
                esac

                # Staged next to the target (same filesystem, exec allowed
                # unlike a noexec /tmp) and moved in only once it runs.
                local yq_tmp="/usr/bin/yq.tmp"
                if ! wget "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${yq_arch}" -O "$yq_tmp" >/dev/null 2>&1; then
                    rm -f "$yq_tmp"
                    echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOADING_YQ]}${COLOR_RESET}"
                    sleep 2
                    manage_custom_legiz
                    return 1
                fi

                # The release publishes checksums for every artifact: a
                # binary that does not match them never reaches /usr/bin.
                # The checksums line carries many digests per file (crc32,
                # md5, sha1, sha256, ...), so the local sha256 has to match
                # one of the 64-hex tokens of our line.
                local yq_sums="/tmp/yq-checksums" yq_line yq_have
                if ! wget "https://github.com/mikefarah/yq/releases/latest/download/checksums" -O "$yq_sums" >/dev/null 2>&1; then
                    rm -f "$yq_tmp" "$yq_sums"
                    echo -e "${COLOR_RED}${LANG[YQ_CHECKSUM_FAIL]}${COLOR_RESET}"
                    sleep 2
                    manage_custom_legiz
                    return 1
                fi
                yq_line=$(grep -E "^yq_linux_${yq_arch}[[:space:]]" "$yq_sums" | head -n1)
                yq_have=$(sha256sum "$yq_tmp" | cut -d' ' -f1)
                rm -f "$yq_sums"
                if [ -z "$yq_line" ] || ! printf '%s\n' "$yq_line" | tr -s '[:space:]' '\n' | grep -qx "$yq_have"; then
                    rm -f "$yq_tmp"
                    echo -e "${COLOR_RED}${LANG[YQ_CHECKSUM_FAIL]}${COLOR_RESET}"
                    sleep 2
                    manage_custom_legiz
                    return 1
                fi

                if ! chmod +x "$yq_tmp"; then
                    rm -f "$yq_tmp"
                    echo -e "${COLOR_RED}${LANG[ERROR_SETTING_YQ_PERMISSIONS]}${COLOR_RESET}"
                    sleep 2
                    manage_custom_legiz
                    return 1
                fi

                if ! "$yq_tmp" --version >/dev/null 2>&1 || ! mv -f "$yq_tmp" /usr/bin/yq; then
                    rm -f "$yq_tmp"
                    echo -e "${COLOR_RED}${LANG[YQ_DOESNT_WORK_AFTER_INSTALLATION]}${COLOR_RESET}"
                    sleep 2
                    manage_custom_legiz
                    return 1
                fi

                echo -e "${COLOR_GREEN}${LANG[YQ_SUCCESSFULLY_INSTALLED]}${COLOR_RESET}"
                sleep 1
            fi

            manage_sub_page_upload
            manage_custom_legiz
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
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

# The stack that runs the subscription page: the panel's own compose or a
# stand-alone subscription box — the same two homes xchk_webserver knows.
legiz_sub_dir() {
    local dir
    for dir in /opt/remnawave /opt/subscription; do
        if [ -f "$dir/docker-compose.yml" ] \
            && grep -qE '^[[:space:]]*remnawave-subscription-page:' "$dir/docker-compose.yml"; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

manage_sub_page_upload() {
    # A missing container is a dead end for this item only — back to the
    # menu, not out of the whole script.
    if ! docker ps -a --filter "name=remnawave-subscription-page" --format '{{.Names}}' | grep -q "^remnawave-subscription-page$"; then
        printf "${COLOR_RED}${LANG[CONTAINER_NOT_FOUND]}${COLOR_RESET}\n" "remnawave-subscription-page"
        sleep 2
        return 1
    fi

    local sub_dir
    if ! sub_dir=$(legiz_sub_dir); then
        echo -e "${COLOR_RED}${LANG[LEGIZ_SUB_DIR_NOT_FOUND]}${COLOR_RESET}"
        sleep 2
        return 1
    fi

    if [ -d "$sub_dir/index.html" ] || [ -d "$sub_dir/app-config.json" ]; then
        rm -rf "${sub_dir:?}/index.html" "${sub_dir:?}/app-config.json"
    fi

    show_sub_page_menu
    # EOF on stdin returns to the caller instead of re-asking forever.
    reading "${LANG[SELECT_SUB_PAGE_CUSTOM]}" SUB_PAGE_OPTION || return 0

    local index_file="$sub_dir/index.html"
    local docker_compose_file="$sub_dir/docker-compose.yml"

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
            # Back to the legiz menu, which re-shows itself after this call —
            # falling through would strip the compose comments and restart
            # the subscription page for nothing.
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;

        *)
            echo -e "${COLOR_YELLOW}${LANG[SUB_PAGE_SELECT_CHOICE]}${COLOR_RESET}"
            sleep 2
            manage_sub_page_upload
            return 1
            ;;
    esac

    /usr/bin/yq $yq_flags eval -i '... comments=""' "$docker_compose_file"

    sed -i -e '/^  [a-zA-Z-]\+:$/ { x; p; x; }' "$docker_compose_file"

    sed -i '/./,$!d' "$docker_compose_file"

    sed -i -e '/^networks:/i\' -e '' "$docker_compose_file"
    sed -i -e '/^volumes:/i\' -e '' "$docker_compose_file"

    # Guarded twin of manage_panel's helper: a failed `up` would leave the
    # subscription page down behind a green success line.
    command -v compose_run_spinner >/dev/null 2>&1 || compose_run_spinner() {
        local desc="$1"; shift
        local rc_file
        rc_file=$(mktemp)
        ( "$@" > /dev/null 2>&1; echo $? > "$rc_file" ) &
        spinner $! "$desc"
        local rc
        rc=$(cat "$rc_file" 2>/dev/null)
        rm -f "$rc_file"
        return "${rc:-1}"
    }
    # compose runs from the stack dir (override files included), inside a
    # subshell so the caller's working directory stays put.
    if ! (cd "$sub_dir" && compose_run_spinner "${LANG[WAITING]}" docker compose down remnawave-subscription-page) \
        || ! (cd "$sub_dir" && compose_run_spinner "${LANG[WAITING]}" docker compose up -d remnawave-subscription-page); then
        echo -e "${COLOR_RED}$(printf "${LANG[COMPOSE_UP_FAIL]}" "$sub_dir" "$sub_dir")${COLOR_RESET}"
        return 1
    fi
    echo -e "${COLOR_GREEN}${LANG[SUB_PAGE_UPDATED_SUCCESS]}${COLOR_RESET}"
}
