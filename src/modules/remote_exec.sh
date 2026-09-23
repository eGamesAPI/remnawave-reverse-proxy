#!/bin/bash
# Module: remote_exec — SSH access

RE_STATE_FILE="${DIR_REMNAWAVE}remote-exec.state"
RE_KEY_DIR="${DIR_REMNAWAVE}ssh"
RE_KEY_FILE="${RE_KEY_DIR}/id_ed25519"
RE_KNOWN_HOSTS="${RE_KEY_DIR}/known_hosts"

re_state_get() {
    [ -r "$RE_STATE_FILE" ] || return 0
    sed -n "s|^$1=||p" "$RE_STATE_FILE" | head -n1
}

re_state_write() {
    printf 'host=%s\nport=%s\nuser=%s\nkey=%s\n' "$1" "$2" "$3" "$4" > "$RE_STATE_FILE"
    chmod 600 "$RE_STATE_FILE" 2>/dev/null
}

re_load_state() {
    RE_HOST=$(re_state_get host)
    RE_PORT=$(re_state_get port)
    [ -n "$RE_PORT" ] || RE_PORT=22
    RE_USER=$(re_state_get user)
    [ -n "$RE_USER" ] || RE_USER=root
    RE_KEY=$(re_state_get key)
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
re_key_comment() {
    local domain
    domain=$(sed -n 's/^PANEL_DOMAIN=//p' /opt/remnawave/.env 2>/dev/null | head -n1 | tr -d '"')
    echo "remnawave-reverse-proxy@${domain:-$(hostname)}"
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
re_try_key() {
    local host="$1" port="$2" user="$3" key="$4"
    [ -r "$key" ] || return 1
    re_ensure_dirs
    ssh -i "$key" -p "$port" \
        -o BatchMode=yes \
        -o ConnectTimeout=8 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$RE_KNOWN_HOSTS" \
        -o IdentitiesOnly=yes \
        "$user@$host" true >/dev/null 2>&1
}

# Keys worth probing, most specific first; deduped, missing files skipped.
re_candidate_keys() {
    {
        re_state_get key
        printf '%s\n' "$RE_KEY_FILE"
        printf '%s\n' /root/.ssh/id_ed25519 /root/.ssh/id_ecdsa /root/.ssh/id_rsa
    } | awk 'NF && !seen[$0]++'
}

# "name<TAB>address" per node, from the saved panel token only — a dead token
# or a node-only box falls back to manual address entry without any prompt.
re_panel_nodes() {
    local token_file="${DIR_REMNAWAVE}token" response
    [ -r "$token_file" ] || return 1
    response=$(make_api_request "GET" "http://127.0.0.1:3000/api/nodes?_=$(date +%s)" "$(cat "$token_file")" 2>/dev/null)
    echo "$response" | jq -r '.response[]? | "\(.name)\t\(.address)"' 2>/dev/null | awk 'NF'
}

reading_hidden() {
    printf ' %s' "$(question "$1")"
    read -rs "$2"
    echo ""
}

# Sets RE_HOST. Panel node list as numbered picks, manual entry as the
# fallback (and the only option without a panel).
re_pick_host() {
    local entries=() entry name address pick last
    if panel_is_installed && command -v jq >/dev/null 2>&1 && load_api_module; then
        mapfile -t entries < <(re_panel_nodes)
    fi

    if [ "${#entries[@]}" -eq 0 ]; then
        reading "${LANG[RE_HOST_PROMPT]}" RE_HOST
        return
    fi

    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[RE_NODES_TITLE]}${COLOR_RESET}"
    echo -e ""
    local i=1
    for entry in "${entries[@]}"; do
        name="${entry%%$'\t'*}"
        address="${entry##*$'\t'}"
        echo -e "${COLOR_YELLOW}${i}. ${COLOR_WHITE}${address}${COLOR_RESET} ${COLOR_GRAY}(${name})${COLOR_RESET}"
        i=$((i + 1))
    done
    last=$i
    echo -e "${COLOR_YELLOW}${last}. ${LANG[RE_NODES_MANUAL]}${COLOR_RESET}"
    echo -e ""
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" pick
    [ -z "$pick" ] && pick=1

    if [ "$pick" = "$last" ]; then
        reading "${LANG[RE_HOST_PROMPT]}" RE_HOST
        return
    fi
    if [ "$pick" -ge 1 ] 2>/dev/null && [ "$pick" -le "${#entries[@]}" ]; then
        RE_HOST="${entries[$((pick - 1))]##*$'\t'}"
        return
    fi
    printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
    sleep 1
    re_pick_host
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

re_bootstrap() {
    local host port user candidate keys=() choice
    re_ensure_client || { echo -e "${COLOR_RED}${LANG[RE_NO_SSH]}${COLOR_RESET}"; return 1; }

    RE_HOST=""
    while [ -z "$RE_HOST" ]; do
        re_pick_host
    done
    host="$RE_HOST"

    reading "$(printf "${LANG[RE_PORT_PROMPT]}" 22)" port
    [ -n "$port" ] || port=22
    reading "$(printf "${LANG[RE_USER_PROMPT]}" root)" user
    [ -n "$user" ] || user=root

    step_do "${LANG[RE_TRYING]}"
    while IFS= read -r candidate; do
        keys+=("$candidate")
    done < <(re_candidate_keys)
    for candidate in "${keys[@]}"; do
        if re_try_key "$host" "$port" "$user" "$candidate"; then
            step_ok "$(printf "${LANG[RE_TRYING_OK]}" "$candidate")"
            re_state_write "$host" "$port" "$user" "$candidate"
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
                    re_state_write "$host" "$port" "$user" "$RE_PICKED_KEY"
                    echo -e "${COLOR_GREEN}$(printf "${LANG[RE_SAVED]}" "$user" "$host" "$port")${COLOR_RESET}"
                    return 0
                fi
                ;;
            2)
                if re_setup_password "$host" "$port" "$user"; then
                    re_state_write "$host" "$port" "$user" "$RE_KEY_FILE"
                    echo -e "${COLOR_GREEN}$(printf "${LANG[RE_SAVED]}" "$user" "$host" "$port")${COLOR_RESET}"
                    return 0
                fi
                ;;
            3)
                if re_setup_paste "$host" "$port" "$user"; then
                    re_state_write "$host" "$port" "$user" "$RE_KEY_FILE"
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

# Run a command on the configured box; output and exit code pass through.
re_run() {
    re_load_state
    re_is_configured || return 1
    re_ensure_dirs
    ssh -i "$RE_KEY" -p "$RE_PORT" \
        -o BatchMode=yes \
        -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$RE_KNOWN_HOSTS" \
        -o IdentitiesOnly=yes \
        "$RE_USER@$RE_HOST" "$@"
}

# Ready for re_run? Bootstraps interactively when not, so a caller (server
# routing) can simply do: re_require_access || bail.
re_require_access() {
    re_load_state
    re_is_configured && return 0
    re_bootstrap
}

re_test_connection() {
    local out
    if out=$(re_run "hostname" 2>&1); then
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
    re_run "$cmd"
    rc=$?
    echo -e ""
    [ "$rc" -eq 0 ] || echo -e "${COLOR_RED}$(printf "${LANG[RE_RUN_FAIL]}" "$rc")${COLOR_RESET}"
    return 0
}

re_revoke() {
    local host="$RE_HOST" marker esc
    # Only our own key ever added a line remotely; a custom-key setup just
    # forgets the pairing.
    if [ "$RE_KEY" = "$RE_KEY_FILE" ] && [ -s "$RE_KEY_FILE.pub" ]; then
        marker=$(awk '{print $3}' "$RE_KEY_FILE.pub")
        esc=${marker//./\\.}
        step_do "${LANG[RE_REVOKING]}"
        if ! re_run "sed -i '\\|${esc}|d' ~/.ssh/authorized_keys"; then
            rm -rf "$RE_KEY_DIR"
            rm -f "$RE_STATE_FILE"
            echo -e "${COLOR_YELLOW}$(printf "${LANG[RE_REVOKE_REMOTE_FAIL]}" "$host" "$marker")${COLOR_RESET}"
            return 1
        fi
    fi
    rm -rf "$RE_KEY_DIR"
    rm -f "$RE_STATE_FILE"
    step_ok "${LANG[RE_REVOKE_OK]}"
    return 0
}

show_remote_exec_menu() {
    re_load_state
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[RE_TITLE]}${COLOR_RESET}"
    echo -e ""

    if re_is_configured; then
        echo -e " ${COLOR_GRAY}$(printf "${LANG[RE_STATUS_READY]}" "$RE_USER" "$RE_HOST" "$RE_PORT")${COLOR_RESET}"
        echo -e " ${COLOR_GRAY}$(printf "${LANG[RE_STATUS_KEY]}" "$RE_KEY")${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[RE_TEST]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[RE_RUN]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[RE_RECONFIGURE]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}4. ${LANG[RE_REVOKE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" 4)" REMOTE_EXEC_OPTION

        case $REMOTE_EXEC_OPTION in
            1)
                re_test_connection
                sleep 2
                show_remote_exec_menu
                ;;
            2)
                re_run_menu
                echo -e "${COLOR_GRAY}${LANG[RE_RUN_RETURN_HINT]}${COLOR_RESET}"
                read -rp ""
                show_remote_exec_menu
                ;;
            3)
                re_bootstrap
                sleep 2
                show_remote_exec_menu
                ;;
            4)
                if reading_yn "$(printf "${LANG[RE_REVOKE_CONFIRM]}" "$RE_HOST")" confirm_revoke; then
                    re_revoke
                fi
                sleep 2
                show_remote_exec_menu
                ;;
            0)
                return 0
                ;;
            *)
                printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" 4
                sleep 1
                show_remote_exec_menu
                ;;
        esac
    else
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
    fi
}

manage_remote_exec() {
    show_remote_exec_menu
}
