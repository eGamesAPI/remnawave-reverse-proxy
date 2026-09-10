#!/bin/bash
# Module: DNS Records
# Used by check_domain for every domain an install asks for, and by the
# tinyauth portal setup. Offers to create the A record through the
# Cloudflare or Gcore API (or wait for a manual record) so users never
# have to touch their DNS dashboard mid-install.

# True when $1 resolves to this server — directly, or through the
# Cloudflare proxy when $3 allows it (a Reality selfsteal domain must not
# be proxied, everything else tolerates it).
dns_record_points_here() {
    local domain="$1" server_ip="$2" allow_cf="${3:-true}"
    local domain_ip
    domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)

    [ -z "$domain_ip" ] && return 1
    [ "$domain_ip" = "$server_ip" ] && return 0
    [ "$allow_cf" = true ] && curl -s --max-time 10 https://www.cloudflare.com/ips-v4 | grep -qF "$domain_ip"
}

# The "I'll create it manually" path: show the exact record to create,
# warn about the consequences, then wait for the user and re-check.
# Returns 0 when the record is confirmed, 1 when the user skips the check.
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

# Make sure $1 has an A record pointing at this server; offers to create
# the record through the Cloudflare or Gcore API when it is missing (or
# proxied, for domains that must not be). Returns 0 when the record is
# confirmed, 1 when the user skipped the check.
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

    # A provider token already entered for a previous domain means the
    # zone lives there — create this record with it, no menu and no
    # second token question. Falls through to the menu if that fails.
    if [ -n "$GCORE_API_KEY" ]; then
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
        echo -e "${COLOR_YELLOW}3. ${LANG[DNS_RECORD_MANUAL]}${COLOR_RESET}"
        echo -e ""
        reading "${LANG[DNS_RECORD_CHOOSE]}" choice
        case "$choice" in
            1) ensure_dns_record_cloudflare "$domain" "$base_domain" "$server_ip"; return $? ;;
            2) ensure_dns_record_gcore "$domain" "$base_domain" "$server_ip"; return $? ;;
            3) manual_dns_record_flow "$domain" "$server_ip" "$allow_cf"; return $? ;;
            *) echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}" ;;
        esac
    done
}

ensure_dns_record_cloudflare() {
    local domain="$1" base_domain="$2" server_ip="$3"

    if [ -z "$CLOUDFLARE_API_KEY" ]; then
        reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
    fi
    local auth_header="Authorization: Bearer ${CLOUDFLARE_API_KEY}"
    if [[ ! $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
        reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL
        auth_header="X-Auth-Key: ${CLOUDFLARE_API_KEY}"
    fi

    local zone_id
    zone_id=$(curl -s --max-time 20 "https://api.cloudflare.com/client/v4/zones?name=$base_domain" \
        -H "$auth_header" -H "X-Auth-Email: ${CLOUDFLARE_EMAIL:-}" -H "Content-Type: application/json" \
        | jq -r '.result[0].id // empty' 2>/dev/null)

    if [ -z "$zone_id" ]; then
        printf "${COLOR_RED}${LANG[DNS_RECORD_ZONE_NOT_FOUND]}${COLOR_RESET}\n" "$base_domain"
        return 1
    fi

    # A record with this name may already exist (wrong IP or proxied) —
    # patch it instead of failing with "record already exists".
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

    # API shape mirrors the certbot-dns-gcore plugin: records live at
    # /dns/v2/zones/{zone}/{record_name}/{type} and the record name carries
    # a trailing dot. Some accounts are served by the RU endpoint, so the
    # international host is tried first and the RU one as a fallback.
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

        # 409 = the record already exists (wrong IP or proxied) — overwrite it.
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
