#!/bin/bash
# Module: Certificates — certbot issuance, renewal, hooks and cron

is_wildcard_cert() {
    local domain=$1
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"

    if [ ! -f "$cert_path" ]; then
        return 1
    fi

    if openssl x509 -noout -text -in "$cert_path" | grep -q "\*\.$domain"; then
        return 0
    else
        return 1
    fi
}

check_certificates() {
    local DOMAIN=$1
    local cert_dir="/etc/letsencrypt/live"

    if [ ! -d "$cert_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN${COLOR_RESET}"
        return 1
    fi

    local live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${DOMAIN}*" 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$live_dir" ] && [ -d "$live_dir" ]; then
        local files=("cert.pem" "chain.pem" "fullchain.pem" "privkey.pem")
        for file in "${files[@]}"; do
            local file_path="$live_dir/$file"
            if [ ! -f "$file_path" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN (missing $file)${COLOR_RESET}"
                return 1
            fi
            if [ ! -L "$file_path" ]; then
                fix_letsencrypt_structure "$(basename "$live_dir")"
                if [ $? -ne 0 ]; then
                    echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN (failed to fix structure)${COLOR_RESET}"
                    return 1
                fi
            fi
        done
        echo -e "${COLOR_GREEN}${LANG[CERT_FOUND]}$(basename "$live_dir")${COLOR_RESET}"
        return 0
    fi

    local base_domain=$(extract_domain "$DOMAIN")
    if [ "$base_domain" != "$DOMAIN" ]; then
        live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${base_domain}*" 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$live_dir" ] && [ -d "$live_dir" ] && is_wildcard_cert "$base_domain"; then
            echo -e "${COLOR_GREEN}${LANG[WILDCARD_CERT_FOUND]}$base_domain ${LANG[FOR_DOMAIN]} $DOMAIN${COLOR_RESET}"
            return 0
        fi
    fi

    echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN${COLOR_RESET}"
    return 1
}

check_api() {
    local attempts=3
    local attempt=1

    while [ $attempt -le $attempts ]; do
        if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "Authorization: Bearer ${CLOUDFLARE_API_KEY}" --header "Content-Type: application/json")
        else
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}" --header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" --header "Content-Type: application/json")
        fi

        if echo "$api_response" | grep -q '"success":true'; then
            echo -e "${COLOR_GREEN}${LANG[CF_VALIDATING]}${COLOR_RESET}"
            return 0
        else
            echo -e "${COLOR_RED}$(printf "${LANG[CF_INVALID_ATTEMPT]}" "$attempt" "$attempts")${COLOR_RESET}"
            if [ $attempt -lt $attempts ]; then
                reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
                reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL
            fi
            attempt=$((attempt + 1))
        fi
    done
    echo -e "${COLOR_RED}$(printf "${LANG[CF_INVALID]}" "$attempts")${COLOR_RESET}"
    return 1
}

get_certificates() {
    local DOMAIN=$1
    local CERT_METHOD=$2
    local LETSENCRYPT_EMAIL=$3
    local BASE_DOMAIN=$(extract_domain "$DOMAIN")
    local WILDCARD_DOMAIN="*.$BASE_DOMAIN"

    printf "${COLOR_YELLOW}${LANG[GENERATING_CERTS]}${COLOR_RESET}\n" "$DOMAIN"

    # Let's Encrypt accepts registrations without an email; an empty answer
    # switches certbot to the no-email mode below.
    local email_args=(--email "$LETSENCRYPT_EMAIL")
    [ -z "$LETSENCRYPT_EMAIL" ] && email_args=(--register-unsafely-without-email)

    case $CERT_METHOD in
        1)
            # Cloudflare API (DNS-01 support wildcard)
            if [ -z "$CLOUDFLARE_API_KEY" ]; then
                reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
            fi
            # Legacy global keys sign with an email; API tokens don't need one
            if [[ ! $CLOUDFLARE_API_KEY =~ [A-Z] ]] && [ -z "$CLOUDFLARE_EMAIL" ]; then
                reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL
            fi

            check_api || return 1

            mkdir -p ~/.secrets/certbot
            if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $CLOUDFLARE_API_KEY
