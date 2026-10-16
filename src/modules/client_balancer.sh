#!/bin/bash
# Module: client_balancer — client-side host balancing via panel XRAY_JSON
# https://docs.rw/learn/xray-json-advanced/ and
# https://xtls.github.io/config/routing.html (BalancerObject).
#
# The panel assembles ONE Xray JSON config for the subscription: hidden
# clones of the picked hosts are injected as outbounds and the CLIENT's
# burstObservatory/leastLoad picks the fastest one. Each clone keeps its
# ORIGINAL inbound, so the panel renders it with its own transport and
# reality keys and the pool may mix inbounds (RAW + GRPC + XHTTP + bridges).
# Nodes are never touched: nothing is switched, nothing sleeps. A vlessRoute
# clone keeps the route marker, so bridge members keep routing through their
# exit. Regular subscription types and Xray Checker never see the wrapper
# (excluded from every type except XRAY_JSON) nor the hidden clones (hidden
# hosts leave all subscriptions) — this is by design.

# One file per balancer in this directory; the filename slug is the
# balancer's stable internal id (the display name can be renamed freely).
CB_CONF_DIR="${DIR_REMNAWAVE}client-balancer"
CB_PANEL_HOST="127.0.0.1:3000"
# Profile names are latin-only on the panel (validated), so the dedicated
# balancer profile carries this fixed name; the user-facing name lives on
# the wrapper host remark instead.
CB_PROFILE_NAME="Balancer"
# Every host this session created (failed PATCHes included), so the
# setup cleanup can delete exactly what it spawned.
CB_CLONES_MADE=()
CB_VHOST_MADE=""
CB_CURRENT=""
CB_HOSTS_JSON=""
CB_PROFILES_JSON=""

# --- client type ----------------------------------------------------------------------

# Xray JSON balancing rides the client's leastLoad core, mihomo balancing is
# a native url-test/fallback group injected into the Default MIHOMO template
# (panel renders the group with the subscription's hosts). Sets
# CB_CLIENT ("xray" | "mihomo"); rc 1 on a walk-away.
cb_pick_client() {
    CB_CLIENT="xray"
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CB_CLIENT_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${COLOR_WHITE}${LANG[CB_CLIENT_XRAY]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_CLIENT_XRAY_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${COLOR_WHITE}${LANG[CB_CLIENT_MIHOMO]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_CLIENT_MIHOMO_HINT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local pick
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" pick || { echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1; }
    case "$pick" in
        1) CB_CLIENT="xray"; return 0 ;;
        2) CB_CLIENT="mihomo"; return 0 ;;
        0) echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1 ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2
            sleep 1
            cb_pick_client
            return $?
            ;;
    esac
}

# --- mihomo: группа в Default MIHOMO шаблоне -------------------------------------------

# The panel renders ONE mihomo template for every user, so a mihomo
# "balancer" is a proxy-group surgically added into the Default MIHOMO
# template: url-test for the fastest preset, an ordered fallback list for
# the reserve one. Each group carries a "# cb:<slug>" marker comment for
# reliable replace/remove; the rest of the template is never touched.

cb_mh_yaml_quote() {
    # Double-quoted YAML scalar: escape backslash and the quote only.
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

cb_mh_fetch_default() {
    local response uuid
    response=$(cb_api "GET" "/api/subscription-templates?_=$(date +%s)")
    CB_MH_TEMPLATE_UUID=$(echo "$response" | jq -r '.response.templates[]? | select(.templateType == "MIHOMO" and .name == "Default") | .uuid' | head -n1)
    [ -n "$CB_MH_TEMPLATE_UUID" ] || { err_msg "$(printf "${LANG[CB_MH_FAIL]}" "Default MIHOMO template not found")"; return 1; }
    response=$(cb_api "GET" "/api/subscription-templates/$CB_MH_TEMPLATE_UUID")
    CB_MH_YAML=$(echo "$response" | jq -r '.response.encodedTemplateYaml // empty' | base64 -d 2>/dev/null)
    [ -n "$CB_MH_YAML" ] || { err_msg "$(printf "${LANG[CB_MH_FAIL]}" "template body is empty")"; return 1; }
    grep -q "^proxy-groups:" <<< "$CB_MH_YAML" || { err_msg "$(printf "${LANG[CB_MH_FAIL]}" "no proxy-groups section")"; return 1; }
}

# Build the group block from CB_MH_GROUP_NAME, CB_PRESET and the ordered
# remark lists CB_MH_MAIN_REMARKS / CB_MH_BACKUP_REMARKS into CB_MH_BLOCK.
# Manual ordered lists (remnawave: include-proxies: false) keep the pool and
# its order fully ours: the panel appends nothing on its own.
cb_mh_build_block() {
    local name type line r
    name=$(cb_mh_yaml_quote "$CB_MH_GROUP_NAME")
    if [ "$CB_PRESET" = "reserve" ]; then
        type="fallback"
    else
        type="url-test"
    fi
    CB_MH_BLOCK="  - name: \"$name\" # cb:$CB_CURRENT"$'\n'"    type: $type"
    CB_MH_BLOCK="$CB_MH_BLOCK"$'\n'"    url: 'https://cp.cloudflare.com/generate_204'"$'\n'"    interval: 30"
    if [ "$CB_PRESET" != "reserve" ]; then
        CB_MH_BLOCK="$CB_MH_BLOCK"$'\n'"    tolerance: 150"
    fi
    CB_MH_BLOCK="$CB_MH_BLOCK"$'\n'"    remnawave:"$'\n'"      include-proxies: false"$'\n'"    proxies:"
    # Line-by-line: remarks may contain spaces, and a word-split loop would
    # turn one name into several phantom group entries.
    while IFS= read -r r; do
        [ -n "$r" ] || continue
        CB_MH_BLOCK="$CB_MH_BLOCK"$'\n'"      - \"$(cb_mh_yaml_quote "$r")\""
    done <<< "$CB_MH_MAIN_REMARKS"$'\n'"$CB_MH_BACKUP_REMARKS"
    [ -n "$CB_MH_BLOCK" ]
}

# Replace (or insert) our block in CB_MH_YAML. Line surgery only: the old
# copy spans from its "# cb:<slug>" marker line to the next group or
# top-level key; the fresh block lands right after "proxy-groups:". The
# marker match is anchored to the line end: slugs may be prefixes of each
# other ("name" and "name-1" after a same-name rerun), and a bare substring
# match would eat the sibling's group too.
cb_mh_apply_block() {
    CB_MH_YAML=$(printf '%s\n' "$CB_MH_YAML" | awk -v block="$CB_MH_BLOCK" -v slug="$CB_CURRENT" '
        BEGIN { split(block, bl, "\n") }
        $0 ~ (" # cb:" slug "$") { skip = 1; next }
        skip {
            if ($0 ~ /^  - / || $0 ~ /^[A-Za-z][A-Za-z0-9-]*:/) { skip = 0 } else { next }
        }
        /^proxy-groups:$/ && !done {
            print
            for (i = 1; i in bl; i++) if (bl[i] != "") print bl[i]
            done = 1
            next
        }
        { print }
        END { if (!done) exit 9 }
    ') || return 1
    [ -n "$CB_MH_YAML" ]
}

cb_mh_patch() {
    local enc response stored
    enc=$(printf '%s' "$CB_MH_YAML" | base64 -w0)
    response=$(cb_api "PATCH" "/api/subscription-templates" \
        "$(jq -nc --arg uuid "$CB_MH_TEMPLATE_UUID" --arg yaml "$enc" '{uuid: $uuid, encodedTemplateYaml: $yaml}')")
    # The panel echoes the stored template: verify the marker made it. The
    # pattern is end-anchored so a slug that prefixes another slug ("name"
    # vs "name-1") cannot verify against the sibling's marker.
    stored=$(echo "$response" | jq -r '.response.encodedTemplateYaml // empty' | base64 -d 2>/dev/null)
    if [ "${1:-present}" = "absent" ]; then
        grep -q " # cb:${CB_CURRENT}\$" <<< "$stored" && return 1
        return 0
    fi
    grep -q " # cb:${CB_CURRENT}\$" <<< "$stored"
}

# Mihomo groups address hosts by NAME, and the panel renames duplicates
# ("X" stays, the second becomes "X ^~2~^", the order depends on the
# per-user shuffle): a picked host sharing its remark with ANY other host
# (hidden ones included: they still consume the plain name) makes the group
# reference the wrong host or a name that never renders, and the client
# rejects the whole config. Refuse such picks outright.
cb_mh_dup_check() { # $1 = space-separated picked uuids
    local uuid remark cnt bad=""
    for uuid in $1; do
        remark=$(printf '%s' "$CB_HOSTS_JSON" | jq -r --arg u "$uuid" '.[] | select(.uuid == $u) | .remark')
        [ -n "$remark" ] || continue
        cnt=$(printf '%s' "$CB_HOSTS_JSON" | jq --arg r "$remark" '[.[] | select(.remark == $r)] | length')
        if [ "$cnt" -gt 1 ]; then
            case " $bad " in *" $remark "*) ;; *) bad="${bad:+$bad }$remark" ;; esac
        fi
    done
    [ -z "$bad" ] && return 0
    echo -e "${COLOR_RED}$(printf "${LANG[CB_MH_DUP]}" "$bad")${COLOR_RESET}"
    return 1
}

