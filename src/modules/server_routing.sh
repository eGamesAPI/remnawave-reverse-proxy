#!/bin/bash
# Module: server_routing — the docs.rw/learn/server-routing and https://xtls.github.io/en/config/routing.html#ruleobject

# One file per bridge in this directory; the filename slug is the bridge's
# stable internal id (the display name inside can be renamed freely).
SR_CONF_DIR="${DIR_REMNAWAVE}server-routing"
SR_LEGACY_STATE="${DIR_REMNAWAVE}server-routing.state"
SR_PANEL_HOST="127.0.0.1:3000"
SR_DEFAULT_PORT=9999
SR_OUTBOUND_TAG="SR_BRIDGE_SS"
SR_ROUTE_OB_PREFIX="SR_BRIDGE_SS_"
SR_SS_METHOD="chacha20-ietf-poly1305"
SR_CURRENT=""
SR_ATTACHED_MAP=""

sr_state_file() {
    printf '%s/%s.bridge' "$SR_CONF_DIR" "${SR_CURRENT:-_none_}"
}

sr_state_get() {
    [ -n "$SR_CURRENT" ] || return 0
    local file
    file=$(sr_state_file)
    [ -r "$file" ] || return 0
    sed -n "s|^$1=||p" "$file" | head -n1
}

sr_state_set() {
    [ -n "$SR_CURRENT" ] || return 0
    local file val
    file=$(sr_state_file)
    mkdir -p "$SR_CONF_DIR"
    chmod 700 "$SR_CONF_DIR" 2>/dev/null
    touch "$file"
    chmod 600 "$file" 2>/dev/null
    if grep -q "^$1=" "$file"; then
        # The replacement is sed-interpreted: a remark typed with &, | or a
        # backslash would corrupt the state line (and host_remark IS free
        # user input).
        val=$(printf '%s\n' "$2" | sed -e 's/[\\|&]/\\&/g')
        sed -i "s|^$1=.*|$1=$val|" "$file"
    else
        echo "$1=$2" >> "$file"
    fi
}

sr_state_clear() {
    [ -n "$SR_CURRENT" ] || return 0
    rm -f "$(sr_state_file)"
}

# One-shot import of the pre-multi-bridge single state file.
sr_migrate_legacy() {
    [ -f "$SR_LEGACY_STATE" ] || return 0
    mkdir -p "$SR_CONF_DIR"
    chmod 700 "$SR_CONF_DIR" 2>/dev/null
    local slug fslug n=0
    slug=$(sr_name_slug "$(sed -n 's|^bridge_name=||p' "$SR_LEGACY_STATE" | head -n1)")
    [ -n "$slug" ] || slug=$(sr_name_slug "$(sed -n 's|^host=||p' "$SR_LEGACY_STATE" | head -n1)")
    [ -n "$slug" ] || slug="bridge"
    fslug="$slug"
    while [ -e "${SR_CONF_DIR}/${fslug}.bridge" ]; do
        n=$((n + 1))
        fslug="${slug}-${n}"
    done
    mv "$SR_LEGACY_STATE" "${SR_CONF_DIR}/${fslug}.bridge"
}

