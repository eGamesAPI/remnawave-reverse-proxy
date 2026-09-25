#!/bin/bash
# Module: Add Node to Panel

an_remote_compose() {
    local secret="$1" lineage="$2" ssl_source="$3"
    cat <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  remnawave-nginx:
    image: nginx:1.30
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
      - ${ssl_source}/$lineage/fullchain.pem:/etc/nginx/ssl/$lineage/fullchain.pem:ro
      - ${ssl_source}/$lineage/privkey.pem:/etc/nginx/ssl/$lineage/privkey.pem:ro
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - 'SECRET_KEY=$secret'
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
EOL
}

# Same nginx.conf as the manual node install: the Reality fallback on the
# unix socket with the node's own certificate, the default-server handshake
# rejection for anyone knocking without the right SNI.
an_remote_nginx_conf() {
    local domain="$1" lineage="$2"
    cat <<EOL
server_names_hash_bucket_size 64;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers 'ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305';
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name $domain;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$lineage/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$lineage/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$lineage/fullchain.pem";

    root /var/www/html;
    index index.html;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    add_header X-Robots-Tag "noindex, nofollow, noarchive, nosnippet, noimageindex" always;
    ssl_reject_handshake on;
    return 444;
}
EOL
}

# Compose for the caddy node variant — the same pair the manual caddy
# "install node only" flow builds: remnanode with the Reality inbound on 443
# plus caddy terminating TLS for the camouflage site on the shared unix
# socket. Caddy provisions and renews the certificate itself over ACME on
# :80, so this variant has no ssl mounts, no certbot and no panel-side
# sync. SECRET_KEY stays single-quoted for the same reason as above.
an_remote_caddy_compose() {
    local secret="$1" domain="$2"
    cat <<EOL
x-common: &common
  ulimits:
    nofile:
      soft: 1048576
      hard: 1048576
  restart: always

x-logging: &logging
  logging:
    driver: json-file
    options:
      max-size: 100m
      max-file: 5

services:
  caddy:
    image: caddy:2.11.2
    container_name: caddy-remnawave
    hostname: caddy-remnawave
    <<: [*common, *logging]
    network_mode: host
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - /var/www/html:/var/www/html:ro
      - /dev/shm:/dev/shm:rw
      - caddy_data:/data
    command: sh -c 'rm -f /dev/shm/nginx.sock && caddy run --config /etc/caddy/Caddyfile --adapter caddyfile'
    environment:
      - CADDY_SOCKET_PATH=/dev/shm/nginx.sock
      - SELF_STEAL_DOMAIN=$domain
    healthcheck:
      test: ["CMD", "test", "-S", "/dev/shm/nginx.sock"]
      interval: 2s
      timeout: 5s
      retries: 15
      start_period: 5s

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    <<: [*common, *logging]
    network_mode: host
    cap_add:
      - NET_ADMIN
    environment:
      - NODE_PORT=2222
      - 'SECRET_KEY=$secret'
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode

volumes:
  caddy_data:
    name: caddy_data
    driver: local
    external: false
EOL
}

# Same Caddyfile as the manual node install: the Reality fallback on the
# unix socket behind proxy_protocol, the http-to-https redirect and the :80
# catch-all that also lets caddy answer its own ACME challenges.
an_remote_caddyfile() {
    cat <<EOL
{
    admin off
    servers {
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
    auto_https disable_redirects
}

http://{\$SELF_STEAL_DOMAIN} {
    bind 0.0.0.0
    redir https://{\$SELF_STEAL_DOMAIN}{uri} permanent
}

https://{\$SELF_STEAL_DOMAIN} {
    bind unix/{\$CADDY_SOCKET_PATH}
    root * /var/www/html
    try_files {path} /index.html
    file_server
}

:80 {
    bind 0.0.0.0
    respond 204
}
EOL
}

an_panel_public_ip() {
    curl -s --connect-timeout 8 --max-time 12 -4 ifconfig.me 2>/dev/null \
        || curl -s --connect-timeout 8 --max-time 12 -4 api.ipify.org 2>/dev/null
}

# isConnected flag for the node registered with this address.
an_node_connected() {
    local domain="$1" token="$2" response
    response=$(make_api_request "GET" "http://127.0.0.1:3000/api/nodes?_=$(date +%s)" "$token" 2>/dev/null)
    [ "$(echo "$response" | jq -r --arg d "$domain" '.response[]? | select(.address == $d) | .isConnected' 2>/dev/null)" = "true" ]
}

