#!/bin/bash
# Module: DNS Records

dns_record_points_here() {
    local domain="$1" server_ip="$2" allow_cf="${3:-true}"
    local domain_ip
    domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)

    [ -z "$domain_ip" ] && return 1
    [ "$domain_ip" = "$server_ip" ] && return 0
    [ "$allow_cf" = true ] && curl -s --max-time 10 https://www.cloudflare.com/ips-v4 | grep -qF "$domain_ip"
}

manual_dns_record_flow() {
    local domain="$1" server_ip="$2" allow_cf="${3:-true}"

    echo -e ""
    printf "${COLOR_YELLOW}${LANG[DNS_RECORD_MANUAL_HINT]}${COLOR_RESET}\n" "$domain" "$server_ip"
    echo -e "${COLOR_RED}${LANG[DNS_RECORD_MANUAL_WARN]}${COLOR_RESET}"

    while true; do
        echo -e ""
        reading "${LANG[DNS_RECORD_MANUAL_WAIT]}" manual_wait_done
        if dns_record_points_here "$domain" "$server_ip" "$allow_cf"; then
            printf "${COLOR_GREEN}${LANG[DNS_RECORD_FOUND]}${COLOR_RESET}\n" "$domain"
            return 0
        fi

        echo -e ""
        echo -e "${COLOR_RED}${LANG[DNS_RECORD_STILL_MISSING]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[DNS_RECORD_RETRY]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[DNS_RECORD_SKIP]}${COLOR_RESET}"
        echo -e ""
        local again
        while true; do
            reading "${LANG[DNS_RECORD_CHECK_PROMPT]}" again
            case "$again" in
                1) break ;;
                2) return 1 ;;
                *) echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}" ;;
            esac
        done
    done
}

ensure_dns_record() {
    local domain="$1"
    local allow_cf="${2:-true}"
    local base_domain
    base_domain=$(extract_domain "$domain")

    local server_ip
    server_ip=$(curl -s -4 --max-time 10 ifconfig.me || curl -s -4 --max-time 10 api.ipify.org || curl -s -4 --max-time 10 ipinfo.io/ip)

    if dns_record_points_here "$domain" "$server_ip" "$allow_cf"; then
        return 0
    fi

    dns_saved_credentials_load

    if [ -n "$BUNNY_API_KEY" ]; then
        ensure_dns_record_bunny "$domain" "$base_domain" "$server_ip" && return 0
    elif [ -n "$GCORE_API_KEY" ]; then
        ensure_dns_record_gcore "$domain" "$base_domain" "$server_ip" && return 0
    elif [ -n "$CLOUDFLARE_API_KEY" ]; then
        ensure_dns_record_cloudflare "$domain" "$base_domain" "$server_ip" && return 0
    fi

    printf "${COLOR_YELLOW}${LANG[DNS_RECORD_MISSING]}${COLOR_RESET}\n" "$domain"

    local choice
    while true; do
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[DNS_RECORD_CREATE_CF]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[DNS_RECORD_CREATE_GC]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[DNS_RECORD_CREATE_BUNNY]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}4. ${LANG[DNS_RECORD_MANUAL]}${COLOR_RESET}"
        echo -e ""
        reading "${LANG[DNS_RECORD_CHOOSE]}" choice
        case "$choice" in
            1) ensure_dns_record_cloudflare "$domain" "$base_domain" "$server_ip"; return $? ;;
            2) ensure_dns_record_gcore "$domain" "$base_domain" "$server_ip"; return $? ;;
            3) ensure_dns_record_bunny "$domain" "$base_domain" "$server_ip"; return $? ;;
            4) manual_dns_record_flow "$domain" "$server_ip" "$allow_cf"; return $? ;;
            *) echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}" ;;
        esac
    done
}