# Every configured bridge slug, one per line.
sr_bridges_list() {
    local f
    for f in "$SR_CONF_DIR"/*.bridge; do
        [ -f "$f" ] || continue
        basename "$f" .bridge
    done
}

# Bridge type: "geo" (country split for the whole profile) or "route"
# (per-user exits via VLESS Route hosts). Files written before the split
# carry no type — those are geo bridges.
sr_bridge_type() {
    local t
    t=$(sed -n 's|^type=||p' "${SR_CONF_DIR}/$1.bridge" 2>/dev/null | head -n1)
    echo "${t:-geo}"
}

# Geo bridges share the SR_BRIDGE_SS outbound; every route bridge writes
# its own tag, so several of them can feed one profile at once.
sr_bridge_outbound_tag() {
    if [ "$(sr_bridge_type "$1")" = "route" ]; then
        echo "${SR_ROUTE_OB_PREFIX}$1"
    else
        echo "$SR_OUTBOUND_TAG"
    fi
}

# "uuid=slug" pairs for every profile attached to a GEO bridge — used to
# mark profiles in the picker and to drop stale claims when a profile is
# repointed. Route bridges are skipped on purpose: several route bridges
# may legitimately feed the same profile, and a geo attach must not strip
# their claims (their teardown would then leak rules).
sr_attached_map() {
    local slug line uuid list out=""
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ "$(sr_bridge_type "$slug")" = "geo" ] || continue
        list=$(sed -n 's|^ru_profiles=||p' "${SR_CONF_DIR}/${slug}.bridge" | head -n1)
        for uuid in $list; do
            [ -n "$uuid" ] && out="${out:+$out }${uuid}=${slug}"
        done
    done < <(sr_bridges_list)
    printf '%s' "$out"
}

# Same shape as sr_attached_map but for ROUTE bridges — informational
# markers only: several route bridges may legitimately feed one profile,
# so the picker shows the claim without any repoint question.
sr_route_claims_map() {
    local slug list uuid out=""
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ "$(sr_bridge_type "$slug")" = "route" ] || continue
        [ "$slug" != "${SR_CURRENT:-}" ] || continue
        list=$(sed -n 's|^ru_profiles=||p' "${SR_CONF_DIR}/${slug}.bridge" | head -n1)
        for uuid in $list; do
            [ -n "$uuid" ] && out="${out:+$out }${uuid}=${slug}"
        done
    done < <(sr_bridges_list)
    printf '%s' "$out"
}

# Remove a profile claim from every bridge state except the current one —
# the winning bridge rewrites the config, the losers must stop tracking it
# (otherwise their teardown would strip the new bridge's rules).
sr_detach_profile_from_others() {
    local uuid="$1" slug file list new_list
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ "$slug" != "$SR_CURRENT" ] || continue
        file="${SR_CONF_DIR}/${slug}.bridge"
        [ -f "$file" ] || continue
        list=$(sed -n 's|^ru_profiles=||p' "$file" | head -n1)
        case " $list " in
            *" $uuid "*)
                new_list=""
                for u in $list; do
                    [ "$u" = "$uuid" ] || new_list="${new_list:+$new_list }$u"
                done
                sed -i "s|^ru_profiles=.*|ru_profiles=$new_list|" "$file"
                ;;
        esac
    done < <(sr_bridges_list)
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
# Exact string first, then by resolved IP: nodes registered through add_node
# carry a DOMAIN address while the operator picks machines by IP — without
# the IP fallback the setup flow mistakes a live user-facing node for «no node»
# and offers to trample it.
# The jq here sticks to the most conservative forms (no array building, no
# index-after-pipe): the panel box may run an old jq, and this chain fires
# on every wait-loop tick, so it must not have exotic corners.
sr_find_node_by_host() {
    local want="$1" match rec node_addr resolved want_ip
    SR_NODE_UUID=""
    SR_NODE_PROFILE=""
    SR_NODE_INBOUNDS=""
    SR_NODE_CONNECTED=false
    sr_fetch_nodes || return 1
    match=$(echo "$SR_NODES_JSON" | jq -c --arg addr "$want" '.[] | select(.address == $addr)' | head -n1)
    if [ -z "$match" ]; then
        if sr_public_ipv4 "$want" >/dev/null; then
            want_ip="$want"
        else
            want_ip=$(dig +short A "$want" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        fi
        [ -n "$want_ip" ] || return 1
        while IFS= read -r rec; do
            [ -n "$rec" ] || continue
            node_addr=$(echo "$rec" | jq -r '.address // empty')
            [ -n "$node_addr" ] || continue
            if [ "$node_addr" != "$want_ip" ]; then
                # Skip private/docker placeholders outright; domains must
                # survive to the resolve below.
                case "$node_addr" in
                    10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|127.*|169.254.*) continue ;;
                esac
                resolved=$(dig +short A "$node_addr" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
                [ "$resolved" = "$want_ip" ] || continue
            fi
            match="$rec"
            break
        done < <(echo "$SR_NODES_JSON" | jq -c '.[]')
    fi
    [ -n "$match" ] || return 1
    SR_NODE_UUID=$(echo "$match" | jq -r '.uuid // empty')
    SR_NODE_PROFILE=$(echo "$match" | jq -r '.configProfile.activeConfigProfileUuid // empty')
    # activeInbounds arrives as uuid strings on some panel builds and as full
    # inbound objects on others (seen live: join() chokes on the objects with
    # "string and object cannot be added") — normalize both to a flat list.
    SR_NODE_INBOUNDS=$(echo "$match" | jq -r '[.configProfile.activeInbounds[]? | if type == "string" then . else (.uuid // empty) end] | join(" ")')
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
    # Panel metadata about the inbounds — the ONLY place where inbound uuids
    # live; the Xray config itself carries tags and ports, never uuids.
    SR_PROFILE_INBOUNDS=$(echo "$response" | jq -c '[.response.inbounds[]? | {uuid: (.uuid // ""), tag: (.tag // ""), port: (.port // null)}]')
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
    name="${SR_NODE_NAME:-SR-Bridge-$(sr_rand 4)}"
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
    # Profile names are unique panel-wide; a leftover with the same name gets
    # a suffix instead of failing the whole setup.
    if echo "$response" | grep -q "already exists"; then
        name="${name}-$(sr_rand 4)"
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
    fi
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
    local inbound_uuid="$1" name response want have
    SR_SQUAD_UUID=$(sr_state_get squad_uuid)
    if [ -n "$SR_SQUAD_UUID" ]; then
        response=$(sr_api "GET" "/api/internal-squads")
        if echo "$response" | jq -e --arg u "$SR_SQUAD_UUID" '.response.internalSquads[]? | select(.uuid == $u)' >/dev/null 2>&1; then
            # The squad may have been born against a DIFFERENT exit inbound:
            # the setup flow reuses squad+user when the exit machine changes, and
            # the new exit's SS inbound only learns the service user through
            # the squad's inbound list. Without the re-assert the whole tunnel
            # dies on SS auth (live case: exit switched Moscow→Estonia, every
            # RU site went dark while the port still answered TCP).
            want="\"$inbound_uuid\""
            have=$(echo "$response" | jq -c --arg u "$SR_SQUAD_UUID" \
                '[.response.internalSquads[]? | select(.uuid == $u) | .inbounds[]? | if type == "string" then . else (.uuid // empty) end] | unique')
            if [ "$have" != "[$want]" ]; then
                sr_api "PATCH" "/api/internal-squads" \
                    "$(jq -nc --arg u "$SR_SQUAD_UUID" --argjson inb "[$want]" '{uuid: $u, inbounds: $inb}')" >/dev/null 2>&1
            fi
            step_ok "${LANG[SR_SQUAD_REUSED]}"
            return 0
        fi
    fi

    name="${SR_SQUAD_NAME:-SR Bridge $(sr_rand 4)}"
    # Squad names are unique panel-wide; a name derived from the bridge slug
    # can collide with a leftover squad (e.g. a bridge whose exit machine was
    # switched — state renamed, panel squad not). Pre-check the existing
    # names, and on the panel's A120 "already exists" retry with a suffix:
    # the pre-check GET can come back empty on a flaky network moment and
    # miss the collision (seen live on a lossy VPS link).
    local squad_names attempt
    squad_names=$(sr_api "GET" "/api/internal-squads" 2>/dev/null | jq -r '.response.internalSquads[]?.name // empty' 2>/dev/null)
    while echo "$squad_names" | grep -qxF "$name"; do
        name="${SR_SQUAD_NAME:-SR Bridge} $(sr_rand 4)"
    done
    step_do "${LANG[SR_CREATE_SQUAD]}"
    for attempt in 1 2 3; do
        response=$(sr_api "POST" "/api/internal-squads" \
            "$(jq -nc --arg name "$name" --argjson inbounds "[\"$inbound_uuid\"]" '{name: $name, inbounds: $inbounds}')")
        SR_SQUAD_UUID=$(echo "$response" | jq -r '.response.uuid // empty')
        [ -n "$SR_SQUAD_UUID" ] && break
        echo "$response" | grep -q "already exists" || break
        name="$name $(sr_rand 4)"
    done
    SR_SQUAD_UUID=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -z "$SR_SQUAD_UUID" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    sr_state_set squad_uuid "$SR_SQUAD_UUID"
    step_ok "${LANG[SR_CREATE_SQUAD_OK]}"
}

sr_ensure_user() {
    local squad_uuid="$1" username response
    SR_USER_ID=$(sr_state_get user_id)
    SR_USER_NAME=$(sr_state_get user_name)
    SR_SS_PASSWORD=$(sr_state_get ss_password)
    if [ -n "$SR_USER_ID" ] && [ -n "$SR_SS_PASSWORD" ] && [ -n "$SR_USER_NAME" ]; then
        # Still alive? A user deleted by hand must not keep feeding a dead
        # password into the public profile.
        response=$(sr_api "GET" "/api/users/by-username/$SR_USER_NAME")
        if echo "$response" | jq -e --arg n "$SR_USER_NAME" '.response.username? == $n' >/dev/null 2>&1; then
            # Liveness alone is not enough: an ssPassword changed by hand in
            # the panel would silently kill the tunnel — the profile keeps
            # baking the STATE password into its outbound. The panel is the
            # truth here (every setup flow writes both sides at once), so
            # adopt the live password into the state; the profile patch that
            # always follows re-bakes it and the tunnel heals.
            local live_pass
            live_pass=$(echo "$response" | jq -r '.response.ssPassword // empty')
            if [ -n "$live_pass" ] && [ "$live_pass" != "$SR_SS_PASSWORD" ]; then
                SR_SS_PASSWORD="$live_pass"
                sr_state_set ss_password "$live_pass"
            fi
            step_ok "${LANG[SR_USER_REUSED]}"
            return 0
        fi
    fi

    username="${SR_USER_WANTED:-srbridge$(sr_rand 6)}"
    # A wanted name already taken by some other account gets a suffix instead
    # of a create failure.
    response=$(sr_api "GET" "/api/users/by-username/$username")
    if echo "$response" | jq -e '.response.username' >/dev/null 2>&1; then
        username="${username}-$(sr_rand 4)"
    fi
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
    # The user object carries a numeric id and shortUuid — no plain uuid
    # field — and the numeric id is what DELETE /api/users/{id} needs.
    SR_USER_ID=$(echo "$response" | jq -r '.response.id // empty')
    if [ -z "$SR_USER_ID" ] || [ "$SR_USER_ID" = "null" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
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
    # "Ours" are matched STRUCTURALLY (exact rule shapes this module writes,
    # whatever outbound they point at): a mode flip must strip the previous
    # mode's geoip:ru/category-ru rules too — with a tag-only strip the old
    # DIRECT rules survived and the dedupe skipped adding the new ones, so
    # the direction never actually flipped.
    merged=$(echo "$SR_PROFILE_CONFIG" | jq -c \
        --arg ob "$SR_OUTBOUND_TAG" --arg host "$host" --argjson port "$port" \
        --arg pass "$password" --arg method "$SR_SS_METHOD" --argjson tags "$SR_PROFILE_TAGS" \
        --arg mode "$mode" --arg ext "$SR_RUEX_RULE" '
        def sr_ours:
            ((.ip // []) == ["geoip:ru"]) or
            ((.domain // []) == ["geosite:category-ru"]) or
            ((.domain // []) == [$ext]);
        . as $cfg
        | ((($cfg.outbounds // []) | map(select(.tag != $ob))) +
           [{ tag: $ob, protocol: "shadowsocks",
              settings: { servers: [{ address: $host, port: $port, method: $method, password: $pass, level: 0 }] } }]) as $newobs
        | (($cfg.routing.rules // []) | map(select((.outboundTag // "") != $ob and (sr_ours | not)))) as $keep
        | ($keep
            + (if ($keep | any((.ip // []) | index("geoip:private"))) then [] else [{ ip: ["geoip:private"], outboundTag: "BLOCK" }] end)
            + (if ($keep | any((.domain // []) | index("geosite:private"))) then [] else [{ domain: ["geosite:private"], outboundTag: "BLOCK" }] end)
            + (if ($keep | any((.protocol // []) | index("bittorrent"))) then [] else [{ protocol: ["bittorrent"], outboundTag: "BLOCK" }] end)
            + [{ ip: ["geoip:ru"], outboundTag: (if $mode == "bridge" then $ob else "DIRECT" end) }]
            + [{ domain: ["geosite:category-ru"], outboundTag: (if $mode == "bridge" then $ob else "DIRECT" end) }]
            + (if $mode == "bridge" then [] else [{ inboundTag: $tags, outboundTag: $ob }] end)) as $rules
        | $cfg + { outbounds: $newobs, routing: (($cfg.routing // {}) + { rules: $rules }) }')
    # Pre-existing RU rules sit earlier in the list and shadow ours in bridge
    # mode — the operator should know instead of wondering why RU leaks.
    # Our own rules from a previous patch don't count.
    if [ "$mode" = "bridge" ] \
        && echo "$SR_PROFILE_CONFIG" | jq -e --arg ob "$SR_OUTBOUND_TAG" --arg ext "$SR_RUEX_RULE" \
            'any((.routing.rules // [])[]; (((.ip // []) == ["geoip:ru"]) or ((.domain // []) == ["geosite:category-ru"])) and ((.outboundTag // "") != $ob))' >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}${LANG[SR_BRIDGE_MODE_SHADOW]}${COLOR_RESET}"
    fi
    sr_patch_profile_config "$profile_uuid" "$merged" || return 1
    step_ok "$(printf "${LANG[SR_PATCH_PROFILE_OK]}" "$SR_PROFILE_NAME")"
}

# Strip our outbound and rules from one public profile (teardown path).
# Structural match for the rules (see sr_patch_public_profile): whatever
# outbound the geo/ext rules point at — a mode flip or teardown must leave
# nothing of ours behind.
sr_unpatch_public_profile() {
    local profile_uuid="$1" merged
    sr_get_profile "$profile_uuid" || return 1
    step_do "$(printf "${LANG[SR_UNPATCH_PROFILE]}" "$SR_PROFILE_NAME")"
    merged=$(echo "$SR_PROFILE_CONFIG" | jq -c --arg ob "$SR_OUTBOUND_TAG" --arg ext "$SR_RUEX_RULE" '
        def sr_ours:
            ((.ip // []) == ["geoip:ru"]) or
            ((.domain // []) == ["geosite:category-ru"]) or
            ((.domain // []) == [$ext]);
        . as $cfg
        | (($cfg.outbounds // []) | map(select(.tag != $ob))) as $obs
        | (($cfg.routing.rules // []) | map(select((.outboundTag // "") != $ob and (sr_ours | not)))) as $rules
        | $cfg + { outbounds: $obs, routing: (($cfg.routing // {}) + { rules: $rules }) }')
    sr_patch_profile_config "$profile_uuid" "$merged" || return 1
    step_ok "$(printf "${LANG[SR_UNPATCH_PROFILE_OK]}" "$SR_PROFILE_NAME")"
}

# --- remote side ---------------------------------------------------------------

sr_panel_public_ip() {
    get_public_ipv4
}

# Public IPv4 or nothing. The CGNAT range is excluded on purpose: a NetBird
# overlay address (100.64.0.0/10) must never become a ufw source — the real
# traffic arrives from the node's public IP and the rule would be dead while
# looking applied.
sr_public_ipv4() {
    local addr="$1"
    echo "$addr" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | grep -vE '^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.|169\.254\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.)'
}

# Raw addresses of the nodes a profile is active on, no filtering. A
# single-box panel+node install carries a docker-gateway placeholder like
# 172.30.0.1 here — private on purpose, and valid for the panel on the same
# host, so entry-node collection must NOT drop it.
sr_profile_node_addresses_raw() {
    local profile_uuid="$1"
    sr_fetch_nodes >/dev/null 2>&1 || return 0
    echo "$SR_NODES_JSON" | jq -r --arg p "$profile_uuid" \
        '.[] | select(.configProfile.activeConfigProfileUuid == $p) | .address' 2>/dev/null | awk 'NF'
}

# Public-IPv4-only variant: DE-side ufw sources (private junk is useless
# there; domains resolve to their public IPv4).
sr_profile_node_addresses() {
    local profile_uuid="$1" addr resolved
    for addr in $(sr_profile_node_addresses_raw "$profile_uuid"); do
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
# SECRET_KEY must be the JSON document from GET /api/keygen (.response
# .secretKey) — remnanode parses it as JSON and crash-loops ("SECRET_KEY
# contains invalid JSON") on anything else, a bare base64 key included.
# The value is single-quoted: a plain YAML scalar starting with '{' would
# parse as a flow mapping.
sr_remote_compose() {
    local link_secret="$1"
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
      - 'SECRET_KEY=$link_secret'
    volumes:
      - /dev/shm:/dev/shm:rw
      - /var/log/remnanode:/var/log/remnanode
EOL
}

# Deploy the node container on the DE box over SSH: docker bootstrap, compose,
# up, firewall, wait for the panel to report it connected. Panel-side objects
# (bridge profile, node record) must already exist.
sr_remote_deploy_node() {
    local host="$1" ss_port="$2" link_secret="$3" panel_ip attempt

    step_do "${LANG[SR_REMOTE_DOCKER]}" >&2
    if ! re_run_host_n "$host" "$(re_remote_docker_install)" >&2; then
        err_msg "${LANG[SR_REMOTE_DOCKER_FAIL]}"
        return 1
    fi

    step_do "${LANG[SR_REMOTE_COMPOSE]}" >&2
    if ! printf '%s\n' "$(sr_remote_compose "$link_secret")" \
        | re_run_host "$host" "mkdir -p /opt/remnanode && cat > /opt/remnanode/docker-compose.yml" >&2; then
        err_msg "${LANG[SR_REMOTE_COMPOSE_FAIL]}"
        return 1
    fi

    step_do "${LANG[SR_REMOTE_UP]}" >&2
    # get.docker.com ships the compose plugin; a distro docker.io may not —
    # docker-compose (v1) is the last resort for the up itself.
    if ! re_run_host_n "$host" 'cd /opt/remnanode && { docker compose up -d || docker-compose up -d; }' >&2; then
        err_msg "${LANG[SR_REMOTE_UP_FAIL]}"
        return 1
    fi

    panel_ip=$(sr_panel_public_ip)
    if [ -n "$panel_ip" ]; then
        # One rule per call, rc each: a `;`-glued chain reports only the last
        # command. The SS port rule carries no proto clause on purpose — the
        # tunnel runs UDP DNS on the same port.
        if ! re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow from $panel_ip to any port 2222 proto tcp")" >/dev/null 2>&1 \
           || ! re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow from $panel_ip to any port $ss_port")" >/dev/null 2>&1; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_UFW_OPEN_FAIL]}" "$ss_port")${COLOR_RESET}" >&2
        fi
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

# A remnanode container runs on the box but the panel has no node record —
# the teardown note told the operator the node and profile may be deleted,
# and coming back must be one question, not manual docker surgery. The
# panel accepts any link key it has ever issued, so the running container
# can be re-registered as-is: read the secret from its environment, create
# a fresh bridge profile, register the node, let the panel dial in.
# Sets the same globals as sr_remote_install_node.
sr_remote_adopt_node() {
    local host="$1" ss_port="$2"
    local response secret node_uuid node_name profile_uuid panel_ip

    step_do "$(printf "${LANG[SR_ADOPT_STEP]}" "$host")" >&2
    # Three ways to the link secret: container env via printenv, the same
    # via env (images without printenv), the compose file. The key is
    # base64(JSON) on live panels ({"nodeCertPerm": ...}) — seen on the
    # user's Moscow box; a bare JSON is accepted too, anything else is not
    # our key.
    secret=$(re_run_host_n "$host" "docker exec remnanode printenv SECRET_KEY 2>/dev/null")
    [ -n "$secret" ] || secret=$(re_run_host_n "$host" "docker exec remnanode env 2>/dev/null | sed -n 's/^SECRET_KEY=//p'")
    [ -n "$secret" ] || secret=$(re_run_host_n "$host" \
        "sed -n \"s/^[[:space:]]*- 'SECRET_KEY=//p\" /opt/remnanode/docker-compose.yml 2>/dev/null | sed \"s/'\$//\"")
    if [ -z "$secret" ]; then
        err_msg "$(printf "${LANG[SR_ADOPT_BAD_KEY]}" "$host" "${LANG[SR_ADOPT_EMPTY]}")"
        return 1
    fi
    if ! echo "$secret" | jq -e . >/dev/null 2>&1 \
       && ! echo "$secret" | base64 -d 2>/dev/null | jq -e . >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_ADOPT_BAD_KEY]}" "$host" "$(printf "${LANG[SR_ADOPT_NOT_JSON]}" "${secret:0:80}")")"
        return 1
    fi
    step_ok "${LANG[SR_ADOPT_KEY_OK]}" >&2

    sr_create_bridge_profile "$ss_port" || return 1
    profile_uuid="$SR_PROFILE_UUID"

    node_name="${SR_NODE_NAME:-SR-Bridge-$(sr_rand 4)}"
    step_do "${LANG[SR_CREATE_NODE]}" >&2
    response=$(sr_api "POST" "/api/nodes" "$(jq -nc \
        --arg name "$node_name" --arg addr "$host" --arg pu "$profile_uuid" --argjson inb "[\"$SR_INBOUND_UUID\"]" '{
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

    # The container is already up; only the firewall may need a reminder.
    panel_ip=$(sr_panel_public_ip)
    if [ -n "$panel_ip" ]; then
        # One rule per call with its own rc — see sr_remote_deploy_node.
        if ! re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow from $panel_ip to any port 2222 proto tcp")" >/dev/null 2>&1 \
           || ! re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow from $panel_ip to any port $ss_port")" >/dev/null 2>&1; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_UFW_OPEN_FAIL]}" "$ss_port")${COLOR_RESET}" >&2
        fi
    fi

    for attempt in 1 2 3 4 5 6; do
        sleep 10
        step_do "$(printf "${LANG[SR_WAIT_CONNECT]}" "$attempt")" >&2
        if sr_node_connected "$host"; then
            step_ok "${LANG[SR_WAIT_CONNECT_OK]}" >&2
            # SR_INBOUND_UUID / SR_INBOUND_TAG stay as sr_create_bridge_profile
            # left them.
            SR_NODE_UUID="$node_uuid"
            SR_PROFILE_UUID="$profile_uuid"
            return 0
        fi
    done
    echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_WAIT_CONNECT_FAIL]}" "$host")${COLOR_RESET}" >&2
    return 0
}

# Register the node in the panel and deploy it on the DE box.
# Sets SR_NODE_UUID / SR_PROFILE_UUID / SR_INBOUND_UUID / SR_INBOUND_TAG.
sr_remote_install_node() {
    local host="$1" ss_port="$2" response link_secret
    local profile_uuid inbound_uuid inbound_tag node_uuid node_name

    # A bridge node carries no user secrets of its own; refuse to trample a
    # box that already runs one — that box belongs to a flow we don't own.
    # The one flow we DO own is a container without a node record (the
    # teardown note says the node may be deleted): offer to re-attach it or
    # to stop and reinstall instead of a hard dead end.
    if re_run_host_n "$host" "docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode"; then
        if reading_yn "${LANG[SR_ADOPT_ASK]}" confirm_adopt; then
            sr_remote_adopt_node "$host" "$ss_port" || return 1
            return 0
        fi
        if reading_yn "$(printf "${LANG[SR_ADOPT_REINSTALL_ASK]}" "$host")" confirm_reinstall; then
            re_run_host_n "$host" "cd /opt/remnanode && { docker compose down || docker-compose down; }" >/dev/null 2>&1
        else
            err_msg "${LANG[SR_REMOTE_NODE_EXISTS]}"
            return 1
        fi
    fi

    # A fresh key from the panel — the node link secret is a JSON document
    # (parsed by remnanode itself), fetched from /api/keygen exactly like
    # get_public_key does for local installs.
    step_do "${LANG[SR_REMOTE_KEYGEN]}" >&2
    response=$(sr_api "GET" "/api/keygen")
    link_secret=$(echo "$response" | jq -r '.response.secretKey // empty')
    if [ -z "$link_secret" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    step_ok "${LANG[SR_REMOTE_KEYGEN_OK]}" >&2

    sr_create_bridge_profile "$ss_port" || return 1
    profile_uuid="$SR_PROFILE_UUID"
    inbound_uuid="$SR_INBOUND_UUID"
    inbound_tag="$SR_INBOUND_TAG"

    node_name="${SR_NODE_NAME:-SR-Bridge-$(sr_rand 4)}"
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

    sr_remote_deploy_node "$host" "$ss_port" "$link_secret" || return 1

    SR_NODE_UUID="$node_uuid"
    SR_PROFILE_UUID="$profile_uuid"
    SR_INBOUND_UUID="$inbound_uuid"
    SR_INBOUND_TAG="$inbound_tag"
    return 0
}

# ufw on the DE box: the SS port for every RU egress address we know of.
# Rules go out one per ssh call with the rc watched per rule — a `;`-glued
# chain reports only the last command's exit code and a failed middle rule
# reads as success.
sr_remote_open_bridge_port() {
    local host="$1" port="$2"
    shift 2
    local sources=("$@") src rule_rc
    local applied=0 failed=0 missing_ufw=0
    step_do "$(printf "${LANG[SR_UFW_OPEN]}" "$host")"
    [ "${#sources[@]}" -gt 0 ] || return 0
    # An inactive ufw still takes the rule (it fires the day ufw gets
    # enabled) — but the report must be honest about the port being open
    # to everyone right now.
    ufw_state=$(re_run_host_n "$host" "ufw status 2>/dev/null | head -n1" 2>/dev/null)
    for src in "${sources[@]}"; do
        [ -n "$src" ] || continue
        rule_rc=0
        re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow from $src to any port $port")" >/dev/null 2>&1 || rule_rc=$?
        case "$rule_rc" in
            0)   applied=$((applied + 1)) ;;
            127) missing_ufw=1 ;;
            *)   failed=$((failed + 1)) ;;
        esac
    done
    if [ "$missing_ufw" = 1 ]; then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_UFW_NO_UFW]}" "$host" "$port")${COLOR_RESET}"
        return 0
    fi
    if [ "$applied" -gt 0 ]; then
        case "$ufw_state" in
            *inactive*)
                echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_UFW_INACTIVE]}" "$host")${COLOR_RESET}"
                sr_ufw_offer_enable "$host" "$port"
                ;;
            *)
                step_ok "${LANG[SR_UFW_OPEN_OK]}"
                ;;
        esac
    fi
    [ "$failed" -gt 0 ] && echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_UFW_OPEN_FAIL]}" "$port")${COLOR_RESET}"
    return 0
}

# An inactive ufw enforces nothing — the machine is open to the world.
# Everything already listening externally keeps working the same way after
# the enable ONLY if it stays allowed, so every current listener gets its
# own allow rule automatically (a port that listened was public anyway),
# ufw turns on without questions, and everything not yet listening stays
# closed. The bridge port and 2222 stay SOURCE-restricted (the rules added
# above) — they are not re-opened to the world. No listener list at all
# (ss failed) means we cannot enumerate what to keep — a question instead
# of a blind enable.
sr_ufw_offer_enable() {
    local host="$1" port="$2" ssh_port raw list cmd=""
    re_target_load_by_host "$host" >/dev/null 2>&1
    ssh_port="${RE_PORT:-22}"
    raw=$(re_run_host_n "$host" "ss -tulnp 2>/dev/null")
    list=""
    if [ -n "$raw" ]; then
        # ss -tulnp prints a Netid column: local addr = $5, process = $7.
        list=$(echo "$raw" | awk 'NR>1 {
            split($5, a, ":"); port=a[length(a)];
            if ($5 ~ /127\.0\.0\.1|\[::1\]/) next;
            proc=$7; sub(/^users:\(\("/, "", proc); sub(/".*$/, "", proc);
            printf "  %s/%s  %s\n", port, $1, proc
        }' | sort -n -u)
    fi

    if [ -n "$list" ]; then
        echo -e " ${COLOR_GRAY}${LANG[SR_UFW_AUTO_KEEP]}${COLOR_RESET}"
        echo "$list"
        # The operator's way back lands FIRST and is verified before enable
        # runs: in a `;`-glued chain a failed ssh-port allow was invisible
        # and enable still fired — a lockout reported as success.
        if ! re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow $ssh_port/tcp")" >/dev/null 2>&1; then
            echo -e "${COLOR_RED}${LANG[SR_UFW_ENABLE_FAIL]}${COLOR_RESET}"
            return 1
        fi
        local pp
        while read -r pp _; do
            [ -n "$pp" ] || continue
            case " ${pp%%/*} " in
                " $ssh_port "|" 2222 "|" $port ") continue ;;
            esac
            re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow $pp")" >/dev/null 2>&1
        done <<< "$list"
        if re_run_host_n "$host" "$(re_remote_ufw_cmd required "echo y | ufw enable >/dev/null 2>&1; ufw status | head -n1")" 2>/dev/null | grep -q active; then
            if re_run_host_n "$host" "echo ok" >/dev/null 2>&1; then
                step_ok "${LANG[SR_UFW_ENABLE_OK]}"
            else
                echo -e "${COLOR_RED}${LANG[SR_UFW_ENABLE_LOCKOUT]}${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_RED}${LANG[SR_UFW_ENABLE_FAIL]}${COLOR_RESET}"
        fi
        return 0
    fi

    # ss gave nothing to work with — never enable blind.
    reading_yn "$(printf "${LANG[SR_UFW_ENABLE_ASK]}" "$host" "$ssh_port" "$port")" confirm_ufw_enable || return 0
    if ! re_run_host_n "$host" "$(re_remote_ufw_cmd required "ufw allow $ssh_port/tcp")" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[SR_UFW_ENABLE_FAIL]}${COLOR_RESET}"
        return 1
    fi
    if ! re_run_host_n "$host" "$(re_remote_ufw_cmd required "echo y | ufw enable >/dev/null 2>&1; ufw status | head -n1")" 2>/dev/null | grep -q active; then
        echo -e "${COLOR_RED}${LANG[SR_UFW_ENABLE_FAIL]}${COLOR_RESET}"
        return 1
    fi
    if re_run_host_n "$host" "echo ok" >/dev/null 2>&1; then
        step_ok "${LANG[SR_UFW_ENABLE_OK]}"
    else
        echo -e "${COLOR_RED}${LANG[SR_UFW_ENABLE_LOCKOUT]}${COLOR_RESET}"
    fi
    return 0
}

sr_remote_close_bridge_port() {
    local host="$1" port="$2"
    shift 2
    local sources=("$@") src
    for src in "${sources[@]}"; do
        [ -n "$src" ] || continue
        re_run_host_n "$host" "$(re_remote_ufw_cmd optional "ufw delete allow from $src to any port $port")" >/dev/null 2>&1
    done
    return 0
}

# TCP reachability of the bridge port from this box.
sr_port_reachable() {
    local host="$1" port="$2"
    timeout 5 bash -c "</dev/tcp/$host/$port" >/dev/null 2>&1
}

# --- naming --------------------------------------------------------------------

# Latin/dash slug from any input (SSH labels may carry spaces or Cyrillic).
sr_name_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' \
        | sed -e 's/^-*//' -e 's/-*$//' | cut -c1-24
}