# Provider credentials as a certbot ini, built from the session variables
# (dns_saved_credentials_load / the DNS record step seeded them) instead of
# copying the panel's ini file: that file may hold a since-revoked token —
# the panel's own wildcard was seen renewing against a dead one. The
# Cloudflare format split mirrors get_certificates: tokens carry uppercase
# letters, legacy global keys pair with the account email.
an_remote_cert_ini() {
    local provider="$1"
    case "$provider" in
        bunny) printf 'dns_bunny_api_key = %s\n' "$BUNNY_API_KEY" ;;
        gcore) printf 'dns_gcore_apitoken = %s\n' "$GCORE_API_KEY" ;;
        cloudflare)
            if [[ "$CLOUDFLARE_API_KEY" =~ [A-Z] ]]; then
                printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_KEY"
            else
                printf 'dns_cloudflare_email = %s\ndns_cloudflare_api_key = %s\n' "$CLOUDFLARE_EMAIL" "$CLOUDFLARE_API_KEY"
            fi
            ;;
    esac
}

# Issue the node's certificate ON the node itself: the panel's provider
# credentials travel over SSH, certbot does DNS-01 right where the renewal
# cron will live, so the node renews on its own forever. The certbot flags
# mirror get_certificates one to one.
an_remote_cert_issue() {
    local host="$1" domain="$2" provider="$3" email="$4"
    local base ini_name plugin_setup="" cert_cmd email_arg lineage

    base=$(extract_domain "$domain")
    case "$provider" in
        bunny) ini_name="bunny.ini" ;;
        gcore) ini_name="gcore.ini" ;;
        *)     ini_name="cloudflare.ini" ;;
    esac

    if [ -n "$email" ]; then
        email_arg="--email $email"
    else
        email_arg="--register-unsafely-without-email"
    fi

    case "$provider" in
        bunny)
            plugin_setup='if ! certbot plugins 2>/dev/null | grep -q "dns-bunny"; then
    if python3 -m pip install --help 2>&1 | grep -q break-system-packages; then
        python3 -m pip install --break-system-packages certbot-dns-bunny >/dev/null 2>&1
    else
        python3 -m pip install certbot-dns-bunny >/dev/null 2>&1
    fi
    certbot plugins 2>/dev/null | grep -q "dns-bunny" || exit 10
fi
'
            cert_cmd="certbot certonly --authenticator dns-bunny --dns-bunny-credentials ~/.secrets/certbot/bunny.ini --dns-bunny-propagation-seconds 120 --cert-name $base -d $base -d '*.$base'"
            ;;
        gcore)
            plugin_setup='if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
    if python3 -m pip install --help 2>&1 | grep -q break-system-packages; then
        python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1
    else
        python3 -m pip install certbot-dns-gcore >/dev/null 2>&1
    fi
    certbot plugins 2>/dev/null | grep -q "dns-gcore" || exit 10
fi
'
            cert_cmd="certbot certonly --authenticator dns-gcore --dns-gcore-credentials ~/.secrets/certbot/gcore.ini --dns-gcore-propagation-seconds 80 -d $base -d '*.$base'"
            ;;
        *)
            cert_cmd="certbot certonly --dns-cloudflare --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini --dns-cloudflare-propagation-seconds 60 -d $base -d '*.$base'"
            ;;
    esac

    if ! an_remote_cert_ini "$provider" \
         | re_run_host "$host" "mkdir -p ~/.secrets/certbot && cat > ~/.secrets/certbot/$ini_name && chmod 600 ~/.secrets/certbot/$ini_name"; then
        return 1
    fi

    if ! re_run_host "$host" "${plugin_setup}${cert_cmd} $email_arg --agree-tos --non-interactive --key-type ecdsa --elliptic-curve secp384r1" >&2; then
        return 1
    fi

    # The renewal cron on the node: a bind-mounted certificate keeps its
    # old inode after renewal until the web server container restarts.
    re_run_host "$host" "crontab -l 2>/dev/null | grep -q certbot || (crontab -l 2>/dev/null; echo '0 5 * * 0 /usr/bin/certbot renew --quiet --deploy-hook \"docker restart remnawave-nginx\"') | crontab -" >/dev/null 2>&1

    lineage=$(re_run_host "$host" "ls -1 /etc/letsencrypt/live/ 2>/dev/null | grep -E '^${base}(-[0-9]+)?\$' | sort -V | tail -1")
    [ -n "$lineage" ] || return 1
    echo "$lineage"
}

