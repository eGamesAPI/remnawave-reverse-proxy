#!/bin/bash
# Module: NetBird

NB_DIR="${DIR_REMNAWAVE}netbird"
NB_STATE="$NB_DIR/netbird.json"
NB_NODES_DIR="$NB_DIR/nodes"
NB_AUDIT="$NB_DIR/audit.log"
# The lock sits next to, not inside, the state dir: purge wipes the dir
# while this very lock is held, and a lock file deleted under flock lets a
# second instance take a fresh one.
NB_LOCK="${DIR_REMNAWAVE}netbird.lock"
NB_PAT_FILE="$NB_DIR/pat"
# NetBird management API, cloud default; a self-hosted management URL from
# the join overrides it (nb_nb_api_base). NB_API_BASE further below is the
# PANEL's API — two different backends, two names.
NB_NB_API_BASE="https://api.netbird.io"
NB_IFACE="wt0"
NB_MIN_VERSION="0.71"
NB_NODE_PORT=2222
NB_API_BASE="http://127.0.0.1:3000"
NB_RUN_ID="${NB_RUN_ID:-$RANDOM$RANDOM}"
NB_NOTE_MARK_PREFIX="[rrp-nb:old="
# UpdateNode.note maxLength in the panel API.
NB_NOTE_MAX=255
# Every netbird up must carry the full set, = form only: "up" persists only
# flags passed explicitly and ignores a bare "--flag false" positional.
NB_UP_FLAGS="--disable-dns=true --disable-client-routes=true --disable-server-routes=true --block-inbound=false --disable-firewall=false"

# ---------------------------------------------------------------------------
# State, journal. Files are read with jq/sed, never sourced.
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

# rc=0 when two IPv4 blocks (a bare IP counts as /32) share any address.
# CIDR blocks are nested or disjoint, so one must hold the other's address.
nb_cidr_overlap() {
    local a="$1" b="$2"
    case "$a" in */*) ;; *) a="$a/32" ;; esac
    case "$b" in */*) ;; *) b="$b/32" ;; esac
    nb_cidr_holds "${a%/*}" "$b" || nb_cidr_holds "${b%/*}" "$a"
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
# An installed (possibly held) client is a success: a bare install -y on a
# held package fails once a newer candidate appears, and on an unheld one
# it would silently upgrade and restart the daemon.
if ! dpkg-query -W -f='${Status}' netbird 2>/dev/null | grep -q 'ok installed'; then
    systemd-run --unit=rrp-nb-apt-INSTALL_UNIT --collect --wait \
        -p Environment=DEBIAN_FRONTEND=noninteractive \
        apt-get -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=300 install -y netbird
fi
apt-mark hold netbird
command -v netbird >/dev/null 2>&1
EOL
}

nb_lazy_off_script() {
    # reconfigure always stops and restarts a running daemon: skip it when
    # lazy connections are already off (every overlay peer would blink).
    cat <<'EOL'
grep -q 'NB_LAZY_CONN.*off' /var/lib/netbird/service.json 2>/dev/null && exit 0
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
    local hn="$1" mgmt="$2" pre="${3:-}" flags run f pre_cmd=":"
    # Both land inside single quotes of a root script: anything outside the
    # hostname/URL alphabets is flattened, never trusted to be quote-free.
    hn=$(printf '%s' "$hn" | tr -c 'A-Za-z0-9._-' '-' | cut -c1-63)
    [ -n "$hn" ] || hn="rrp-${NB_RUN_ID}"
    printf '%s' "$mgmt" | grep -qE '^https://[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$' || mgmt=""
    # "down": an already connected client ignores up's flags — drop the
    # session first so SetConfig runs (operator-confirmed re-registration).
    [ "$pre" = "down" ] && pre_cmd="netbird down >/dev/null 2>&1 || true"
    # --disable-ipv6 is decided by the machine that runs `up` (the script
    # checks its own sysctl), never by the panel's IPv6 state.
    flags="${NB_UP_FLAGS}"
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
${pre_cmd}
v6=""
if [ "\$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" = "1" ]; then v6="--disable-ipv6=true"; fi
rc=0
up_log=\$(env -i HOME=/root PATH=/usr/sbin:/usr/bin:/sbin:/bin netbird up --setup-key-file "\$f" --hostname '${hn}' ${flags} \${v6}${mgmt:+ --management-url '${mgmt}'} 2>&1) || rc=\$?
printf '%s\n' "\$up_log" >&2
[ \$rc -ne 0 ] && exit \$rc
# A connected client skips SetConfig: flags and hostname were not applied.
case "\$up_log" in *"Already connected"*) echo "RRP_ALREADY=1" ;; esac
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

# Management URL the panel itself joined with, for remote `up` calls: empty
# for the cloud default (the client's built-in URL), the self-hosted URL
# otherwise — a bare `up` on a fresh box always lands in the cloud.
nb_mgmt_for_remote() {
    local u
    u=$(nb_state_get mgmt_url)
    [ -n "$u" ] || u=$(nb_mgmt_url)
    printf '%s' "$u" | grep -qE '^https://[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$' || return 0
    case "$u" in
        https://api.netbird.io|https://api.netbird.io/*|https://api.netbird.io:443|https://api.netbird.io:443/*) return 0 ;;
    esac
    printf '%s' "$u"
}

# Management REST API base: a self-hosted management serves /api on the same
# host:port as its gRPC, so the PAT goes where the panel is registered and
# never to the cloud by default.
nb_nb_api_base() {
    local u
    # "Cloud" and "unknown/unusable" are different answers: an unknown URL
    # (no join yet) or a non-https one must never default the PAT to the
    # cloud — return 1 and let the caller refuse.
    u=$(nb_state_get mgmt_url)
    [ -n "$u" ] || u=$(nb_mgmt_url)
    [ -n "$u" ] || return 1
    case "$u" in
        https://api.netbird.io|https://api.netbird.io/*|https://api.netbird.io:443|https://api.netbird.io:443/*)
            printf '%s' "$NB_NB_API_BASE"
            return 0
            ;;
    esac
    printf '%s' "$u" | grep -qE '^https://[A-Za-z0-9._-]+(:[0-9]+)?(/[A-Za-z0-9._/-]*)?$' || return 1
    printf '%s' "$u" | sed -E 's#^(https://[A-Za-z0-9._-]+(:[0-9]+)?).*#\1#'
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
    local out="$1" marker="$NB_NOTE_MARK_PREFIX" head rest
    # The closing "]" is searched AFTER the marker: a "]" earlier in the note
    # ("[DE] ...") used to glue the marker back in and grow the string without
    # end. Every pass drops one marker, so the loop always terminates.
    while [[ "$out" == *"${marker}"* ]]; do
        head="${out%%"${marker}"*}"
        rest="${out#*"${marker}"}"
        if [[ "$rest" == *"]"* ]]; then
            out="${head}${rest#*"]"}"
        else
            out="$head"
            break
        fi
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
    local token="$1" uuid="$2" note="$3" body r
    # jq --arg keeps a multi-line note one JSON string (jq -R split it into
    # several and broke the body); rc=0 only when the panel stored exactly
    # this note. UpdateNode caps the note at NB_NOTE_MAX characters.
    [ "${#note}" -le "$NB_NOTE_MAX" ] || return 1
    body=$(jq -nc --arg u "$uuid" --arg n "$note" '{uuid:$u, note:$n}') || return 1
    r=$(make_api_request "PATCH" "${NB_API_BASE}/api/nodes" "$token" "$body" 2>/dev/null)
    printf '%s' "$r" | jq -e --arg n "$note" '(.response.note // "") == $n' >/dev/null 2>&1
}

