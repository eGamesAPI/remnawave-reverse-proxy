#!/bin/bash
# Module: remote_exec — SSH access

RE_LEGACY_STATE="${DIR_REMNAWAVE}remote-exec.state"
RE_CONF_DIR="${DIR_REMNAWAVE}remote-exec"
RE_ACTIVE_FILE="${DIR_REMNAWAVE}remote-exec.active"
RE_KEY_DIR="${DIR_REMNAWAVE}ssh"
RE_KEY_FILE="${RE_KEY_DIR}/id_ed25519"
RE_KNOWN_HOSTS="${RE_KEY_DIR}/known_hosts"

# Filename-safe target id for a host:port pair.
re_target_name() {
    printf '%s_%s' "$1" "$2" | tr -c 'a-zA-Z0-9._-' '_'
}

# Persist a target; the optional sixth argument is the NetBird overlay alias.
# Unknown keys already in the file survive the rewrite, one host keeps one
# target — a write with a new port replaces the stale file instead of racing
# directory collation — and an overlay alias lives on exactly one target.
re_target_write() {
    local host="$1" port="$2" user="$3" key="$4" label="${5:-}" overlay="${6:-}"
    local name other file tmp
    name=$(re_target_name "$host" "$port")
    mkdir -p "$RE_CONF_DIR" 2>/dev/null

    while IFS= read -r other; do
        [ "$other" = "$name" ] && continue
        rm -f -- "${RE_CONF_DIR}/${other}.target"
    done < <(re_targets_list | while IFS= read -r t; do
        re_target_load "$t" && [ "$RE_HOST" = "$host" ] && printf '%s\n' "$t"
    done)

    if [ -n "$overlay" ]; then
        while IFS= read -r other; do
            [ "$other" = "$name" ] && continue
            file="${RE_CONF_DIR}/${other}.target"
            [ -f "$file" ] && sed -i '/^overlay=/d' "$file"
        done < <(re_targets_list)
    fi

    file="${RE_CONF_DIR}/${name}.target"
    tmp="${file}.tmp"
    {
        [ -f "$file" ] && grep -v -E '^(host|port|user|key|label|overlay)=' "$file"
        printf 'host=%s\nport=%s\nuser=%s\nkey=%s\nlabel=%s\n' "$host" "$port" "$user" "$key" "$label"
        [ -n "$overlay" ] && printf 'overlay=%s\n' "$overlay"
    } > "$tmp" 2>/dev/null
    mv -f "$tmp" "$file"
    chmod 600 "$file" 2>/dev/null
    printf '%s\n' "$name" > "$RE_ACTIVE_FILE"
    chmod 600 "$RE_ACTIVE_FILE" 2>/dev/null
}

# One-shot import of the pre-multi-target single state file.
re_migrate_legacy() {
    [ -f "$RE_LEGACY_STATE" ] || return 0
    local host port user key
    host=$(sed -n 's|^host=||p' "$RE_LEGACY_STATE" | head -n1)
    port=$(sed -n 's|^port=||p' "$RE_LEGACY_STATE" | head -n1)
    user=$(sed -n 's|^user=||p' "$RE_LEGACY_STATE" | head -n1)
    key=$(sed -n 's|^key=||p' "$RE_LEGACY_STATE" | head -n1)
    # Validate BEFORE removing: a partial read must not destroy the only copy.
    { [ -n "$host" ] && [ -n "$key" ]; } || return 0
    rm -f "$RE_LEGACY_STATE"
    [ -n "$port" ] || port=22
    [ -n "$user" ] || user=root
    re_target_write "$host" "$port" "$user" "$key"
}