sr_cap_first() {
    printf '%s%s' "$(printf '%s' "${1:0:1}" | tr '[:lower:]' '[:upper:]')" "${1:1}"
}

# One name for the whole bridge; squad/user/node/profile derive from it.
# Default: the SSH target's label (Moscow), falling back to the address.
# For a brand-new bridge this is also where its state file is born — the
# internal slug stays stable even if the display name is renamed later.
sr_pick_bridge_name() {
    local default_slug input fslug n=0
    default_slug=$(sr_name_slug "${SR_HOST_LABEL:-$SR_HOST}")
    [ -n "$default_slug" ] || default_slug="bridge"
    reading "$(printf "${LANG[SR_NAME_PROMPT]}" "$(sr_cap_first "$default_slug")")" input
    SR_BRIDGE_SLUG=$(sr_name_slug "${input:-$default_slug}")
    [ -n "$SR_BRIDGE_SLUG" ] || SR_BRIDGE_SLUG="bridge"
    SR_SQUAD_NAME="$(sr_cap_first "$SR_BRIDGE_SLUG") bridge"
    SR_USER_WANTED="bridge-${SR_BRIDGE_SLUG}"
    SR_NODE_NAME="$(sr_cap_first "$SR_BRIDGE_SLUG")-bridge"
    if [ -z "$SR_CURRENT" ]; then
        fslug="$SR_BRIDGE_SLUG"
        while [ -e "${SR_CONF_DIR}/${fslug}.bridge" ]; do
            n=$((n + 1))
            fslug="${SR_BRIDGE_SLUG}-${n}"
        done
        SR_CURRENT="$fslug"
    fi
    sr_state_set bridge_name "$SR_BRIDGE_SLUG"
}

# --- setup flow ----------------------------------------------------------------

sr_pick_bridge_host() {
    local names=() name pick i label
    SR_HOST_LABEL=""
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
        SR_HOST_LABEL="$RE_LABEL"
        return 0
    fi
    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
    sleep 1
    sr_pick_bridge_host
}

# Which public profile gets the outbound; sets SR_PICKED_PROFILE (rc=1 — the
# picker was cancelled). The bridge's own profile is never offered: routing a
# box through itself is not a thing. The optional second arg is a
# space-separated list of already-attached profiles, shown with a marker.
# The third arg ("warn-only") keeps foreign-owner markers but drops the
# repoint question — route bridges stack on one profile by design.
sr_pick_public_profile() {
    local skip_uuid="$1" attached="${2:-}" warn_only="${3:-}" response entries=() entry uuid name count pick i rest mark
    response=$(sr_api "GET" "/api/config-profiles")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.configProfiles' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    while IFS= read -r entry; do
        entries+=("$entry")
    done < <(echo "$response" | jq -r --arg skip "$skip_uuid" \
        '.response.configProfiles[]
        | select((.uuid // "") != $skip)
        | select((([.inbounds[]?.tag // ""] | map(select(startswith("SR_BRIDGE_SS_IN_") | not)) | length) > 0) or ((.inbounds | length) == 0))
        | "\(.uuid)\t\(.name)\t\(.inbounds | length)"')

    if [ "${#entries[@]}" -eq 0 ]; then
        err_msg "${LANG[SR_NO_PROFILES]}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_PICK_PROFILE_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_PICK_PROFILE_HINT]}${COLOR_RESET}"
    echo -e ""
    i=1
    local owner
    for entry in "${entries[@]}"; do
        uuid="${entry%%$'\t'*}"
        rest="${entry#*$'\t'}"
        name="${rest%%$'\t'*}"
        count="${rest##*$'\t'}"
        mark=""
        case " $attached " in
            *" $uuid "*) mark=" ${COLOR_GREEN}${LANG[SR_ATTACHED_MARK]}${COLOR_RESET}" ;;
            *)
                owner=""
                for pair in $SR_ATTACHED_MAP; do
                    case "$pair" in
                        "$uuid="*) owner="${pair#*=}" ;;
                    esac
                done
                [ -n "$owner" ] && mark=" ${COLOR_YELLOW}→ ${LANG[SR_ATTACHED_OTHER]} ${owner}${COLOR_RESET}"
                ;;
        esac
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${name}${COLOR_RESET}${mark} ${COLOR_GRAY}(${count} ${LANG[SR_INBOUNDS_WORD]})${COLOR_RESET}"
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
        SR_PICKED_PROFILE_NAME=$(echo "${entries[$((pick - 1))]}" | cut -f2)
        # A profile already routed by another bridge gets repointed — the
        # operator confirms, the other bridge drops its claim. In warn-only
        # mode (route bridges stacking on one profile) the marker above is
        # pure information, no question.
        owner=""
        for pair in $SR_ATTACHED_MAP; do
            case "$pair" in
                "$SR_PICKED_PROFILE="*) owner="${pair#*=}" ;;
            esac
        done
        if [ -n "$owner" ] && [ "$owner" != "${SR_CURRENT:-}" ] && [ -z "$warn_only" ]; then
            if ! reading_yn "$(printf "${LANG[SR_REPOINT_CONFIRM]}" "$SR_PICKED_PROFILE_NAME" "$owner")" confirm_repoint; then
                return 1
            fi
            SR_REPOINTED_FROM="$owner"
        else
            SR_REPOINTED_FROM=""
        fi
        return 0
    fi
    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$((i - 1))"
    sleep 1
    sr_pick_public_profile "$skip_uuid" "$attached" "$warn_only"
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

# Bridge inbound on the exit machine: reuse the SR profile a half-finished
# run left on an existing node record, append the SS inbound to a
# user-facing node (asked), or switch/install. Shared by both bridge types.
# Sets SR_EXIT_PROFILE_UUID / SR_EXIT_INBOUND_UUID / SR_EXIT_INBOUND_TAG /
# SR_EXIT_NODE_UUID / SR_EXIT_PROFILE_CREATED / SR_EXIT_NODE_INSTALLED.
sr_provision_exit() {
    local host="$1" ss_port="$2"
    local profile_uuid inbound_uuid inbound_tag node_uuid
    local profile_created=no node_installed=no has_vless=no ib mode_choice

    if sr_find_node_by_host "$host"; then
        node_uuid="$SR_NODE_UUID"

        # A previous run may have died after creating the node record but
        # before finishing the remote install — it left an SR-Bridge profile
        # active on the node. Reuse it instead of stacking a second one.
        # uuids come from the panel inbound metadata, never from the Xray
        # config (which has no uuids at all).
        local reuse_uuid="" reuse_tag
        if [ -n "$SR_NODE_PROFILE" ] && sr_get_profile "$SR_NODE_PROFILE" >/dev/null 2>&1; then
            reuse_uuid=$(echo "$SR_PROFILE_INBOUNDS" | jq -r '.[] | select((.tag // "") | startswith("SR_BRIDGE_SS_IN_")) | .uuid' | head -n1)
            reuse_tag=$(echo "$SR_PROFILE_INBOUNDS" | jq -r '.[] | select((.tag // "") | startswith("SR_BRIDGE_SS_IN_")) | .tag' | head -n1)
        fi

        # A node whose profile cannot be read (deleted in the panel during
        # a cleanup) used to fall through to the silent switch below —
        # switching a node's assignment deserves a question, not a surprise.
        if [ -n "$SR_NODE_PROFILE" ] && ! sr_get_profile "$SR_NODE_PROFILE" >/dev/null 2>&1; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_NODE_DEAD_PROFILE]}" "$host")${COLOR_RESET}"
            if ! reading_yn "${LANG[SR_NODE_DEAD_PROFILE_ASK]}" confirm_switch_dead; then
                echo -e "${COLOR_YELLOW}${LANG[SR_INSTALL_NODE_DECLINED]}${COLOR_RESET}"
                return 1
            fi
        fi

        if [[ "$reuse_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && [ -n "$reuse_tag" ]; then
            # Keep the inbound port in step with what was just asked (a retry
            # with a different port must not silently keep the old one).
            local cur_port fixed_cfg
            cur_port=$(echo "$SR_PROFILE_INBOUNDS" | jq -r --arg t "$reuse_tag" '.[] | select(.tag == $t) | .port')
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
            if ! re_run_host_n "$host" "docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode"; then
                local response link_secret
                step_do "${LANG[SR_REMOTE_KEYGEN]}" >&2
                response=$(sr_api "GET" "/api/keygen")
                link_secret=$(echo "$response" | jq -r '.response.secretKey // empty')
                if [ -z "$link_secret" ]; then
                    err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
                    return 1
                fi
                step_ok "${LANG[SR_REMOTE_KEYGEN_OK]}" >&2
                sr_remote_deploy_node "$host" "$ss_port" "$link_secret" || return 1
                node_installed=yes
            fi
        else
            has_vless=no
            if [ -n "$SR_NODE_PROFILE" ] && sr_get_profile "$SR_NODE_PROFILE" >/dev/null 2>&1; then
                # Config inbounds carry NO uuids (tags only) — the old check
                # read .uuid straight from the config, always found nothing
                # and silently switched USER-FACING nodes to an SS-only
                # profile (seen live on Moscow). Join protocols with the
                # node's active inbound uuids by TAG, via the metadata array.
                for ib in $(echo "$SR_PROFILE_INBOUNDS" | jq -r --argjson cfg "$SR_PROFILE_CONFIG" '
                    [$cfg.inbounds[]? | select(.protocol == "vless" or .protocol == "trojan") | .tag] as $user
                    | .[] | . as $i | select(($user | index(($i.tag // ""))) != null) | .uuid' 2>/dev/null); do
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
                # The freshly appended inbound must also become ACTIVE on
                # the node — the panel pushes only the inbounds listed in
                # the node record (seen live: SS sat in the profile,
                # port silent). Re-assert the node with the full set.
                if sr_get_profile "$profile_uuid" >/dev/null 2>&1; then
                    step_do "${LANG[SR_NODE_ACTIVATE]}" >&2
                    if sr_set_node_profile "$node_uuid" "$profile_uuid" \
                        $(echo "$SR_PROFILE_INBOUNDS" | jq -r '.[].uuid'); then
                        step_ok "${LANG[SR_NODE_ACTIVATE_OK]}" >&2
                    else
                        echo -e "${COLOR_YELLOW}${LANG[SR_NODE_ACTIVATE_FAIL]}${COLOR_RESET}" >&2
                    fi
                fi
            else
                # The last line of defence after two live incidents: a switch
                # closes whatever inbounds the node serves right now, so it
                # asks even when the user-inbound detection saw none.
                if ! reading_yn "$(printf "${LANG[SR_SWITCH_CONFIRM]}" "$host")" confirm_switch; then
                    echo -e "${COLOR_YELLOW}${LANG[SR_INSTALL_NODE_DECLINED]}${COLOR_RESET}"
                    return 1
                fi
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

    SR_EXIT_PROFILE_UUID="$profile_uuid"
    SR_EXIT_INBOUND_UUID="$inbound_uuid"
    SR_EXIT_INBOUND_TAG="$inbound_tag"
    SR_EXIT_NODE_UUID="$node_uuid"
    SR_EXIT_PROFILE_CREATED="$profile_created"
    SR_EXIT_NODE_INSTALLED="$node_installed"
    return 0
}

# Full bridge setup. Without args it re-runs in the CURRENT bridge context
# (squad/user/objects reused); "fresh" (from the top-level menu) starts a
# brand-new bridge: the state file is born at the name step.
sr_setup() {
    local host ss_port

    if [ "${1:-}" = "fresh" ]; then
        SR_CURRENT=""
    fi

    load_api_module || return 1
    load_remote_exec_module || return 1
    get_panel_token || { echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"; return 1; }
    sr_migrate_legacy

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_SETUP_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_SETUP_HINT]}${COLOR_RESET}"
    echo -e ""

    sr_pick_bridge_host || { echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"; return 1; }
    host="$SR_HOST"

    reading "$(printf "${LANG[SR_PORT_PROMPT]}" "$SR_DEFAULT_PORT")" ss_port
    [ -n "$ss_port" ] || ss_port=$SR_DEFAULT_PORT

    sr_pick_route_mode
    sr_pick_bridge_name

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
    sr_provision_exit "$host" "$ss_port" || return 1

    sr_state_set type geo
    sr_state_set host "$host"
    sr_state_set port "$ss_port"
    sr_state_set route_mode "$SR_ROUTE_MODE"
    sr_state_set node_uuid "$SR_EXIT_NODE_UUID"
    sr_state_set profile_uuid "$SR_EXIT_PROFILE_UUID"
    sr_state_set profile_created "$SR_EXIT_PROFILE_CREATED"
    sr_state_set node_installed "$SR_EXIT_NODE_INSTALLED"
    sr_state_set inbound_uuid "$SR_EXIT_INBOUND_UUID"
    sr_state_set inbound_tag "$SR_EXIT_INBOUND_TAG"

    # --- squad + service user -------------------------------------------------
    # NB: sr_provision_exit's profile_uuid/inbound_uuid are its locals and die
    # on return — the surviving values are the SR_EXIT_* exports (sr_setup has
    # no locals of these names; passing $inbound_uuid here once fed the squad
    # an empty string and the panel answered "Invalid UUID").
    sr_ensure_squad "$SR_EXIT_INBOUND_UUID" || return 1
    sr_ensure_user "$SR_SQUAD_UUID" || return 1

    # --- public RU profile ----------------------------------------------------
    SR_ATTACHED_MAP=$(sr_attached_map)
    sr_pick_public_profile "$SR_EXIT_PROFILE_UUID" || return 1
    sr_patch_public_profile "$SR_PICKED_PROFILE" "$host" "$ss_port" "$SR_SS_PASSWORD" "$SR_ROUTE_MODE" || return 1
    [ -n "$SR_REPOINTED_FROM" ] && sr_detach_profile_from_others "$SR_PICKED_PROFILE"

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
    # One source per line: a space-joined value reads back as a single
    # "a b c" source and `ufw delete allow from a b c` can never match.
    sr_state_set ufw_sources "$(printf '%s\n' "${sources[@]}")"
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
    echo -e "${COLOR_GRAY}${LANG[SR_DONE_SQUAD_NOTE]}${COLOR_RESET}"

    # Extended RU lists are global; a fresh bridge is a natural moment to
    # offer them. When they are already on, a re-setup just makes sure the
    # (possibly new) profile carries the rule too.
    if sr_ruex_enabled; then
        sr_ruex_switch_rules on
    elif reading_yn "${LANG[SR_RUEX_SETUP_ASK]}" confirm_ruex_setup; then
        sr_ruex_enable
    fi
    return 0
}

# --- teardown -------------------------------------------------------------------

# Fast path: point one more public profile at the ALREADY configured bridge.
# Everything bridge-side comes from state; only the profile is asked for.
sr_attach_profile() {
    local host port mode password profile_uuid ru_list
    load_api_module || return 1
    load_remote_exec_module || return 1
    get_panel_token || { echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"; return 1; }

    host=$(sr_state_get host)
    port=$(sr_state_get port)
    mode=$(sr_state_get route_mode)
    password=$(sr_state_get ss_password)
    profile_uuid=$(sr_state_get profile_uuid)
    if [ -z "$host" ] || [ -z "$port" ] || [ -z "$password" ]; then
        echo -e "${COLOR_RED}${LANG[SR_ATTACH_NOT_READY]}${COLOR_RESET}"
        return 1
    fi

    ru_list=$(sr_state_get ru_profiles)
    SR_ATTACHED_MAP=$(sr_attached_map)
    sr_pick_public_profile "$profile_uuid" "$ru_list" || return 1
    sr_patch_public_profile "$SR_PICKED_PROFILE" "$host" "$port" "$password" "${mode:-direct}" || return 1
    [ -n "$SR_REPOINTED_FROM" ] && sr_detach_profile_from_others "$SR_PICKED_PROFILE"

    # A profile attached while the extended lists are on must carry the rule
    # too, not only the ones patched at enable time.
    sr_ruex_enabled && sr_ruex_switch_rules on

    case " $ru_list " in
        *" $SR_PICKED_PROFILE "*) ;;
        *) sr_state_set ru_profiles "${ru_list:+$ru_list }$SR_PICKED_PROFILE" ;;
    esac

    # New profile may mean new egress nodes — merge their addresses into the
    # stored ufw sources instead of overwriting (teardown closes them all).
    local sources=() addr panel_ip merged
    while IFS= read -r addr; do
        [ -n "$addr" ] && [ "$addr" != "$host" ] && sources+=("$addr")
    done < <(sr_profile_node_addresses "$SR_PICKED_PROFILE")
    panel_ip=$(sr_panel_public_ip)
    [ -n "$panel_ip" ] && sources+=("$panel_ip")
    # Newline-separated, like sr_setup writes it.
    merged=$(sr_state_get ufw_sources)
    for addr in "${sources[@]}"; do
        [ -n "$addr" ] || continue
        printf '%s\n' "$merged" | grep -qxF "$addr" || merged="${merged:+$merged
}$addr"
    done
    sr_state_set ufw_sources "$merged"
    sr_remote_open_bridge_port "$host" "$port" "${sources[@]}"
    return 0
}

# --- rename / teardown ----------------------------------------------------------

# Rename every bridge object in the panel from one name: squad (inbounds must
# be resent with the PATCH), user (by numeric id), node and profile (by uuid).
sr_rename_bridge() {
    local slug input cap response failed=""
    local btype exit_shared old_slug old_cap
    btype=$(sr_bridge_type "$SR_CURRENT")
    exit_shared=$(sr_state_get exit_shared)
    old_slug=$(sr_state_get bridge_name)
    [ -n "$old_slug" ] || old_slug="bridge"
    old_cap=$(sr_cap_first "$old_slug")
    reading "$(printf "${LANG[SR_NAME_PROMPT]}" "$old_cap")" input
    # Enter keeps the CURRENT name — $old_slug, not the unset $slug this line
    # used to reference (empty slug aborted the rename silently).
    slug=$(sr_name_slug "${input:-$old_slug}")
    [ -n "$slug" ] || return 1
    if [ "$slug" = "$old_slug" ]; then
        echo -e "${COLOR_GRAY}${LANG[SR_RENAME_SAME]}${COLOR_RESET}"
        return 0
    fi
    cap=$(sr_cap_first "$slug")

    step_do "${LANG[SR_RENAME_STEP]}"

    local squad_uuid inbounds_json squad_name
    squad_uuid=$(sr_state_get squad_uuid)
    if [ -n "$squad_uuid" ]; then
        response=$(sr_api "GET" "/api/internal-squads")
        inbounds_json=$(echo "$response" | jq -c --arg u "$squad_uuid" \
            '[.response.internalSquads[]? | select(.uuid == $u) | .inbounds[].uuid]')
        # Squad names are panel-unique: on a collision claim a suffixed name
        # instead of failing the rename halfway (same policy as creation).
        squad_name="$cap bridge"
        response=$(sr_api "PATCH" "/api/internal-squads" "$(jq -nc \
            --arg u "$squad_uuid" --arg n "$squad_name" --argjson i "$inbounds_json" \
            '{uuid: $u, name: $n, inbounds: $i}')")
        if ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 \
            && echo "$response" | grep -q "already exists"; then
            squad_name="$squad_name $(sr_rand 4)"
            response=$(sr_api "PATCH" "/api/internal-squads" "$(jq -nc \
                --arg u "$squad_uuid" --arg n "$squad_name" --argjson i "$inbounds_json" \
                '{uuid: $u, name: $n, inbounds: $i}')")
        fi
        echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || failed="${failed:+$failed, }${LANG[SR_WORD_SQUAD]}"
    fi

    # Usernames are immutable in the panel API (username is an identifier,
    # not a renameable field) — the service user is "renamed" by recreating
    # it: create under the new name, repoint the public profiles to the new
    # password, then delete the old one. Both users are valid squad members
    # until the swap, so the bridge never blinks.
    local user_id user_name new_name new_pass new_id host port mode ru p
    user_id=$(sr_state_get user_id)
    user_name=$(sr_state_get user_name)
    if [ -n "$user_id" ] && [ -n "$user_name" ]; then
        new_name="bridge-$slug"
        response=$(sr_api "GET" "/api/users/by-username/$new_name")
        if echo "$response" | jq -e '.response.username' >/dev/null 2>&1; then
            new_name="${new_name}-$(sr_rand 4)"
        fi
        new_pass=$(sr_gen_password)
        response=$(sr_api "POST" "/api/users" "$(jq -nc \
            --arg u "$new_name" --arg pass "$new_pass" --argjson squad "[\"$squad_uuid\"]" '{
                username: $u,
                status: "ACTIVE",
                expireAt: "2099-12-31T23:59:59.000Z",
                trafficLimitBytes: 0,
                activeInternalSquads: $squad,
                ssPassword: $pass,
                description: "server routing bridge service user (remnawave-reverse-proxy)"
            }')")
        new_id=$(echo "$response" | jq -r '.response.id // empty')
        if [ -n "$new_id" ]; then
            host=$(sr_state_get host)
            port=$(sr_state_get port)
            mode=$(sr_state_get route_mode)
            ru=$(sr_state_get ru_profiles)
            swap_ok=yes
            for p in $ru; do
                if [ "$btype" = "route" ]; then
                    sr_patch_profile_route "$p" "$host" "$port" "$new_pass" \
                        "$(sr_state_get route_no)" "$(sr_bridge_outbound_tag "$SR_CURRENT")" || swap_ok=no
                else
                    sr_patch_public_profile "$p" "$host" "$port" "$new_pass" "${mode:-direct}" || swap_ok=no
                fi
            done
            if [ "$swap_ok" = "yes" ]; then
                response=$(sr_api "DELETE" "/api/users/$user_id")
                sr_state_set user_id "$new_id"
                sr_state_set user_name "$new_name"
                sr_state_set ss_password "$new_pass"
            else
                # The old user still feeds the profile config — drop the
                # half-created replacement instead and report the failure.
                sr_api "DELETE" "/api/users/$new_id" >/dev/null 2>&1
                failed="${failed:+$failed, }${LANG[SR_WORD_USER]}"
            fi
        else
            failed="${failed:+$failed, }${LANG[SR_WORD_USER]}"
        fi
    fi

    # The exit node and profile belong to the SOURCE bridge on a shared
    # line — renaming them here would rename them for every bridge on that
    # exit. The live-truth check covers geo bridges too: they carry no
    # birth-time exit_shared marker at all.
    local profile_uuid node_uuid obj_name r_host r_port
    r_host=$(sr_state_get host)
    r_port=$(sr_state_get port)
    if ! sr_exit_shared_now "$r_host" "$r_port"; then
        profile_uuid=$(sr_state_get profile_uuid)
        if [ -n "$profile_uuid" ]; then
            # Profile names are panel-unique too — same suffixed retry.
            obj_name="$cap-bridge"
            response=$(sr_api "PATCH" "/api/config-profiles" "$(jq -nc \
                --arg u "$profile_uuid" --arg n "$obj_name" '{uuid: $u, name: $n}')")
            if ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 \
                && echo "$response" | grep -q "already exists"; then
                response=$(sr_api "PATCH" "/api/config-profiles" "$(jq -nc \
                    --arg u "$profile_uuid" --arg n "$obj_name $(sr_rand 4)" '{uuid: $u, name: $n}')")
            fi
            echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || failed="${failed:+$failed, }${LANG[SR_WORD_PROFILE]}"
        fi

        node_uuid=$(sr_state_get node_uuid)
        if [ -n "$node_uuid" ]; then
            response=$(sr_api "PATCH" "/api/nodes" "$(jq -nc \
                --arg u "$node_uuid" --arg n "$cap-bridge" '{uuid: $u, name: $n}')")
            echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || failed="${failed:+$failed, }${LANG[SR_WORD_NODE]}"
        fi
    fi

    # The subscription host follows the bridge name when it still carries
    # our «base → name» pattern; a custom remark is left untouched.
    if [ "$btype" = "route" ]; then
        local host_uuid h_remark h_base h_rid
        host_uuid=$(sr_state_get host_uuid)
        if [ -n "$host_uuid" ]; then
            step_do "${LANG[SR_RENAME_HOST_STEP]}"
            h_base=$(sr_state_get host_remark_base)
            h_remark=$(sr_state_get host_remark)
            h_rid=$(sr_state_get route_no)
            [ -n "$h_rid" ] || h_rid=2
            if [ "$h_remark" = "$(printf "${LANG[SR_HOST_REMARK_FMT]}" "$h_base" "$old_cap")" ]; then
                h_remark="$(printf "${LANG[SR_HOST_REMARK_FMT]}" "$h_base" "$cap")"
            fi
            sr_host_patch "$host_uuid" "$h_remark" "$h_rid" false \
                || failed="${failed:+$failed, }${LANG[SR_WORD_HOST]}"
            sr_state_set host_remark "$h_remark"
        fi
    fi

    sr_state_set bridge_name "$slug"
    if [ -n "$failed" ]; then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_RENAME_FAIL]}" "$failed")${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[SR_RENAME_OK]}"
}

# Does ANOTHER bridge (any type) still consume this exit host:port? Teardown
# must not close the exit's firewall while a sibling line lives on it: the
# birth-time exit_shared marker goes stale the moment a sibling is added or
# removed, the state files are the live truth. Host spellings drift between
# bridges (domain vs IP for the same box), so non-matching names are
# compared by their resolved IPv4.
sr_exit_shared_now() {
    local host="$1" port="$2" slug f fhost fport fhost_ip
    local host_ip=""
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ "$slug" != "${SR_CURRENT:-}" ] || continue
        f="${SR_CONF_DIR}/${slug}.bridge"
        fhost=$(sed -n 's|^host=||p' "$f" 2>/dev/null | head -n1)
        fport=$(sed -n 's|^port=||p' "$f" 2>/dev/null | head -n1)
        { [ -n "$fhost" ] && [ "$fport" = "$port" ]; } || continue
        [ "$fhost" = "$host" ] && return 0
        [ -z "$host_ip" ] && case "$host" in
            *[!0-9.]*) host_ip=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1) ;;
            *) host_ip="$host" ;;
        esac
        case "$fhost" in
            *[!0-9.]*) fhost_ip=$(dig +short A "$fhost" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1) ;;
            *) fhost_ip="$fhost" ;;
        esac
        [ -n "$host_ip" ] && [ -n "$fhost_ip" ] && [ "$host_ip" = "$fhost_ip" ] && return 0
    done < <(sr_bridges_list)
    return 1
}

