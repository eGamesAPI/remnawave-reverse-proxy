#!/bin/bash
# Module: SelfSteal Templates

show_template_source_options() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CHOOSE_TEMPLATE_SOURCE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SIMPLE_WEB_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[SNI_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[NOTHING_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[SPECIFIC_TEMPLATES]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

randomhtml_start_spinner() {
    echo -e "${COLOR_YELLOW}${LANG[RANDOM_TEMPLATE]}${COLOR_RESET}"
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

# Failure path helper: stop the spinner, clear its line, report the
# message, remove downloaded artifacts. Always returns 1.
randomhtml_fail() {
    local message="$1"

    randomhtml_stop_spinner

    echo "${message}"

    cd /opt/ 2>/dev/null || true
    rm -rf /opt/simple-web-templates-*/ /opt/sni-templates-*/ /opt/nothing-sni-*/ 2>/dev/null

    return 1
}

# Download the template archive from a single URL into ./main.zip,
# validating the response is actually a zip: proxies in the fallback
# chain may answer with rate-limit or error pages instead.
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

# Phase 1: download the chosen template set into /opt and enter its
# directory. Sets the selected_url and archive_ref globals.
randomhtml_fetch() {
    local template_source="$1"

    cd /opt/ || { randomhtml_fail "${LANG[UNPACK_ERROR]}"; return 1; }

    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-*/ sni-templates-*/ nothing-sni-*/ 2>/dev/null

    # Pinned commits: the parsing below depends on the repository layout,
    # bump the hashes when the template sets need updating.
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

    # Direct GitHub first, then public prefix proxies so the install keeps
    # working on networks where github.com is unreachable. The pinned SHA
    # still guarantees the payload: the archive must extract into the
    # exact repo-<sha> directory enforced below.
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

# Valid template names for the fetched set, one per line: html pages
# for nothing-sni, folders that actually contain html pages otherwise.
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

# Phase 2 (random): set RandomHTML to a random template of the set.
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

# Phase 2 (interactive): list the templates of the set and let the
# user pick one by number.
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

# Phase 3: randomize the chosen template, verify the markers and
# install it into /var/www/html.
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

    # Append the marker rule at the end of each stylesheet: prepending it
    # would break files that start with @charset or @import.
    while IFS= read -r -d '' css_file; do
        printf '/* %s */\n.%s { display: block; }\n' "$random_comment" "$random_class" >> "$css_file"
    done < <(find "./$RandomHTML" -type f -name "*.css" -print0)

    # Make sure the markers were injected before replacing the live stub
    if ! grep -Rqs --include='*.html' "$random_meta_id" "./$RandomHTML" 2>/dev/null; then
        randomhtml_fail "${LANG[FAILED_TO_MODIFY_HTML_FILES]}"
        return 1
    fi

    randomhtml_stop_spinner

    echo "${LANG[SELECT_TEMPLATE]}" "${RandomHTML}"

    mkdir -p /var/www/html/ || { echo "Failed to create /var/www/html/"; return 1; }
    # Include dotfiles: cp -a copies them in from the template
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

# Install a random template from the given set ("simple", "sni",
# "nothing" or empty for a fully random set).
randomhtml() {
    local template_source="$1"

    randomhtml_start_spinner
    randomhtml_fetch "$template_source" || return 1
    randomhtml_pick_random || return 1
    randomhtml_apply
}

# Interactive entry for the menu: choose a set, then a specific
# template from it (simple is excluded: too many entries to list).
randomhtml_specific() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CHOOSE_TEMPLATE_SET]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SNI_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[NOTHING_TEMPLATES]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[CHOOSE_TEMPLATE_SET]}" TEMPLATE_SET

    local source_set
    case $TEMPLATE_SET in
        1) source_set="sni" ;;
        2) source_set="nothing" ;;
        0) return 0 ;;
        *)
            echo -e "${COLOR_RED}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
            return 1
            ;;
    esac

    randomhtml_start_spinner
    randomhtml_fetch "$source_set" || return 1
    randomhtml_stop_spinner
    randomhtml_pick_specific || return 1
    randomhtml_apply
}