# Strip our block without inserting a fresh one (teardown). Marker match
# end-anchored, same reason as cb_mh_apply_block.
cb_mh_remove_block() {
    CB_MH_YAML=$(printf '%s\n' "$CB_MH_YAML" | awk -v slug="$CB_CURRENT" '
        $0 ~ (" # cb:" slug "$") { skip = 1; next }
        skip {
            if ($0 ~ /^  - / || $0 ~ /^[A-Za-z][A-Za-z0-9-]*:/) { skip = 0 } else { next }
        }
        { print }
    ')
    [ -n "$CB_MH_YAML" ]
}

# --- state ----------------------------------------------------------------------

cb_state_file() {
    printf '%s/%s.bal' "$CB_CONF_DIR" "${CB_CURRENT:-_none_}"
}

cb_state_get() {
    [ -n "$CB_CURRENT" ] || return 0
    local file
    file=$(cb_state_file)
    [ -r "$file" ] || return 0
    sed -n "s|^$1=||p" "$file" | head -n1
}

cb_state_set() {
    [ -n "$CB_CURRENT" ] || return 0
    local file val
    file=$(cb_state_file)
    mkdir -p "$CB_CONF_DIR"
    chmod 700 "$CB_CONF_DIR" 2>/dev/null
    touch "$file"
    chmod 600 "$file" 2>/dev/null
    if grep -q "^$1=" "$file"; then
        # The replacement is sed-interpreted: a remark typed with &, | or a
        # backslash would corrupt the state line (and the remark IS free
        # user input).
        val=$(printf '%s\n' "$2" | sed -e 's/[\\|&]/\\&/g')
        sed -i "s|^$1=.*|$1=$val|" "$file"
    else
        echo "$1=$2" >> "$file"
    fi
}

cb_state_clear() {
    [ -n "$CB_CURRENT" ] || return 0
    rm -f "$(cb_state_file)"
}

# Every configured balancer slug, one per line.
cb_balancers_list() {
    local f
    for f in "$CB_CONF_DIR"/*.bal; do
        [ -f "$f" ] || continue
        basename "$f" .bal
    done
}

# Latin/dash slug from any input (Cyrillic collapses to nothing).
cb_slug() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9-' '-' \
        | sed -e 's/^-*//' -e 's/-*$//' | cut -c1-24
}

cb_cap_first() {
    # ${var^} uppercases in place: under a non-UTF-8 locale it leaves a
    # Cyrillic first letter as it is instead of slicing a byte off it.
    printf '%s' "${1^}"
}

# --- api ------------------------------------------------------------------------

cb_api() {
    local method="$1" path="$2" data="${3:-}"
    make_api_request "$method" "http://${CB_PANEL_HOST}${path}" "$token" "$data"
}

cb_rand() {
    tr -dc 'a-z0-9' < /dev/urandom | head -c "${1:-4}"
}

cb_saved_token_works() {
    local token_file="${DIR_REMNAWAVE}token"
    [ -r "$token_file" ] || return 1
    token=$(cat "$token_file")
    cb_api "GET" "/api/config-profiles" | jq -e '.response.configProfiles' >/dev/null 2>&1
}

# The panel must be 2.6.3+ (injectHosts directives). Read from the compose
# tag, no docker calls — this runs on every menu render path. A bare "2"
# floats at the end of the 2.x line (>= 2.6.3), tags of unknown shape are
# let through and the API itself will speak up if the feature is missing.
cb_panel_version_ok() {
    local tag lowest
    tag=$(panel_image_tag "/opt/remnawave" 2>/dev/null) || tag=""
    case "$tag" in
        ""|1|1.*) return 1 ;;
        2|3|3.*|4.*|latest|dev) return 0 ;;
        2.*)
            lowest=$(printf '%s\n' "$tag" "2.6.3" | sort -V | head -n1)
            [ "$lowest" = "2.6.3" ]
            ;;
        *) return 0 ;;
    esac
}

# Xray JSON clients receive the balancer config from the base subscription
# path only when the panel serves JSON there; without the flag the full
# config arrives solely by the /v2ray-json suffix link. Enabled through
# the panel API: already-on stays silent, a failure prints the manual
# path and the wizard carries on (the suffix link keeps working).
cb_ensure_json_base() {
    local response uuid value
    response=$(cb_api "GET" "/api/subscription-settings?_=$(date +%s)")
    if ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}${LANG[CB_JSON_BASE_MANUAL]}${COLOR_RESET}"
        return 0
    fi
    value=$(echo "$response" | jq -r '.response.serveJsonAtBaseSubscription // empty')
    [ "$value" = "true" ] && return 0
    uuid=$(echo "$response" | jq -r '.response.uuid')
    response=$(cb_api "PATCH" "/api/subscription-settings" \
        "$(jq -nc --arg u "$uuid" '{uuid: $u, serveJsonAtBaseSubscription: true}')")
    if echo "$response" | jq -e '.response.serveJsonAtBaseSubscription == true' >/dev/null 2>&1; then
        echo -e "${COLOR_GREEN}${LANG[CB_JSON_BASE_ENABLED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[CB_JSON_BASE_MANUAL]}${COLOR_RESET}"
    fi
    return 0
}

# --- original hosts visibility ---------------------------------------------------
#
# The wrapper replaces a whole list of hosts with ONE subscription entry, so
# the picked originals are hidden for the balancer's lifetime (they keep
# WORKING — nothing on the nodes changes — they just leave the subscription
# listing). Hosts that were VISIBLE before the wizard get hidden and tracked
# in the state; the teardown brings them back. Hosts the admin had hidden
# earlier are never touched, and a host stays hidden while another balancer
# still lists it.

cb_host_set_hidden() { # $1 host uuid, $2 true|false
    local response
    response=$(cb_api "PATCH" "/api/hosts" "$(jq -nc --arg u "$1" --argjson v "$2" '{uuid: $u, isHidden: $v}')")
    echo "$response" | jq -e --argjson v "$2" --arg u "$1" '.response.uuid == $u and .response.isHidden == $v' >/dev/null 2>&1
}

cb_hide_originals() { # $1 = source uuid list
    local src todo="" hidden=0
    for src in $1; do
        [ "$(printf '%s' "$CB_HOSTS_JSON" | jq -r --arg h "$src" '.[] | select(.uuid == $h) | .isHidden')" = "false" ] || continue
        todo="${todo:+$todo }$src"
    done
    [ -n "$todo" ] || return 0
    step_do "${LANG[CB_HIDE_STEP]}"
    for src in $todo; do
        if cb_host_set_hidden "$src" true; then
            hidden=$((hidden + 1))
            cb_state_set hidden_srcs "$(printf '%s\n' $(cb_state_get hidden_srcs) "$src" | awk 'NF' | sort -u | tr '\n' ' ')"
        fi
    done
    step_ok "$(printf "${LANG[CB_HIDE_OK]}" "$hidden")"
    return 0
}