EOL
            else
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
            fi
            chmod 600 ~/.secrets/certbot/cloudflare.ini

            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$BASE_DOMAIN" \
                -d "$WILDCARD_DOMAIN" \
                "${email_args[@]}" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            ;;
        2)
            # ACME HTTP-01 (without wildcard)
            local nginx_was_running=false
            if docker ps --filter "name=^/remnawave-nginx$" --format '{{.Names}}' | grep -qx "remnawave-nginx"; then
                nginx_was_running=true
                docker stop remnawave-nginx > /dev/null
            fi

            ufw allow 80/tcp comment 'HTTP for ACME challenge' > /dev/null 2>&1

            certbot certonly \
                --standalone \
                -d "$DOMAIN" \
                "${email_args[@]}" \
                --agree-tos \
                --non-interactive \
                --http-01-port 80 \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            local certbot_status=$?

            ufw delete allow 80/tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1

            if [ "$nginx_was_running" = true ]; then
                docker start remnawave-nginx > /dev/null
            fi

            if [ "$certbot_status" -ne 0 ]; then
                return "$certbot_status"
            fi
            ;;
        3)
            # Gcore DNS-01 (wildcard)

            if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                echo -e "${COLOR_YELLOW}${LANG[GCORE_PLUGIN_INSTALLING]}${COLOR_RESET}"
                
                if python3 -m pip install --help 2>&1 | grep -q "break-system-packages"; then
                    python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1
                else
                python3 -m pip install certbot-dns-gcore >/dev/null 2>&1
                fi
                    
                if certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                    echo -e "${COLOR_GREEN}${LANG[GCORE_PLUGIN_INSTALLED]}${COLOR_RESET}"
                else
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_GCORE_PLUGIN]}${COLOR_RESET}"
                    return 1
                fi
            else
                echo -e "${COLOR_GREEN}${LANG[GCORE_PLUGIN_AVAILABLE]}${COLOR_RESET}"
            fi

            # The token may already be set — ensure_dns_record_gcore asked
            # for it when the DNS record was created automatically.
            if [ -z "$GCORE_API_KEY" ]; then
                reading "${LANG[ENTER_GCORE_TOKEN]}" GCORE_API_KEY
            fi

            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini

            certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$BASE_DOMAIN" \
                -d "$WILDCARD_DOMAIN" \
                "${email_args[@]}" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            ;;
        *)
            echo -e "${COLOR_RED}${LANG[INVALID_CERT_METHOD]}${COLOR_RESET}"
            return 1
            ;;
    esac

    # Wildcard lineages (DNS-01 methods) are named after the base domain,
    # not after the subdomain the caller asked for
    local expected_lineage="$DOMAIN"
    if [ "$CERT_METHOD" = "1" ] || [ "$CERT_METHOD" = "3" ]; then
        expected_lineage="$BASE_DOMAIN"
    fi

    if [ ! -d "/etc/letsencrypt/live/$expected_lineage" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $expected_lineage${COLOR_RESET}"
        return 1
    fi
}

#Manage Certificates
show_manage_certificates() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_8]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[CERT_UPDATE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[CERT_GENERATE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[CERT_MANUAL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_certificates() {
    show_manage_certificates
    reading "${LANG[CERT_PROMPT1]}" CERT_OPTION
    case $CERT_OPTION in
        1)
            if ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CERTBOT]}${COLOR_RESET}"
                    log_clear
                    return 1
                }
            fi
            update_current_certificates
            log_clear
            ;;
        2)
            if ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CERTBOT]}${COLOR_RESET}"
                    log_clear
                    return 1
                }
            fi
            generate_new_certificates
            log_clear
            ;;
        3)
            manage_manual_certificate
            log_clear
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
            return 1
            ;;
    esac
}