# Every configured target name, one per line; nothing when none exist.
re_targets_list() {
    local f
    for f in "$RE_CONF_DIR"/*.target; do
        [ -f "$f" ] || continue
        basename "$f" .target
    done
}

# Load target <name> into RE_HOST/RE_PORT/RE_USER/RE_KEY/RE_LABEL.
re_target_load() {
    local file="${RE_CONF_DIR}/$1.target"
    [ -r "$file" ] || return 1
    RE_HOST=$(sed -n 's|^host=||p' "$file" | head -n1)
    RE_PORT=$(sed -n 's|^port=||p' "$file" | head -n1)
    [ -n "$RE_PORT" ] || RE_PORT=22
    RE_USER=$(sed -n 's|^user=||p' "$file" | head -n1)
    [ -n "$RE_USER" ] || RE_USER=root
    RE_KEY=$(sed -n 's|^key=||p' "$file" | head -n1)
    RE_LABEL=$(sed -n 's|^label=||p' "$file" | head -n1)
    RE_OVERLAY=$(sed -n 's|^overlay=||p' "$file" | head -n1)
    [ -n "$RE_HOST" ] && [ -n "$RE_KEY" ]
}

# Find the target bound to the address — its public host or its NetBird
# overlay alias — whatever the port. A miss must clear the loaded fields:
# callers act on RE_* afterwards, and a stale target's user/port silently
# rode along (add_node printed access details of the wrong machine).
re_target_load_by_host() {
    local want="$1" name
    RE_HOST=""; RE_PORT=""; RE_USER=""; RE_KEY=""; RE_LABEL=""; RE_OVERLAY=""
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if re_target_load "$name" && { [ "$RE_HOST" = "$want" ] || { [ -n "$RE_OVERLAY" ] && [ "$RE_OVERLAY" = "$want" ]; }; }; then
            return 0
        fi
    done < <(re_targets_list)
    # The loop probes every file with re_target_load; without a final reset a
    # miss would leave the LAST examined target sitting in RE_*.
    RE_HOST=""; RE_PORT=""; RE_USER=""; RE_KEY=""; RE_LABEL=""; RE_OVERLAY=""
    return 1
}

# Drop the remembered host key for host:port (and optionally its overlay
# alias) before reconnecting to a box that legitimately changed its key — an
# OS reinstall. accept-new alone would silently trust the new key, so this is
# always an explicit operator action with the fingerprint checked separately.
re_forget_host_key() {
    local host="$1" port="${2:-22}" alias="${3:-}"
    ssh-keygen -R "[${host}]:${port}" -f "$RE_KNOWN_HOSTS" >/dev/null 2>&1
    ssh-keygen -R "$host" -f "$RE_KNOWN_HOSTS" >/dev/null 2>&1
    [ -n "$alias" ] && ssh-keygen -R "[${alias}]:${port}" -f "$RE_KNOWN_HOSTS" >/dev/null 2>&1
    return 0
}

# Load the active (last used) target; with exactly one configured target
# that one wins even without the pointer.
re_load_state() {
    re_migrate_legacy
    local name
    if [ -r "$RE_ACTIVE_FILE" ]; then
        name=$(cat "$RE_ACTIVE_FILE" 2>/dev/null)
        re_target_load "$name" && return 0
    fi
    name=$(re_targets_list | head -n1)
    [ -n "$name" ] && re_target_load "$name"
    return 0
}

re_is_configured() {
    [ -n "$RE_HOST" ] && [ -n "$RE_KEY" ] && [ -f "$RE_KEY" ]
}

# The known_hosts file lives beside our key; a custom-key setup would have
# nowhere to record the host without it.
re_ensure_dirs() {
    mkdir -p "$RE_KEY_DIR" 2>/dev/null && chmod 700 "$RE_KEY_DIR" 2>/dev/null
}

re_ensure_client() {
    command -v ssh >/dev/null 2>&1 && return 0
    apt-get -o DPkg::Lock::Timeout=300 install -y openssh-client >/dev/null 2>&1
    command -v ssh >/dev/null 2>&1
}

re_ensure_sshpass() {
    command -v sshpass >/dev/null 2>&1 && return 0
    step_do "${LANG[RE_NO_SSHPASS]}"
    apt-get -o DPkg::Lock::Timeout=300 install -y sshpass >/dev/null 2>&1
    command -v sshpass >/dev/null 2>&1
}

# Marker on every key we install: identifies our line in authorized_keys for
# revocation and shows up in sshd logs as "this was the panel, not the human".
# Quotes, backslashes and whitespace are stripped: the pubkey is interpolated
# into single-quoted remote commands and a sed address on revoke — one stray
# character in PANEL_DOMAIN would break both.
re_key_comment() {
    local domain
    domain=$(sed -n 's/^PANEL_DOMAIN=//p' /opt/remnawave/.env 2>/dev/null | head -n1 | tr -d '"')
    domain=$(printf '%s' "${domain:-$(hostname)}" | tr -d "'\\\\" | tr -d '[:space:]')
    echo "remnawave-reverse-proxy@${domain:-localhost}"
}

re_generate_key() {
    re_ensure_dirs
    [ -f "$RE_KEY_FILE" ] && return 0
    ssh-keygen -q -t ed25519 -N "" -C "$(re_key_comment)" -f "$RE_KEY_FILE" || return 1
    chmod 600 "$RE_KEY_FILE" "$RE_KEY_FILE.pub" 2>/dev/null
    return 0
}

re_pubkey() {
    if [ -s "$RE_KEY_FILE.pub" ]; then
        cat "$RE_KEY_FILE.pub"
    else
        echo "$(ssh-keygen -y -f "$RE_KEY_FILE" 2>/dev/null) $(re_key_comment)"
    fi
}

# Silent publickey probe: BatchMode keeps it from ever waiting on a prompt.
# -n keeps ssh from draining the caller's stdin — a probe that ate the input
# stream left every later read in the interactive setup at EOF (seen live: a piped
# answers file died exactly here). Data-shipping ssh calls must NOT copy this.
re_try_key() {
    local host="$1" port="$2" user="$3" key="$4"
    [ -r "$key" ] || return 1
    re_ensure_dirs
    ssh -n -i "$key" -p "$port" \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$RE_KNOWN_HOSTS" \
        -o IdentitiesOnly=yes \
        "$user@$host" true >/dev/null 2>&1
}

# Keys worth probing, most specific first; deduped, missing files skipped.
# Custom keys remembered by earlier targets come first: a box the operator
# already automated is the most likely to accept the same key again.
re_candidate_keys() {
    {
        sed -n 's|^key=||p' "$RE_CONF_DIR"/*.target 2>/dev/null
        printf '%s\n' "$RE_KEY_FILE"
        printf '%s\n' /root/.ssh/id_ed25519 /root/.ssh/id_ecdsa /root/.ssh/id_rsa
    } | awk 'NF && !seen[$0]++'
}

# "name<TAB>address<TAB>uuid" per node, from the saved panel token only — a
# dead token or a node-only box falls back to manual address entry without
# any prompt. The uuid lets callers resolve overlay addresses back to the
# public host through the netbird module state.
re_panel_nodes() {
    local token_file="${DIR_REMNAWAVE}token" response
    [ -r "$token_file" ] || return 1
    response=$(make_api_request "GET" "http://127.0.0.1:3000/api/nodes?_=$(date +%s)" "$(cat "$token_file")" 2>/dev/null)
    echo "$response" | jq -r '.response[]? | "\(.name)\t\(.address)\t\(.uuid)"' 2>/dev/null | awk 'NF'
}

# SSH address for a panel node. A node moved onto the NetBird overlay carries
# its overlay IP as .address; the real public host sits in the netbird module
# state next to the node uuid. Without that state the panel address passes
# through unchanged.
re_public_addr() {
    local address="$1" uuid="${2:-}" f pub
    if [ -d "${DIR_REMNAWAVE}netbird/nodes" ]; then
        for f in "${DIR_REMNAWAVE}netbird/nodes"/*.json; do
            [ -f "$f" ] || continue
            if jq -e --arg a "$address" --arg u "$uuid" \
                'select(.overlay == $a or ($u != "" and .uuid == $u))' "$f" >/dev/null 2>&1; then
                pub=$(jq -r '.public_host // .old_address // empty' "$f" 2>/dev/null)
                [ -n "$pub" ] && { printf '%s' "$pub"; return 0; }
            fi
        done
    fi
    printf '%s' "$address"
}

reading_hidden() {
    printf ' %s' "$(question "$1")"
    read -rs "$2"
    echo ""
}

# Free-text label shown in menus: echo -e would eat backslash escapes, so
# they are stripped; length capped to keep one line per machine.
re_clean_label() {
    local l="${1//\\/}"
    printf '%s' "${l:0:32}"
}

# Sets RE_HOST from the panel node list or manual entry; rc=1 — cancelled.
# The list shows the public host: after a NetBird migration .address is an
# overlay IP that SSH must never depend on. An empty pick re-asks instead of
# silently taking the first node, and EOF cancels instead of recursing.
re_pick_host() {
    local entries=() entry name address uuid pub pick last i
    if panel_is_installed && command -v jq >/dev/null 2>&1 && load_api_module; then
        mapfile -t entries < <(re_panel_nodes)
    fi

    if [ "${#entries[@]}" -eq 0 ]; then
        reading "${LANG[RE_HOST_PROMPT]}" RE_HOST || return 1
        [ -n "$RE_HOST" ] || return 1
        return 0
    fi

    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[RE_NODES_TITLE]}${COLOR_RESET}"
        echo -e ""
        i=1
        for entry in "${entries[@]}"; do
            name="${entry%%$'\t'*}"
            address=$(printf '%s' "$entry" | cut -f2)
            uuid=$(printf '%s' "$entry" | cut -f3)
            pub=$(re_public_addr "$address" "$uuid")
            if [ "$pub" != "$address" ]; then
                echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${pub}${COLOR_RESET} ${COLOR_GRAY}(${name}, overlay: ${address})${COLOR_RESET}"
            else
                echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${address}${COLOR_RESET} ${COLOR_GRAY}(${name})${COLOR_RESET}"
            fi
            i=$((i + 1))
        done
        last=$i
        echo -e "${COLOR_YELLOW}${last}. ${LANG[RE_NODES_MANUAL]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" pick || return 1

        if [ "$pick" = "0" ]; then
            return 1
        fi
        if [ "$pick" = "$last" ]; then
            reading "${LANG[RE_HOST_PROMPT]}" RE_HOST || return 1
            [ -n "$RE_HOST" ] || continue
            return 0
        fi
        if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#entries[@]}" ]; then
            address=$(printf '%s' "${entries[$((pick - 1))]}" | cut -f2)
            uuid=$(printf '%s' "${entries[$((pick - 1))]}" | cut -f3)
            RE_HOST=$(re_public_addr "$address" "$uuid")
            return 0
        fi
        printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
        sleep 1
    done
}

# Operator points at a key that already lives here; sets RE_PICKED_KEY. The
# result goes through a global on purpose: the dialog prints to stdout, so
# capturing the function with $(...) would glue the messages onto the path.
# The file is used in place, never read.
re_setup_custom_key() {
    local host="$1" port="$2" user="$3" path
    RE_PICKED_KEY=""
    while true; do
        reading "${LANG[RE_KEY_PATH_PROMPT]}" path
        [ -z "$path" ] && return 1
        if [ ! -r "$path" ]; then
            echo -e "${COLOR_RED}${LANG[RE_KEY_PATH_BAD]}${COLOR_RESET}"
            continue
        fi
        if re_try_key "$host" "$port" "$user" "$path"; then
            RE_PICKED_KEY="$path"
            return 0
        fi
        echo -e "${COLOR_YELLOW}${LANG[RE_TRYING_FAIL]}${COLOR_RESET}"
    done
}

# Password once, key installed, password forgotten. SSHPASS goes through the
# environment (sshpass -e) — a -p argument would be visible in ps output.
re_setup_password() {
    local host="$1" port="$2" user="$3" pass pubkey rc
    re_ensure_sshpass || return 1

    reading_hidden "$(printf "${LANG[RE_PASS_PROMPT]}" "$host")" pass
    [ -n "$pass" ] || return 1

    re_generate_key || return 1
    pubkey=$(re_pubkey) || return 1

    step_do "$(printf "${LANG[RE_INSTALLING]}" "$host")"
    export SSHPASS="$pass"
    sshpass -e ssh -p "$port" \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$RE_KNOWN_HOSTS" \
        -o PreferredAuthentications=password \
        -o PubkeyAuthentication=no \
        "$user@$host" \
        "mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && { grep -qF '$pubkey' ~/.ssh/authorized_keys || echo '$pubkey' >> ~/.ssh/authorized_keys; }"
    rc=$?
    unset SSHPASS pass

    # sshpass rc 5 means the password itself was rejected; anything else
    # (closed port, no password auth at all) shows the ssh error above.
    if [ "$rc" -eq 5 ]; then
        echo -e "${COLOR_RED}${LANG[RE_PASS_WRONG]}${COLOR_RESET}"
        return 1
    fi
    if [ "$rc" -ne 0 ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[RE_INSTALL_FAIL]}" "ssh rc=$rc")${COLOR_RESET}"
        return 1
    fi

    if re_try_key "$host" "$port" "$user" "$RE_KEY_FILE"; then
        step_ok "${LANG[RE_INSTALL_OK]}"
        return 0
    fi
    echo -e "${COLOR_RED}$(printf "${LANG[RE_INSTALL_FAIL]}" "${LANG[RE_VERIFY_FAIL]}")${COLOR_RESET}"
    return 1
}

re_setup_paste() {
    local host="$1" port="$2" user="$3" pubkey answer
    re_generate_key || return 1
    pubkey=$(re_pubkey) || return 1

    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[RE_PASTE_TITLE]}" "$host")${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_WHITE}${pubkey}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}$(printf "${LANG[RE_PASTE_CMD]}" "$host")${COLOR_RESET}"
    echo -e "${COLOR_WHITE}echo '$pubkey' >> ~/.ssh/authorized_keys${COLOR_RESET}"
    echo -e ""

    while true; do
        reading "${LANG[RE_PASTE_CHECK]}" answer
        [ "$answer" = "q" ] && return 1
        if re_try_key "$host" "$port" "$user" "$RE_KEY_FILE"; then
            step_ok "${LANG[RE_INSTALL_OK]}"
            return 0
        fi
        echo -e "${COLOR_YELLOW}${LANG[RE_TRYING_FAIL]}${COLOR_RESET}"
    done
}

# Bootstrap a target; an optional argument preseeds the address (server
# routing knows the bridge node's address and must not re-ask it).
re_bootstrap() {
    local host port user label candidate keys=() choice
    re_ensure_client || { echo -e "${COLOR_RED}${LANG[RE_NO_SSH]}${COLOR_RESET}"; return 1; }
    re_migrate_legacy

    if [ -n "${1:-}" ]; then
        RE_HOST="$1"
    else
        re_pick_host || { echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"; return 1; }
    fi
    host="$RE_HOST"

    reading "$(printf "${LANG[RE_PORT_PROMPT]}" 22)" port
    [ -n "$port" ] || port=22
    reading "$(printf "${LANG[RE_USER_PROMPT]}" root)" user
    [ -n "$user" ] || user=root
    # callers print the globals after a successful bootstrap (AN_SSH_OK),
    # and a failed re_target_load_by_host before us has just reset them
    RE_PORT="$port"
    RE_USER="$user"
    reading "${LANG[RE_LABEL_PROMPT]}" label
    label=$(re_clean_label "$label")

    step_do "${LANG[RE_TRYING]}"
    while IFS= read -r candidate; do
        keys+=("$candidate")
    done < <(re_candidate_keys)
    for candidate in "${keys[@]}"; do
        if re_try_key "$host" "$port" "$user" "$candidate"; then
            step_ok "$(printf "${LANG[RE_TRYING_OK]}" "$candidate")"
            re_target_write "$host" "$port" "$user" "$candidate" "$label"
            echo -e "${COLOR_GREEN}$(printf "${LANG[RE_SAVED]}" "$user" "$host" "$port")${COLOR_RESET}"
            return 0
        fi
    done
    echo -e "${COLOR_YELLOW}${LANG[RE_TRYING_FAIL]}${COLOR_RESET}"

    while true; do
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[RE_METHOD_TITLE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[RE_METHOD_CUSTOM]}${COLOR_RESET}"
        echo -e "    ${COLOR_GRAY}${LANG[RE_METHOD_CUSTOM_HINT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[RE_METHOD_PASSWORD]}${COLOR_RESET}"
        echo -e "    ${COLOR_GRAY}${LANG[RE_METHOD_PASSWORD_HINT]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[RE_METHOD_PASTE]}${COLOR_RESET}"
        echo -e "    ${COLOR_GRAY}${LANG[RE_METHOD_PASTE_HINT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 3)" choice

        case $choice in
            1)
                if re_setup_custom_key "$host" "$port" "$user"; then
                    re_target_write "$host" "$port" "$user" "$RE_PICKED_KEY" "$label"
                    echo -e "${COLOR_GREEN}$(printf "${LANG[RE_SAVED]}" "$user" "$host" "$port")${COLOR_RESET}"
                    return 0
                fi
                ;;
            2)
                if re_setup_password "$host" "$port" "$user"; then
                    re_target_write "$host" "$port" "$user" "$RE_KEY_FILE" "$label"
                    echo -e "${COLOR_GREEN}$(printf "${LANG[RE_SAVED]}" "$user" "$host" "$port")${COLOR_RESET}"
                    return 0
                fi
                ;;
            3)
                if re_setup_paste "$host" "$port" "$user"; then
                    re_target_write "$host" "$port" "$user" "$RE_KEY_FILE" "$label"
                    echo -e "${COLOR_GREEN}$(printf "${LANG[RE_SAVED]}" "$user" "$host" "$port")${COLOR_RESET}"
                    return 0
                fi
                ;;
            0)
                echo -e "${COLOR_YELLOW}${LANG[RE_CANCELLED]}${COLOR_RESET}"
                return 1
                ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 3
                sleep 1
                ;;
        esac
    done
}

# Run a command on the currently loaded target; output and exit code pass
# through. Callers either re_load_state() first or use re_run/re_run_host.
re_ssh_run() {
    re_is_configured || return 1
    re_ensure_dirs
    ssh -i "$RE_KEY" -p "$RE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$RE_KNOWN_HOSTS" \
        -o IdentitiesOnly=yes \
        "$RE_USER@$RE_HOST" "$@"
}

# Run on the active (last used) target.
re_run() {
    re_load_state
    re_ssh_run "$@"
}

# Run on the target bound to the given address; rc=2 when none is bound.
re_run_host() {
    local host="$1"
    shift
    re_migrate_legacy
    re_target_load_by_host "$host" || return 2
    re_ssh_run "$@"
}

# re_run_host with ssh -n: for remote commands that read no stdin (checks,
# status dumps, rule pushes). Keeps the CALLER's input stream intact — a
# plain re_run_host between interactive prompts eats the piped answers and every
# later read hits EOF. Data-shipping calls (cat > file, tar -xf -) must use
# re_run_host: -n would cut their payload.
re_run_host_n() {
    local host="$1"
    shift
    re_migrate_legacy
    re_target_load_by_host "$host" || return 2
    re_is_configured || return 1
    re_ensure_dirs
    ssh -n -i "$RE_KEY" -p "$RE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$RE_KNOWN_HOSTS" \
        -o IdentitiesOnly=yes \
        "$RE_USER@$RE_HOST" "$@"
}

# Ready for re_run? Bootstraps interactively when not.
re_require_access() {
    re_load_state
    re_is_configured && return 0
    re_bootstrap
}

# Ready for re_run_host <address>? Bootstraps for that exact address when no
# target is bound to it yet.
re_require_access_host() {
    re_migrate_legacy
    re_target_load_by_host "$1" && [ -f "$RE_KEY" ] && return 0
    re_bootstrap "$1"
}

# Remote Docker bootstrap script. Echoes the script text — run it with
# re_run_host. Mirrors install_packages from install_remnawave.sh:
# curl-or-wget download over get.docker.com plus the three proxy mirrors,
# shebang validation of what landed, an Aliyun-mirror retry of the script
# itself, and the distro docker.io only as the last resort. A minimal image
# with neither downloader gets curl from apt first. A fresh-boot host may be
# mid unattended-upgrades, so every apt here waits out the dpkg lock, and the
# update units get a graceful SIGTERM if it is still held after two minutes.
re_remote_docker_install() {
    cat <<'EOL'
if command -v docker >/dev/null 2>&1; then exit 0; fi
# make every apt on this box (incl. nested get.docker.com calls) wait for
# the dpkg lock instead of failing on it
mkdir -p /etc/apt/apt.conf.d 2>/dev/null
printf 'DPkg::Lock::Timeout "300";\n' > /etc/apt/apt.conf.d/99remnawave-lock-wait 2>/dev/null
lock_waited=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    [ "$lock_waited" -eq 0 ] && echo "automatic system updates are running, waiting for the dpkg lock (up to 2 min)"
    sleep 5
    lock_waited=$((lock_waited + 5))
    [ "$lock_waited" -ge 120 ] && break
done
if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
    echo "dpkg lock still held, asking system updates to stop (they resume on the next timer run)"
    systemctl kill --kill-who=all --signal=SIGTERM apt-daily.service apt-daily-upgrade.service unattended-upgrades.service >/dev/null 2>&1
    lock_waited=0
    while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
        sleep 5
        lock_waited=$((lock_waited + 5))
        [ "$lock_waited" -ge 120 ] && break
    done
    # finish a package half-configured by the SIGTERM (live-observed on grub-pc)
    dpkg --configure -a >/dev/null 2>&1 || true
fi
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
    apt-get -o DPkg::Lock::Timeout=300 update -y >/dev/null
    apt-get -o DPkg::Lock::Timeout=300 install -y docker.io docker-compose-v2 || apt-get -o DPkg::Lock::Timeout=300 install -y docker.io
fi
command -v docker >/dev/null 2>&1
EOL
}

# Rule chain for a remote ufw: installs ufw from apt when the box has none
# (a fresh minimal image has no package lists, the curl lesson) and then
# runs the rules. "required" exits 127 when ufw never appeared, so the ssh
# exit code tells the truth; "optional" (teardown) treats a missing ufw as
# nothing-to-do success.
re_remote_ufw_cmd() {
    local mode="$1" rules="$2"
    printf 'command -v ufw >/dev/null 2>&1 || { apt-get -o DPkg::Lock::Timeout=300 update -y >/dev/null 2>&1; apt-get -o DPkg::Lock::Timeout=300 install -y ufw >/dev/null 2>&1; }
if ! command -v ufw >/dev/null 2>&1; then
    if [ "%s" = required ]; then exit 127; else exit 0; fi
fi
%s' "$mode" "$rules"
}

re_test_connection() {
    local out
    if out=$(re_ssh_run "hostname" 2>&1); then
        step_ok "$(printf "${LANG[RE_TEST_OK]}" "$out")"
        return 0
    fi
    echo -e "${COLOR_RED}$(printf "${LANG[RE_TEST_FAIL]}" "$out")${COLOR_RESET}"
    return 1
}

re_run_menu() {
    local cmd rc
    reading "$(printf "${LANG[RE_CMD_PROMPT]}" "$RE_HOST")" cmd
    [ -z "$cmd" ] && return 0
    echo -e ""
    re_ssh_run "$cmd"
    rc=$?
    echo -e ""
    # A remote answer may legitimately be empty (an empty ls, a quiet service
    # reload) — a bare blank line reads as "nothing happened", so the outcome
    # is stated on success too.
    if [ "$rc" -eq 0 ]; then
        echo -e "${COLOR_GRAY}${LANG[RE_RUN_DONE]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}$(printf "${LANG[RE_RUN_FAIL]}" "$rc")${COLOR_RESET}"
    fi
    return 0
}

# Key kind for the status line: our service key vs the operator's own file.
re_key_kind() {
    if [ "$RE_KEY" = "$RE_KEY_FILE" ]; then
        echo "${LANG[RE_KEY_KIND_OWN]}"
    else
        printf "${LANG[RE_KEY_KIND_CUSTOM]}" "$RE_KEY"
    fi
}

# "(label)" suffix for list lines; empty when the machine has no name.
re_label_suffix() {
    [ -n "$RE_LABEL" ] && printf ' %s(%s)%s' "$COLOR_GRAY" "$RE_LABEL" "$COLOR_RESET"
    return 0
}

# Rewrite the loaded target with a new label; empty input drops the name.
re_rename_target() {
    local label
    reading "${LANG[RE_LABEL_PROMPT]}" label
    label=$(re_clean_label "$label")
    re_target_write "$RE_HOST" "$RE_PORT" "$RE_USER" "$RE_KEY" "$label" "${RE_OVERLAY:-}"
    RE_LABEL="$label"
    step_ok "${LANG[RE_RENAME_OK]}"
}

# Revoke the currently loaded target: drop our line on that box, forget the
# pairing. The shared local key survives while any other target still uses it.
re_revoke_target() {
    local host="$RE_HOST" name marker esc
    name=$(re_target_name "$RE_HOST" "$RE_PORT")

    if [ "$RE_KEY" = "$RE_KEY_FILE" ] && [ -s "$RE_KEY_FILE.pub" ]; then
        marker=$(awk '{print $3}' "$RE_KEY_FILE.pub")
        esc=${marker//./\\.}
        step_do "${LANG[RE_REVOKING]}"
        if ! re_ssh_run "sed -i '\\|${esc}|d' ~/.ssh/authorized_keys"; then
            rm -f "${RE_CONF_DIR}/${name}.target"
            [ "$(cat "$RE_ACTIVE_FILE" 2>/dev/null)" = "$name" ] && rm -f "$RE_ACTIVE_FILE"
            echo -e "${COLOR_YELLOW}$(printf "${LANG[RE_REVOKE_REMOTE_FAIL]}" "$host" "$marker")${COLOR_RESET}"
            return 1
        fi
    fi

    rm -f "${RE_CONF_DIR}/${name}.target"
    [ "$(cat "$RE_ACTIVE_FILE" 2>/dev/null)" = "$name" ] && rm -f "$RE_ACTIVE_FILE"

    # The key dir also holds known_hosts with every target's baseline; it goes
    # only when the last target is gone — wiping it early makes the next
    # accept-new silently trust a changed host key on machines still paired.
    if ! compgen -G "${RE_CONF_DIR}/*.target" >/dev/null; then
        rm -rf "$RE_KEY_DIR"
    fi
    step_ok "${LANG[RE_REVOKE_OK]}"
    return 0
}

show_remote_exec_menu() {
    re_migrate_legacy
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[RE_TITLE]}${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}${LANG[RE_DOC_LINK]}${COLOR_RESET}"
    echo -e ""

    local names=() name pick i
    while IFS= read -r name; do
        [ -n "$name" ] && names+=("$name")
    done < <(re_targets_list)

    if [ "${#names[@]}" -eq 0 ]; then
        echo -e " ${COLOR_GRAY}${LANG[RE_STATUS_NOT_CONFIGURED]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[RE_SETUP]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 1)" REMOTE_EXEC_OPTION

        case $REMOTE_EXEC_OPTION in
            1)
                re_bootstrap
                sleep 2
                show_remote_exec_menu
                ;;
            0)
                return 0
                ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 1
                sleep 1
                show_remote_exec_menu
                ;;
        esac
        return 0
    fi

    echo -e " ${COLOR_GRAY}$(printf "${LANG[RE_TARGETS_COUNT]}" "${#names[@]}")${COLOR_RESET}"
    echo -e ""
    i=1
    for name in "${names[@]}"; do
        if re_target_load "$name"; then
            echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${RE_USER}@${RE_HOST}:${RE_PORT}${COLOR_RESET}$(re_label_suffix) ${COLOR_GRAY}($(re_key_kind))${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${name}${COLOR_RESET}"
        fi
        i=$((i + 1))
    done
    local new=$i
    echo -e "${COLOR_YELLOW}${new}. ${LANG[RE_NEW_TARGET]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$new")" REMOTE_EXEC_OPTION

    case $REMOTE_EXEC_OPTION in
        0)
            return 0
            ;;
        "$new")
            re_bootstrap
            sleep 2
            show_remote_exec_menu
            ;;
        *)
            if [ "$REMOTE_EXEC_OPTION" -ge 1 ] 2>/dev/null && [ "$REMOTE_EXEC_OPTION" -le "${#names[@]}" ]; then
                re_target_menu "${names[$((REMOTE_EXEC_OPTION - 1))]}"
                sleep 1
                show_remote_exec_menu
            else
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$new"
                sleep 1
                show_remote_exec_menu
            fi
            ;;
    esac
}

re_target_menu() {
    local name="$1"
    re_target_load "$name" || return 1
    printf '%s\n' "$name" > "$RE_ACTIVE_FILE"

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[RE_TITLE]}${COLOR_RESET}"
    echo -e ""
    if [ -n "$RE_LABEL" ]; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[RE_STATUS_LABEL]}" "$RE_LABEL")${COLOR_RESET}"
    fi
    echo -e " ${COLOR_GRAY}$(printf "${LANG[RE_STATUS_READY]}" "$RE_USER" "$RE_HOST" "$RE_PORT")${COLOR_RESET}"
    echo -e " ${COLOR_GRAY}$(printf "${LANG[RE_STATUS_KEY]}" "$(re_key_kind)")${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[RE_TEST]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[RE_RUN]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[RE_RENAME]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[RE_RECONFIGURE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[RE_REVOKE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 5)" REMOTE_EXEC_OPTION

    case $REMOTE_EXEC_OPTION in
        1)
            re_test_connection
            sleep 2
            re_target_menu "$name"
            ;;
        2)
            re_run_menu
            echo -e "${COLOR_GRAY}${LANG[RE_RUN_RETURN_HINT]}${COLOR_RESET}"
            read -rp ""
            re_target_menu "$name"
            ;;
        3)
            re_rename_target
            sleep 1
            re_target_menu "$name"
            ;;
        4)
            # The address may change during reconfiguration, so the flow
            # returns to the machine list instead of this (possibly stale) name.
            re_bootstrap
            sleep 2
            ;;
        5)
            echo -e "    ${COLOR_GRAY}${LANG[RE_REVOKE_HINT]}${COLOR_RESET}"
            if reading_yn "$(printf "${LANG[RE_REVOKE_CONFIRM]}" "$RE_HOST")" confirm_revoke; then
                re_revoke_target
            fi
            sleep 2
            ;;
        0)
            return 0
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 5
            sleep 1
            re_target_menu "$name"
            ;;
    esac
}

manage_remote_exec() {
    show_remote_exec_menu
}