cb_src_in_other_balancer() { # $1 source uuid
    local f
    for f in "$CB_CONF_DIR"/*.bal; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "${CB_CURRENT}.bal" ] && continue
        awk -v u="$1" 'BEGIN{FS="="} $1=="orig_srcs"{n=split($2,a," "); for(i=1;i<=n;i++) if(a[i]==u) found=1} END{exit !found}' "$f" && return 0
    done
    return 1
}

cb_unhide_originals() {
    local list uuid back=0
    list=$(cb_state_get hidden_srcs)
    [ -n "$list" ] || return 0
    step_do "${LANG[CB_UNHIDE_STEP]}"
    for uuid in $list; do
        cb_src_in_other_balancer "$uuid" && continue
        cb_host_set_hidden "$uuid" false && back=$((back + 1))
    done
    step_ok "$(printf "${LANG[CB_UNHIDE_OK]}" "$back")"
    return 0
}

# Full host list (the panel endpoint takes no filters). Wrapper hosts of
# every balancer (ours) are collected here too: their vhost_uuid state lines
# feed the eligibility filter, because a wrapper is a clone of a member and
# must never become a member itself.
cb_fetch_hosts() {
    local response
    response=$(cb_api "GET" "/api/hosts?_=$(date +%s)")
    # Type check, not truthiness: jq -e treats [] as false, and an empty
    # host list is a valid state (a fresh panel), not an API failure.
    if [ -z "$response" ] || ! echo "$response" | jq -e '(.response | type) == "array"' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    CB_HOSTS_JSON=$(echo "$response" | jq -c '.response')
    CB_WRAPPER_UUIDS=$(awk -F= '/^vhost_uuid=/{printf "%s ", $2}' "$CB_CONF_DIR"/*.bal 2>/dev/null | sed 's/ $//')
}

cb_fetch_profiles() {
    local response
    response=$(cb_api "GET" "/api/config-profiles?_=$(date +%s)")
    if [ -z "$response" ] || ! echo "$response" | jq -e '(.response.configProfiles | type) == "array"' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    CB_PROFILES_JSON=$(echo "$response" | jq -c '.response.configProfiles')
}

# --- eligible hosts ---------------------------------------------------------------
#
# Members are HIDDEN CLONES of existing hosts — the originals stay visible
# in every subscription and untouched. Which hosts may become members:
#   enabled, no "CB:CLONE" tag (ours: clones of any balancer and the wrapper
#   host cloned from a member both carry it) and not on a legacy pre-3.9
#   "Balancer" profile. A host with its OWN XRAY_JSON template IS offered:
#   hand-tuned hosts behind a CDN ride their client settings exactly there,
#   and the clone keeps the template along (the "template" marker flags it
#   in the picker). Hidden hosts ARE offered for Xray JSON (the clone stays
#   hidden and hidden is exactly what injectHosts selects from) and so are
#   vlessRoute bridge hosts: the clone keeps its own inbound and the route
#   marker, so bridges keep routing through their exit. Mihomo groups name
#   VISIBLE hosts only — hidden entries never render there, so the mihomo
#   pickers keep hidden hosts out.
# $1 = inbound uuid filter ("" = no filter), $2 = "hidden" to include
# hidden hosts. Lines: uuid \t remark \t address \t sni \t inbound \t
# profile \t inbound label \t hidden flag \t route flag \t template flag.
cb_eligible_lines() {
    jq -nr --argjson hosts "$CB_HOSTS_JSON" --argjson profiles "$CB_PROFILES_JSON" --arg iu "${1:-}" --arg ih "${2:-}" --arg wr "${CB_WRAPPER_UUIDS:-}" '
        (($profiles | map(. as $p | .inbounds[]? | {key: (.uuid // ""), value: "\($p.name) / \(.tag // .uuid)"})) | from_entries) as $labels
        | ($profiles | map(select(.name == "Balancer" or ((.name // "") | startswith("Balancer ")))
                           | .inbounds[]?.uuid) | map(select(. != null))) as $legacy
        | ($wr | split(" ") | map(select(length > 0))) as $wrappers
        | $hosts[]
        | select(.isDisabled != true)
        | . as $h
        | (.inbound.configProfileInboundUuid // "") as $ib
        | select(($legacy | index($ib)) == null)
        | select((.tags // []) | index("CB:CLONE") == null)
        | select($ih == "hidden" or .isHidden != true)
        | select($iu == "" or $ib == $iu)
        | select($wrappers | index($h.uuid) == null)
        | "\(.uuid)\t\(.remark)\t\(.address // "")\t\(.sni // "")\t\($ib)\t\(.inbound.configProfileUuid // "")\t\($labels[$ib] // $ib)\t\(if .isHidden then "hidden" else "" end)\t\(if .vlessRouteId != null then "route" else "" end)\t\(if .xrayJsonTemplateUuid != null then "tpl" else "" end)"'
}

# --- pickers -----------------------------------------------------------------------

cb_pick_preset() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CB_PRESET_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${COLOR_WHITE}${LANG[CB_PRESET_BALANCER]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_PRESET_BALANCER_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${COLOR_WHITE}${LANG[CB_PRESET_RESERVE]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_PRESET_RESERVE_HINT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local pick
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" pick || { echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1; }
    case "$pick" in
        1) CB_PRESET="balancer"; return 0 ;;
        2) CB_PRESET="reserve"; return 0 ;;
        0) echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1 ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2
            sleep 1
            cb_pick_preset
            ;;
    esac
}

# Multi-pick of eligible hosts. During creation the list spans EVERY inbound
# (clones keep their own), inside a running balancer it is scoped to the
# balancer's inbound (legacy balancers only). Sets CB_PICKED_UUIDS (space
# separated, input order = outbound order), CB_PICKED_REMARKS and
# CB_PICKED_ENTRIES (full lines). $1 = min count, $2 = exclude list
# ("uuid uuid ..."), $3 = inbound filter, $4 = how many hosts must stay
# UNPICKED (the reserve preset needs one for its backup step, so the mains
# may not swallow the whole pool), $5 = "hidden" to offer hidden hosts too
# (Xray JSON only: mihomo groups name visible hosts).
cb_pick_members() {
    local min="$1" exclude="${2:-}" ibuf="${3:-}" keep="${4:-0}" hidden="${5:-}" entries=() entry pick i uuid remark addr label
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        uuid=$(echo "$entry" | cut -f1)
        case " $exclude " in *" $uuid "*) continue ;; esac
        entries+=("$entry")
    done < <(cb_eligible_lines "$ibuf" "$hidden")

    if [ "${#entries[@]}" -lt $((min + keep)) ]; then
        if [ "$keep" -gt 0 ]; then
            echo -e "${COLOR_RED}$(printf "${LANG[CB_PICK_RESERVE_SHORT]}" "$((min + keep))")${COLOR_RESET}"
        else
            echo -e "${COLOR_RED}${LANG[CB_PICK_NOHOSTS]}${COLOR_RESET}"
        fi
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${CB_PICK_TITLE}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${CB_PICK_HINT}${COLOR_RESET}"
    echo -e ""
    i=1
    for entry in "${entries[@]}"; do
        remark=$(echo "$entry" | cut -f2)
        addr=$(echo "$entry" | cut -f3)
        label=$(echo "$entry" | cut -f7)
        markers=""
        [ "$(echo "$entry" | cut -f8)" = "hidden" ] && markers="${LANG[CB_FLAG_HIDDEN]}"
        [ "$(echo "$entry" | cut -f9)" = "route" ] && markers="${markers:+$markers, }${LANG[CB_FLAG_ROUTE]}"
        [ "$(echo "$entry" | cut -f10)" = "tpl" ] && markers="${markers:+$markers, }${LANG[CB_FLAG_TEMPLATE]}"
        [ -n "$markers" ] && markers=" ${COLOR_GRAY}[${markers}]${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${remark}${COLOR_RESET} ${COLOR_GRAY}(${addr}) — ${label}${COLOR_RESET}${markers}"
        i=$((i + 1))
    done
    echo -e ""
    reading "$(printf "${LANG[CB_PICK_PROMPT]}" "$((i - 1))")" pick || { echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1; }

    # Comma separated numbers; the panel keeps the given order in the config.
    local nums=() n ok=1 seen
    pick="${pick// /}"
    IFS=',' read -ra parts <<< "$pick"
    for n in "${parts[@]}"; do
        if [ "$n" -ge 1 ] 2>/dev/null && [ "$n" -le "${#entries[@]}" ]; then
            seen=0
            for u in "${nums[@]:-}"; do [ "$u" = "$n" ] && seen=1; done
            [ "$seen" = "0" ] && nums+=("$n")
        else
            ok=0
            break
        fi
    done
    if [ "$ok" != "1" ] || [ "${#nums[@]}" -eq 0 ]; then
        printf "${COLOR_YELLOW}${LANG[CB_PICK_INVALID]}${COLOR_RESET}\n" "$((i - 1))"
        sleep 1
        cb_pick_members "$min" "$exclude" "$ibuf" "$keep" "$hidden"
        return $?
    fi
    if [ "${#nums[@]}" -lt "$min" ]; then
        printf "${COLOR_YELLOW}${LANG[CB_PICK_MIN]}${COLOR_RESET}\n" "$min"
        sleep 1
        cb_pick_members "$min" "$exclude" "$ibuf" "$keep" "$hidden"
        return $?
    fi
    if [ "$keep" -gt 0 ] && [ "${#nums[@]}" -gt $(( ${#entries[@]} - keep )) ]; then
        echo -e "${COLOR_YELLOW}${LANG[CB_PICK_KEEP_MAIN]}${COLOR_RESET}"
        sleep 1
        cb_pick_members "$min" "$exclude" "$ibuf" "$keep" "$hidden"
        return $?
    fi

    CB_PICKED_UUIDS=""
    CB_PICKED_REMARKS=""
    CB_PICKED_ENTRIES=""
    for n in "${nums[@]}"; do
        entry="${entries[$((n - 1))]}"
        CB_PICKED_UUIDS="${CB_PICKED_UUIDS:+$CB_PICKED_UUIDS }$(echo "$entry" | cut -f1)"
        CB_PICKED_REMARKS="${CB_PICKED_REMARKS:+$CB_PICKED_REMARKS }$(echo "$entry" | cut -f2)"
        CB_PICKED_ENTRIES="${CB_PICKED_ENTRIES:+$CB_PICKED_ENTRIES
}$entry"
    done
    return 0
}

# Wrapper so the callers can pass the dialog texts without globals leaking
# between calls. $1 title, $2 hint, $3 min, $4 exclude list, $5 inbound filter,
# $6 hosts that must stay unpicked, $7 "hidden" to offer hidden hosts.
cb_pick_members_titled() {
    CB_PICK_TITLE="$1"
    CB_PICK_HINT="$2"
    cb_pick_members "$3" "${4:-}" "${5:-}" "${6:-}" "${7:-}"
}

# --- squad coverage -------------------------------------------------------------------
#
# The wrapper host lives on the first main's inbound and a user sees it
# through the squads covering THAT inbound. Clones keep their own inbounds,
# so they inherit the original coverage on their own. When members sit on
# inbounds covered by squads that do NOT cover the wrapper inbound, those
# squads get the wrapper inbound added, so nobody who could reach a member
# loses the entry. Every addition is tracked in the state (squads_patched)
# and reverted on teardown.

cb_fetch_squads() {
    local response
    response=$(cb_api "GET" "/api/internal-squads?_=$(date +%s)")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    CB_SQUADS_JSON=$(echo "$response" | jq -c '.response | if type == "array" then . else (.internalSquads // []) end')
}

# $1 = wrapper inbound uuid, $2 = member inbound uuids (space separated).
# Coverage works in BOTH directions, or users lose parts of the balancer:
#   a squad covering the WRAPPER must also cover every member inbound — the
#   clones live there, and a clone outside the squad never reaches the
#   user's host list, so injectHosts cannot resolve it (the outbound just
#   disappears from the config);
#   a squad covering a MEMBER but not the wrapper never shows the wrapper
#   host at all.
# One PATCH per touched squad; every added inbound is echoed as "squad=inbound"
# on stdout for the state (may be empty). rc 1 only on an API failure.
cb_patch_squads() {
    local wrapper_ib="$1" member_ibs="$2" patched="" sq cw miss need ib body response
    [ -n "$wrapper_ib" ] || return 0
    cb_fetch_squads || return 1
    # The miss column carries a dash instead of an empty list: read collapses
    # empty tab-separated fields, and the next column would slide into miss.
    while IFS=$'\t' read -r sq cw miss need; do
        [ -n "$sq" ] || continue
        [ "$miss" = "-" ] && miss=""
        if [ "$cw" = "1" ] && [ -n "$miss" ]; then
            body=$(printf '%s' "$CB_SQUADS_JSON" | jq -c --arg s "$sq" --arg add "$miss" \
                '.[] | select(.uuid == $s) | (([.inbounds[]?.uuid] + ($add | split(",") | map(select(. != "")))) | unique)')
            response=$(cb_api "PATCH" "/api/internal-squads" \
                "$(jq -nc --arg u "$sq" --argjson ibs "$body" '{uuid: $u, inbounds: $ibs}')")
            echo "$response" | jq -e '.response.uuid // empty' >/dev/null 2>&1 || {
                err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
                return 1
            }
            for ib in ${miss//,/ }; do
                [ -n "$ib" ] && patched="${patched:+$patched }$sq=$ib"
            done
        fi
        if [ "$need" = "1" ]; then
            body=$(printf '%s' "$CB_SQUADS_JSON" | jq -c --arg s "$sq" --arg ib "$wrapper_ib" \
                '.[] | select(.uuid == $s) | ([.inbounds[]?.uuid] + [$ib]) | unique')
            response=$(cb_api "PATCH" "/api/internal-squads" \
                "$(jq -nc --arg u "$sq" --argjson ibs "$body" '{uuid: $u, inbounds: $ibs}')")
            echo "$response" | jq -e '.response.uuid // empty' >/dev/null 2>&1 || {
                err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
                return 1
            }
            patched="${patched:+$patched }$sq=$wrapper_ib"
        fi
    done < <(printf '%s' "$CB_SQUADS_JSON" | jq -r --arg w "$wrapper_ib" --arg mi "$member_ibs" '
        ($mi | split(" ") | map(select(. != ""))) as $m
        | .[] | .uuid as $u | ([.inbounds[]?.uuid]) as $ibs
        | [ $u,
            (if ($ibs | index($w)) != null then "1" else "0" end),
            ([ $m[] | select(. as $x | $ibs | index($x) == null) ]
             | if length == 0 then "-" else join(",") end),
            (if (($ibs | any(. as $x | $m | index($x) != null)) and ($ibs | index($w) == null))
             then "1" else "0" end)
          ] | @tsv')
    printf '%s' "$patched"
    return 0
}

# Whether another live balancer still needs this inbound in its squads
# (its own squads_patched line mentions the same "squad=inbound" need).
cb_ib_in_other_balancer() { # $1 = inbound uuid
    local f
    for f in "$CB_CONF_DIR"/*.bal; do
        [ -f "$f" ] || continue
        [ "$(basename "$f")" = "${CB_CURRENT}.bal" ] && continue
        awk -v ib="$1" 'BEGIN{FS="="} $1=="squads_patched"{n=split($2,a," "); for(i=1;i<=n;i++){split(a[i],p,"="); if(p[2]==ib) found=1}} END{exit !found}' "$f" && return 0
    done
    return 1
}

# Remove inbounds we added from the squads we added them to, $1 =
# "squad=ib" pairs exactly as cb_patch_squads recorded them. All pairs of
# one squad are undone with a single PATCH (a per-pair PATCH would re-add
# the sibling inbound from the stale snapshot). An inbound is skipped while
# another balancer still needs it.
cb_revert_squad_pairs() {
    local pairs="$1" pair sq ib drop body response
    [ -n "$pairs" ] || return 0
    cb_fetch_squads >/dev/null 2>&1 || return 1
    for sq in $(printf '%s\n' $pairs | cut -d= -f1 | awk 'NF' | sort -u); do
        drop=""
        for pair in $pairs; do
            [ "${pair%%=*}" = "$sq" ] || continue
            ib="${pair#*=}"
            cb_ib_in_other_balancer "$ib" && continue
            case " $drop " in *" $ib "*) ;; *) drop="$drop $ib" ;; esac
        done
        [ -n "$drop" ] || continue
        body=$(printf '%s' "$CB_SQUADS_JSON" | jq -c --arg s "$sq" --arg drop "$drop" \
            '.[] | select(.uuid == $s)
             | [.inbounds[]?.uuid | select(. as $ib | ($drop | split(" ") | index($ib)) == null)]')
        response=$(cb_api "PATCH" "/api/internal-squads" \
            "$(jq -nc --arg u "$sq" --argjson ibs "$body" '{uuid: $u, inbounds: $ibs}')")
        echo "$response" | jq -e '.response.uuid // empty' >/dev/null 2>&1 || return 1
    done
    return 0
}

# --- template ---------------------------------------------------------------------

# The balancer config rides ON TOP of the panel's Default XRAY_JSON template:
# whatever the admin tuned there (dns, routing rules, local inbounds, extra
# outbounds) is inherited, and only the balancing machinery is added. Rules
# from the Default keep working ahead of the balancer's catch-all; a bare
# catch-all rule from the Default is REPLACED by the balancer's one (it would
# swallow everything before the balancer ever fires). Sets CB_DEF_JSON ({}
# when there is nothing to inherit) and CB_DEF_RULES (inherited rule count).
cb_fetch_default_json() {
    local response uuid
    CB_DEF_JSON="{}"
    CB_DEF_RULES=0
    response=$(cb_api "GET" "/api/subscription-templates?_=$(date +%s)")
    uuid=$(echo "$response" | jq -r '.response.templates[]? | select(.templateType == "XRAY_JSON" and .name == "Default") | .uuid' | head -n1)
    [ -n "$uuid" ] || return 0
    response=$(cb_api "GET" "/api/subscription-templates/$uuid")
    CB_DEF_JSON=$(echo "$response" | jq -c '.response.templateJson // {}')
    [ -n "$CB_DEF_JSON" ] || CB_DEF_JSON="{}"
    # Custom rule count for the closing note: everything that survives the
    # catch-all filter except the stock bittorrent rule a fresh panel seeds.
    CB_DEF_RULES=$(printf '%s' "$CB_DEF_JSON" | jq '
        [(.routing.rules // [])[]
         | select([(keys_unsorted[]) as $k
                   | select($k != "type" and $k != "network"
                            and $k != "outboundTag" and $k != "balancerTag")] | length > 0)
         | select((del(.type)) != {protocol: ["bittorrent"], outboundTag: "direct"})] | length')
}

# Build the whole XRAY_JSON template into CB_TEMPLATE_JSON on top of
# CB_DEF_JSON. The remnawave block is panel-side only — the panel strips it
# and splices the hidden clones in as proxy/proxy-2/... (and
# backup/backup-2/... for reserve). balancer.fallbackTag may only name an
# outbound (per xtls routing docs), so the reserve preset falls back to the
# FIRST backup host ("backup").
cb_build_template() {
    local mains backups subject fallback
    mains=$(printf '%s\n' $CB_MAIN_UUIDS | jq -R -s 'split("\n") | map(select(length > 0))')
    if [ -n "${CB_BACKUP_UUIDS:-}" ]; then
        backups=$(printf '%s\n' $CB_BACKUP_UUIDS | jq -R -s 'split("\n") | map(select(length > 0))')
        subject='["proxy","backup"]'
        fallback="backup"
    else
        backups="[]"
        subject='["proxy"]'
        fallback="direct"
    fi
    CB_TEMPLATE_JSON=$(jq -nc --argjson def "$CB_DEF_JSON" \
        --argjson mains "$mains" --argjson backups "$backups" \
        --arg fallback "$fallback" --argjson subject "$subject" '
        ($def | {
            dns: (.dns // {servers: ["1.1.1.1", "1.0.0.1"], queryStrategy: "UseIP"}),
            routing: (.routing // {}),
            inbounds: (.inbounds // [
                {tag: "socks", port: 10808, listen: "127.0.0.1", protocol: "socks",
                 settings: {udp: true, auth: "noauth"},
                 sniffing: {enabled: true, routeOnly: false, destOverride: ["http", "tls", "quic"]}},
                {tag: "http", port: 10809, listen: "127.0.0.1", protocol: "http",
                 settings: {allowTransparent: false},
                 sniffing: {enabled: true, routeOnly: false, destOverride: ["http", "tls", "quic"]}}]),
            outbounds: (.outbounds // [{tag: "direct", protocol: "freedom"}, {tag: "block", protocol: "blackhole"}])
        }) as $base
        # Keep only rules that actually match something (domain/ip/port/
        # protocol/...): a bare {network, outboundTag} catch-all from the
        # Default would eat every connection before the balancer fires.
        | (($base.routing.rules // [])
           | map(select([(keys_unsorted[]) as $k
                         | select($k != "type" and $k != "network"
                                  and $k != "outboundTag" and $k != "balancerTag")] | length > 0))) as $rules
        | ($rules | any((.protocol // []) | index("bittorrent"))) as $has_bt
        | $base + {
            remnawave: {
                injectHosts:
                    ([{selector: {type: "uuids", values: $mains}, tagPrefix: "proxy"}]
                     + (if ($backups | length) > 0
                        then [{selector: {type: "uuids", values: $backups}, tagPrefix: "backup"}]
                        else [] end))
            },
            burstObservatory: {
                pingConfig: {
                    timeout: "3s", interval: "30s", sampling: 1,
                    destination: "http://www.gstatic.com/generate_204", connectivity: ""
                },
                subjectSelector: $subject
            },
            routing: ($base.routing + {
                balancers: [{
                    tag: "balancer", selector: ["proxy"],
                    strategy: {type: "leastLoad",
                               settings: {maxRTT: "1s", expected: 2, baselines: ["1s"], tolerance: 0.01}},
                    fallbackTag: $fallback
                }],
                rules: ($rules
                        + (if $has_bt then [] else [{protocol: ["bittorrent"], outboundTag: "direct"}] end)
                        + [{network: "tcp,udp", balancerTag: "balancer"}]),
                domainMatcher: ($base.routing.domainMatcher // "hybrid"),
                domainStrategy: ($base.routing.domainStrategy // "IPIfNonMatch")
            })
        }')
    [ -n "$CB_TEMPLATE_JSON" ]
}

# Template names are latin-only panel-wide; keep ours derived from the slug
# and dodge an existing name instead of guessing.
cb_unique_template_name() {
    local base="$1" names name suffix
    names=$(cb_api "GET" "/api/subscription-templates?_=$(date +%s)" \
        | jq -r '.response.templates[]?.name // empty' 2>/dev/null)
    name="$base"
    while printf '%s\n' "$names" | grep -qx "$name"; do
        suffix=$(cb_rand 4)
        name="${base}-${suffix}"
    done
    echo "$name"
}

# POST creates the empty shell, PATCH carries the actual JSON payload.
cb_template_create() {
    local slug="$1" name response
    name=$(cb_unique_template_name "CB ${slug}")
    step_do "$(printf "${LANG[CB_CREATE_TEMPLATE]}" "$name")"
    response=$(cb_api "POST" "/api/subscription-templates" \
        "$(jq -nc --arg n "$name" '{name: $n, templateType: "XRAY_JSON"}')")
    CB_TEMPLATE_UUID=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -z "$CB_TEMPLATE_UUID" ]; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    CB_TEMPLATE_NAME="$name"
    step_ok "${LANG[CB_CREATE_TEMPLATE_OK]}"
}

cb_template_push() {
    local response
    step_do "${LANG[CB_PUSH_TEMPLATE]}"
    response=$(cb_api "PATCH" "/api/subscription-templates" \
        "$(jq -nc --arg uuid "$CB_TEMPLATE_UUID" --argjson json "$CB_TEMPLATE_JSON" \
            '{uuid: $uuid, templateJson: $json}')")
    echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || {
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    }
    step_ok "${LANG[CB_PUSH_TEMPLATE_OK]}"
}

# Regenerate + push from the CURRENT balancer's state. Callers must load the
# state lists into CB_MAIN_UUIDS / CB_BACKUP_UUIDS first. The Default base
# is fetched here too: admin edits between rebuilds must survive refreshes.
cb_template_refresh() {
    # The template uuid comes from the state: add/remove run in a fresh menu
    # session where the setup-time global is long gone (an empty uuid made
    # the panel reject the PATCH with "Invalid UUID" and the refresh died
    # after the state had already grown).
    [ -n "${CB_TEMPLATE_UUID:-}" ] || CB_TEMPLATE_UUID=$(cb_state_get template_uuid)
    [ -n "${CB_DEF_JSON:-}" ] || cb_fetch_default_json
    cb_build_template || { err_msg "${LANG[CB_TEMPLATE_BUILD_FAIL]}"; return 1; }
    cb_template_push
}

cb_template_delete() {
    local response
    response=$(cb_api "DELETE" "/api/subscription-templates/$1")
    # 204 No Content on success; an empty body is fine, anything json-ish with
    # an error message is not.
    if [ -n "$response" ] && echo "$response" | jq -e '.message // .statusCode' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

# --- hosts -------------------------------------------------------------------------

# Round-trip PATCH body: everything the update endpoint knows is sent back,
# so partial-update semantics can never wipe a field we did not mean to
# touch (same discipline as server_routing's sr_host_patch).
cb_host_roundtrip_body() {
    local uuid="$1" overrides="$2"
    cb_api "GET" "/api/hosts/$uuid" | jq -c --argjson ov "$overrides" '.response |
        {uuid, remark, address, port, path, sni, host, alpn, fingerprint,
         isDisabled, securityLayer, xhttpExtraParams, muxParams, sockoptParams,
         finalMask, serverDescription, tags, isHidden, overrideSniFromAddress,
         keepSniBlank, vlessRouteId, pinnedPeerCertSha256, verifyPeerCertByName,
         shuffleHost, mihomoX25519, mihomoIpVersion, xrayJsonTemplateUuid,
         excludeFromSubscriptionTypes, mapper,
         inbound: {configProfileUuid: .inbound.configProfileUuid,
                   configProfileInboundUuid: .inbound.configProfileInboundUuid},
         nodes} * $ov'
}

# Copy a host. POST /api/hosts/actions/clone exists only since panel 3.4.4;
# older panels answer it with the route-missing JSON ("Cannot POST ..."), and
# then the copy is created by hand from a fresh GET of the source — disabled
# and hidden, mirroring how the clone endpoint leaves its own copies, so the
# follow-up PATCH converges to the same result on both paths. Sets CB_NEW_UUID.
cb_host_duplicate() {
    local src_uuid="$1" response body
    response=$(cb_api "POST" "/api/hosts/actions/clone" \
        "$(jq -nc --arg u "$src_uuid" '{cloneFromUuid: $u}')")
    CB_NEW_UUID=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -n "$CB_NEW_UUID" ]; then
        CB_CLONES_MADE+=("$CB_NEW_UUID")
        return 0
    fi
    if ! echo "$response" | jq -e '(.message // "") | startswith("Cannot POST")' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    response=$(cb_api "GET" "/api/hosts/$src_uuid")
    if ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    body=$(echo "$response" | jq -c '.response |
        {remark, address, port, path, sni, host, alpn, fingerprint,
         isDisabled, securityLayer, xhttpExtraParams, muxParams, sockoptParams,
         finalMask, serverDescription, tags, isHidden, overrideSniFromAddress,
         keepSniBlank, vlessRouteId, pinnedPeerCertSha256, verifyPeerCertByName,
         shuffleHost, mihomoX25519, mihomoIpVersion, xrayJsonTemplateUuid,
         excludeFromSubscriptionTypes, mapper,
         inbound: {configProfileUuid: .inbound.configProfileUuid,
                   configProfileInboundUuid: .inbound.configProfileInboundUuid},
         nodes} + {isDisabled: true, isHidden: true}')
    response=$(cb_api "POST" "/api/hosts" "$body")
    CB_NEW_UUID=$(echo "$response" | jq -r '.response.uuid // empty')
    if [ -z "$CB_NEW_UUID" ]; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    CB_CLONES_MADE+=("$CB_NEW_UUID")
}

# Clone the source host and hide the copy. Live-checked on 3.4.4: the panel
# rewrites a clone's remark to a unique "#_xxx <remark>" form, does NOT copy
# the address and creates the copy DISABLED — and disabled hosts are skipped
# by injectHosts selectors. So the clone is PATCHed with the source remark,
# address, port, isHidden and enabled. The clone KEEPS its original inbound
# (and the vlessRouteId the panel copies along): the subscription renderer
# reads transport and reality keys from the host's own inbound, so a mixed
# pool just works and bridges keep routing. The "CB:CLONE" tag marks the
# copy as ours so it never shows up as a candidate again. $2/$3 remain for
# legacy balancers whose clones live on a dedicated inbound. Sets CB_NEW_UUID.
cb_clone_hidden_member() {
    local src_uuid="$1" ov_pf="${2:-}" ov_ib="${3:-}" response body remark src_addr src_port src_tags
    response=$(cb_api "GET" "/api/hosts/$src_uuid")
    if ! echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    fi
    remark=$(echo "$response" | jq -r '.response.remark')
    src_addr=$(echo "$response" | jq -r '.response.address // ""')
    src_port=$(echo "$response" | jq -r '.response.port')
    src_tags=$(echo "$response" | jq -c '(.response.tags // []) + ["CB:CLONE"] | unique')
    step_do "$(printf "${LANG[CB_CLONE_MEMBER]}" "$remark")"
    cb_host_duplicate "$src_uuid" || return 1
    local ov=""
    [ -n "$ov_pf" ] && [ -n "$ov_ib" ] && ov=", inbound: {configProfileUuid: \"$ov_pf\", configProfileInboundUuid: \"$ov_ib\"}"
    body=$(cb_host_roundtrip_body "$CB_NEW_UUID" \
        "$(jq -nc --arg r "$remark" --arg a "$src_addr" --argjson p "$src_port" --argjson t "$src_tags" \
            "{remark: \$r, address: \$a, port: \$p, isHidden: true, isDisabled: false, tags: \$t$ov}")")
    response=$(cb_api "PATCH" "/api/hosts" "$body")
    echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || {
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    }
    step_ok "$(printf "${LANG[CB_CLONE_MEMBER_OK]}" "$remark")"
}

# The wrapper host: a clone of the first member carrying remark, server
# description and the template binding; it keeps the first member's inbound,
# so the users of that member see the wrapper through their squads. Visible
# ONLY in XRAY_JSON subs — excluded from every other type, which is also
# what keeps Xray Checker from dialing a wrapper address nobody ever
# connects to. A wrapper never routes on its own, so vlessRouteId is
# cleared even when the first member is a bridge host.
cb_create_vhost() {
    local src_uuid="$1" remark="$2" template_uuid="$3" response body
    step_do "$(printf "${LANG[CB_VHOST_CREATE]}" "$remark")"
    cb_host_duplicate "$src_uuid" || return 1
    CB_VHOST_MADE="$CB_NEW_UUID" 
    body=$(cb_host_roundtrip_body "$CB_NEW_UUID" "$(jq -nc \
        --arg remark "$remark" --arg uuid "$template_uuid" --arg desc "${LANG[CB_VHOST_DESC]}" '
        {remark: $remark, isHidden: false, isDisabled: false, vlessRouteId: null,
         xrayJsonTemplateUuid: $uuid, serverDescription: $desc,
         excludeFromSubscriptionTypes: ["XRAY_BASE64", "MIHOMO", "STASH", "CLASH", "SINGBOX"]}')")
    response=$(cb_api "PATCH" "/api/hosts" "$body")
    echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || {
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    }
    step_ok "${LANG[CB_VHOST_OK]}"
}

cb_host_delete() {
    local response
    response=$(cb_api "DELETE" "/api/hosts/$1")
    if [ -n "$response" ] && echo "$response" | jq -e '.message // .statusCode' >/dev/null 2>&1; then
        return 1
    fi
    return 0
}

cb_host_summary() {
    # "remark (address)" for member listings; empty when the host is gone.
    local response
    response=$(cb_api "GET" "/api/hosts/$1" 2>/dev/null)
    echo "$response" | jq -r 'if .response.uuid then "\(.response.remark) (\(.response.address))" else empty end' 2>/dev/null
}

# --- setup flow ----------------------------------------------------------------------

# Undo whatever a half-finished cb_setup managed to create: clones, wrapper,
# template and the squad additions of this run. Nodes are never touched by
# the wizard, so there is nothing to switch back. Extra arguments: uuids of
# member clones already made and the vhost uuid.
cb_setup_cleanup() {
    local uuid template_uuid="$1" vhost_uuid="$2"; shift 2
    for uuid in "$@" ${CB_CLONES_MADE[@]:-}; do
        [ -n "$uuid" ] && cb_host_delete "$uuid" 2>/dev/null
    done
    [ -n "$vhost_uuid" ] && cb_host_delete "$vhost_uuid" 2>/dev/null
    [ -n "${CB_VHOST_MADE:-}" ] && cb_host_delete "$CB_VHOST_MADE" 2>/dev/null
    [ -n "$template_uuid" ] && cb_template_delete "$template_uuid" 2>/dev/null
    [ -n "${CB_SQUADS_ADDED:-}" ] && cb_revert_squad_pairs "$CB_SQUADS_ADDED"
    cb_state_clear 2>/dev/null
}

cb_pick_name() {
    local default_slug input fslug n=0
    default_slug=$(cb_slug "${LANG[CB_DEFAULT_NAME]}")
    [ -n "$default_slug" ] || default_slug="balancer"
    reading "$(printf "${LANG[CB_NAME_PROMPT]}" "${LANG[CB_DEFAULT_NAME]}")" input || { echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1; }
    CB_VHOST_REMARK="${input:-${LANG[CB_DEFAULT_NAME]}}"
    CB_SLUG=$(cb_slug "$CB_VHOST_REMARK")
    [ -n "$CB_SLUG" ] || CB_SLUG="$default_slug"
    # A NEW balancer always gets a FRESH state file: a CB_CURRENT leaked from
    # an earlier selection or menu render must never redirect the state
    # writes into an existing balancer's file.
    fslug="$CB_SLUG"
    while [ -e "${CB_CONF_DIR}/${fslug}.bal" ]; do
        n=$((n + 1))
        fslug="${CB_SLUG}-${n}"
    done
    CB_CURRENT="$fslug"
}

# The mihomo wizard: pick hosts of ANY inbound (the group just names them),
# name the group, splice it into the Default MIHOMO template. No dedicated
# profile, no clones, no wrapper: the pool is the visible hosts themselves.
cb_mh_setup() {
    cb_pick_preset || return 1

    local min_main=2 keep_main=0 main_hint="${LANG[CB_PICK_MAIN_HINT]}"
    [ "$CB_PRESET" = "reserve" ] && { min_main=1; keep_main=1; main_hint="${LANG[CB_PICK_MAIN_HINT_RESERVE]}"; }

    cb_pick_members_titled "${LANG[CB_PICK_MAIN_TITLE]}" "$main_hint" "$min_main" "" "" "$keep_main" || return 1
    local main_uuids="$CB_PICKED_UUIDS" backup_uuids=""
    if [ "$CB_PRESET" = "reserve" ]; then
        cb_pick_members_titled "${LANG[CB_PICK_BACKUP_TITLE]}" "${LANG[CB_PICK_BACKUP_HINT]}" 1 "$main_uuids" "" || return 1
        backup_uuids="$CB_PICKED_UUIDS"
    fi

    cb_mh_dup_check "$main_uuids ${backup_uuids:-}" || return 1

    cb_pick_name || return 1

    step_do "$(printf "${LANG[CB_MH_STEP]}" "$CB_VHOST_REMARK")"
    cb_mh_fetch_default || return 1
    CB_MH_GROUP_NAME="$CB_VHOST_REMARK"
    CB_MH_MAIN_REMARKS=$(cb_mh_sync_remarks "$main_uuids")
    CB_MH_BACKUP_REMARKS=$(cb_mh_sync_remarks "${backup_uuids:-}")
    cb_mh_build_block || { err_msg "${LANG[CB_TEMPLATE_BUILD_FAIL]}"; return 1; }
    cb_mh_apply_block || { err_msg "${LANG[CB_TEMPLATE_BUILD_FAIL]}"; return 1; }
    cb_mh_patch || { err_msg "$(printf "${LANG[CB_MH_FAIL]}" "template update rejected")"; return 1; }

    cb_state_set mode mihomo
    cb_state_set vhost_remark "$CB_VHOST_REMARK"
    cb_state_set preset "$CB_PRESET"
    cb_state_set mh_group "$CB_VHOST_REMARK"
    cb_state_set template_uuid "$CB_MH_TEMPLATE_UUID"
    cb_state_set template_name "Default MIHOMO"
    cb_state_set members_main "$main_uuids"
    cb_state_set members_backup "${backup_uuids:-}"
    cb_state_set created "$(date +%F)"

    step_ok "$(printf "${LANG[CB_MH_DONE]}" "$CB_VHOST_REMARK")"
    echo -e " ${COLOR_GRAY}${LANG[CB_MH_DONE_HINT]}${COLOR_RESET}"
}

# Rebuild + re-patch the group from the CURRENT state (add/remove/rename).
# Remarks are re-derived from the stored uuids on every rebuild: a host
# renamed in the panel heals the group on the next action instead of
# leaving a dangling name that kills the whole client config.
cb_mh_refresh() {
    cb_mh_fetch_default || return 1
    CB_MH_GROUP_NAME=$(cb_state_get mh_group)
    CB_MH_MAIN_REMARKS=$(cb_mh_sync_remarks "$(cb_state_get members_main)")
    CB_MH_BACKUP_REMARKS=$(cb_mh_sync_remarks "$(cb_state_get members_backup)")
    cb_mh_build_block || { err_msg "${LANG[CB_TEMPLATE_BUILD_FAIL]}"; return 1; }
    cb_mh_apply_block || { err_msg "${LANG[CB_TEMPLATE_BUILD_FAIL]}"; return 1; }
    cb_mh_patch
}

# Rewrite the state lists from the uuid lists via one hosts snapshot.
cb_mh_sync_remarks() {
    local response
    response=$(cb_api "GET" "/api/hosts?_=$(date +%s)")
    [ -n "$response" ] || return 1
    local list="$1" out="" uuid remark
    for uuid in $list; do
        remark=$(echo "$response" | jq -r --arg u "$uuid" '.response[]? | select(.uuid == $u) | .remark' 2>/dev/null)
        [ -n "$remark" ] && out="${out:+$out$'
'}$remark"
    done
    printf '%s' "$out"
}

cb_setup() {
    local uuid made=() vhost_uuid="" template_uuid=""
    CB_CLONES_MADE=()
    CB_VHOST_MADE=""
    load_api_module || return 1
    get_panel_token || { echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"; return 1; }

    if ! cb_panel_version_ok; then
        local version
        version=$(panel_installed_version 2>/dev/null || echo "?")
        echo -e "${COLOR_RED}$(printf "${LANG[CB_PANEL_OLD]}" "$version")${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[CB_PANEL_OLD_HINT]}${COLOR_RESET}"
        return 1
    fi

    cb_fetch_profiles || return 1
    cb_fetch_hosts || return 1
    cb_pick_client || return 1

    if [ "$CB_CLIENT" = "mihomo" ]; then
        cb_mh_setup || return 1
        return 0
    fi

    # Xray JSON clients need JSON served at the subscription base path to
    # see the balancer from the plain link; the wizard flips the panel
    # setting itself instead of sending the user to the panel UI.
    cb_ensure_json_base

    cb_pick_preset || return 1

    local min_main=2 keep_main=0 main_hint="${LANG[CB_PICK_MAIN_HINT]}"
    [ "$CB_PRESET" = "reserve" ] && { min_main=1; keep_main=1; main_hint="${LANG[CB_PICK_MAIN_HINT_RESERVE]}"; }

    # Any inbound, hidden hosts and bridges included: every clone keeps its
    # own inbound, so the pool may be as mixed as the panel itself.
    cb_pick_members_titled "${LANG[CB_PICK_MAIN_TITLE]}" "$main_hint" "$min_main" "" "" "$keep_main" "hidden" || return 1
    local main_srcs="$CB_PICKED_UUIDS" picked_entries="$CB_PICKED_ENTRIES"
    CB_MAIN_UUIDS=""
    CB_BACKUP_UUIDS=""

    if [ "$CB_PRESET" = "reserve" ]; then
        cb_pick_members_titled "${LANG[CB_PICK_BACKUP_TITLE]}" "${LANG[CB_PICK_BACKUP_HINT]}" 1 "$main_srcs" "" 0 "hidden" || return 1
        CB_BACKUP_SRC_UUIDS="$CB_PICKED_UUIDS"
        picked_entries="$picked_entries
$CB_PICKED_ENTRIES"
    else
        CB_BACKUP_SRC_UUIDS=""
    fi

    cb_pick_name || { cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"; return 1; }

    # The balancer config inherits whatever the admin tuned in the panel's
    # Default XRAY_JSON template (routing rules, dns, local inbounds).
    cb_fetch_default_json

    # Template first: its uuid goes onto the wrapper host.
    cb_template_create "$CB_SLUG" || { cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"; return 1; }
    template_uuid="$CB_TEMPLATE_UUID"

    local src
    for src in $main_srcs; do
        if ! cb_clone_hidden_member "$src"; then
            cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"
            return 1
        fi
        made+=("$CB_NEW_UUID")
        CB_MAIN_UUIDS="${CB_MAIN_UUIDS:+$CB_MAIN_UUIDS }$CB_NEW_UUID"
    done
    for src in ${CB_BACKUP_SRC_UUIDS:-}; do
        if ! cb_clone_hidden_member "$src"; then
            cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"
            return 1
        fi
        made+=("$CB_NEW_UUID")
        CB_BACKUP_UUIDS="${CB_BACKUP_UUIDS:+$CB_BACKUP_UUIDS }$CB_NEW_UUID"
    done

    cb_build_template || { cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"; return 1; }
    cb_template_push || { cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"; return 1; }

    cb_create_vhost "${CB_MAIN_UUIDS%% *}" "$CB_VHOST_REMARK" "$template_uuid" || {
        cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"
        return 1
    }
    vhost_uuid="$CB_NEW_UUID"

    # Squads that cover a member's inbound but not the wrapper's one get the
    # wrapper inbound added, so nobody loses the balancer entry.
    local wrapper_ib member_ibs patched
    wrapper_ib=$(printf '%s\n' "$picked_entries" | head -n1 | cut -f5)
    member_ibs=$(printf '%s\n' "$picked_entries" | cut -f5 | awk 'NF' | sort -u | tr '\n' ' ')
    CB_SQUADS_ADDED=""
    patched=$(cb_patch_squads "$wrapper_ib" "$member_ibs")
    if [ $? -ne 0 ]; then
        # A half-done patch run must be undone by the cleanup too.
        CB_SQUADS_ADDED="$patched"
        cb_setup_cleanup "$template_uuid" "$vhost_uuid" "${made[@]}"
        return 1
    fi
    if [ -n "$patched" ]; then
        CB_SQUADS_ADDED="$patched"
        echo -e " ${COLOR_GRAY}$(printf "${LANG[CB_SQUAD_NOTE]}" "$(printf '%s\n' $patched | wc -l)")${COLOR_RESET}"
    fi

    cb_state_set vhost_uuid "$vhost_uuid"
    cb_state_set vhost_remark "$CB_VHOST_REMARK"
    cb_state_set template_uuid "$template_uuid"
    cb_state_set template_name "$CB_TEMPLATE_NAME"
    cb_state_set preset "$CB_PRESET"
    cb_state_set wrapper_ib "$wrapper_ib"
    cb_state_set members_main "$CB_MAIN_UUIDS"
    cb_state_set members_backup "${CB_BACKUP_UUIDS:-}"
    cb_state_set squads_patched "${CB_SQUADS_ADDED:-}"
    cb_state_set created "$(date +%F)"

    # The wrapper replaces the whole list with one entry: the picked
    # originals leave the subscription listing (they keep working).
    cb_state_set orig_srcs "$(printf '%s\n' $main_srcs ${CB_BACKUP_SRC_UUIDS:-} | awk 'NF' | sort -u | tr '\n' ' ')"
    cb_hide_originals "$(cb_state_get orig_srcs)"

    local backup_part=""
    if [ -n "$CB_BACKUP_UUIDS" ]; then
        backup_part=$(printf "${LANG[CB_DONE_BACKUP]}" "$(printf '%s\n' $CB_BACKUP_UUIDS | wc -w)")
    fi
    echo ""
    step_ok "$(printf "${LANG[CB_DONE]}" "$CB_VHOST_REMARK" "$(printf '%s\n' $CB_MAIN_UUIDS | wc -w)" "$backup_part")"
    echo -e " ${COLOR_GRAY}${LANG[CB_DONE_HINT]}${COLOR_RESET}"
    [ "${CB_DEF_RULES:-0}" -gt 0 ] && echo -e " ${COLOR_GRAY}$(printf "${LANG[CB_DEF_INHERITED]}" "$CB_DEF_RULES")${COLOR_RESET}"
}

# --- per-balancer actions --------------------------------------------------------------

# Live listing of members with a netbird-style drift check: every stored
# uuid must still resolve, stay hidden and stay enabled.
cb_members_show() {
    local list label uuid summary gone=0
    for label in main backup; do
        [ "$label" = "backup" ] && [ -z "$(cb_state_get members_backup)" ] && continue
        echo -e ""
        if [ "$label" = "main" ]; then
            echo -e "${COLOR_GREEN}${LANG[CB_MEMBERS_MAIN]}${COLOR_RESET}"
            list=$(cb_state_get members_main)
        else
            echo -e "${COLOR_GREEN}${LANG[CB_MEMBERS_BACKUP]}${COLOR_RESET}"
            list=$(cb_state_get members_backup)
        fi
        for uuid in $list; do
            summary=$(cb_host_summary "$uuid")
            if [ -n "$summary" ]; then
                echo -e " ${COLOR_WHITE}${summary}${COLOR_RESET}"
            else
                echo -e " ${COLOR_RED}$(printf "${LANG[CB_STATUS_MEMBER_GONE]}" "$uuid")${COLOR_RESET}"
                gone=$((gone + 1))
            fi
        done
    done
    if [ "$gone" -gt 0 ]; then
        echo -e ""
        echo -e " ${COLOR_RED}${LANG[CB_DRIFT_HINT]}${COLOR_RESET}"
    else
        echo -e ""
        echo -e " ${COLOR_GRAY}${LANG[CB_STATUS_OK]}${COLOR_RESET}"
    fi
}

cb_member_add() {
    local group pick legacy=0
    # Members, their hidden originals (adding one twice would duplicate the
    # outbound) and wrappers of other balancers stay out of the list.
    local exclude="$(cb_state_get members_main) $(cb_state_get members_backup) $(cb_state_get orig_srcs)"
    cb_fetch_hosts || return 1
    cb_fetch_profiles || return 1

    # Balancers built before 3.9 gathered clones on a dedicated inbound with
    # their nodes switched to it: new clones must be rebound the same way.
    # Fresh balancers clone onto the source's own inbound.
    if [ "$(cb_state_get mode)" = "mihomo" ]; then
        CB_INBOUND_UUID=""
        CB_INBOUND_LABEL=""
        group="main"
    else
        CB_INBOUND_UUID=$(cb_state_get inbound_uuid)
        CB_INBOUND_LABEL=$(cb_state_get inbound_label)
        [ -n "$CB_INBOUND_UUID" ] && [ -n "$(cb_state_get member_pf)" ] && legacy=1
    fi

    if [ "$(cb_state_get preset)" = "reserve" ]; then
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[CB_ADD_GROUP_TITLE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${COLOR_WHITE}${LANG[CB_GROUP_MAIN]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${COLOR_WHITE}${LANG[CB_GROUP_BACKUP]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" pick || { echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1; }
        case "$pick" in
            1) group="main" ;;
            2) group="backup" ;;
            0) echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1 ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2
                sleep 1
                return 1
                ;;
        esac
    else
        group="main"
    fi

    local hidden_mode=""
    [ "$legacy" = "0" ] && hidden_mode="hidden"
    cb_pick_members_titled "${LANG[CB_PICK_ADD_TITLE]}" "${LANG[CB_PICK_MAIN_HINT]}" 1 "$exclude" "$CB_INBOUND_UUID" 0 "$hidden_mode" || return 1

    local added=0 src
    if [ "$(cb_state_get mode)" = "mihomo" ]; then
        cb_mh_dup_check "$(cb_state_get members_main) $(cb_state_get members_backup) $CB_PICKED_UUIDS" || return 1
        for src in $CB_PICKED_UUIDS; do
            if [ "$group" = "main" ]; then
                cb_state_set members_main "$(cb_state_get members_main) $src"
            else
                cb_state_set members_backup "$(cb_state_get members_backup) $src"
            fi
            added=$((added + 1))
        done
        step_do "${LANG[CB_MH_UPDATE_STEP]}"
        cb_mh_refresh || return 1
        step_ok "$(printf "${LANG[CB_ADD_OK]}" "$added")"
        return 0
    fi
    for src in $CB_PICKED_UUIDS; do
        if [ "$legacy" = "1" ]; then
            cb_clone_hidden_member "$src" "$(cb_state_get member_pf)" "$CB_INBOUND_UUID" || return 1
        else
            cb_clone_hidden_member "$src" || return 1
        fi
        if [ "$group" = "main" ]; then
            cb_state_set members_main "$(cb_state_get members_main) $CB_NEW_UUID"
        else
            cb_state_set members_backup "$(cb_state_get members_backup) $CB_NEW_UUID"
        fi
        added=$((added + 1))
    done
    # Freshly added sources leave the subscription listing like the rest.
    if [ "$legacy" = "0" ]; then
        cb_state_set orig_srcs "$(printf '%s\n' $(cb_state_get orig_srcs) $CB_PICKED_UUIDS | awk 'NF' | sort -u | tr '\n' ' ')"
        cb_hide_originals "$CB_PICKED_UUIDS"
        local wrapper_ib member_ibs patched new_ibs=""
        wrapper_ib=$(cb_state_get wrapper_ib)
        for src in $CB_PICKED_UUIDS; do
            new_ibs="$new_ibs $(printf '%s' "$CB_HOSTS_JSON" | jq -r --arg h "$src" '.[] | select(.uuid == $h) | .inbound.configProfileInboundUuid // ""')"
        done
        member_ibs=$(printf '%s\n' $new_ibs | awk 'NF' | sort -u | tr '\n' ' ')
        # A failure here leaves the wrapper unseen in one squad; the member
        # itself is already in, so carry on and record whatever was patched.
        patched=$(cb_patch_squads "$wrapper_ib" "$member_ibs")
        if [ -n "$patched" ]; then
            cb_state_set squads_patched "$(printf '%s\n' $(cb_state_get squads_patched) $patched | awk 'NF' | sort -u | tr '\n' ' ')"
            echo -e " ${COLOR_GRAY}$(printf "${LANG[CB_SQUAD_NOTE]}" "$(printf '%s\n' $patched | wc -l)")${COLOR_RESET}"
        fi
    fi
    step_do "${LANG[CB_TEMPLATE_REFRESH]}"
    CB_MAIN_UUIDS=$(cb_state_get members_main)
    CB_BACKUP_UUIDS=$(cb_state_get members_backup)
    cb_template_refresh || return 1
    step_ok "$(printf "${LANG[CB_ADD_OK]}" "$added")"
    if [ "$group" = "backup" ]; then
        echo -e " ${COLOR_GRAY}${LANG[CB_BACKUP_FIRST_NOTE]}${COLOR_RESET}"
    fi
}

cb_member_remove() {
    local entries=() entry pick i uuid group
    local main_list backup_list
    main_list=$(cb_state_get members_main)
    backup_list=$(cb_state_get members_backup)

    local all="$main_list ${backup_list:+$backup_list}"
    while IFS= read -r entry; do
        [ -n "$entry" ] && entries+=("$entry")
    done < <(
        for uuid in $main_list; do
            printf '%s\tmain\t%s\n' "$uuid" "$(cb_host_summary "$uuid")"
        done
        for uuid in $backup_list; do
            printf '%s\tbackup\t%s\n' "$uuid" "$(cb_host_summary "$uuid")"
        done
    )
    if [ "${#entries[@]}" -eq 0 ]; then
        echo -e "${COLOR_RED}${LANG[CB_NOT_READY]}${COLOR_RESET}"
        return 1
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CB_REMOVE_TITLE]}${COLOR_RESET}"
    echo -e ""
    i=1
    for entry in "${entries[@]}"; do
        uuid=$(echo "$entry" | cut -f1)
        group=$(echo "$entry" | cut -f2)
        if [ "$group" = "main" ]; then
            echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}$(echo "$entry" | cut -f3)${COLOR_RESET} ${COLOR_GRAY}— ${LANG[CB_GROUP_MAIN]}${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}$(echo "$entry" | cut -f3)${COLOR_RESET} ${COLOR_GRAY}— ${LANG[CB_GROUP_BACKUP]}${COLOR_RESET}"
        fi
        i=$((i + 1))
    done
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$((i - 1))")" pick || { echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1; }
    if ! [ "$pick" -ge 1 ] 2>/dev/null || [ "$pick" -gt "${#entries[@]}" ]; then
        printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$((i - 1))"
        sleep 1
        return 1
    fi

    entry="${entries[$((pick - 1))]}"
    uuid=$(echo "$entry" | cut -f1)
    group=$(echo "$entry" | cut -f2)

    local min_main=2
    [ "$(cb_state_get preset)" = "reserve" ] && min_main=1
    if [ "$group" = "main" ]; then
        local main_n
        main_n=$(printf '%s\n' $main_list | wc -w)
        if [ "$main_n" -le "$min_main" ]; then
            printf "${COLOR_YELLOW}${LANG[CB_REMOVE_REFUSE]}${COLOR_RESET}\n" "$min_main"
            return 1
        fi
    fi

    step_do "$(printf "${LANG[CB_REMOVE_STEP]}" "$(echo "$entry" | cut -f3)")"
    if [ "$(cb_state_get mode)" = "mihomo" ]; then
        local new_list="" u
        if [ "$group" = "main" ]; then
            for u in $main_list; do [ "$u" = "$uuid" ] || new_list="${new_list:+$new_list }$u"; done
            cb_state_set members_main "$new_list"
        else
            for u in $backup_list; do [ "$u" = "$uuid" ] || new_list="${new_list:+$new_list }$u"; done
            cb_state_set members_backup "$new_list"
        fi
        step_do "${LANG[CB_MH_UPDATE_STEP]}"
        cb_mh_refresh || return 1
        step_ok "${LANG[CB_REMOVE_OK]}"
        if [ "$group" = "backup" ] && [ -z "$(cb_state_get members_backup)" ]; then
            echo -e " ${COLOR_GRAY}${LANG[CB_BACKUP_EMPTY_NOTE]}${COLOR_RESET}"
        fi
        return 0
    fi
    if ! cb_host_delete "$uuid"; then
        err_msg "$(printf "${LANG[CB_REMOVE_FAIL]}" "$uuid")"
        return 1
    fi
    local new_list=""
    local u
    for u in $main_list; do
        [ "$group" = "main" ] && [ "$u" = "$uuid" ] && continue
        new_list="${new_list:+$new_list }$u"
    done
    [ "$group" = "main" ] && cb_state_set members_main "$new_list"
    if [ "$group" = "backup" ]; then
        new_list=""
        for u in $backup_list; do
            [ "$u" = "$uuid" ] && continue
            new_list="${new_list:+$new_list }$u"
        done
        cb_state_set members_backup "$new_list"
    fi

    step_do "${LANG[CB_TEMPLATE_REFRESH]}"
    CB_MAIN_UUIDS=$(cb_state_get members_main)
    CB_BACKUP_UUIDS=$(cb_state_get members_backup)
    cb_template_refresh || return 1
    step_ok "${LANG[CB_REMOVE_OK]}"
    if [ "$group" = "backup" ] && [ -z "$(cb_state_get members_backup)" ]; then
        echo -e " ${COLOR_GRAY}${LANG[CB_BACKUP_EMPTY_NOTE]}${COLOR_RESET}"
    fi
}

cb_rename() {
    local current new
    current=$(cb_state_get vhost_remark)
    reading "$(printf "${LANG[CB_RENAME_PROMPT]}" "$current")" new || { echo -e "${COLOR_YELLOW}${LANG[CB_ABORTED]}${COLOR_RESET}"; return 1; }
    new="${new:-$current}"
    if [ "$new" = "$current" ]; then
        echo -e "${COLOR_YELLOW}${LANG[CB_RENAME_SAME]}${COLOR_RESET}"
        return 0
    fi
    local uuid body response
    if [ "$(cb_state_get mode)" = "mihomo" ]; then
        step_do "${LANG[CB_MH_UPDATE_STEP]}"
        cb_state_set mh_group "$new"
        cb_state_set vhost_remark "$new"
        cb_mh_refresh || return 1
        step_ok "$(printf "${LANG[CB_RENAME_OK]}" "$new")"
        return 0
    fi
    uuid=$(cb_state_get vhost_uuid)
    body=$(cb_host_roundtrip_body "$uuid" "$(jq -nc --arg r "$new" '{remark: $r}')")
    response=$(cb_api "PATCH" "/api/hosts" "$body")
    echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1 || {
        err_msg "$(printf "${LANG[CB_API_FAIL]}" "$response")"
        return 1
    }
    cb_state_set vhost_remark "$new"
    step_ok "$(printf "${LANG[CB_RENAME_OK]}" "$new")"
}

cb_teardown() {
    local uuid leftovers="" label
    step_do "$(printf "${LANG[CB_TEARDOWN_STEP]}" "$(cb_state_get vhost_remark)")"
    if [ "$(cb_state_get mode)" = "mihomo" ]; then
        cb_mh_fetch_default || return 1
        cb_mh_remove_block || { err_msg "${LANG[CB_TEMPLATE_BUILD_FAIL]}"; return 1; }
        cb_mh_patch absent || { err_msg "$(printf "${LANG[CB_MH_FAIL]}" "template update rejected")"; return 1; }
        cb_state_clear
        step_ok "${LANG[CB_TEARDOWN_OK]}"
        return 0
    fi
    for uuid in $(cb_state_get members_main) $(cb_state_get members_backup); do
        cb_host_delete "$uuid" || leftovers="${leftovers:+$leftovers }$uuid"
    done
    uuid=$(cb_state_get vhost_uuid)
    [ -n "$uuid" ] && { cb_host_delete "$uuid" || leftovers="${leftovers:+$leftovers }$uuid"; }

    # Nodes borrowed for the dedicated profile go back to their own profiles,
    # then the emptied profile itself is removed. Legacy 3.8 balancers stored
    # ONE inbound per node, which silently dropped the profile's other
    # inbounds on teardown — so the whole profile's inbound list is restored
    # (for the usual one-inbound-per-profile layout that is the same thing).
    local restore bind n opf oib by_pair pair response uuids ib_list
    restore=$(cb_state_get node_restore)
    if [ -n "$restore" ]; then
        step_do "${LANG[CB_UNIFY_BACK_STEP]}"
        by_pair=$(printf '%s\n' $restore | awk -F= '{print $2 "/" $3}' | sort -u)
        for pair in $by_pair; do
            opf="${pair%%/*}"
            oib="${pair#*/}"
            uuids=""
            for bind in $restore; do
                n=$(echo "$bind" | cut -d= -f1)
                [ "$(echo "$bind" | cut -d= -f2)" = "$opf" ] && [ "$(echo "$bind" | cut -d= -f3)" = "$oib" ] && uuids="$uuids $n"
            done
            ib_list=$(cb_api "GET" "/api/config-profiles/$opf" 2>/dev/null \
                | jq -r '.response.inbounds[]?.uuid' 2>/dev/null | awk 'NF' | tr '\n' ' ')
            [ -n "${ib_list// /}" ] || ib_list="$oib"
            local ibs_json
            ibs_json=$(printf '%s\n' $ib_list | jq -R -s 'split("\n") | map(select(length > 0))')
            response=$(cb_api "POST" "/api/nodes/bulk-actions/profile-modification" \
                "$(jq -nc --arg pf "$opf" --argjson ibs "$ibs_json" --arg us "$uuids" \
                    '{uuids: ($us | split(" ") | map(select(length > 0))),
                      configProfile: {activeConfigProfileUuid: $pf, activeInbounds: $ibs}}')")
            echo "$response" | jq -e '.message // .statusCode' >/dev/null 2>&1 \
                && leftovers="${leftovers:+$leftovers }node:${uuids// /,}"
        done
        # grep -c prints a "0" even on no match, so the count decides here.
        [ "$(printf '%s\n' "$leftovers" | grep -c "node:")" -eq 0 ] && step_ok "${LANG[CB_UNIFY_BACK_OK]}"
    fi
    # Squads that got the wrapper inbound added lose it again (a fresh
    # balancer's only footprint besides the hosts and the template).
    local patched
    patched=$(cb_state_get squads_patched)
    if [ -n "$patched" ]; then
        step_do "${LANG[CB_SQUAD_BACK_STEP]}"
        cb_revert_squad_pairs "$patched" \
            || leftovers="${leftovers:+$leftovers }squad:${patched// /,}"
        [ "$(printf '%s\n' "$leftovers" | grep -c "squad:")" -eq 0 ] && step_ok "${LANG[CB_SQUAD_BACK_OK]}"
    fi
    # Originals hidden at creation come back once their nodes are home.
    cb_unhide_originals
    uuid=$(cb_state_get member_pf)
    if [ -n "$uuid" ]; then
        # Fresh profile list: the menu may not have loaded it this session.
        cb_fetch_profiles >/dev/null 2>&1
        local pf_name
        pf_name=$(printf '%s' "${CB_PROFILES_JSON:-[]}" | jq -r --arg p "$uuid" '.[]? | select(.uuid == $p) | .name // empty' 2>/dev/null)
        # Only the profile this wizard created disappears on teardown; the
        # one the members originally lived on stays.
        if [ "$pf_name" = "${CB_PROFILE_NAME}" ] || [ "${pf_name#"${CB_PROFILE_NAME} "}" != "$pf_name" ]; then
            cb_api "DELETE" "/api/config-profiles/$uuid" >/dev/null 2>&1 \
                || leftovers="${leftovers:+$leftovers }profile:$uuid"
        fi
    fi
    uuid=$(cb_state_get template_uuid)
    [ -n "$uuid" ] && { cb_template_delete "$uuid" || leftovers="${leftovers:+$leftovers }$uuid"; }
    if [ -n "$leftovers" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[CB_TEARDOWN_PARTIAL]}" "$leftovers")${COLOR_RESET}"
        cb_state_clear
        return 1
    fi
    cb_state_clear
    step_ok "${LANG[CB_TEARDOWN_OK]}"
}