sr_teardown() {
    # Route bridges have their own teardown: hosts to delete, a different
    # unpatch shape, and shared-exit objects that must survive.
    if [ "$(sr_bridge_type "$SR_CURRENT")" = "route" ]; then
        sr_teardown_route
        return 0
    fi
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
        if sr_exit_shared_now "$host" "$port"; then
            echo -e "${COLOR_GRAY}${LANG[SR_TEARDOWN_EXIT_SHARED]}${COLOR_RESET}"
        else
            local sources=() src
            # tr normalizes states written by older versions (space-joined
            # single line) into one source per line.
            while read -r src; do
                [ -n "$src" ] && sources+=("$src")
            done <<< "$(sr_state_get ufw_sources | tr ' ' '\n')"
            if [ "${#sources[@]}" -gt 0 ]; then
                step_do "${LANG[SR_TEARDOWN_UFW]}"
                sr_remote_close_bridge_port "$host" "$port" "${sources[@]}" && step_ok "${LANG[SR_TEARDOWN_UFW_OK]}"
            fi
        fi
    fi

    # The bridge node and its profile are left running: they carry no routes
    # once the public profiles are stripped, and an unknown previous state
    # makes switching the node back unsafe.
    echo -e "${COLOR_YELLOW}${LANG[SR_TEARDOWN_KEEP_NOTE]}${COLOR_RESET}"
    sr_state_clear
    step_ok "${LANG[SR_TEARDOWN_DONE]}"
}

# --- per-user bridges (VLESS Route) ----------------------------------------------
#
# The route number lives in the HOST, a native panel object: the
# subscription page bakes vlessRouteId into the last bytes of the user
# UUID, and the entry profile's {vlessRoute: N} rule sends that user
# through this bridge's outbound. The tunnel to the exit machine is the
# same Shadowsocks line as the geo bridges; what differs is the rule set
# written into the profile and the host created on the entry inbound.

# vlessRoute needs Xray 26.3.27+. An older core rejects tail-modified
# UUIDs, so users on route hosts could not connect AT ALL — the gate is
# not cosmetic. rc: 0 ok, 1 too old, 2 unparsable.
sr_xray_version_ok() {
    local v a b c
    v=$(printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+)+' | head -n1)
    [ -n "$v" ] || return 2
    IFS=. read -r a b c <<< "$v"
    a=${a:-0}; b=${b:-0}; c=${c:-0}
    [ "$a" -gt 26 ] && return 0
    [ "$a" -lt 26 ] && return 1
    [ "$b" -gt 3 ] && return 0
    [ "$b" -lt 3 ] && return 1
    [ "$c" -ge 27 ] && return 0
    return 1
}

# Xray version of one entry-node machine: local container first, then an
# SSH-managed remote. Empty output = could not check.
sr_xray_version_on() {
    local addr="$1" resolved compose
    resolved=$(dig +short A "$addr" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
    compose=$(sr_ruex_local_compose)
    if [ -n "$compose" ] && { [ "$addr" = "$(sr_panel_public_ip)" ] || [ "$resolved" = "$(sr_panel_public_ip)" ] \
         || ! sr_public_ipv4 "$addr" >/dev/null; }; then
        docker exec remnanode xray -version 2>/dev/null | head -n1
        return 0
    fi
    if re_target_load_by_host "$addr"; then
        # -n: this runs inside a `while read` over the profile's node list —
        # a data-less ssh without it eats the remaining addresses and every
        # later node went unchecked (B-41).
        re_run_host_n "$addr" "docker exec remnanode xray -version 2>/dev/null | head -n1" 2>/dev/null | head -n1
        return 0
    fi
    return 3
}

# Gate every entry node of the profile: a single old core is fatal,
# unchecked machines only warn (the admin may know better).
sr_route_check_xray() {
    local profile_uuid="$1" addr ver bad="" unknown=""
    step_do "${LANG[SR_XRAY_CHECK]}"
    while IFS= read -r addr; do
        [ -n "$addr" ] || continue
        ver=$(sr_xray_version_on "$addr")
        if [ -z "$ver" ]; then
            unknown="${unknown:+$unknown, }$addr"
        elif ! sr_xray_version_ok "$ver"; then
            bad="${bad:+$bad, }$addr"
            echo -e "${COLOR_RED}$(printf "${LANG[SR_XRAY_OLD]}" "$addr" "$ver")${COLOR_RESET}"
        fi
    done < <(sr_profile_node_addresses_raw "$profile_uuid")
    [ -z "$bad" ] || return 1
    [ -n "$unknown" ] && echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_XRAY_UNKNOWN]}" "$unknown")${COLOR_RESET}"
    step_ok "${LANG[SR_XRAY_OK]}"
    return 0
}

