#!/bin/bash
# Module: server_routing — the docs.rw/learn/server-routing

SR_STATE_FILE="${DIR_REMNAWAVE}server-routing.state"
SR_PANEL_HOST="127.0.0.1:3000"
SR_DEFAULT_PORT=9999
SR_OUTBOUND_TAG="SR_BRIDGE_SS"
SR_SS_METHOD="chacha20-ietf-poly1305"

sr_state_get() {
    [ -r "$SR_STATE_FILE" ] || return 0
    sed -n "s|^$1=||p" "$SR_STATE_FILE" | head -n1
}

sr_state_set() {
    mkdir -p "$DIR_REMNAWAVE"
    touch "$SR_STATE_FILE"
    chmod 600 "$SR_STATE_FILE" 2>/dev/null
    if grep -q "^$1=" "$SR_STATE_FILE"; then
        sed -i "s|^$1=.*|$1=$2|" "$SR_STATE_FILE"
    else
        echo "$1=$2" >> "$SR_STATE_FILE"
    fi
}

sr_state_clear() {
    rm -f "$SR_STATE_FILE"
}

sr_api() {
    local method="$1" path="$2" data="${3:-}"
    make_api_request "$method" "http://${SR_PANEL_HOST}${path}" "$token" "$data"
}

sr_rand() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-4}"
}

# SS password: plain alphanumerics, so it never needs JSON escaping anywhere.
sr_gen_password() {
    tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 24
}

# --- node helpers -------------------------------------------------------------

sr_fetch_nodes() {
    local response
    response=$(sr_api "GET" "/api/nodes?_=$(date +%s)")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    SR_NODES_JSON=$(echo "$response" | jq -c '.response')
}

# Loads SR_NODE_* for the node whose address matches; rc=1 when absent.
sr_find_node_by_host() {
    local want="$1" match
    SR_NODE_UUID=""
    SR_NODE_PROFILE=""
    SR_NODE_INBOUNDS=""
    SR_NODE_CONNECTED=false
    sr_fetch_nodes || return 1
    match=$(echo "$SR_NODES_JSON" | jq -c --arg addr "$want" '[.[] | select(.address == $addr)] | .[0]')
    [ "$match" = "null" ] && return 1
    SR_NODE_UUID=$(echo "$match" | jq -r '.uuid')
    SR_NODE_PROFILE=$(echo "$match" | jq -r '.configProfile.activeConfigProfileUuid // empty')
    SR_NODE_INBOUNDS=$(echo "$match" | jq -r '.configProfile.activeInbounds // [] | join(" ")')
    SR_NODE_CONNECTED=$(echo "$match" | jq -r '.isConnected // false')
    return 0
}

sr_node_connected() {
    sr_find_node_by_host "$1" || return 1
    [ "$SR_NODE_CONNECTED" = "true" ]
}

# --- profile helpers ----------------------------------------------------------

sr_get_profile() {
    local response
    response=$(sr_api "GET" "/api/config-profiles/$1")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.config' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    SR_PROFILE_NAME=$(echo "$response" | jq -r '.response.name')
    SR_PROFILE_CONFIG=$(echo "$response" | jq -c '.response.config')
    SR_PROFILE_TAGS=$(echo "$response" | jq -c '[.response.inbounds[]? | select(.tag) | .tag]')
}

sr_patch_profile_config() {
    local uuid="$1" config="$2" response
    response=$(sr_api "PATCH" "/api/config-profiles" \
        "$(jq -nc --arg uuid "$uuid" --argjson cfg "$config" '{uuid: $uuid, config: $cfg}')")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    return 0
}

# Fresh dedicated bridge profile; sets SR_PROFILE_UUID / SR_INBOUND_UUID /
# SR_INBOUND_TAG. Dialog lines go to stderr — the caller captures nothing, but
# the convention is uniform across the value-producing helpers here.
sr_create_bridge_profile() {
    local port="$1" name tag response
    name="SR-Bridge-$(sr_rand 4)"
    tag="SR_BRIDGE_SS_IN_$(sr_rand 4)"

    step_do "${LANG[SR_CREATE_PROFILE]}" >&2
    response=$(sr_api "POST" "/api/config-profiles" "$(jq -nc \
        --arg name "$name" --arg tag "$tag" --argjson port "$port" \
        --arg method "$SR_SS_METHOD" '{
            name: $name,
            config: {
                log: { loglevel: "warning" },
                inbounds: [{
                    tag: $tag,
                    port: $port,
                    protocol: "shadowsocks",
                    settings: { method: $method, network: "tcp,udp", clients: [] },
                    sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
                }],
                outbounds: [
                    { tag: "DIRECT", protocol: "freedom" },
                    { tag: "BLOCK", protocol: "blackhole" }
                ],
                routing: { rules: [ { ip: ["geoip:private"], outboundTag: "BLOCK" } ] }
            }
        }')")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    SR_PROFILE_UUID=$(echo "$response" | jq -r '.response.uuid')
    SR_INBOUND_UUID=$(echo "$response" | jq -r --arg t "$tag" '.response.inbounds[] | select(.tag == $t) | .uuid')
    if [ -z "$SR_INBOUND_UUID" ] || [ "$SR_INBOUND_UUID" = "null" ]; then
        err_msg "${LANG[SR_CREATE_PROFILE_FAIL]}"
        return 1
    fi
    SR_INBOUND_TAG="$tag"
    step_ok "${LANG[SR_CREATE_PROFILE_OK]}" >&2
}