# Note with the old-address marker appended; the free-text part is cut so
# the whole string fits the panel's limit and the marker is never lost.
nb_note_with_marker() {
    local base marker="${NB_NOTE_MARK_PREFIX}$2]" room
    base=$(nb_note_strip "$1")
    room=$(( NB_NOTE_MAX - ${#marker} ))
    [ "$room" -lt 0 ] && room=0
    [ "${#base}" -gt "$room" ] && base="${base:0:$room}"
    printf '%s%s' "$base" "$marker"
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
# The container copy is judged on its own too: with NetBird DNS active on
# the host both files match, yet a later flags fix restores the host file
# and leaves the container on a resolver that no longer listens.
wc=$(ip -4 -o addr show dev wt0 2>/dev/null | awk '{print $4; exit}')
nb_gen=0
grep -q 'Generated by NetBird' /etc/resolv.conf 2>/dev/null && nb_gen=1
if [ "$nb_gen" = 0 ] && command -v ss >/dev/null 2>&1 \
   && ss -Hlunp 'sport = :53' 2>/dev/null | grep -q netbird; then
    nb_gen=1
fi
in_wt0() {
    [ -n "$wc" ] || return 1
    oldifs=$IFS; IFS=.
    set -- $1 ${wc%/*}
    IFS=$oldifs
    [ $# -eq 8 ] || return 1
    bits=${wc#*/}
    m=$(( (0xFFFFFFFF << (32 - bits)) & 0xFFFFFFFF ))
    [ $(( ((($1 << 24) + ($2 << 16) + ($3 << 8) + $4)) & m )) -eq $(( ((($5 << 24) + ($6 << 16) + ($7 << 8) + $8)) & m )) ]
}
while read -r ns; do
    case "$ns" in
        127.0.0.153) rm -f /tmp/rrp-nb-a.$$ /tmp/rrp-nb-b.$$; exit 9 ;;
        127.0.0.1|100.*)
            if [ "$nb_gen" = 1 ] || in_wt0 "$ns"; then
                rm -f /tmp/rrp-nb-a.$$ /tmp/rrp-nb-b.$$
                exit 9
            fi
            ;;
    esac
done < /tmp/rrp-nb-a.$$
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
# even the SYN-ACK to 2222 (F19, B-14). Preset files hold "<id>\t<entry>"
# lines and apply to every node, so the test is an overlap of any address
# entry with the overlay prefix, not a node name/address lookup.
nb_plugin_blocks_overlay() {
    local prefix="${1:-100.64.0.0/10}" f _id entry
    for f in "${DIR_REMNAWAVE}egress-preset.state" "${DIR_REMNAWAVE}ingress-preset.state"; do
        [ -f "$f" ] || continue
        while IFS=$'\t' read -r _id entry; do
            nb_cidr_overlap "$entry" "$prefix" && return 0
        done < "$f"
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
                # The live prefix, not a stale one from an earlier account:
                # the "already in overlay" guards read network_cidr first.
                local cur_prefix
                cur_prefix=$(nb_overlay_prefix)
                [ -n "$cur_prefix" ] && nb_state_set network_cidr "$cur_prefix"
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
    # The core objects bind THIS machine into the panel group: only the
    # panel may take the API branch.
    if nb_api_mode && panel_is_installed; then
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
    # With wt0 up the panel peer is found by IP: a pre-registered peer does
    # not inherit the one-off key's auto_groups, so bind it now.
    if [ -n "$kid" ]; then
        nb_ensure_core_objects || echo -e "${COLOR_YELLOW}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"
    fi

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
        # Panel only: on a node or a sub box the funnel would put that
        # machine into the panel group and create a stray policy set.
        local api_now
        if panel_is_installed; then
            echo -e " ${COLOR_GRAY}${LANG[NB_JOIN_API_HINT]}${COLOR_RESET}"
            if reading_yn "${LANG[NB_JOIN_API_ASK]}" api_now; then
                if nb_activate_api; then
                    nb_policies_flow
                    return 0
                fi
            fi
        fi
        nb_policy_checklist
    fi
    return 0
}

# Collisions of the overlay prefix with routes, interfaces and docker nets.
# The destination is the FIRST field of a route line ($2 is "via"/"dev");
# the overlay's own wt0 routes are ours. Blocks overlap in either direction
# (a docker 100.64.0.0/10 swallows the whole overlay), every IPAM subnet counts.
nb_prefix_collisions() {
    local prefix="$1" out="" subnet name subs
    while read -r subnet; do
        [ -n "$subnet" ] || continue
        nb_cidr_overlap "$subnet" "$prefix" && out="${out}route:${subnet}, "
    done < <(ip -4 -o route 2>/dev/null | grep -v "[[:space:]]dev ${NB_IFACE}\([[:space:]]\|\$\)" | awk '$1 != "default" {print $1}')
    while read -r name subs; do
        for subnet in $subs; do
            nb_cidr_overlap "$subnet" "$prefix" && out="${out}docker:${name}(${subnet}), "
        done
    done < <(docker network inspect -f '{{.Name}} {{range .IPAM.Config}}{{.Subnet}} {{end}}' $(docker network ls -q 2>/dev/null) 2>/dev/null)
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

NB_PAT_TMP=""

nb_on_abort() {
    # An access token candidate never outlives an interrupted activation.
    [ -n "$NB_PAT_TMP" ] && rm -f "$NB_PAT_TMP"
    # A finished outcome (failed, rolled back, connected) is never rewritten
    # into aborted_at_*: the header's rollback_failed alarm lives on it.
    if [ -n "$nb_current_uuid" ] && [ -n "$nb_current_step" ]; then
        case "$(nb_node_get "$nb_current_uuid" state 2>/dev/null)" in
            rollback_failed|rolled_back|connected|dns_blocked|*_failed) nb_current_step="" ;;
        esac
    fi
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

# A node address that lands on the panel's own host: its overlay IP, the
# panel domain, a local interface address or the public IPv4 (directly or
# through a name). Such a node is local — "migrating" it would ssh into the
# panel itself, restart its NetBird daemon and pin the node to the overlay.
nb_addr_is_panel_host() {
    local a="$1" dom self_ov ips x locals pub=""
    [ -n "$a" ] || return 1
    self_ov=$(nb_wt0_ip)
    [ -n "$self_ov" ] && [ "$a" = "$self_ov" ] && return 0
    dom=$(sed -n 's/^PANEL_DOMAIN=//p' /opt/remnawave/.env 2>/dev/null | head -n1 | tr -d "\"'")
    [ -n "$dom" ] && [ "$a" = "$dom" ] && return 0
    if nb_is_ipv4 "$a"; then
        ips="$a"
    else
        ips=$(getent ahostsv4 "$a" 2>/dev/null | awk '{print $1}' | sort -u)
    fi
    [ -n "$ips" ] || return 1
    locals=$(ip -4 -o addr show 2>/dev/null | awk '{split($4, p, "/"); print p[1]}')
    for x in $ips; do
        printf '%s\n' "$locals" | grep -qxF "$x" && return 0
    done
    # Behind NAT the public IPv4 is on no interface: ask once, only now.
    pub=$(nb_public_ipv4) || return 1
    for x in $ips; do
        [ "$x" = "$pub" ] && return 0
    done
    return 1
}

nb_ufw_wt0_rule() { printf 'allow in on %s from %s to any port %s proto tcp' "$NB_IFACE" "$1" "$NB_NODE_PORT"; }

# Peer hostname from a free-text panel node name: the same normalisation as
# the join prompt, a stable fallback when nothing usable is left.
nb_node_hostname() {
    local hn
    hn=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | tr -c 'a-z0-9-' '-' | cut -c1-63)
    hn=$(printf '%s' "$hn" | sed 's/^-*//; s/-*$//')
    # A name flattened to bare digits ("Германия 1" → "1") collides across
    # nodes: at least one latin letter, else the unique fallback.
    { printf '%s' "$hn" | grep -qE '^[a-z0-9-]{1,63}$' && printf '%s' "$hn" | grep -q '[a-z]'; } \
        || hn="rrp-node-$(printf '%s' "$2" | cut -c1-8)"
    printf '%s' "$hn"
}

# Every exit of a migration clears the in-flight markers: a later ^C at an
# unrelated prompt must not stamp aborted_at_* onto this node's outcome.
nb_migrate() {
    local rc
    nb_migrate_run
    rc=$?
    nb_current_step=""
    nb_current_uuid=""
    return $rc
}

nb_migrate_run() {
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
    if nb_addr_is_panel_host "$address"; then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_LOCAL_HOST_SKIP]}" "$name" "$address")${COLOR_RESET}"
        return 1
    fi
    [ -n "$proxy" ] && [ "$proxy" != "null" ] && { echo -e "${COLOR_YELLOW}${LANG[NB_MG_PROXY_SKIP]}${COLOR_RESET}"; return 1; }
    [ "$iconn" = "true" ] || echo -e "${COLOR_YELLOW}${LANG[NB_MG_NOT_CONNECTED]}${COLOR_RESET}"

    local prefix live_prefix
    prefix=$(nb_state_get network_cidr)
    live_prefix=$(nb_overlay_prefix)
    [ -n "$prefix" ] || prefix="$live_prefix"
    # The live wt0 prefix is checked too: a stale network_cidr must not let
    # an overlay address through to be snapshotted as the "old" public one.
    if { [ -n "$prefix" ] && nb_cidr_holds "$address" "$prefix"; } \
       || { [ -n "$live_prefix" ] && nb_cidr_holds "$address" "$live_prefix"; }; then
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
    done
    if nb_plugin_blocks_overlay "${live_prefix:-$prefix}"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_PLUGIN_BLOCK]}" "$name")${COLOR_RESET}"
        return 3
    fi

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
    # old_address and orig_note are taken once per cycle (§8.2 step 8): a
    # resumed run would read back a note that already carries the marker.
    # Only a new record or a finished rollback takes a fresh snapshot.
    local snap_fresh=0
    case "$(nb_node_get "$uuid" state 2>/dev/null)" in ""|rolled_back) snap_fresh=1 ;; esac
    nb_node_set "$uuid" uuid "$uuid"
    nb_node_set "$uuid" name "$name"
    # The live address was proven non-overlay above (prefix + live wt0), so a
    # resumed run refreshes it too: a public IP rotated between the attempts
    # must not leave a dead one for the rollback and break-glass.
    local prev_old
    prev_old=$(nb_node_get "$uuid" old_address)
    if [ "$snap_fresh" = 1 ] || [ -z "$prev_old" ] || ! nb_cidr_holds "$address" "100.64.0.0/10"; then
        [ -n "$prev_old" ] && [ "$prev_old" != "$address" ] \
            && nb_audit "old_address refreshed uuid=$uuid ${prev_old} -> ${address}"
        nb_node_set "$uuid" old_address "$address"
    fi
    if [ "$snap_fresh" = 1 ] || ! jq -e 'has("orig_note")' "$(nb_node_file "$uuid")" >/dev/null 2>&1; then
        nb_node_set "$uuid" orig_note "$(nb_note_strip "$note")"
    fi
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

    # A client that is already connected answers `up` with "Already
    # connected" and applies neither the flag contract nor the hostname.
    # Read after lazy-off: its reconfigure restarts an idle daemon, which
    # then auto-connects on its stored profile. Only our own earlier run
    # (same overlay in the record) passes as is; anything else needs an
    # explicit yes for down + up with our key.
    local nb_st nb_st_url nb_st_ip reup=""
    nb_st=$(re_run_host_n "$pub" 'timeout 15 netbird status --json 2>/dev/null' 2>/dev/null)
    if printf '%s' "$nb_st" | jq -e '.management.connected == true or .daemonStatus == "Connected"' >/dev/null 2>&1; then
        nb_st_url=$(printf '%s' "$nb_st" | jq -r '.management.url // "?"' 2>/dev/null)
        nb_st_ip=$(printf '%s' "$nb_st" | jq -r '.netbirdIp // "?"' 2>/dev/null)
        nb_st_ip=${nb_st_ip%/*}
        if [ "$nb_st_ip" != "$(nb_node_get "$uuid" overlay)" ]; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_NB_PRESENT]}" "$name" "$nb_st_url" "$nb_st_ip")${COLOR_RESET}"
            if ! reading_yn "${LANG[NB_MG_NB_REUP_ASK]}" mg_reup; then
                nb_node_state "$uuid" nb_up_failed
                nb_journal "$uuid" nb_up blocked
                return 3
            fi
            reup=down
        fi
    fi

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
    # A re-registered client keeps the management URL of its stored profile
    # unless one is given: name the cloud explicitly when the panel is there.
    local up_mgmt
    up_mgmt=$(nb_mgmt_for_remote)
    if [ "$reup" = down ] && [ -z "$up_mgmt" ] && [ "$(nb_nb_api_base 2>/dev/null)" = "$NB_NB_API_BASE" ]; then
        up_mgmt="https://api.netbird.io:443"
    fi
    up_out=$(printf '%s\n' "$key" | re_run_host "$pub" "$(nb_up_script "$(nb_node_hostname "$name" "$uuid")" "$up_mgmt" "$reup")")
    unset key
    [ -n "$kid" ] && { nb_revoke_setup_key "$kid"; nb_audit "one-off key revoked (node $name)"; }
    ov=$(printf '%s\n' "$up_out" | sed -n 's/^RRP_OVERLAY=//p' | tail -n1)
    if ! nb_is_ipv4 "$ov"; then
        echo -e "${COLOR_RED}${LANG[NB_MG_UP_FAIL]}${COLOR_RESET}"
        nb_node_state "$uuid" nb_up_failed
        nb_journal "$uuid" nb_up failed
        return 4
    fi
    # The key is ignored for a peer the management already knows (lookup by
    # WireGuard key), and a stored profile keeps its own management URL: the
    # node may sit in another account. The overlay must be in ours.
    local want_prefix="${live_prefix:-$prefix}"
    if [ -n "$want_prefix" ] && ! nb_cidr_holds "$ov" "$want_prefix"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_MG_NB_FOREIGN]}" "$name" "$ov" "$want_prefix")${COLOR_RESET}"
        nb_node_state "$uuid" nb_up_failed
        nb_journal "$uuid" nb_up foreign
        return 4
    fi
    # "Already connected" slipped past the status check (the daemon was
    # still connecting): nothing was applied — stop, the next run asks.
    if [ -z "$reup" ] && printf '%s\n' "$up_out" | grep -qx 'RRP_ALREADY=1' \
       && [ "$ov" != "$(nb_node_get "$uuid" overlay)" ]; then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_NB_PRESENT]}" "$name" "$(nb_mgmt_for_remote)" "$ov")${COLOR_RESET}"
        nb_node_state "$uuid" nb_up_failed
        nb_journal "$uuid" nb_up already_connected
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
        # Identity goes straight to the overlay IP under the public host's
        # pinned key (re_run_host_n "$ov" resolves the alias and connects to
        # the PUBLIC host — it compared the node with itself). Policies may
        # open only 2222 on the overlay: then the node's own wt0, read over
        # the public path, must hold the overlay IP.
        local mid2 hk_alias="$t_host" id_bad=0
        [ "$t_port" = "22" ] || hk_alias="[${t_host}]:${t_port}"
        mid2=$(ssh -n -i "$t_key" -p "$t_port" -o BatchMode=yes -o ConnectTimeout=8 \
            -o StrictHostKeyChecking=yes -o HostKeyAlias="$hk_alias" \
            -o UserKnownHostsFile="$RE_KNOWN_HOSTS" -o IdentitiesOnly=yes \
            "$t_user@$ov" 'cat /etc/machine-id' 2>/dev/null | tr -d '[:space:]')
        if [ -n "$mid2" ]; then
            [ -n "$mid" ] && [ "$mid2" != "$mid" ] && id_bad=1
        elif ! re_run_host_n "$pub" "ip -4 -o addr show dev ${NB_IFACE} 2>/dev/null" 2>/dev/null \
                | awk '{split($4, p, "/"); print p[1]}' | grep -qxF "$ov"; then
            id_bad=1
        fi
        if [ "$id_bad" = 1 ]; then
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
    # All three carry the state's once-taken old_address, never the live
    # one of a resumed run.
    local keep_addr
    keep_addr=$(nb_node_get "$uuid" old_address)
    [ -n "$keep_addr" ] || keep_addr="$address"
    printf '%s\n' "$keep_addr" | re_run_host "$pub" \
        'mkdir -p /opt/remnanode 2>/dev/null; cat > /opt/remnanode/.rrp-netbird; chmod 600 /opt/remnanode/.rrp-netbird 2>/dev/null' >/dev/null 2>&1
    nb_patch_note "$token" "$uuid" "$(nb_note_with_marker "$note" "$keep_addr")" \
        || echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_NOTE_FAIL]}" "$name")${COLOR_RESET}"

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
    # Imported nodes never had their note snapshotted (nor a marker written):
    # without an orig_note field the live note is left alone, not blanked.
    local orig
    if jq -e 'has("orig_note")' "$(nb_node_file "$uuid")" >/dev/null 2>&1; then
        orig=$(nb_node_get "$uuid" orig_note)
        nb_patch_note "$token" "$uuid" "$(nb_note_strip "${orig:-}")" \
            || echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_MG_NOTE_RESTORE_FAIL]}" "$(nb_node_get "$uuid" name)")${COLOR_RESET}"
    fi

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
    local token f uuid ok=0 fail=0 list="" nodes_json prefix live
    nb_load_api || { echo -e "${COLOR_RED}${LANG[NB_ERR_API]}${COLOR_RESET}"; return 1; }
    token=$(cat "${DIR_REMNAWAVE}token")

    # The live address is the fact: any recorded node whose panel address
    # sits inside the overlay prefix goes back (imported ones included),
    # and a failed rollback stays on the list whatever the answer.
    local api_ok=1
    nodes_json=$(nb_api_nodes "$token")
    printf '%s' "$nodes_json" | jq -e '.response | type == "array"' >/dev/null 2>&1 || {
        api_ok=0
        echo -e "${COLOR_YELLOW}${LANG[NB_ERR_API]}${COLOR_RESET}"
    }
    prefix=$(nb_state_get network_cidr)
    [ -n "$prefix" ] || prefix=$(nb_overlay_prefix)
    for f in "$NB_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        uuid=$(jq -r '.uuid // empty' "$f" 2>/dev/null)
        [ -n "$uuid" ] || continue
        live=$(nb_node_obj "$nodes_json" "$uuid" | jq -r '.address // empty' 2>/dev/null)
        if [ -n "$live" ] && [ -n "$prefix" ] && nb_cidr_holds "$live" "$prefix"; then
            list="$list $uuid"
            continue
        fi
        case "$(jq -r '.state // empty' "$f" 2>/dev/null)" in
            patched|connected|done|public_closed|aborted_at_*|path_failed|alias|rollback_failed) list="$list $uuid" ;;
            imported)
                # Without a live answer an imported node is taken by its
                # recorded overlay (import only records in-prefix ones).
                live=$(jq -r '.overlay // empty' "$f" 2>/dev/null)
                if [ "$api_ok" = 0 ] && [ -n "$live" ] && [ -n "$prefix" ] && nb_cidr_holds "$live" "$prefix"; then
                    list="$list $uuid"
                fi
                ;;
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

    # The list is taken whole first and walked from an array: the public-host
    # prompt inside the loop must read the terminal, not the jq stream. Tabs
    # keep node names with spaces in one field.
    local rows=() row self_ov
    mapfile -t rows < <(echo "$nodes_json" | jq -r '.response[]? | [.uuid, .name, .address] | @tsv' 2>/dev/null)
    self_ov=$(nb_wt0_ip)
    for row in "${rows[@]}"; do
        IFS=$'\t' read -r uuid name address <<< "$row"
        [ -n "$uuid" ] || continue
        # Only nodes already on the overlay are a manual scheme (§8.4); the
        # local node and the panel's own overlay address are not.
        [ "$address" = "172.30.0.1" ] && continue
        [ -n "$self_ov" ] && [ "$address" = "$self_ov" ] && continue
        nb_cidr_holds "$address" "$prefix" || continue
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
    done

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
# Diagnostics — local client health + overlay/panel drift
# ---------------------------------------------------------------------------

nb_diag() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_DIAG_TITLE]}${COLOR_RESET}"
    echo -e ""

    if ! nb_pkg_installed; then
        echo -e " ${COLOR_GRAY}${LANG[NB_DIAG_NO_CLIENT]}${COLOR_RESET}"
    else
        # State lives in flags; the words shown come from LANG only.
        local ver cidr mgmturl hold_ok=0 lazy_off=0 flags_bad=0
        ver=$(nb_client_version)
        nb_hold_on && hold_ok=1
        nb_lazy_off && lazy_off=1
        nb_profile_flags_bad && flags_bad=1
        cidr=$(nb_wt0_cidr); cidr=${cidr:--}
        mgmturl=$(nb_mgmt_url); mgmturl=${mgmturl:--}
        local w_hold="${LANG[NB_NO]}" w_lazy="${LANG[NB_LAZY_ON_STATE]}" w_flags="${LANG[NB_FLAGS_OK_STATE]}"
        [ "$hold_ok" = 1 ] && w_hold="${LANG[NB_YES]}"
        [ "$lazy_off" = 1 ] && w_lazy="${LANG[NB_LAZY_OFF_STATE]}"
        [ "$flags_bad" = 1 ] && w_flags="${LANG[NB_FLAGS_BAD_STATE]}"
        echo -e " $(printf "${LANG[NB_DIAG_CLIENT]}" "$ver" "$w_hold" "$w_lazy" "$w_flags")"
        echo -e " $(printf "${LANG[NB_DIAG_ADDR]}" "${COLOR_WHITE}${cidr}${COLOR_RESET}" "${COLOR_WHITE}${mgmturl}${COLOR_RESET}")"
        [ "$flags_bad" = 1 ] && echo -e " ${COLOR_YELLOW}${LANG[NB_DIAG_FLAGS_BAD]}${COLOR_RESET}"
        [ "$hold_ok" = 0 ] && echo -e " ${COLOR_YELLOW}${LANG[NB_DIAG_NO_HOLD]}${COLOR_RESET}"
        [ "$lazy_off" = 0 ] && echo -e " ${COLOR_YELLOW}${LANG[NB_DIAG_LAZY_ON]}${COLOR_RESET}"
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

    # One node list for the whole pass, and only a valid answer counts: an
    # unreachable API used to report every node as deleted from the panel.
    local f uuid live_obj live_addr st ov nodes_json
    nodes_json=$(nb_api_nodes "$token")
    if ! printf '%s' "$nodes_json" | jq -e '.response | type == "array"' >/dev/null 2>&1; then
        echo -e " ${COLOR_YELLOW}${LANG[NB_ERR_API]}${COLOR_RESET}"
        return 0
    fi
    for f in "$NB_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        uuid=$(jq -r '.uuid // empty' "$f" 2>/dev/null)
        [ -n "$uuid" ] || continue
        st=$(jq -r '.state // empty' "$f" 2>/dev/null)
        ov=$(jq -r '.overlay // empty' "$f" 2>/dev/null)
        live_obj=$(nb_node_obj "$nodes_json" "$uuid")
        live_addr=$(echo "$live_obj" | jq -r '.address // empty' 2>/dev/null)
        if [ -z "$live_addr" ]; then
            echo -e " ${COLOR_YELLOW}$(printf "${LANG[NB_DIAG_GONE]}" "$(jq -r --arg u "$uuid" '.name // $u' "$f" 2>/dev/null)")${COLOR_RESET}"
            continue
        fi
        if [ -n "$ov" ] && [ "$live_addr" != "$ov" ] && [ "$st" != "rolled_back" ]; then
            echo -e " ${COLOR_YELLOW}$(printf "${LANG[NB_DIAG_DRIFT]}" "$(jq -r '.name // "?"' "$f" 2>/dev/null)" "$ov" "$live_addr")${COLOR_RESET}"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Flags window: down + up with the mandatory set, detached
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
# Canary update — this machine only in the basic stage
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
# Disable — ordered, with guards
# ---------------------------------------------------------------------------

# "No node still rides the overlay" guard of disable/purge. Fail-closed:
# the live panel list is the fact; without a valid answer the local records
# decide, and an empty local list still needs the typed hostname.
nb_overlay_nodes_guard() {
    local token="" prefix resp addr f count=0 local_n=0 confirm_hn
    nb_load_api 2>/dev/null || true
    [ -s "${DIR_REMNAWAVE}token" ] && token=$(cat "${DIR_REMNAWAVE}token")
    prefix=$(nb_state_get network_cidr)
    [ -n "$prefix" ] || prefix=$(nb_overlay_prefix)
    # No recorded prefix and wt0 already down: the whole NetBird range still
    # lets a valid API answer decide instead of the local records alone.
    [ -n "$prefix" ] || prefix="100.64.0.0/10"
    [ -n "$token" ] && resp=$(nb_api_nodes "$token")
    if [ -n "$prefix" ] && printf '%s' "$resp" | jq -e '.response | type == "array"' >/dev/null 2>&1; then
        while read -r addr; do
            nb_cidr_holds "$addr" "$prefix" && count=$((count + 1))
        done < <(printf '%s' "$resp" | jq -r '.response[]?.address // empty' 2>/dev/null)
        if [ "$count" -gt 0 ]; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_OFF_NODES_LEFT]}" "$count")${COLOR_RESET}"
            return 1
        fi
        return 0
    fi
    for f in "$NB_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        case "$(jq -r '.state // empty' "$f" 2>/dev/null)" in
            connected|patched|imported|rollback_failed|done|aborted_at_wait|aborted_at_patched) local_n=$((local_n + 1)) ;;
        esac
    done
    echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_OFF_API_UNKNOWN]}" "$local_n")${COLOR_RESET}"
    if [ "$local_n" -gt 0 ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_OFF_NODES_LEFT]}" "$local_n")${COLOR_RESET}"
        return 1
    fi
    reading "${LANG[NB_OFF_LOCAL_CONFIRM]}" confirm_hn || return 1
    [ "$confirm_hn" = "$(hostname -s)" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_OFF_LOCAL_MISMATCH]}${COLOR_RESET}"; return 1; }
    return 0
}

nb_disable() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_OFF_TITLE]}${COLOR_RESET}"
    echo -e ""

    if panel_is_installed; then
        # The sub and the checker reach the panel through the overlay this
        # very command would take down — their reverts must come first.
        if [ -s "$NB_DIR/sub.json" ]; then
            echo -e "${COLOR_RED}${LANG[NB_PURGE_SUB_LEFT]}${COLOR_RESET}"
            return 1
        fi
        if [ -s "$NB_DIR/checker.json" ]; then
            echo -e "${COLOR_RED}${LANG[NB_PURGE_CHK_LEFT]}${COLOR_RESET}"
            return 1
        fi
        nb_overlay_nodes_guard || return 1
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
command -v netbird >/dev/null 2>&1 && exit 1
# The deb has no postrm: profiles (WireGuard key, ManagementURL) and
# service.json stay in the state dir and a later join would reuse them.
rm -rf /etc/netbird /var/lib/netbird 2>/dev/null
[ -e /var/lib/netbird ] && exit 1
exit 0'
}

# Delete one account peer by id; echoes 1 when it went, 0 otherwise. Never
# by name: hostnames like "debian" repeat across unrelated machines.
nb_peer_delete_id() {
    if [ -n "$1" ] && nb_nb_api DELETE "/api/peers/$1" >/dev/null 2>&1; then
        echo 1
    else
        echo 0
    fi
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
        nb_overlay_nodes_guard || return 1
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
    local sweep=() sf host name pid ov sweep_go=n swept_names="" failed="" swept_peers=()
    while IFS= read -r sf; do
        [ -f "$sf" ] || continue
        host=$(jq -r '.public_host // empty' "$sf" 2>/dev/null)
        name=$(jq -r '.name // empty' "$sf" 2>/dev/null)
        pid=$(jq -r '.peer_id // empty' "$sf" 2>/dev/null)
        ov=$(jq -r '.overlay // empty' "$sf" 2>/dev/null)
        [ -n "$host" ] && sweep+=("$host|$pid|$ov|${name:-}")
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
            IFS='|' read -r host pid ov name <<< "$entry"
            step_do "$(printf "${LANG[NB_PURGE_REMOTE_STEP]}" "$host")"
            if nb_remote_netbird_uninstall "$host"; then
                step_ok "${LANG[NB_PURGE_REMOTE_OK]}"
                [ -n "$name" ] && swept_names="$swept_names $name"
                swept_peers+=("$pid|$ov")
            else
                echo -e "${COLOR_RED}$(printf "${LANG[NB_PURGE_REMOTE_FAIL]}" "$host")${COLOR_RESET}"
                failed="$failed $host"
            fi
        done
    fi

    # This machine's peer is found by its overlay IP (unique in the account),
    # so the IP is taken while wt0 still exists.
    local self_ip
    self_ip=$(nb_wt0_ip)
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
        [ -n "$self_ip" ] && gone=$((gone + $(nb_peer_delete_id "$(nb_peer_id_by_ip "$self_ip")")))
        for rn in "${swept_peers[@]}"; do
            IFS='|' read -r pid ov <<< "$rn"
            # The live IP lookup wins over a stored id a re-registration
            # may have made stale.
            [ -n "$ov" ] && pid=$(nb_peer_id_by_ip "$ov" || printf '%s' "$pid")
            gone=$((gone + $(nb_peer_delete_id "$pid")))
        done
        [ "$gone" -gt 0 ] && echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_PURGE_PEER_GONE]}" "$gone")${COLOR_RESET}"
    fi

    # A Default the module switched off comes back before its saved body
    # goes with the state dir (§8.11); without the token the body is kept
    # outside the dir for a manual restore.
    local def_file="${NB_DIR}/default_policy.json" def_done=0 def_live
    if [ -s "$def_file" ]; then
        if nb_pat_stored; then
            def_live=$(nb_default_policy)
            if [ -n "$def_live" ] && [ "$(printf '%s' "$def_live" | jq -r .enabled 2>/dev/null)" = "true" ]; then
                def_done=1
            elif [ -n "$def_live" ] && nb_default_restore; then
                def_done=1
                nb_audit "purge: default policy restored"
                echo -e " ${COLOR_GREEN}${LANG[NB_POL_DEFAULT_RESTORED]}${COLOR_RESET}"
            fi
        fi
    fi

    step_do "${LANG[NB_PURGE_STEP_PKG]}"
    apt-mark unhold netbird >/dev/null 2>&1
    if ! apt-get -o DPkg::Lock::Timeout=300 purge -y netbird >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[NB_PURGE_PKG_FAIL]}${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[NB_PURGE_STEP_PKG_OK]}"
    # No postrm in the deb: the client state (WireGuard key, profile with
    # the old ManagementURL) is wiped by hand, or a fresh join reuses it.
    rm -rf /etc/netbird /var/lib/netbird 2>/dev/null

    step_do "${LANG[NB_PURGE_STEP_STATE]}"
    if [ -s "$def_file" ] && [ "$def_done" != 1 ]; then
        local def_keep
        def_keep="/root/rrp-netbird-default_policy.$(date -u +%Y%m%d%H%M%S).json"
        (umask 077; cp -f "$def_file" "$def_keep") 2>/dev/null \
            && echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_PURGE_DEFAULT_KEPT]}" "$def_keep")${COLOR_RESET}"
    fi
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
    local method="$1" path="$2" data="${3:-}" pat out base
    pat=$(cat "$NB_PAT_FILE" 2>/dev/null)
    if [ -z "$pat" ]; then
        NB_NB_CODE="0"
        echo '{"message":"no PAT stored"}'
        return 1
    fi
    base=$(nb_nb_api_base) || {
        NB_NB_CODE="0"
        echo '{"message":"no usable management URL"}'
        return 1
    }
    if [ -n "$data" ]; then
        out=$(curl -s -m 20 -w '\n%{http_code}' -X "$method" \
            -H @<(printf 'Authorization: Token %s\nContent-Type: application/json\n' "$pat") \
            -d "$data" "$base$path" 2>/dev/null)
    else
        out=$(curl -s -m 20 -w '\n%{http_code}' -X "$method" \
            -H @<(printf 'Authorization: Token %s\n' "$pat") "$base$path" 2>/dev/null)
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

# Peer id of THIS machine. The wt0 IP is unique in the account and wins;
# the dns label (hostname at join) is not — a stale peer of a reinstalled
# panel or a foreign "debian" keeps the bare label while ours got name-X-Y —
# so it only counts when the IP is unknown and exactly one peer carries it.
nb_self_peer_id() {
    local ip peers
    # Only the wt0 IP identifies this machine: a DNS label is not unique
    # ("debian", a stale peer of a reinstalled panel) and would hand the
    # panel role to a stranger. No IP yet → no peer; nb_join binds after up.
    ip=$(nb_wt0_ip)
    [ -n "$ip" ] || return 1
    peers=$(nb_nb_api GET /api/peers) || return 1
    printf '%s' "$peers" | jq -r --arg ip "$ip" \
        '[.[]? | select(((.ip // "") | (split("/") | .[0])) == $ip) | .id][0] // empty' 2>/dev/null | grep .
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
# GET answers peers as {id,name} objects while PUT takes plain id strings
# (same trap as policies): normalise to ids, and carry resources back as
# {id,type} — a PUT without them would empty the group's resources.
NB_GROUP_PUT_JQ='{name: .name, peers: $ids}
    + (if (.resources // []) | length > 0 then {resources: [.resources[] | {id, type}]} else {} end)'

nb_group_add_peer() {
    local gid="$1" peer="$2" cur body rc
    cur=$(nb_nb_api GET "/api/groups/$gid")
    rc=$?
    [ "$rc" -ne 0 ] && return 1
    echo "$cur" | jq -e --arg p "$peer" '[(.peers // [])[] | (.id? // .)] | index($p) != null' >/dev/null 2>&1 && return 0
    body=$(echo "$cur" | jq -c --arg p "$peer" \
        "([(.peers // [])[] | (.id? // .)] + [\$p] | unique) as \$ids | ${NB_GROUP_PUT_JQ}") || return 1
    nb_nb_api PUT "/api/groups/$gid" "$body" >/dev/null
}

# Mirror of the add: drop a peer from the group's member list. Best-effort —
# a peer the account no longer knows is already "removed".
nb_group_remove_peer() {
    local gid="$1" peer="$2" cur body rc
    cur=$(nb_nb_api GET "/api/groups/$gid")
    rc=$?
    [ "$rc" -ne 0 ] && return 1
    echo "$cur" | jq -e --arg p "$peer" '[(.peers // [])[] | (.id? // .)] | index($p) != null' >/dev/null 2>&1 || return 0
    body=$(echo "$cur" | jq -c --arg p "$peer" \
        "([(.peers // [])[] | (.id? // .)] - [\$p]) as \$ids | ${NB_GROUP_PUT_JQ}") || return 1
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
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    local pat probe api_base
    # Where the PAT goes is settled before it is typed: no join yet or a
    # non-https management means no API mode, never a cloud default.
    api_base=$(nb_nb_api_base) || { echo -e "${COLOR_RED}${LANG[NB_SET_API_BASE_BAD]}${COLOR_RESET}"; return 1; }
    echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_API_BASE]}" "$api_base")${COLOR_RESET}"
    nb_read_hidden "${LANG[NB_SET_PAT_PROMPT]}" pat
    [ -n "$pat" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"; return 1; }
    nb_ensure_dirs
    # The candidate lives in a temp file until the explicit yes: a failed
    # re-activation or a "no" must leave a working stored PAT untouched,
    # and ^C (nb_on_abort) removes the candidate. nb_nb_api reads the
    # global path, so it is shadowed here for the checks.
    local pat_final="$NB_PAT_FILE"
    NB_PAT_TMP="${NB_PAT_FILE}.new.$$"
    (umask 077; printf '%s' "$pat" > "$NB_PAT_TMP") || { NB_PAT_TMP=""; return 1; }
    unset pat
    local NB_PAT_FILE="$NB_PAT_TMP"

    step_do "${LANG[NB_SET_PAT_CHECK]}"
    probe=$(nb_nb_api GET /api/peers)
    if [ $? -ne 0 ]; then
        rm -f "$NB_PAT_TMP"; NB_PAT_TMP=""
        echo -e "${COLOR_RED}${LANG[NB_SET_PAT_BAD]}: $(echo "$probe" | jq -r '.message // ""' 2>/dev/null)${COLOR_RESET}"
        return 1
    fi
    # Role gate (§8.8): a non-admin PAT can read peers, so the probe alone
    # would pass and the flow would die later at group creation with a
    # generic error. Reject only on POSITIVE evidence of a foreign role —
    # an unreachable users/current must not lock out a working admin PAT.
    # The account owner holds every admin right and more.
    local cur_role
    cur_role=$(nb_nb_api GET /api/users/current | jq -r '.role // empty' 2>/dev/null)
    case "$cur_role" in
        ""|admin|owner) ;;
        *)
            rm -f "$NB_PAT_TMP"; NB_PAT_TMP=""
            echo -e "${COLOR_RED}${LANG[NB_SET_PAT_BAD]} (role: ${cur_role})${COLOR_RESET}"
            return 1
            ;;
    esac
    step_ok "${LANG[NB_SET_PAT_OK]}"

    step_do "${LANG[NB_POL_STEP_GROUPS]}"
    if ! nb_ensure_core_objects; then
        rm -f "$NB_PAT_TMP"; NB_PAT_TMP=""
        echo -e "${COLOR_RED}${LANG[NB_POL_GROUPS_FAIL]}${COLOR_RESET}"
        return 1
    fi
    step_ok "${LANG[NB_POL_GROUPS_OK]}"

    if reading_yn "${LANG[NB_SET_PAT_STORE_ASK]}" store_pat; then
        if ! mv -f "$NB_PAT_TMP" "$pat_final"; then
            rm -f "$NB_PAT_TMP"; NB_PAT_TMP=""
            return 1
        fi
        NB_PAT_TMP=""
        chmod 600 "$pat_final" 2>/dev/null
        nb_state_set pat_set_at "$(date -u +%F)"
    else
        rm -f "$NB_PAT_TMP"; NB_PAT_TMP=""
        echo -e "${COLOR_YELLOW}${LANG[NB_SET_PAT_KEPT]}${COLOR_RESET}"
        return 1
    fi
    nb_state_set mode api
    nb_audit "api-mode activated groups+policy ensured"
    echo -e "${COLOR_GREEN}${LANG[NB_SET_DONE]}${COLOR_RESET}"
    return 0
}

# Before Default goes off, every overlay member the module knows must sit
# in a module group: nodes (migrated in any mode or imported), the sub and
# the checker with their policies to the listener. Pre-registered peers never
# pick up a key's auto_groups, and basic-mode runs bind nothing at all.
nb_pol_bind_all() {
    local f ov pid bad=0 role port gid pol
    for f in "$NB_NODES_DIR"/*.json; do
        [ -f "$f" ] || continue
        case "$(jq -r '.state // empty' "$f" 2>/dev/null)" in connected|done|imported|patched|aborted_at_wait|aborted_at_patched|rollback_failed) ;; *) continue ;; esac
        ov=$(jq -r '.overlay // empty' "$f" 2>/dev/null)
        [ -n "$ov" ] || continue
        pid=$(nb_peer_id_by_ip "$ov")
        if [ -n "$pid" ] && nb_group_add_peer "$(nb_state_get grp_nodes)" "$pid"; then
            nb_node_set "$(jq -r '.uuid // empty' "$f" 2>/dev/null)" peer_id "$pid"
        else
            echo -e "${COLOR_RED}$(printf "${LANG[NB_POL_BIND_FAIL]}" "$(jq -r '.name // "?"' "$f" 2>/dev/null)" "$ov")${COLOR_RESET}"
            bad=1
        fi
    done
    for role in sub checker; do
        [ -s "$NB_DIR/${role}.json" ] || continue
        ov=$(jq -r '.overlay // empty' "$NB_DIR/${role}.json" 2>/dev/null)
        port=$(jq -r '.port // empty' "$NB_DIR/${role}.json" 2>/dev/null)
        gid=""; pol=""; pid=""
        if [ -n "$ov" ] && [ -n "$port" ]; then
            gid=$(nb_group_ensure "$(nb_group_name "$role")")
        fi
        if [ -n "$gid" ]; then
            nb_state_set "grp_${role}" "$gid"
            pol=$(nb_policy_ensure "$(nb_group_name "${role}2panel")" "$gid" "$(nb_state_get grp_panel)" "$port")
            pid=$(nb_peer_id_by_ip "$ov")
        fi
        if [ -z "$pol" ] || [ -z "$pid" ] || ! nb_group_add_peer "$gid" "$pid"; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_POL_BIND_FAIL]}" "$role" "${ov:--}")${COLOR_RESET}"
            bad=1
        fi
    done
    return $bad
}

# Sub/checker reachability of the listener from their own boxes: the panel
# side check proves nothing about the sub2panel/checker2panel direction.
nb_pol_svc_check() {
    local role h port panel_ov bad=0
    panel_ov=$(nb_wt0_ip)
    for role in sub checker; do
        [ -s "$NB_DIR/${role}.json" ] || continue
        h=$(jq -r '.host // empty' "$NB_DIR/${role}.json" 2>/dev/null)
        port=$(jq -r '.port // empty' "$NB_DIR/${role}.json" 2>/dev/null)
        if ! nb_is_ipv4 "$panel_ov" || ! [[ "$port" =~ ^[0-9]+$ ]] || [ -z "$h" ] || ! nb_need_re            || ! re_run_host_n "$h" "timeout 5 bash -c '</dev/tcp/${panel_ov}/${port}'" >/dev/null 2>&1; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_POL_SVC_FAIL]}" "${role} (${h:-?})" "${port:-?}")${COLOR_RESET}"
            bad=1
        fi
    done
    return $bad
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

    local bind_ok=1
    nb_pol_bind_all || bind_ok=0

    # Foreign peers: registered but in none of our groups — with Default off
    # they lose connectivity; say so before the switch.
    local fgn=0 p gids
    gids="$(nb_state_get grp_panel) $(nb_state_get grp_nodes) $(nb_state_get grp_sub) $(nb_state_get grp_checker)"
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
            case "$(jq -r '.state // empty' "$f" 2>/dev/null)" in connected|done|imported|patched|aborted_at_wait|aborted_at_patched|rollback_failed) ;; *) continue ;; esac
            ov=$(jq -r '.overlay // empty' "$f" 2>/dev/null)
            [ -n "$ov" ] || continue
            nb_path_check "$ov" || { echo -e "${COLOR_RED}$(printf "${LANG[NB_POL_PATH_FAIL]}" "$(jq -r '.name // "?"' "$f")")${COLOR_RESET}"; bad=1; }
        done
        nb_pol_svc_check || bad=1
        return $bad
    }

    local d state
    d=$(nb_default_policy)
    if [ -n "$d" ] && [ "$(echo "$d" | jq -r .enabled)" = "true" ]; then
        step_do "${LANG[NB_POL_STEP_PATH]}"
        if [ "$bind_ok" != 1 ] || ! nb_pol_pathcheck_all; then
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
            nb_pol_pathcheck_all || dead=1
            if [ "$dead" = 1 ]; then
                # The restore is the only way back for the stranded paths:
                # a few tries, and a failure is said out loud, never as a
                # success.
                local try restored=0
                for try in 1 2 3; do
                    nb_default_restore && { restored=1; break; }
                    sleep 3
                done
                if [ "$restored" = 1 ]; then
                    nb_audit "default policy auto-restored"
                    echo -e "${COLOR_RED}${LANG[NB_POL_AUTO_RESTORE]}${COLOR_RESET}"
                else
                    nb_audit "default policy auto-restore FAILED"
                    echo -e "${COLOR_RED}$(printf "${LANG[NB_POL_AUTO_RESTORE_FAIL]}" "${NB_DIR}/default_policy.json")${COLOR_RESET}"
                fi
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
    local pick last opt_forget opt_rot
    while true; do
        last=1
        opt_forget=99
        opt_rot=99
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[NB_SET_TITLE]}${COLOR_RESET}"
        echo -e ""
        local mode_disp pat_at
        mode_disp="${LANG[NB_MODE_BASIC]}"
        [ "$(nb_state_get mode)" = "api" ] && mode_disp="API"
        echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_MODE]}" "$mode_disp")${COLOR_RESET}"
        if nb_pat_stored; then
            pat_at=$(nb_state_get pat_set_at)
            echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_PAT_PRESENT]}" "${pat_at:-${LANG[NB_NO]}}")${COLOR_RESET}"
            echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_API_BASE]}" "$(nb_nb_api_base || printf '%s' '-')")${COLOR_RESET}"
        else
            echo -e " ${COLOR_GRAY}${LANG[NB_SET_PAT_ABSENT]}${COLOR_RESET}"
            echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SET_API_BASE]}" "$(nb_nb_api_base || printf '%s' '-')")${COLOR_RESET}"
        fi
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[NB_SET_ACTIVATE]}${COLOR_RESET}"
        if nb_pat_stored; then
            last=$((last + 1)); opt_forget=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_SET_FORGET]}${COLOR_RESET}"
        fi
        # The rotation talks to the panel API and SSH only — a sub moved in
        # the basic mode needs it just as much, PAT or not.
        if [ -s "$NB_DIR/sub.json" ]; then
            last=$((last + 1)); opt_rot=$last
            echo -e "${COLOR_YELLOW}${last}. ${LANG[NB_SET_ROTATE]}${COLOR_RESET}"
        fi
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" pick || return 0
        if [ "$pick" = "1" ]; then
            nb_activate_api
        elif [ "$pick" = "$opt_forget" ] && [ "$opt_forget" != 99 ]; then
            rm -f "$NB_PAT_FILE"; nb_state_set mode basic; nb_audit "pat forgotten"
            echo -e "${COLOR_GREEN}${LANG[NB_SET_FORGOTTEN]}${COLOR_RESET}"
        elif [ "$pick" = "$opt_rot" ] && [ "$opt_rot" != 99 ]; then
            nb_sub_rotate
        elif [ "$pick" = "0" ]; then
            return 0
        else
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
        fi
    done
}

# ---------------------------------------------------------------------------
# Subscription page over overlay: a listener on the panel's host
# network proxy + a small allowlist by overlay IP. Nothing is ever bound to
# the overlay IP itself and no Docker port is published on it (moby#39559).
# ---------------------------------------------------------------------------

NB_SUB_MARK_BEGIN="# BEGIN rrp-netbird"
NB_SUB_MARK_END="# END rrp-netbird"
# The subscription server's public path crosses the panel's hidden-cookie
# gate; the current pair lives in the panel's nginx map. Overridable so the
# harness can point it at a fixture.
NB_PANEL_NGINX_CONF="${NB_PANEL_NGINX_CONF:-/opt/remnawave/nginx.conf}"

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
                | grep -oE 'listen [0-9]+|^:[0-9]+' | grep -oE '[0-9]+' | head -n1)
            # (one grep for both dialects: two greps chained with || share
            # one stdin, the first drained it and Caddy's ":PORT {" was never
            # seen — the listener crept to the next port on every apply)
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
# /api/sub/ it fetches (its UI lists every proxy, it gets nothing
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
# Same scopes as the nginx block: the union gets /api/sub/, the sub alone
# the four subscription-page prefixes, everything else is dropped. An empty
# allowlist is a valid block (the first migration writes the listener before
# the sub.json/checker.json it would allow).
nb_listener_block_caddy() {
    local port="$1" allow sub_ips chk_ips sub_all="" m
    sub_ips=$(nb_listener_allows_sub)
    chk_ips=$(nb_listener_allows_checker)
    for allow in $sub_ips $chk_ips; do
        case " $sub_all " in *" $allow "*) continue ;; esac
        sub_all="$sub_all $allow"
    done
    sub_all=$(printf '%s' "$sub_all" | sed 's/^ //')
    sub_ips=$(printf '%s' "$sub_ips" | tr '\n' ' ' | sed 's/ *$//')
    {
        echo "$NB_SUB_MARK_BEGIN"
        echo ":$port {"
        echo "    bind 0.0.0.0"
        if [ -n "$sub_all" ]; then
            echo "    @rrp_sub {"
            echo "        remote_ip $sub_all"
            echo "        path /api/sub/*"
            echo "    }"
        fi
        if [ -n "$sub_ips" ]; then
            echo "    @rrp_page {"
            echo "        remote_ip $sub_ips"
            echo "        path /api/system/metadata /api/users/by-username/* /api/subscriptions/subpage-config/* /api/subscription-page-configs*"
            echo "    }"
        fi
        for m in rrp_sub rrp_page; do
            { [ "$m" = rrp_sub ] && [ -z "$sub_all" ]; } && continue
            { [ "$m" = rrp_page ] && [ -z "$sub_ips" ]; } && continue
            echo "    handle @$m {"
            echo "        reverse_proxy 127.0.0.1:3000 {"
            echo "            header_up X-Forwarded-Proto https"
            echo "            header_up -Cookie"
            echo "        }"
            echo "    }"
        done
        echo "    handle {"
        echo "        abort"
        echo "    }"
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

# Revoke every earlier subscription-page-rrp token and keep only the newest
# one (the token just minted and proven in the compose): a rotation that
# leaves the old, maybe leaked, 10-year token alive is no rotation. $1 is
# a credential allowed on /api/tokens (the admin JWT or the token that
# minted); prints nothing, audits the count.
nb_sub_revoke_old() {
    command -v make_api_request >/dev/null 2>&1 || load_api_module >/dev/null 2>&1 || true
    local auth="$1" resp u n=0
    [ -n "$auth" ] || return 1
    resp=$(make_api_request "GET" "http://127.0.0.1:3000/api/tokens" "$auth")
    echo "$resp" | jq -e '.response.tokens | type == "array"' >/dev/null 2>&1 || return 1
    for u in $(echo "$resp" | jq -r '[.response.tokens[] | select(.name == "subscription-page-rrp")]
            | sort_by(.createdAt) | .[:-1][] | .uuid' 2>/dev/null); do
        [[ "$u" =~ ^[0-9a-fA-F-]{36}$ ]] || continue
        make_api_request "DELETE" "http://127.0.0.1:3000/api/tokens/$u" "$auth" >/dev/null 2>&1 && n=$((n + 1))
    done
    nb_audit "sub old tokens revoked count=$n"
    return 0
}

# Rotate the subscription server's token to a fresh scoped one. Needs the
# superadmin login once (the API token cannot mint); the JWT is used in
# memory and discarded.
nb_sub_rotate() {
    local host panel_ov token jwt compose_new compose_old auth="" port
    [ -s "$NB_DIR/sub.json" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_ROT_NO_SUB]}${COLOR_RESET}"; return 1; }
    host=$(jq -r .host "$NB_DIR/sub.json")
    port=$(jq -r '.port // empty' "$NB_DIR/sub.json")
    [[ "$port" =~ ^[0-9]+$ ]] || { echo -e "${COLOR_YELLOW}${LANG[NB_ROT_NO_SUB]}${COLOR_RESET}"; return 1; }
    panel_ov=$(nb_wt0_ip)
    # Without wt0 the compose would get "http://:<port>".
    nb_is_ipv4 "$panel_ov" || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }

    step_do "${LANG[NB_ROT_MINT]}"
    token=$(nb_sub_mint_token)
    [ -n "$token" ] && auth=$(cat "${DIR_REMNAWAVE}token" 2>/dev/null)
    if [ -z "$token" ]; then
        local username password login_data login_response
        echo -e "${COLOR_YELLOW}${LANG[NB_ROT_LOGIN_HINT]}${COLOR_RESET}"
        reading "${LANG[NB_ROT_USERNAME]}" username || return 1
        [ -n "$username" ] || return 1
        nb_read_hidden "${LANG[NB_ROT_PASSWORD]}" password
        [ -n "$password" ] || return 1
        # The password never reaches an argv: jq builds the body from stdin
        # and curl reads it back from stdin.
        login_data=$(printf '%s\n%s\n' "$username" "$password" | jq -Rnc '{username: input, password: input}')
        unset password
        login_response=$(printf '%s' "$login_data" | curl -s --connect-timeout 10 --max-time 60 -X POST \
            -H @<(printf 'Content-Type: application/json\nX-Forwarded-For: 127.0.0.1\nX-Forwarded-Proto: https\nX-Remnawave-Client-Type: browser\n') \
            --data-binary @- "http://127.0.0.1:3000/api/auth/login")
        unset login_data
        jwt=$(echo "$login_response" | jq -r '.response.accessToken // .accessToken // empty')
        if [ -z "$jwt" ] || [ "$jwt" = "null" ]; then
            echo -e "${COLOR_RED}${LANG[NB_ROT_LOGIN_FAIL]}: $(echo "$login_response" | jq -r '.message // ""' 2>/dev/null)${COLOR_RESET}"
            return 1
        fi
        token=$(nb_sub_mint_token "$jwt")
        # The JWT outlives the mint only until the old tokens are revoked.
        auth="$jwt"
        unset jwt
        [ -n "$token" ] || { echo -e "${COLOR_RED}${LANG[NB_SUB_TOKEN_FAIL]}${COLOR_RESET}"; unset auth; return 1; }
    fi
    step_ok "${LANG[NB_ROT_MINT_OK]}"

    step_do "${LANG[NB_ROT_PUSH]}"
    compose_old=$(re_run_host_n "$host" 'cat /opt/subscription/docker-compose.yml 2>/dev/null')
    if [ -z "$compose_old" ]; then
        unset token
        echo -e "${COLOR_RED}${LANG[NB_SUB_NO_COMPOSE]}${COLOR_RESET}"
        return 3
    fi
    compose_new=$(printf '%s\n' "$compose_old" | nb_sub_rewrite_compose "http://${panel_ov}:${port}" "$token")
    if ! nb_sub_compose_applied "$compose_new" "http://${panel_ov}:${port}" "$token"; then
        unset token
        echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_COMPOSE_UNSUPPORTED]}" "$host")${COLOR_RESET}"
        return 3
    fi
    if ! printf '%s\n' "$compose_new" \
         | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.tmp && mv -f /opt/subscription/docker-compose.yml.tmp /opt/subscription/docker-compose.yml && chmod 600 /opt/subscription/docker-compose.yml' >/dev/null 2>&1; then
        unset token
        echo -e "${COLOR_RED}${LANG[NB_SUB_COMPOSE_FAIL]}${COLOR_RESET}"
        return 3
    fi
    unset compose_new
    re_run_host_n "$host" 'cd /opt/subscription && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1
    sleep 8
    # Proof = the container stays up AND the new token opens metadata over
    # the listener; otherwise the previous compose goes back.
    local rot_fail="" meta=""
    if ! re_run_host_n "$host" 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "remnawave-subscription-page Up"'; then
        rot_fail="${LANG[NB_SUB_CONTAINER_DOWN]}"
    else
        meta=$(nb_sub_meta_code "$host" "$panel_ov" "$port" "$token")
        [ "$meta" = "200" ] || rot_fail="$(printf "${LANG[NB_SUB_META_FAIL]}" "${meta:-no answer}")"
    fi
    unset token
    if [ -n "$rot_fail" ]; then
        echo -e "${COLOR_RED}${rot_fail}${COLOR_RESET}"
        if printf '%s\n' "$compose_old" \
             | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.tmp && mv -f /opt/subscription/docker-compose.yml.tmp /opt/subscription/docker-compose.yml && chmod 600 /opt/subscription/docker-compose.yml' >/dev/null 2>&1 \
           && re_run_host_n "$host" 'cd /opt/subscription && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1; then
            echo -e "${COLOR_YELLOW}${LANG[NB_ROT_RESTORED]}${COLOR_RESET}"
        else
            echo -e "${COLOR_RED}${LANG[NB_SUB_COMPOSE_FAIL]}${COLOR_RESET}"
        fi
        unset compose_old auth
        return 5
    fi
    unset compose_old
    nb_sub_revoke_old "$auth" || echo -e "${COLOR_YELLOW}${LANG[NB_ROT_REVOKE_FAIL]}${COLOR_RESET}"
    unset auth
    nb_audit "sub token rotated host=$host"
    step_ok "${LANG[NB_ROT_DONE]}"
    return 0
}

# Rewrite a subscription compose for the overlay path. Our own installer
# formats (nginx and caddy variants) plus the wiki manual one all carry the
# same variable lines, so the transform is line-based.
# The values ride in awk's environment, never in argv (a sed expression put
# the token on the panel's process list).
nb_sub_rewrite_compose() {
    NB_RW_URL="$1" NB_RW_TOK="$2" awk '
        function pfx(s) { if (match(s, /^[ \t]*- /)) return substr(s, 1, RLENGTH); return "" }
        /^([ \t]*- )?(EGAMES_COOKIE|CADDY_AUTH_API_TOKEN)=/ { next }
        /^([ \t]*- )?REMNAWAVE_PANEL_URL=/ { print pfx($0) "REMNAWAVE_PANEL_URL=" ENVIRON["NB_RW_URL"]; next }
        /^([ \t]*- )?REMNAWAVE_API_TOKEN=/ { print pfx($0) "REMNAWAVE_API_TOKEN=" ENVIRON["NB_RW_TOK"]; next }
        { print }'
}

# The subscription page's variables must sit in the compose itself as
# "VAR=" lines (list form); env_file/.env, quoted and map forms are not
# rewritten — say so instead of failing later on a misleading step.
nb_sub_compose_supported() {
    printf '%s\n' "$1" | grep -qE '^([[:space:]]*- )?REMNAWAVE_PANEL_URL=' \
        && printf '%s\n' "$1" | grep -qE '^([[:space:]]*- )?REMNAWAVE_API_TOKEN='
}

# The rewritten compose really carries the overlay URL and the token (a
# builtin match: the token never reaches a grep argv).
nb_sub_compose_applied() {
    local compose="$1" url="$2" token="$3"
    [[ $'\n'"$compose"$'\n' == *$'\n'*"REMNAWAVE_PANEL_URL=${url}"$'\n'* ]] \
        && [[ $'\n'"$compose"$'\n' == *$'\n'*"REMNAWAVE_API_TOKEN=${token}"$'\n'* ]]
}

# rc=0 when the compose's $2 variable already points at an http:// address
# inside the overlay range (the account prefix or NetBird's 100.64.0.0/10),
# whatever the panel's overlay IP is today.
nb_compose_rides_overlay() {
    local h prefix
    h=$(printf '%s\n' "$1" | sed -n "s|.*$2=http://\([0-9.]*\):.*|\1|p" | head -n1)
    nb_is_ipv4 "$h" || return 1
    prefix=$(nb_state_get network_cidr)
    [ -n "$prefix" ] || prefix=$(nb_overlay_prefix)
    { [ -n "$prefix" ] && nb_cidr_holds "$h" "$prefix"; } || nb_cidr_holds "$h" "100.64.0.0/10"
}

# Metadata through the listener from the sub box, authorized by $4; the
# header travels on stdin (curl -H @-), not in the remote argv.
nb_sub_meta_code() {
    local host="$1" panel_ov="$2" port="$3" token="$4"
    printf 'Authorization: Bearer %s\nX-Forwarded-For: 10.0.0.1\n' "$token" \
        | re_run_host "$host" "curl -s -o /dev/null -w '%{http_code}' -m 10 -H @- 'http://${panel_ov}:${port}/api/system/metadata'" 2>/dev/null
}

# Full §8.6 migration of one subscription server.
nb_sub_migrate() {
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }
    nb_mgmt_connected || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }
    local panel_ov
    panel_ov=$(nb_wt0_ip)
    nb_is_ipv4 "$panel_ov" || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }

    local host sub_ov key="" kid=""
    reading "${LANG[NB_SUB_HOST_PROMPT]}" host || return 1
    [ -n "$host" ] || return 1
    re_require_access_host "$host" || return 2

    # The compose form is checked before anything changes (listener, join,
    # sub.json): an unsupported one must not leave a record that blocks
    # disable/purge until a revert.
    local compose_pre
    compose_pre=$(re_run_host_n "$host" 'cat /opt/subscription/docker-compose.yml 2>/dev/null')
    if [ -z "$compose_pre" ] || ! printf '%s\n' "$compose_pre" | grep -q 'remnawave-subscription-page'; then
        echo -e "${COLOR_RED}${LANG[NB_SUB_NO_COMPOSE]}${COLOR_RESET}"
        return 3
    fi
    if ! nb_sub_compose_supported "$compose_pre"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_COMPOSE_UNSUPPORTED]}" "$host")${COLOR_RESET}"
        return 3
    fi
    unset compose_pre

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
        up_out=$(printf '%s\n' "$key" | re_run_host "$host" "$(nb_up_script "$host" "$(nb_mgmt_for_remote)")")
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
    if ! nb_sub_compose_supported "$compose_new"; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_COMPOSE_UNSUPPORTED]}" "$host")${COLOR_RESET}"
        return 3
    fi
    # Snapshot only a still-public compose: on a re-migrate the live file
    # already rides the overlay and the first-migration backup must survive
    # for the revert. A live public compose is the truth and refreshes the
    # snapshot (the stack may have been reinstalled since); "overlay" is
    # judged by the URL's address range, not by today's panel wt0 IP (a
    # re-registered panel has a new one).
    if ! printf '%s\n' "$compose_new" | grep -q "REMNAWAVE_PANEL_URL=http://${panel_ov}:" \
       && ! nb_compose_rides_overlay "$compose_new" REMNAWAVE_PANEL_URL; then
        printf '%s' "$compose_new" | base64 -w0 > "${NB_DIR}/sub.compose.b64"
        chmod 600 "${NB_DIR}/sub.compose.b64" 2>/dev/null
        printf '%s\n' "$compose_new" | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.rrpbak' >/dev/null 2>&1
    fi

    local minted=""
    token=$(nb_sub_mint_token)
    [ -n "$token" ] && minted=1
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
    # A compose the rewrite could not touch stays public: never announce it
    # as migrated.
    if ! nb_sub_compose_applied "$compose_new" "http://${panel_ov}:${port}" "$token"; then
        unset token
        echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_COMPOSE_UNSUPPORTED]}" "$host")${COLOR_RESET}"
        return 3
    fi

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
    meta=$(nb_sub_meta_code "$host" "$panel_ov" "$port" "$token")
    unset token
    if [ "$meta" != "200" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_META_FAIL]}" "${meta:-no answer}")${COLOR_RESET}"
        nb_sub_rollback "$host"
        return 5
    fi
    printf '{"host":"%s","overlay":"%s","port":"%s","state":"connected"}' "$host" "$sub_ov" "$port" > "$NB_DIR/sub.json"
    chmod 600 "$NB_DIR/sub.json" 2>/dev/null
    # A fresh token is live and proven: the earlier ones of the same name go.
    [ -n "$minted" ] && { nb_sub_revoke_old "$(cat "${DIR_REMNAWAVE}token" 2>/dev/null)" \
        || echo -e "${COLOR_YELLOW}${LANG[NB_ROT_REVOKE_FAIL]}${COLOR_RESET}"; }
    nb_audit "sub migrated host=$host overlay=$sub_ov port=$port"
    step_ok "${LANG[NB_SUB_DONE_STEP]}"
    echo -e "${COLOR_GREEN}$(printf "${LANG[NB_SUB_DONE]}" "$host" "$sub_ov")${COLOR_RESET}"
    return 0
}

nb_sub_rollback() {
    local host="$1" had
    step_do "${LANG[NB_SUB_ROLLBACK]}"
    # The record and the snapshot go only after the restore landed and the
    # stack came up: a failed write keeps them for the revert item.
    if [ -s "${NB_DIR}/sub.compose.b64" ]; then
        if ! base64 -d "${NB_DIR}/sub.compose.b64" \
               | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.tmp && mv -f /opt/subscription/docker-compose.yml.tmp /opt/subscription/docker-compose.yml' >/dev/null 2>&1 \
           || ! re_run_host_n "$host" 'cd /opt/subscription && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_ROLLBACK_FAIL]}" "$host")${COLOR_RESET}"
            nb_audit "sub rollback FAILED host=$host (record kept)"
            return 1
        fi
    fi
    rm -f "$NB_DIR/sub.json" "${NB_DIR}/sub.compose.b64"
    # Rebuild the listener only when another service still rides it; an
    # allowlist-less 444 block on the port is nobody's leftover.
    if [ -s "$NB_DIR/checker.json" ]; then
        nb_listener_apply >/dev/null 2>&1
    else
        nb_listener_remove
    fi
    nb_audit "sub rolled back host=$host"
    step_ok "${LANG[NB_SUB_ROLLBACK_OK]}"
    return 0
}

# Current hidden-cookie pair (<name>=<value>, both random per install) from
# the panel's nginx map ("~*name=value" 1;) or the Caddyfile matcher; empty
# when the panel runs without the gate.
nb_sub_cookie_current() {
    local pair
    pair=$(sed -n 's/.*"~\*\([A-Za-z0-9_-]*=[A-Za-z0-9_-]*\)".*/\1/p' "$NB_PANEL_NGINX_CONF" 2>/dev/null | head -n1)
    [ -n "$pair" ] || pair=$(sed -n 's/.*not header Cookie \*\([A-Za-z0-9_-]*=[A-Za-z0-9_-]*\)\*.*/\1/p' \
        /opt/remnawave/Caddyfile 2>/dev/null | head -n1)
    printf '%s' "$pair"
}