# Light status lines for the submenu header: state counts plus, when the
# saved token works, a live check that wrapper and template still exist.
cb_status_live() {
    local preset main_n backup_n response
    preset=$(cb_state_get preset)
    main_n=$(printf '%s\n' $(cb_state_get members_main) | wc -w)
    backup_n=$(printf '%s\n' $(cb_state_get members_backup) | wc -w)
    local groups
    groups=$(printf "${LANG[CB_STATUS_GROUPS]}" "$main_n")
    [ "$backup_n" -gt 0 ] && groups="$groups$(printf "${LANG[CB_STATUS_BACKUP]}" "$backup_n")"
    echo -e " ${COLOR_GRAY}${groups}${COLOR_RESET}"
    if [ "$preset" = "reserve" ]; then
        echo -e " ${COLOR_GRAY}${LANG[CB_STATUS_PRESET_RESERVE]}${COLOR_RESET}"
    else
        echo -e " ${COLOR_GRAY}${LANG[CB_STATUS_PRESET_BALANCER]}${COLOR_RESET}"
    fi

    cb_saved_token_works || return 0
    if [ "$(cb_state_get mode)" = "mihomo" ]; then
        local name template_uuid tpl
        name="$CB_CURRENT"
        template_uuid=$(cb_state_get template_uuid)
        tpl=$(cb_api "GET" "/api/subscription-templates/$template_uuid" 2>/dev/null)
        if echo "$tpl" | jq -r '.response.encodedTemplateYaml // empty' | base64 -d 2>/dev/null | grep -q " # cb:${name}\$"; then
            echo -e " ${COLOR_GRAY}${LANG[CB_MH_GROUP_OK]}${COLOR_RESET}"
        else
            echo -e " ${COLOR_RED}${LANG[CB_MH_GROUP_GONE]}${COLOR_RESET}"
        fi
        return 0
    fi
    response=$(cb_api "GET" "/api/hosts/$(cb_state_get vhost_uuid)" 2>/dev/null)
    if echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        echo -e " ${COLOR_GRAY}${LANG[CB_STATUS_VHOST_OK]}${COLOR_RESET}"
    else
        echo -e " ${COLOR_RED}${LANG[CB_STATUS_VHOST_GONE]}${COLOR_RESET}"
    fi
    response=$(cb_api "GET" "/api/subscription-templates/$(cb_state_get template_uuid)" 2>/dev/null)
    if echo "$response" | jq -e '.response.uuid' >/dev/null 2>&1; then
        echo -e " ${COLOR_GRAY}${LANG[CB_STATUS_TEMPLATE_OK]}${COLOR_RESET}"
    else
        echo -e " ${COLOR_RED}${LANG[CB_STATUS_TEMPLATE_GONE]}${COLOR_RESET}"
    fi
}