# A reused panel certificate is issued and renewed on the panel (DNS-01
# works from anywhere), so renewal must travel to the node: this script
# pushes the refreshed files and restarts the node's nginx — the compose
# bind-mounts the files, and without a restart the container keeps serving
# the old inode until it expires.
an_setup_cert_sync() {
    local host="$1" lineage="$2"
    local sync_script="${DIR_REMNAWAVE}node-cert-sync.sh"
    local sync_list="${DIR_REMNAWAVE}node-cert-sync.list"

    if [ ! -f "$sync_script" ]; then
        cat > "$sync_script" <<'EOL'
#!/bin/bash
# Managed by remnawave-reverse-proxy (add_node auto deploy): pushes renewed
# node certificates to the node servers. Entries live in node-cert-sync.list
# as "host lineage" lines.
set -u
DIR_REMNAWAVE="/usr/local/remnawave_reverse/"
log="${DIR_REMNAWAVE}node-cert-sync.log"
exec >>"$log" 2>&1
[ -r "${DIR_REMNAWAVE}modules/remote_exec.sh" ] || exit 0
declare -A LANG=()
. "${DIR_REMNAWAVE}modules/remote_exec.sh"

while read -r host lineage; do
    [ -n "$host" ] && [ -n "$lineage" ] || continue
    full="/etc/letsencrypt/live/$lineage/fullchain.pem"
    key="/etc/letsencrypt/live/$lineage/privkey.pem"
    [ -r "$full" ] && [ -r "$key" ] || continue
    end=$(openssl x509 -noout -enddate -in "$full" 2>/dev/null) || continue
    days=$(( ($(date -d "${end#notAfter=}" +%s) - $(date +%s)) / 86400 ))
    [ "$days" -lt 31 ] || continue
    if cat "$full" | re_run_host "$host" "cat > /opt/remnanode/ssl/$lineage/fullchain.pem" \
       && cat "$key" | re_run_host "$host" "cat > /opt/remnanode/ssl/$lineage/privkey.pem"; then
        re_run_host "$host" "docker restart remnawave-nginx" >/dev/null 2>&1
        echo "$(date '+%F %T') $host $lineage synced ($days days left)"
    else
        echo "$(date '+%F %T') $host $lineage PUSH FAILED"
    fi
done < "${DIR_REMNAWAVE}node-cert-sync.list"
EOL
        chmod 700 "$sync_script" 2>/dev/null
        : > "$sync_list"
        chmod 600 "$sync_list" 2>/dev/null
    fi

    grep -qxF "$host $lineage" "$sync_list" 2>/dev/null || echo "$host $lineage" >> "$sync_list"
    add_cron_rule "30 4 * * * /bin/bash ${DIR_REMNAWAVE}node-cert-sync.sh"
}

# Which DNS provider actually hosts the zone: the panel's own certificate
# for it was issued by that provider's authenticator — a saved key merely
# existing (a dead Gcore ini next to a live Cloudflare one) says nothing
# about where the zone lives.
an_zone_provider() {
    # conf must not sit in the same local line as base: words of a single
    # builtin expand before any of its assignments land, so $base would be
    # empty and the conf path silently wrong.
    local base="$1" auth
    local conf="/etc/letsencrypt/renewal/$base.conf"
    [ -f "$conf" ] && auth=$(sed -n 's/^authenticator[[:space:]]*=[[:space:]]*//p' "$conf" | head -1)
    case "$auth" in
        dns-cloudflare) echo cloudflare ;;
        dns-bunny)      echo bunny ;;
        dns-gcore)      echo gcore ;;
    esac
}

