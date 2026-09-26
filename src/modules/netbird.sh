#!/bin/bash
# Module: NetBird — mesh-подключение панели и нод (basic mode).
# Design contract: Netbird.md §6–§11. Orchestrator is the panel box: it holds
# the panel token and the remote_exec key. SSH to managed machines ALWAYS goes
# over their public address; the overlay IP is only an alias for lookup.
# Nothing is ever bound to the overlay IP and no Docker port is published on
# it (moby#39559: Exited(128) after reboot). The public 2222 path from the
# panel to every node stays in place as the fallback; closing it is a separate
# explicit action that this stage does not offer.

NB_DIR="${DIR_REMNAWAVE}netbird"
NB_STATE="$NB_DIR/netbird.json"
NB_NODES_DIR="$NB_DIR/nodes"
NB_AUDIT="$NB_DIR/audit.log"
NB_LOCK="$NB_DIR/.lock"
NB_PAT_FILE="$NB_DIR/pat"
# NetBird management API (cloud). NB_API_BASE further below is the PANEL's
# API — two different backends, two names.
NB_NB_API_BASE="https://api.netbird.io"
NB_IFACE="wt0"
NB_MIN_VERSION="0.71"
NB_NODE_PORT=2222
NB_API_BASE="http://127.0.0.1:3000"
NB_RUN_ID="${NB_RUN_ID:-$RANDOM$RANDOM}"
NB_NOTE_MARK_PREFIX="[rrp-nb:old="
# Every netbird up must carry the full set, = form only: "up" persists only
# flags passed explicitly and ignores a bare "--flag false" positional.
NB_UP_FLAGS="--disable-dns=true --disable-client-routes=true --disable-server-routes=true --block-inbound=false --disable-firewall=false"

# ---------------------------------------------------------------------------
# State, journal, audit (§9). Files are read with jq/sed, never sourced.
# Writes go tmp + mv under the module lock; everything is 600.
# ---------------------------------------------------------------------------

nb_ensure_dirs() {
    mkdir -p "$NB_DIR" "$NB_NODES_DIR" 2>/dev/null
    chmod 700 "$NB_DIR" "$NB_NODES_DIR" 2>/dev/null
}

# Both getters accept the field with or without the leading dot; jq needs it.
nb_state_get() {
    [ -f "$NB_STATE" ] || return 1
    jq -r ".${1#.} // empty" "$NB_STATE" 2>/dev/null
}

nb_state_set() {
    local key="$1" val="$2" cur
    nb_ensure_dirs
    cur=$(cat "$NB_STATE" 2>/dev/null) || cur="{}"
    printf '%s' "$cur" | jq --arg k "$key" --arg v "$val" '.[$k] = $v' > "${NB_STATE}.tmp" 2>/dev/null || return 1
    mv -f "${NB_STATE}.tmp" "$NB_STATE"
    chmod 600 "$NB_STATE" 2>/dev/null
}

nb_node_file() { printf '%s/%s.json' "$NB_NODES_DIR" "$1"; }

nb_node_exists() { [ -f "$(nb_node_file "$1")" ]; }

nb_node_get() {
    local f
    f=$(nb_node_file "$1")
    [ -f "$f" ] || return 1
    jq -r ".${2#.} // empty" "$f" 2>/dev/null
}

# Set one string field on a node record; creates the record when absent.
nb_node_set() {
    local uuid="$1" key="$2" val="$3" f cur
    f=$(nb_node_file "$uuid")
    nb_ensure_dirs
    cur=$(cat "$f" 2>/dev/null) || cur='{}'
    printf '%s' "$cur" | jq --arg k "$key" --arg v "$val" '.[$k] = $v' > "${f}.tmp" 2>/dev/null || return 1
    mv -f "${f}.tmp" "$f"
    chmod 600 "$f" 2>/dev/null
}

nb_node_state() { nb_node_set "$1" state "$2"; }

nb_journal() {
    local uuid="$1" step="$2" phase="$3" f cur
    f=$(nb_node_file "$uuid")
    [ -f "$f" ] || return 0
    cur=$(cat "$f")
    printf '%s' "$cur" | jq --arg s "$step" --arg p "$phase" --arg t "$(date -u +%FT%TZ)" \
        '.journal += [{"step":$s,"phase":$p,"ts":$t}]' > "${f}.tmp" 2>/dev/null || return 0
    mv -f "${f}.tmp" "$f"
    chmod 600 "$f" 2>/dev/null
}

# One line per mutation, no secrets: what changed, on which object.
nb_audit() {
    nb_ensure_dirs
    printf '%s\t%s\n' "$(date -u +%FT%TZ)" "$*" >> "$NB_AUDIT"
    chmod 600 "$NB_AUDIT" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Small IP helpers. Everything is IPv4; overlay traffic is what we route.
# ---------------------------------------------------------------------------

nb_is_ipv4() { printf '%s' "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'; }

nb_ip_int() {
    local o
    IFS='.' read -r -a o <<< "$1"
    [ "${#o[@]}" -eq 4 ] || return 1
    echo $(( (o[0] << 24) + (o[1] << 16) + (o[2] << 8) + o[3] ))
}

# rc=0 when ip (bare or with /mask) falls inside cidr.
nb_cidr_holds() {
    local ip net bits ipi neti mask
    ip="${1%/*}"
    net="${2%/*}"
    bits="${2#*/}"
    nb_is_ipv4 "$ip" || return 1
    nb_is_ipv4 "$net" || return 1
    [ "$bits" -ge 0 ] && [ "$bits" -le 32 ] 2>/dev/null || return 1
    ipi=$(nb_ip_int "$ip") || return 1
    neti=$(nb_ip_int "$net") || return 1
    mask=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( ipi & mask )) -eq $(( neti & mask )) ]
}

# Panel public IPv4 over https with validation — the answer is substituted
# into root-level remote commands, so an error page must never slip through.
nb_public_ipv4() {
    local ip
    ip=$(curl -fsS4 --connect-timeout 8 --max-time 15 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
    nb_is_ipv4 "$ip" || return 1
    printf '%s' "$ip"
}

# ---------------------------------------------------------------------------
# Local client probes
# ---------------------------------------------------------------------------

nb_pkg_installed() { dpkg -s netbird >/dev/null 2>&1; }

nb_client_version() { netbird version 2>/dev/null | head -n1 | tr -d '[:space:]'; }

nb_status_json() { timeout 15 netbird status --json 2>/dev/null; }

nb_mgmt_connected() { nb_status_json | jq -e '.management.connected == true' >/dev/null 2>&1; }

nb_mgmt_url() { nb_status_json | jq -r '.management.url // empty' 2>/dev/null; }

nb_wt0_ip() {
    ip -4 -o addr show dev "$NB_IFACE" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}'
}

nb_wt0_cidr() {
    ip -4 -o addr show dev "$NB_IFACE" 2>/dev/null | awk '{print $4; exit}'
}

# Overlay prefix of the account as seen on this machine (/16 from wt0).
nb_overlay_prefix() {
    local c
    c=$(nb_wt0_cidr)
    [ -n "$c" ] && printf '%s' "$c"
}

nb_lazy_off() {
    grep -q 'NB_LAZY_CONN.*off' /var/lib/netbird/service.json 2>/dev/null
}

nb_hold_on() { apt-mark showhold 2>/dev/null | grep -qx netbird; }

