#!/bin/bash
# Module: Xray core for the node — official XTLS build or the Jolymmiles
# server-focused fork, installed as a bind-mount over the bundled binary.
# Works purely on the host (docker compose), no panel API involved.

XC_STATE_FILE="${DIR_REMNAWAVE}xray-core.state"
XC_BINARY_NAME="xray-core"
XC_MOUNT="./${XC_BINARY_NAME}:/usr/local/bin/xray"

# Known-good pins used when api.github.com is unreachable.
XC_PIN_off="v26.9.9"
XC_PIN_joly="v26.9.5-0936"

xc_repo_of() {
    case "$1" in
        off)  echo "XTLS/Xray-core" ;;
        joly) echo "Jolymmiles/Xray-core" ;;
    esac
}

xc_source_name() {
    case "$1" in
        off)  echo "XTLS (официальное)" ;;
        joly) echo "Jolymmiles (форк)" ;;
    esac
}

# Directory holding the compose file with the remnanode service.
xc_core_dir() {
    local dir compose
    for dir in /opt/remnanode /opt/remnawave; do
        compose="$dir/docker-compose.yml"
        if [ -f "$compose" ] && grep -q "^[[:space:]]*remnanode:" "$compose"; then
            echo "$dir"
            return 0
        fi
    done
    return 1
}

xc_state_get() {
    [ -r "$XC_STATE_FILE" ] || return 0
    sed -n "s|^$1=||p" "$XC_STATE_FILE" | head -n1
}

xc_state_set() {
    printf 'source=%s\nversion=%s\n' "$1" "$2" > "$XC_STATE_FILE"
    chmod 600 "$XC_STATE_FILE" 2>/dev/null
}

xc_state_clear() {
    rm -f "$XC_STATE_FILE"
}

# Latest release tag (releases list, so fork build-suffixed tags count too).
# No jq dependency: node-only boxes may not have it.
xc_latest_tag() {
    local repo="$1"
    curl -fsSL --connect-timeout 8 --max-time 15 \
        "https://api.github.com/repos/${repo}/releases?per_page=1" 2>/dev/null \
        | sed -n 's/.*"tag_name":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# Resolve the newest tag for a source; prints the tag, rc=1 when the pinned
# fallback was used because GitHub API is unreachable.
xc_resolve_tag() {
    local source="$1" tag
    tag=$(xc_latest_tag "$(xc_repo_of "$source")")
    if [ -n "$tag" ]; then
        echo "$tag"
        return 0
    fi
    eval echo "\"\$XC_PIN_${source}\""
    return 1
}

# Does the tag exist as a release? rc=2 = could not check (offline).
xc_tag_exists() {
    local repo="$1" tag="$2" code
    code=$(curl -sL -o /dev/null -w "%{http_code}" --connect-timeout 8 --max-time 15 \
        "https://api.github.com/repos/${repo}/releases/tags/${tag}" 2>/dev/null)
    [ "$code" = "200" ] && return 0
    [ "$code" = "000" ] && return 2
    return 1
}

xc_asset_name() {
    case "$(uname -m)" in
        x86_64|amd64) echo "Xray-linux-64.zip" ;;
        aarch64|arm64) echo "Xray-linux-arm64-v8a.zip" ;;
        armv7l|armv7)  echo "Xray-linux-arm32-v7a.zip" ;;
        armv6l)        echo "Xray-linux-arm32-v6.zip" ;;
        i386|i686)     echo "Xray-linux-32.zip" ;;
        *) return 1 ;;
    esac
}

# Mirror prefixes for github.com release downloads — same chain the script
# uses everywhere; GitHub is often unreachable from RU networks.
xc_mirror_prefixes() {
    printf '%s\n' "" "https://gh-proxy.com/" "https://ghfast.top/" "https://ghproxy.net/"
}