# Public metadata probe run ON the sub box against its restored compose:
# every credential the subscription page itself sends (Bearer token, gate
# cookie, X-Api-Key of TinyAuth/Caddy MFA) goes into a 600 header file,
# never into argv. Prints the HTTP code, or "skip" without URL/token.
nb_sub_public_probe_script() {
    cat <<'EOL'
f=/opt/subscription/docker-compose.yml
val() { grep -v '^[[:space:]]*#' "$f" 2>/dev/null | sed -n "s/.*$1=//p" | head -n1 | tr -d "\"'\r"; }
u=$(val REMNAWAVE_PANEL_URL)
t=$(val REMNAWAVE_API_TOKEN)
c=$(val EGAMES_COOKIE)
a=$(val CADDY_AUTH_API_TOKEN)
if [ -z "$u" ] || [ -z "$t" ]; then echo skip; exit 0; fi
h=$(umask 077; mktemp) || exit 1
trap 'rm -f "$h"' EXIT
{
    printf 'Authorization: Bearer %s\n' "$t"
    [ -n "$c" ] && printf 'Cookie: %s\n' "$c"
    [ -n "$a" ] && printf 'X-Api-Key: %s\n' "$a"
} > "$h"
curl -s -o /dev/null -w "%{http_code}" -m 15 -H @"$h" "$u/api/system/metadata"
EOL
}