update_current_certificates() {
    local cert_dir="/etc/letsencrypt/live"
    if [ ! -d "$cert_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi

    declare -A unique_domains
    declare -A cert_status
    local renew_threshold=30
    local log_dir="/var/log/letsencrypt"

    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 755 "$log_dir"
    fi

    for domain_dir in "$cert_dir"/*; do
        if [ -d "$domain_dir" ]; then
            local domain=$(basename "$domain_dir")
            local cert_domain
            cert_domain=$(echo "$domain" | sed -E 's/(-[0-9]+)$//')
            unique_domains["$cert_domain"]="$domain_dir"
        fi
    done

    for cert_domain in "${!unique_domains[@]}"; do
        local domain_dir="${unique_domains[$cert_domain]}"
        local domain
        domain=$(basename "$domain_dir")

        local cert_method="2" # 2 = ACME HTTP-01
        local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"

        if [ -f "$renewal_conf" ]; then
            if grep -q "dns_cloudflare" "$renewal_conf"; then
                cert_method="1" # Cloudflare DNS-01
            elif grep -q "dns-gcore" "$renewal_conf"; then
                cert_method="3" # Gcore DNS-01
            fi
        fi

        local cert_file="$domain_dir/fullchain.pem"
        local cert_mtime_before
        cert_mtime_before=$(stat -c %Y "$cert_file" 2>/dev/null || echo 0)

        fix_letsencrypt_structure "$cert_domain"

        local days_left
        days_left=$(check_cert_expiry "$domain")
        if [ $? -ne 0 ]; then
            cert_status["$cert_domain"]="${LANG[ERROR_PARSING_CERT]}"
            continue
        fi

        if [ "$cert_method" == "1" ]; then
            # Cloudflare
            local cf_credentials_file
            cf_credentials_file=$(grep "dns_cloudflare_credentials" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$cf_credentials_file" ] && [ ! -f "$cf_credentials_file" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_CLOUDFLARE_FILE_NOT_FOUND]}${COLOR_RESET}"
                reading "${COLOR_YELLOW}${LANG[ENTER_CF_TOKEN]}${COLOR_RESET}" CLOUDFLARE_API_KEY
                # API tokens contain uppercase letters and need no email;
                # legacy global keys sign with the email
                if [[ ! $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                    reading "${COLOR_YELLOW}${LANG[ENTER_CF_EMAIL]}${COLOR_RESET}" CLOUDFLARE_EMAIL
                fi

                if ! check_api; then
                    cert_status["$cert_domain"]="${LANG[ERROR_UPDATE]}"
                    continue
                fi

                mkdir -p "$(dirname "$cf_credentials_file")"
                if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                    cat > "$cf_credentials_file" <<EOL
dns_cloudflare_api_token = $CLOUDFLARE_API_KEY
EOL
                else
                    cat > "$cf_credentials_file" <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
                fi
                chmod 600 "$cf_credentials_file"
            fi
        elif [ "$cert_method" == "3" ]; then
            # Gcore
            local gcore_credentials_file
            gcore_credentials_file=$(grep "dns-gcore-credentials" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$gcore_credentials_file" ] && [ ! -f "$gcore_credentials_file" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GCORE_FILE_NOT_FOUND]}${COLOR_RESET}"
                if [ -z "$GCORE_API_KEY" ]; then
                    reading "${COLOR_YELLOW}${LANG[ENTER_GCORE_TOKEN]}${COLOR_RESET}" GCORE_API_KEY
                fi

                mkdir -p "$(dirname "$gcore_credentials_file")"
                cat > "$gcore_credentials_file" <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
                chmod 600 "$gcore_credentials_file"
            fi
        fi

        if [ "$days_left" -le "$renew_threshold" ]; then
            if [ "$cert_method" == "2" ]; then
                ufw allow 80/tcp > /dev/null 2>&1 && ufw reload > /dev/null 2>&1
            fi

            certbot renew --cert-name "$domain" --no-random-sleep-on-renew >> /var/log/letsencrypt/letsencrypt.log 2>&1 &
            local cert_pid=$!
            spinner $cert_pid "${LANG[WAITING]}"
            wait $cert_pid
            local certbot_exit_code=$?

            if [ "$cert_method" == "2" ]; then
                ufw delete allow 80/tcp > /dev/null 2>&1 && ufw reload > /dev/null 2>&1
            fi

            if [ "$certbot_exit_code" -ne 0 ]; then
                cert_status["$cert_domain"]="${LANG[ERROR_UPDATE]}: ${LANG[CERTBOT_RENEWAL_FAILED]}"
                continue
            fi

            local new_cert_dir
            new_cert_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "$cert_domain*" | sort -V | tail -n 1)
            local new_domain
            new_domain=$(basename "$new_cert_dir")
            local cert_mtime_after
            cert_mtime_after=$(stat -c %Y "$new_cert_dir/fullchain.pem" 2>/dev/null || echo 0)

            if check_certificates "$new_domain" > /dev/null 2>&1 && [ "$cert_mtime_before" != "$cert_mtime_after" ]; then
                local new_days_left
                new_days_left=$(check_cert_expiry "$new_domain")
                if [ $? -eq 0 ]; then
                    cert_status["$cert_domain"]="${LANG[UPDATED]}"
                else
                    cert_status["$cert_domain"]="${LANG[ERROR_PARSING_CERT]}"
                fi
            else
                cert_status["$cert_domain"]="${LANG[ERROR_UPDATE]}"
            fi
        else
            cert_status["$cert_domain"]="${LANG[REMAINING]} $days_left ${LANG[DAYS]}"
            continue
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[RESULTS_CERTIFICATE_UPDATES]}${COLOR_RESET}"
    for cert_domain in "${!cert_status[@]}"; do
        if [[ "${cert_status[$cert_domain]}" == "${LANG[UPDATED]}" ]]; then
            echo -e "${COLOR_GREEN}${LANG[CERTIFICATE_FOR]}$cert_domain ${LANG[SUCCESSFULLY_UPDATED]}${COLOR_RESET}"
        elif [[ "${cert_status[$cert_domain]}" =~ "${LANG[ERROR_UPDATE]}" ]]; then
            echo -e "${COLOR_RED}${LANG[FAILED_TO_UPDATE_CERTIFICATE_FOR]}$cert_domain: ${cert_status[$cert_domain]}${COLOR_RESET}"
        elif [[ "${cert_status[$cert_domain]}" == "${LANG[ERROR_PARSING_CERT]}" ]]; then
            echo -e "${COLOR_RED}${LANG[ERROR_CHECKING_EXPIRY_FOR]}$cert_domain${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[CERTIFICATE_FOR]}$cert_domain ${LANG[DOES_NOT_REQUIRE_UPDATE]}${cert_status[$cert_domain]})${COLOR_RESET}"
        fi
    done

    sleep 2
    log_clear
    remnawave_reverse
}

generate_new_certificates() {
    reading "${LANG[CERT_GENERATE_PROMPT]}" NEW_DOMAIN

    echo -e "${COLOR_YELLOW}${LANG[CERT_METHOD_PROMPT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[CERT_METHOD_CF]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[CERT_METHOD_ACME]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[CERT_METHOD_GCORE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""

    while true; do
        reading "${LANG[CERT_METHOD_CHOOSE]}" CERT_METHOD
        case "$CERT_METHOD" in
            0)
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
                ;;
            1|2|3)
                break
                ;;
            *)
                echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
                ;;
        esac
    done

    local LETSENCRYPT_EMAIL=""
    if [ "$CERT_METHOD" == "2" ] || [ "$CERT_METHOD" == "3" ]; then
        reading "${LANG[EMAIL_PROMPT]}" LETSENCRYPT_EMAIL
    fi

    if [ "$CERT_METHOD" == "1" ] || [ "$CERT_METHOD" == "3" ]; then
        # 1 = CF DNS-01, 3 = Gcore DNS-01 — wildcard
        echo -e "${COLOR_YELLOW}${LANG[GENERATING_WILDCARD_CERT]} *.$NEW_DOMAIN...${COLOR_RESET}"
        get_certificates "$NEW_DOMAIN" "$CERT_METHOD" "$LETSENCRYPT_EMAIL"
    elif [ "$CERT_METHOD" == "2" ]; then
        # 2 = ACME HTTP-01
        echo -e "${COLOR_YELLOW}${LANG[GENERATING_CERTS]} $NEW_DOMAIN...${COLOR_RESET}"
        get_certificates "$NEW_DOMAIN" "2" "$LETSENCRYPT_EMAIL"
    else
        echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
        return 1
    fi

    if check_certificates "$NEW_DOMAIN"; then
        # Wire the renewal hooks right away: without the pre/post hooks a
        # standalone cert cannot renew unattended while nginx holds port 80
        local lineage_domain="$NEW_DOMAIN"
        if [ "$CERT_METHOD" = "1" ] || [ "$CERT_METHOD" = "3" ]; then
            lineage_domain=$(extract_domain "$NEW_DOMAIN")
        fi
        local renewal_conf="/etc/letsencrypt/renewal/$lineage_domain.conf"
        [ -f "$renewal_conf" ] && configure_certbot_renewal_hooks "$renewal_conf"
        echo -e "${COLOR_GREEN}${LANG[CERT_UPDATE_SUCCESS]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]}${COLOR_RESET}"
    fi

    sleep 2
    log_clear
    remnawave_reverse
}

check_cert_expiry() {
    local domain="$1"
    local cert_dir="/etc/letsencrypt/live"
    local live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${domain}*" | sort -V | tail -n 1)
    if [ -z "$live_dir" ] || [ ! -d "$live_dir" ]; then
        return 1
    fi
    local cert_file="$live_dir/fullchain.pem"
    if [ ! -f "$cert_file" ]; then
        return 1
    fi
    local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | sed 's/notAfter=//')
    if [ -z "$expiry_date" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PARSING_CERT]}${COLOR_RESET}"
        return 1
    fi
    local expiry_epoch=$(TZ=UTC date -d "$expiry_date" +%s 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PARSING_CERT]}${COLOR_RESET}"
        return 1
    fi
    local current_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    echo "$days_left"
    return 0
}

configure_certbot_renewal_hooks() {
    local renewal_conf="$1"

    if [ ! -f "$renewal_conf" ]; then
        return 1
    fi

    sed -i -E '/^(pre_hook|post_hook|renew_hook|deploy_hook) = /d' "$renewal_conf"

    if grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$renewal_conf"; then
        echo "pre_hook = /usr/bin/docker stop remnawave-nginx" >> "$renewal_conf"
        echo "post_hook = /usr/bin/docker start remnawave-nginx" >> "$renewal_conf"
    else
        echo "deploy_hook = /usr/bin/docker restart remnawave-nginx" >> "$renewal_conf"
    fi
}

fix_letsencrypt_structure() {
    local domain=$1
    local live_dir="/etc/letsencrypt/live/$domain"
    local archive_dir="/etc/letsencrypt/archive/$domain"
    local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"

    if [ ! -d "$live_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi
    if [ ! -d "$archive_dir" ]; then
        echo -e "${COLOR_RED}${LANG[ARCHIVE_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi
    if [ ! -f "$renewal_conf" ]; then
        echo -e "${COLOR_RED}${LANG[RENEWAL_CONF_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi

    local conf_archive_dir=$(grep "^archive_dir" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
    if [ "$conf_archive_dir" != "$archive_dir" ]; then
        echo -e "${COLOR_RED}${LANG[ARCHIVE_DIR_MISMATCH]}${COLOR_RESET}"
        return 1
    fi

    local latest_version=$(ls -1 "$archive_dir" | grep -E 'cert[0-9]+.pem' | sort -V | tail -n 1 | sed -E 's/.*cert([0-9]+)\.pem/\1/')
    if [ -z "$latest_version" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_VERSION_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi

    local files=("cert" "chain" "fullchain" "privkey")
    for file in "${files[@]}"; do
        local archive_file="$archive_dir/$file$latest_version.pem"
        local live_file="$live_dir/$file.pem"
        if [ ! -f "$archive_file" ]; then
            echo -e "${COLOR_RED}${LANG[FILE_NOT_FOUND]} $archive_file${COLOR_RESET}"
            return 1
        fi
        if [ -f "$live_file" ] && [ ! -L "$live_file" ]; then
            rm "$live_file"
        fi
        ln -sf "$archive_file" "$live_file"
    done

    local cert_path="$live_dir/cert.pem"
    local chain_path="$live_dir/chain.pem"
    local fullchain_path="$live_dir/fullchain.pem"
    local privkey_path="$live_dir/privkey.pem"
    if ! grep -q "^cert = $cert_path" "$renewal_conf"; then
        sed -i "s|^cert =.*|cert = $cert_path|" "$renewal_conf"
    fi
    if ! grep -q "^chain = $chain_path" "$renewal_conf"; then
        sed -i "s|^chain =.*|chain = $chain_path|" "$renewal_conf"
    fi
    if ! grep -q "^fullchain = $fullchain_path" "$renewal_conf"; then
        sed -i "s|^fullchain =.*|fullchain = $fullchain_path|" "$renewal_conf"
    fi
    if ! grep -q "^privkey = $privkey_path" "$renewal_conf"; then
        sed -i "s|^privkey =.*|privkey = $privkey_path|" "$renewal_conf"
    fi

    configure_certbot_renewal_hooks "$renewal_conf"

    chmod 644 "$live_dir/cert.pem" "$live_dir/chain.pem" "$live_dir/fullchain.pem"
    chmod 600 "$live_dir/privkey.pem"
    return 0
}
#Manage Certificates

handle_certificates() {
    local -n domains_to_check_ref=$1
    local cert_method="$2"
    local letsencrypt_email="$3"
    local target_dir="${4:-/opt/remnawave}"

    declare -A unique_domains
    local need_certificates=false
    local min_days_left=9999

    echo -e "${COLOR_YELLOW}${LANG[CHECK_CERTS]}${COLOR_RESET}"
    sleep 1

    echo -e "${COLOR_YELLOW}${LANG[REQUIRED_DOMAINS]}${COLOR_RESET}"
    for domain in "${!domains_to_check_ref[@]}"; do
        echo -e "${COLOR_WHITE}- $domain${COLOR_RESET}"
    done

    for domain in "${!domains_to_check_ref[@]}"; do
        if ! check_certificates "$domain"; then
            need_certificates=true
        else
            days_left=$(check_cert_expiry "$domain")
            if [ $? -eq 0 ] && [ "$days_left" -lt "$min_days_left" ]; then
                min_days_left=$days_left
            fi
        fi
    done

    if [ "$need_certificates" = true ]; then
        echo -e ""
        echo -e "${COLOR_YELLOW}${LANG[CERT_METHOD_PROMPT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[CERT_METHOD_CF]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[CERT_METHOD_ACME]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[CERT_METHOD_GCORE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""

        # A token already entered for the DNS record means the zone lives
        # at that provider, so its method is the sensible default: prefill
        # it (Enter accepts, the choice stays editable for ACME fans).
        local cert_default=""
        if [ -n "$GCORE_API_KEY" ]; then
            cert_default="3"
        elif [ -n "$CLOUDFLARE_API_KEY" ]; then
            cert_default="1"
        fi
        if [ -n "$cert_default" ]; then
            echo -e "${COLOR_GREEN}${LANG[CERT_METHOD_SUGGESTED]}${COLOR_RESET}"
            echo -e ""
        fi

        while true; do
            if [ -n "$cert_default" ]; then
                read -rei "$cert_default" -p " $(question "${LANG[CERT_METHOD_CHOOSE]}")" cert_method
                cert_default=""
            else
                reading "${LANG[CERT_METHOD_CHOOSE]}" cert_method
            fi
            case "$cert_method" in
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    exit 1
                    ;;
                1)
                    break
                    ;;
                2|3)
                    reading "${LANG[EMAIL_PROMPT]}" letsencrypt_email
                    break
                    ;;
                *)
                    echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
                    ;;
            esac
        done
    else
        echo -e "${COLOR_GREEN}${LANG[CERTS_SKIPPED]}${COLOR_RESET}"
        cert_method="1"
        for domain in "${!domains_to_check_ref[@]}"; do
            local existing_conf="/etc/letsencrypt/renewal/$domain.conf"
            local base_domain
            base_domain=$(extract_domain "$domain")
            if [ -f "/etc/letsencrypt/renewal/$base_domain.conf" ] && is_wildcard_cert "$base_domain"; then
                existing_conf="/etc/letsencrypt/renewal/$base_domain.conf"
            fi

            if grep -Eq '^[[:space:]]*authenticator[[:space:]]*=[[:space:]]*standalone[[:space:]]*$' "$existing_conf" 2>/dev/null; then
                # Opening port 80 is required if any managed certificate uses HTTP-01.
                cert_method="2"
                break
            elif grep -q "dns-gcore" "$existing_conf" 2>/dev/null; then
                cert_method="3"
            fi
        done
    fi

    declare -A cert_domains_added

    if [ "$need_certificates" = true ] && [ "$cert_method" == "1" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        for domain in "${!unique_domains[@]}"; do
            get_certificates "$domain" "1" ""
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                return 1
            fi
            min_days_left=90
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done

    elif [ "$need_certificates" = true ] && [ "$cert_method" == "3" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        for domain in "${!unique_domains[@]}"; do
            get_certificates "$domain" "3" "$letsencrypt_email"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                return 1
            fi
            min_days_left=90
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done

    elif [ "$need_certificates" = true ] && [ "$cert_method" == "2" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            get_certificates "$domain" "2" "$letsencrypt_email"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                continue
            fi
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done
    else
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            local cert_domain="$domain"
            if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
                cert_domain="$base_domain"
            fi
            if [ -z "${cert_domains_added[$cert_domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$cert_domain/fullchain.pem:/etc/nginx/ssl/$cert_domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$cert_domain/privkey.pem:/etc/nginx/ssl/$cert_domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$cert_domain"]="1"
            fi
        done
    fi

    local cron_command
    # The deploy hook restarts the web server container only when a cert
    # was actually renewed: the certs are bind-mounted into the container
    # by file, so without a restart it keeps serving the old inode until
    # it eventually expires.
    local renew_hook="docker restart remnawave-nginx remnawave-caddy 2>/dev/null || true"
    if [ "$cert_method" == "2" ]; then
        cron_command="ufw allow 80/tcp >/dev/null 2>&1 && /usr/bin/certbot renew --quiet --deploy-hook \"$renew_hook\"; certbot_status=\$?; ufw delete allow 80/tcp >/dev/null 2>&1; ufw reload >/dev/null 2>&1; exit \$certbot_status"
    else
        cron_command="/usr/bin/certbot renew --quiet --deploy-hook \"$renew_hook\""
    fi

    if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew"; then
        echo -e "${COLOR_YELLOW}${LANG[ADDING_CRON_FOR_EXISTING_CERTS]}${COLOR_RESET}"
        add_cron_rule "0 5 * * 0 $cron_command"
    elif [ "$min_days_left" -le 30 ] && ! crontab -u root -l 2>/dev/null | grep -q "0 5 * * 0.*$cron_command"; then
        echo -e "${COLOR_YELLOW}${LANG[CERT_EXPIRY_SOON]} $min_days_left ${LANG[DAYS]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[UPDATING_CRON]}${COLOR_RESET}"
        crontab -u root -l 2>/dev/null | grep -v "/usr/bin/certbot renew" | crontab -u root -
        add_cron_rule "0 5 * * 0 $cron_command"
    else
        echo -e "${COLOR_YELLOW}${LANG[CRON_ALREADY_EXISTS]}${COLOR_RESET}"
    fi

    for domain in "${!domains_to_check_ref[@]}"; do
        local cert_domain="$domain"
        local base_domain
        base_domain=$(extract_domain "$domain")
        if [ -f "/etc/letsencrypt/renewal/$base_domain.conf" ] && is_wildcard_cert "$base_domain"; then
            cert_domain="$base_domain"
        fi

        local renewal_conf="/etc/letsencrypt/renewal/$cert_domain.conf"
        if [ -f "$renewal_conf" ]; then
            configure_certbot_renewal_hooks "$renewal_conf"
        fi
    done
}

# Days remaining until the given openssl end date ("notAfter" value)
cert_days_left() {
    local end_date="$1"
    local end_epoch
    end_epoch=$(TZ=UTC date -d "$end_date" +%s 2>/dev/null) || return 1
    echo $(( (end_epoch - $(date +%s)) / 86400 ))
}

# Whether a SAN/CN list covers the domain (exact or wildcard match)
cert_covers_domain() {
    local domain="$1" list="$2" entry base
    while IFS= read -r entry; do
        entry="${entry//[[:space:]]/}"
        [ -z "$entry" ] && continue
        [ "$entry" = "$domain" ] && return 0
        case "$entry" in
            \*.*)
                base="${entry#\*.}"
                case "$domain" in
                    *."$base") return 0 ;;
                esac
                ;;
        esac
    done <<< "$list"
    return 1
}

# Full check of a manually uploaded certificate pair
verify_manual_certificate() {
    local domain="$1"
    local cert_dir="$2"
    local fullchain="$cert_dir/fullchain.pem"
    local privkey="$cert_dir/privkey.pem"

    if [ ! -s "$fullchain" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[CERT_MANUAL_MISSING]}" "$fullchain")${COLOR_RESET}"
        return 1
    fi
    if [ ! -s "$privkey" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[CERT_MANUAL_MISSING]}" "$privkey")${COLOR_RESET}"
        return 1
    fi

    if ! openssl x509 -in "$fullchain" -noout >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[CERT_MANUAL_INVALID_CERT]}${COLOR_RESET}"
        return 1
    fi
    if ! openssl pkey -in "$privkey" -noout >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[CERT_MANUAL_INVALID_KEY]}${COLOR_RESET}"
        return 1
    fi

    local cert_pub key_pub
    cert_pub=$(openssl x509 -in "$fullchain" -pubkey -noout 2>/dev/null | md5sum | cut -d' ' -f1)
    key_pub=$(openssl pkey -in "$privkey" -pubout 2>/dev/null | md5sum | cut -d' ' -f1)
    if [ -z "$cert_pub" ] || [ "$cert_pub" != "$key_pub" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_MANUAL_MISMATCH]}${COLOR_RESET}"
        return 1
    fi

    local sans cn sans_display
    sans=$(openssl x509 -in "$fullchain" -noout -ext subjectAltName 2>/dev/null | grep -o 'DNS:[^ ,]*' | sed 's/^DNS://')
    cn=$(openssl x509 -in "$fullchain" -noout -subject 2>/dev/null | sed -n 's/.*CN[[:space:]]*=[[:space:]]*//p')
    if ! cert_covers_domain "$domain" "$sans"$'\n'"$cn"; then
        sans_display=$(printf '%s' "$sans" | tr '\n' ' ')
        echo -e "${COLOR_RED}$(printf "${LANG[CERT_MANUAL_DOMAIN_MISMATCH]}" "$domain" "${sans_display:-$cn}")${COLOR_RESET}"
        return 1
    fi

    local end_date days_left
    end_date=$(openssl x509 -in "$fullchain" -noout -enddate 2>/dev/null | cut -d= -f2-)
    days_left=$(cert_days_left "$end_date") || {
        echo -e "${COLOR_RED}${LANG[ERROR_PARSING_CERT]}${COLOR_RESET}"
        return 1
    }
    if [ "$days_left" -lt 0 ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[CERT_MANUAL_EXPIRED]}" "$(( -days_left ))")${COLOR_RESET}"
        return 1
    fi

    printf "${COLOR_GREEN}${LANG[CERT_MANUAL_EXPIRES]}${COLOR_RESET}\n" "$days_left" "$end_date"
    if [ "$days_left" -le 30 ]; then
        echo -e "${COLOR_YELLOW}${LANG[CERT_MANUAL_SOON]}${COLOR_RESET}"
    fi
    return 0
}

# Interactive: the user uploads their own certificate (bought etc.);
# the script shows where to put it and verifies the pair
manage_manual_certificate() {
    local cert_domain cert_dir server_ip ready_answer

    reading "${LANG[CERT_MANUAL_DOMAIN]}" cert_domain
    if ! [[ "$cert_domain" =~ ^[a-zA-Z0-9.-]+$ ]]; then
        echo -e "${COLOR_RED}${LANG[CERT_MANUAL_BAD_DOMAIN]}${COLOR_RESET}"
        return 1
    fi

    cert_dir="/etc/letsencrypt/live/$cert_domain"
    mkdir -p "$cert_dir"

    server_ip=$(curl -s -4 --max-time 10 ifconfig.me 2>/dev/null)
    [ -z "$server_ip" ] && server_ip=$(hostname -I 2>/dev/null | awk '{print $1}')

    printf "${COLOR_YELLOW}${LANG[CERT_MANUAL_UPLOAD]}${COLOR_RESET}\n" "$cert_dir" "$cert_dir" "${server_ip:-<server-ip>}" "$cert_dir"

    while true; do
        reading "${LANG[CERT_MANUAL_READY]}" ready_answer
        if [ "$ready_answer" = "0" ]; then
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
        fi
        if verify_manual_certificate "$cert_domain" "$cert_dir"; then
            chmod 600 "$cert_dir/privkey.pem"
            printf "${COLOR_GREEN}${LANG[CERT_MANUAL_OK]}${COLOR_RESET}\n" "$cert_dir"
            setup_cert_telegram_notifications
            return 0
        fi
        echo -e "${COLOR_YELLOW}${LANG[CERT_MANUAL_RETRY]}${COLOR_RESET}"
    done
}

# Optional daily Telegram reminders about expiring certificates
setup_cert_telegram_notifications() {
    local notify_conf="${DIR_REMNAWAVE}cert-notify.conf"
    local notify_script="${DIR_REMNAWAVE}cert-notify.sh"

    [ -f "$notify_conf" ] && return 0

    printf "${COLOR_YELLOW}${LANG[CERT_TG_ASK]}${COLOR_RESET}\n"
    local enabled
    read_yn enabled || return 0

    local tg_token tg_chat response
    while true; do
        reading "${LANG[CERT_TG_TOKEN]}" tg_token || return 0
        [ "$tg_token" = "0" ] && return 0
        reading "${LANG[CERT_TG_CHAT]}" tg_chat || return 0
        [ "$tg_chat" = "0" ] && return 0
        # Both go into a sourced config — allow only safe characters
        if ! [[ "$tg_token" =~ ^[0-9A-Za-z:_-]+$ ]] || ! [[ "$tg_chat" =~ ^-?[0-9]+$ ]]; then
            echo -e "${COLOR_RED}${LANG[CERT_TG_FAIL]}${COLOR_RESET}"
            continue
        fi

        echo -e "${COLOR_YELLOW}${LANG[CERT_TG_TESTING]}${COLOR_RESET}"
        response=$(curl -s -m 20 "https://api.telegram.org/bot${tg_token}/sendMessage" \
            --data-urlencode "chat_id=${tg_chat}" \
            --data-urlencode "text=✅ ${LANG[CERT_TG_TEST_TEXT]}" 2>/dev/null)
        if printf '%s' "$response" | grep -q '"ok":true'; then
            break
        fi
        echo -e "${COLOR_RED}${LANG[CERT_TG_FAIL]}${COLOR_RESET}"
    done

    cat > "$notify_conf" <<EOL
TG_TOKEN='$tg_token'
TG_CHAT='$tg_chat'
DAYS=14
LANG_SEL='ru'
EOL
    chmod 600 "$notify_conf"

    cat > "$notify_script" <<'EOL'
#!/bin/bash
# Daily certificate expiry check with Telegram reminders.
CONF="__NOTIFY_CONF__"
[ -r "$CONF" ] || exit 0
. "$CONF"
: "${TG_TOKEN:?}" "${TG_CHAT:?}"
DAYS="${DAYS:-14}"

send_tg() {
    curl -s -m 20 --get "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        --data-urlencode "chat_id=${TG_CHAT}" \
        --data-urlencode "text=$1" >/dev/null 2>&1
}

report=""
now_epoch=$(date +%s)
for dir in /etc/letsencrypt/live/*/; do
    fc="${dir}fullchain.pem"
    [ -r "$fc" ] || continue
    end_date=$(openssl x509 -in "$fc" -enddate -noout 2>/dev/null | cut -d= -f2-)
    [ -n "$end_date" ] || continue
    end_epoch=$(TZ=UTC date -d "$end_date" +%s 2>/dev/null) || continue
    days=$(( (end_epoch - now_epoch) / 86400 ))
    if [ "$days" -le "$DAYS" ]; then
        report="${report}$(basename "$dir"): ${days} дн. (${end_date})"$'\n'
    fi
done

if [ -n "$report" ]; then
    send_tg "$(printf "⚠️ Сертификаты истекают:\n%s" "$report")"
fi
EOL
    sed -i "s|__NOTIFY_CONF__|$notify_conf|" "$notify_script"
    chmod 700 "$notify_script"

    if ! crontab -u root -l 2>/dev/null | grep -q "cert-notify.sh"; then
        add_cron_rule "0 9 * * * $notify_script"
    fi

    echo -e "${COLOR_GREEN}${LANG[CERT_TG_OK]}${COLOR_RESET}"
}