# Append the SS inbound to an existing profile (the node keeps serving its
# users); sets SR_INBOUND_UUID / SR_INBOUND_TAG.
sr_add_ss_inbound() {
    local profile_uuid="$1" port="$2" tag merged inbound_uuid
    tag="SR_BRIDGE_SS_IN_$(sr_rand 4)"
    sr_get_profile "$profile_uuid" || return 1

    step_do "${LANG[SR_ADD_INBOUND]}" >&2
    merged=$(echo "$SR_PROFILE_CONFIG" | jq -c \
        --arg tag "$tag" --argjson port "$port" --arg method "$SR_SS_METHOD" '
        .inbounds = ((.inbounds // []) + [{
            tag: $tag, port: $port, protocol: "shadowsocks",
            settings: { method: $method, network: "tcp,udp", clients: [] },
            sniffing: { enabled: true, destOverride: ["http", "tls", "quic"] }
        }])')
    sr_patch_profile_config "$profile_uuid" "$merged" || return 1
    inbound_uuid=$(sr_api "GET" "/api/config-profiles/$profile_uuid" \
        | jq -r --arg t "$tag" '.response.inbounds[]? | select(.tag == $t) | .uuid')
    if [ -z "$inbound_uuid" ] || [ "$inbound_uuid" = "null" ]; then
        err_msg "${LANG[SR_ADD_INBOUND_FAIL]}"
        return 1
    fi
    SR_INBOUND_UUID="$inbound_uuid"
    SR_INBOUND_TAG="$tag"
    step_ok "${LANG[SR_ADD_INBOUND_OK]}" >&2
}