ensure_dns_record_bunny() {
    local domain="$1" base_domain="$2" server_ip="$3"

    if [ -z "$BUNNY_API_KEY" ]; then
        reading "${LANG[ENTER_BUNNY_TOKEN]}" BUNNY_API_KEY
    fi

    # The zone list carries every zone of the account; the record's parent
    # zone is the registrable base (the suffix-aware extract_domain).
    local zones_resp zone_id
    zones_resp=$(curl -s --max-time 20 "https://api.bunny.net/dnszone" \
        -H "AccessKey: ${BUNNY_API_KEY}" -H "Accept: application/json")
    zone_id=$(echo "$zones_resp" | jq -r --arg zone "$base_domain" \
        '.Items[]? | select(.Domain == $zone) | .Id' | head -n1)
    if [ -z "$zone_id" ]; then
        printf "${COLOR_RED}${LANG[DNS_RECORD_ZONE_NOT_FOUND]}${COLOR_RESET}\n" "$base_domain"
        return 1
    fi

    # The working key refreshes certbot's renewal credential too — after a
    # key roll the old bunny.ini would fail the next wildcard renewal.
    mkdir -p "$HOME/.secrets/certbot"
    printf 'dns_bunny_api_key = %s\n' "$BUNNY_API_KEY" > "$HOME/.secrets/certbot/bunny.ini"
    chmod 600 "$HOME/.secrets/certbot/bunny.ini" 2>/dev/null
    echo -e "${COLOR_GRAY}${LANG[DNS_TOKEN_REFRESHED]}${COLOR_RESET}"

    # Record names are relative to the zone (panel.example.com in the
    # example.com zone is just "panel"); the apex record is "@".
    local record_name
    if [ "$domain" = "$base_domain" ]; then
        record_name="@"
    else
        record_name="${domain%.$base_domain}"
    fi

    local zone_resp record_id
    zone_resp=$(curl -s --max-time 20 "https://api.bunny.net/dnszone/$zone_id" \
        -H "AccessKey: ${BUNNY_API_KEY}" -H "Accept: application/json")
    record_id=$(echo "$zone_resp" | jq -r --arg name "$record_name" \
        '.Records[]? | select(.Type == 0 and .Name == $name) | .Id' | head -n1)

    local http_code
    # An existing A record pointing elsewhere is replaced: Bunny's update
    # verb is undocumented, while delete + create are the two operations
    # certbot-dns-bunny itself relies on.
    if [ -n "$record_id" ]; then
        http_code=$(curl -s -o /tmp/bunny-dns.out -w "%{http_code}" --max-time 20 -X DELETE \
            "https://api.bunny.net/dnszone/$zone_id/records/$record_id" \
            -H "AccessKey: ${BUNNY_API_KEY}" -H "Accept: application/json")
        if [ "$http_code" != "204" ]; then
            echo -e "${COLOR_RED}${LANG[DNS_RECORD_FAILED]} (HTTP $http_code)${COLOR_RESET}"
            [ -s /tmp/bunny-dns.out ] && echo -e "${COLOR_RED}$(tail -c 200 /tmp/bunny-dns.out)${COLOR_RESET}"
            rm -f /tmp/bunny-dns.out
            return 1
        fi
    fi

    http_code=$(curl -s -o /tmp/bunny-dns.out -w "%{http_code}" --max-time 20 -X PUT \
        "https://api.bunny.net/dnszone/$zone_id/records" \
        -H "AccessKey: ${BUNNY_API_KEY}" -H "Content-Type: application/json" \
        --data "{\"Type\":0,\"Ttl\":120,\"Name\":\"$record_name\",\"Value\":\"$server_ip\"}")

    if [ "$http_code" = "201" ]; then
        printf "${COLOR_GREEN}${LANG[DNS_RECORD_CREATED]}${COLOR_RESET}\n" "$domain" "$server_ip"
        rm -f /tmp/bunny-dns.out
        return 0
    fi

    echo -e "${COLOR_RED}${LANG[DNS_RECORD_FAILED]} (HTTP $http_code)${COLOR_RESET}"
    [ -s /tmp/bunny-dns.out ] && echo -e "${COLOR_RED}$(tail -c 200 /tmp/bunny-dns.out)${COLOR_RESET}"
    rm -f /tmp/bunny-dns.out
    return 1
}