# Deploy the freshly registered node on its server over SSH: DNS record and
# package bootstrap through the project's own modules, certificate — reused
# from the panel when its wildcard already covers the node domain, issued on
# the node otherwise — camouflage site, firewall, containers, then wait for
# the panel to report the node connected.
an_auto_deploy() {
    local domain="$1" token="$3" ws="${4:-nginx}"
    local host
    local tmpd lineage secret panel_ip node_ip base_domain
    local dns_prov="" cert_on_node=0 ssl_source self lang_val

    load_remote_exec_module || return 1
    # Target lookup, domain-first: an existing target bound to the domain is
    # reused silently; a resolving domain goes straight to the module's
    # bootstrap by that name (no address questions — the domain WAS the
    # answer). Only a domain that resolves nowhere — brand-new, the A record
    # appears later in this very flow — asks for the server IP, the one
    # thing ssh cannot do without.
    re_migrate_legacy
    local cand_ip ssh_addr
    cand_ip=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
    if ! { re_target_load_by_host "$domain" && re_try_key "$RE_HOST" "$RE_PORT" "$RE_USER" "$RE_KEY"; }; then
        if { [ -n "$cand_ip" ] && re_target_load_by_host "$cand_ip" && re_try_key "$RE_HOST" "$RE_PORT" "$RE_USER" "$RE_KEY"; }; then
            :
        else
            ssh_addr="$domain"
            if [ -z "$cand_ip" ]; then
                reading "$(printf "${LANG[AN_SSH_HOST_IP]}" "$domain")" ssh_addr
                if [ -z "$ssh_addr" ]; then
                    echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"
                    return 2
                fi
            fi
            if ! re_bootstrap "$ssh_addr"; then
                # The bootstrap has already said why. rc 2 marks a user
                # walk-away so the caller offers no retry.
                return 2
            fi
        fi
    fi
    host="$RE_HOST"
    step_ok "$(printf "${LANG[AN_SSH_OK]}" "${RE_USER}@${RE_HOST}:${RE_PORT}")"

    node_ip=$(re_run_host "$host" "curl -s -4 --max-time 10 ifconfig.me || curl -s -4 --max-time 10 api.ipify.org" 2>/dev/null)
    if [ -z "$node_ip" ]; then
        err_msg "${LANG[AN_NO_NODE_IP]}"
        return 1
    fi

    # A remnanode that already runs on the box belongs to a flow we do not
    # own — replacing it destroys that node's registration, so it is always
    # a confirmation, never an assumption.
    if re_run_host "$host" "if command -v docker >/dev/null 2>&1; then docker ps -a --format '{{.Names}}' | grep -qx remnanode; else exit 1; fi" >/dev/null 2>&1; then
        if reading_yn "${LANG[AN_REMOTE_REINSTALL_ASK]}" confirm_remote_reinstall; then
            re_run_host "$host" "cd /opt/remnanode && { docker compose down || docker-compose down; }" >/dev/null 2>&1
        else
            err_msg "${LANG[AN_REMOTE_ABORT]}"
            # A deliberate no — retrying would just re-ask the same question.
            return 2
        fi
    fi

    if re_run_host "$host" "ss -tln 2>/dev/null | awk '{print \$4}' | grep -qE ':443$'" >/dev/null 2>&1; then
        err_msg "${LANG[AN_PORT_BUSY]}"
        return 1
    fi

    # Caddy answers ACME on :80 — a listener already sitting there would leave
    # the caddy container crash-looping after a "successful" deploy.
    if [ "$ws" = "caddy" ] \
        && re_run_host "$host" "ss -tln 2>/dev/null | awk '{print \$4}' | grep -qE ':80$'" >/dev/null 2>&1; then
        err_msg "${LANG[AN_PORT80_BUSY]}"
        return 1
    fi

    step_do "${LANG[SR_REMOTE_KEYGEN]}" >&2
    local response
    response=$(make_api_request "GET" "http://127.0.0.1:3000/api/keygen" "$token")
    secret=$(echo "$response" | jq -r '.response.secretKey // empty')
    if [ -z "$secret" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    step_ok "${LANG[SR_REMOTE_KEYGEN_OK]}" >&2

    # The node's domain must point at the node, not at this panel: the A
    # record is created through the panel's saved DNS-API credentials, with
    # the node's IP — Reality breaks behind a proxied record, so no
    # Cloudflare proxy tolerance here.
    load_dns_records_module
    base_domain=$(extract_domain "$domain")
    dns_saved_credentials_load
    # The provider of a zone the panel already holds a certificate for is
    # read from its renewal conf — that pairing is certain, the record is
    # created silently. An unknown zone gets a picker instead: keys merely
    # present in ~/.secrets say nothing about where THIS zone lives (live
    # case: a Cloudflare key saved, the new zone actually on Gcore).
    local zone_prov dns_pick
    zone_prov=$(an_zone_provider "$base_domain")
    case "$zone_prov" in
        cloudflare) [ -n "$CLOUDFLARE_API_KEY" ] || zone_prov="" ;;
        gcore)      [ -n "$GCORE_API_KEY" ] || zone_prov="" ;;
        bunny)      [ -n "$BUNNY_API_KEY" ] || zone_prov="" ;;
    esac
    if ! dns_record_points_here "$domain" "$node_ip" false; then
        if [ -n "$zone_prov" ]; then
            step_do "$(printf "${LANG[AN_DNS_STEP]}" "$domain" "$node_ip")" >&2
            case "$zone_prov" in
                cloudflare) ensure_dns_record_cloudflare "$domain" "$base_domain" "$node_ip" || return 1 ;;
                gcore)      ensure_dns_record_gcore "$domain" "$base_domain" "$node_ip" || return 1 ;;
                bunny)      ensure_dns_record_bunny "$domain" "$base_domain" "$node_ip" || return 1 ;;
            esac
            step_ok "${LANG[AN_DNS_OK]}" >&2
        else
            echo -e ""
            echo -e "${COLOR_GREEN}$(printf "${LANG[AN_DNS_PICK_TITLE]}" "$base_domain")${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}1. ${LANG[DNS_RECORD_CREATE_CF]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}2. ${LANG[DNS_RECORD_CREATE_GC]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}3. ${LANG[DNS_RECORD_CREATE_BUNNY]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}4. ${LANG[DNS_RECORD_MANUAL]}${COLOR_RESET}"
            echo -e ""
            while true; do
                reading "${LANG[DNS_RECORD_CHOOSE]}" dns_pick
                case "$dns_pick" in
                    1)
                        step_do "$(printf "${LANG[AN_DNS_STEP]}" "$domain" "$node_ip")" >&2
                        ensure_dns_record_cloudflare "$domain" "$base_domain" "$node_ip" && { step_ok "${LANG[AN_DNS_OK]}" >&2; break; }
                        ;;
                    2)
                        step_do "$(printf "${LANG[AN_DNS_STEP]}" "$domain" "$node_ip")" >&2
                        ensure_dns_record_gcore "$domain" "$base_domain" "$node_ip" && { step_ok "${LANG[AN_DNS_OK]}" >&2; break; }
                        ;;
                    3)
                        step_do "$(printf "${LANG[AN_DNS_STEP]}" "$domain" "$node_ip")" >&2
                        ensure_dns_record_bunny "$domain" "$base_domain" "$node_ip" && { step_ok "${LANG[AN_DNS_OK]}" >&2; break; }
                        ;;
                    4)
                        manual_dns_record_flow "$domain" "$node_ip" false && break
                        ;;
                    *)
                        echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
                        ;;
                esac
            done
        fi
    fi

    # Package bootstrap through the project's own script: docker with the
    # full mirror chain, ufw (443 open, ssh preserved), certbot, BBR —
    # exactly what the manual node install would run on this box. The
    # language file is preseeded so the script never prompts over the wire.
    lang_val=$(cat "$LANG_FILE" 2>/dev/null)
    case "$lang_val" in 1|2) ;; *) lang_val=2 ;; esac
    # A checkout the script runs from beats the installed copy: it is the
    # exact code under test and may know flags the installed one does not.
    self=""
    [ -n "$LOCAL_SRC_DIR" ] && [ -s "${LOCAL_SRC_DIR}/../install_remnawave.sh" ] && self="${LOCAL_SRC_DIR}/../install_remnawave.sh"
    [ -z "$self" ] && self="${DIR_REMNAWAVE}remnawave_reverse"
    [ -s "$self" ] || self="/usr/local/bin/remnawave_reverse"
    if [ ! -s "$self" ]; then
        err_msg "${LANG[AN_PACKAGES_FAIL]}"
        return 1
    fi

    step_do "${LANG[AN_PACKAGES]}" >&2
    if ! printf '%s\n' "$lang_val" | re_run_host "$host" "mkdir -p ${DIR_REMNAWAVE} && cat > ${DIR_REMNAWAVE}selected_language" \
       || ! cat "$self" | re_run_host "$host" "cat > /tmp/remnawave_bootstrap.sh" \
       || ! re_run_host "$host" "bash /tmp/remnawave_bootstrap.sh --bootstrap-packages; rc=\$?; rm -f /tmp/remnawave_bootstrap.sh; exit \$rc" >&2; then
        err_msg "${LANG[AN_PACKAGES_FAIL]}"
        return 1
    fi

    # Certificate. A panel wildcard that already covers the node domain is
    # reused — registering a second certificate for the same zone would be
    # pointless. Anything else is issued on the node itself, and the node
    # renews it on its own from then on. The caddy variant opts out of the
    # whole branch: caddy provisions and renews its own certificate over
    # ACME on the open port 80, so there is nothing to copy or sync.
    load_certificates_module
    if [ "$ws" = "caddy" ]; then
        :
    elif lineage=$(resolve_certificate_domain "$domain"); then
        ssl_source="./ssl"
    else
        cert_on_node=1
        # The record step names the provider it just used (DNS_RECORD_PROVIDER);
        # a pre-existing record falls back to the renewal-conf pairing.
        local cert_prov="${DNS_RECORD_PROVIDER:-$zone_prov}"
        local cert_email
        cert_email=$(sed -n 's/^email = //p' /etc/letsencrypt/renewal/*.conf 2>/dev/null | head -n1)
        case "$cert_prov" in
            bunny|gcore|cloudflare) ;;
            *)
                err_msg "$(printf "${LANG[AN_DNS_UNKNOWN]}" "$base_domain")"
                return 1
                ;;
        esac
        step_do "$(printf "${LANG[AN_CERT_ISSUE]}" "$domain")" >&2
        if ! lineage=$(an_remote_cert_issue "$host" "$domain" "$cert_prov" "$cert_email"); then
            err_msg "$(printf "${LANG[AN_CERT_FAIL]}" "$domain")"
            return 1
        fi
        ssl_source="/etc/letsencrypt/live"
    fi

    # The camouflage site is generated on the panel into a staging dir —
    # the panel's own /var/www/html keeps serving the panel's site.
    load_selfsteal_templates_module || { err_msg "${LANG[AN_HTML_FAIL]}"; return 1; }
    tmpd=$(mktemp -d) || return 1
    randomhtml_start_spinner
    if ! { randomhtml_fetch "" && randomhtml_pick_random && randomhtml_apply "$tmpd/html"; }; then
        randomhtml_stop_spinner 2>/dev/null
        rm -rf "$tmpd"
        err_msg "${LANG[AN_HTML_FAIL]}"
        return 1
    fi
    # The spinner watches the MAIN pid — left running it would churn braille
    # dots over every later step line and the menu, until the script exits.
    randomhtml_stop_spinner 2>/dev/null

    # Caddy's ACME handshake arrives on :80 — without the rule the very
    # first certificate issue would stall behind the firewall.
    if [ "$ws" = "caddy" ]; then
        if re_run_host "$host" "ufw allow 80/tcp" >/dev/null 2>&1; then
            step_ok "${LANG[AN_UFW_80_OK]}" >&2
        else
            echo -e "${COLOR_YELLOW}${LANG[AN_UFW_80_FAIL]}${COLOR_RESET}" >&2
        fi
    fi

    # The panel dials the node on 2222; ufw is up after the bootstrap, so
    # the rule has to land now or the panel never reaches the node.
    panel_ip=$(an_panel_public_ip)
    if [ -n "$panel_ip" ]; then
        if re_run_host "$host" "ufw allow from $panel_ip to any port 2222 proto tcp" >/dev/null 2>&1; then
            step_ok "${LANG[AN_UFW_2222_OK]}" >&2
        else
            echo -e "${COLOR_YELLOW}${LANG[AN_UFW_2222_FAIL]}${COLOR_RESET}" >&2
        fi
    else
        echo -e "${COLOR_YELLOW}${LANG[AN_NO_PANEL_IP]}${COLOR_RESET}" >&2
    fi

    step_do "${LANG[SR_REMOTE_COMPOSE]}" >&2
    local compose_body conf_body conf_path mkdir_cmd
    if [ "$ws" = "caddy" ]; then
        compose_body=$(an_remote_caddy_compose "$secret" "$domain")
        conf_body=$(an_remote_caddyfile)
        conf_path="/opt/remnanode/Caddyfile"
        mkdir_cmd="/opt/remnanode"
    else
        compose_body=$(an_remote_compose "$secret" "$lineage" "$ssl_source")
        conf_body=$(an_remote_nginx_conf "$domain" "$lineage")
        conf_path="/opt/remnanode/nginx.conf"
        mkdir_cmd="/opt/remnanode/ssl/$lineage"
    fi
    if ! printf '%s\n' "$compose_body" \
         | re_run_host "$host" "mkdir -p $mkdir_cmd && cat > /opt/remnanode/docker-compose.yml" \
       || ! printf '%s\n' "$conf_body" \
         | re_run_host "$host" "cat > $conf_path" \
       || { [ "$ws" != "caddy" ] && [ "$cert_on_node" = 0 ] \
            && ! cat "/etc/letsencrypt/live/$lineage/fullchain.pem" \
               | re_run_host "$host" "cat > /opt/remnanode/ssl/$lineage/fullchain.pem"; } \
       || { [ "$ws" != "caddy" ] && [ "$cert_on_node" = 0 ] \
            && ! cat "/etc/letsencrypt/live/$lineage/privkey.pem" \
               | re_run_host "$host" "cat > /opt/remnanode/ssl/$lineage/privkey.pem"; } \
       || ! tar -C "$tmpd/html" -cf - . \
         | re_run_host "$host" "mkdir -p /var/www/html && tar -xf - -C /var/www/html"; then
        rm -rf "$tmpd"
        err_msg "${LANG[AN_PUSH_FAIL]}"
        return 1
    fi
    step_ok "${LANG[SR_REMOTE_COMPOSE_OK]}" >&2

    step_do "${LANG[SR_REMOTE_UP]}" >&2
    if ! re_run_host "$host" 'cd /opt/remnanode && { docker compose up -d || docker-compose up -d; }' >&2; then
        rm -rf "$tmpd"
        err_msg "${LANG[SR_REMOTE_UP_FAIL]}"
        return 1
    fi

    rm -rf "$tmpd"
    if [ "$cert_on_node" = 0 ] && [ "$ws" != "caddy" ]; then
        an_setup_cert_sync "$host" "$lineage"
    fi

    local attempt resolved_ip="" hosts_hinted=0
    resolved_ip=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

    # A freshly created record stays invisible to the panel's resolver for
    # minutes (live: Quad9 kept the negative entry ~10 minutes after the
    # record already existed everywhere else). The panel keeps retrying and
    # would connect on its own eventually, but the wait is avoidable: hint
    # the panel container with the known IP. The line lives until the
    # container restarts, and is cleaned up below once real DNS answers.
    if [ -n "$node_ip" ] && [ -z "$resolved_ip" ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave; then
            if docker exec remnawave sh -c "grep -q '$node_ip $domain\$' /etc/hosts 2>/dev/null || echo '$node_ip $domain' >> /etc/hosts" 2>/dev/null; then
                hosts_hinted=1
                step_ok "$(printf "${LANG[AN_HOSTS_HINT]}" "$domain")" >&2
            fi
        fi
    fi

    # With the hint in place the panel resolves the name already — skip the
    # DNS wait and go straight to the connection poll. The wait is only for
    # the unhinted case (no panel container or the exec failed).
    if [ "$hosts_hinted" = 0 ] && [ -z "$resolved_ip" ]; then
        for attempt in 1 2 3 4 5 6 7 8; do
            resolved_ip=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
            [ -n "$resolved_ip" ] && break
            step_do "$(printf "${LANG[AN_WAIT_DNS]}" "$domain" "$attempt")" >&2
            sleep 15
        done
    fi

    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        sleep 15
        step_do "$(printf "${LANG[SR_WAIT_CONNECT]}" "$attempt")" >&2
        if an_node_connected "$domain" "$token"; then
            step_ok "${LANG[SR_WAIT_CONNECT_OK]}" >&2
            echo -e "${COLOR_GREEN}${LANG[AN_DEPLOY_OK]}${COLOR_RESET}"
            if [ "$ws" = "caddy" ]; then
                echo -e "${COLOR_GRAY}${LANG[AN_SYNC_CADDY]}${COLOR_RESET}"
            elif [ "$cert_on_node" = 0 ]; then
                echo -e "${COLOR_GRAY}${LANG[AN_SYNC_NOTE]}${COLOR_RESET}"
            else
                echo -e "${COLOR_GRAY}${LANG[AN_SYNC_NODE]}${COLOR_RESET}"
            fi
            if [ "$hosts_hinted" = 1 ]; then
                # The success banner is the last word the operator reads —
                # the hint cleanup runs in the background, silently: it waits
                # for real DNS and takes the line back; if the menu closes
                # before that, the line simply dies with the container's next
                # restart. /etc/hosts inside the container is bind-mounted,
                # so the rewrite goes through cat, never sed -i.
                (
                    dns_now=""
                    for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
                        dns_now=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1)
                        [ -n "$dns_now" ] && break
                        sleep 15
                    done
                    [ -n "$dns_now" ] && docker exec remnawave sh -c "grep -v '$node_ip $domain\$' /etc/hosts > /tmp/an-h && cat /tmp/an-h > /etc/hosts && rm -f /tmp/an-h" 2>/dev/null
                ) >/dev/null 2>&1 &
            fi
            return 0
        fi
    done
    echo -e "${COLOR_YELLOW}${LANG[AN_WAIT_FAIL]}${COLOR_RESET}"
    return 0
}

an_show_manual_instruction() {
    echo -e "${COLOR_RED}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_RED}${LANG[POST_PANEL_INSTRUCTION]}${COLOR_RESET}"
    echo -e "${COLOR_RED}-------------------------------------------------${COLOR_RESET}"
}

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

    local auto_mode
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[AN_MODE_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[AN_MODE_AUTO]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[AN_MODE_AUTO_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[AN_MODE_MANUAL]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[AN_MODE_MANUAL_HINT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    while true; do
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" auto_mode
        case "$auto_mode" in
            1|2) break ;;
            0) echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"; return 0 ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2
                sleep 1
                ;;
        esac
    done

    # The web server only matters for the automatic path — the manual one
    # picks it later in the "install node only" flow on the node itself.
    local an_ws="nginx" ws_choice
    if [ "$auto_mode" = "1" ]; then
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[SELECT_WEBSERVER_TITLE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. Nginx${COLOR_RESET}"
        echo -e "    ${COLOR_GRAY}${LANG[AN_WS_NGINX_HINT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. Caddy${COLOR_RESET}"
        echo -e "    ${COLOR_GRAY}${LANG[AN_WS_CADDY_HINT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        while true; do
            reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" ws_choice
            case "$ws_choice" in
                1) an_ws="nginx"; break ;;
                2) an_ws="caddy"; break ;;
                0) echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"; return 0 ;;
                *)
                    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2
                    sleep 1
                    ;;
            esac
        done
    fi

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

    # Best-effort: bind the shared node plugin (node plugins menu manages it)
    # right at birth — without activePluginUuid the node runs no plugin at all.
    local plugin_uuid=""
    plugin_uuid=$(make_api_request "GET" "http://$domain_url/api/node-plugins?_=$(date +%s)" "$token" 2>/dev/null \
        | jq -r '[.response[]? | select(
               .name == "Reverse Node Plugins"
               or ((.pluginConfig // {}) | (has("torrentBlocker") or has("ingressFilter") or has("egressFilter"))))]
             | first | .uuid // empty' 2>/dev/null)

    create_node "$domain_url" "$token" "$config_profile_uuid" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$entity_name" "$plugin_uuid" || return 1

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

    if [ "$auto_mode" != "1" ]; then
        an_show_manual_instruction
        return 0
    fi

    local deployed=1 retry rc=0
    while true; do
        rc=0
        an_auto_deploy "$SELFSTEAL_DOMAIN" "$entity_name" "$token" "$an_ws" && { deployed=0; break; } || rc=$?
        [ "$rc" = 2 ] && break
        reading_yn "${LANG[AN_RETRY_ASK]}" retry || break
    done
    if [ "$deployed" -ne 0 ]; then
        echo -e ""
        if [ "$rc" = 2 ]; then
            echo -e "${COLOR_YELLOW}${LANG[AN_CANCELLED]}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[AN_FALLBACK]}${COLOR_RESET}"
        fi
        an_show_manual_instruction
    fi
}