# Revert: put the subscription page back on the panel's public path.
# Restores the pre-migration compose (state-dir snapshot first, the on-box
# .rrpbak twin second), proves the public path answers, then rebuilds or
# removes the listener and drops the state. A panel reinstall may have
# rotated the hidden-cookie gate since the migration — the restored compose
# gets the CURRENT value before the page goes up. The NetBird client on the
# sub box deliberately stays (full removal explains the manual cleanup); SSH
# rides the public host, so the revert works with the overlay down too.
nb_sub_revert() {
    [ -s "$NB_DIR/sub.json" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_SUB_R_NOTHING]}${COLOR_RESET}"; return 1; }
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }
    local host sub_ov
    host=$(jq -r '.host // empty' "$NB_DIR/sub.json" 2>/dev/null)
    sub_ov=$(jq -r '.overlay // empty' "$NB_DIR/sub.json" 2>/dev/null)
    [ -n "$host" ] || { echo -e "${COLOR_RED}${LANG[NB_SUB_R_NOHOST]}${COLOR_RESET}"; return 1; }

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_SUB_R_TITLE]}${COLOR_RESET}"
    echo -e ""
    reading_yn "$(printf "${LANG[NB_SUB_R_CONFIRM]}" "$host")" go || return 1

    # The pre-migration compose: local snapshot first, the on-box twin
    # second. Neither means the migration stopped before the rewrite — the
    # live compose never stopped being the public one.
    step_do "${LANG[NB_SUB_R_STEP_COMPOSE]}"
    local restored=""
    if [ -s "${NB_DIR}/sub.compose.b64" ]; then
        base64 -d "${NB_DIR}/sub.compose.b64" \
            | re_run_host "$host" 'umask 077; cat > /opt/subscription/docker-compose.yml.tmp && mv -f /opt/subscription/docker-compose.yml.tmp /opt/subscription/docker-compose.yml && chmod 600 /opt/subscription/docker-compose.yml' >/dev/null 2>&1 \
            && restored=1
    fi
    if [ -z "$restored" ] && re_run_host_n "$host" 'test -s /opt/subscription/docker-compose.yml.rrpbak' >/dev/null 2>&1; then
        re_run_host_n "$host" 'cp -f /opt/subscription/docker-compose.yml.rrpbak /opt/subscription/docker-compose.yml && chmod 600 /opt/subscription/docker-compose.yml' >/dev/null 2>&1 \
            && restored=1
    fi
    if [ -z "$restored" ]; then
        re_run_host_n "$host" 'test -s /opt/subscription/docker-compose.yml' >/dev/null 2>&1 \
            || { echo -e "${COLOR_RED}${LANG[NB_SUB_NO_COMPOSE]}${COLOR_RESET}"; return 3; }
        echo -e "${COLOR_YELLOW}${LANG[NB_SUB_R_NOSNAP]}${COLOR_RESET}"
    fi
    # Stale gate value from a pre-reinstall snapshot would leave the page
    # knocking on a closed door: sync it to what the panel uses right now.
    local cur_cookie=""
    cur_cookie=$(nb_sub_cookie_current)
    if [ -n "$cur_cookie" ] \
       && re_run_host_n "$host" 'grep -q "EGAMES_COOKIE=" /opt/subscription/docker-compose.yml' >/dev/null 2>&1; then
        # The gate pair rides stdin into ENVIRON, never the remote argv.
        local ck_script
        ck_script=$(cat <<'EOS'
umask 077
IFS= read -r c
f=/opt/subscription/docker-compose.yml
NB_C="$c" awk '{ if (match($0, /EGAMES_COOKIE=[A-Za-z0-9_-]*=[A-Za-z0-9_-]*/)) $0 = substr($0, 1, RSTART - 1) "EGAMES_COOKIE=" ENVIRON["NB_C"] substr($0, RSTART + RLENGTH); print }' "$f" > "$f.rrptmp" \
    && cat "$f.rrptmp" > "$f"
rc=$?
rm -f "$f.rrptmp"
exit $rc
EOS
)
        printf '%s\n' "$cur_cookie" | re_run_host "$host" "$ck_script" >/dev/null 2>&1
        echo -e "${COLOR_GRAY}${LANG[NB_SUB_R_COOKIE]}${COLOR_RESET}"
    fi
    step_ok "${LANG[NB_SUB_R_COMPOSE_OK]}"

    step_do "${LANG[NB_SUB_R_STEP_UP]}"
    re_run_host_n "$host" 'cd /opt/subscription && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1 \
        || { echo -e "${COLOR_RED}${LANG[NB_SUB_R_UP_FAIL]}${COLOR_RESET}"; return 3; }
    local i down=0
    for i in 1 2 3 4 5 6; do
        sleep 5
        re_run_host_n "$host" 'docker ps --format "{{.Names}} {{.Status}}" | grep -q "remnawave-subscription-page Up"' >/dev/null 2>&1 || { down=1; break; }
    done
    [ "$down" = 1 ] && { echo -e "${COLOR_RED}${LANG[NB_SUB_R_UP_FAIL]}${COLOR_RESET}"; return 3; }
    step_ok "${LANG[NB_SUB_R_UP_OK]}"

    # The public proof, mirrored from the migration: ask the panel's public
    # address for metadata with the token the restored compose carries —
    # and the gate cookie when the panel runs hidden. The container staying
    # up is the overlay proof; this is the public one.
    step_do "${LANG[NB_SUB_R_STEP_VERIFY]}"
    local code
    code=$(re_run_host_n "$host" "$(nb_sub_public_probe_script)" 2>/dev/null)
    if [ "$code" = "skip" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NB_SUB_R_VERIFY_SKIP]}${COLOR_RESET}"
    else
        if [ "$code" != "200" ]; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_SUB_R_VERIFY_FAIL]}" "${code:-no answer}")${COLOR_RESET}"
            return 5
        fi
    fi
    step_ok "${LANG[NB_SUB_R_VERIFY_OK]}"

    step_do "${LANG[NB_SUB_R_STEP_LISTENER]}"
    if nb_api_mode && [ -n "$sub_ov" ]; then
        local spid gid
        spid=$(nb_peer_id_by_ip "$sub_ov")
        gid=$(nb_state_get grp_sub)
        [ -n "$spid" ] && [ -n "$gid" ] && nb_group_remove_peer "$gid" "$spid"
    fi
    rm -f "$NB_DIR/sub.json" "${NB_DIR}/sub.compose.b64"
    re_run_host_n "$host" 'rm -f /opt/subscription/docker-compose.yml.rrpbak' >/dev/null 2>&1
    if [ -s "$NB_DIR/checker.json" ]; then
        nb_listener_apply >/dev/null 2>&1 || echo -e "${COLOR_YELLOW}${LANG[NB_SUB_LISTENER_FAIL]}${COLOR_RESET}"
        step_ok "${LANG[NB_SUB_R_LISTENER_OK]}"
    else
        nb_listener_remove
        step_ok "${LANG[NB_SUB_R_LISTENER_GONE]}"
    fi
    nb_audit "sub reverted host=$host"
    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[NB_SUB_R_DONE]}" "$host")${COLOR_RESET}"
    return 0
}