# One URL over all mirrors, written straight to a file. The core is a binary
# zip — it must never pass through a command substitution, bash strips null
# bytes there and corrupts the archive.
xc_fetch_file() {
    local url="$1" dest="$2" prefix
    while IFS= read -r prefix; do
        if command -v curl >/dev/null 2>&1; then
            if curl -fsSL $CURL_IP_FLAGS --connect-timeout 10 --max-time 300 -o "$dest" "${prefix}${url}" 2>/dev/null && [ -s "$dest" ]; then
                return 0
            fi
        else
            if wget $WGET_IP_FLAGS -q -T 20 -t 1 -O "$dest" "${prefix}${url}" 2>/dev/null && [ -s "$dest" ]; then
                return 0
            fi
        fi
    done < <(xc_mirror_prefixes)
    return 1
}

xc_backup_compose() {
    local compose="$1" bak stamp
    stamp=$(date +%Y%m%d-%H%M%S 2>/dev/null || echo manual)
    bak="${compose}.bak-${stamp}"
    cp -p "$compose" "$bak" 2>/dev/null || return 1
    XC_LAST_BACKUP="$bak"
    ls -1t "${compose}".bak-* 2>/dev/null | tail -n +6 | while IFS= read -r old; do
        rm -f "$old" 2>/dev/null
    done
    return 0
}

xc_compose_valid() {
    local dir="$1"
    ( cd "$dir" && docker compose config -q ) >/dev/null 2>&1
}

# Add the bind-mount to the remnanode service. Our own templates always have
# a /dev/shm volume inside the node service, so the insertion anchors on the
# first /dev/shm line seen after the remnanode: marker; indentation is taken
# from that very line.
xc_add_mount() {
    local compose="$1" tmp
    grep -q -- "$XC_MOUNT" "$compose" && return 0
    tmp=$(mktemp) || return 1
    awk -v mount="$XC_MOUNT" '
        { print }
        !done && in_node && $0 ~ /- \/dev\/shm:\/dev\/shm/ {
            match($0, /^[[:space:]]*/)
            pad = substr($0, RSTART, RLENGTH)
            print pad "- " mount
            done = 1
        }
        /^[[:space:]]*remnanode:[[:space:]]*$/ { in_node = 1 }
    ' "$compose" > "$tmp"
    if ! grep -q -- "$XC_MOUNT" "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv "$tmp" "$compose"
    return 0
}

xc_remove_mount() {
    local compose="$1"
    sed -i "\|${XC_MOUNT}|d" "$compose"
}