# --- menus --------------------------------------------------------------------------------

show_client_balancer_menu() {
    local names=() name i label preset
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(cb_balancers_list)

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CB_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[CB_DOC_LINK]}${COLOR_RESET}"
    echo -e ""

    if [ "${#names[@]}" -eq 0 ]; then
        echo -e " ${COLOR_GRAY}${LANG[CB_NONE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[CB_MENU_NEW]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        local pick
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 1)" pick || return 0
        case "$pick" in
            1)
                cb_setup
                sleep 2
                show_client_balancer_menu
                ;;
            0) return 0 ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 1
                sleep 1
                show_client_balancer_menu
                ;;
        esac
        return 0
    fi

    echo -e " ${COLOR_GRAY}$(printf "${LANG[CB_COUNT]}" "${#names[@]}")${COLOR_RESET}"
    echo -e ""
    # The render loop borrows CB_CURRENT to read each balancer's state; it
    # must not leak past the loop — a leftover value would make "create"
    # write the new balancer's state into the LAST rendered balancer's file.
    local render_prev_current="${CB_CURRENT}"
    i=1
    for name in "${names[@]}"; do
        CB_CURRENT="$name"
        label=$(cb_state_get vhost_remark)
        [ -n "$label" ] || label="$name"
        preset=$(cb_state_get preset)
        if [ "$preset" = "reserve" ]; then
            preset="• ${LANG[CB_STATUS_PRESET_RESERVE]}"
        else
            preset="• ${LANG[CB_STATUS_PRESET_BALANCER]}"
        fi
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}$(cb_cap_first "$label")${COLOR_RESET} ${COLOR_GRAY}${preset}${COLOR_RESET}"
        i=$((i + 1))
    done
    CB_CURRENT="$render_prev_current"
    local new=$i
    echo -e "${COLOR_YELLOW}${new}. ${LANG[CB_MENU_NEW]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local pick
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$new")" pick || return 0
    case "$pick" in
        0) return 0 ;;
        "$new")
            cb_setup
            sleep 2
            show_client_balancer_menu
            ;;
        *)
            if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#names[@]}" ]; then
                cb_balancer_menu "${names[$((pick - 1))]}"
                sleep 1
                show_client_balancer_menu
            else
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$new"
                sleep 1
                show_client_balancer_menu
            fi
            ;;
    esac
}