# State-aware menu entry: a live sub record offers the revert first, the
# re-migrate stays as the repair path; no record means a plain migration.
nb_sub_manage() {
    local host sub_ov pick
    host=$(jq -r '.host // empty' "$NB_DIR/sub.json" 2>/dev/null)
    sub_ov=$(jq -r '.overlay // empty' "$NB_DIR/sub.json" 2>/dev/null)
    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[NB_SUB_M_TITLE]}${COLOR_RESET}"
        [ -n "$host" ] && echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_SUB_M_STATE]}" "$host" "${sub_ov:--}")${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[NB_SUB_M_REVERT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[NB_SUB_M_REMIGRATE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" pick || return 0
        case "$pick" in
            1) nb_sub_revert; return $? ;;
            2) nb_sub_migrate; return $? ;;
            0) return 0 ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2 ;;
        esac
    done
}

nb_sub_flow() {
    if [ -s "$NB_DIR/sub.json" ]; then
        nb_sub_manage
    else
        nb_sub_migrate
    fi
}

# ---------------------------------------------------------------------------
# Xray Checker over overlay: the checker fetches its subscription
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

nb_checker_migrate() {
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }
    nb_mgmt_connected || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }
    nb_api_mode || { echo -e "${COLOR_YELLOW}${LANG[NB_POL_NO_API]}${COLOR_RESET}"; return 1; }
    local panel_ov
    panel_ov=$(nb_wt0_ip)
    nb_is_ipv4 "$panel_ov" || { echo -e "${COLOR_RED}${LANG[NB_ERR_PANEL_NOT_JOINED]}${COLOR_RESET}"; return 3; }

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

    # The UI/metrics listen on 0.0.0.0:2112 (host network) and only the
    # host firewall keeps them off the internet: say so before anything
    # changes when UFW is off or already lets 2112 in from outside wt0.
    # Verbose status carries the default incoming policy; an allow-by-default
    # box, a port range over 2112 or a port-less "Anywhere" rule is open too.
    local ufw_st ufw_script
    ufw_script=$(cat <<'EOS'
command -v ufw >/dev/null 2>&1 || { echo off; exit 0; }
st=$(ufw status verbose 2>/dev/null)
printf '%s\n' "$st" | grep -q '^Status: active' || { echo off; exit 0; }
printf '%s\n' "$st" | grep -qE '^Default: (deny|reject) \(incoming\)' || { echo open; exit 0; }
printf '%s\n' "$st" | awk '
    /^To +Action/ { t = 1; next }
    !t || !/ALLOW|LIMIT/ { next }
    $2 == "on" && $3 == "wt0" { next }
    $1 == "Anywhere" { o = 1; next }
    {
        n = split($1, parts, ",")
        for (i = 1; i <= n; i++) {
            p = parts[i]; sub(/\/(tcp|udp)$/, "", p)
            if (p == "2112") o = 1
            else if (p ~ /^[0-9]+:[0-9]+$/) { split(p, r, ":"); if (r[1] + 0 <= 2112 && r[2] + 0 >= 2112) o = 1 }
        }
    }
    END { print (o ? "open" : "ok") }'
EOS
)
    ufw_st=$(re_run_host_n "$host" "$ufw_script" 2>/dev/null)
    if [ -z "$ufw_st" ]; then
        # No answer is not "UFW off": say that the state is unknown.
        echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_XCHK_UFW_UNKNOWN]}" "$host")${COLOR_RESET}"
        reading_yn "${LANG[NB_XCHK_UFW_ASK]}" xchk_ufw_go || { echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"; return 1; }
    elif [ "$ufw_st" != "ok" ]; then
        if [ "$ufw_st" = "open" ]; then
            echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_XCHK_UFW_OPEN]}" "$host")${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_XCHK_UFW_OFF]}" "$host")${COLOR_RESET}"
        fi
        reading_yn "${LANG[NB_XCHK_UFW_ASK]}" xchk_ufw_go || { echo -e "${COLOR_YELLOW}${LANG[NB_CANCELLED]}${COLOR_RESET}"; return 1; }
    fi

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
        up_out=$(printf '%s\n' "$key" | re_run_host "$host" "$(nb_up_script "$host" "$(nb_mgmt_for_remote)")")
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
    step_do "${LANG[NB_XCHK_STEP_LISTENER_ALLOW]}"
    nb_listener_apply || echo -e "${COLOR_YELLOW}${LANG[NB_SUB_LISTENER_FAIL]}${COLOR_RESET}"
    step_ok "$(printf "${LANG[NB_SUB_LISTENER_OK]}" "$port")"

    # Minimal remote stack: checker only, host network, metrics on 0.0.0.0
    # guarded by basic auth (generated here, stored in the state file), the
    # public interface closed by ufw (checked, or accepted by the operator,
    # before the join) — overlay peers alone see it.
    step_do "${LANG[NB_XCHK_STEP_STACK]}"
    local ui_user="rrp" ui_pass
    ui_pass=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 16)
    # Snapshot a pre-existing public stack (the xchk module writes the same
    # path) so the revert can bring it back; our own overlay compose never
    # overwrites the backup.
    local old_compose
    old_compose=$(re_run_host_n "$host" 'cat /opt/xray-checker/docker-compose.yml 2>/dev/null')
    # A live public compose refreshes the snapshot; an overlay one never
    # does — it is known by its address range, not only by today's wt0 IP.
    if [ -n "$old_compose" ] \
       && ! printf '%s\n' "$old_compose" | grep -q "SUBSCRIPTION_URL=http://${panel_ov}:" \
       && ! nb_compose_rides_overlay "$old_compose" SUBSCRIPTION_URL; then
        printf '%s' "$old_compose" | base64 -w0 > "${NB_DIR}/checker.compose.b64"
        chmod 600 "${NB_DIR}/checker.compose.b64" 2>/dev/null
    fi
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
    # The xchk stack in the same project dir may carry a sidecar (nginx/caddy
    # publishing the UI on the public domain) and a status page that would
    # hit the now-protected metrics: they go as orphans. The pre-migration
    # compose snapshot brings them back on revert/rollback.
    re_run_host_n "$host" 'cd /opt/xray-checker && { docker compose up -d --remove-orphans || docker-compose up -d --remove-orphans; }' >/dev/null 2>&1 \
        || { echo -e "${COLOR_RED}${LANG[NB_SUB_UP_FAIL]}${COLOR_RESET}"; nb_checker_rollback "$host"; return 3; }
    if [ -s "${NB_DIR}/checker.compose.b64" ]; then
        re_run_host_n "$host" 'for c in xray-checker-nginx xray-checker-caddy xray-checker-statuspage; do docker rm -f "$c" >/dev/null 2>&1; done; true' >/dev/null 2>&1
    fi
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
    # The shortUuid (a live subscription of every squad) rides in a curl
    # config on stdin, not in the ssh command line or the remote argv.
    local sub_code
    sub_code=$(printf 'url = "http://%s:%s/api/sub/%s"\n' "$panel_ov" "$port" "$short" \
        | re_run_host "$host" "curl -s -o /dev/null -w '%{http_code}' -m 10 -K -" 2>/dev/null)
    if [ "$sub_code" != "200" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[NB_XCHK_SUB_FAIL]}" "${sub_code:-no answer}")${COLOR_RESET}"
        nb_checker_rollback "$host"
        return 5
    fi
    local m_code
    m_code=$(curl -s -o /dev/null -w '%{http_code}' -m 8 -K <(printf 'user = "%s:%s"\n' "$ui_user" "$ui_pass") "http://${chk_ov}:2112/metrics" 2>/dev/null)
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
    step_do "${LANG[NB_XCHK_ROLLBACK]}"
    # With a pre-migration snapshot the public stack comes back — the
    # rollback must not leave the module's minimal compose in its place.
    # Without one there was nothing before us: tear the minimal stack down.
    # The snapshot is the only copy of the public stack (the box has no
    # twin): it and the record go only after the restore landed and came up.
    if [ -s "${NB_DIR}/checker.compose.b64" ]; then
        if ! base64 -d "${NB_DIR}/checker.compose.b64" \
               | re_run_host "$host" 'umask 077; cat > /opt/xray-checker/docker-compose.yml.tmp && mv -f /opt/xray-checker/docker-compose.yml.tmp /opt/xray-checker/docker-compose.yml' >/dev/null 2>&1 \
           || ! re_run_host_n "$host" 'cd /opt/xray-checker && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1; then
            echo -e "${COLOR_RED}$(printf "${LANG[NB_XCHK_ROLLBACK_FAIL]}" "$host")${COLOR_RESET}"
            nb_audit "checker rollback FAILED host=$host (record kept)"
            return 1
        fi
    else
        re_run_host_n "$host" 'cd /opt/xray-checker && { docker compose down || docker-compose down; }' >/dev/null 2>&1
    fi
    rm -f "$NB_DIR/checker.json" "${NB_DIR}/checker.compose.b64"
    # Rebuild the listener only when another service still rides it; an
    # allowlist-less 444 block on the port is nobody's leftover.
    if [ -s "$NB_DIR/sub.json" ]; then
        nb_listener_apply >/dev/null 2>&1
    else
        nb_listener_remove
    fi
    nb_audit "checker rolled back host=$host"
    step_ok "${LANG[NB_XCHK_ROLLBACK_OK]}"
}

