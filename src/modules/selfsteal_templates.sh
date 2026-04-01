#!/bin/bash
# Module: SelfSteal Templates

show_template_source_options() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CHOOSE_TEMPLATE_SOURCE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SIMPLE_WEB_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[SNI_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[NOTHING_TEMPLATES]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

randomhtml() {
    local template_source="$1"

    cd /opt/ || { echo "${LANG[UNPACK_ERROR]}"; exit 1; }

    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/ 2>/dev/null

    echo -e "${COLOR_YELLOW}${LANG[RANDOM_TEMPLATE]}${COLOR_RESET}"
    sleep 1
    spinner $$ "${LANG[WAITING]}" &
    spinner_pid=$!

    template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
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

    while ! wget -q --timeout=30 --tries=10 --retry-connrefused "$selected_url"; do
        echo "${LANG[DOWNLOAD_FAIL]}"
        sleep 3
    done

    unzip -o main.zip &>/dev/null || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
    rm -f main.zip

    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        cd simple-web-templates-main/ || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        rm -rf assets ".gitattributes" "README.md" "_config.yml" 2>/dev/null
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        cd nothing-sni-main/ || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        rm -rf .github README.md 2>/dev/null
    else
        cd sni-templates-main/ || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi

    # Special handling for nothing-sni - select random HTML file
    if [[ "$selected_url" == *"nothing-sni"* ]]; then
        # Randomly select one HTML file from 1-8.html
        selected_number=$((RANDOM % 8 + 1))
        RandomHTML="${selected_number}.html"
    else
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path . | sed 's|./||')

        RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"
    fi

    if [[ "$selected_url" == *"distillium"* && "$RandomHTML" == "503 error pages" ]]; then
        cd "$RandomHTML" || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        versions=("v1" "v2")
        RandomVersion="${versions[$RANDOM % ${#versions[@]}]}"
        RandomHTML="$RandomHTML/$RandomVersion"
        cd ..
    fi

    local random_meta_id=$(openssl rand -hex 16)
    local random_comment=$(openssl rand -hex 8)
    local random_class_suffix=$(openssl rand -hex 4)
    local random_title_prefix="Page_"
    local random_title_suffix=$(openssl rand -hex 4)
    local random_footer_text="Designed by RandomSite_${random_title_suffix}"
    local random_id_suffix=$(openssl rand -hex 4)

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
        -e "s/<body/<body class=\"$random_class\"/" \
        -e "s/CHANGEMEPLS/$random_username/g" \
        {} \;

    find "./$RandomHTML" -type f -name "*.css" -exec sed -i \
        -e "1i\/* $random_comment */" \
        -e "1i.$random_class { display: block; }" \
        {} \;

    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    printf "\r\033[K" > /dev/tty

    echo "${LANG[SELECT_TEMPLATE]}" "${RandomHTML}"

    if [[ -d "${RandomHTML}" ]]; then
        if [[ ! -d "/var/www/html/" ]]; then
            mkdir -p "/var/www/html/" || { echo "Failed to create /var/www/html/"; exit 1; }
        fi
        rm -rf /var/www/html/*
        cp -a "${RandomHTML}"/. "/var/www/html/"
        echo "${LANG[TEMPLATE_COPY]}"
    elif [[ -f "${RandomHTML}" ]]; then
        cp "${RandomHTML}" "/var/www/html/index.html"
        echo "${LANG[TEMPLATE_COPY]}"
    else
        echo "${LANG[UNPACK_ERROR]}" && exit 1
    fi

    if ! find "/var/www/html" -type f -name "*.html" -exec grep -q "$random_meta_name" {} \; 2>/dev/null; then
        echo -e "${COLOR_RED}${LANG[FAILED_TO_MODIFY_HTML_FILES]}${COLOR_RESET}"
        return 1
    fi

    cd /opt/
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/
}