# Download the release, verify SHA256 from .dgst, unpack and install the
# binary next to the compose file.
xc_download_core() {
    local dir="$1" source="$2" tag="$3"
    local repo asset base tmpd want have
    repo=$(xc_repo_of "$source")
    asset=$(xc_asset_name) || {
        echo -e "${COLOR_RED}$(printf "${LANG[XC_ARCH_UNSUPPORTED]}" "$(uname -m)")${COLOR_RESET}"
        return 1
    }
    base="https://github.com/${repo}/releases/download/${tag}"

    step_do "$(printf "${LANG[XC_DOWNLOADING]}" "$tag" "$asset")"
    tmpd=$(mktemp -d) || return 1

    if ! xc_fetch_file "$base/$asset" "$tmpd/core.zip"; then
        echo -e "${COLOR_RED}${LANG[XC_DOWNLOAD_FAILED]}${COLOR_RESET}"
        rm -rf "$tmpd"
        return 1
    fi

    # SHA2-256 from the .dgst sidecar when it is served
    if xc_fetch_file "$base/${asset}.dgst" "$tmpd/core.dgst" && [ -s "$tmpd/core.dgst" ]; then
        want=$(sed -n 's/^SHA2-256=//p' "$tmpd/core.dgst" | head -n1 | tr -d ' ')
        have=$(sha256sum "$tmpd/core.zip" 2>/dev/null | cut -d' ' -f1)
        if [ -n "$want" ] && [ "$want" != "$have" ]; then
            echo -e "${COLOR_RED}${LANG[XC_CHECKSUM_FAILED]}${COLOR_RESET}"
            rm -rf "$tmpd"
            return 1
        fi
        [ -n "$want" ] && echo -e "${COLOR_GREEN}${LANG[XC_CHECKSUM_OK]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[XC_CHECKSUM_SKIP]}${COLOR_RESET}"
    fi

    if ! unzip -qo "$tmpd/core.zip" xray -d "$tmpd" 2>/dev/null; then
        echo -e "${COLOR_RED}${LANG[XC_UNPACK_FAILED]}${COLOR_RESET}"
        rm -rf "$tmpd"
        return 1
    fi
    if ! head -c 4 "$tmpd/xray" 2>/dev/null | grep -q "ELF"; then
        echo -e "${COLOR_RED}${LANG[XC_UNPACK_FAILED]}${COLOR_RESET}"
        rm -rf "$tmpd"
        return 1
    fi

    install -m 755 "$tmpd/xray" "$dir/$XC_BINARY_NAME" || { rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"
    return 0
}

# Install a given source+tag end to end: download, mount, recreate the node.
xc_install_core() {
    local source="$1" tag="$2" confirm
    local dir compose was_valid

    dir=$(xc_core_dir) || {
        echo -e "${COLOR_YELLOW}${LANG[XC_NO_NODE]}${COLOR_RESET}"
        return 1
    }
    compose="$dir/docker-compose.yml"

    echo ""
    if ! reading_yn "$(printf "${LANG[XC_WARNING]}" "$(xc_source_name "$source")" "$tag")" confirm; then
        return 0
    fi

    xc_download_core "$dir" "$source" "$tag" || return 1

    xc_compose_valid "$dir"; was_valid=$?
    xc_backup_compose "$compose"
    if ! xc_add_mount "$compose"; then
        echo -e "${COLOR_RED}${LANG[XC_MOUNT_FAILED]}${COLOR_RESET}"
        rm -f "$dir/$XC_BINARY_NAME"
        return 1
    fi
    if [ "$was_valid" = "0" ] && ! xc_compose_valid "$dir"; then
        [ -n "$XC_LAST_BACKUP" ] && cp -p "$XC_LAST_BACKUP" "$compose"
        echo -e "${COLOR_RED}${LANG[XC_COMPOSE_ROLLED_BACK]}${COLOR_RESET}"
        rm -f "$dir/$XC_BINARY_NAME"
        return 1
    fi

    xc_state_set "$source" "$tag"

    step_do "${LANG[XC_APPLYING]}"
    ( cd "$dir" && docker compose up -d remnanode ) > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"

    local running
    running=$(docker exec remnanode xray version 2>/dev/null | head -n1)
    if [ -n "$running" ]; then
        step_ok "$(printf "${LANG[XC_INSTALLED_OK]}" "$(xc_source_name "$source")" "$tag")"
    else
        echo -e "${COLOR_YELLOW}$(printf "${LANG[XC_INSTALLED_NORUN]}" "$(xc_source_name "$source")" "$tag")${COLOR_RESET}"
    fi
    return 0
}

xc_restore_core() {
    local dir compose confirm
    dir=$(xc_core_dir) || {
        echo -e "${COLOR_YELLOW}${LANG[XC_NO_NODE]}${COLOR_RESET}"
        return 1
    }
    compose="$dir/docker-compose.yml"

    if ! grep -q -- "$XC_MOUNT" "$compose"; then
        echo -e "${COLOR_YELLOW}${LANG[XC_RESTORE_NOTHING]}${COLOR_RESET}"
        return 0
    fi
    if ! reading_yn "${LANG[XC_RESTORE_CONFIRM]}" confirm; then
        return 0
    fi

    xc_backup_compose "$compose"
    xc_remove_mount "$compose"
    rm -f "$dir/$XC_BINARY_NAME"
    xc_state_clear

    step_do "${LANG[XC_APPLYING]}"
    ( cd "$dir" && docker compose up -d remnanode ) > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    step_ok "${LANG[XC_RESTORED_OK]}"
}

xc_print_status() {
    local dir mount_present running installed_source installed_tag
    dir=$(xc_core_dir) || {
        echo -e "${COLOR_YELLOW}${LANG[XC_NO_NODE]}${COLOR_RESET}"
        return 1
    }
    mount_present=false
    grep -q -- "$XC_MOUNT" "$dir/docker-compose.yml" 2>/dev/null && mount_present=true
    installed_source=$(xc_state_get "source")
    installed_tag=$(xc_state_get "version")

    if [ "$mount_present" = true ] && [ -n "$installed_tag" ]; then
        echo -e " $(printf "${LANG[XC_STATUS_INSTALLED]}" "$(xc_source_name "$installed_source")" "$installed_tag")"
    else
        echo -e " ${COLOR_GRAY}${LANG[XC_STATUS_BUNDLED]}${COLOR_RESET}"
    fi
    running=$(docker exec remnanode xray version 2>/dev/null | head -n1)
    [ -n "$running" ] && echo -e " ${COLOR_GRAY}$(printf "${LANG[XC_STATUS_RUNNING]}" "$running")${COLOR_RESET}"
}

show_xray_core_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[XC_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    xc_print_status
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[XC_SOURCE_OFF]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[XC_SOURCE_JOLY]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[XC_MANUAL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[XC_UPDATE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[XC_RESTORE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    local last=5 xc_option
    reading "$(printf "${LANG[MANAGE_PANEL_NODE_PROMPT]}" "$last")" xc_option

    local source tag
    case $xc_option in
        1|2)
            [ "$xc_option" = "1" ] && source="off" || source="joly"
            step_do "${LANG[XC_RESOLVING]}"
            if tag=$(xc_resolve_tag "$source"); then
                echo -e "${COLOR_GREEN}$(printf "${LANG[XC_LATEST_FOUND]}" "$tag")${COLOR_RESET}"
            else
                echo -e "${COLOR_YELLOW}$(printf "${LANG[XC_LATEST_FAILED]}" "$tag")${COLOR_RESET}"
            fi
            xc_install_core "$source" "$tag"
            sleep 2
            show_xray_core_menu
            ;;
        3)
            xc_install_manual
            sleep 2
            show_xray_core_menu
            ;;
        4)
            xc_update_core
            sleep 2
            show_xray_core_menu
            ;;
        5)
            xc_restore_core
            sleep 2
            show_xray_core_menu
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            printf "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}\n" "$last"
            sleep 1
            show_xray_core_menu
            ;;
    esac
}