# Revert: take the checker off the overlay. With a pre-migration
# snapshot the public stack comes back and gets proven; without one the
# module-installed overlay stack is torn down — the public checker is then
# the xchk module's job again. The NetBird client stays on the box (full
# removal explains the manual cleanup); SSH rides the public host, so this
# works with the overlay down too.
nb_checker_revert() {
    [ -s "$NB_DIR/checker.json" ] || { echo -e "${COLOR_YELLOW}${LANG[NB_XCHK_R_NOTHING]}${COLOR_RESET}"; return 1; }
    panel_is_installed || { echo -e "${COLOR_RED}${LANG[NB_ERR_ROLE]}${COLOR_RESET}"; return 1; }
    nb_need_re || { echo -e "${COLOR_RED}${LANG[NB_ERR_RE]}${COLOR_RESET}"; return 1; }
    local host chk_ov snap=0
    host=$(jq -r '.host // empty' "$NB_DIR/checker.json" 2>/dev/null)
    chk_ov=$(jq -r '.overlay // empty' "$NB_DIR/checker.json" 2>/dev/null)
    [ -n "$host" ] || { echo -e "${COLOR_RED}${LANG[NB_SUB_R_NOHOST]}${COLOR_RESET}"; return 1; }
    [ -s "${NB_DIR}/checker.compose.b64" ] && snap=1

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[NB_XCHK_R_TITLE]}${COLOR_RESET}"
    echo -e ""
    if [ "$snap" = 1 ]; then
        reading_yn "$(printf "${LANG[NB_XCHK_R_CONFIRM_SNAP]}" "$host")" go || return 1
    else
        reading_yn "$(printf "${LANG[NB_XCHK_R_CONFIRM_CLEAN]}" "$host")" go || return 1
    fi

    if [ "$snap" = 1 ]; then
        step_do "${LANG[NB_XCHK_R_STEP_RESTORE]}"
        base64 -d "${NB_DIR}/checker.compose.b64" \
            | re_run_host "$host" 'umask 077; mkdir -p /opt/xray-checker && cat > /opt/xray-checker/docker-compose.yml.tmp && mv -f /opt/xray-checker/docker-compose.yml.tmp /opt/xray-checker/docker-compose.yml && chmod 600 /opt/xray-checker/docker-compose.yml' >/dev/null 2>&1 \
            || { echo -e "${COLOR_RED}${LANG[NB_XCHK_R_RESTORE_FAIL]}${COLOR_RESET}"; return 3; }
        step_ok "${LANG[NB_XCHK_R_RESTORE_OK]}"

        step_do "${LANG[NB_XCHK_R_STEP_UP]}"
        re_run_host_n "$host" 'cd /opt/xray-checker && { docker compose up -d || docker-compose up -d; }' >/dev/null 2>&1 \
            || { echo -e "${COLOR_RED}${LANG[NB_XCHK_R_UP_FAIL]}${COLOR_RESET}"; return 3; }
        step_ok "${LANG[NB_XCHK_R_UP_OK]}"

        # The restored stack is our own byte-identical snapshot: its health
        # is the pre-migration condition, not the revert's doing. A dead
        # subscription URL earns a warning, not a blocked revert.
        step_do "${LANG[NB_XCHK_R_STEP_VERIFY]}"
        local pub_sub code
        pub_sub=$(re_run_host_n "$host" 'sed -n "s/.*SUBSCRIPTION_URL=//p" /opt/xray-checker/docker-compose.yml | head -n1' 2>/dev/null | tr -d "\"'\r")
        if [ -z "$pub_sub" ]; then
            echo -e "${COLOR_YELLOW}${LANG[NB_XCHK_R_VERIFY_SKIP]}${COLOR_RESET}"
        else
            code=$(printf 'url = "%s"\n' "$pub_sub" \
                | re_run_host "$host" "curl -s -o /dev/null -w '%{http_code}' -m 15 -K -" 2>/dev/null)
            if [ "$code" != "200" ]; then
                echo -e "${COLOR_YELLOW}$(printf "${LANG[NB_XCHK_R_VERIFY_WARN]}" "${code:-no answer}")${COLOR_RESET}"
            fi
        fi
        step_ok "${LANG[NB_XCHK_R_VERIFY_OK]}"
    else
        step_do "${LANG[NB_XCHK_R_STEP_DOWN]}"
        if re_run_host_n "$host" 'test -f /opt/xray-checker/docker-compose.yml' >/dev/null 2>&1; then
            re_run_host_n "$host" 'cd /opt/xray-checker && { docker compose down || docker-compose down; }' >/dev/null 2>&1
            # down is silenced — the gone container is the outcome proof.
            if re_run_host_n "$host" 'docker ps -a --format "{{.Names}}" | grep -qx xray-checker' >/dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[NB_XCHK_R_DOWN_FAIL]}${COLOR_RESET}"
                return 3
            fi
            re_run_host_n "$host" 'rm -f /opt/xray-checker/docker-compose.yml' >/dev/null 2>&1
        fi
        step_ok "${LANG[NB_XCHK_R_DOWN_OK]}"
    fi

    step_do "${LANG[NB_XCHK_R_STEP_LISTENER]}"
    if nb_api_mode && [ -n "$chk_ov" ]; then
        local cpid gid
        cpid=$(nb_peer_id_by_ip "$chk_ov")
        gid=$(nb_state_get grp_checker)
        [ -n "$cpid" ] && [ -n "$gid" ] && nb_group_remove_peer "$gid" "$cpid"
    fi
    rm -f "$NB_DIR/checker.json" "${NB_DIR}/checker.compose.b64"
    if [ -s "$NB_DIR/sub.json" ]; then
        nb_listener_apply >/dev/null 2>&1 || echo -e "${COLOR_YELLOW}${LANG[NB_SUB_LISTENER_FAIL]}${COLOR_RESET}"
        step_ok "${LANG[NB_XCHK_R_LISTENER_OK]}"
    else
        nb_listener_remove
        step_ok "${LANG[NB_XCHK_R_LISTENER_GONE]}"
    fi
    nb_audit "checker reverted host=$host snap=$snap"
    echo -e ""
    if [ "$snap" = 1 ]; then
        echo -e "${COLOR_GREEN}$(printf "${LANG[NB_XCHK_R_DONE_SNAP]}" "$host")${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}$(printf "${LANG[NB_XCHK_R_DONE_CLEAN]}" "$host")${COLOR_RESET}"
    fi
    return 0
}