# Actual up-flags from the local profile; "ok" when they match the contract.
# Only profiles with a ManagementURL count (a registered client): the directory
# also holds active_profile.json/state.json whose missing fields read as
# "false" and used to flag every never-connected client as bad.
nb_profile_flags_bad() {
    local f v bad=0
    for f in /var/lib/netbird/*.json; do
        [ -f "$f" ] || continue
        jq -e '(.ManagementURL // "") != ""' "$f" >/dev/null 2>&1 || continue
        v=$(jq -r '[.DisableDNS, .DisableClientRoutes, .DisableServerRoutes, .BlockInbound, .DisableFirewall] | @tsv' "$f" 2>/dev/null)
        [ "$v" = $'true\ttrue\ttrue\tfalse\tfalse' ] || bad=1
    done
    # Predicate semantics, as every caller uses it: rc=0 means "flags are
    # bad" (a warning is due). The old `return $bad` was inverted — a
    # healthy client printed "flags: BAD" and a broken one stayed silent.
    [ "$bad" -eq 1 ]
}

nb_ipv6_disabled() {
    [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "1" ]
}

nb_extra_up_flags() {
    nb_ipv6_disabled && printf ' --disable-ipv6=true'
    return 0
}

# ---------------------------------------------------------------------------
# Machine roles (panel / node / anything else)
# ---------------------------------------------------------------------------

nb_role_is_node() {
    { [ -f /opt/remnanode/docker-compose.yml ] && grep -q "^[[:space:]]*remnanode:" /opt/remnanode/docker-compose.yml; } || \
    { [ -f /opt/remnawave/docker-compose.yml ] && grep -q "^[[:space:]]*remnanode:" /opt/remnawave/docker-compose.yml; }
}

# ---------------------------------------------------------------------------
# remote_exec dependency (lazy): only flows that touch other machines load it
# ---------------------------------------------------------------------------

nb_need_re() {
    command -v re_run_host_n >/dev/null 2>&1 && return 0
    load_remote_exec_module
}

# ---------------------------------------------------------------------------
# Install (§8.1 step 2) — apt repo, detached install, hold, lazy off
# ---------------------------------------------------------------------------

nb_apt_repo_script() {
    cat <<'EOL'
set -e
if ! dpkg -s netbird >/dev/null 2>&1; then
    # Armored key straight into signed-by: no gpg --dearmor (it demands a
    # tty headless), supported by apt >= 2.4 (Debian 12+, Ubuntu 22.04+).
    curl -fsSL --connect-timeout 10 -o /usr/share/keyrings/netbird-archive-keyring.asc https://pkgs.netbird.io/debian/public.key
    printf '%s\n' "deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.asc] https://pkgs.netbird.io/debian stable main" > /etc/apt/sources.list.d/netbird.list
    apt-get -o DPkg::Lock::Timeout=300 update -y >/dev/null
fi
EOL
}

nb_apt_install_script() {
    cat <<'EOL'
set -e
systemd-run --unit=rrp-nb-apt-INSTALL_UNIT --collect --wait \
    -p Environment=DEBIAN_FRONTEND=noninteractive \
    apt-get -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300 install -y netbird
apt-mark hold netbird
command -v netbird >/dev/null 2>&1
EOL
}

nb_lazy_off_script() {
    cat <<'EOL'
netbird service reconfigure --service-env NB_LAZY_CONN=off >/dev/null 2>&1
grep -q 'NB_LAZY_CONN.*off' /var/lib/netbird/service.json 2>/dev/null
EOL
}

# Local install of the client. Idempotent: an installed package is a success.
nb_install_local() {
    nb_pkg_installed && return 0
    step_do "${LANG[NB_INSTALLING]}"
    if ! bash -c "$(nb_apt_repo_script)" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[NB_INSTALL_FAIL]}${COLOR_RESET}"
        return 1
    fi
    local install_script unit="rrp-nb-apt-${NB_RUN_ID}"
    install_script=$(nb_apt_install_script)
    install_script=${install_script//INSTALL_UNIT/$unit}
    if ! bash -c "$install_script" >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[NB_INSTALL_FAIL]}${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[NB_INSTALL_OK]}"
    return 0
}

# ---------------------------------------------------------------------------
# Registration (§8.1 step 4). The setup key never touches argv: it travels
# through stdin into a tmpfs file inside one ssh call, with a trap guarding
# the cleanup. `up` runs under env -i so no ambient NB_* leaks in (F20).
# ---------------------------------------------------------------------------

nb_read_hidden() {
    printf ' %s' "$(question "$1")"
    read -rs "$2"
    local rc=$?
    echo ""
    return "$rc"
}

nb_up_script() {
    local hn="$1" mgmt="$2" flags run f
    flags="${NB_UP_FLAGS}$(nb_extra_up_flags)"
    run="rrp${NB_RUN_ID}"
    f="/run/rrp-nb/key.${run}"
    read -r -d '' run_script <<EOS || true
set -e
umask 077
install -d -m 700 /run/rrp-nb
f='${f}'
trap 'rm -f "\$f"' EXIT
IFS= read -r k
printf '%s' "\$k" > "\$f"
unset k
env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin netbird up --setup-key-file "\$f" --hostname '${hn}' ${flags}${mgmt:+ --management-url '${mgmt}'}
rc=\$?
[ \$rc -ne 0 ] && exit \$rc
i=0
while [ \$i -lt 20 ]; do
    if netbird status --json 2>/dev/null | grep -q '"connected"[[:space:]]*:[[:space:]]*true'; then
        ip=\$(netbird status -4 2>/dev/null | tr -d '[:space:]')
        if [[ "\$ip" =~ ^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+\$ ]]; then
            echo "RRP_OVERLAY=\$ip"
            exit 0
        fi
    fi
    sleep 3
    i=\$((i + 1))
done
exit 3
EOS
    printf '%s' "$run_script"
}

# Key comes from a variable on the caller side and is piped; it is not
# exported anywhere and is unset right after the call.
nb_up_local() {
    local key="$1" hn="$2" mgmt="$3" script rc
    script=$(nb_up_script "$hn" "$mgmt")
    printf '%s\n' "$key" | bash -c "$script"
    rc=$?
    return $rc
}

nb_wait_ready() {
    local deadline=$(( $(date +%s) + 60 ))
    while [ "$(date +%s)" -lt "$deadline" ]; do
        nb_mgmt_connected && [ -n "$(nb_wt0_ip)" ] && return 0
        sleep 3
    done
    return 1
}

# ---------------------------------------------------------------------------
# Panel API helpers
# ---------------------------------------------------------------------------

# Panel API access. Must run in the CALLER's shell (no command
# substitution): the sourcing of remnawave_api.sh has to land where
# rw_token_is_api/make_api_request are used afterwards.
nb_load_api() {
    load_api_module || return 1
    [ -s "${DIR_REMNAWAVE}token" ] || return 1
    return 0
}

nb_api_token() {
    nb_load_api || return 1
    cat "${DIR_REMNAWAVE}token"
}

nb_api_nodes() {
    # self-sufficient: this helper may run in a subshell where no flow
    # loaded the panel API module beforehand
    command -v make_api_request >/dev/null 2>&1 || load_api_module >/dev/null 2>&1 || true
    make_api_request "GET" "${NB_API_BASE}/api/nodes?_=$(date +%s)" "$1"
}

nb_node_obj() {
    echo "$1" | jq -r --arg u "$2" '[.response[]? | select(.uuid == $u)][0] // empty' 2>/dev/null
}

nb_patch_node_address() {
    # self-sufficient: this helper may run in a subshell where no flow
    # loaded the panel API module beforehand
    command -v make_api_request >/dev/null 2>&1 || load_api_module >/dev/null 2>&1 || true
    local token="$1" uuid="$2" address="$3" r
    r=$(make_api_request "PATCH" "${NB_API_BASE}/api/nodes" "$token" \
        "{\"uuid\":\"$uuid\",\"address\":\"$address\"}")
    echo "$r" | jq -e --arg a "$address" '.response.address == $a' >/dev/null 2>&1
}

# Success = confirmed reconnection AFTER the change, not the legacy
# isConnected alone: a stale true from before the PATCH lies (F16).
nb_wait_node_connected() {
    local token="$1" uuid="$2" t0="$3" wait_s="${4:-120}" stable_s="${5:-45}"
    local deadline=$(( $(date +%s) + wait_s )) ok_since=0
    while [ "$(date +%s)" -lt "$deadline" ]; do
        local obj isc iconn lsc ep
        obj=$(nb_node_obj "$(nb_api_nodes "$token")" "$uuid")
        isc=$(echo "$obj" | jq -r '.isConnecting // false' 2>/dev/null)
        iconn=$(echo "$obj" | jq -r '.isConnected // false' 2>/dev/null)
        lsc=$(echo "$obj" | jq -r '.lastStatusChange // empty' 2>/dev/null)
        if [ "$isc" = "false" ] && [ "$iconn" = "true" ] && [ -n "$lsc" ]; then
            ep=$(date -d "$lsc" +%s 2>/dev/null || echo 0)
            if [ "$ep" -ge $(( t0 - 5 )) ]; then
                [ "$ok_since" -eq 0 ] && ok_since=$(date +%s)
                if [ $(( $(date +%s) - ok_since )) -ge "$stable_s" ]; then return 0; fi
            else
                ok_since=0
            fi
        else
            ok_since=0
        fi
        sleep 3
    done
    return 1
}

# note marker: the node's pre-migration address must survive panel edits.
# Pure string ops: the marker's "[" would read as a bracket expression in sed.
nb_note_strip() {
    local out="$1" marker="$NB_NOTE_MARK_PREFIX"
    while [[ "$out" == *"${marker}"* ]]; do
        out="${out%%"${marker}"*}${out#*"]"}"
    done
    printf '%s' "$out"
}

nb_note_old_addr() {
    local s="$1" marker="$NB_NOTE_MARK_PREFIX"
    [[ "$s" == *"${marker}"* ]] || return 0
    s="${s#*"${marker}"}"
    printf '%s' "${s%%]*}"
}

nb_patch_note() {
    # self-sufficient: this helper may run in a subshell where no flow
    # loaded the panel API module beforehand
    command -v make_api_request >/dev/null 2>&1 || load_api_module >/dev/null 2>&1 || true
    local token="$1" uuid="$2" note="$3"
    make_api_request "PATCH" "${NB_API_BASE}/api/nodes" "$token" \
        "{\"uuid\":\"$uuid\",\"note\":$(printf '%s' "$note" | jq -R .)}" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Path check (§8.2 step 6) — from the panel backend's own network namespace.
# A host-side check proves nothing about the bridge → MASQUERADE → wt0 path.
# ---------------------------------------------------------------------------

nb_path_check() {
    local ov="$1" pid
    nb_is_ipv4 "$ov" || return 1
    pid=$(docker inspect -f '{{.State.Pid}}' remnawave 2>/dev/null)
    [ -n "$pid" ] && [ "$pid" -gt 0 ] 2>/dev/null || return 1
    nsenter -t "$pid" -n timeout 5 bash -c "</dev/tcp/${ov}/${NB_NODE_PORT}" 2>/dev/null || return 1
    if command -v openssl >/dev/null 2>&1; then
        # Server flight of the node mTLS handshake is >1280 bytes: this also
        # proves the PMTU is not broken through the tunnel.
        nsenter -t "$pid" -n timeout 10 openssl s_client -connect "${ov}:${NB_NODE_PORT}" </dev/null 2>/dev/null \
            | grep -qE 'Cipher is|BEGIN CERTIFICATE' || return 1
    fi
    return 0
}

nb_path_check_retry() {
    local ov="$1" attempt rc=1
    for attempt in 1 2 3 4 5 6; do
        nb_path_check "$ov" && { rc=0; break; }
        sleep 5
    done
    return $rc
}

# ---------------------------------------------------------------------------
# DNS guard (§8.2 step 3). Docker snapshots the host resolv.conf at container
# start and strips comments, so detection goes by nameserver lines (F8).
# rc=9 means the node container still runs with NetBird's resolver.
# ---------------------------------------------------------------------------

nb_dns_guard_script() {
    cat <<'EOL'
p=$(docker inspect -f '{{.ResolvConfPath}}' remnanode 2>/dev/null) || exit 0
[ -n "$p" ] && [ -f "$p" ] || exit 0
grep '^nameserver' "$p" 2>/dev/null | awk '{print $2}' | sort > /tmp/rrp-nb-a.$$
grep '^nameserver' /etc/resolv.conf 2>/dev/null | awk '{print $2}' | sort > /tmp/rrp-nb-b.$$
if ! cmp -s /tmp/rrp-nb-a.$$ /tmp/rrp-nb-b.$$; then
    if comm -23 /tmp/rrp-nb-a.$$ /tmp/rrp-nb-b.$$ | grep -Eq '^100\.|^127\.0\.0\.(1|153)$'; then
        rm -f /tmp/rrp-nb-a.$$ /tmp/rrp-nb-b.$$
        exit 9
    fi
fi
rm -f /tmp/rrp-nb-a.$$ /tmp/rrp-nb-b.$$
exit 0
EOL
}

# ---------------------------------------------------------------------------
# Guard helpers for migration pre-flight
# ---------------------------------------------------------------------------

# Nodes referenced by server-routing bridges / ruex must not migrate until
# server_routing is overlay-aware (Netbird.md B-02/B-03): its public-source
# logic and cron lookups would silently break.
nb_sr_references() {
    local needle="$1" f
    [ -d "${DIR_REMNAWAVE}server-routing" ] || return 1
    for f in "${DIR_REMNAWAVE}server-routing"/*; do
        [ -f "$f" ] || continue
        grep -qF "$needle" "$f" 2>/dev/null && return 0
    done
    return 1
}

# Ingress/Egress plugin presets: the egress preset blocks 100.64/10 on ALL
# nodes when computed from the panel's routes — an overlay node would drop
# even the SYN-ACK to 2222 (F19, B-14).
nb_plugin_references() {
    local needle="$1" f
    for f in "${DIR_REMNAWAVE}egress-preset.state" "${DIR_REMNAWAVE}ingress-preset.state"; do
        [ -f "$f" ] || continue
        grep -qF "$needle" "$f" 2>/dev/null && return 0
    done
    return 1
}

# ---------------------------------------------------------------------------
# Join flow (§8.1) — this machine, any role
# ---------------------------------------------------------------------------

nb_join() {
    command -v jq >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_ERR_JQ]}${COLOR_RESET}"; return 3; }
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_JOIN_TITLE]}${COLOR_RESET}"
    echo -e ""

    if [ ! -e /dev/net/tun ]; then
        echo -e "${COLOR_RED}${LANG[NB_PRE_TUN]}${COLOR_RESET}"
        return 3
    fi

    if [ -d /sys/module/wireguard ]; then
        :
    else
        echo -e "${COLOR_YELLOW}${LANG[NB_PRE_WG_USERSPACE]}${COLOR_RESET}"
    fi

    local version="" registered="" fqdn=""
    if nb_pkg_installed; then
        version=$(nb_client_version)
        echo -e "${COLOR_GRAY}$(printf "${LANG[NB_PRE_INSTALLED]}" "$version")${COLOR_RESET}"
        if nb_mgmt_connected; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_PRE_CONNECTED_OTHER]}" "$(hostname -s)" "$(nb_mgmt_url)")${COLOR_RESET}"
            if reading_yn "${LANG[NB_PRE_USE_CURRENT]}" ans_use; then
                # A re-join must not demote an active API mode: the PAT is
                # still stored and one-off keys depend on it (live bug).
                [ "$(nb_state_get mode)" = "api" ] || nb_state_set mode basic
                nb_state_set mgmt_url "$(nb_mgmt_url)"
                echo -e "${COLOR_GREEN}${LANG[NB_JOIN_DONE_CURRENT]}${COLOR_RESET}"
                return 0
            fi
            echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"
            return 1
        fi
        # Installed but idle: flags of the stored profile still matter.
        if nb_profile_flags_bad; then
            echo -e "${COLOR_YELLOW}${LANG[NB_PRE_FLAGS_BAD]}${COLOR_RESET}"
        fi
    else
        curl -fsSI --connect-timeout 8 https://pkgs.netbird.io/ >/dev/null 2>&1 \
            || { echo -e "${COLOR_RED}${LANG[NB_PRE_REACH]}${COLOR_RESET}"; return 3; }
    fi

    if [ -n "$version" ]; then
        local lowest ok=1
        lowest=$(printf '%s\n' "$NB_MIN_VERSION" "$version" | sort -V | head -n1)
        [ "$lowest" = "$NB_MIN_VERSION" ] || ok=0
        if [ "$ok" -eq 0 ]; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_PRE_VERSION_OLD]}" "$version" "$NB_MIN_VERSION")${COLOR_RESET}"
            if reading_yn "${LANG[NB_PRE_ASK_UPDATE]}" ans_upd; then
                nb_update_self || return 3
            fi
        fi
    fi

    local key="" kid="" hn_def hn mgmt
    if nb_api_mode; then
        # One-off key for this machine, bound to the panel group, revoked
        # right after the successful up. Nothing for the operator to paste.
        nb_ensure_core_objects || return 3
        local kk
        kk=$(nb_oneoff_key "$(nb_state_get grp_panel)" "rrp-join-$(hostname -s)-${NB_RUN_ID}") || return 3
        kid=${kk%% *}
        key=${kk#* }
    else
        echo -e " ${COLOR_GRAY}${LANG[NB_KEY_HINT]}${COLOR_RESET}"
        while true; do
            nb_read_hidden "${LANG[NB_KEY_PROMPT]}" key || return 1
            [ -n "$key" ] && break
            echo -e "${COLOR_YELLOW}${LANG[NB_KEY_EMPTY]}${COLOR_RESET}"
        done
    fi

    hn_def=$(printf '%s' "$(hostname -s)" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-63)
    while true; do
        reading "$(printf "${LANG[NB_HOSTNAME_PROMPT]}" "$hn_def")" hn || return 1
        hn="${hn:-$hn_def}"
        hn=$(printf '%s' "$hn" | tr 'A-Z' 'a-z')
        printf '%s' "$hn" | grep -qE '^[a-z0-9-]{1,63}$' && break
        echo -e "${COLOR_RED}${LANG[NB_HOSTNAME_BAD]}${COLOR_RESET}"
    done

    echo -e " ${COLOR_GRAY}${LANG[NB_MGMT_HINT]}${COLOR_RESET}"
    while true; do
        reading "${LANG[NB_MGMT_PROMPT]}" mgmt || return 1
        [ -z "$mgmt" ] && break
        printf '%s' "$mgmt" | grep -qE '^https://[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$' && break
        echo -e "${COLOR_RED}${LANG[NB_MGMT_BAD]}${COLOR_RESET}"
    done

    nb_install_local || return 3
    # The env rides along the install on a fresh machine; an installed but
    # disconnected client gets it here too — the reconfigure restart only
    # blinks a connection that does not exist yet.
    if ! nb_lazy_off; then
        step_do "${LANG[NB_LAZY_OFF]}"
        if bash -c "$(nb_lazy_off_script)" >/dev/null 2>&1; then
            step_ok "${LANG[NB_LAZY_OFF_OK]}"
        else
            echo -e "${COLOR_YELLOW}${LANG[NB_LAZY_OFF_FAIL]}${COLOR_RESET}"
        fi
    fi

    step_do "${LANG[NB_UP_RUNNING]}"
    if ! nb_up_local "$key" "$hn" "$mgmt"; then
        unset key
        [ -n "$kid" ] && nb_revoke_setup_key "$kid"
        echo -e "${COLOR_RED}${LANG[NB_UP_FAIL]}${COLOR_RESET}"
        return 4
    fi
    unset key
    [ -n "$kid" ] && { nb_revoke_setup_key "$kid"; nb_audit "one-off key revoked (join)"; }

    step_do "${LANG[NB_WAIT_READY]}"
    nb_wait_ready || { echo -e "${COLOR_RED}${LANG[NB_READY_FAIL]}${COLOR_RESET}"; return 4; }
    local ov
    ov=$(nb_wt0_ip)
    step_ok "$(printf "${LANG[NB_READY_OK]}" "$ov")"

    # Post checks: host resolv.conf must be untouched, the account prefix must
    # not collide with local routes or docker networks.
    if grep -qE '^nameserver[[:space:]]+(100\.|127\.0\.0\.(1|153))' /etc/resolv.conf 2>/dev/null; then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_POST_RESOLV_WARN]}" "$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')")${COLOR_RESET}"
    fi
    local prefix hits=""
    prefix=$(nb_overlay_prefix)
    [ -n "$prefix" ] && hits=$(nb_prefix_collisions "$prefix")
    [ -n "$hits" ] && echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_POST_COLLIDE]}" "$prefix" "$hits")${COLOR_RESET}"

    # Same guard as in the use-current branch: keep an active API mode.
    [ "$(nb_state_get mode)" = "api" ] || nb_state_set mode basic
    nb_state_set mgmt_url "$(nb_mgmt_url)"
    nb_state_set network_cidr "$prefix"
    if panel_is_installed; then
        nb_state_set panel_overlay "$ov"
    fi
    nb_audit "join host=$(hostname -s) overlay=$ov mgmt=$(nb_mgmt_url)"
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_JOIN_DONE]}${COLOR_RESET}"
    if [ "$(nb_state_get mode)" != "api" ]; then
        # A fresh join lands in basic mode, where the policy work is manual
        # and too easy to get wrong. Offer the API funnel first: activate
        # (PAT -> groups), then the Default-off question with its path
        # checks. The checklist stays as the fallback for basic mode.
        local api_now
        echo -e " ${COLOR_GRAY}${LANG[NB_JOIN_API_HINT]}${COLOR_RESET}"
        if reading_yn "${LANG[NB_JOIN_API_ASK]}" api_now; then
            if nb_activate_api; then
                nb_policies_flow
                return 0
            fi
        fi
        nb_policy_checklist
    fi
    return 0
}

# Collisions of the overlay prefix with routes, interfaces and docker nets.
nb_prefix_collisions() {
    local prefix="$1" out="" subnet name
    while read -r subnet; do
        [ -n "$subnet" ] || continue
        nb_cidr_holds "$subnet" "$prefix" && out="${out}route:${subnet}, "
    done < <(ip -4 -o route 2>/dev/null | awk '{print $2}' | grep -v ^default)
    while read -r name subnet; do
        [ -n "$subnet" ] || continue
        nb_cidr_holds "$subnet" "$prefix" && out="${out}docker:${name}(${subnet}), "
    done < <(docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' $(docker network ls -q 2>/dev/null) 2>/dev/null | awk '{print $1, $2}')
    printf '%s' "$out" | sed 's/, $//'
}

# Basic mode cannot see the account's policies — say so, precisely.
nb_policy_checklist() {
    echo -e ""
    echo -e "${COLOR_YELLOW}${LANG[NB_POL_CHECKLIST_TITLE]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}${LANG[NB_POL_CHECKLIST]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[NB_POL_DEFAULT_WARN]}${COLOR_RESET}"
}

# ---------------------------------------------------------------------------
# Migration (§8.2)
# ---------------------------------------------------------------------------

nb_current_step=""
nb_current_uuid=""

nb_on_abort() {
    if [ -n "$nb_current_uuid" ] && [ -n "$nb_current_step" ]; then
        nb_journal "$nb_current_uuid" "$nb_current_step" aborted
        nb_node_state "$nb_current_uuid" "aborted_at_${nb_current_step}"
        nb_audit "abort uuid=$nb_current_uuid step=$nb_current_step"
        echo ""
        echo -e "${COLOR_YELLOW}${LANG[NB_ABORTED_MIGRATE]}${COLOR_RESET}"
    else
        # Nothing was in flight — an interrupted prompt must not claim a
        # journal entry that was never written.
        echo ""
        echo -e "${COLOR_YELLOW}${LANG[NB_ABORTED]}${COLOR_RESET}"
    fi
    # An interrupt must actually interrupt: after the trap returns, bash
    # re-executes the interrupted read, so merely printing would loop the
    # flow right back to the same prompt ("Прервано" every ^C, no exit).
    exit 130
}

# Pick a node to migrate; the uuid lands in NB_PICKED_UUID (a global, not
# stdout — the dialog itself prints to stdout, so capturing the function
# would glue the menu onto the uuid). rc=1 — cancelled.
NB_PICKED_UUID=""
nb_pick_migratable() {
    local items=() obj i pick
    while read -r obj; do
        [ -n "$obj" ] || continue
        items+=("$obj")
    done < <(echo "$2" | jq -c '.response[]?' 2>/dev/null)

    NB_PICKED_UUID=""
    [ "${#items[@]}" -gt 0 ] || { echo -e "${COLOR_YELLOW}${LANG[NB_MG_PICK_NONE]}${COLOR_RESET}"; return 1; }

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_MG_TITLE]}${COLOR_RESET}"
    echo -e ""
    # Column widths come from the rows themselves: fixed 20/24 columns leave
    # short names behind a wall of spaces and let long hosts push the
    # status mark out of line.
    local rows=() line name host conn nw=0 hw=0 idx=1
    for obj in "${items[@]}"; do
        line=$(printf '%s' "$obj" | jq -r '"\(.name)\t\(.address)\t\(.isConnected)"')
        rows+=("$line")
        IFS=$'\t' read -r name host conn <<<"$line"
        [ "${#name}" -gt "$nw" ] && nw=${#name}
        [ "${#host}" -gt "$hw" ] && hw=${#host}
    done
    for line in "${rows[@]}"; do
        printf '%s\n' "$line" | awk -v i="$idx" -v nw="$((nw + 2))" -v hw="$((hw + 2))" -F'\t' \
            '{ printf "  %d. %-*s %-*s %s\n", i, nw, $1, hw, $2, ($3=="true"?"✓":"✗") }'
        idx=$((idx + 1))
    done
    reading "$(printf "${LANG[NB_MG_PICK]}" "$((idx - 1))")" pick || return 1
    [ "$pick" = "0" ] && return 1
    if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#items[@]}" ]; then
        NB_PICKED_UUID=$(echo "${items[$((pick - 1))]}" | jq -r '.uuid')
        [ -n "$NB_PICKED_UUID" ] && return 0
    fi
    return 1
}

# Best-effort public host for a node: ssh target, netbird state, then ask.
nb_public_host_for() {
    local address="$1" name="$2" uuid="$3" pub="" def=""
    if nb_need_re && re_target_load_by_host "$address"; then
        pub="$RE_HOST"
    fi
    [ -n "$pub" ] || pub=$(nb_node_get "$uuid" public_host)
    [ -n "$pub" ] || def=$(nb_node_get "$uuid" old_address)
    while [ -z "$pub" ]; do
        reading "$(printf "${LANG[NB_MG_PUB_PROMPT]}" "$name" "${def:-?}")" pub || return 1
        if nb_is_ipv4 "$pub" || printf '%s' "$pub" | grep -qE '^[A-Za-z0-9._-]+$'; then
            break
        fi
        pub=""
    done
    printf '%s' "$pub"
}

nb_ufw_wt0_rule() { printf 'allow in on %s from %s to any port %s proto tcp' "$NB_IFACE" "$1" "$NB_NODE_PORT"; }

nb_migrate() {
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    command -v jq >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_ERR_JQ]}${COLOR_RESET}"; return 1; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }

    nb_mgmt_connected || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }
    local panel_ov
    panel_ov=$(nb_wt0_ip)
    [ -n "$panel_ov" ] || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }

    local token
    nb_load_api || { echo -e "${COLOR_RED}${LANG[NB_ERR_API]}${COLOR_RESET}"; return 3; }
    token=$(cat "${DIR_REMNAWAVE}token")
    if ! rw_token_is_api "$token"; then
        echo -e "${COLOR_RED}${LANG[NB_MG_TOKEN_BAD]}${COLOR_RESET}"
        return 3
    fi

    local nodes_json
    nodes_json=$(nb_api_nodes "$token")
    echo "$nodes_json" | jq -e '.response' >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_ERR_API]}${COLOR_RESET}"; return 3; }

    local uuid
    nb_pick_migratable "$token" "$nodes_json" || return 1
    uuid="$NB_PICKED_UUID"
    [ -n "$uuid" ] || return 1

    local obj name address port note iconn proxy
    obj=$(nb_node_obj "$nodes_json" "$uuid")
    name=$(echo "$obj" | jq -r '.name // "?"')
    address=$(echo "$obj" | jq -r '.address // empty')
    port=$(echo "$obj" | jq -r '.port // 2222')
    note=$(echo "$obj" | jq -r '.note // ""')
    iconn=$(echo "$obj" | jq -r '.isConnected // false')
    proxy=$(echo "$obj" | jq -r '.proxyUrl // empty')

    [ "$address" = "172.30.0.1" ] && { echo -e "${COLOR_YELLOW}${LANG[NB_MG_LOCAL_SKIP]}${COLOR_RESET}"; return 1; }
    [ -n "$proxy" ] && [ "$proxy" != "null" ] && { echo -e "${COLOR_YELLOW}${LANG[NB_MG_PROXY_SKIP]}${COLOR_RESET}"; return 1; }
    [ "$iconn" = "true" ] || echo -e "${COLOR_YELLOW}${LANG[NB_MG_NOT_CONNECTED]}${COLOR_RESET}"

    local prefix
    prefix=$(nb_state_get network_cidr)
    [ -n "$prefix" ] || prefix=$(nb_overlay_prefix)
    if [ -n "$prefix" ] && nb_cidr_holds "$address" "$prefix"; then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_ALREADY]}" "$address")${COLOR_RESET}"
        return 1
    fi

    # Unfinished journal entry for this node → resume or roll back, never a
    # silent second run.
    if nb_node_exists "$uuid"; then
        local st
        st=$(nb_node_get "$uuid" state)
        case "$st" in
            planned|nb_up|wt0_rule|path_failed|path_ok|alias|patched|connected|dns_blocked|install_failed|nb_up_failed|alias_failed|aborted_at_*)
                echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_RESUME]}" "$name" "$st")${COLOR_RESET}"
                reading "${LANG[NB_MG_RESUME_PROMPT]}" r_resume || return 1
                case "$r_resume" in
                    в|r) nb_rollback_one "$token" "$uuid" "$panel_ov"; return $? ;;
                    п|c) ;;
                    *) return 1 ;;
                esac
                ;;
        esac
    fi

    # Guards: server-routing references and plugin presets block the move
    # until their consumers are overlay-aware (B-02/B-03/B-14).
    local needle
    for needle in "$uuid" "$address" "$name"; do
        if nb_sr_references "$needle"; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_SR_BLOCK]}" "$name")${COLOR_RESET}"
            return 3
        fi
        if nb_plugin_references "$needle"; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_PLUGIN_BLOCK]}" "$name")${COLOR_RESET}"
            return 3
        fi
    done

    local pub
    pub=$(nb_public_host_for "$address" "$name" "$uuid") || return 1
    nb_is_ipv4 "$pub" || printf '%s' "$pub" | grep -qE '^[A-Za-z0-9._-]+$' || {
        echo -e "${COLOR_RED}${LANG[NB_ERR_HOST_CHARS]}${COLOR_RESET}"; return 3;
    }

    echo -e ""
    echo -e "${COLOR_WHITE}$(printf "${LANG[NB_MG_PLAN]}" "$name")${COLOR_RESET}"
    if ! reading_yn "${LANG[NB_MG_CONFIRM]}" mg_go; then
        echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"
        return 1
    fi

    nb_current_uuid="$uuid"
    nb_audit "migrate start uuid=$uuid name=$name old=$address pub=$pub"

    # -- step 1-2: snapshot + ssh access
    nb_node_set "$uuid" uuid "$uuid"
    nb_node_set "$uuid" name "$name"
    nb_node_set "$uuid" old_address "$address"
    nb_node_set "$uuid" orig_note "$note"
    nb_node_set "$uuid" public_host "$pub"
    nb_node_set "$uuid" port "$port"
    nb_node_set "$uuid" panel_overlay_at_migration "$panel_ov"
    nb_node_state "$uuid" planned
    nb_journal "$uuid" snapshot done

    nb_current_step=ssh
    nb_journal "$uuid" ssh started
    step_do "$(printf "${LANG[NB_MG_STEP_SSH]}" "$pub")"
    re_require_access_host "$pub" || { nb_node_state "$uuid" aborted_at_ssh; return 2; }
    local mid
    mid=$(re_run_host_n "$pub" 'cat /etc/machine-id' 2>/dev/null | tr -d '[:space:]')
    [ -n "$mid" ] && nb_node_set "$uuid" machine_id "$mid"
    nb_journal "$uuid" ssh done
    step_ok "$pub"

    # -- step 3: DNS guard
    nb_current_step=dns_guard
    nb_journal "$uuid" dns_guard started
    step_do "${LANG[NB_MG_STEP_DNSGUARD]}"
    local dns_rc=0
    re_run_host_n "$pub" "$(nb_dns_guard_script)" >/dev/null 2>&1 || dns_rc=$?
    if [ "$dns_rc" -eq 9 ]; then
        echo -e "${COLOR_RED}${LANG[NB_MG_DNS_BLOCK]}${COLOR_RESET}"
        nb_node_state "$uuid" dns_blocked
        nb_journal "$uuid" dns_guard blocked
        return 3
    fi
    nb_journal "$uuid" dns_guard done
    step_ok "${LANG[NB_MG_STEP_DNSGUARD_OK]}"

    # -- step 4: join the node (§8.1 remote)
    nb_current_step=nb_up
    nb_journal "$uuid" nb_up started
    step_do "$(printf "${LANG[NB_MG_STEP_INSTALL]}" "$name")"
    if ! re_run_host_n "$pub" "$(nb_apt_repo_script)" >/dev/null 2>&1; then
        nb_node_state "$uuid" install_failed
        return 3
    fi
    local install_script unit="rrp-nb-apt-${NB_RUN_ID}"
    install_script=$(nb_apt_install_script)
    install_script=${install_script//INSTALL_UNIT/$unit}
    re_run_host_n "$pub" "$install_script" >/dev/null 2>&1 || { nb_node_state "$uuid" install_failed; return 3; }
    re_run_host_n "$pub" "$(nb_lazy_off_script)" >/dev/null 2>&1 \
        || echo -e "${COLOR_YELLOW}${LANG[NB_LAZY_OFF_FAIL]}${COLOR_RESET}"

    local key="" kid="" up_out ov
    if nb_api_mode; then
        # One-off for the node, auto-bound to the nodes group; revoked once
        # used. The operator never sees a key in API mode.
        nb_ensure_core_objects || { nb_node_state "$uuid" aborted_at_nb_up; return 1; }
        local kk
        kk=$(nb_oneoff_key "$(nb_state_get grp_nodes)" "rrp-node-${name}-${NB_RUN_ID}") || { nb_node_state "$uuid" aborted_at_nb_up; return 1; }
        kid=${kk%% *}
        key=${kk#* }
    else
        nb_read_hidden "$(printf "${LANG[NB_MG_KEY_PROMPT]}" "$name")" key
        [ -n "$key" ] || { nb_node_state "$uuid" aborted_at_nb_up; return 1; }
    fi
    up_out=$(printf '%s\n' "$key" | re_run_host "$pub" "$(nb_up_script "$name" "")")
    unset key
    [ -n "$kid" ] && { nb_revoke_setup_key "$kid"; nb_audit "one-off key revoked (node $name)"; }
    ov=$(printf '%s\n' "$up_out" | sed -n 's/^RRP_OVERLAY=//p' | tail -n1)
    if ! nb_is_ipv4 "$ov"; then
        echo -e "${COLOR_RED}${LANG[NB_MG_UP_FAIL]}${COLOR_RESET}"
        nb_node_state "$uuid" nb_up_failed
        nb_journal "$uuid" nb_up failed
        return 4
    fi
    nb_node_set "$uuid" overlay "$ov"
    nb_journal "$uuid" nb_up done
    step_ok "$(printf "${LANG[NB_MG_STEP_INSTALL_OK]}" "$name" "$ov")"

    # A pre-registered peer does not inherit the one-off key's auto_groups:
    # bind it to the nodes group by overlay IP or the panel→nodes policy
    # will not cover it (seen live: Default off + policy on = no route).
    if nb_api_mode; then
        local npid
        npid=$(nb_peer_id_by_ip "$ov")
        [ -n "$npid" ] && nb_group_add_peer "$(nb_state_get grp_nodes)" "$npid" \
            && nb_node_set "$uuid" peer_id "$npid"
    fi

    # -- step 5: fallback wt0 rule on the node (works only with NetBird's
    # firewall off, which is exactly the emergency it exists for)
    nb_current_step=wt0_rule
    nb_journal "$uuid" wt0_rule started
    step_do "${LANG[NB_MG_STEP_UFW]}"
    local rule
    rule=$(nb_ufw_wt0_rule "$panel_ov")
    if re_run_host_n "$pub" "$(re_remote_ufw_cmd required "ufw ${rule}")" >/dev/null 2>&1; then
        nb_node_set "$uuid" wt0_rule "$rule"
        nb_journal "$uuid" wt0_rule done
        step_ok "${LANG[NB_MG_STEP_UFW_OK]}"
    else
        echo -e "${COLOR_YELLOW}${LANG[NB_MG_STEP_UFW_FAIL]}${COLOR_RESET}"
        nb_journal "$uuid" wt0_rule failed
    fi

    # -- step 6: path check from the panel container netns
    nb_current_step=path
    nb_journal "$uuid" path started
    step_do "$(printf "${LANG[NB_MG_STEP_PATH]}" "$ov")"
    if ! nb_path_check_retry "$ov"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_PATH_FAIL]}" "$ov" "6")${COLOR_RESET}"
        echo -e "${COLOR_GRAY}${LANG[NB_MG_PATH_HINTS]}${COLOR_RESET}"
        nb_node_state "$uuid" path_failed
        nb_journal "$uuid" path failed
        return 4
    fi
    nb_journal "$uuid" path done
    step_ok "$(printf "${LANG[NB_MG_STEP_PATH_OK]}" "$ov")"

    # -- step 7: overlay alias on the ssh target (identity-checked)
    nb_current_step=alias
    nb_journal "$uuid" alias started
    step_do "${LANG[NB_MG_STEP_ALIAS]}"
    if re_target_load_by_host "$pub"; then
        local t_host="$RE_HOST" t_port="$RE_PORT" t_user="$RE_USER" t_key="$RE_KEY" t_label="$RE_LABEL"
        re_target_write "$t_host" "$t_port" "$t_user" "$t_key" "$t_label" "$ov"
        local mid2
        mid2=$(re_run_host_n "$ov" 'cat /etc/machine-id' 2>/dev/null | tr -d '[:space:]')
        if [ -n "$mid" ] && [ "$mid2" != "$mid" ]; then
            echo -e "${COLOR_RED}${LANG[NB_MG_ALIAS_MID]}${COLOR_RESET}"
            re_target_write "$t_host" "$t_port" "$t_user" "$t_key" "$t_label" ""
            nb_node_state "$uuid" alias_failed
            return 3
        fi
        nb_node_set "$uuid" ssh_target "$(re_target_name "$t_host" "$t_port")"
    fi
    nb_journal "$uuid" alias done
    step_ok "${LANG[NB_MG_STEP_ALIAS_OK]}"

    # -- step 8: old address survives in three places (state, note, node fs)
    printf '%s\n' "$address" | re_run_host "$pub" \
        'mkdir -p /opt/remnanode 2>/dev/null; cat > /opt/remnanode/.rrp-netbird; chmod 600 /opt/remnanode/.rrp-netbird 2>/dev/null' >/dev/null 2>&1
    nb_patch_note "$token" "$uuid" "$(nb_note_strip "$note")${NB_NOTE_MARK_PREFIX}${address}]"

    # -- step 9: PATCH
    nb_current_step=patched
    nb_journal "$uuid" patched started
    step_do "$(printf "${LANG[NB_MG_STEP_PATCH]}" "$ov")"
    if ! nb_patch_node_address "$token" "$uuid" "$ov"; then
        echo -e "${COLOR_RED}${LANG[NB_MG_PATCH_FAIL]}${COLOR_RESET}"
        nb_rollback_one "$token" "$uuid" "$panel_ov"
        return 5
    fi
    local t_patch
    t_patch=$(date +%s)
    nb_node_state "$uuid" patched
    nb_journal "$uuid" patched done
    step_ok "$(printf "${LANG[NB_MG_STEP_PATCH_OK]}" "$ov")"

    # -- step 10: confirmed reconnection
    nb_current_step=wait
    nb_journal "$uuid" wait started
    step_do "${LANG[NB_MG_STEP_WAIT]}"
    if nb_wait_node_connected "$token" "$uuid" "$t_patch"; then
        nb_node_state "$uuid" connected
        nb_journal "$uuid" wait done
        step_ok "${LANG[NB_MG_STEP_WAIT_OK]}"
    else
        echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_WAIT_FAIL]}" "$address")${COLOR_RESET}"
        nb_rollback_one "$token" "$uuid" "$panel_ov"
        return 5
    fi

    nb_current_step=""
    nb_audit "migrate done uuid=$uuid overlay=$ov"
    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[NB_MG_DONE]}" "$name" "$ov")${COLOR_RESET}"
    echo -e "${COLOR_GRAY}${LANG[NB_MG_PUBLIC_KEPT]}${COLOR_RESET}"
    return 0
}

# Rollback of one node to its public address (also used by break-glass).
nb_rollback_one() {
    local token="$1" uuid="$2" panel_ov="${3:-}" old ov pub rc=0
    old=$(nb_node_get "$uuid" old_address)
    ov=$(nb_node_get "$uuid" overlay)
    pub=$(nb_node_get "$uuid" public_host)
    [ -n "$old" ] || { echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_NO_OLD]}" "$uuid")${COLOR_RESET}"; return 6; }

    step_do "$(printf "${LANG[NB_MG_ROLLBACK]}" "$old")"
    local t0 addr_now
    t0=$(date +%s)
    if ! nb_patch_node_address "$token" "$uuid" "$old"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_ROLLBACK_FAIL]}" "$uuid" "$ov" "$old")${COLOR_RESET}"
        nb_node_state "$uuid" rollback_failed
        nb_journal "$uuid" rollback failed
        return 6
    fi
    # The address is the truth; the reconnect is only a confirmation. A node
    # that is simply offline (host down) must not read as a failed rollback.
    addr_now=$(nb_node_obj "$(nb_api_nodes "$token")" "$uuid" | jq -r '.address // empty' 2>/dev/null)
    if [ "$addr_now" != "$old" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_ROLLBACK_FAIL]}" "$uuid" "$ov" "$old")${COLOR_RESET}"
        nb_node_state "$uuid" rollback_failed
        nb_journal "$uuid" rollback failed
        return 6
    fi
    nb_node_state "$uuid" rolled_back
    nb_journal "$uuid" rollback done
    if nb_wait_node_connected "$token" "$uuid" "$t0" 60 15; then
        step_ok "$(printf "${LANG[NB_MG_ROLLBACK_OK]}" "$old")"
    else
        echo -e "${COLOR_YELLOW}${LANG[NB_MG_ROLLBACK_UNCONFIRMED]}${COLOR_RESET}"
    fi

    # note marker off. The state's orig_note is authoritative: a live read
    # right after the address PATCH can come back empty, and an empty answer
    # used to skip the cleanup silently.
    local orig
    orig=$(nb_node_get "$uuid" orig_note)
    nb_patch_note "$token" "$uuid" "$(nb_note_strip "${orig:-}")"

    # alias off
    if [ -n "$pub" ] && nb_need_re && re_target_load_by_host "$pub"; then
        re_target_write "$RE_HOST" "$RE_PORT" "$RE_USER" "$RE_KEY" "$RE_LABEL" ""
    fi
    [ "$rc" -eq 0 ] && nb_audit "rollback uuid=$uuid to=$old"
    return $rc
}

# ---------------------------------------------------------------------------
# Break-glass (§8.3): all overlay nodes back to public addresses in one go.
# NetBird itself is not touched; the public 2222 rule keeps this path alive.
# ---------------------------------------------------------------------------

nb_breakglass() {
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    local token f uuid ok=0 fail=0 list=""
    nb_load_api || { echo -e "${COLOR_RED}${LANG[NB_ERR_API]}${COLOR_RESET}"; return 1; }
    token=$(cat "${DIR_REMNAWAVE}token")

    for f in "$NB_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        uuid=$(jq -r '.uuid // empty' "$f" 2>/dev/null)
        [ -n "$uuid" ] || continue
        case "$(jq -r '.state // empty' "$f" 2>/dev/null)" in
            patched|connected|done|public_closed|aborted_at_*|path_failed|alias) list="$list $uuid" ;;
        esac
    done
    [ -n "$list" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_BG_NONE]}${COLOR_RESET}"; return 0; }

    echo -e ""
    echo -e "${COLOR_YELLOW}${LANG[NB_BG_WARN]}${COLOR_RESET}"
    reading_yn "${LANG[NB_BG_CONFIRM]}" bg_go || { echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"; return 1; }

    local panel_ip
    panel_ip=$(nb_public_ipv4) || panel_ip=""

    for uuid in $list; do
        local pub old
        pub=$(nb_node_get "$uuid" public_host)
        old=$(nb_node_get "$uuid" old_address)
        if [ -n "$pub" ] && nb_need_re && re_run_host_n "$pub" true >/dev/null 2>&1; then
            if [ -n "$panel_ip" ]; then
                re_run_host_n "$pub" "$(re_remote_ufw_cmd required "ufw allow from ${panel_ip} to any port ${NB_NODE_PORT} proto tcp")" >/dev/null 2>&1 \
                    || echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_BG_UFW_FAIL]}" "$pub")${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_BG_MANUAL]}" "$(nb_node_get "$uuid" name)" "$old" "${panel_ip:-<panel-ip>}")${COLOR_RESET}"
        fi
        if nb_rollback_one "$token" "$uuid" ""; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done
    nb_audit "breakglass ok=$ok fail=$fail"
    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[NB_BG_DONE]}" "$ok" "$fail")${COLOR_RESET}"
    return 0
}

# ---------------------------------------------------------------------------
# Import of a manually built scheme (§8.4) — nodes that walked the wiki guide
# ---------------------------------------------------------------------------

nb_import() {
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    nb_mgmt_connected || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }
    command -v jq >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_ERR_JQ]}${COLOR_RESET}"; return 1; }

    local token prefix nodes_json found=0 name address uuid pub
    nb_load_api || { echo -e "${COLOR_RED}${LANG[NB_ERR_API]}${COLOR_RESET}"; return 1; }
    token=$(cat "${DIR_REMNAWAVE}token")
    prefix=$(nb_state_get network_cidr)
    [ -n "$prefix" ] || prefix=$(nb_overlay_prefix)
    [ -n "$prefix" ] || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }

    nodes_json=$(nb_api_nodes "$token")
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_IMP_TITLE]}${COLOR_RESET}"
    echo -e ""

    while read -r uuid name address; do
        [ -n "$uuid" ] || continue
        nb_node_exists "$uuid" && continue
        found=$((found + 1))
        pub=$(nb_public_host_for "$address" "$name" "$uuid") || { found=$((found - 1)); continue; }
        nb_node_set "$uuid" uuid "$uuid"
        nb_node_set "$uuid" name "$name"
        nb_node_set "$uuid" address "$address"
        nb_node_set "$uuid" overlay "$address"
        nb_node_set "$uuid" old_address "$pub"
        nb_node_set "$uuid" public_host "$pub"
        nb_node_state "$uuid" imported
        nb_journal "$uuid" import done
        echo -e " ${COLOR_GREEN}✓${COLOR_RESET} ${name}: ${pub} → ${address}"
    done < <(echo "$nodes_json" | jq -r '.response[]? | "\(.uuid) \(.name) \(.address)"' 2>/dev/null)

    if [ "$found" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_IMP_NONE]}" "$prefix")${COLOR_RESET}"
        return 0
    fi

    nb_audit "import count=$found"
    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[NB_IMP_DONE]}" "$found")${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[NB_IMP_DNS_HINT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[NB_IMP_FLAGS_HINT]}${COLOR_RESET}"
    return 0
}

# ---------------------------------------------------------------------------
# Diagnostics (§8.9) — local client health + overlay/panel drift
# ---------------------------------------------------------------------------

nb_diag() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_DIAG_TITLE]}${COLOR_RESET}"
    echo -e ""

    if ! nb_pkg_installed; then
        echo -e " ${COLOR_GRAY}${LANG[NB_DIAG_NO_CLIENT]}${COLOR_RESET}"
    else
        local ver hold="нет" lazy="вкл или неизвестно" flags="?" cidr mgmturl
        ver=$(nb_client_version)
        nb_hold_on && hold="да"
        nb_lazy_off && lazy="выкл"
        nb_profile_flags_bad && flags="плохие" || flags="ок"
        cidr=$(nb_wt0_cidr); cidr=${cidr:--}
        mgmturl=$(nb_mgmt_url); mgmturl=${mgmturl:--}
        echo -e " $(printf "${LANG[NB_DIAG_CLIENT]}" "$ver" "$hold" "$lazy" "$flags")"
        echo -e " адрес в сети: ${COLOR_WHITE}${cidr}${COLOR_RESET} · сервер управления: ${COLOR_WHITE}${mgmturl}${COLOR_RESET}"
        [ "$flags" = "плохие" ] && echo -e " ${COLOR_YELLOW}${LANG[NB_DIAG_FLAGS_BAD]}${COLOR_RESET}"
        [ "$hold" = "нет" ] && echo -e " ${COLOR_YELLOW}${LANG[NB_DIAG_NO_HOLD]}${COLOR_RESET}"
        [ "$lazy" != "выкл" ] && echo -e " ${COLOR_YELLOW}${LANG[NB_DIAG_LAZY_ON]}${COLOR_RESET}"
    fi

    panel_is_installed || return 0

    local token
    nb_load_api || { echo -e " ${COLOR_GRAY}${LANG[NB_DIAG_NO_TOKEN]}${COLOR_RESET}"; return 0; }
    token=$(cat "${DIR_REMNAWAVE}token")

    local stored_panel_ov
    stored_panel_ov=$(nb_state_get panel_overlay)
    if [ -n "$stored_panel_ov" ] && [ "$stored_panel_ov" != "$(nb_wt0_ip)" ]; then
        echo -e " ${COLOR_YELLOW}$(printf "${LANG[NB_DIAG_PANEL_DRIFT]}" "$stored_panel_ov" "$(nb_wt0_ip)")${COLOR_RESET}"
    fi

    local f uuid live_obj live_addr st ov
    for f in "$NB_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        uuid=$(jq -r '.uuid // empty' "$f" 2>/dev/null)
        [ -n "$uuid" ] || continue
        st=$(jq -r '.state // empty' "$f" 2>/dev/null)
        ov=$(jq -r '.overlay // empty' "$f" 2>/dev/null)
        live_obj=$(nb_node_obj "$(nb_api_nodes "$token")" "$uuid")
        live_addr=$(echo "$live_obj" | jq -r '.address // empty' 2>/dev/null)
        if [ -z "$live_addr" ]; then
            echo -e " ${COLOR_YELLOW}$(printf "${LANG[NB_DIAG_GONE]}" "$(jq -r '.name // $uuid' "$f" 2>/dev/null)")${COLOR_RESET}"
            continue
        fi
        if [ -n "$ov" ] && [ "$live_addr" != "$ov" ]; then
            echo -e " ${COLOR_YELLOW}$(printf "${LANG[NB_DIAG_DRIFT]}" "$(jq -r '.name // "?"' "$f" 2>/dev/null)" "$ov" "$live_addr")${COLOR_RESET}"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Flags window (§8.1): down + up with the mandatory set, detached
# ---------------------------------------------------------------------------

nb_fix_flags_local() {
    step_do "${LANG[NB_FL_RUNNING]}"
    local flags="${NB_UP_FLAGS}$(nb_extra_up_flags)"
    local unit="rrp-nb-flags-${NB_RUN_ID}"
    systemd-run --unit="$unit" --collect --wait \
        bash -c "netbird down; env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin netbird up ${flags}" >/dev/null 2>&1 || {
        echo -e "${COLOR_RED}${LANG[NB_FL_FAIL]}${COLOR_RESET}"
        return 1
    }
    sleep 3
    nb_wait_ready || { echo -e "${COLOR_RED}${LANG[NB_READY_FAIL]}${COLOR_RESET}"; return 1; }
    if ! nb_lazy_off; then
        bash -c "$(nb_lazy_off_script)" >/dev/null 2>&1 || true
    fi
    step_ok "${LANG[NB_FL_DONE]}"
    return 0
}

nb_fix_flags() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_FL_TITLE]}${COLOR_RESET}"
    echo -e ""
    if panel_is_installed; then
        echo -e "${COLOR_YELLOW}${LANG[NB_FL_WARN_PANEL]}${COLOR_RESET}"
    elif nb_role_is_node; then
        echo -e "${COLOR_YELLOW}${LANG[NB_FL_WARN_NODE]}${COLOR_RESET}"
    fi
    reading_yn "${LANG[NB_FL_CONFIRM]}" fl_go || { echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"; return 1; }
    nb_fix_flags_local
}

# ---------------------------------------------------------------------------
# Canary update (§8.10) — this machine only in the basic stage
# ---------------------------------------------------------------------------

nb_update_self() {
    local cur ver cand
    cur=$(nb_client_version)
    # The pinned client must not float on apt upgrades, so the path to the
    # latest version runs through here: look it up in the repo and make it
    # the default answer.
    step_do "${LANG[NB_UPD_LOOKUP]}"
    apt-get -o DPkg::Lock::Timeout=300 update -qq >/dev/null 2>&1
    cand=$(apt-cache policy netbird 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n1)
    [ "$cand" = "(none)" ] && cand=""
    if [ -n "$cand" ]; then
        step_ok "$(printf "${LANG[NB_UPD_LATEST_OK]}" "$cand")"
    else
        echo -e "${COLOR_YELLOW}${LANG[NB_UPD_LATEST_FAIL]}${COLOR_RESET}"
    fi
    if [ -n "$cand" ]; then
        reading "$(printf "${LANG[NB_UPD_VERSION_LATEST]}" "$cand")" ver || return 1
        [ -n "$ver" ] || ver="$cand"
    else
        reading "$(printf "${LANG[NB_UPD_VERSION]}" "${cur:-?}")" ver || return 1
    fi
    [ -n "$ver" ] || return 1
    printf '%s' "$ver" | grep -qE '^[0-9]+(\.[0-9]+){1,3}$' || { echo -e "${COLOR_RED}${LANG[NB_UPD_BAD]}${COLOR_RESET}"; return 1; }
    if [ "$ver" = "$cur" ]; then
        echo -e "${COLOR_GREEN}$(printf "${LANG[NB_UPD_ALREADY]}" "$cur")${COLOR_RESET}"
        return 0
    fi
    echo -e "${COLOR_YELLOW}${LANG[NB_UPD_WARN]}${COLOR_RESET}"
    reading_yn "${LANG[NB_UPD_CONFIRM]}" upd_go || return 1
    step_do "$(printf "${LANG[NB_UPD_RUNNING]}" "$ver")"
    local unit="rrp-nb-upd-${NB_RUN_ID}"
    systemd-run --unit="$unit" --collect --wait \
        -p Environment=DEBIAN_FRONTEND=noninteractive \
        apt-get -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300 \
            install -y --allow-change-held-packages "netbird=${ver}" >/dev/null 2>&1 || {
        echo -e "${COLOR_RED}${LANG[NB_UPD_FAIL]}${COLOR_RESET}"
        return 1
    }
    apt-mark hold netbird >/dev/null 2>&1
    if ! nb_lazy_off; then
        bash -c "$(nb_lazy_off_script)" >/dev/null 2>&1 \
            || echo -e "${COLOR_YELLOW}${LANG[NB_UPD_LAZY_LOST]}${COLOR_RESET}"
    fi
    step_ok "$(printf "${LANG[NB_UPD_DONE]}" "$(nb_client_version)")"
    nb_audit "update self ver=$ver"
    return 0
}

nb_update() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_UPD_TITLE]}${COLOR_RESET}"
    echo -e ""
    nb_update_self
    return $?
}

# ---------------------------------------------------------------------------
# Disable (§8.11) — ordered, with guards
# ---------------------------------------------------------------------------

nb_disable() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_OFF_TITLE]}${COLOR_RESET}"
    echo -e ""

    if panel_is_installed; then
        local token count=0 prefix obj
        nb_load_api 2>/dev/null || true
        token=""
        [ -s "${DIR_REMNAWAVE}token" ] && token=$(cat "${DIR_REMNAWAVE}token")
        prefix=$(nb_state_get network_cidr)
        [ -n "$prefix" ] || prefix=$(nb_overlay_prefix)
        if [ -n "$token" ] && [ -n "$prefix" ]; then
            while read -r obj; do
                nb_cidr_holds "$obj" "$prefix" && count=$((count + 1))
            done < <(nb_api_nodes "$token" | jq -r '.response[]?.address // empty' 2>/dev/null)
            [ "$count" -gt 0 ] && {
                echo -e "${COLOR_RED}$(printf "${LANG[NB_OFF_NODES_LEFT]}" "$count")${COLOR_RESET}"
                return 1
            }
        fi
        echo -e "${COLOR_WHITE}${LANG[NB_OFF_ORDER]}${COLOR_RESET}"
        reading_yn "${LANG[NB_OFF_CONFIRM]}" off_go || return 1
        netbird down >/dev/null 2>&1
        nb_audit "disable panel"
        echo -e "${COLOR_GREEN}${LANG[NB_OFF_DONE]}${COLOR_RESET}"
        return 0
    fi

    # Node-only box: refuse while remnanode runs without a public fallback.
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
        local has_public=""
        if command -v ufw >/dev/null 2>&1 && ufw show added 2>/dev/null | grep "${NB_NODE_PORT}" | grep -qv "in on ${NB_IFACE}"; then
            has_public=1
        fi
        if [ -z "$has_public" ]; then
            echo -e "${COLOR_RED}${LANG[NB_OFF_LOCAL_BLOCK]}${COLOR_RESET}"
            return 1
        fi
    fi
    local confirm_hn
    reading "${LANG[NB_OFF_LOCAL_CONFIRM]}" confirm_hn || return 1
    [ "$confirm_hn" = "$(hostname -s)" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_OFF_LOCAL_MISMATCH]}${COLOR_RESET}"; return 1; }
    netbird down >/dev/null 2>&1
    nb_audit "disable local"
    echo -e "${COLOR_GREEN}${LANG[NB_OFF_DONE]}${COLOR_RESET}"
    return 0
}

# Remove the client from a machine the module installed it on (nodes, and
# later sub/checker hosts): down, logout, package purge, config wipe. rc=0
# only when the client is really gone.
nb_remote_netbird_uninstall() {
    re_run_host_n "$1" 'netbird down >/dev/null 2>&1
netbird logout >/dev/null 2>&1
systemctl stop netbird >/dev/null 2>&1
apt-mark unhold netbird >/dev/null 2>&1
apt-get -o DPkg::Lock::Timeout=300 purge -y netbird >/dev/null 2>&1
rm -rf /etc/netbird 2>/dev/null
command -v netbird >/dev/null 2>&1 && exit 1
exit 0'
}

# Delete every account peer whose name or hostname matches; echoes the count.
nb_peer_delete_by_name() {
    local name="$1" pid removed=0
    while read -r pid; do
        [ -n "$pid" ] || continue
        nb_nb_api DELETE "/api/peers/$pid" >/dev/null 2>&1 && removed=$((removed + 1))
    done < <(nb_nb_api GET /api/peers 2>/dev/null | jq -r --arg n "$name" '.[]? | select(.name == $n or .hostname == $n) | .id' 2>/dev/null)
    echo "$removed"
    return 0
}

# Full teardown for fresh-from-scratch runs. Guards refuse while any part of
# the scheme still rides the network (panel nodes, subscription, checker);
# the sweep removes the client from the node machines over SSH and deletes
# their peers from the account; finally the local client and the module
# state go. Groups and policies in the account stay — a new join reuses
# them.
nb_purge() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_PURGE_TITLE]}${COLOR_RESET}"
    echo -e ""

    if [ -s "$NB_DIR/sub.json" ]; then
        echo -e "${COLOR_RED}${LANG[NB_PURGE_SUB_LEFT]}${COLOR_RESET}"
        return 1
    fi
    if [ -s "$NB_DIR/checker.json" ]; then
        echo -e "${COLOR_RED}${LANG[NB_PURGE_CHK_LEFT]}${COLOR_RESET}"
        return 1
    fi

    if panel_is_installed; then
        local token count=0 prefix obj
        nb_load_api 2>/dev/null || true
        token=""
        [ -s "${DIR_REMNAWAVE}token" ] && token=$(cat "${DIR_REMNAWAVE}token")
        prefix=$(nb_state_get network_cidr)
        [ -n "$prefix" ] || prefix=$(nb_overlay_prefix)
        if [ -n "$token" ] && [ -n "$prefix" ]; then
            while read -r obj; do
                nb_cidr_holds "$obj" "$prefix" && count=$((count + 1))
            done < <(nb_api_nodes "$token" | jq -r '.response[]?.address // empty' 2>/dev/null)
            [ "$count" -gt 0 ] && {
                echo -e "${COLOR_RED}$(printf "${LANG[NB_OFF_NODES_LEFT]}" "$count")${COLOR_RESET}"
                return 1
            }
        fi
    fi

    # Node-only box: same stranding guard as disable — remnanode running
    # without a public 2222 fallback must not lose its management path.
    if ! panel_is_installed && docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnanode; then
        local has_public=""
        if command -v ufw >/dev/null 2>&1 && ufw show added 2>/dev/null | grep "${NB_NODE_PORT}" | grep -qv "in on ${NB_IFACE}"; then
            has_public=1
        fi
        if [ -z "$has_public" ]; then
            echo -e "${COLOR_RED}${LANG[NB_OFF_LOCAL_BLOCK]}${COLOR_RESET}"
            return 1
        fi
    fi

    # Machines the module installed the client on. Node records survive the
    # unwind; the sub/checker revert flows forget their hosts, so those
    # clients are covered by the manual note in the confirm text.
    local sweep=() sf host name sweep_go=n swept_names="" failed=""
    while IFS= read -r sf; do
        [ -f "$sf" ] || continue
        host=$(jq -r '.public_host // empty' "$sf" 2>/dev/null)
        name=$(jq -r '.name // empty' "$sf" 2>/dev/null)
        [ -n "$host" ] && sweep+=("$host|${name:-}")
    done < <(ls "${NB_NODES_DIR}"/*.json 2>/dev/null)

    echo -e "${COLOR_WHITE}${LANG[NB_PURGE_ORDER]}${COLOR_RESET}"
    if [ "${#sweep[@]}" -gt 0 ]; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_PURGE_REMOTE_LIST]}" "${#sweep[@]}")${COLOR_RESET}"
        reading_yn "${LANG[NB_PURGE_REMOTE_ASK]}" sweep_go || sweep_go=n
    fi
    reading_yn "${LANG[NB_PURGE_CONFIRM]}" purge_go || return 1

    if [ "$sweep_go" = "y" ]; then
        nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }
        local entry
        for entry in "${sweep[@]}"; do
            host=${entry%%|*}
            name=${entry#*|}
            [ -n "$name" ] || name=""
            step_do "$(printf "${LANG[NB_PURGE_REMOTE_STEP]}" "$host")"
            if nb_remote_netbird_uninstall "$host"; then
                step_ok "${LANG[NB_PURGE_REMOTE_OK]}"
                [ -n "$name" ] && swept_names="$swept_names $name"
            else
                echo -e "${COLOR_RED}$(printf "${LANG[NB_PURGE_REMOTE_FAIL]}" "$host")${COLOR_RESET}"
                failed="$failed $host"
            fi
        done
    fi

    step_do "${LANG[NB_PURGE_STEP_DOWN]}"
    netbird down >/dev/null 2>&1
    netbird logout >/dev/null 2>&1
    systemctl stop netbird >/dev/null 2>&1
    step_ok "${LANG[NB_PURGE_STEP_DOWN_OK]}"

    # A fresh join registers a new peer, so old entries would linger offline
    # forever; remove this machine's and the swept nodes' peers while the
    # stored token still works.
    if nb_pat_stored; then
        local gone=0 rn
        gone=$((gone + $(nb_peer_delete_by_name "$(hostname -s)")))
        for rn in $swept_names; do
            gone=$((gone + $(nb_peer_delete_by_name "$rn")))
        done
        [ "$gone" -gt 0 ] && echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_PURGE_PEER_GONE]}" "$gone")${COLOR_RESET}"
    fi

    step_do "${LANG[NB_PURGE_STEP_PKG]}"
    apt-mark unhold netbird >/dev/null 2>&1
    if ! apt-get -o DPkg::Lock::Timeout=300 purge -y netbird >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[NB_PURGE_PKG_FAIL]}${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[NB_PURGE_STEP_PKG_OK]}"
    rm -rf /etc/netbird 2>/dev/null

    step_do "${LANG[NB_PURGE_STEP_STATE]}"
    nb_audit "purge: client removed, module state wiped${swept_names:+, swept:$(printf '%s' "$swept_names")}"
    rm -rf "$NB_DIR"
    step_ok "${LANG[NB_PURGE_STEP_STATE_OK]}"

    [ -n "$failed" ] && echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_PURGE_REMOTE_LEFT]}" "$failed")${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${LANG[NB_PURGE_DONE]}${COLOR_RESET}"
    return 0
}

# ---------------------------------------------------------------------------
# API mode (PR2): PAT of an admin service user, groups, one-off keys,
# unidirectional policies, the Default on/off procedure (§8.8).
# ---------------------------------------------------------------------------

nb_pat_stored() { [ -s "$NB_PAT_FILE" ]; }

nb_api_mode() { nb_pat_stored && [ "$(nb_state_get mode)" = "api" ]; }

# NetBird management API. The PAT rides in a header file, never argv.
# Body goes to stdout; rc=0 on any 2xx. NB_NB_CODE is set too, but ONLY for
# same-shell calls — a `var=$(nb_nb_api …)` subshell drops it, so capture
# rc via $? and read the message from the body instead.
NB_NB_CODE=""
nb_nb_api() {
    local method="$1" path="$2" data="${3:-}" pat out
    pat=$(cat "$NB_PAT_FILE" 2>/dev/null)
    if [ -z "$pat" ]; then
        NB_NB_CODE="0"
        echo '{"message":"no PAT stored"}'
        return 1
    fi
    if [ -n "$data" ]; then
        out=$(curl -s -m 20 -w '\n%{http_code}' -X "$method" \
            -H @<(printf 'Authorization: Token %s\nContent-Type: application/json\n' "$pat") \
            -d "$data" "$NB_NB_API_BASE$path" 2>/dev/null)
    else
        out=$(curl -s -m 20 -w '\n%{http_code}' -X "$method" \
            -H @<(printf 'Authorization: Token %s\n' "$pat") "$NB_NB_API_BASE$path" 2>/dev/null)
    fi
    NB_NB_CODE="${out##*$'\n'}"
    printf '%s' "${out%$'\n'*}"
    [ "${NB_NB_CODE:-0}" -ge 200 ] 2>/dev/null && [ "${NB_NB_CODE:-0}" -lt 300 ] 2>/dev/null
}

# Short object namespace prefix so the module only ever touches its own
# groups/policies/keys and can list what it does NOT own.
nb_panel_id() {
    local h
    h=$(sed -n 's/^PANEL_DOMAIN=//p' /opt/remnawave/.env 2>/dev/null | head -n1 | tr -d '"')
    printf '%s' "${h:-$(hostname -s)}" | cksum | cut -c1-6
}

nb_group_name() { printf 'rrp-%s-%s' "$(nb_panel_id)" "$1"; }

nb_group_find() {
    local name="$1" g
    while read -r g; do
        [ "$(echo "$g" | jq -r .name 2>/dev/null)" = "$name" ] && { echo "$g" | jq -r .id; return 0; }
    done < <(nb_nb_api GET /api/groups | jq -c '.[]?' 2>/dev/null)
    return 1
}

# Ensure a group; an optional peer id seeds it at creation (the only cheap
# moment to bind an already-registered peer to a group).
nb_group_ensure() {
    local name="$1" peer="${2:-}" id body
    id=$(nb_group_find "$name") && { printf '%s' "$id"; return 0; }
    if [ -n "$peer" ]; then
        body=$(jq -nc --arg n "$name" --arg p "$peer" '{name:$n, peers:[$p]}')
    else
        body=$(jq -nc --arg n "$name" '{name:$n}')
    fi
    nb_nb_api POST /api/groups "$body" | jq -r '.id // empty'
}

# Peer id of THIS machine: dns label first (hostname at join), wt0 IP second.
nb_self_peer_id() {
    local ip label p pip
    ip=$(nb_wt0_ip)
    label=$(hostname -s)
    while read -r p; do
        pip=$(echo "$p" | jq -r '.ip // empty' 2>/dev/null); pip="${pip%/*}"
        if [ "$(echo "$p" | jq -r '.dns_label // empty' 2>/dev/null | cut -d. -f1)" = "$label" ] \
           || { [ -n "$ip" ] && [ "$pip" = "$ip" ]; }; then
            echo "$p" | jq -r .id
            return 0
        fi
    done < <(nb_nb_api GET /api/peers | jq -c '.[]?' 2>/dev/null)
    return 1
}

# One-off setup key bound to a group; prints "id key". The key exists in
# clear only here and in the caller's memory, revoked right after `up`.
nb_oneoff_key() {
    local group_id="$1" name="$2" body resp rc
    body=$(jq -nc --arg n "$name" --arg g "$group_id" \
        '{name:$n, type:"one-off", expires_in:86400, usage_limit:1, ephemeral:false, auto_groups:[$g]}')
    resp=$(nb_nb_api POST /api/setup-keys "$body")
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo -e "${COLOR_RED}NetBird API: $(echo "$resp" | jq -r '.message // "unknown error"' 2>/dev/null)${COLOR_RESET}" >&2
        return 1
    fi
    echo "$resp" | jq -r '"\(.id) \(.key)"' | grep -q ' ' || return 1
    echo "$resp" | jq -r '"\(.id) \(.key)"'
}

# Peer id by overlay IP (mask-tolerant): an already-registered node that
# re-registers through a one-off key does NOT pick up the key's auto_groups
# — the module must bind it to the nodes group explicitly.
nb_peer_id_by_ip() {
    local want="$1" p pip
    while read -r p; do
        pip=$(echo "$p" | jq -r '.ip // empty' 2>/dev/null); pip="${pip%/*}"
        [ "$pip" = "$want" ] && { echo "$p" | jq -r .id; return 0; }
    done < <(nb_nb_api GET /api/peers | jq -c '.[]?' 2>/dev/null)
    return 1
}

nb_revoke_setup_key() { nb_nb_api DELETE "/api/setup-keys/$1" >/dev/null; }

nb_policy_find() {
    local name="$1" p
    while read -r p; do
        [ "$(echo "$p" | jq -r .name 2>/dev/null)" = "$name" ] && { echo "$p" | jq -r .id; return 0; }
    done < <(nb_nb_api GET /api/policies | jq -c '.[]?' 2>/dev/null)
    return 1
}

# Unidirectional src→dst tcp/port policy, ours by name. The CREATE request
# takes sources/destinations as PLAIN group-id strings — the GET response
# wraps them into objects, and objects sent back fail server-side unmarshal
# with a misleading "couldn't parse JSON request".
nb_policy_ensure() {
    local name="$1" src_id="$2" dst_id="$3" port="$4" id body
    id=$(nb_policy_find "$name") && { printf '%s' "$id"; return 0; }
    body=$(jq -nc --arg n "$name" --arg s "$src_id" --arg d "$dst_id" \
        '{name:$n, description:"managed by remnawave-reverse-proxy", enabled:true,
          rules:[{name:$n, enabled:true, action:"accept", bidirectional:false,
                  sources:[$s], destinations:[$d],
                  protocol:"tcp", ports:["'"$port"'"]}]}')
    nb_nb_api POST /api/policies "$body" | jq -r '.id // empty'
}

# A GET policy body reshaped for PUT: source/destination objects flattened
# back to id strings (see nb_policy_ensure).
nb_policy_body_for_put() {
    jq -c '.rules //= [] | .rules |= map((.sources // []) |= map(.id? // .) | (.destinations // []) |= map(.id? // .))'
}

nb_default_policy() {
    nb_nb_api GET /api/policies | jq -c '[.[]? | select(.name == "Default")][0] // empty'
}

nb_default_disable() {
    local d id
    d=$(nb_default_policy)
    [ -n "$d" ] || return 1
    id=$(echo "$d" | jq -r .id)
    printf '%s' "$d" > "${NB_DIR}/default_policy.json"
    chmod 600 "${NB_DIR}/default_policy.json" 2>/dev/null
    nb_nb_api PUT "/api/policies/$id" "$(echo "$d" | nb_policy_body_for_put | jq -c '.enabled=false')" >/dev/null
}

nb_default_restore() {
    local d id
    d=$(cat "${NB_DIR}/default_policy.json" 2>/dev/null)
    [ -n "$d" ] || return 1
    id=$(echo "$d" | jq -r .id)
    nb_nb_api PUT "/api/policies/$id" "$(echo "$d" | nb_policy_body_for_put)" >/dev/null
}

# Add a peer to an existing group (PUT takes the whole peer list; the only
# moment a group binds peers for free is its creation).
nb_group_add_peer() {
    local gid="$1" peer="$2" cur body rc
    cur=$(nb_nb_api GET "/api/groups/$gid")
    rc=$?
    [ "$rc" -ne 0 ] && return 1
    echo "$cur" | jq -e --arg p "$peer" '(.peers // []) | index($p)' >/dev/null 2>&1 && return 0
    body=$(echo "$cur" | jq -c --arg p "$peer" '{name: .name, peers: ((.peers // []) + [$p] | unique)}')
    nb_nb_api PUT "/api/groups/$gid" "$body" >/dev/null
}

# The groups and the panel→nodes policy the module depends on. Idempotent,
# safe to call in any state — API calls hit the cloud, the local client may
# not even be up yet (join-time).
nb_ensure_core_objects() {
    local peer gid
    peer=$(nb_self_peer_id 2>/dev/null)
    gid=$(nb_group_ensure "$(nb_group_name panel)" "${peer:-}")
    [ -n "$gid" ] || return 1
    nb_state_set grp_panel "$gid"
    # A freshly registered panel peer only lands in the group through the
    # one-off key's auto_groups; when the peer predates the group, bind it.
    if [ -n "$peer" ]; then
        nb_group_add_peer "$gid" "$peer" || true
    fi

    gid=$(nb_group_ensure "$(nb_group_name nodes)")
    [ -n "$gid" ] || return 1
    nb_state_set grp_nodes "$gid"

    gid=$(nb_policy_ensure "$(nb_group_name panel2nodes)" \
        "$(nb_state_get grp_panel)" "$(nb_state_get grp_nodes)" 2222)
    [ -n "$gid" ] || return 1
    nb_state_set pol_panel2nodes "$gid"
    return 0
}

# PAT activation: check, groups, policy, persist. PAT survives in 600 only
# by an explicit yes.
nb_activate_api() {
    local pat probe
    nb_read_hidden "${LANG[NB_SET_PAT_PROMPT]}" pat
    [ -n "$pat" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"; return 1; }
    mkdir -p "$NB_DIR"; chmod 700 "$NB_DIR" 2>/dev/null
    printf '%s' "$pat" > "$NB_PAT_FILE"; chmod 600 "$NB_PAT_FILE" 2>/dev/null

    step_do "${LANG[NB_SET_PAT_CHECK]}"
    probe=$(nb_nb_api GET /api/peers)
    if [ $? -ne 0 ]; then
        rm -f "$NB_PAT_FILE"
        echo -e "${COLOR_RED}${LANG[NB_SET_PAT_BAD]}: $(echo "$probe" | jq -r '.message // ""' 2>/dev/null)${COLOR_RESET}"
        return 1
    fi
    # Role gate (§8.8): a non-admin PAT can read peers, so the probe alone
    # would pass and the flow would die later at group creation with a
    # generic error. Reject only on POSITIVE evidence of a foreign role —
    # an unreachable users/current must not lock out a working admin PAT.
    local cur_role
    cur_role=$(nb_nb_api GET /api/users/current | jq -r '.role // empty' 2>/dev/null)
    if [ -n "$cur_role" ] && [ "$cur_role" != "admin" ]; then
        rm -f "$NB_PAT_FILE"
        echo -e "${COLOR_RED}${LANG[NB_SET_PAT_BAD]} (role: ${cur_role})${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[NB_SET_PAT_OK]}"

    step_do "${LANG[NB_POL_STEP_GROUPS]}"
    if ! nb_ensure_core_objects; then
        echo -e "${COLOR_RED}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[NB_POL_GROUPS_OK]}"

    if reading_yn "${LANG[NB_SET_PAT_STORE_ASK]}" store_pat; then
        nb_state_set pat_set_at "$(date -u +%F)"
    else
        rm -f "$NB_PAT_FILE"
        echo -e "${COLOR_YELLOW}${LANG[NB_SET_PAT_KEPT]}${COLOR_RESET}"
        return 1
    fi
    nb_state_set mode api
    nb_audit "api-mode activated groups+policy ensured"
    echo -e "${COLOR_GREEN}${LANG[NB_SET_DONE]}${COLOR_RESET}"
    return 0
}

# §8.8: with the panel→nodes policy proven live, Default goes off with the
# body saved for a one-keyword restore. One confirmation per invocation.
nb_policies_flow() {
    if ! nb_api_mode; then
        echo -e "${COLOR_YELLOW}${LANG[NB_POL_NO_API]}${COLOR_RESET}"
        return 1
    fi

    step_do "${LANG[NB_POL_STEP_GROUPS]}"
    nb_ensure_core_objects || { echo -e "${COLOR_RED}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"; return 1; }
    step_ok "${LANG[NB_POL_GROUPS_OK]}"
    step_ok "${LANG[NB_POL_POLICY_OK]}"

    # Foreign peers: registered but in none of our groups — with Default off
    # they lose connectivity; say so before the switch.
    local fgn=0 p gids
    gids="$(nb_state_get grp_panel) $(nb_state_get grp_nodes)"
    while read -r p; do
        [ -n "$p" ] || continue
        local in_ours=0 g
        for g in $(echo "$p" | jq -r '.groups[]?.id' 2>/dev/null); do
            case " $gids " in *" $g "*) in_ours=1 ;; esac
        done
        [ "$in_ours" = 0 ] && fgn=$((fgn + 1))
    done < <(nb_nb_api GET /api/peers | jq -c '.[]?' 2>/dev/null)
    [ "$fgn" -gt 0 ] && echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_POL_FOREIGN]}" "$fgn")${COLOR_RESET}"

    # The switch only counts when the paths survive it; a dead policy set
    # rolls Default back instead of stranding nodes. The restore direction
    # needs no checks — it only widens access.
    nb_pol_pathcheck_all() {
        local f ov bad=0
        for f in "$NB_NODES_DIR"/*.json; do
            [ -f "$f" ] || continue
            case "$(jq -r '.state // empty' "$f" 2>/dev/null)" in connected|done) ;; *) continue ;; esac
            ov=$(jq -r '.overlay // empty' "$f" 2>/dev/null)
            [ -n "$ov" ] || continue
            nb_path_check "$ov" || { echo -e "${COLOR_RED}$(printf "${LANG[NB_POL_PATH_FAIL]}" "$(jq -r '.name // "?"' "$f")")${COLOR_RESET}"; bad=1; }
        done
        return $bad
    }

    local d state
    d=$(nb_default_policy)
    if [ -n "$d" ] && [ "$(echo "$d" | jq -r .enabled)" = "true" ]; then
        step_do "${LANG[NB_POL_STEP_PATH]}"
        if ! nb_pol_pathcheck_all; then
            echo -e "${COLOR_RED}${LANG[NB_POL_PATH_BAD_ABORT]}${COLOR_RESET}"
            return 1
        fi
        step_ok "${LANG[NB_POL_PATH_OK]}"
        echo -e "${COLOR_YELLOW}${LANG[NB_POL_DEFAULT_ON]}${COLOR_RESET}"
        reading_yn "${LANG[NB_POL_DEFAULT_OFF_ASK]}" off_default || return 0
        if nb_default_disable; then
            nb_audit "default policy disabled (body saved)"
            # The switch only counts when the paths survive it; a dead
            # policy set rolls Default back instead of stranding nodes.
            step_do "${LANG[NB_POL_POSTCHECK]}"
            sleep 3
            local dead=0
            for f in "$NB_NODES_DIR"/*.json; do
                [ -f "$f" ] || continue
                case "$(jq -r '.state // empty' "$f" 2>/dev/null)" in connected|done) ;; *) continue ;; esac
                ov=$(jq -r '.overlay // empty' "$f" 2>/dev/null)
                [ -n "$ov" ] || continue
                nb_path_check "$ov" || dead=1
            done
            if [ "$dead" = 1 ]; then
                nb_default_restore
                echo -e "${COLOR_RED}${LANG[NB_POL_AUTO_RESTORE]}${COLOR_RESET}"
                return 1
            fi
            echo -e "${COLOR_GREEN}${LANG[NB_POL_DEFAULT_DISABLED]}${COLOR_RESET}"
        else
            echo -e "${COLOR_RED}${LANG[NB_POL_DEFAULT_FAIL]}${COLOR_RESET}"
            return 1
        fi
    elif [ -n "$d" ]; then
        echo -e "${COLOR_GREEN}${LANG[NB_POL_DEFAULT_ALREADY]}${COLOR_RESET}"
        if [ -s "${NB_DIR}/default_policy.json" ] \
            && reading_yn "${LANG[NB_POL_DEFAULT_RESTORE_ASK]}" rs_default; then
            nb_default_restore && { nb_audit "default policy restored"; echo -e "${COLOR_GREEN}${LANG[NB_POL_DEFAULT_RESTORED]}${COLOR_RESET}"; }
        fi
    else
        echo -e "${COLOR_YELLOW}${LANG[NB_POL_DEFAULT_ABSENT]}${COLOR_RESET}"
    fi
    return 0
}

nb_settings_flow() {
    local pick last
    while true; do
        last=1
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[NB_SET_TITLE]}${COLOR_RESET}"
        echo -e ""
        local mode_disp
        mode_disp=$(nb_state_get mode || echo basic)
        [ "$mode_disp" = "api" ] && mode_disp="API" || mode_disp="базовый"
        echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_MODE]}" "$mode_disp")${COLOR_RESET}"
        if nb_pat_stored; then
            echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_PAT_PRESENT]}" "$(nb_state_get pat_set_at || echo нет)")${COLOR_RESET}"
            echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_API_BASE]}" "$NB_NB_API_BASE")${COLOR_RESET}"
        else
            echo -e " ${COLOR_GRAY}${LANG[NB_SET_PAT_ABSENT]}${COLOR_RESET}"
            echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_API_BASE]}" "$NB_NB_API_BASE")${COLOR_RESET}"
        fi
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[NB_SET_ACTIVATE]}${COLOR_RESET}"
        if nb_pat_stored; then
            last=2
            echo -e "${COLOR_YELLOW}2. ${LANG[NB_SET_FORGET]}${COLOR_RESET}"
            if [ -s "$NB_DIR/sub.json" ]; then
                last=3
                echo -e "${COLOR_YELLOW}3. ${LANG[NB_SET_ROTATE]}${COLOR_RESET}"
            fi
        fi
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" pick || return 0
        case "$pick" in
            1) nb_activate_api ;;
            2)
                if [ "$last" = 2 ] || [ "$last" = 3 ]; then
                    rm -f "$NB_PAT_FILE"; nb_state_set mode basic; nb_audit "pat forgotten"
                    echo -e "${COLOR_GREEN}${LANG[NB_SET_FORGOTTEN]}${COLOR_RESET}"
                else
                    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
                fi
                ;;
            3)
                if [ "$last" = 3 ]; then
                    nb_sub_rotate
                else
                    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
                fi
                ;;
            0) return 0 ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last" ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Subscription page over overlay (PR3, §8.6): a listener on the panel's host
# network proxy + a small allowlist by overlay IP. Nothing is ever bound to
# the overlay IP itself and no Docker port is published on it (moby#39559).
# ---------------------------------------------------------------------------

NB_SUB_MARK_BEGIN="# BEGIN rrp-netbird"
NB_SUB_MARK_END="# END rrp-netbird"

nb_web_server_kind() {
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-nginx; then
        echo nginx; return 0
    fi
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx remnawave-caddy; then
        echo caddy; return 0
    fi
    return 1
}

# First free port from 3100 up — never 3000 (docker-proxy) or 8443 (the
# panel's emergency access). A port already bound by OUR OWN marker block is
# not "busy": reusing it keeps the ACL policy (named, hence port-frozen) in
# sync with the listener across re-runs.
nb_listener_port_pick() {
    local p cand conf ours
    for conf in /opt/remnawave/nginx.conf /opt/remnawave/Caddyfile; do
        if [ -f "$conf" ]; then
            ours=$(sed -n "/^${NB_SUB_MARK_BEGIN}\$/,/^${NB_SUB_MARK_END}\$/p" "$conf" 2>/dev/null \
                | { grep -oE 'listen [0-9]+' || grep -oE '^:[0-9]+'; } | grep -oE '[0-9]+' | head -n1)
            [ -n "$ours" ] && { printf '%s' "$ours"; return 0; }
        fi
    done
    p=$(nb_state_get nb_api_port)
    if [ -n "$p" ] && ! ss -tln 2>/dev/null | grep -q ":$p\b"; then
        printf '%s' "$p"; return 0
    fi
    for cand in 3100 3101 3102 3103 3104 3105; do
        [ "$cand" = 3000 ] && continue
        if ! ss -tln 2>/dev/null | grep -q ":$cand\b"; then
            nb_state_set nb_api_port "$cand"
            printf '%s' "$cand"
            return 0
        fi
    done
    return 1
}

# Overlay IPs allowed at the listener. Two sets, two scopes: the
# subscription page gets the full prefix set, the checker only the raw
# /api/sub/ it fetches (§8.7 — its UI lists every proxy, it gets nothing
# else).
nb_listener_allows_sub() {
    [ -f "$NB_DIR/sub.json" ] && jq -r '.overlay // empty' "$NB_DIR/sub.json" 2>/dev/null
}

nb_listener_allows_checker() {
    [ -f "$NB_DIR/checker.json" ] && jq -r '.overlay // empty' "$NB_DIR/checker.json" 2>/dev/null
}

# Marker block renderer. The prefix set mirrors subscription-page's panel
# calls (F17); the checker joins only /api/sub/; everything else gets 444.
# Server-level proxy_set_header is inherited by locations that declare none.
nb_listener_block_nginx() {
    local port="$1" allow sub_ips chk_ips sub_all=""
    sub_ips=$(nb_listener_allows_sub)
    chk_ips=$(nb_listener_allows_checker)
    # One machine may carry both roles (sub + checker): duplicate location
    # blocks make nginx -t fail with "duplicate location" — union first.
    for allow in $sub_ips $chk_ips; do
        case " $sub_all " in *" $allow "*) continue ;; esac
        sub_all="$sub_all $allow"
    done
    sub_all=$(printf '%s' "$sub_all" | sed 's/^ //')
    {
        echo "$NB_SUB_MARK_BEGIN"
        echo "server {"
        echo "    listen $port;"
        echo "    proxy_set_header Cookie \"\";"
        echo "    proxy_set_header X-Forwarded-Proto https;"
        echo "    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;"
    # ONE /api/sub/ location for the whole union: a per-IP loop used to emit
    # duplicate location blocks and fail nginx -t the moment the sub server
    # and the checker lived on different machines.
    if [ -n "$sub_all" ]; then
        echo "    location ^~ /api/sub/ { $(for allow in $sub_all; do printf 'allow %s; ' "$allow"; done)deny all; proxy_pass http://127.0.0.1:3000; }"
    fi
        if [ -n "$sub_ips" ]; then
            echo "    location = /api/system/metadata { $(for allow in $sub_ips; do printf 'allow %s; ' "$allow"; done)deny all; proxy_pass http://127.0.0.1:3000; }"
            echo "    location ^~ /api/users/by-username/ { $(for allow in $sub_ips; do printf 'allow %s; ' "$allow"; done)deny all; proxy_pass http://127.0.0.1:3000; }"
            echo "    location ^~ /api/subscriptions/subpage-config/ { $(for allow in $sub_ips; do printf 'allow %s; ' "$allow"; done)deny all; proxy_pass http://127.0.0.1:3000; }"
            echo "    location ^~ /api/subscription-page-configs { $(for allow in $sub_ips; do printf 'allow %s; ' "$allow"; done)deny all; proxy_pass http://127.0.0.1:3000; }"
        fi
        echo "    location / { return 444; }"
        echo "}"
        echo "$NB_SUB_MARK_END"
    }
}

# Apply nginx: strip the old marker block, append the fresh one. The conf is
# a bind-mounted single file — writes go through cat > to keep the inode,
# never sed -i. nginx -t gates the reload; a failure rolls the text back.
nb_listener_apply_nginx() {
    local conf="/opt/remnawave/nginx.conf" tmp port block
    port=$(nb_listener_port_pick) || return 1
    [ -f "$conf" ] || return 1
    tmp=$(mktemp)
    awk -v b="$NB_SUB_MARK_BEGIN" -v e="$NB_SUB_MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$conf" > "$tmp"
    nb_listener_block_nginx "$port" >> "$tmp"
    cp -p "$conf" "${conf}.rrpnbak"
    cat "$tmp" > "$conf"
    rm -f "$tmp"
    local test_rc=0
    docker exec remnawave-nginx nginx -t >/dev/null 2>&1 || test_rc=$?
    if [ "$test_rc" -ne 0 ]; then
        cat "${conf}.rrpnbak" > "$conf"
        rm -f "${conf}.rrpnbak"
        return 1
    fi
    docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1
    rm -f "${conf}.rrpnbak"
    sleep 1
    ss -tln 2>/dev/null | grep -q ":$port\b"
}

# Caddy twin: admin off means only a container restart applies the file; the
# caller warns about the few seconds of panel downtime.
nb_listener_block_caddy() {
    local port="$1" allow ips
    ips="$(nb_listener_allows_sub) $(nb_listener_allows_checker)"
    ips=$(printf '%s' "$ips" | sed 's/^ //;s/ $//')
    [ -n "$ips" ] || return 1
    {
        echo "$NB_SUB_MARK_BEGIN"
        echo ":$port {"
        echo "    bind 0.0.0.0"
        printf '    @allow remote_ip %s\n' "$ips"
        echo "    handle @allow {"
        echo "        reverse_proxy 127.0.0.1:3000 {"
        echo "            header_up X-Forwarded-Proto https"
        echo "            header_up -Cookie"
        echo "        }"
        echo "    }"
        echo "    respond 444"
        echo "}"
        echo "$NB_SUB_MARK_END"
    }
}

nb_listener_apply_caddy() {
    local conf="/opt/remnawave/Caddyfile" tmp port
    port=$(nb_listener_port_pick) || return 1
    [ -f "$conf" ] || return 1
    tmp=$(mktemp)
    awk -v b="$NB_SUB_MARK_BEGIN" -v e="$NB_SUB_MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$conf" > "$tmp"
    nb_listener_block_caddy "$port" >> "$tmp" || { rm -f "$tmp"; return 1; }
    cp -p "$conf" "${conf}.rrpnbak"
    cat "$tmp" > "$conf"
    rm -f "$tmp"
    docker restart remnawave-caddy >/dev/null 2>&1
    sleep 6
    if ! docker ps --format '{{.Names}}' | grep -qx remnawave-caddy \
       || ! ss -tln 2>/dev/null | grep -q ":$port\b"; then
        cat "${conf}.rrpnbak" > "$conf"
        rm -f "${conf}.rrpnbak"
        docker restart remnawave-caddy >/dev/null 2>&1
        return 1
    fi
    rm -f "${conf}.rrpnbak"
    return 0
}

nb_listener_apply() {
    local kind
    kind=$(nb_web_server_kind) || { echo -e "${COLOR_RED}${LANG[NB_SUB_NO_WEBSERVER]}${COLOR_RESET}"; return 1; }
    if [ "$kind" = caddy ]; then
        echo -e "${COLOR_YELLOW}${LANG[NB_SUB_CADDY_WARN]}${COLOR_RESET}"
        nb_listener_apply_caddy
    else
        nb_listener_apply_nginx
    fi
}

nb_listener_remove() {
    local kind conf
    kind=$(nb_web_server_kind) || return 1
    if [ "$kind" = caddy ]; then
        conf="/opt/remnawave/Caddyfile"
    else
        conf="/opt/remnawave/nginx.conf"
    fi
    [ -f "$conf" ] || return 0
    awk -v b="$NB_SUB_MARK_BEGIN" -v e="$NB_SUB_MARK_END" '
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        !skip { print }
    ' "$conf" > "${conf}.tmp"
    if ! cmp -s "${conf}.tmp" "$conf"; then
        cat "${conf}.tmp" > "$conf"
        if [ "$kind" = caddy ]; then
            docker restart remnawave-caddy >/dev/null 2>&1
        else
            docker exec remnawave-nginx nginx -t >/dev/null 2>&1 \
                && docker exec remnawave-nginx nginx -s reload >/dev/null 2>&1
        fi
    fi
    rm -f "${conf}.tmp"
    return 0
}

nb_listener_status() {
    local port
    port=$(nb_state_get nb_api_port)
    [ -n "$port" ] || port=-
    if grep -qF "$NB_SUB_MARK_BEGIN" /opt/remnawave/nginx.conf 2>/dev/null \
       || grep -qF "$NB_SUB_MARK_BEGIN" /opt/remnawave/Caddyfile 2>/dev/null; then
        echo "listener :$port ✓"
    else
        echo "listener :${port} —"
    fi
}

# Scoped token for the subscription server, minted on the panel; the value
# goes straight into the remote compose, never into a local file. Scoped or
# nothing — no wildcard fallback. An admin login JWT may be passed: the
# saved API token gets 403 on /api/tokens (only admin JWTs may mint).
nb_sub_mint_token() {
    # self-sufficient: this helper may run in a subshell where no flow
    # loaded the panel API module beforehand
    command -v make_api_request >/dev/null 2>&1 || load_api_module >/dev/null 2>&1 || true
    local jwt="${1:-}" token body resp
    if [ -n "$jwt" ]; then
        token="$jwt"
    else
        token=$(cat "${DIR_REMNAWAVE}token" 2>/dev/null)
    fi
    body=$(jq -nc '{name:"subscription-page-rrp", expiresInDays:3650,
        scopes:["subscription-page-configs:list","subscription-page-configs:get",
                "subscriptions:subpage-config","system:metadata","users:by-username"]}')
    resp=$(make_api_request "POST" "http://127.0.0.1:3000/api/tokens" "$token" "$body")
    echo "$resp" | jq -r '.response.token // empty'
}

# Rotate the subscription server's token to a fresh scoped one. Needs the
# superadmin login once (the API token cannot mint); the JWT is used in
# memory and discarded.
nb_sub_rotate() {
    local host panel_ov token jwt compose_new
    [ -s "$NB_DIR/sub.json" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_ROT_NO_SUB]}${COLOR_RESET}"; return 1; }
    host=$(jq -r .host "$NB_DIR/sub.json")
    panel_ov=$(nb_wt0_ip)
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }

    step_do "${LANG[NB_ROT_MINT]}"
    token=$(nb_sub_mint_token)
    if [ -z "$token" ]; then
        local username password login_data login_response
        echo -e "${COLOR_YELLOW}${LANG[NB_ROT_LOGIN_HINT]}${COLOR_RESET}"
        reading "${LANG[NB_ROT_USERNAME]}" username || return 1
        [ -n "$username" ] || return 1
        nb_read_hidden "${LANG[NB_ROT_PASSWORD]}" password
        [ -n "$password" ] || return 1
        login_data=$(jq -n --arg u "$username" --arg p "$password" '{username:$u,password:$p}')
        login_response=$(make_api_request "POST" "http://127.0.0.1:3000/api/auth/login" "" "$login_data")
        jwt=$(echo "$login_response" | jq -r '.response.accessToken // .accessToken // empty')
        unset password
        if [ -z "$jwt" ] || [ "$jwt" = "null" ]; then
            echo -e "${COLOR_RED}${LANG[NB_ROT_LOGIN_FAIL]}: $(echo "$login_response" | jq -r '.message // ""' 2>/dev/null)${COLOR_RESET}"
            return 1
        fi
        token=$(nb_sub_mint_token "$jwt")
        unset jwt
        [ -n "$token" ] || { echo -e "${COLOR_RED}${LANG[NB_SUB_TOKEN_FAIL]}${COLOR_RESET}"; return 1; }
    fi
    step_ok "${LANG[NB_ROT_MINT_OK]}"

    step_do "${LANG[NB_ROT_PUSH]}"
    compose_new=$(re_run_host_n "$host" 'cat /opt/subscription/docker-compose.yml 2>/dev/null')
    if [ -z "$compose_new" ]; then
        unset token
        echo -e "${COLOR_RED}${LANG[NB_SUB_NO_COMPOSE]}${COLOR_RESET}"
        return 3
    fi
    compose_new=$(printf '%s\n' "$compose_new" | nb_sub_rewrite_compose "http://${panel_ov}:$(jq -r .port "$NB_DIR/sub.json")" "$token")
    unset token
    if ! printf '%s\n' "$compose_new" \
         | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.tmp && mv -f /opt/subscription/docker-compose.yml.tmp /opt/subscription/docker-compose.yml && chmod 600 /opt/subscription/docker-compose.yml' >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[NB_SUB_COMPOSE_FAIL]}${COLOR_RESET}"
        return 3
    fi
    re_run_host_n "$host" 'cd /opt/subscription && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1
    sleep 8
    if ! re_run_host_n "$host" 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "remnawave-subscription-page Up"'; then
        echo -e "${COLOR_RED}${LANG[NB_SUB_CONTAINER_DOWN]}${COLOR_RESET}"
        return 5
    fi
    nb_audit "sub token rotated host=$host"
    step_ok "${LANG[NB_ROT_DONE]}"
    return 0
}

# Rewrite a subscription compose for the overlay path. Our own installer
# formats (nginx and caddy variants) plus the wiki manual one all carry the
# same variable lines, so the transform is line-based.
nb_sub_rewrite_compose() {
    local panel_url="$1" token="$2"
    sed -e "s|^\([[:space:]]*- \)\?REMNAWAVE_PANEL_URL=.*|\1REMNAWAVE_PANEL_URL=$panel_url|" \
        -e "s|^\([[:space:]]*- \)\?REMNAWAVE_API_TOKEN=.*|\1REMNAWAVE_API_TOKEN=$token|" \
        -e "/^\([[:space:]]*- \)\?\(EGAMES_COOKIE\|CADDY_AUTH_API_TOKEN\)=/d"
}

# Full §8.6 migration of one subscription server.
nb_sub_flow() {
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }
    nb_mgmt_connected || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }
    local panel_ov
    panel_ov=$(nb_wt0_ip)
    [ -n "$panel_ov" ] || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }

    local host sub_ov key="" kid=""
    reading "${LANG[NB_SUB_HOST_PROMPT]}" host || return 1
    [ -n "$host" ] || return 1
    re_require_access_host "$host" || return 2

    step_do "${LANG[NB_SUB_STEP_LISTENER]}"
    local port
    if ! nb_listener_apply; then
        echo -e "${COLOR_RED}${LANG[NB_SUB_LISTENER_FAIL]}${COLOR_RESET}"
        return 3
    fi
    port=$(nb_state_get nb_api_port)
    step_ok "$(printf "${LANG[NB_SUB_LISTENER_OK]}" "$port")"

    # API mode: the sub needs its own group and a one-directional policy to
    # the panel's listener port.
    if nb_api_mode; then
        local gid
        gid=$(nb_group_ensure "$(nb_group_name sub)")
        [ -n "$gid" ] || { echo -e "${COLOR_RED}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"; return 3; }
        nb_state_set grp_sub "$gid"
        nb_policy_ensure "$(nb_group_name sub2panel)" "$gid" "$(nb_state_get grp_panel)" "$port" >/dev/null \
            || { echo -e "${COLOR_RED}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"; return 3; }
    fi

    # Join the machine unless its overlay is already up (one machine may
    # legitimately carry several roles).
    step_do "$(printf "${LANG[NB_SUB_STEP_JOIN]}" "$host")"
    if re_run_host_n "$host" 'netbird status --json 2>/dev/null | grep -q "\"connected\"[[:space:]]*:[[:space:]]*true"' >/dev/null 2>&1; then
        sub_ov=$(re_run_host_n "$host" "ip -4 -o addr show wt0 2>/dev/null" | awk '{print $4}' | cut -d/ -f1 | head -n1)
        nb_is_ipv4 "$sub_ov" || sub_ov=""
    fi
    if [ -z "$sub_ov" ]; then
        if ! nb_api_mode; then
            echo -e "${COLOR_RED}${LANG[NB_SUB_NEED_API]}${COLOR_RESET}"
            return 3
        fi
        re_run_host_n "$host" "$(nb_apt_repo_script)" >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_INSTALL_FAIL]}${COLOR_RESET}"; return 3; }
        local is unit="rrp-nb-apt-${NB_RUN_ID}"
        is=$(nb_apt_install_script); is=${is//INSTALL_UNIT/$unit}
        re_run_host_n "$host" "$is" >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_INSTALL_FAIL]}${COLOR_RESET}"; return 3; }
        re_run_host_n "$host" "$(nb_lazy_off_script)" >/dev/null 2>&1 || true
        local kk
        kk=$(nb_oneoff_key "$(nb_state_get grp_sub)" "rrp-sub-${NB_RUN_ID}") || return 3
        kid=${kk%% *}; key=${kk#* }
        local up_out
        up_out=$(printf '%s\n' "$key" | re_run_host "$host" "$(nb_up_script "$host" "")")
        unset key
        [ -n "$kid" ] && nb_revoke_setup_key "$kid"
        sub_ov=$(printf '%s\n' "$up_out" | sed -n 's/^RRP_OVERLAY=//p' | tail -n1)
        nb_is_ipv4 "$sub_ov" || { echo -e "${COLOR_RED}${LANG[NB_MG_UP_FAIL]}${COLOR_RESET}"; return 4; }
    fi
    step_ok "$(printf "${LANG[NB_SUB_JOIN_OK]}" "$sub_ov")"

    # Bind the peer to the sub group (auto_groups skip existing peers).
    if nb_api_mode; then
        local spid
        spid=$(nb_peer_id_by_ip "$sub_ov")
        [ -n "$spid" ] && nb_group_add_peer "$(nb_state_get grp_sub)" "$spid"
    fi

    # Allowlist the fresh IP at the listener.
    printf '{"host":"%s","overlay":"%s","port":"%s","state":"joined"}' "$host" "$sub_ov" "$port" > "$NB_DIR/sub.json"
    chmod 600 "$NB_DIR/sub.json" 2>/dev/null
    step_do "${LANG[NB_SUB_STEP_LISTENER_ALLOW]}"
    nb_listener_apply || echo -e "${COLOR_YELLOW}${LANG[NB_SUB_LISTENER_FAIL]}${COLOR_RESET}"
    step_ok "$(printf "${LANG[NB_SUB_LISTENER_OK]}" "$port")"

    # Compose: snapshot on the box and in the state, then rewrite over the
    # wire (read here, transform here, write back — no remote jq needed).
    step_do "${LANG[NB_SUB_STEP_COMPOSE]}"
    local compose_new token
    compose_new=$(re_run_host_n "$host" 'cat /opt/subscription/docker-compose.yml 2>/dev/null')
    if [ -z "$compose_new" ] || ! printf '%s\n' "$compose_new" | grep -q 'remnawave-subscription-page'; then
        echo -e "${COLOR_RED}${LANG[NB_SUB_NO_COMPOSE]}${COLOR_RESET}"
        return 3
    fi
    printf '%s' "$compose_new" | base64 -w0 > "${NB_DIR}/sub.compose.b64"
    chmod 600 "${NB_DIR}/sub.compose.b64" 2>/dev/null
    printf '%s\n' "$compose_new" | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.rrpbak' >/dev/null 2>&1

    token=$(nb_sub_mint_token)
    if [ -z "$token" ]; then
        # Minting needs an admin login JWT — an API token gets 403 on
        # /api/tokens. The overlay migration must not depend on it: keep the
        # compose's existing token (it worked publicly, it works over the
        # overlay) and say so; rotation is a separate action.
        local old_tok
        old_tok=$(printf '%s\n' "$compose_new" | sed -n 's/.*REMNAWAVE_API_TOKEN=//p' | head -n1)
        if [ -n "$old_tok" ]; then
            echo -e "${COLOR_YELLOW}${LANG[NB_SUB_TOKEN_KEPT]}${COLOR_RESET}"
            token="$old_tok"
        else
            echo -e "${COLOR_RED}${LANG[NB_SUB_TOKEN_FAIL]}${COLOR_RESET}"
            return 3
        fi
    fi
    compose_new=$(printf '%s\n' "$compose_new" | nb_sub_rewrite_compose "http://${panel_ov}:${port}" "$token")

    if ! printf '%s\n' "$compose_new" \
         | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.tmp && mv -f /opt/subscription/docker-compose.yml.tmp /opt/subscription/docker-compose.yml && chmod 600 /opt/subscription/docker-compose.yml' >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[NB_SUB_COMPOSE_FAIL]}${COLOR_RESET}"
        return 3
    fi
    unset compose_new
    re_run_host_n "$host" 'cd /opt/subscription && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1 \
        || { echo -e "${COLOR_RED}${LANG[NB_SUB_UP_FAIL]}${COLOR_RESET}"; return 3; }
    step_ok "${LANG[NB_SUB_COMPOSE_OK]}"

    # Verify: the container exits 1 when the panel is unreachable — staying
    # up IS the overlay proof. The listener must also answer the sub box
    # with 200 on metadata, authorized by the token it just received.
    step_do "${LANG[NB_SUB_STEP_VERIFY]}"
    local i down=0 meta
    for i in 1 2 3 4 5 6; do
        sleep 5
        if ! re_run_host_n "$host" 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "remnawave-subscription-page Up"'; then
            down=1; break
        fi
    done
    if [ "$down" = 1 ]; then
        echo -e "${COLOR_RED}${LANG[NB_SUB_CONTAINER_DOWN]}${COLOR_RESET}"
        unset token
        nb_sub_rollback "$host"
        return 5
    fi
    meta=$(printf 'Authorization: Bearer %s\nX-Forwarded-For: 10.0.0.1\n' "$token" \
        | re_run_host "$host" 'read -r h; curl -s -o /dev/null -w "%{http_code}" -m 10 -H "$h" "http://'"${panel_ov}"':'"$port"'/api/system/metadata"' 2>/dev/null)
    unset token
    if [ "$meta" != "200" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_META_FAIL]}" "${meta:-no answer}")${COLOR_RESET}"
        nb_sub_rollback "$host"
        return 5
    fi
    printf '{"host":"%s","overlay":"%s","port":"%s","state":"connected"}' "$host" "$sub_ov" "$port" > "$NB_DIR/sub.json"
    chmod 600 "$NB_DIR/sub.json" 2>/dev/null
    nb_audit "sub migrated host=$host overlay=$sub_ov port=$port"
    step_ok "${LANG[NB_SUB_DONE_STEP]}"
    echo -e "${COLOR_GREEN}$(printf "${LANG[NB_SUB_DONE]}" "$host" "$sub_ov")${COLOR_RESET}"
    return 0
}

nb_sub_rollback() {
    local host="$1" had
    step_do "${LANG[NB_SUB_ROLLBACK]}"
    if [ -s "${NB_DIR}/sub.compose.b64" ]; then
        base64 -d "${NB_DIR}/sub.compose.b64" \
            | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.tmp && mv -f /opt/subscription/docker-compose.yml.tmp /opt/subscription/docker-compose.yml' >/dev/null 2>&1
        re_run_host_n "$host" 'cd /opt/subscription && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1
    fi
    rm -f "$NB_DIR/sub.json" "${NB_DIR}/sub.compose.b64"
    nb_listener_apply >/dev/null 2>&1
    nb_audit "sub rolled back host=$host"
    step_ok "${LANG[NB_SUB_ROLLBACK_OK]}"
    return 0
}

# ---------------------------------------------------------------------------
# Xray Checker over overlay (PR4, §8.7): the checker fetches its subscription
# from the listener's /api/sub/ only; node checks keep going over public
# addresses; metrics/UI answer overlay peers alone.
# ---------------------------------------------------------------------------

# Monitor user + its raw subscription path. Self-contained mirror of
# xchk_ensure_monitor_user's core (the xchk original demands a full public
# subscriptionUrl; over overlay only the shortUuid tail matters).
NB_XCHK_MONITOR_USER="xray-checker"
NB_XCHK_IMAGE="kutovoys/xray-checker:latest"

nb_xchk_assign_squads() {
    # self-sufficient: this helper may run in a subshell where no flow
    # loaded the panel API module beforehand
    command -v make_api_request >/dev/null 2>&1 || load_api_module >/dev/null 2>&1 || true
    local token="$1" response squads squads_json
    response=$(make_api_request "GET" "http://127.0.0.1:3000/api/internal-squads?_=$(date +%s)" "$token")
    squads=$(echo "$response" | jq -r '[.response.internalSquads[]?.uuid] | join(" ")' 2>/dev/null)
    [ -z "$squads" ] && return 1
    squads_json=$(printf '%s\n' $squads | jq -R . | jq -s .)
    response=$(make_api_request "PATCH" "http://127.0.0.1:3000/api/users" "$token" \
        "$(jq -n --arg u "$NB_XCHK_MONITOR_USER" --argjson s "$squads_json" \
            '{username: $u, activeInternalSquads: $s}')")
    echo "$response" | jq -e '.response.username' >/dev/null 2>&1
}

nb_xchk_short_uuid() {
    local token response sub_url
    nb_load_api || return 1
    token=$(cat "${DIR_REMNAWAVE}token")
    response=$(make_api_request "GET" "http://127.0.0.1:3000/api/users/by-username/${NB_XCHK_MONITOR_USER}?_=$(date +%s)" "$token")
    sub_url=$(echo "$response" | jq -r '.response.subscriptionUrl // empty' 2>/dev/null)
    if [ -z "$sub_url" ]; then
        local expire_at
        expire_at=$(date -u -d "+10 years" +%Y-%m-%dT%H:%M:%S.000Z)
        response=$(make_api_request "POST" "http://127.0.0.1:3000/api/users" "$token" \
            "$(jq -n --arg u "$NB_XCHK_MONITOR_USER" \
                --arg d "Monitoring user for Xray Checker (created by remnawave-reverse-proxy)" \
                --arg e "$expire_at" \
                '{username: $u, description: $d, expireAt: $e}')")
        sub_url=$(echo "$response" | jq -r '.response.subscriptionUrl // empty' 2>/dev/null)
    fi
    [ -n "$sub_url" ] || return 1
    # Without squads the panel serves a placeholder entry and the checker
    # dies on "no valid proxy configurations" — sync on every run (the
    # design wants every enabled host in the checker's subscription).
    nb_xchk_assign_squads "$token" || true
    # subscriptionUrl = https://host/api/sub/<shortUuid> — only the tail is
    # the secret; the host part is replaced by the overlay listener anyway.
    printf '%s' "$sub_url" | awk -F/ '{print $NF}'
}

nb_checker_flow() {
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }
    nb_mgmt_connected || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }
    nb_api_mode || { echo -e "${COLOR_YELLOW}${LANG[NB_POL_NO_API]}${COLOR_RESET}"; return 1; }
    local panel_ov
    panel_ov=$(nb_wt0_ip)
    [ -n "$panel_ov" ] || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }

    step_do "${LANG[NB_XCHK_STEP_USER]}"
    local short
    short=$(nb_xchk_short_uuid) || { echo -e "${COLOR_RED}${LANG[NB_XCHK_USER_FAIL]}${COLOR_RESET}"; return 3; }
    step_ok "$(printf "${LANG[NB_XCHK_USER_OK]}" "$NB_XCHK_MONITOR_USER")"

    step_do "${LANG[NB_SUB_STEP_LISTENER]}"
    local port
    nb_listener_apply || { echo -e "${COLOR_RED}${LANG[NB_SUB_LISTENER_FAIL]}${COLOR_RESET}"; return 3; }
    port=$(nb_state_get nb_api_port)

    local gid
    gid=$(nb_group_ensure "$(nb_group_name checker)")
    [ -n "$gid" ] || { echo -e "${COLOR_RED}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"; return 3; }
    nb_state_set grp_checker "$gid"
    nb_policy_ensure "$(nb_group_name checker2panel)" "$gid" "$(nb_state_get grp_panel)" "$port" >/dev/null \
        || { echo -e "${COLOR_RED}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"; return 3; }
    # The panel scrapes metrics over the overlay; a dedicated admins group
    # replaces it later (§8.8).
    nb_policy_ensure "$(nb_group_name panel2checker)" "$(nb_state_get grp_panel)" "$gid" 2112 >/dev/null || true
    step_ok "${LANG[NB_POL_GROUPS_OK]}"

    local host chk_ov key="" kid=""
    reading "${LANG[NB_XCHK_HOST_PROMPT]}" host || return 1
    [ -n "$host" ] || return 1
    re_require_access_host "$host" || return 2

    step_do "$(printf "${LANG[NB_SUB_STEP_JOIN]}" "$host")"
    if re_run_host_n "$host" 'netbird status --json 2>/dev/null | grep -q "\"connected\"[[:space:]]*:[[:space:]]*true"' >/dev/null 2>&1; then
        chk_ov=$(re_run_host_n "$host" "ip -4 -o addr show wt0 2>/dev/null" | awk '{print $4}' | cut -d/ -f1 | head -n1)
        nb_is_ipv4 "$chk_ov" || chk_ov=""
    fi
    if [ -z "$chk_ov" ]; then
        re_run_host_n "$host" "$(nb_apt_repo_script)" >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_INSTALL_FAIL]}${COLOR_RESET}"; return 3; }
        local is unit="rrp-nb-apt-${NB_RUN_ID}"
        is=$(nb_apt_install_script); is=${is//INSTALL_UNIT/$unit}
        re_run_host_n "$host" "$is" >/dev/null 2>&1 || { echo -e "${COLOR_RED}${LANG[NB_INSTALL_FAIL]}${COLOR_RESET}"; return 3; }
        re_run_host_n "$host" "$(nb_lazy_off_script)" >/dev/null 2>&1 || true
        local kk up_out
        kk=$(nb_oneoff_key "$gid" "rrp-chk-${NB_RUN_ID}") || return 3
        kid=${kk%% *}; key=${kk#* }
        up_out=$(printf '%s\n' "$key" | re_run_host "$host" "$(nb_up_script "$host" "")")
        unset key
        [ -n "$kid" ] && nb_revoke_setup_key "$kid"
        chk_ov=$(printf '%s\n' "$up_out" | sed -n 's/^RRP_OVERLAY=//p' | tail -n1)
        nb_is_ipv4 "$chk_ov" || { echo -e "${COLOR_RED}${LANG[NB_MG_UP_FAIL]}${COLOR_RESET}"; return 4; }
    fi
    local cpid
    cpid=$(nb_peer_id_by_ip "$chk_ov")
    [ -n "$cpid" ] && nb_group_add_peer "$gid" "$cpid"
    step_ok "$(printf "${LANG[NB_SUB_JOIN_OK]}" "$chk_ov")"

    printf '{"host":"%s","overlay":"%s","port":"%s","state":"joined"}' "$host" "$chk_ov" "$port" > "$NB_DIR/checker.json"
    chmod 600 "$NB_DIR/checker.json" 2>/dev/null
    step_do "${LANG[NB_SUB_STEP_LISTENER_ALLOW]}"
    nb_listener_apply || echo -e "${COLOR_YELLOW}${LANG[NB_SUB_LISTENER_FAIL]}${COLOR_RESET}"
    step_ok "$(printf "${LANG[NB_SUB_LISTENER_OK]}" "$port")"

    # Minimal remote stack: checker only, host network, metrics on 0.0.0.0
    # guarded by basic auth (generated here, stored in the state file), the
    # public interface stays closed by ufw — overlay peers alone see it.
    step_do "${LANG[NB_XCHK_STEP_STACK]}"
    local ui_user="rrp" ui_pass
    ui_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    local compose
    compose=$(cat <<EOL
services:
  xray-checker:
    image: ${NB_XCHK_IMAGE}
    container_name: xray-checker
    hostname: xray-checker
    restart: unless-stopped
    network_mode: host
    environment:
      - SUBSCRIPTION_URL=http://${panel_ov}:${port}/api/sub/${short}
      - SUBSCRIPTION_UPDATE=true
      - SUBSCRIPTION_UPDATE_INTERVAL=300
      - PROXY_CHECK_INTERVAL=60
      - PROXY_CHECK_METHOD=ip
      - PROXY_TIMEOUT=30
      - METRICS_HOST=0.0.0.0
      - METRICS_PORT=2112
      - METRICS_PROTECTED=true
      - METRICS_USERNAME=${ui_user}
      - METRICS_PASSWORD=${ui_pass}
      - XRAY_LOG_LEVEL=none
      - LOG_LEVEL=info
EOL
)
    if ! printf '%s\n' "$compose" \
         | re_run_host "$host" 'umask 077; mkdir -p /opt/xray-checker && cat > /opt/xray-checker/docker-compose.yml.tmp && mv -f /opt/xray-checker/docker-compose.yml.tmp /opt/xray-checker/docker-compose.yml' >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[NB_XCHK_STACK_FAIL]}${COLOR_RESET}"
        return 3
    fi
    re_run_host_n "$host" 'cd /opt/xray-checker && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1 \
        || { echo -e "${COLOR_RED}${LANG[NB_SUB_UP_FAIL]}${COLOR_RESET}"; nb_checker_rollback "$host"; return 3; }
    step_ok "${LANG[NB_XCHK_STACK_OK]}"

    # Verify: the subscription must load over the overlay (the checker exits
    # without it) and metrics must answer the panel peer — never the public.
    step_do "${LANG[NB_SUB_STEP_VERIFY]}"
    local i down=0
    for i in 1 2 3 4 5 6; do
        sleep 5
        if ! re_run_host_n "$host" 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "xray-checker Up"'; then
            down=1; break
        fi
    done
    if [ "$down" = 1 ]; then
        echo -e "${COLOR_RED}${LANG[NB_XCHK_CONTAINER_DOWN]}${COLOR_RESET}"
        nb_checker_rollback "$host"
        return 5
    fi
    local sub_code
    sub_code=$(re_run_host_n "$host" "curl -s -o /dev/null -w '%{http_code}' -m 10 http://${panel_ov}:${port}/api/sub/${short}" 2>/dev/null)
    if [ "$sub_code" != "200" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_XCHK_SUB_FAIL]}" "${sub_code:-no answer}")${COLOR_RESET}"
        nb_checker_rollback "$host"
        return 5
    fi
    local m_code
    m_code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 -u "${ui_user}:${ui_pass}" "http://${chk_ov}:2112/metrics" 2>/dev/null)
    printf '{"host":"%s","overlay":"%s","port":"%s","metrics_user":"%s","metrics_pass":"%s","state":"connected"}' \
        "$host" "$chk_ov" "$port" "$ui_user" "$ui_pass" > "$NB_DIR/checker.json"
    chmod 600 "$NB_DIR/checker.json" 2>/dev/null
    nb_audit "checker migrated host=$host overlay=$chk_ov"
    step_ok "${LANG[NB_SUB_DONE_STEP]}"
    echo -e "${COLOR_GREEN}$(printf "${LANG[NB_XCHK_DONE]}" "$host" "$chk_ov" "${m_code:-?}")${COLOR_RESET}"
    return 0
}

nb_checker_rollback() {
    local host="$1"
    step_do "${LANG[NB_SUB_ROLLBACK]}"
    re_run_host_n "$host" 'cd /opt/xray-checker && { docker compose down || docker-compose down; }' >/dev/null 2>&1
    rm -f "$NB_DIR/checker.json"
    nb_listener_apply >/dev/null 2>&1
    nb_audit "checker rolled back host=$host"
    step_ok "${LANG[NB_SUB_ROLLBACK_OK]}"
}

# ---------------------------------------------------------------------------
# Nodes flow (§7.2): the menu label promises migrate AND import of a manual
# scheme — nb_import used to be dead code with no way to reach it.
# ---------------------------------------------------------------------------

nb_nodes_flow() {
    local pick
    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[NB_MENU_NODES]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[NB_MG_TITLE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[NB_IMP_TITLE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" pick || return 0
        case "$pick" in
            1)
                nb_migrate
                ;;
            2)
                nb_import
                ;;
            0) return 0 ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Menu (§7.2)
# ---------------------------------------------------------------------------

nb_header() {
    echo -e "${COLOR_GREEN}${LANG[NB_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[NB_DOC_LINK]}${COLOR_RESET}"
    echo -e ""
    if ! nb_pkg_installed; then
        echo -e " ${COLOR_GRAY}${LANG[NB_DIAG_NO_CLIENT]}${COLOR_RESET}"
    else
        local hold="" cidr conn ver mode
        nb_hold_on && hold=" (версия закреплена)"
        ver="$(nb_client_version)${hold}"
        cidr=$(nb_wt0_cidr); cidr=${cidr:--}
        nb_mgmt_connected && conn="есть" || conn="нет"
        mode=$(nb_state_get mode || echo basic)
        [ "$mode" = "api" ] && mode="API" || mode="базовый"
        echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_H_CLIENT]}" "$ver" "$cidr" "$conn")${COLOR_RESET}"
        echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_H_MODE]}" "$mode")${COLOR_RESET}"
    fi
    local f warn
    for f in "$NB_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        jq -e '.state == "rollback_failed"' "$f" >/dev/null 2>&1 && {
            warn="${warn}$(jq -r '.name' "$f" 2>/dev/null) "
        }
    done
    [ -n "$warn" ] && echo -e " ${COLOR_RED}$(printf "${LANG[NB_H_WARN]}" "$warn")${COLOR_RESET}"
    echo -e ""
}

nb_menu() {
    local last=0 submenu=0
    local opt_join=99 opt_nodes=99 opt_bg=99 opt_sub=99 opt_xchk=99 opt_diag=99 opt_pol=99 opt_set=99 opt_flags=99 opt_upd=99 opt_off=99 opt_purge=99
    while true; do
        last=0
        submenu=0
        echo -e ""
        nb_header

        last=$((last + 1)); opt_join=$last
        echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_JOIN]}${COLOR_RESET}"

        if panel_is_installed; then
            last=$((last + 1)); opt_nodes=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_NODES]}${COLOR_RESET}"
            last=$((last + 1)); opt_bg=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_BG]}${COLOR_RESET}"
            last=$((last + 1)); opt_sub=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_SUB]}${COLOR_RESET}"
            last=$((last + 1)); opt_xchk=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_XCHK]}${COLOR_RESET}"
        fi

        last=$((last + 1)); opt_diag=$last
        echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_DIAG]}${COLOR_RESET}"

        # Policies live in API mode only; activation sits in Settings.
        if nb_api_mode; then
            last=$((last + 1)); opt_pol=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_POL]}${COLOR_RESET}"
        fi

        last=$((last + 1)); opt_set=$last
        echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_SET]}${COLOR_RESET}"

        if nb_pkg_installed; then
            last=$((last + 1)); opt_flags=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_FLAGS]}${COLOR_RESET}"
            last=$((last + 1)); opt_upd=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_UPDATE]}${COLOR_RESET}"
            last=$((last + 1)); opt_off=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_OFF]}${COLOR_RESET}"
            last=$((last + 1)); opt_purge=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_MENU_PURGE]}${COLOR_RESET}"
        fi

        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        local pick
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" pick || return 0

        [ "$pick" = "0" ] && return 0
        if [ "$pick" = "$opt_join" ]; then
            nb_join
        elif [ "$pick" = "$opt_nodes" ] && [ "$opt_nodes" != 99 ]; then
            submenu=1
            nb_nodes_flow
        elif [ "$pick" = "$opt_bg" ] && [ "$opt_bg" != 99 ]; then
            nb_breakglass
        elif [ "$pick" = "$opt_sub" ] && [ "$opt_sub" != 99 ]; then
            submenu=1
            nb_sub_flow
        elif [ "$pick" = "$opt_xchk" ] && [ "$opt_xchk" != 99 ]; then
            submenu=1
            nb_checker_flow
        elif [ "$pick" = "$opt_diag" ]; then
            nb_diag
        elif [ "$pick" = "$opt_pol" ] && [ "$opt_pol" != 99 ]; then
            submenu=1
            nb_policies_flow
        elif [ "$pick" = "$opt_set" ]; then
            submenu=1
            nb_settings_flow
        elif [ "$pick" = "$opt_flags" ] && [ "$opt_flags" != 99 ]; then
            nb_fix_flags
        elif [ "$pick" = "$opt_upd" ] && [ "$opt_upd" != 99 ]; then
            nb_update
        elif [ "$pick" = "$opt_off" ] && [ "$opt_off" != 99 ]; then
            nb_disable
        elif [ "$pick" = "$opt_purge" ] && [ "$opt_purge" != 99 ]; then
            nb_purge
        else
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
        fi
        # Submenu flows loop and redraw on their own and their output stays
        # on screen above the header; pausing after an exit chosen with 0
        # would demand a second Enter for nothing.
        if [ "$submenu" -eq 0 ]; then
            echo -e ""
            read -rp "$(printf %b " ${COLOR_GRAY}${LANG[NB_RETURN]}${COLOR_RESET}")" _ || return 0
        fi
    done
}

manage_netbird() {
    nb_ensure_dirs
    exec 9>"$NB_LOCK"
    if ! flock -n 9; then
        echo -e "${COLOR_YELLOW}${LANG[NB_ERR_LOCK]}${COLOR_RESET}"
        return 0
    fi
    trap nb_on_abort INT TERM HUP
    nb_menu
    local rc=$?
    trap - INT TERM HUP
    # The fd must not leak into the nested remnawave_reverse run.
    exec 9>&-
    return 0
}