ensure_dns_record_cloudflare() {
    local domain="$1" base_domain="$2" server_ip="$3"
    local auth_header zone_resp zone_id cf_err

    # A rolled or revoked token must not poison the whole run: Cloudflare's
    # auth failure is reported as such (not as a missing zone), the token
    # is re-asked, and the attempt repeats.
    local attempt
    for attempt in 1 2 3; do
        if [ -z "$CLOUDFLARE_API_KEY" ]; then
            reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
        fi
        auth_header="Authorization: Bearer ${CLOUDFLARE_API_KEY}"
        if [[ ! $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
            if [ -z "$CLOUDFLARE_EMAIL" ]; then
                reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL
            fi
            auth_header="X-Auth-Key: ${CLOUDFLARE_API_KEY}"
        fi

        zone_resp=$(curl -s --max-time 20 "https://api.cloudflare.com/client/v4/zones?name=$base_domain" \
            -H "$auth_header" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL:-}" -H "Content-Type: application/json")

        if echo "$zone_resp" | jq -e '.success == false' >/dev/null 2>&1; then
            cf_err=$(echo "$zone_resp" | jq -r '.errors[0].message // .errors[0].code // "unknown"')
            printf "${COLOR_RED}${LANG[DNS_TOKEN_REJECTED]}${COLOR_RESET}\n" "$cf_err"
            CLOUDFLARE_API_KEY=""
            CLOUDFLARE_EMAIL=""
            continue
        fi

        zone_id=$(echo "$zone_resp" | jq -r '.result[0].id // empty' 2>/dev/null)
        if [ -z "$zone_id" ]; then
            printf "${COLOR_RED}${LANG[DNS_RECORD_ZONE_NOT_FOUND]}${COLOR_RESET}\n" "$base_domain"
            return 1
        fi
        break
    done
    if [ -z "$zone_id" ]; then
        echo -e "${COLOR_RED}${LANG[DNS_TOKEN_REJECTED_FINAL]}${COLOR_RESET}"
        return 1
    fi

    # The working token refreshes certbot's renewal credential too — after a
    # token roll the old cloudflare.ini would fail the next wildcard renewal.
    mkdir -p "$HOME/.secrets/certbot"
    if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
        printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_KEY" > "$HOME/.secrets/certbot/cloudflare.ini"
    else
        printf 'dns_cloudflare_email = %s\ndns_cloudflare_api_key = %s\n' \
            "$CLOUDFLARE_EMAIL" "$CLOUDFLARE_API_KEY" > "$HOME/.secrets/certbot/cloudflare.ini"
    fi
    chmod 600 "$HOME/.secrets/certbot/cloudflare.ini" 2>/dev/null
    echo -e "${COLOR_GRAY}${LANG[DNS_TOKEN_REFRESHED]}${COLOR_RESET}"

    local record_id response
    record_id=$(curl -s --max-time 20 "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records?type=A&name=$domain" \
        -H "$auth_header" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL:-}" -H "Content-Type: application/json" \
        | jq -r '.result[0].id // empty' 2>/dev/null)

    # DNS-only record: a proxied one breaks Reality selfsteal domains and
    # is not needed for the DNS-01 challenge either.
    if [ -n "$record_id" ]; then
        response=$(curl -s --max-time 20 -X PATCH "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records/$record_id" \
            -H "$auth_header" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL:-}" -H "Content-Type: application/json" \
            --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$server_ip\",\"ttl\":120,\"proxied\":false}")
        if echo "$response" | jq -e '.success == true' > /dev/null 2>&1; then
            printf "${COLOR_GREEN}${LANG[DNS_RECORD_UPDATED]}${COLOR_RESET}\n" "$domain" "$server_ip"
            return 0
        fi
        echo -e "${COLOR_RED}${LANG[DNS_RECORD_FAILED]}: $(echo "$response" | jq -r '.errors[0].message // "unknown error"')${COLOR_RESET}"
        return 1
    fi

    response=$(curl -s --max-time 20 -X POST "https://api.cloudflare.com/client/v4/zones/$zone_id/dns_records" \
        -H "$auth_header" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL:-}" -H "Content-Type: application/json" \
        --data "{\"type\":\"A\",\"name\":\"$domain\",\"content\":\"$server_ip\",\"ttl\":120,\"proxied\":false}")

    if echo "$response" | jq -e '.success == true' > /dev/null 2>&1; then
        printf "${COLOR_GREEN}${LANG[DNS_RECORD_CREATED]}${COLOR_RESET}\n" "$domain" "$server_ip"
        return 0
    fi

    echo -e "${COLOR_RED}${LANG[DNS_RECORD_FAILED]}: $(echo "$response" | jq -r '.errors[0].message // "unknown error"')${COLOR_RESET}"
    return 1
}

ensure_dns_record_gcore() {
    local domain="$1" base_domain="$2" server_ip="$3"

    if [ -z "$GCORE_API_KEY" ]; then
        reading "${LANG[ENTER_GCORE_TOKEN]}" GCORE_API_KEY
    fi

    local body host http_code
    body=$(printf '{"resource_records":[{"content":["%s"],"enabled":true}],"ttl":120}' "$server_ip")

    for host in "https://api.gcore.com" "https://api.edgecenter.ru"; do
        http_code=$(curl -s -o /tmp/gcore-dns.out -w "%{http_code}" --max-time 20 -X POST \
            "${host}/dns/v2/zones/${base_domain}/${domain}./A" \
            -H "Authorization: APIKey ${GCORE_API_KEY}" -H "Content-Type: application/json" \
            --data "$body")

        if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
            printf "${COLOR_GREEN}${LANG[DNS_RECORD_CREATED]}${COLOR_RESET}\n" "$domain" "$server_ip"
            rm -f /tmp/gcore-dns.out
            return 0
        fi

        if [ "$http_code" = "409" ]; then
            http_code=$(curl -s -o /tmp/gcore-dns.out -w "%{http_code}" --max-time 20 -X PUT \
                "${host}/dns/v2/zones/${base_domain}/${domain}./A" \
                -H "Authorization: APIKey ${GCORE_API_KEY}" -H "Content-Type: application/json" \
                --data "$body")
            if [ "$http_code" = "200" ] || [ "$http_code" = "201" ] || [ "$http_code" = "204" ]; then
                printf "${COLOR_GREEN}${LANG[DNS_RECORD_UPDATED]}${COLOR_RESET}\n" "$domain" "$server_ip"
                rm -f /tmp/gcore-dns.out
                return 0
            fi
        fi
    done

    echo -e "${COLOR_RED}${LANG[DNS_RECORD_FAILED]} (HTTP $http_code)${COLOR_RESET}"
    [ -s /tmp/gcore-dns.out ] && echo -e "${COLOR_RED}$(tail -c 200 /tmp/gcore-dns.out)${COLOR_RESET}"
    rm -f /tmp/gcore-dns.out
    return 1
}