# State-aware menu entry, the sub twin: revert first, re-migrate as repair.
nb_checker_manage() {
    local host chk_ov pick
    host=$(jq -r '.host // empty' "$NB_DIR/checker.json" 2>/dev/null)
    chk_ov=$(jq -r '.overlay // empty' "$NB_DIR/checker.json" 2>/dev/null)
    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[NB_XCHK_M_TITLE]}${COLOR_RESET}"
        [ -n "$host" ] && echo -e " ${COLOR_GRAY}$(printf "${LANG[NB_XCHK_M_STATE]}" "$host" "${chk_ov:--}")${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[NB_XCHK_M_REVERT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[NB_XCHK_M_REMIGRATE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 2)" pick || return 0
        case "$pick" in
            1) nb_checker_revert; return $? ;;
            2) nb_checker_migrate; return $? ;;
            0) return 0 ;;
            *) printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 2 ;;
        esac
    done
}

nb_checker_flow() {
    if [ -s "$NB_DIR/checker.json" ]; then
        nb_checker_manage
    else
        nb_checker_migrate
    fi
}

# ---------------------------------------------------------------------------
# Nodes flow: the menu label promises migrate AND import of a manual
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
# Menu
# ---------------------------------------------------------------------------

nb_header() {
    echo -e "${COLOR_GREEN}${LANG[NB_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[NB_DOC_LINK]}${COLOR_RESET}"
    echo -e ""
    if ! nb_pkg_installed; then
        echo -e " ${COLOR_GRAY}${LANG[NB_DIAG_NO_CLIENT]}${COLOR_RESET}"
    else
        local hold="" cidr conn ver mode
        nb_hold_on && hold="${LANG[NB_HOLD_SUFFIX]}"
        ver="$(nb_client_version)${hold}"
        cidr=$(nb_wt0_cidr); cidr=${cidr:--}
        conn="${LANG[NB_NO]}"
        nb_mgmt_connected && conn="${LANG[NB_YES]}"
        mode="${LANG[NB_MODE_BASIC]}"
        [ "$(nb_state_get mode)" = "api" ] && mode="API"
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
        # Numbers are rebuilt every pass: a stale one (policies gone after
        # "forget PAT", package items after purge) would shadow or hide-run.
        opt_join=99; opt_nodes=99; opt_bg=99; opt_sub=99; opt_xchk=99; opt_diag=99
        opt_pol=99; opt_set=99; opt_flags=99; opt_upd=99; opt_off=99; opt_purge=99
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
