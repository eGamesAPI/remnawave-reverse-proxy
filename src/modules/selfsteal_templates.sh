#!/bin/bash
# Module: SelfSteal Templates

SITE_CLONE_UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

show_template_source_options() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CHOOSE_TEMPLATE_SOURCE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SIMPLE_WEB_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[SNI_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[NOTHING_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[SITE_CLONE_TEMPLATES]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

randomhtml_start_spinner() {
    echo -e "${COLOR_YELLOW}${1:-${LANG[RANDOM_TEMPLATE]}}${COLOR_RESET}"
    sleep 1
    spinner $$ "${LANG[WAITING]}" &
    spinner_pid=$!
}

randomhtml_stop_spinner() {
    if [ -n "${spinner_pid:-}" ]; then
        kill "${spinner_pid}" 2>/dev/null
        wait "${spinner_pid}" 2>/dev/null
    fi
    printf "\r\033[K" 2>/dev/null > /dev/tty || printf "\r\033[K"
}

randomhtml_fail() {
    local message="$1"

    randomhtml_stop_spinner

    echo "${message}"

    cd /opt/ 2>/dev/null || true
    rm -rf /opt/simple-web-templates-*/ /opt/sni-templates-*/ /opt/nothing-sni-*/ /opt/site-clone-*/ 2>/dev/null

    return 1
}

randomhtml_download() {
    local url="$1"

    rm -f main.zip
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 --speed-limit 1024 --speed-time 60 -o main.zip "$url" 2>/dev/null || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=60 --tries=1 -O main.zip "$url" 2>/dev/null || return 1
    else
        return 1
    fi

    [ -s main.zip ] && [ "$(head -c 2 main.zip)" = "PK" ]
}

randomhtml_fetch() {
    local template_source="$1"

    cd /opt/ || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }

    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-*/ sni-templates-*/ nothing-sni-*/ 2>/dev/null

    local template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/6b7690b37af85c35117b6da65a36b1b3e0503477.zip"
        "https://github.com/distillium/sni-templates/archive/99fafe48b41060f1225592b472994af6c21b057d.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/58a6d1b012ad87d6194c64feb81c0a8801db3f93.zip"
    )

    if [ -z "$template_source" ]; then
        selected_url=${template_urls[$RANDOM % ${#template_urls[@]}]}
    else
        if [ "$template_source" = "simple" ]; then
            selected_url=${template_urls[0]}  # Simple web templates
        elif [ "$template_source" = "sni" ]; then
            selected_url=${template_urls[1]}  # Sni templates
        elif [ "$template_source" = "nothing" ]; then
            selected_url=${template_urls[2]}  # Nothing templates
        else
            selected_url=${template_urls[1]}  # Default to Sni templates
        fi
    fi

    local download_prefixes=(
        ""
        "https://gh-proxy.com/"
        "https://ghfast.top/"
        "https://ghproxy.net/"
    )
    local download_ok=false
    local mirror_prefix dl_round

    for dl_round in 1 2; do
        for mirror_prefix in "${download_prefixes[@]}"; do
            if randomhtml_download "${mirror_prefix}${selected_url}"; then
                download_ok=true
                break
            fi
        done
        [ "$download_ok" = "true" ] && break
        echo "${LANG[DOWNLOAD_FAIL]}"
        sleep 3
    done

    if [ "$download_ok" != "true" ]; then
        randomhtml_fail "${LANG[DOWNLOAD_FAIL]}"
        return 1
    fi

    unzip -o main.zip &>/dev/null || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
    rm -f main.zip

    local archive_ref
    archive_ref="${selected_url##*/}"
    archive_ref="${archive_ref%.zip}"

    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        cd "simple-web-templates-${archive_ref}" 2>/dev/null || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
        rm -rf assets ".gitattributes" "README.md" "_config.yml" 2>/dev/null
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        cd "nothing-sni-${archive_ref}" 2>/dev/null || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
        rm -rf .github README.md 2>/dev/null
    else
        cd "sni-templates-${archive_ref}" 2>/dev/null || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi
}

randomhtml_template_list() {
    if [[ "$selected_url" == *"nothing-sni"* ]]; then
        find . -maxdepth 1 -type f -name "*.html" | sed 's|^\./||' | sort -V
    else
        local template_dir
        for template_dir in */; do
            template_dir="${template_dir%/}"
            if [ -n "$(find "$template_dir" -type f -name "*.html" -print -quit)" ]; then
                printf '%s\n' "$template_dir"
            fi
        done | sort
    fi
}

randomhtml_pick_random() {
    mapfile -t templates < <(randomhtml_template_list)
    if (( ${#templates[@]} == 0 )); then
        randomhtml_fail "${LANG[UNPACK_ERROR]}"
        return 1
    fi

    RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"

    if [[ "$selected_url" == *"distillium"* && "$RandomHTML" == "503 error pages" ]]; then
        cd "$RandomHTML" || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
        versions=("v1" "v2")
        RandomVersion="${versions[$RANDOM % ${#versions[@]}]}"
        RandomHTML="$RandomHTML/$RandomVersion"
        cd ..
    fi
}

randomhtml_pick_specific() {
    mapfile -t templates < <(randomhtml_template_list)
    if (( ${#templates[@]} == 0 )); then
        randomhtml_fail "${LANG[UNPACK_ERROR]}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[AVAILABLE_TEMPLATES]}${COLOR_RESET}"
    echo -e ""
    local idx
    for idx in "${!templates[@]}"; do
        echo -e "${COLOR_YELLOW}$((idx + 1)). ${COLOR_RESET}${templates[$idx]}"
    done
    echo -e ""

    local template_pick
    while true; do
        reading "${LANG[ENTER_TEMPLATE_NUMBER]}" template_pick
        if [ "$template_pick" = "0" ]; then
            randomhtml_fail "${LANG[EXIT]}"
            return 1
        fi
        if [[ "$template_pick" =~ ^[0-9]+$ ]]; then
            template_pick=$((10#$template_pick))
            if (( template_pick >= 1 && template_pick <= ${#templates[@]} )); then
                break
            fi
        fi
        echo -e "${COLOR_RED}${LANG[INVALID_TEMPLATE_NUMBER]}${COLOR_RESET}"
    done

    RandomHTML="${templates[$((template_pick - 1))]}"

    if [[ "$selected_url" == *"distillium"* && "$RandomHTML" == "503 error pages" ]]; then
        cd "$RandomHTML" || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
        versions=("v1" "v2")
        RandomVersion="${versions[$RANDOM % ${#versions[@]}]}"
        RandomHTML="$RandomHTML/$RandomVersion"
        cd ..
    fi
}

randomhtml_apply() {
    local random_meta_id random_comment random_class_suffix random_title_suffix random_id_suffix
    random_meta_id=$(openssl rand -hex 16)
    random_comment=$(openssl rand -hex 8)
    random_class_suffix=$(openssl rand -hex 4)
    random_title_suffix=$(openssl rand -hex 4)
    random_id_suffix=$(openssl rand -hex 4)
    local random_title_prefix="Page_"
    local random_footer_text="Designed by RandomSite_${random_title_suffix}"

    local meta_names=("viewport-id" "session-id" "track-id" "render-id" "page-id" "config-id")
    local meta_usernames=("Payee6296" "UserX1234" "AlphaBeta" "GammaRay" "DeltaForce" "EchoZulu" "Foxtrot99" "HotelCalifornia" "IndiaInk" "JulietBravo")
    local random_meta_name=${meta_names[$RANDOM % ${#meta_names[@]}]}
    local random_username=${meta_usernames[$RANDOM % ${#meta_usernames[@]}]}

    local class_prefixes=("style" "data" "ui" "layout" "theme" "view")
    local random_class_prefix=${class_prefixes[$RANDOM % ${#class_prefixes[@]}]}
    local random_class="$random_class_prefix-$random_class_suffix"
    local random_title="${random_title_prefix}${random_title_suffix}"

    find "./$RandomHTML" -type f -name "*.html" -exec sed -i \
        -e "s|<!-- Website template by freewebsitetemplates.com -->||" \
        -e "s|<!-- Theme by: WebThemez.com -->||" \
        -e "s|<a href=\"http://freewebsitetemplates.com\">Free Website Templates</a>|<span>${random_footer_text}</span>|" \
        -e "s|<a href=\"http://webthemez.com\" alt=\"webthemez\">WebThemez.com</a>|<span>${random_footer_text}</span>|" \
        -e "s|id=\"Content\"|id=\"rnd_${random_id_suffix}\"|" \
        -e "s|id=\"subscribe\"|id=\"sub_${random_id_suffix}\"|" \
        -e "s|<title>.*</title>|<title>${random_title}</title>|" \
        -e "s/<\/head>/<meta name=\"$random_meta_name\" content=\"$random_meta_id\">\n<!-- $random_comment -->\n<\/head>/" \
        -e "s|\(<body[^>]*[[:space:]]\)class=\"|\1class=\"${random_class} |" \
        -e "/<body[^>]*[[:space:]]class=/!s|<body\([^>]*\)>|<body\1 class=\"${random_class}\">|" \
        -e "s/CHANGEMEPLS/$random_username/g" \
        {} \;

    while IFS= read -r -d '' css_file; do
        printf '/* %s */\n.%s { display: block; }\n' "$random_comment" "$random_class" >> "$css_file"
    done < <(find "./$RandomHTML" -type f -name "*.css" -print0)

    if ! grep -Rqs --include='*.html' "$random_meta_id" "./$RandomHTML" 2>/dev/null; then
        randomhtml_fail "${LANG[FAILED_TO_MODIFY_HTML_FILES]}"
        return 1
    fi

    randomhtml_stop_spinner

    echo "${LANG[SELECT_TEMPLATE]}" "${TEMPLATE_DISPLAY_NAME:-$RandomHTML}"

    mkdir -p /var/www/html/ || { echo "Failed to create /var/www/html/"; return 1; }
    rm -rf /var/www/html/* /var/www/html/.[!.]* /var/www/html/..?* 2>/dev/null

    if [[ -d "${RandomHTML}" ]]; then
        cp -a "${RandomHTML}"/. "/var/www/html/" || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
        echo "${LANG[TEMPLATE_COPY]}"
    elif [[ -f "${RandomHTML}" ]]; then
        cp "${RandomHTML}" "/var/www/html/index.html" || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }
        echo "${LANG[TEMPLATE_COPY]}"
    else
        randomhtml_fail "${LANG[UNPACK_ERROR]}"
        return 1
    fi

    cd /opt/
    rm -rf simple-web-templates-*/ sni-templates-*/ nothing-sni-*/ 2>/dev/null

    return 0
}

randomhtml() {
    local template_source="$1"

    randomhtml_start_spinner
    randomhtml_fetch "$template_source" || return 1
    randomhtml_pick_random || return 1
    randomhtml_apply
}

randomhtml_choose() {
    local source_set="$1"

    randomhtml_start_spinner
    randomhtml_fetch "$source_set" || return 1
    randomhtml_stop_spinner
    randomhtml_pick_specific || return 1
    randomhtml_apply
}

randomhtml_check_free_space() {
    local need_bytes="$1"
    local path avail_kb avail_mb need_mb

    for path in /opt /var/www/html; do
        avail_kb=$(df -kP "$path" 2>/dev/null | awk 'NR==2{print $4}')
        [ -z "$avail_kb" ] && continue
        if [ "$((avail_kb * 1024))" -lt "$need_bytes" ]; then
            avail_mb=$(awk -v b="$((avail_kb * 1024))" 'BEGIN{printf "%.0f", b/1048576}')
            need_mb=$(awk -v b="$need_bytes" 'BEGIN{printf "%.0f", b/1048576}')
            echo -e "${COLOR_RED}$(printf "${LANG[SITE_NO_SPACE]}" "$path" "${avail_mb}M" "${need_mb}M")${COLOR_RESET}"
            return 1
        fi
    done
    return 0
}

randomhtml_clone() {
    local max_bytes=$(( ${SITE_CLONE_MAX_MB:-20} * 1024 * 1024 ))
    local site_url clone_root host_root base_dir
    local asset_url len total_bytes total_mb html_size main_html
    local confirmed asset_count=0

    reading "${LANG[ENTER_SITE_URL]}" site_url
    [[ "$site_url" =~ ^https?:// ]] || site_url="https://$site_url"

    clone_root="/opt/site-clone-$(openssl rand -hex 4)"
    rm -rf /opt/site-clone-*/ 2>/dev/null
    mkdir -p "$clone_root" || { echo "${LANG[UNPACK_ERROR]}"; return 1; }
    cd "$clone_root" || { echo "${LANG[UNPACK_ERROR]}"; return 1; }

    randomhtml_start_spinner "${LANG[SITE_CLONE_DOWNLOADING]}"

    # Browser-like headers: bare curl/wget get rejected outright by
    # some anti-bot setups
    local curl_headers=(
        -A "$SITE_CLONE_UA"
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        -H "Accept-Language: en-US,en;q=0.9"
        -H "Sec-Fetch-Site: none"
        -H "Sec-Fetch-Mode: navigate"
        -H "Sec-Fetch-Dest: document"
        -H "Upgrade-Insecure-Requests: 1"
    )

    if ! curl -fsSL "${curl_headers[@]}" --connect-timeout 10 --max-time 60 -o page.html "$site_url" 2>/dev/null; then
        local http_code
        http_code=$(curl -s -o /dev/null -w "%{http_code}" "${curl_headers[@]}" --connect-timeout 10 --max-time 30 "$site_url" 2>/dev/null)
        case "$http_code" in
            403|503|429)
                randomhtml_fail "$(printf "${LANG[SITE_ANTIBOT]}" "$http_code")"
                ;;
            000|"")
                randomhtml_fail "${LANG[SITE_UNREACHABLE]}"
                ;;
            *)
                randomhtml_fail "$(printf "${LANG[SITE_HTTP_STATUS]}" "$http_code")"
                ;;
        esac
        return 1
    fi
    if grep -qiE 'cdn-cgi/challenge-platform|_cf_chl_opt|<title>Just a moment' page.html; then
        randomhtml_fail "${LANG[SITE_ANTIBOT_200]}"
        return 1
    fi
    html_size=$(stat -c %s page.html 2>/dev/null || echo 0)
    if [ "$html_size" -eq 0 ]; then
        randomhtml_fail "${LANG[SITE_UNREACHABLE]}"
        return 1
    fi

    host_root=$(printf '%s' "$site_url" | sed -E 's#^(https?://[^/]+).*#\1#')
    case "$site_url" in
        */) base_dir="$site_url" ;;
        *) base_dir="${site_url%/*}/" ;;
    esac

    total_bytes=$html_size
    while IFS= read -r asset_url; do
        [ -z "$asset_url" ] && continue
        len=$(curl -sIL -A "$SITE_CLONE_UA" --connect-timeout 8 --max-time 15 "$asset_url" 2>/dev/null \
            | tr -d '\r' | grep -i '^content-length:' | tail -n 1 | awk '{print $2}')
        if [ -n "$len" ]; then
            total_bytes=$((total_bytes + len))
            asset_count=$((asset_count + 1))
        fi
    done < <(grep -oE '(src|href|data-src|srcset)="[^"]+"' page.html \
        | sed -E 's/^[a-z-]+="([^"]+)"$/\1/' \
        | grep -Ei '\.(css|js|mjs|png|jpe?g|gif|svg|webp|avif|ico|woff2?|ttf|otf|eot|mp4|webm)([?#]|$)' \
        | grep -vE '^(#|javascript:|mailto:|tel:|data:)' \
        | sort -u \
        | while IFS= read -r u; do
            case "$u" in
                http://*|https://*) printf '%s\n' "$u" ;;
                //*) printf '%s\n' "${site_url%%://*}:$u" ;;
                /*) printf '%s\n' "$host_root$u" ;;
                *) printf '%s\n' "$base_dir$u" ;;
            esac
        done)

    total_mb=$(awk -v b="$total_bytes" 'BEGIN{printf "%.1f", b/1048576}')
    randomhtml_stop_spinner
    printf "${COLOR_YELLOW}${LANG[SITE_SIZE_ESTIMATE]}${COLOR_RESET}\n" "$asset_count" "${total_mb}M"

    if [ "$total_bytes" -gt "$max_bytes" ]; then
        printf "${COLOR_YELLOW}${LANG[SITE_TOO_LARGE]}${COLOR_RESET}\n" "${total_mb}M"
        read_yn confirmed || { randomhtml_fail "${LANG[EXIT]}"; return 1; }
    fi

    rm -f page.html
    local clone_sections="n"
    printf "${COLOR_YELLOW}${LANG[SITE_CLONE_SECTIONS]}${COLOR_RESET}\n"
    read_yn clone_sections || true

    local need_bytes=$total_bytes
    if [ "$clone_sections" = "y" ]; then
        local quota_bytes=$(( ${SITE_CLONE_QUOTA_MB:-100} * 1024 * 1024 ))
        [ "$quota_bytes" -gt "$need_bytes" ] && need_bytes=$quota_bytes
    fi
    need_bytes=$(( need_bytes + need_bytes / 10 ))
    if ! randomhtml_check_free_space "$need_bytes"; then
        cd /opt/ 2>/dev/null || true
        rm -rf "$clone_root" 2>/dev/null
        return 1
    fi

    local wget_args=(--page-requisites --convert-links --adjust-extension
        --no-host-directories --directory-prefix="$clone_root"
        -e robots=off -U "$SITE_CLONE_UA"
        --header="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
        --header="Accept-Language: en-US,en;q=0.9"
        --connect-timeout=15 --timeout=60 --tries=2 -q)
    if [ "$clone_sections" = "y" ]; then
        wget_args+=(--recursive --level=2 "-Q${SITE_CLONE_QUOTA_MB:-100}m")
    fi
    randomhtml_start_spinner "${LANG[SITE_CLONE_DOWNLOADING_FULL]}"
    if ! wget "${wget_args[@]}" "$site_url"; then
        randomhtml_fail "${LANG[SITE_CLONE_EMPTY]}"
        return 1
    fi
    randomhtml_stop_spinner

    local downloaded_mb
    downloaded_mb=$(du -sk . 2>/dev/null | cut -f1 | awk '{printf "%.1f", $1/1024}')
    printf "${COLOR_GREEN}${LANG[SITE_CLONE_ACTUAL]}${COLOR_RESET}\n" "${downloaded_mb}M"

    if [ ! -f index.html ]; then
        main_html=$(find . -type f -name "*.html" | sort | head -n 1)
        if [ -n "$main_html" ] && [ "$main_html" != "./index.html" ]; then
            cp "$main_html" index.html
        fi
    fi
    if [ ! -s index.html ]; then
        randomhtml_fail "${LANG[SITE_CLONE_EMPTY]}"
        return 1
    fi

    TEMPLATE_DISPLAY_NAME="$site_url"
    RandomHTML="."
    randomhtml_apply
    local apply_rc=$?

    cd /opt/ 2>/dev/null || true
    rm -rf "$clone_root" 2>/dev/null
    return "$apply_rc"
}