# Everything in this menu acts on the balancer it was opened for.
cb_balancer_menu() {
    local name="$1"
    CB_CURRENT="$name"
    [ -f "$(cb_state_file)" ] || return 1
    local label
    label=$(cb_state_get vhost_remark)
    [ -n "$label" ] || label="$name"

    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[CB_MENU_TITLE]}" "$(cb_cap_first "$label")")${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[CB_DOC_LINK]}${COLOR_RESET}"
    echo -e ""
    cb_status_live
    echo -e ""

    echo -e "${COLOR_YELLOW}1. ${LANG[CB_MENU_SHOW]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_MENU_SHOW_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[CB_MENU_ADD]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_MENU_ADD_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[CB_MENU_REMOVE]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_MENU_REMOVE_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[CB_MENU_RENAME]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_MENU_RENAME_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[CB_MENU_TEARDOWN]}${COLOR_RESET}"
    echo -e "    ${COLOR_GRAY}${LANG[CB_MENU_TEARDOWN_HINT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local pick
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 5)" pick || return 0
    case "$pick" in
        1)
            if get_panel_token; then
                cb_members_show
            fi
            sleep 2
            cb_balancer_menu "$name"
            ;;
        2)
            if get_panel_token; then
                cb_member_add
            fi
            sleep 2
            cb_balancer_menu "$name"
            ;;
        3)
            if get_panel_token; then
                cb_member_remove
            fi
            sleep 2
            cb_balancer_menu "$name"
            ;;
        4)
            if get_panel_token; then
                cb_rename
            fi
            sleep 2
            cb_balancer_menu "$name"
            ;;
        5)
            if reading_yn "$(printf "${LANG[CB_TEARDOWN_CONFIRM]}" "$(cb_cap_first "$label")")" confirm_teardown; then
                if get_panel_token; then
                    cb_teardown
                fi
            fi
            sleep 2
            ;;
        0) return 0 ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 5
            sleep 1
            cb_balancer_menu "$name"
            ;;
    esac
}

manage_client_balancer() {
    # The submenu header may call the panel (cb_status_live via the saved
    # token), so the API module must be in place before any menu renders.
    load_api_module || return 1
    show_client_balancer_menu
}