# Route rules for one public profile: our outbound plus {vlessRoute} rules
# placed after the leading block rules and above everything else, so a
# routed user's whole connection follows the route while everyone else
# keeps the profile's existing behaviour. Structural strip makes re-runs
# and number changes clean.
sr_patch_profile_route() {
    local profile_uuid="$1" host="$2" port="$3" password="$4" route_no="$5" ob="$6" merged
    sr_get_profile "$profile_uuid" || return 1
    step_do "$(printf "${LANG[SR_ROUTE_PATCH_STEP]}" "$SR_PROFILE_NAME")"
    merged=$(echo "$SR_PROFILE_CONFIG" | jq -c \
        --arg ob "$ob" --arg host "$host" --argjson port "$port" \
        --arg pass "$password" --arg method "$SR_SS_METHOD" --argjson no "$route_no" '
        def sr_ours:
            has("vlessRoute") and (
                ((.outboundTag // "") == $ob) or
                ((.vlessRoute == 1) and ((.outboundTag // "") == "DIRECT"))
            );
        . as $cfg
        | (($cfg.outbounds // []) | map(select(.tag != $ob))) as $obs
        | (($cfg.routing.rules // []) | map(select(sr_ours | not))) as $rules
        | ($rules | to_entries | map(select((.value.outboundTag // "BLOCK") != "BLOCK")) | .[0].key // ($rules | length)) as $cut
        | ((if ($rules | any((.ip // []) == ["geoip:private"])) then [] else [{ ip: ["geoip:private"], outboundTag: "BLOCK" }] end)
           + (if ($rules | any((.domain // []) == ["geosite:private"])) then [] else [{ domain: ["geosite:private"], outboundTag: "BLOCK" }] end)
           + (if ($rules | any((.protocol // []) | index("bittorrent"))) then [] else [{ protocol: ["bittorrent"], outboundTag: "BLOCK" }] end)) as $blocks
        | $cfg + {
            outbounds: ($obs + [{ tag: $ob, protocol: "shadowsocks",
                settings: { servers: [{ address: $host, port: $port, method: $method, password: $pass, level: 0 }] } }]),
            routing: (($cfg.routing // {}) + { rules:
                ($blocks
                 + $rules[0:$cut]
                 + [{ vlessRoute: 1, outboundTag: "DIRECT" }, { vlessRoute: $no, outboundTag: $ob }]
                 + $rules[$cut:]) })
          }')
    sr_patch_profile_config "$profile_uuid" "$merged" || return 1
    step_ok "${LANG[SR_ROUTE_PATCH_OK]}"
}

# Strip this bridge's route rules and outbound from a profile. The shared
# service route 1 rule goes only when this bridge owns the direct host
# (another route bridge on the same profile may be its owner).
sr_unpatch_profile_route() {
    local profile_uuid="$1" ob="$2" strip_direct="${3:-no}" merged
    sr_get_profile "$profile_uuid" || return 1
    step_do "$(printf "${LANG[SR_UNPATCH_PROFILE]}" "$SR_PROFILE_NAME")"
    merged=$(echo "$SR_PROFILE_CONFIG" | jq -c --arg ob "$ob" --arg sd "$strip_direct" '
        def sr_mine:
            ((.outboundTag // "") == $ob) or
            (if $sd == "yes" then (has("vlessRoute") and .vlessRoute == 1 and ((.outboundTag // "") == "DIRECT")) else false end);
        . as $cfg
        | (($cfg.outbounds // []) | map(select(.tag != $ob))) as $obs
        | (($cfg.routing.rules // []) | map(select(sr_mine | not))) as $rules
        | $cfg + { outbounds: $obs, routing: (($cfg.routing // {}) + { rules: $rules }) }')
    sr_patch_profile_config "$profile_uuid" "$merged" || return 1
    step_ok "$(printf "${LANG[SR_UNPATCH_PROFILE_OK]}" "$SR_PROFILE_NAME")"
}

# --- hosts ------------------------------------------------------------------------

# Full host list (the panel endpoint takes no filters).
sr_fetch_hosts() {
    local response
    response=$(sr_api "GET" "/api/hosts?_=$(date +%s)")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    SR_HOSTS_JSON=$(echo "$response" | jq -c '.response')
}

# VLESS inbound uuids of the current profile: the route travels in the
# UUID tail, so hosts on Trojan/Shadowsocks inbounds cannot carry one.
# The metadata array holds uuid+tag, the Xray config holds tag+protocol —
# joined by tag.
sr_vless_inbound_uuids() {
    echo "$SR_PROFILE_INBOUNDS" | jq -r --argjson cfg "$SR_PROFILE_CONFIG" '
        [$cfg.inbounds[]? | select(.protocol == "vless") | .tag] as $vless
        | .[] | . as $i | select(($vless | index(($i.tag // ""))) != null) | $i.uuid'
}

# Pick the host to clone: enabled, on a VLESS inbound, carrying no route
# of its own. Sets SR_SOURCE_HOST_UUID / SR_SOURCE_HOST_REMARK.
sr_pick_source_host() {
    local profile_uuid="$1" vless_uuids vless_arr entries=() entry uuid remark pick i rest
    sr_fetch_hosts || return 1
    vless_uuids=$(sr_vless_inbound_uuids)
    [ -n "$vless_uuids" ] || { echo -e "${COLOR_RED}${LANG[SR_PROFILE_NO_VLESS]}${COLOR_RESET}"; return 1; }
    vless_arr=$(echo "$vless_uuids" | jq -R -s 'split("\n") | map(select(length > 0))')
    while IFS= read -r entry; do
        [ -n "$entry" ] && entries+=("$entry")
    done < <(echo "$SR_HOSTS_JSON" | jq -r --arg p "$profile_uuid" --argjson vless "$vless_arr" '
        .[] | . as $h
        | select((($h.inbound.configProfileUuid // "") == $p) and (($h.inbound.configProfileInboundUuid // "") as $iu | ($vless | index($iu)) != null))
        | select(.isDisabled != true)
        | select(.vlessRouteId == null)
        | "\(.uuid)\t\(.remark)"')

    if [ "${#entries[@]}" -eq 0 ]; then
        echo -e "${COLOR_RED}${LANG[SR_HOST_NO_SOURCE]}${COLOR_RESET}"
        return 1
    fi
    if [ "${#entries[@]}" -eq 1 ]; then
        SR_SOURCE_HOST_UUID="${entries[0]%%$'\t'*}"
        SR_SOURCE_HOST_REMARK="${entries[0]#*$'\t'}"
        return 0
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_HOST_PICK_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_HOST_PICK_HINT]}${COLOR_RESET}"
    echo -e ""
    i=1
    for entry in "${entries[@]}"; do
        remark="${entry#*$'\t'}"
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${remark}${COLOR_RESET}"
        i=$((i + 1))
    done
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$((i - 1))")" pick
    [ "$pick" = "0" ] && return 1
    if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#entries[@]}" ]; then
        SR_SOURCE_HOST_UUID=$(echo "${entries[$((pick - 1))]}" | cut -f1)
        SR_SOURCE_HOST_REMARK=$(echo "${entries[$((pick - 1))]}" | cut -f2)
        return 0
    fi
    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$((i - 1))"
    sleep 1
    sr_pick_source_host "$profile_uuid"
}

# An existing rid=1 host on this profile's VLESS inbounds — the direct host
# is one per PROFILE, not per bridge.
sr_find_direct_host_uuid() {
    local profile_uuid="$1" vless_arr
    vless_arr=$(sr_vless_inbound_uuids | jq -R -s 'split("\n") | map(select(length > 0))')
    [ "$vless_arr" = "[]" ] && return 1
    echo "$SR_HOSTS_JSON" | jq -r --arg p "$profile_uuid" --argjson vless "$vless_arr" '
        .[] | select(.vlessRouteId == 1)
        | select((.inbound.configProfileUuid // "") == $p)
        | select((.inbound.configProfileInboundUuid // "") as $iu | ($vless | index($iu)) != null)
        | .uuid' 2>/dev/null | head -n1
}

# Round-trip PATCH body: everything the update endpoint knows is sent
# back, so partial-update semantics can never wipe a field we did not
# mean to touch. remark / route / disabled are the only changes.
sr_host_patch() {
    local host_uuid="$1" remark="$2" route_id="$3" disabled="$4" response body
    response=$(sr_api "GET" "/api/hosts/$host_uuid")
    if ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    body=$(echo "$response" | jq -c --arg remark "$remark" \
        --argjson rid "$route_id" --argjson dis "$disabled" '.response |
        {uuid, remark: $remark, address, port, path, sni, host, alpn, fingerprint,
         isDisabled: $dis, securityLayer, xhttpExtraParams, muxParams, sockoptParams,
         finalMask, serverDescription, tags, isHidden, overrideSniFromAddress,
         keepSniBlank, vlessRouteId: $rid, pinnedPeerCertSha256, verifyPeerCertByName,
         shuffleHost, mihomoX25519, mihomoIpVersion, xrayJsonTemplateUuid,
         excludeFromSubscriptionTypes, mapper,
         inbound: {configProfileUuid: .inbound.configProfileUuid,
                   configProfileInboundUuid: .inbound.configProfileInboundUuid},
         nodes}')
    response=$(sr_api "PATCH" "/api/hosts" "$body")
    echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || { err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"; return 1; }
    return 0
}

# Clone the source host and stamp remark + route number; the clone copies
# every connection parameter (address, port, SNI, transport). A live host
# uuid from a previous run is PATCHed in place instead of cloning a second
# copy. Sets SR_NEW_HOST_UUID.
sr_route_create_host() {
    local src_uuid="$1" remark="$2" route_id="$3" existing_uuid="${4:-}" response new_uuid
    step_do "$(printf "${LANG[SR_HOST_CREATE]}" "$remark" "$route_id")"
    if [ -n "$existing_uuid" ]; then
        response=$(sr_api "GET" "/api/hosts/$existing_uuid")
        if echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
            if sr_host_patch "$existing_uuid" "$remark" "$route_id" false; then
                SR_NEW_HOST_UUID="$existing_uuid"
                step_ok "$(printf "${LANG[SR_HOST_CREATE_OK]}" "$remark")"
                return 0
            fi
            return 1
        fi
    fi
    response=$(sr_api "POST" "/api/hosts/actions/clone" "$(jq -nc --arg u "$src_uuid" '{cloneFromUuid: $u}')")
    new_uuid=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -z "$new_uuid" ]; then
        err_msg "$(printf "${LANG[SR_API_FAIL]}" "$response")"
        return 1
    fi
    sr_host_patch "$new_uuid" "$remark" "$route_id" false || return 1
    SR_NEW_HOST_UUID="$new_uuid"
    step_ok "$(printf "${LANG[SR_HOST_CREATE_OK]}" "$remark")"
}

# Route numbers already taken: other bridges' state plus vlessRoute values
# already present in the profile's rules (an admin's own rules count too).
sr_route_numbers_used() {
    local profile_config="${1:-}" slug no out=" _"
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ "$slug" != "${SR_CURRENT:-}" ] || continue
        no=$(sed -n 's|^route_no=||p' "${SR_CONF_DIR}/${slug}.bridge" 2>/dev/null | head -n1)
        case "$no" in ''|*[!0-9]*) ;; *) out="$out $no" ;; esac
    done < <(sr_bridges_list)
    if [ -n "$profile_config" ]; then
        while IFS= read -r no; do
            [ -n "$no" ] && out="$out $no"
        done < <(echo "$profile_config" | jq -r '.routing.rules[]? | select(.vlessRoute != null) | .vlessRoute' 2>/dev/null)
    fi
    printf '%s' "$out"
}

sr_next_route_no() {
    local used="$1" n=2
    while case " $used " in *" $n "*) true ;; *) false ;; esac; do
        n=$((n + 1))
    done
    echo "$n"
}

# Display name of the line's EXIT: stored during setup; bridges created
# before that key existed fall back to the source bridge's name (a shared
# exit is matched by host+port) or their own name.
sr_exit_label() {
    local label slug f
    label=$(sr_state_get exit_label)
    [ -n "$label" ] && { echo "$label"; return 0; }
    if [ "$(sr_state_get exit_shared)" = "yes" ]; then
        local host port
        host=$(sr_state_get host)
        port=$(sr_state_get port)
        while IFS= read -r slug; do
            [ -n "$slug" ] || continue
            [ "$slug" != "$SR_CURRENT" ] || continue
            f="${SR_CONF_DIR}/${slug}.bridge"
            [ "$(sed -n 's|^host=||p' "$f" | head -n1)" = "$host" ] || continue
            [ "$(sed -n 's|^port=||p' "$f" | head -n1)" = "$port" ] || continue
            label=$(sed -n 's|^bridge_name=||p' "$f" | head -n1)
            [ -n "$label" ] && { echo "$label"; return 0; }
        done < <(sr_bridges_list)
    fi
    label=$(sr_state_get bridge_name)
    echo "${label:-$SR_CURRENT}"
}

# Fast path: point one more public profile at the ALREADY configured line.
# Everything bridge-side comes from state; the new profile gets the same
# route number, its own cloned host («<its host> → <exit>») and its entry
# nodes allowed into the exit's firewall.
sr_route_attach_profile() {
    local host port password route_no ob exit_label
    load_api_module || return 1
    load_remote_exec_module || return 1
    get_panel_token || { echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"; return 1; }

    host=$(sr_state_get host)
    port=$(sr_state_get port)
    password=$(sr_state_get ss_password)
    route_no=$(sr_state_get route_no)
    if [ -z "$host" ] || [ -z "$port" ] || [ -z "$password" ] || [ -z "$route_no" ]; then
        echo -e "${COLOR_RED}${LANG[SR_ATTACH_NOT_READY]}${COLOR_RESET}"
        return 1
    fi
    ob=$(sr_bridge_outbound_tag "$SR_CURRENT")
    exit_label=$(sr_exit_label)

    local ru_list
    ru_list=$(sr_state_get ru_profiles)
    SR_ATTACHED_MAP=$(sr_route_claims_map)
    sr_pick_public_profile "$(sr_state_get profile_uuid)" "$ru_list" warn-only || return 1
    local entry_profile="$SR_PICKED_PROFILE"
    # Already attached? Re-attaching would clone a SECOND identical host into
    # subscriptions — the repair path is «Настроить заново», which reuses the
    # recorded host uuids.
    case " $ru_list " in
        *" $entry_profile "*)
            echo -e "${COLOR_YELLOW}${LANG[SR_ATTACH_ALREADY]}${COLOR_RESET}"
            return 1
            ;;
    esac
    sr_get_profile "$entry_profile" || return 1

    sr_pick_source_host "$entry_profile" || return 1

    sr_route_check_xray "$entry_profile" || return 1
    sr_patch_profile_route "$entry_profile" "$host" "$port" "$password" "$route_no" "$ob" || return 1

    case " $ru_list " in
        *" $entry_profile "*) ;;
        *) sr_state_set ru_profiles "${ru_list:+$ru_list }$entry_profile" ;;
    esac

    local def_remark host_remark extra
    def_remark="$(printf "${LANG[SR_HOST_REMARK_FMT]}" "$SR_SOURCE_HOST_REMARK" "$(sr_cap_first "$exit_label")")"
    reading "$(printf "${LANG[SR_HOST_REMARK_PROMPT]}" "$def_remark")" host_remark
    host_remark="${host_remark:-$def_remark}"
    sr_route_create_host "$SR_SOURCE_HOST_UUID" "$host_remark" "$route_no" || return 1
    extra=$(sr_state_get host_uuid_extra)
    sr_state_set host_uuid_extra "${extra:+$extra }$SR_NEW_HOST_UUID"

    # The exit's ufw only knows the sources from this line's birth — the
    # new entry nodes must be allowed in (rules added here are not tracked
    # in state, a shared exit closes nothing on teardown anyway).
    local sources=() addr panel_ip
    while IFS= read -r addr; do
        [ -n "$addr" ] && [ "$addr" != "$host" ] && sources+=("$addr")
    done < <(sr_profile_node_addresses "$entry_profile")
    panel_ip=$(sr_panel_public_ip)
    [ -n "$panel_ip" ] && sources+=("$panel_ip")
    if [ "${#sources[@]}" -gt 0 ]; then
        sr_remote_open_bridge_port "$host" "$port" "${sources[@]}"
    fi
    return 0
}

# --- route setup ------------------------------------------------------------------

# Per-user bridge setup. Same shape as sr_setup ("fresh" vs re-run in the
# current context), but the public profile gets vlessRoute rules instead
# of the geo split, and the user-facing part is a host with vlessRouteId.
sr_setup_route() {
    local host ss_port slug src_slug src_label line pick i
    local exit_shared=no inbound_uuid inbound_tag node_uuid bridge_profile

    if [ "${1:-}" = "fresh" ]; then
        SR_CURRENT=""
    fi

    load_api_module || return 1
    load_remote_exec_module || return 1
    get_panel_token || { echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"; return 1; }
    sr_migrate_legacy

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_ROUTE_SETUP_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_ROUTE_SETUP_HINT]}${COLOR_RESET}"
    echo -e ""

    # --- exit machine: another bridge's line or a brand-new box ---------------
    # Dedup by host:port — several bridges routinely share one exit (a geo
    # line plus route lines stacked on it); without the dedup the menu lists
    # the same machine once per bridge and picking "the second one" silently
    # routes through it instead of the intended "new machine" entry below.
    local candidates=() c_host c_port c_inbound c_seen=" "
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ "$slug" != "${SR_CURRENT:-}" ] || continue
        c_host=$(sed -n 's|^host=||p' "${SR_CONF_DIR}/${slug}.bridge" | head -n1)
        c_port=$(sed -n 's|^port=||p' "${SR_CONF_DIR}/${slug}.bridge" | head -n1)
        c_inbound=$(sed -n 's|^inbound_uuid=||p' "${SR_CONF_DIR}/${slug}.bridge" | head -n1)
        { [ -n "$c_host" ] && [ -n "$c_port" ] && [ -n "$c_inbound" ]; } || continue
        case "$c_seen" in *" $c_host:$c_port "*) continue ;; esac
        c_seen="$c_seen$c_host:$c_port "
        candidates+=("$slug	$c_host	$c_port")
    done < <(sr_bridges_list)

    if [ "${#candidates[@]}" -eq 0 ]; then
        sr_pick_bridge_host || { echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"; return 1; }
        reading "$(printf "${LANG[SR_PORT_PROMPT]}" "$SR_DEFAULT_PORT")" ss_port
        [ -n "$ss_port" ] || ss_port=$SR_DEFAULT_PORT
        sr_pick_bridge_name
        sr_state_set type route
        SR_ROUTE_EXIT_LABEL="$SR_BRIDGE_SLUG"

        re_require_access_host "$SR_HOST" || { echo -e "${COLOR_RED}$(printf "${LANG[SR_SSH_FAIL]}" "$SR_HOST")${COLOR_RESET}"; return 1; }
        local panel_ip host_ip
        panel_ip=$(sr_panel_public_ip)
        host_ip=$(dig +short A "$SR_HOST" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        [ -z "$host_ip" ] && host_ip="$SR_HOST"
        if [ -n "$panel_ip" ] && { [ "$SR_HOST" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
            echo -e "${COLOR_RED}${LANG[SR_SAME_BOX]}${COLOR_RESET}"
            return 1
        fi

        sr_provision_exit "$SR_HOST" "$ss_port" || return 1
        host="$SR_HOST"
        node_uuid="$SR_EXIT_NODE_UUID"
        bridge_profile="$SR_EXIT_PROFILE_UUID"
        inbound_uuid="$SR_EXIT_INBOUND_UUID"
        inbound_tag="$SR_EXIT_INBOUND_TAG"
    else
        echo -e "${COLOR_GREEN}${LANG[SR_EXIT_SOURCE_TITLE]}${COLOR_RESET}"
        echo -e ""
        i=1
        for line in "${candidates[@]}"; do
            src_slug="${line%%$'\t'*}"
            src_label=$(sed -n 's|^bridge_name=||p' "${SR_CONF_DIR}/${src_slug}.bridge" | head -n1)
            [ -n "$src_label" ] || src_label="$src_slug"
            rest="${line#*$'\t'}"
            echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}$(printf "${LANG[SR_EXIT_SOURCE_REUSE]}" "$(sr_cap_first "$src_label")" "${rest//$'\t'/:}")${COLOR_RESET}"
            i=$((i + 1))
        done
        local last=$i
        echo -e "${COLOR_YELLOW}${last}. ${LANG[SR_EXIT_SOURCE_NEW]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" pick
        [ -z "$pick" ] && pick=1
        [ "$pick" = "0" ] && return 1
        if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#candidates[@]}" ]; then
            line="${candidates[$((pick - 1))]}"
            src_slug="${line%%$'\t'*}"
            local sf="${SR_CONF_DIR}/${src_slug}.bridge"
            host=$(sed -n 's|^host=||p' "$sf" | head -n1)
            ss_port=$(sed -n 's|^port=||p' "$sf" | head -n1)
            inbound_uuid=$(sed -n 's|^inbound_uuid=||p' "$sf" | head -n1)
            inbound_tag=$(sed -n 's|^inbound_tag=||p' "$sf" | head -n1)
            node_uuid=$(sed -n 's|^node_uuid=||p' "$sf" | head -n1)
            bridge_profile=$(sed -n 's|^profile_uuid=||p' "$sf" | head -n1)
            src_label=$(sed -n 's|^bridge_name=||p' "$sf" | head -n1)
            [ -n "$src_label" ] || src_label="$src_slug"
            if [ -z "$host" ] || [ -z "$ss_port" ] || [ -z "$inbound_uuid" ]; then
                echo -e "${COLOR_RED}$(printf "${LANG[SR_EXIT_REUSE_STATE_BAD]}" "$(sr_cap_first "$src_label")")${COLOR_RESET}"
                return 1
            fi
            exit_shared=yes
            step_ok "$(printf "${LANG[SR_EXIT_REUSE_OK]}" "$(sr_cap_first "$src_label")" "$host" "$ss_port")"
            # A second line to the same exit: the admin-facing name is the
            # exit plus a line number («estonia-2»). The USER-facing host
            # name follows the EXIT, not this line — see the host step — so
            # subscriptions read «Moscow → Estonia», never «… → Estonia-2».
            local n2=2
            while [ -e "${SR_CONF_DIR}/${src_slug}-${n2}.bridge" ]; do
                n2=$((n2 + 1))
            done
            SR_HOST_LABEL="${src_slug}-${n2}"
            SR_ROUTE_EXIT_LABEL="$src_label"
            sr_pick_bridge_name
            sr_state_set type route
        elif [ "$pick" = "$last" ]; then
            sr_pick_bridge_host || { echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"; return 1; }
            reading "$(printf "${LANG[SR_PORT_PROMPT]}" "$SR_DEFAULT_PORT")" ss_port
            [ -n "$ss_port" ] || ss_port=$SR_DEFAULT_PORT
            sr_pick_bridge_name
            sr_state_set type route
            SR_ROUTE_EXIT_LABEL="$SR_BRIDGE_SLUG"

            re_require_access_host "$SR_HOST" || { echo -e "${COLOR_RED}$(printf "${LANG[SR_SSH_FAIL]}" "$SR_HOST")${COLOR_RESET}"; return 1; }
            local panel_ip host_ip
            panel_ip=$(sr_panel_public_ip)
            host_ip=$(dig +short A "$SR_HOST" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
            [ -z "$host_ip" ] && host_ip="$SR_HOST"
            if [ -n "$panel_ip" ] && { [ "$SR_HOST" = "$panel_ip" ] || [ "$host_ip" = "$panel_ip" ]; }; then
                echo -e "${COLOR_RED}${LANG[SR_SAME_BOX]}${COLOR_RESET}"
                return 1
            fi

            sr_provision_exit "$SR_HOST" "$ss_port" || return 1
            host="$SR_HOST"
            node_uuid="$SR_EXIT_NODE_UUID"
            bridge_profile="$SR_EXIT_PROFILE_UUID"
            inbound_uuid="$SR_EXIT_INBOUND_UUID"
            inbound_tag="$SR_EXIT_INBOUND_TAG"
        else
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            sr_setup_route "${1:-}"
            return $?
        fi
    fi

    sr_state_set host "$host"
    sr_state_set port "$ss_port"
    sr_state_set exit_shared "$exit_shared"
    sr_state_set exit_label "${SR_ROUTE_EXIT_LABEL:-$(sr_state_get bridge_name)}"
    sr_state_set node_uuid "$node_uuid"
    sr_state_set profile_uuid "$bridge_profile"
    sr_state_set profile_created "$( [ "$exit_shared" = yes ] && echo no || echo "$SR_EXIT_PROFILE_CREATED" )"
    sr_state_set node_installed "$( [ "$exit_shared" = yes ] && echo no || echo "$SR_EXIT_NODE_INSTALLED" )"
    sr_state_set inbound_uuid "$inbound_uuid"
    sr_state_set inbound_tag "$inbound_tag"

    # Own squad and service user even on a shared exit: the SS inbound takes
    # clients from every squad bound to it, and a separate line is visible
    # in the panel's traffic stats (the same trick as running one service
    # user per bridge by hand).
    sr_ensure_squad "$inbound_uuid" || return 1
    sr_ensure_user "$SR_SQUAD_UUID" || return 1

    # --- entry profile: hosts only carry routes on VLESS inbounds -------------
    # Route bridges stack on one profile by design, so foreign claims are
    # shown as markers without the repoint question — seeing «already fed by
    # bridge X» prevents accidental duplicate lines to the same exit.
    SR_ATTACHED_MAP=$(sr_route_claims_map)
    local ru_list
    ru_list=$(sr_state_get ru_profiles)
    sr_pick_public_profile "$bridge_profile" "$ru_list" warn-only || return 1
    local entry_profile="$SR_PICKED_PROFILE"
    sr_get_profile "$entry_profile" || return 1

    sr_pick_source_host "$entry_profile" || return 1
    local src_host_uuid="$SR_SOURCE_HOST_UUID" src_remark="$SR_SOURCE_HOST_REMARK"

    # --- route number -----------------------------------------------------------
    local used def_no no_input route_no own_no filtered n
    used=$(sr_route_numbers_used "$SR_PROFILE_CONFIG")
    own_no=$(sr_state_get route_no)
    # A re-run keeps its own number: the profile still carries this bridge's
    # stale rules and they must not read as «taken» — the patch below strips
    # them anyway.
    if [ -n "$own_no" ]; then
        filtered=""
        for n in $used; do
            [ "$n" = "$own_no" ] || filtered="${filtered:+$filtered }$n"
        done
        used="$filtered"
        def_no="$own_no"
    else
        def_no=$(sr_next_route_no "$used")
    fi
    while true; do
        reading "$(printf "${LANG[SR_ROUTE_NO_PROMPT]}" "$def_no")" no_input
        no_input="${no_input:-$def_no}"
        case "$no_input" in
            ''|*[!0-9]*)
                echo -e "${COLOR_YELLOW}${LANG[SR_ROUTE_NO_INVALID]}${COLOR_RESET}"
                continue
                ;;
        esac
        if [ "$no_input" -lt 2 ] || [ "$no_input" -gt 65535 ]; then
            echo -e "${COLOR_YELLOW}${LANG[SR_ROUTE_NO_INVALID]}${COLOR_RESET}"
            continue
        fi
        case " $used " in
            *" $no_input "*)
                echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_ROUTE_NO_TAKEN]}" "$no_input")${COLOR_RESET}"
                continue
                ;;
        esac
        route_no="$no_input"
        break
    done

    # --- version gate, then rules ---------------------------------------------
    sr_route_check_xray "$entry_profile" || return 1

    local ob="${SR_ROUTE_OB_PREFIX}${SR_CURRENT}"
    sr_patch_profile_route "$entry_profile" "$host" "$ss_port" "$SR_SS_PASSWORD" "$route_no" "$ob" || return 1

    ru_list=$(sr_state_get ru_profiles)
    case " $ru_list " in
        *" $entry_profile "*) ;;
        *) sr_state_set ru_profiles "${ru_list:+$ru_list }$entry_profile" ;;
    esac
    sr_state_set route_no "$route_no"
    sr_state_set outbound_tag "$ob"

    # --- hosts --------------------------------------------------------------------
    # The user-facing name follows the EXIT (the source bridge's name for a
    # reused line, this bridge's own name otherwise): subscriptions must
    # read «Moscow → Estonia», never «Moscow → Estonia-2».
    local def_remark host_remark
    def_remark="$(printf "${LANG[SR_HOST_REMARK_FMT]}" "$src_remark" "$(sr_cap_first "${SR_ROUTE_EXIT_LABEL:-$SR_BRIDGE_SLUG}")")"
    reading "$(printf "${LANG[SR_HOST_REMARK_PROMPT]}" "$def_remark")" host_remark
    host_remark="${host_remark:-$def_remark}"
    sr_route_create_host "$src_host_uuid" "$host_remark" "$route_no" "$(sr_state_get host_uuid)" || return 1
    sr_state_set host_uuid "$SR_NEW_HOST_UUID"
    sr_state_set host_remark "$host_remark"
    sr_state_set host_remark_base "$src_remark"

    # A «direct» host only differs from the plain one where the profile
    # already splits countries; on an untouched profile the default host
    # IS the direct egress.
    local direct_created=no d_remark direct_uuid
    if echo "$SR_PROFILE_CONFIG" | jq -e 'any(.routing.rules[]?; (.ip // []) == ["geoip:ru"])' >/dev/null 2>&1; then
        # The rid=1 direct host belongs to the PROFILE, not to this bridge:
        # reuse the one another route bridge already created — cloning a
        # second one puts duplicates into every subscription.
        direct_uuid=$(sr_state_get host_uuid_direct)
        [ -n "$direct_uuid" ] || direct_uuid=$(sr_find_direct_host_uuid "$entry_profile")
        d_remark="$(printf "${LANG[SR_HOST_DIRECT_FMT]}" "$src_remark")"
        sr_route_create_host "$src_host_uuid" "$d_remark" 1 "$direct_uuid" || return 1
        sr_state_set host_uuid_direct "$SR_NEW_HOST_UUID"
        direct_created=yes
    fi

    # --- firewall on the exit box ----------------------------------------------
    # Own machine: record the sources (teardown closes them later). A shared
    # line skips the bookkeeping but still must let the NEW entry nodes
    # reach the port — the exit's ufw only knows the sources from the line
    # that was born on that machine.
    local sources=() addr panel_ip
    while IFS= read -r addr; do
        [ -n "$addr" ] && [ "$addr" != "$host" ] && sources+=("$addr")
    done < <(sr_profile_node_addresses "$entry_profile")
    panel_ip=$(sr_panel_public_ip)
    [ -n "$panel_ip" ] && sources+=("$panel_ip")
    if [ "$exit_shared" = "no" ]; then
        sr_state_set ufw_sources "$(printf '%s ' "${sources[@]}")"
    fi
    sr_remote_open_bridge_port "$host" "$ss_port" "${sources[@]}"

    # --- verify --------------------------------------------------------------------
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
    echo -e "${COLOR_GREEN}${LANG[SR_ROUTE_DONE_TITLE]}${COLOR_RESET}"
    printf "${COLOR_YELLOW}${LANG[SR_ROUTE_DONE_LINE]}${COLOR_RESET}\n" "$host" "$ss_port" "$route_no"
    printf "${COLOR_YELLOW}${LANG[SR_ROUTE_DONE_HOST]}${COLOR_RESET}\n" "$host_remark"
    [ "$direct_created" = "yes" ] && printf "${COLOR_YELLOW}${LANG[SR_ROUTE_DONE_DIRECT_NOTE]}${COLOR_RESET}\n" "$d_remark"
    printf "${COLOR_GRAY}${LANG[SR_ROUTE_DONE_STATS]}${COLOR_RESET}\n" "$SR_USER_NAME"
    echo -e "${COLOR_GRAY}${LANG[SR_ROUTE_DONE_TEST]}${COLOR_RESET}"
    return 0
}

# Hide or restore the route host in every subscription. Rules stay — this
# is a visibility switch, not a teardown step.
sr_route_toggle_host() {
    local host_uuid response remark rid disabled
    host_uuid=$(sr_state_get host_uuid)
    if [ -z "$host_uuid" ]; then
        echo -e "${COLOR_RED}${LANG[SR_HOST_GONE]}${COLOR_RESET}"
        return 1
    fi
    response=$(sr_api "GET" "/api/hosts/$host_uuid")
    remark=$(echo "$response" | jq -r '.response.remark // empty')
    disabled=$(echo "$response" | jq -r '.response.isDisabled // empty')
    if [ -z "$remark" ]; then
        echo -e "${COLOR_RED}${LANG[SR_HOST_GONE]}${COLOR_RESET}"
        return 1
    fi
    rid=$(sr_state_get route_no)
    [ -n "$rid" ] || rid=2
    if [ "$disabled" = "true" ]; then
        sr_host_patch "$host_uuid" "$remark" "$rid" false \
            && step_ok "${LANG[SR_HOST_TOGGLE_SHOW_OK]}" \
            && sr_state_set host_remark "$remark"
    else
        sr_host_patch "$host_uuid" "$remark" "$rid" true \
            && step_ok "${LANG[SR_HOST_TOGGLE_HIDE_OK]}" \
            && sr_state_set host_remark "$remark"
    fi
}

# Teardown of a route bridge: rules and outbound out of the profiles, the
# host(s) deleted, the own service user and squad removed. The exit
# node/profile/ufw of a shared line belong to the source bridge and stay;
# users fall back to the profile's remaining rules — a stale tail simply
# matches nothing.
sr_teardown_route() {
    local host port ru_list uuid response user_id squad_uuid ob strip_direct=no

    ob=$(sr_bridge_outbound_tag "$SR_CURRENT")
    # The rid=1 direct host is shared per profile (every route bridge on the
    # profile records the SAME uuid): strip its rule and delete the host only
    # when no other bridge still references it.
    local direct_shared=no d_uuid ds_slug ds_f
    d_uuid=$(sr_state_get host_uuid_direct)
    if [ -n "$d_uuid" ]; then
        while IFS= read -r ds_slug; do
            [ "$ds_slug" != "${SR_CURRENT:-}" ] || continue
            ds_f="${SR_CONF_DIR}/${ds_slug}.bridge"
            [ "$(sed -n 's/^host_uuid_direct=//p' "$ds_f" 2>/dev/null | head -n1)" = "$d_uuid" ] && direct_shared=yes
        done < <(sr_bridges_list)
    fi
    [ -n "$d_uuid" ] && [ "$direct_shared" = "no" ] && strip_direct=yes
    ru_list=$(sr_state_get ru_profiles)
    for uuid in $ru_list; do
        sr_unpatch_profile_route "$uuid" "$ob" "$strip_direct" \
            || echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_TEARDOWN_PARTIAL]}" "$uuid")${COLOR_RESET}"
    done

    local key huuid
    for key in host_uuid_direct host_uuid; do
        huuid=$(sr_state_get "$key")
        [ -n "$huuid" ] || continue
        if [ "$key" = "host_uuid_direct" ] && [ "$direct_shared" = "yes" ]; then
            continue
        fi
        step_do "${LANG[SR_TEARDOWN_HOST]}"
        response=$(sr_api "DELETE" "/api/hosts/$huuid")
        [ -z "$response" ] && step_ok "${LANG[SR_TEARDOWN_HOST_OK]}"
    done
    # Hosts created by «Подключить ещё профиль» on other profiles.
    for huuid in $(sr_state_get host_uuid_extra); do
        [ -n "$huuid" ] || continue
        step_do "${LANG[SR_TEARDOWN_HOST]}"
        response=$(sr_api "DELETE" "/api/hosts/$huuid")
        [ -z "$response" ] && step_ok "${LANG[SR_TEARDOWN_HOST_OK]}"
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

    host=$(sr_state_get host)
    port=$(sr_state_get port)
    # The birth-time exit_shared marker alone is stale truth: another bridge
    # may have been born on this line later (or the birth sibling removed).
    # Close the firewall only when NO other bridge consumes the exit now.
    if [ -n "$host" ] && [ -n "$port" ]; then
        if sr_exit_shared_now "$host" "$port"; then
            echo -e "${COLOR_GRAY}${LANG[SR_TEARDOWN_EXIT_SHARED]}${COLOR_RESET}"
        else
            load_remote_exec_module
            local sources=() src
            # tr normalizes states written by older versions (space-joined
            # single line) into one source per line.
            while read -r src; do
                [ -n "$src" ] && sources+=("$src")
            done <<< "$(sr_state_get ufw_sources | tr ' ' '\n')"
            if [ "${#sources[@]}" -gt 0 ]; then
                step_do "${LANG[SR_TEARDOWN_UFW]}"
                sr_remote_close_bridge_port "$host" "$port" "${sources[@]}" && step_ok "${LANG[SR_TEARDOWN_UFW_OK]}"
            fi
            echo -e "${COLOR_YELLOW}${LANG[SR_TEARDOWN_KEEP_NOTE]}${COLOR_RESET}"
        fi
    fi
    sr_state_clear
    step_ok "${LANG[SR_TEARDOWN_DONE]}"
}

# --- menu ------------------------------------------------------------------------

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

# --- extended RU geodata (runetfreedom) ----------------------------------------
#
# Stock rules (geosite:category-ru via the .ru TLD wildcard + geoip:ru) miss
# RU services living on foreign TLDs. The runetfreedom dat adds the
# ru-available-only-inside category (domains reachable only from inside RU);
# the dat is mounted as a SEPARATE file per the node docs (never overwrite
# the stock geosite/geoip) and referenced with ext:. Routing is evaluated on
# the ENTRY nodes, so the file goes there — local compose and SSH-managed
# remote machines; a node without SSH access is reported for manual mounting.

SR_RUEX_FILE="geosite-ruex.dat"
SR_RUEX_RULE="ext:geosite-ruex.dat:ru-available-only-inside"
SR_RUEX_STATE="${SR_CONF_DIR}/ruex.state"

sr_ruex_state_get() {
    [ -r "$SR_RUEX_STATE" ] || return 0
    sed -n "s|^$1=||p" "$SR_RUEX_STATE" | head -n1
}

sr_ruex_state_set() {
    mkdir -p "$SR_CONF_DIR"
    touch "$SR_RUEX_STATE"
    chmod 600 "$SR_RUEX_STATE" 2>/dev/null
    if grep -q "^$1=" "$SR_RUEX_STATE"; then
        sed -i "s|^$1=.*|$1=$2|" "$SR_RUEX_STATE"
    else
        echo "$1=$2" >> "$SR_RUEX_STATE"
    fi
}

sr_ruex_enabled() {
    [ "$(sr_ruex_state_get enabled)" = "yes" ]
}

# Entry-node addresses across all GEO bridges, deduped. Route bridges are
# skipped: their profiles carry per-bridge outbounds, not the shared
# SR_BRIDGE_SS the ext: rule would point at (a dangling outboundTag kills
# the whole node config).
sr_ruex_entry_nodes() {
    local slug profile profiles addr out=""
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        [ "$(sr_bridge_type "$slug")" = "geo" ] || continue
        profiles=$(sed -n 's|^ru_profiles=||p' "${SR_CONF_DIR}/${slug}.bridge" 2>/dev/null | head -n1)
        for profile in $profiles; do
            while IFS= read -r addr; do
                [ -n "$addr" ] || continue
                case " $out " in
                    *" $addr "*) ;;
                    *) out="${out:+$out }$addr" ;;
                esac
            done < <(sr_profile_node_addresses_raw "$profile")
        done
    done < <(sr_bridges_list)
    printf '%s' "$out"
}

# Compose of the local remnanode, if this box runs one.
sr_ruex_local_compose() {
    local d c
    for d in /opt/remnanode /opt/remnawave; do
        c="$d/docker-compose.yml"
        if [ -f "$c" ] && grep -q "^[[:space:]]*remnanode:" "$c"; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

# Latest runetfreedom geosite.dat over the mirrors, sha256-verified.
sr_ruex_download() {
    local dest="$1"
    local base="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
    local mirror ok=false
    for mirror in "$base" "https://gh-proxy.com/$base" "https://ghfast.top/$base" "https://ghproxy.net/$base"; do
        rm -f "$dest/geosite.dat" "$dest/geosite.dat.sha256sum"
        if curl -fsSL $CURL_IP_FLAGS --connect-timeout 15 --max-time 180 "${mirror}/geosite.dat" -o "$dest/geosite.dat" 2>/dev/null \
           && curl -fsSL $CURL_IP_FLAGS --connect-timeout 10 --max-time 30 "${mirror}/geosite.dat.sha256sum" -o "$dest/geosite.dat.sha256sum" 2>/dev/null \
           && [ -s "$dest/geosite.dat" ]; then
            ok=true
            break
        fi
    done
    $ok || return 1
    local want got
    want=$(grep -oE '^[0-9a-fA-F]{64}' "$dest/geosite.dat.sha256sum" 2>/dev/null | head -n1)
    got=$(sha256sum "$dest/geosite.dat" | cut -d' ' -f1)
    [ -n "$want" ] && [ "$want" = "$got" ]
}

# Idempotent volume line for the remnanode service; the anchor line lives in
# every remnanode volumes block this script has ever written.
sr_ruex_compose_add() {
    local file="$1" ind
    grep -q "geosite-ruex.dat" "$file" && return 0
    ind=$(grep -m1 '/var/log/remnanode' "$file" | sed 's/[^[:space:]].*//')
    [ -n "$ind" ] || ind="      "
    sed -i "\|/var/log/remnanode|i\\${ind}- ./${SR_RUEX_FILE}:/usr/local/share/xray/${SR_RUEX_FILE}" "$file"
}

sr_ruex_compose_del() {
    sed -i '\|geosite-ruex.dat|d' "$1"
}

# Add (on) or remove (off) the ext: rule in every bridged profile. The rule
# inherits the outbound the profile already sends geoip:ru traffic to.
sr_ruex_switch_rules() {
    local on_off="$1" slug profile profiles merged count=0 ob
    # Every rules re-run is also the cheap moment to bring a stale cron
    # updater up to the current marker (fixes reach boxes enabled long ago).
    [ "$on_off" = "on" ] && sr_ruex_ensure_updater
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        # Geo bridges only — see sr_ruex_entry_nodes for the dangling-tag
        # story. Profiles patched by both types get the rule via their geo
        # bridge.
        [ "$(sr_bridge_type "$slug")" = "geo" ] || continue
        profiles=$(sed -n 's|^ru_profiles=||p' "${SR_CONF_DIR}/${slug}.bridge" 2>/dev/null | head -n1)
        for profile in $profiles; do
            sr_get_profile "$profile" || continue
            # The list means "reachable only from inside RU": unlike the
            # plain geo rules it needs the RU egress in EVERY mode — in
            # mode "direct" the bridge is exactly what makes those domains
            # work instead of dying on the foreign entry.
            ob="$SR_OUTBOUND_TAG"
            if [ "$on_off" = "on" ]; then
                merged=$(echo "$SR_PROFILE_CONFIG" | jq -c --arg rule "$SR_RUEX_RULE" --arg ob "$ob" '
                    .routing.rules |= (if any((.domain // []) | index($rule)) then .
                        else . + [{ domain: [$rule], outboundTag: $ob }] end)')
            else
                merged=$(echo "$SR_PROFILE_CONFIG" | jq -c --arg rule "$SR_RUEX_RULE" '
                    .routing.rules |= map(select((.domain // []) | index($rule) | not))')
            fi
            if [ "$merged" != "$SR_PROFILE_CONFIG" ]; then
                sr_patch_profile_config "$profile" "$merged" && count=$((count + 1))
            fi
        done
    done < <(sr_bridges_list)
    SR_RUEX_SWITCHED=$count
    return 0
}

# Standalone daily updater for cron: it must not source the menu app, so it
# re-implements the small pieces it needs (mirrors+sha download, per-target
# ssh from remote-exec state files, node restart through the saved panel
# token). Restarts happen ONLY when a file actually changed.
# The version marker makes fixes reach already-installed boxes: any flow that
# re-runs the rules regenerates the script when the marker differs.
SR_RUEX_UPDATER_MARKER="rrp-ruex-update v2"
sr_ruex_write_updater() {
    cat > "${SR_CONF_DIR}/ruex-update.sh" <<UPD
#!/bin/bash
# ${SR_RUEX_UPDATER_MARKER} — auto-generated by remnawave-reverse-proxy
# (server routing, extended RU lists). Manual edits are lost on regen.
DIR=/usr/local/remnawave_reverse
STATE="\$DIR/server-routing/ruex.state"
KEY="\$DIR/ssh/id_ed25519"
KH="\$DIR/ssh/known_hosts"
LOG="\$DIR/server-routing/ruex-update.log"
BASE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
FILE="geosite-ruex.dat"
TMP=\$(mktemp -d)

log() {
    echo "\$(date '+%F %T') \$*" >> "\$LOG"
    tail -n 50 "\$LOG" > "\$LOG.t" 2>/dev/null && mv "\$LOG.t" "\$LOG"
}

# ssh target for an address from the remote-exec state files. A node moved
# onto the NetBird overlay carries its overlay IP in the panel; the target
# file holds it as the overlay= alias while host= stays the public address
# ssh must actually use.
tgt_for() {
    local f h p u ov
    for f in "\$DIR"/remote-exec/*.target; do
        [ -f "\$f" ] || continue
        h=\$(sed -n 's|^host=||p' "\$f" | head -n1)
        ov=\$(sed -n 's|^overlay=||p' "\$f" | head -n1)
        { [ "\$h" = "\$1" ] || [ "\$ov" = "\$1" ]; } || continue
        p=\$(sed -n 's|^port=||p' "\$f" | head -n1); [ -n "\$p" ] || p=22
        u=\$(sed -n 's|^user=||p' "\$f" | head -n1); [ -n "\$u" ] || u=root
        echo "\$u@\$h -p \$p"
        return 0
    done
    return 1
}

# Node uuid by panel address, with the netbird module state as the fallback:
# an overlay node's .address is its overlay IP, which the ruex state never
# held — the overlay→uuid map lives in netbird/nodes/*.json.
uuid_for() {
    local addr="\$1" u nf ov
    u=\$(echo "\$resp" | jq -r --arg a "\$addr" '.response[]? | select(.address == \$a) | .uuid' 2>/dev/null | head -n1)
    [ -n "\$u" ] && { echo "\$u"; return 0; }
    for nf in "\$DIR"/netbird/nodes/*.json; do
        [ -f "\$nf" ] || continue
        ov=\$(jq -r '.overlay // empty' "\$nf" 2>/dev/null)
        if [ "\$ov" = "\$addr" ]; then
            jq -r '.uuid // empty' "\$nf" 2>/dev/null
            return 0
        fi
    done
    return 1
}

cd "\$TMP" || exit 1
ok=0
for m in "\$BASE" "https://gh-proxy.com/\$BASE" "https://ghfast.top/\$BASE" "https://ghproxy.net/\$BASE"; do
    if curl -fsSL --connect-timeout 15 --max-time 180 "\$m/geosite.dat" -o geosite.dat 2>/dev/null \\
       && curl -fsSL --connect-timeout 10 --max-time 30 "\$m/geosite.dat.sha256sum" -o geosite.dat.sha256sum 2>/dev/null \\
       && [ -s geosite.dat ]; then
        ok=1
        break
    fi
done
if [ "\$ok" != 1 ]; then
    log "download failed from all mirrors"
    rm -rf "\$TMP"
    exit 1
fi
want=\$(grep -oE '^[0-9a-fA-F]{64}' geosite.dat.sha256sum | head -n1)
got=\$(sha256sum geosite.dat | cut -d' ' -f1)
if [ -n "\$want" ] && [ "\$want" != "\$got" ]; then
    log "checksum mismatch"
    rm -rf "\$TMP"
    exit 1
fi

changed=""
local_dir=""
for d in /opt/remnanode /opt/remnawave; do
    if [ -f "\$d/docker-compose.yml" ] && grep -q '^[[:space:]]*remnanode:' "\$d/docker-compose.yml" 2>/dev/null; then
        local_dir="\$d"
        break
    fi
done
if [ -n "\$local_dir" ] && [ -f "\$local_dir/\$FILE" ]; then
    cur=\$(sha256sum "\$local_dir/\$FILE" | cut -d' ' -f1)
    if [ "\$cur" != "\$got" ]; then
        if cp -f geosite.dat "\$local_dir/\$FILE"; then
            changed="local"
            log "local file updated"
        fi
    fi
fi

nodes=\$(sed -n 's|^nodes=||p' "\$STATE" | head -n1)
for addr in \$nodes; do
    [ -n "\$addr" ] || continue
    tgt=\$(tgt_for "\$addr") || continue
    cur=\$(cat geosite.dat | ssh -i "\$KEY" \$tgt -o BatchMode=yes -o ConnectTimeout=10 \\
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="\$KH" -o IdentitiesOnly=yes \\
        "sha256sum /opt/remnanode/\$FILE 2>/dev/null | cut -d' ' -f1" 2>/dev/null)
    [ "\$cur" = "\$got" ] && continue
    if cat geosite.dat | ssh -i "\$KEY" \$tgt -o BatchMode=yes -o ConnectTimeout=10 \\
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="\$KH" -o IdentitiesOnly=yes \\
        "cat > /opt/remnanode/\$FILE" 2>/dev/null; then
        changed="\$changed \$addr"
        log "remote \$addr updated"
    fi
done
rm -rf "\$TMP"

# xray reads geodata at config load: restart the nodes only when a file
# changed, quiet days cost nothing.
[ -n "\$changed" ] || exit 0
TOKEN=\$(cat "\$DIR/token" 2>/dev/null)
if [ -z "\$TOKEN" ]; then
    log "file updated, panel token missing — restart skipped until any config change"
    exit 0
fi
# Same headers as make_api_request: the panel's JWT guard rejects the saved
# login token without the browser client-type header. The token rides in a
# header file, not argv.
resp=\$(curl -s --connect-timeout 10 --max-time 30 \\
    -H @<(printf 'Authorization: Bearer %s\nContent-Type: application/json\nX-Forwarded-For: 127.0.0.1\nX-Forwarded-Proto: https\nX-Remnawave-Client-Type: browser\n' "\$TOKEN") \\
    "http://127.0.0.1:3000/api/nodes" 2>/dev/null)
if ! echo "\$resp" | jq -e '.response' >/dev/null 2>&1; then
    log "panel node list failed - restart skipped, answer: \${resp:0:200}"
    exit 1
fi
for addr in \$nodes; do
    [ -n "\$addr" ] || continue
    uuid=\$(uuid_for "\$addr")
    [ -n "\$uuid" ] || continue
    curl -sf --max-time 30 -X POST \\
        -H @<(printf 'Authorization: Bearer %s\nX-Forwarded-For: 127.0.0.1\nX-Forwarded-Proto: https\nX-Remnawave-Client-Type: browser\n' "\$TOKEN") \\
        "http://127.0.0.1:3000/api/nodes/\$uuid/actions/restart" >/dev/null 2>&1 \\
        && log "node \$addr restarted" || log "node \$addr restart failed"
done
UPD
    chmod 700 "${SR_CONF_DIR}/ruex-update.sh"
}

# Regenerate the updater when its marker is stale; called wherever ruex rules
# re-run, so fixes reach boxes that enabled ruex long ago.
sr_ruex_ensure_updater() {
    [ -f "${SR_CONF_DIR}/ruex-update.sh" ] || return 0
    head -3 "${SR_CONF_DIR}/ruex-update.sh" 2>/dev/null | grep -qF "$SR_RUEX_UPDATER_MARKER" && return 0
    sr_ruex_write_updater
}

sr_ruex_enable() {
    local nodes addr resolved local_ip compose tmpd touched=""
    nodes=$(sr_ruex_entry_nodes)
    if [ -z "$nodes" ]; then
        echo -e "${COLOR_RED}${LANG[SR_RUEX_NO_NODES]}${COLOR_RESET}"
        return 1
    fi

    step_do "${LANG[SR_RUEX_DOWNLOADING]}"
    tmpd=$(mktemp -d)
    if ! sr_ruex_download "$tmpd"; then
        rm -rf "$tmpd"
        echo -e "${COLOR_RED}${LANG[SR_RUEX_DOWNLOAD_FAIL]}${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[SR_RUEX_DOWNLOAD_OK]}"

    local_ip=$(sr_panel_public_ip)
    for addr in $nodes; do
        resolved=$(dig +short A "$addr" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1)
        [ -n "$resolved" ] || resolved="$addr"
        compose=$(sr_ruex_local_compose)
        # Local entry node: the address is this box, or it is private
        # (docker-gateway placeholder of a single-box install) while this
        # box does run the node.
        if [ -n "$compose" ] && { [ "$addr" = "$local_ip" ] || [ "$resolved" = "$local_ip" ] \
             || ! sr_public_ipv4 "$addr" >/dev/null; }; then
            step_do "${LANG[SR_RUEX_MOUNT_LOCAL]}"
            cp -f "$tmpd/geosite.dat" "$(dirname "$compose")/${SR_RUEX_FILE}"
            sr_ruex_compose_add "$compose"
            if (cd "$(dirname "$compose")" && docker compose up -d) >/dev/null 2>&1 \
               && docker exec remnanode test -s "/usr/local/share/xray/${SR_RUEX_FILE}" >/dev/null 2>&1; then
                touched="${touched:+$touched }$addr"
            else
                echo -e "${COLOR_RED}$(printf "${LANG[SR_RUEX_MOUNT_FAIL]}" "$addr")${COLOR_RESET}"
            fi
        elif re_target_load_by_host "$addr" && re_run_host_n "$addr" "test -f /opt/remnanode/docker-compose.yml"; then
            step_do "$(printf "${LANG[SR_RUEX_MOUNT_REMOTE]}" "$addr")"
            if cat "$tmpd/geosite.dat" | re_run_host "$addr" "cat > /opt/remnanode/${SR_RUEX_FILE}" \
               && re_run_host_n "$addr" "grep -q geosite-ruex /opt/remnanode/docker-compose.yml || sed -i '\|/var/log/remnanode|i\\      - ./${SR_RUEX_FILE}:/usr/local/share/xray/${SR_RUEX_FILE}' /opt/remnanode/docker-compose.yml" \
               && re_run_host_n "$addr" "cd /opt/remnanode && docker compose up -d" >/dev/null 2>&1 \
               && re_run_host_n "$addr" "docker exec remnanode test -s /usr/local/share/xray/${SR_RUEX_FILE}" >/dev/null 2>&1; then
                touched="${touched:+$touched }$addr"
            else
                echo -e "${COLOR_RED}$(printf "${LANG[SR_RUEX_MOUNT_FAIL]}" "$addr")${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_YELLOW}$(printf "${LANG[SR_RUEX_NO_SSH]}" "$addr")${COLOR_RESET}"
        fi
    done
    rm -rf "$tmpd"

    if [ -z "$touched" ]; then
        echo -e "${COLOR_RED}${LANG[SR_RUEX_MOUNT_FAIL_ALL]}${COLOR_RESET}"
        return 1
    fi

    step_do "${LANG[SR_RUEX_RULES]}"
    sr_ruex_switch_rules on
    step_ok "$(printf "${LANG[SR_RUEX_RULES_OK]}" "$SR_RUEX_SWITCHED")"

    sr_ruex_state_set enabled "yes"
    sr_ruex_state_set nodes "$touched"
    sr_ruex_write_updater
    add_cron_rule "30 4 * * * bash ${SR_CONF_DIR}/ruex-update.sh"
    step_ok "$(printf "${LANG[SR_RUEX_ON_OK]}" "$touched")"
    echo -e "${COLOR_GRAY}${LANG[SR_RUEX_CRON_OK]}${COLOR_RESET}"
    return 0
}

sr_ruex_disable() {
    if ! reading_yn "${LANG[SR_RUEX_OFF_CONFIRM]}" confirm_ruex_off; then
        return 1
    fi
    step_do "${LANG[SR_RUEX_OFF_STEP]}"
    sr_ruex_switch_rules off

    local addr compose
    for addr in $(sr_ruex_state_get nodes); do
        [ -n "$addr" ] || continue
        compose=$(sr_ruex_local_compose)
        if [ -n "$compose" ]; then
            sr_ruex_compose_del "$compose"
            rm -f "$(dirname "$compose")/${SR_RUEX_FILE}"
            (cd "$(dirname "$compose")" && docker compose up -d) >/dev/null 2>&1
        elif re_target_load_by_host "$addr"; then
            re_run_host "$addr" "sed -i '\|geosite-ruex.dat|d' /opt/remnanode/docker-compose.yml; rm -f /opt/remnanode/${SR_RUEX_FILE}; cd /opt/remnanode && docker compose up -d" >/dev/null 2>&1
        fi
    done
    rm -f "$SR_RUEX_STATE"
    crontab -u root -l 2>/dev/null | grep -v "ruex-update.sh" | crontab -u root - 2>/dev/null
    rm -f "${SR_CONF_DIR}/ruex-update.sh" "${SR_CONF_DIR}/ruex-update.log"
    step_ok "${LANG[SR_RUEX_OFF_OK]}"
    return 0
}

sr_ruex_toggle() {
    load_api_module || return 1
    load_remote_exec_module || return 1
    if sr_ruex_enabled; then
        get_panel_token && sr_ruex_disable
    else
        get_panel_token && sr_ruex_enable
    fi
}

# Gray "(настроено: N)" suffix for the chooser items; silent when zero.
sr_kind_count_suffix() {
    [ "$1" -gt 0 ] 2>/dev/null || return 0
    printf " $(printf "${LANG[SR_KIND_COUNT]}" "$1")"
}

# Top level: which kind of bridge. The two flows share the exit machinery
# but answer different questions — country split for everyone at once vs a
# named exit per user.
show_server_routing_menu() {
    sr_migrate_legacy
    local geo_n=0 route_n=0 slug t
    while IFS= read -r slug; do
        [ -n "$slug" ] || continue
        t=$(sr_bridge_type "$slug")
        if [ "$t" = "route" ]; then
            route_n=$((route_n + 1))
        else
            geo_n=$((geo_n + 1))
        fi
    done < <(sr_bridges_list)

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_DOC_LINK]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${COLOR_WHITE}${LANG[SR_KIND_GEO]}${COLOR_RESET}${COLOR_GRAY}$(sr_kind_count_suffix "$geo_n")${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_KIND_GEO_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${COLOR_WHITE}${LANG[SR_KIND_ROUTE]}${COLOR_RESET}${COLOR_GRAY}$(sr_kind_count_suffix "$route_n")${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_KIND_ROUTE_HINT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" SR_OPTION

    case $SR_OPTION in
        1)
            sr_show_geo_menu
            ;;
        2)
            sr_show_route_menu
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
}

# Geo bridges: the country split. One line per bridge, plus the entry
# point for a brand-new one.
sr_show_geo_menu() {
    sr_migrate_legacy
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_TITLE_GEO]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_DOC_LINK]}${COLOR_RESET}"
    echo -e ""

    local names=() name pick i host port label
    while IFS= read -r name; do
        [ -n "$name" ] && [ "$(sr_bridge_type "$name")" = "geo" ] && names+=("$name")
    done < <(sr_bridges_list)

    if [ "${#names[@]}" -eq 0 ]; then
        echo -e " ${COLOR_GRAY}${LANG[SR_STATUS_NOT_CONFIGURED]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[SR_MENU_SETUP]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 1)" SR_OPTION

        case $SR_OPTION in
            1)
                sr_setup fresh
                sleep 2
                sr_show_geo_menu
                ;;
            0)
                return 0
                ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 1
                sleep 1
                sr_show_geo_menu
                ;;
        esac
        return 0
    fi

    echo -e " ${COLOR_GRAY}$(printf "${LANG[SR_BRIDGES_COUNT]}" "${#names[@]}")${COLOR_RESET}"
    if sr_ruex_enabled; then
        echo -e " ${COLOR_GRAY}${LANG[SR_RUEX_STATUS_ON]}${COLOR_RESET}"
    fi
    echo -e ""
    i=1
    for name in "${names[@]}"; do
        SR_CURRENT="$name"
        label=$(sr_state_get bridge_name)
        [ -n "$label" ] || label="$name"
        host=$(sr_state_get host)
        port=$(sr_state_get port)
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}$(sr_cap_first "$label")${COLOR_RESET} ${COLOR_GRAY}(${host}:${port})${COLOR_RESET}"
        i=$((i + 1))
    done
    local new=$i
    echo -e "${COLOR_YELLOW}${new}. ${LANG[SR_BRIDGE_NEW]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$new")" SR_OPTION

    case $SR_OPTION in
        0)
            return 0
            ;;
        "$new")
            sr_setup fresh
            sleep 2
            sr_show_geo_menu
            ;;
        *)
            if [ "$SR_OPTION" -ge 1 ] 2>/dev/null && [ "$SR_OPTION" -le "${#names[@]}" ]; then
                sr_bridge_menu "${names[$((SR_OPTION - 1))]}"
                sleep 1
                sr_show_geo_menu
            else
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$new"
                sleep 1
                sr_show_geo_menu
            fi
            ;;
    esac
}

# Route bridges: per-user exits. Same shape as the geo list, but every
# line carries the bridge's route number.
sr_show_route_menu() {
    sr_migrate_legacy
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_TITLE_ROUTE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_ROUTE_DOC_LINK]}${COLOR_RESET}"
    echo -e ""

    local names=() name pick i host port label rno
    while IFS= read -r name; do
        [ -n "$name" ] && [ "$(sr_bridge_type "$name")" = "route" ] && names+=("$name")
    done < <(sr_bridges_list)

    if [ "${#names[@]}" -eq 0 ]; then
        echo -e " ${COLOR_GRAY}${LANG[SR_ROUTE_NONE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[SR_MENU_SETUP]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 1)" SR_OPTION

        case $SR_OPTION in
            1)
                sr_setup_route fresh
                sleep 2
                sr_show_route_menu
                ;;
            0)
                return 0
                ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 1
                sleep 1
                sr_show_route_menu
                ;;
        esac
        return 0
    fi

    echo -e " ${COLOR_GRAY}$(printf "${LANG[SR_BRIDGES_COUNT]}" "${#names[@]}")${COLOR_RESET}"
    echo -e ""
    i=1
    for name in "${names[@]}"; do
        SR_CURRENT="$name"
        label=$(sr_state_get bridge_name)
        [ -n "$label" ] || label="$name"
        host=$(sr_state_get host)
        port=$(sr_state_get port)
        rno=$(sr_state_get route_no)
        [ -n "$rno" ] || rno="?"
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}$(sr_cap_first "$label")${COLOR_RESET} ${COLOR_GRAY}(${LANG[SR_ROUTE_WORD]} ${rno}, ${host}:${port})${COLOR_RESET}"
        i=$((i + 1))
    done
    local new=$i
    echo -e "${COLOR_YELLOW}${new}. ${LANG[SR_BRIDGE_NEW]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$new")" SR_OPTION

    case $SR_OPTION in
        0)
            return 0
            ;;
        "$new")
            sr_setup_route fresh
            sleep 2
            sr_show_route_menu
            ;;
        *)
            if [ "$SR_OPTION" -ge 1 ] 2>/dev/null && [ "$SR_OPTION" -le "${#names[@]}" ]; then
                sr_route_bridge_menu "${names[$((SR_OPTION - 1))]}"
                sleep 1
                sr_show_route_menu
            else
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$new"
                sleep 1
                sr_show_route_menu
            fi
            ;;
    esac
}

# Per-bridge menu for a route bridge: host visibility, re-setup, rename,
# teardown. Everything acts on the bridge it was opened for.
sr_route_bridge_menu() {
    local name="$1"
    SR_CURRENT="$name"
    [ -f "$(sr_state_file)" ] || return 1
    local label rno remark hidden=""
    label=$(sr_state_get bridge_name)
    [ -n "$label" ] || label="$name"
    rno=$(sr_state_get route_no)
    [ -n "$rno" ] || rno="?"

    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[SR_ROUTE_MENU_TITLE]}" "$(sr_cap_first "$label")")${COLOR_RESET} ${COLOR_GRAY}(${LANG[SR_ROUTE_WORD]} ${rno})${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_ROUTE_DOC_LINK]}${COLOR_RESET}"
    echo -e ""
    sr_status_live
    remark=$(sr_state_get host_remark)
    local live_uuid
    live_uuid=$(sr_state_get host_uuid)
    # An empty (stub bridge) or malformed uuid would hit /api/hosts/ as a
    # LIST request — the panel answers with an array and the field lookups
    # below explode with "Cannot index array". Query only a real uuid.
    if sr_saved_token_works && [[ "$live_uuid" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        local response
        response=$(sr_api "GET" "/api/hosts/$live_uuid" 2>/dev/null)
        remark=$(echo "$response" | jq -r '.response.remark // empty')
        [ "$(echo "$response" | jq -r '.response.isDisabled // empty')" = "true" ] && hidden=yes
    fi
    if [ -n "$remark" ]; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[SR_ROUTE_STATUS_HOST]}" "$remark")${COLOR_GRAY}${hidden:+ ${LANG[SR_ROUTE_STATUS_HOST_HIDDEN]}}${COLOR_RESET}"
    fi
    echo -e ""

    local toggle_label
    if [ "$hidden" = "yes" ]; then
        toggle_label="${LANG[SR_ROUTE_MENU_HOST_SHOW]}"
    else
        toggle_label="${LANG[SR_ROUTE_MENU_HOST_HIDE]}"
    fi

    echo -e "${COLOR_YELLOW}1. ${toggle_label}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_ROUTE_MENU_HOST_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[SR_MENU_ATTACH]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_ROUTE_MENU_ATTACH_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[SR_MENU_SETUP_AGAIN]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_ROUTE_MENU_SETUP_AGAIN_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[SR_MENU_RENAME]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_ROUTE_MENU_RENAME_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[SR_MENU_TEARDOWN]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_ROUTE_MENU_TEARDOWN_HINT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 5)" SR_OPTION

    case $SR_OPTION in
        1)
            if get_panel_token; then
                sr_route_toggle_host
            fi
            sleep 2
            sr_route_bridge_menu "$name"
            ;;
        2)
            sr_route_attach_profile
            sleep 2
            sr_route_bridge_menu "$name"
            ;;
        3)
            sr_setup_route
            sleep 2
            sr_route_bridge_menu "$name"
            ;;
        4)
            if get_panel_token; then
                sr_rename_bridge
            fi
            sleep 2
            sr_route_bridge_menu "$name"
            ;;
        5)
            if reading_yn "${LANG[SR_TEARDOWN_CONFIRM]}" confirm_teardown; then
                if get_panel_token; then
                    sr_teardown_route
                fi
            fi
            sleep 2
            ;;
        0)
            return 0
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 5
            sleep 1
            sr_route_bridge_menu "$name"
            ;;
    esac
}

# Per-bridge menu: everything acts on the bridge it was opened for.
sr_bridge_menu() {
    local name="$1"
    SR_CURRENT="$name"
    [ -f "$(sr_state_file)" ] || return 1
    local label
    label=$(sr_state_get bridge_name)
    [ -n "$label" ] || label="$name"

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SR_TITLE_GEO]}: ${COLOR_WHITE}$(sr_cap_first "$label")${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[SR_DOC_LINK]}${COLOR_RESET}"
    echo -e ""
    sr_status_live
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SR_MENU_ATTACH]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_MENU_ATTACH_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. $(sr_ruex_menu_label)${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_RUEX_MENU_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[SR_MENU_SETUP_AGAIN]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_MENU_SETUP_AGAIN_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[SR_MENU_RENAME]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_MENU_RENAME_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[SR_MENU_TEARDOWN]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[SR_MENU_TEARDOWN_HINT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 5)" SR_OPTION

    case $SR_OPTION in
        1)
            sr_attach_profile
            sleep 2
            sr_bridge_menu "$name"
            ;;
        2)
            sr_ruex_toggle
            sleep 2
            sr_bridge_menu "$name"
            ;;
        3)
            sr_setup
            sleep 2
            sr_bridge_menu "$name"
            ;;
        4)
            if get_panel_token; then
                sr_rename_bridge
            fi
            sleep 2
            sr_bridge_menu "$name"
            ;;
        5)
            if reading_yn "${LANG[SR_TEARDOWN_CONFIRM]}" confirm_teardown; then
                if get_panel_token; then
                    sr_teardown
                fi
            fi
            sleep 2
            ;;
        0)
            return 0
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 5
            sleep 1
            sr_bridge_menu "$name"
            ;;
    esac
}

# Bridge-menu label for the RU-lists toggle: shows the current state and
# where the press leads, so "restore the stock lists" is discoverable.
sr_ruex_menu_label() {
    if sr_ruex_enabled; then
        echo "${LANG[SR_RUEX_MENU_ON]}"
    else
        echo "${LANG[SR_RUEX_MENU_OFF]}"
    fi
}

manage_server_routing() {
    # sr_status_live talks to the panel from the menu header already, so the
    # API module (get_panel_token / make_api_request / err_msg) must be in
    # place before any menu renders — not only inside sr_setup.
    load_api_module || return 1
    sr_migrate_legacy
    show_server_routing_menu
}