# Point a node at a profile with exactly these inbounds (bulk endpoint).
sr_set_node_profile() {
    local node_uuid="$1" profile_uuid="$2"; shift 2
    local inbounds_json response
    inbounds_json=$(printf '%s\n' "$@" | jq -R . | jq -s .)
    response=$(sr_api "POST" "/api/nodes/bulk-actions/profile-modification" \
        "$(jq -nc --argjson uuids "[\"$node_uuid\"]" --arg pu "$profile_uuid" --argjson inb "$inbounds_json" \
            '{uuids: $uuids, configProfile: {activeConfigProfileUuid: $pu, activeInbounds: $inb}}')")
    # 204 with an empty body is the success shape; anything JSON with
    # statusCode/message is an API error.
    if [ -n "$response" ] && echo "$response" | jq -e 'has("statusCode") or has("message")' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    return 0
}

# --- squad and service user ---------------------------------------------------

sr_ensure_squad() {
    local inbound_uuid="$1" name response
    SR_SQUAD_UUID=$(sr_state_get squad_uuid)
    if [ -n "$SR_SQUAD_UUID" ]; then
        response=$(sr_api "GET" "/api/internal-squads")
        if echo "$response" | jq -e --arg u "$SR_SQUAD_UUID" '.response.internalSquads[]? | select(.uuid == $u)' >/dev/null 2>&1; then
            step_ok "${LANG[SR_SQUAD_REUSED]}"
            return 0
        fi
    fi

    name="SR Bridge $(sr_rand 4)"
    step_do "${LANG[SR_CREATE_SQUAD]}"
    response=$(sr_api "POST" "/api/internal-squads" \
        "$(jq -nc --arg name "$name" --argjson inbounds "[\"$inbound_uuid\"]" '{name: $name, inbounds: $inbounds}')")
    SR_SQUAD_UUID=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -z "$SR_SQUAD_UUID" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    sr_state_set squad_uuid "$SR_SQUAD_UUID"
    step_ok "${LANG[SR_CREATE_SQUAD_OK]}"
}

sr_ensure_user() {
    local squad_uuid="$1" username response user_uuid
    SR_USER_ID=$(sr_state_get user_id)
    SR_USER_NAME=$(sr_state_get user_name)
    SR_SS_PASSWORD=$(sr_state_get ss_password)
    if [ -n "$SR_USER_ID" ] && [ -n "$SR_SS_PASSWORD" ] && [ -n "$SR_USER_NAME" ]; then
        # Still alive? A user deleted by hand must not keep feeding a dead
        # password into the public profile.
        response=$(sr_api "GET" "/api/users/by-username/$SR_USER_NAME")
        if echo "$response" | jq -e --arg n "$SR_USER_NAME" '.response.username? == $n' >/dev/null 2>&1; then
            step_ok "${LANG[SR_USER_REUSED]}"
            return 0
        fi
    fi

    username="srbridge$(sr_rand 6)"
    SR_SS_PASSWORD=$(sr_gen_password)
    step_do "${LANG[SR_CREATE_USER]}"
    response=$(sr_api "POST" "/api/users" "$(jq -nc \
        --arg u "$username" --arg pass "$SR_SS_PASSWORD" --argjson squad "[\"$squad_uuid\"]" '{
            username: $u,
            status: "ACTIVE",
            expireAt: "2099-12-31T23:59:59.000Z",
            trafficLimitBytes: 0,
            activeInternalSquads: $squad,
            ssPassword: $pass,
            description: "server routing bridge service user (remnawave-reverse-proxy)"
        }')")
    user_uuid=$(echo "$response" | jq -r '.response.uuid // empty')
    SR_USER_ID=$(echo "$response" | jq -r '.response.id // empty')
    if [ -z "$user_uuid" ] || [ -z "$SR_USER_ID" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    sr_state_set user_uuid "$user_uuid"
    sr_state_set user_id "$SR_USER_ID"
    sr_state_set user_name "$username"
    sr_state_set ss_password "$SR_SS_PASSWORD"
    SR_USER_NAME="$username"
    step_ok "${LANG[SR_CREATE_USER_OK]}"
}

# --- public profile merge -----------------------------------------------------

# GET→merge→PATCH of one public RU profile. Re-running replaces our previous
# outbound and rules in place and never touches anything else in the config.
# The catch-all rule routes every inbound tag of this profile.
sr_patch_public_profile() {
    local profile_uuid="$1" host="$2" port="$3" password="$4" mode="${5:-direct}" merged
    sr_get_profile "$profile_uuid" || return 1
    if [ "$(echo "$SR_PROFILE_TAGS" | jq 'length')" -eq 0 ]; then
        err_msg "${LANG[SR_PROFILE_NO_INBOUNDS]}"
        return 1
    fi

    step_do "$(printf "${LANG[SR_PATCH_PROFILE]}" "$SR_PROFILE_NAME")"
    # direct: RU rules → DIRECT + a catch-all sending everything else into
    #          the bridge (the article's topology);
    # bridge: RU rules → the bridge and NO catch-all — untouched traffic keeps
    #          whatever egress the profile already had (direct, typically).
    merged=$(echo "$SR_PROFILE_CONFIG" | jq -c \
        --arg ob "$SR_OUTBOUND_TAG" --arg host "$host" --argjson port "$port" \
        --arg pass "$password" --arg method "$SR_SS_METHOD" --argjson tags "$SR_PROFILE_TAGS" \
        --arg mode "$mode" '
        . as $cfg
        | ((($cfg.outbounds // []) | map(select(.tag != $ob))) +
           [{ tag: $ob, protocol: "shadowsocks",
              settings: { servers: [{ address: $host, port: $port, method: $method, password: $pass, level: 0 }] } }]) as $newobs
        | (($cfg.routing.rules // []) | map(select((.outboundTag // "") != $ob))) as $keep
        | ($keep
            + (if ($keep | any((.ip // []) | index("geoip:private"))) then [] else [{ ip: ["geoip:private"], outboundTag: "BLOCK" }] end)
            + (if ($keep | any((.domain // []) | index("geosite:private"))) then [] else [{ domain: ["geosite:private"], outboundTag: "BLOCK" }] end)
            + (if ($keep | any((.protocol // []) | index("bittorrent"))) then [] else [{ protocol: ["bittorrent"], outboundTag: "BLOCK" }] end)
            + (if ($keep | any((.ip // []) | index("geoip:ru"))) then [] else [{ ip: ["geoip:ru"], outboundTag: (if $mode == "bridge" then $ob else "DIRECT" end) }] end)
            + (if ($keep | any((.domain // []) | index("geosite:category-ru"))) then [] else [{ domain: ["geosite:category-ru"], outboundTag: (if $mode == "bridge" then $ob else "DIRECT" end) }] end)
            + (if $mode == "bridge" then [] else [{ inboundTag: $tags, outboundTag: $ob }] end)) as $rules
        | $cfg + { outbounds: $newobs, routing: (($cfg.routing // {}) + { rules: $rules }) }')
    # Pre-existing RU rules sit earlier in the list and shadow ours in bridge
    # mode — the operator should know instead of wondering why RU leaks.
    if [ "$mode" = "bridge" ] \
        && echo "$SR_PROFILE_CONFIG" | jq -e 'any((.routing.rules // [])[]; ((.ip // []) | index("geoip:ru")) or ((.domain // []) | index("geosite:category-ru")))' >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}${LANG[SR_BRIDGE_MODE_SHADOW]}${COLOR_RESET}"
    fi
    sr_patch_profile_config "$profile_uuid" "$merged" || return 1
    step_ok "$(printf "${LANG[SR_PATCH_PROFILE_OK]}" "$SR_PROFILE_NAME")"
}

# Strip our outbound and rules from one public profile (teardown path).
sr_unpatch_public_profile() {
    local profile_uuid="$1" merged
    sr_get_profile "$profile_uuid" || return 1
    step_do "$(printf "${LANG[SR_UNPATCH_PROFILE]}" "$SR_PROFILE_NAME")"
    merged=$(echo "$SR_PROFILE_CONFIG" | jq -c --arg ob "$SR_OUTBOUND_TAG" '
        . as $cfg
        | (($cfg.outbounds // []) | map(select(.tag != $ob))) as $obs
        | (($cfg.routing.rules // []) | map(select((.outboundTag // "") != $ob))) as $rules
        | $cfg + { outbounds: $obs, routing: (($cfg.routing // {}) + { rules: $rules }) }')
    sr_patch_profile_config "$profile_uuid" "$merged" || return 1
    step_ok "$(printf "${LANG[SR_UNPATCH_PROFILE_OK]}" "$SR_PROFILE_NAME")"
}

# --- remote side ---------------------------------------------------------------

sr_panel_public_ip() {
    curl -s --connect-timeout 8 --max-time 12 -4 ifconfig.me 2>/dev/null \
        || curl -s --connect-timeout 8 --max-time 12 -4 api.ipify.org 2>/dev/null
}

# Public IPv4 or nothing.
sr_public_ipv4() {
    local addr="$1"
    echo "$addr" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.)'
}

# Egress sources for the DE-side ufw: addresses of the nodes the patched
# profile is active on. A node record may carry a docker-internal IP or a
# domain instead of a public IPv4 — private junk is dropped, domains resolve
# to their public IPv4; anything unresolved is skipped (the panel box IP,
# collected separately, covers the panel+node single-box case anyway).
sr_profile_node_addresses() {
    local profile_uuid="$1" addr resolved
    sr_fetch_nodes >/dev/null 2>&1 || return 0
    for addr in $(echo "$SR_NODES_JSON" | jq -r --arg p "$profile_uuid" \
        '.[] | select(.configProfile.activeConfigProfileUuid == $p) | .address' 2>/dev/null | awk 'NF'); do
        if sr_public_ipv4 "$addr" >/dev/null; then
            sr_public_ipv4 "$addr"
        else
            resolved=$(dig +short A "$addr" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            [ -n "$resolved" ] && sr_public_ipv4 "$resolved"
        fi
    done
}

# One remnanode container, host networking, no nginx/domain/certs: a bridge
# node is headless, the SS inbound listens straight on the host.
sr_remote_compose() {
    local public_key="$1"
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
      - SECRET_KEY=$public_key
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
EOL
}

# Deploy the node container on the DE box over SSH: docker bootstrap, compose,
# up, firewall, wait for the panel to report it connected. Panel-side objects
# (bridge profile, node record) must already exist.
sr_remote_deploy_node() {
    local host="$1" ss_port="$2" public_key="$3" panel_ip attempt

    step_do "${LANG[SR_REMOTE_DOCKER]}" >&2
    # Mirrors install_packages from install_remnawave.sh: curl-or-wget
    # download over get.docker.com plus the three proxy mirrors, shebang
    # validation of what landed, an Aliyun-mirror retry of the script
    # itself, and the distro docker.io only as the last resort. A minimal
    # image with neither downloader gets curl from apt first.
    if ! re_run_host "$host" 'if command -v docker >/dev/null 2>&1; then exit 0; fi
if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    apt-get -o DPkg::Lock::Timeout=300 update -y >/dev/null
    apt-get -o DPkg::Lock::Timeout=300 install -y curl
fi
docker_ok=""
for docker_url in https://get.docker.com \
    https://gh-proxy.com/https://raw.githubusercontent.com/docker/docker-install/master/install.sh \
    https://ghfast.top/https://raw.githubusercontent.com/docker/docker-install/master/install.sh \
    https://ghproxy.net/https://raw.githubusercontent.com/docker/docker-install/master/install.sh; do
    rm -f /tmp/get-docker.sh
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 10 "$docker_url" -o /tmp/get-docker.sh
    else
        wget -q --timeout=10 --tries=1 -O /tmp/get-docker.sh "$docker_url"
    fi
    if [ -s /tmp/get-docker.sh ] && head -1 /tmp/get-docker.sh | grep -q "^#!/bin/sh"; then
        if sh /tmp/get-docker.sh || sh /tmp/get-docker.sh --mirror Aliyun; then
            docker_ok=1
            break
        fi
    fi
done
rm -f /tmp/get-docker.sh
if [ -z "$docker_ok" ]; then
    apt-get -o DPkg::Lock::Timeout=300 update -y
    apt-get -o DPkg::Lock::Timeout=300 install -y docker.io docker-compose-v2 || apt-get -o DPkg::Lock::Timeout=300 install -y docker.io
fi
command -v docker >/dev/null 2>&1' >&2; then
        err_msg "${LANG[SR_REMOTE_DOCKER_FAIL]}"
        return 1
    fi

    step_do "${LANG[SR_REMOTE_COMPOSE]}" >&2
    if ! printf '%s\n' "$(sr_remote_compose "$public_key")" \
        | re_run_host "$host" "mkdir -p /opt/remnanode && cat > /opt/remnanode/docker-compose.yml" >&2; then
        err_msg "${LANG[SR_REMOTE_COMPOSE_FAIL]}"
        return 1
    fi

    step_do "${LANG[SR_REMOTE_UP]}" >&2
    # get.docker.com ships the compose plugin; a distro docker.io may not —
    # docker-compose (v1) is the last resort for the up itself.
    if ! re_run_host "$host" 'cd /opt/remnanode && { docker compose up -d || docker-compose up -d; }' >&2; then
        err_msg "${LANG[SR_REMOTE_UP_FAIL]}"
        return 1
    fi

    panel_ip=$(sr_panel_public_ip)
    if [ -n "$panel_ip" ]; then
        re_run_host "$host" "command -v ufw >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=300 install -y ufw >/dev/null 2>&1; ufw allow from $panel_ip to any port 2222 proto tcp; ufw allow from $panel_ip to any port $ss_port proto tcp" >/dev/null 2>&1
    fi

    # The panel dials the node on 2222; poll until it reports connected.
    for attempt in 1 2 3 4 5 6; do
        sleep 10
        step_do "$(printf "${LANG[SR_WAIT_CONNECT]}" "$attempt")" >&2
        if sr_node_connected "$host"; then
            step_ok "${LANG[SR_WAIT_CONNECT_OK]}" >&2
            return 0
        fi
    done
    echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_WAIT_CONNECT_FAIL]}" "$host")${COLOR_RESET}" >&2
    return 0
}

# Register the node in the panel and deploy it on the DE box.
# Sets SR_NODE_UUID / SR_PROFILE_UUID / SR_INBOUND_UUID / SR_INBOUND_TAG.
sr_remote_install_node() {
    local host="$1" ss_port="$2" response public_key
    local profile_uuid inbound_uuid inbound_tag node_uuid node_name

    # A bridge node carries no user secrets of its own; refuse to trample a
    # box that already runs one — that box belongs to a flow we don't own.
    if re_run_host "$host" "docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode"; then
        err_msg "${LANG[SR_REMOTE_NODE_EXISTS]}"
        return 1
    fi

    # A fresh publicKey from the x25519 generator is a valid node SECRET_KEY;
    # previously issued keys also stay valid (verified on a live panel), so
    # one new key per install is fine.
    step_do "${LANG[SR_REMOTE_KEYGEN]}" >&2
    response=$(sr_api "GET" "/api/system/tools/x25519/generate")
    public_key=$(echo "$response" | jq -r '.response.keypairs[0].publicKey // empty')
    if [ -z "$public_key" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    step_ok "${LANG[SR_REMOTE_KEYGEN_OK]}" >&2

    sr_create_bridge_profile "$ss_port" || return 1
    profile_uuid="$SR_PROFILE_UUID"
    inbound_uuid="$SR_INBOUND_UUID"
    inbound_tag="$SR_INBOUND_TAG"

    node_name="SR-Bridge-$(sr_rand 4)"
    step_do "${LANG[SR_CREATE_NODE]}" >&2
    response=$(sr_api "POST" "/api/nodes" "$(jq -nc \
        --arg name "$node_name" --arg addr "$host" --arg pu "$profile_uuid" --argjson inb "[\"$inbound_uuid\"]" '{
            name: $name, address: $addr, port: 2222,
            configProfile: { activeConfigProfileUuid: $pu, activeInbounds: $inb },
            isTrafficTrackingActive: false, trafficLimitBytes: 0, notifyPercent: 0,
            trafficResetDay: 31, countryCode: "XX", consumptionMultiplier: 1.0
        }')")
    node_uuid=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -z "$node_uuid" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    step_ok "${LANG[SR_CREATE_NODE_OK]}" >&2

    sr_remote_deploy_node "$host" "$ss_port" "$public_key" || return 1

    SR_NODE_UUID="$node_uuid"
    SR_PROFILE_UUID="$profile_uuid"
    SR_INBOUND_UUID="$inbound_uuid"
    SR_INBOUND_TAG="$inbound_tag"
    return 0
}

# ufw on the DE box: the SS port for every RU egress address we know of.
sr_remote_open_bridge_port() {
    local host="$1" port="$2"
    shift 2
    local sources=("$@") src cmd=""
    step_do "$(printf "${LANG[SR_UFW_OPEN]}" "$host")"
    for src in "${sources[@]}"; do
        [ -n "$src" ] || continue
        cmd="${cmd:+$cmd; }ufw allow from $src to any port $port proto tcp"
    done
    [ -n "$cmd" ] || return 0
    cmd="command -v ufw >/dev/null 2>&1 || apt-get -o DPkg::Lock::Timeout=300 install -y ufw >/dev/null 2>&1; $cmd"
    if re_run_host "$host" "$cmd" >/dev/null 2>&1; then
        step_ok "${LANG[SR_UFW_OPEN_OK]}"
    else
        echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_UFW_OPEN_FAIL]}" "$port")${COLOR_RESET}"
    fi
}

sr_remote_close_bridge_port() {
    local host="$1" port="$2"
    shift 2
    local sources=("$@") src cmd=""
    for src in "${sources[@]}"; do
        [ -n "$src" ] || continue
        cmd="${cmd:+$cmd; }ufw delete allow from $src to any port $port proto tcp"
    done
    [ -n "$cmd" ] || return 0
    re_run_host "$host" "$cmd" >/dev/null 2>&1
}

# TCP reachability of the bridge port from this box.
sr_port_reachable() {
    local host="$1" port="$2"
    timeout 5 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1
}

# --- wizard --------------------------------------------------------------------

sr_pick_bridge_host() {
    local names=() name pick i label
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(re_targets_list)

    if [ "${#names[@]}" -eq 0 ]; then
        reading "${LANG[SR_BRIDGE_HOST_PROMPT]}" SR_HOST
        [ -n "$SR_HOST" ] || return 1
        return 0
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_BRIDGE_HOST_TITLE]}${COLOR_RESET}"
    echo -e ""
    i=1
    for name in "${names[@]}"; do
        label=""
        if re_target_load "$name"; then
            [ -n "$RE_LABEL" ] && label=" (${RE_LABEL})"
            echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${RE_USER}@${RE_HOST}:${RE_PORT}${COLOR_RESET}${COLOR_GRAY}${label}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${name}${COLOR_RESET}"
        fi
        i=$((i + 1))
    done
    local last=$i
    echo -e "${COLOR_YELLOW}${last}. ${LANG[SR_BRIDGE_HOST_MANUAL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" pick
    [ -z "$pick" ] && pick=1
    if [ "$pick" = "0" ]; then
        return 1
    fi
    if [ "$pick" = "$last" ]; then
        reading "${LANG[SR_BRIDGE_HOST_PROMPT]}" SR_HOST
        [ -n "$SR_HOST" ] || return 1
        return 0
    fi
    if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#names[@]}" ]; then
        re_target_load "${names[$((pick - 1))]}"
        SR_HOST="$RE_HOST"
        return 0
    fi
    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
    sleep 1
    sr_pick_bridge_host
}

# Which public profile gets the outbound; sets SR_PICKED_PROFILE (rc=1 — the
# picker was cancelled). The bridge's own profile is never offered: routing a
# box through itself is not a thing.
sr_pick_public_profile() {
    local skip_uuid="$1" response entries=() entry uuid name count pick i rest
    response=$(sr_api "GET" "/api/config-profiles")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.configProfiles' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    while IFS= read -r entry; do
        entries+=("$entry")
    done < <(echo "$response" | jq -r --arg skip "$skip_uuid" \
        '.response.configProfiles[] | select((.uuid // "") != $skip) | "\(.uuid)\t\(.name)\t\(.inbounds | length)"')

    if [ "${#entries[@]}" -eq 0 ]; then
        err_msg "${LANG[SR_NO_PROFILES]}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_PICK_PROFILE_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_PICK_PROFILE_HINT]}${COLOR_RESET}"
    echo -e ""
    i=1
    for entry in "${entries[@]}"; do
        uuid="${entry%%$'\t'*}"
        rest="${entry#*$'\t'}"
        name="${rest%%$'\t'*}"
        count="${rest##*$'\t'}"
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${name}${COLOR_RESET} ${COLOR_GRAY}(${count} ${LANG[SR_INBOUNDS_WORD]})${COLOR_RESET}"
        i=$((i + 1))
    done
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$((i - 1))")" pick
    [ -z "$pick" ] && pick=1
    [ "$pick" = "0" ] && return 1
    if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#entries[@]}" ]; then
        SR_PICKED_PROFILE=$(echo "${entries[$((pick - 1))]}" | cut -f1)
        return 0
    fi
    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$((i - 1))"
    sleep 1
    sr_pick_public_profile "$skip_uuid"
}

sr_pick_route_mode() {
    # Where RU traffic should leave from depends on the topology: the article
    # has the entry node inside RU (RU sites leave it directly); a box abroad
    # with an RU exit machine wants the exact opposite.
    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[SR_ROUTE_MODE_TITLE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[SR_ROUTE_MODE_DIRECT]}${COLOR_RESET}"
        echo -e "    ${COLOR_GRAY}${LANG[SR_ROUTE_MODE_DIRECT_HINT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[SR_ROUTE_MODE_BRIDGE]}${COLOR_RESET}"
        echo -e "    ${COLOR_GRAY}${LANG[SR_ROUTE_MODE_BRIDGE_HINT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" SR_ROUTE_MODE_PICK
        case $SR_ROUTE_MODE_PICK in
            1) SR_ROUTE_MODE=direct; return 0 ;;
            2) SR_ROUTE_MODE=bridge; return 0 ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2 ;;
        esac
    done
}

sr_setup() {
    local host ss_port profile_uuid inbound_uuid inbound_tag node_uuid
    local profile_created=no node_installed=no has_vless=no ib mode_choice

    load_api_module || return 1
    load_remote_exec_module || return 1
    get_panel_token || { echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"; return 1; }

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_SETUP_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_SETUP_HINT]}${COLOR_RESET}"
    echo -e ""

    sr_pick_bridge_host || { echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"; return 1; }
    host="$SR_HOST"

    reading "$(printf "${LANG[SR_PORT_PROMPT]}" "$SR_DEFAULT_PORT")" ss_port
    [ -n "$ss_port" ] || ss_port=$SR_DEFAULT_PORT

    sr_pick_route_mode

    re_require_access_host "$host" || { echo -e "${COLOR_RED}$(printf "${LANG[SR_SSH_FAIL]}" "$host")${COLOR_RESET}"; return 1; }

    # Routing a box through itself is a no-op with extra encryption — catch
    # the obvious typo of picking this very server as the exit machine.
    local panel_ip host_ip
    panel_ip=$(sr_panel_public_ip)
    host_ip=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    [ -z "$host_ip" ] && host_ip="$host"
    if [ -n "$panel_ip" ] && { [ "$host" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
        echo -e "${COLOR_RED}${LANG[SR_SAME_BOX]}${COLOR_RESET}"
        return 1
    fi

    # --- bridge inbound: existing node or remote install ---------------------
    if sr_find_node_by_host "$host"; then
        node_uuid="$SR_NODE_UUID"

        # A previous run may have died after creating the node record but
        # before finishing the remote install — it left an SR-Bridge profile
        # active on the node. Reuse it instead of stacking a second one.
        local reuse_uuid="" reuse_tag
        if [ -n "$SR_NODE_PROFILE" ] && sr_get_profile "$SR_NODE_PROFILE" >/dev/null 2>&1; then
            reuse_uuid=$(echo "$SR_PROFILE_CONFIG" | jq -r '.inbounds[]? | select((.tag // "") | startswith("SR_BRIDGE_SS_IN_")) | .uuid' | head -n1)
            reuse_tag=$(echo "$SR_PROFILE_CONFIG" | jq -r '.inbounds[]? | select((.tag // "") | startswith("SR_BRIDGE_SS_IN_")) | .tag' | head -n1)
        fi

        if [ -n "$reuse_uuid" ] && [ -n "$reuse_tag" ]; then
            # Keep the inbound port in step with what was just asked (a retry
            # with a different port must not silently keep the old one).
            local cur_port fixed_cfg
            cur_port=$(echo "$SR_PROFILE_CONFIG" | jq -r --arg t "$reuse_tag" '.inbounds[]? | select(.tag == $t) | .port')
            if [ "$cur_port" != "$ss_port" ]; then
                fixed_cfg=$(echo "$SR_PROFILE_CONFIG" | jq -c --arg t "$reuse_tag" --argjson p "$ss_port" \
                    '.inbounds |= map(if .tag == $t then .port = $p else . end)')
                sr_patch_profile_config "$SR_NODE_PROFILE" "$fixed_cfg" || return 1
            fi
            profile_uuid="$SR_NODE_PROFILE"
            inbound_uuid="$reuse_uuid"
            inbound_tag="$reuse_tag"
            step_ok "${LANG[SR_REUSE_PROFILE]}"

            # The same dead run may have left the machine itself without its
            # node — finish the deployment with a fresh link key when the
            # remnanode container is not running there.
            if ! re_run_host "$host" "docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode"; then
                local response public_key
                step_do "${LANG[SR_REMOTE_KEYGEN]}" >&2
                response=$(sr_api "GET" "/api/system/tools/x25519/generate")
                public_key=$(echo "$response" | jq -r '.response.keypairs[0].publicKey // empty')
                if [ -z "$public_key" ]; then
                    err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
                    return 1
                fi
                step_ok "${LANG[SR_REMOTE_KEYGEN_OK]}" >&2
                sr_remote_deploy_node "$host" "$ss_port" "$public_key" || return 1
                node_installed=yes
            fi
        else
            has_vless=no
            if [ -n "$SR_NODE_PROFILE" ] && sr_get_profile "$SR_NODE_PROFILE" >/dev/null 2>&1; then
                for ib in $(echo "$SR_PROFILE_CONFIG" | jq -r '.inbounds[]? | select(.protocol == "vless" or .protocol == "trojan") | .uuid' 2>/dev/null); do
                    case " $SR_NODE_INBOUNDS " in
                        *" $ib "*) has_vless=yes ;;
                    esac
                done
            fi

            if [ "$has_vless" = "yes" ]; then
                echo -e ""
                echo -e "${COLOR_YELLOW}${LANG[SR_NODE_USERFACING_WARN]}${COLOR_RESET}"
                if reading_yn "${LANG[SR_NODE_ADD_INBOUND]}" confirm_add; then
                    mode_choice=add
                else
                    mode_choice=switch
                fi
            else
                mode_choice=switch
            fi

            if [ "$mode_choice" = "add" ]; then
                sr_add_ss_inbound "$SR_NODE_PROFILE" "$ss_port" || return 1
                profile_uuid="$SR_NODE_PROFILE"
                inbound_uuid="$SR_INBOUND_UUID"
                inbound_tag="$SR_INBOUND_TAG"
            else
                sr_create_bridge_profile "$ss_port" || return 1
                profile_uuid="$SR_PROFILE_UUID"
                inbound_uuid="$SR_INBOUND_UUID"
                inbound_tag="$SR_INBOUND_TAG"
                profile_created=yes
                step_do "${LANG[SR_SWITCH_NODE]}"
                sr_set_node_profile "$node_uuid" "$profile_uuid" "$inbound_uuid" || return 1
                step_ok "${LANG[SR_SWITCH_NODE_OK]}"
            fi
        fi
    else
        if ! reading_yn "$(printf "${LANG[SR_INSTALL_NODE_ASK]}" "$host")" confirm_install; then
            echo -e "${COLOR_YELLOW}${LANG[SR_INSTALL_NODE_DECLINED]}${COLOR_RESET}"
            return 1
        fi
        sr_remote_install_node "$host" "$ss_port" || return 1
        node_uuid="$SR_NODE_UUID"
        profile_uuid="$SR_PROFILE_UUID"
        inbound_uuid="$SR_INBOUND_UUID"
        inbound_tag="$SR_INBOUND_TAG"
        profile_created=yes
        node_installed=yes
    fi

    sr_state_set host "$host"
    sr_state_set port "$ss_port"
    sr_state_set route_mode "$SR_ROUTE_MODE"
    sr_state_set node_uuid "$node_uuid"
    sr_state_set profile_uuid "$profile_uuid"
    sr_state_set profile_created "$profile_created"
    sr_state_set node_installed "$node_installed"
    sr_state_set inbound_uuid "$inbound_uuid"
    sr_state_set inbound_tag "$inbound_tag"

    # --- squad + service user -------------------------------------------------
    sr_ensure_squad "$inbound_uuid" || return 1
    sr_ensure_user "$SR_SQUAD_UUID" || return 1

    # --- public RU profile ----------------------------------------------------
    sr_pick_public_profile "$profile_uuid" || return 1
    sr_patch_public_profile "$SR_PICKED_PROFILE" "$host" "$ss_port" "$SR_SS_PASSWORD" "$SR_ROUTE_MODE" || return 1

    local ru_list
    ru_list=$(sr_state_get ru_profiles)
    case " $ru_list " in
        *" $SR_PICKED_PROFILE "*) ;;
        *) ru_list="${ru_list:+$ru_list }$SR_PICKED_PROFILE" ;;
    esac
    sr_state_set ru_profiles "$ru_list"

    # --- firewall on the DE box ------------------------------------------------
    local sources=() addr panel_ip
    while IFS= read -r addr; do
        [ -n "$addr" ] && [ "$addr" != "$host" ] && sources+=("$addr")
    done < <(sr_profile_node_addresses "$SR_PICKED_PROFILE")
    panel_ip=$(sr_panel_public_ip)
    [ -n "$panel_ip" ] && sources+=("$panel_ip")
    sr_state_set ufw_sources "$(printf '%s ' "${sources[@]}")"
    sr_remote_open_bridge_port "$host" "$ss_port" "${sources[@]}"

    # --- verify -----------------------------------------------------------------
    echo -e ""
    if sr_node_connected "$host"; then
        step_ok "$(printf "${LANG[SR_STATUS_NODE_OK]}" "$host")"
    else
        echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_STATUS_NODE_DOWN]}" "$host")${COLOR_RESET}"
    fi
    if sr_port_reachable "$host" "$ss_port"; then
        step_ok "$(printf "${LANG[SR_STATUS_PORT_OK]}" "$ss_port")"
    else
        echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_STATUS_PORT_FAIL]}" "$host" "$ss_port")${COLOR_RESET}"
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_DONE_TITLE]}${COLOR_RESET}"
    printf "${COLOR_YELLOW}${LANG[SR_DONE_LINE]}${COLOR_RESET}\n" "$host" "$ss_port"
    if [ "$SR_ROUTE_MODE" = "bridge" ]; then
        echo -e "${COLOR_YELLOW}${LANG[SR_DONE_RULES_BRIDGE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[SR_DONE_TEST_BRIDGE]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[SR_DONE_RULES_DIRECT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[SR_DONE_TEST_DIRECT]}${COLOR_RESET}"
    fi
    return 0
}

# --- teardown -------------------------------------------------------------------

sr_teardown() {
    local host port ru_list uuid response user_id squad_uuid src
    host=$(sr_state_get host)
    port=$(sr_state_get port)
    ru_list=$(sr_state_get ru_profiles)

    load_remote_exec_module

    for uuid in $ru_list; do
        sr_unpatch_public_profile "$uuid" || echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_TEARDOWN_PARTIAL]}" "$uuid")${COLOR_RESET}"
    done

    user_id=$(sr_state_get user_id)
    if [ -n "$user_id" ]; then
        step_do "${LANG[SR_TEARDOWN_USER]}"
        response=$(sr_api "DELETE" "/api/users/$user_id")
        [ -z "$response" ] && step_ok "${LANG[SR_TEARDOWN_USER_OK]}"
    fi

    squad_uuid=$(sr_state_get squad_uuid)
    if [ -n "$squad_uuid" ]; then
        step_do "${LANG[SR_TEARDOWN_SQUAD]}"
        response=$(sr_api "DELETE" "/api/internal-squads/$squad_uuid")
        [ -z "$response" ] && step_ok "${LANG[SR_TEARDOWN_SQUAD_OK]}"
    fi

    if [ -n "$host" ] && [ -n "$port" ]; then
        local sources=() src
        while read -r src; do
            [ -n "$src" ] && sources+=("$src")
        done <<< "$(sr_state_get ufw_sources)"
        if [ "${#sources[@]}" -gt 0 ]; then
            step_do "${LANG[SR_TEARDOWN_UFW]}"
            sr_remote_close_bridge_port "$host" "$port" "${sources[@]}" && step_ok "${LANG[SR_TEARDOWN_UFW_OK]}"
        fi
    fi

    # The bridge node and its profile are left running: they carry no routes
    # once the public profiles are stripped, and an unknown previous state
    # makes switching the node back unsafe.
    echo -e "${COLOR_YELLOW}${LANG[SR_TEARDOWN_KEEP_NOTE]}${COLOR_RESET}"
    sr_state_clear
    step_ok "${LANG[SR_TEARDOWN_DONE]}"
}

# --- menu ------------------------------------------------------------------------

sr_configured() {
    [ -n "$(sr_state_get host)" ] && [ -n "$(sr_state_get profile_uuid)" ]
}

# Saved-token-only panel access for passive status rendering: the menu must
# never sit on an invisible username/password prompt.
sr_saved_token_works() {
    local token_file="${DIR_REMNAWAVE}token"
    [ -r "$token_file" ] || return 1
    token=$(cat "$token_file")
    sr_api "GET" "/api/config-profiles" | jq -e '.response.configProfiles' >/dev/null 2>&1
}

sr_status_live() {
    local host port
    host=$(sr_state_get host)
    port=$(sr_state_get port)

    echo -e " ${COLOR_GRAY}$(printf "${LANG[SR_STATUS_HOST]}" "$host" "$port")${COLOR_RESET}"

    if sr_saved_token_works; then
        if sr_node_connected "$host"; then
            echo -e " ${COLOR_GRAY}$(printf "${LANG[SR_STATUS_NODE_OK]}" "$host")${COLOR_RESET}"
        else
            echo -e " ${COLOR_RED}$(printf "${LANG[SR_STATUS_NODE_DOWN]}" "$host")${COLOR_RESET}"
        fi
    fi
    if sr_port_reachable "$host" "$port"; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[SR_STATUS_PORT_OK]}" "$port")${COLOR_RESET}"
    else
        echo -e " ${COLOR_YELLOW}$(printf "${LANG[SR_STATUS_PORT_FAIL]}" "$host" "$port")${COLOR_RESET}"
    fi
}

show_server_routing_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_TITLE]}${COLOR_RESET}"
    echo -e ""

    if sr_configured; then
        sr_status_live
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[SR_MENU_SETUP_AGAIN]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[SR_MENU_TEARDOWN]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" SR_OPTION

        case $SR_OPTION in
            1)
                sr_setup
                sleep 2
                show_server_routing_menu
                ;;
            2)
                if reading_yn "${LANG[SR_TEARDOWN_CONFIRM]}" confirm_teardown; then
                    load_api_module
                    if get_panel_token; then
                        sr_teardown
                    fi
                fi
                sleep 2
                show_server_routing_menu
                ;;
            0)
                return 0
                ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2
                sleep 1
                show_server_routing_menu
                ;;
        esac
    else
        echo -e " ${COLOR_GRAY}${LANG[SR_STATUS_NOT_CONFIGURED]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[SR_MENU_SETUP]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 1)" SR_OPTION

        case $SR_OPTION in
            1)
                sr_setup
                sleep 2
                show_server_routing_menu
                ;;
            0)
                return 0
                ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 1
                sleep 1
                show_server_routing_menu
                ;;
        esac
    fi
}

manage_server_routing() {
    # sr_status_live talks to the panel from the menu header already, so the
    # API module (get_panel_token / make_api_request / err_msg) must be in
    # place before any menu renders — not only inside sr_setup.
    load_api_module || return 1
    show_server_routing_menu
}