xc_install_manual() {
    local source xc_input repo rc
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[XC_SOURCE_OFF_NAME]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[XC_SOURCE_JOLY_NAME]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[XC_MANUAL_SOURCE_PROMPT]}" source_num
    case $source_num in
        1) source="off" ;;
        2) source="joly" ;;
        *) return 0 ;;
    esac
    reading "${LANG[XC_MANUAL_PROMPT]}" xc_input || return 0
    [ -z "$xc_input" ] && return 0

    repo=$(xc_repo_of "$source")
    xc_tag_exists "$repo" "$xc_input"
    rc=$?
    if [ "$rc" = "1" ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[XC_MANUAL_INVALID]}" "$xc_input")${COLOR_RESET}"
        return 1
    fi
    if [ "$rc" = "2" ]; then
        echo -e "${COLOR_YELLOW}${LANG[XC_MANUAL_UNCHECKED]}${COLOR_RESET}"
    fi
    xc_install_core "$source" "$xc_input"
}

xc_update_core() {
    local source current tag
    source=$(xc_state_get "source")
    current=$(xc_state_get "version")
    if [ -z "$source" ] || [ -z "$current" ]; then
        echo -e "${COLOR_YELLOW}${LANG[XC_UPDATE_NONE]}${COLOR_RESET}"
        return 0
    fi
    step_do "${LANG[XC_RESOLVING]}"
    if ! tag=$(xc_resolve_tag "$source"); then
        echo -e "${COLOR_YELLOW}$(printf "${LANG[XC_LATEST_FAILED]}" "$tag")${COLOR_RESET}"
    fi
    if [ "$tag" = "$current" ]; then
        echo -e "${COLOR_GREEN}$(printf "${LANG[XC_UPDATE_SAME]}" "$current")${COLOR_RESET}"
        return 0
    fi
    xc_install_core "$source" "$tag"
}

manage_xray_core() {
    if ! xc_core_dir >/dev/null; then
        echo -e "${COLOR_YELLOW}${LANG[XC_NO_NODE]}${COLOR_RESET}"
        sleep 2
        return
    fi
    show_xray_core_menu
}
