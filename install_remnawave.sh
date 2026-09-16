#!/bin/bash
SCRIPT_VERSION="Dev 3.3.7"
UPDATE_AVAILABLE=false
DIR_REMNAWAVE="/usr/local/remnawave_reverse/"
LANG_FILE="${DIR_REMNAWAVE}selected_language"

# Where this script and its modules/languages are downloaded from.
# Flip SOURCE_BRANCH to "dev" to point every download at the development
# branch at once — no other URL in this file mentions the branch.
SOURCE_REPO="eGamesAPI/remnawave-reverse-proxy"
SOURCE_BRANCH="main"
SOURCE_BASE_URL="https://raw.githubusercontent.com/${SOURCE_REPO}/refs/heads/${SOURCE_BRANCH}"

SCRIPT_URL="${SOURCE_BASE_URL}/install_remnawave.sh"
LANG_BASE_URL="${SOURCE_BASE_URL}/src/lang"

# The module and language cache under DIR_REMNAWAVE belongs to one version of
# this script. Sourcing files an older release left behind would run code this
# version was never tested against, so the cache carries a stamp.
SOURCE_STAMP_FILE="${DIR_REMNAWAVE}source"
SOURCE_STAMP="$SCRIPT_VERSION"

# A src/ directory next to this script wins over the network, so a change can
# be run before it is pushed. Empty when the script runs from /usr/local/bin.
LOCAL_SRC_DIR=""
if [ -n "${BASH_SOURCE[0]}" ]; then
    _self_dir="$(cd -- "$(dirname -- "$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)"
    [ -d "${_self_dir}/src" ] && LOCAL_SRC_DIR="${_self_dir}/src"
    unset _self_dir
fi

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_WHITE="\033[1;37m"
COLOR_RED="\033[1;31m"
COLOR_GRAY='\033[0;90m'

CURL_IP_FLAGS=""
WGET_IP_FLAGS=""
detect_broken_ipv6() {
    command -v curl >/dev/null 2>&1 || return 0
    if curl -6 -s --connect-timeout 5 --max-time 8 -o /dev/null https://api64.ipify.org 2>/dev/null; then
        return 0
    fi
    CURL_IP_FLAGS="-4"
    WGET_IP_FLAGS="-4"
}

# Mirror URLs for a raw.githubusercontent file URL: the original first, then
# public proxies; the branch part is stripped from the original URL so every
# mirror follows SOURCE_BRANCH too.
script_mirror_urls() {
    local file_url="$1"
    printf '%s\n' \
        "$file_url" \
        "https://cdn.jsdelivr.net/gh/${SOURCE_REPO}@${SOURCE_BRANCH}/${file_url#*${SOURCE_BRANCH}/}" \
        "https://raw.githack.com/${SOURCE_REPO}/${SOURCE_BRANCH}/${file_url#*${SOURCE_BRANCH}/}" \
        "https://gh-proxy.com/${file_url}"
}

# SCRIPT_VERSION from the remote install script, tried over every mirror and
# with both curl and wget. A box that cannot reach raw.githubusercontent.com
# must still learn that an update exists.
fetch_remote_script_version() {
    local mirrors mirror head version
    mapfile -t mirrors < <(script_mirror_urls "$SCRIPT_URL")

    for mirror in "${mirrors[@]}"; do
        head=""
        if command -v curl >/dev/null 2>&1; then
            head=$(curl -sL $CURL_IP_FLAGS --connect-timeout 10 --max-time 20 "$mirror" 2>/dev/null | head -n 5)
        elif command -v wget >/dev/null 2>&1; then
            head=$(wget $WGET_IP_FLAGS -q -T 10 -t 1 -O- "$mirror" 2>/dev/null | head -n 5)
        else
            return 1
        fi
        version=$(printf '%s\n' "$head" | grep -m 1 '^SCRIPT_VERSION=' | cut -d'"' -f2)
        if [ -n "$version" ]; then
            echo "$version"
            return 0
        fi
    done
    return 1
}

# Download file with multiple mirrors and validation
download_with_mirrors() {
    local file_url="$1"
    local dest_file="$2"
    local file_type="${3:-script}"  # script, lang, module
    
    local mirrors
    mapfile -t mirrors < <(script_mirror_urls "$file_url")

    local temp_file="${dest_file}.tmp"
    local download_success=false
    local http_code=""
    
    # Try each mirror
    for mirror_url in "${mirrors[@]}"; do
        if command -v curl &> /dev/null; then
            http_code=$(curl -sL $CURL_IP_FLAGS -w "%{http_code}" --connect-timeout 10 --max-time 30 "$mirror_url" -o "$temp_file" 2>/dev/null)
            if [ "$http_code" = "200" ] && [ -s "$temp_file" ]; then
                # Validate file content
                if validate_downloaded_file "$temp_file" "$file_type"; then
                    download_success=true
                    break
                fi
            fi
        elif command -v wget &> /dev/null; then
            if wget $WGET_IP_FLAGS -q --timeout=10 --tries=1 "$mirror_url" -O "$temp_file" 2>/dev/null; then
                if [ -s "$temp_file" ]; then
                    # Validate file content
                    if validate_downloaded_file "$temp_file" "$file_type"; then
                        download_success=true
                        break
                    fi
                fi
            fi
        fi
    done
    
    if [ "$download_success" = "true" ]; then
        mv "$temp_file" "$dest_file"
        rm -f "${dest_file}.bak"
        return 0
    else
        rm -f "$temp_file"
        return 1
    fi
}

# Validate downloaded file content
validate_downloaded_file() {
    local file="$1"
    local file_type="$2"
    
    if [ ! -s "$file" ]; then
        return 1
    fi
    
    # Our own sources start with the bash shebang, and an HTML error page never
    # does. Decide on that first: the heuristics below grep for strings this
    # script itself contains ("404"/"Not Found", "Terms of Service"/"scraping"),
    # so running them over a genuine install_remnawave.sh rejected every copy.
    if [[ "$file_type" == "script" ]] || [[ "$file_type" == "lang" ]] || [[ "$file_type" == "module" ]]; then
        if ! head -1 "$file" | grep -q "^#!/bin/bash"; then
            return 1
        fi
        if [ "$file_type" = "lang" ] && ! grep -q "declare -gA LANG" "$file"; then
            return 1
        fi
        return 0
    fi
    
    # Check for HTTP error responses or rate limit errors
    if grep -q "429" "$file" && grep -q "Too Many Requests" "$file"; then
        return 1
    fi
    
    if grep -q "404" "$file" && grep -q "Not Found" "$file"; then
        return 1
    fi
    
    # Check for Terms of Service warnings (GitHub scraping warning)
    if grep -q "Terms of Service" "$file" && grep -q "scraping" "$file"; then
        return 1
    fi
    
    return 0
}

download_script_file() {
    local url="$1"
    local dest_file="$2"

    rm -f "$dest_file"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL $CURL_IP_FLAGS --connect-timeout 10 --speed-limit 1024 --speed-time 60 -o "$dest_file" "$url" 2>/dev/null || return 1
    elif command -v wget >/dev/null 2>&1; then
        wget $WGET_IP_FLAGS -q --timeout=60 --tries=1 -O "$dest_file" "$url" 2>/dev/null || return 1
    else
        return 1
    fi

    [ -s "$dest_file" ]
}

run_backup_restore() {
    local script_url="https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh"
    local script_file="${HOME}/backup-restore.sh"

    local download_prefixes=(
        ""
        "https://gh-proxy.com/"
        "https://ghfast.top/"
        "https://ghproxy.net/"
    )
    local mirror_prefix script_ok=false

    for mirror_prefix in "${download_prefixes[@]}"; do
        if download_script_file "${mirror_prefix}${script_url}" "$script_file"; then
            if head -1 "$script_file" | grep -q "^#!/bin/bash"; then
                script_ok=true
                break
            fi
        fi
    done

    if [ "$script_ok" != "true" ]; then
        rm -f "$script_file"
        echo -e "${COLOR_RED}${LANG[BACKUP_SCRIPT_FAIL]}${COLOR_RESET}"
        return 1
    fi

    chmod +x "$script_file"
    bash "$script_file"
}

configure_docker_registry_mirrors() {
    local daemon_json="/etc/docker/daemon.json"
    local mirrors='["https://mirror.gcr.io/", "https://dockerhub.timeweb.cloud"]'

    mkdir -p /etc/docker

    if [ ! -s "$daemon_json" ]; then
        printf '{\n  "log-driver": "local",\n  "registry-mirrors": %s\n}\n' "$mirrors" > "$daemon_json"
    elif jq -e 'has("registry-mirrors")' "$daemon_json" >/dev/null 2>&1; then
        return 0
    elif jq empty "$daemon_json" 2>/dev/null; then
        jq --argjson m "$mirrors" '.["registry-mirrors"] = $m |
            if has("log-driver") then . else .["log-driver"] = "local" end' \
            "$daemon_json" > "${daemon_json}.tmp" 2>/dev/null \
            && mv "${daemon_json}.tmp" "$daemon_json" \
            || {
                rm -f "${daemon_json}.tmp"
                echo -e "${COLOR_YELLOW}${LANG[DOCKER_MIRRORS_SKIP]}${COLOR_RESET}" >&2
                return 0
            }
    else
        echo -e "${COLOR_YELLOW}${LANG[DOCKER_MIRRORS_SKIP]}${COLOR_RESET}" >&2
        return 0
    fi

    echo -e "${COLOR_GREEN}${LANG[DOCKER_MIRRORS_APPLIED]}${COLOR_RESET}"
    systemctl restart docker >/dev/null 2>&1
}

load_language() {
    if [ -f "$LANG_FILE" ]; then
        local saved_lang=$(cat "$LANG_FILE")
        case $saved_lang in
            1) set_language en ;;
            2) set_language ru ;;
            *)
                rm -f "$LANG_FILE"
                return 1 ;;
        esac
        return 0
    fi
    return 1
}

# Language variables
declare -gA LANG=(
    [CHOOSE_LANG]="Select language:"
    [LANG_EN]="English"
    [LANG_RU]="Русский"
)

show_language() {
    echo -e "${COLOR_GREEN}${LANG[CHOOSE_LANG]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[LANG_EN]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[LANG_RU]}${COLOR_RESET}"
    echo -e ""
}

set_language() {
     local lang="$1"
     local lang_file="${DIR_REMNAWAVE}lang/${lang}.sh"
     local force_update="${2:-false}"

     unset LANG
     declare -gA LANG

     if [ -n "$LOCAL_SRC_DIR" ] && [ -f "${LOCAL_SRC_DIR}/lang/${lang}.sh" ]; then
         source "${LOCAL_SRC_DIR}/lang/${lang}.sh"
         return 0
     fi

     if [ "$force_update" = "true" ] || [ ! -f "$lang_file" ]; then
         local lang_url="${LANG_BASE_URL}/${lang}.sh"
         mkdir -p "${DIR_REMNAWAVE}lang"
         
         # Use download_with_mirrors for reliable download
         if ! download_with_mirrors "$lang_url" "$lang_file" "lang"; then
             # Fallback: try direct download if mirrors fail
             if command -v curl &> /dev/null; then
                 curl -sL $CURL_IP_FLAGS "$lang_url" -o "$lang_file" 2>/dev/null
             elif command -v wget &> /dev/null; then
                 wget $WGET_IP_FLAGS -q "$lang_url" -O "$lang_file" 2>/dev/null
             fi
         fi
     fi

     if [ -f "$lang_file" ]; then
         source "$lang_file"
     else
         # Emergency fallback: download English from mirrors
         local en_url="${LANG_BASE_URL}/en.sh"
         local temp_en_file="${DIR_REMNAWAVE}lang/en_temp.sh"
         
         if download_with_mirrors "$en_url" "$temp_en_file" "lang"; then
             source "$temp_en_file"
             mv "$temp_en_file" "${DIR_REMNAWAVE}lang/en.sh"
         else
             # Last resort: direct download
             if command -v curl &> /dev/null; then
                 source <(curl -sL $CURL_IP_FLAGS "$en_url" 2>/dev/null)
             elif command -v wget &> /dev/null; then
                 source <(wget $WGET_IP_FLAGS -qO- "$en_url" 2>/dev/null)
             fi
         fi
     fi
}

question() {
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

reading() {
    read -rp " $(question "$1")" "$2"
}

reading_yn() {
    printf ' %s' "$(question "$1")"
    read_yn "$2"
}

read_yn() {
    local __var="$1" __ans
    while true; do
        read -r __ans || { printf -v "$__var" 'n'; echo; return 1; }
        __ans="${__ans//[[:space:]]/}"
        case "${__ans,,}" in
            y|yes|д|да) printf -v "$__var" 'y'; return 0 ;;
            n|no|н|нет) printf -v "$__var" 'n'; return 1 ;;
            *) echo -e "${COLOR_RED}${LANG[INVALID_YN]}${COLOR_RESET}" ;;
        esac
    done
}

step_do() {
    echo -e "${COLOR_YELLOW}[ * ]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

step_ok() {
    echo -e "${COLOR_GREEN}[ ✓ ]${COLOR_RESET} $*"
}

error() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}"
    exit 1
}

# Abort after the superadmin already exists. The credentials live in memory and
# are printed only by the final banner, so an early exit would lose them.
abort_with_credentials() {
    if [ -n "$SUPERADMIN_USERNAME" ] && [ -n "$SUPERADMIN_PASSWORD" ]; then
        echo -e ""
        echo -e "${COLOR_YELLOW}${LANG[ADMIN_CREDS]}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}${SUPERADMIN_USERNAME}${COLOR_RESET}"
        echo -e "${COLOR_WHITE}${SUPERADMIN_PASSWORD}${COLOR_RESET}"
        echo -e ""
    fi
    error "$*"
}

check_not_running() {
    local container_pattern="$1"
    local message="$2"

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxE "$container_pattern"; then
        error "$message"
    fi
}

check_panel_not_running() {
    check_not_running 'remnawave|remnawave-db' "${LANG[PANEL_ALREADY_RUNNING]}"
}

check_node_not_running() {
    check_not_running 'remnanode' "${LANG[NODE_ALREADY_RUNNING]}"
}

check_sub_not_running() {
    check_not_running 'remnawave-subscription-page' "${LANG[SUB_ALREADY_RUNNING]}"
}

check_port_443_free() {
    local listeners
    listeners=$(ss -tlnp 2>/dev/null | awk '$4 ~ /:443$/')
    [ -z "$listeners" ] && return 0

    # A listener owned by our own reverse-proxy container is handled by the
    # install flow itself; only foreign services block the installation.
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qxE 'remnawave-nginx|remnawave-caddy'; then
        return 0
    fi

    local offenders
    offenders=$(echo "$listeners" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | sort -u | paste -sd, -)
    error "$(printf "${LANG[PORT_443_BUSY]}" "${offenders:-unknown}")"
}

allow_ssh_ports() {
    local ssh_ports="" port ok=true

    if command -v sshd >/dev/null 2>&1; then
        ssh_ports=$(sshd -T 2>/dev/null | awk '/^port /{print $2}')
    fi
    if [ -z "$ssh_ports" ]; then
        ssh_ports=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null)
    fi
    [ -z "$ssh_ports" ] && ssh_ports=22

    for port in $ssh_ports; do
        ufw allow "$port/tcp" comment 'SSH' >/dev/null 2>&1 || ok=false
    done

    [ "$ok" = true ]
}

check_os() {
    local os_id os_major
    os_id=$(sed -n 's/^ID=//p' /etc/os-release | head -n 1)
    os_id="${os_id//\"/}"
    os_major=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | head -n 1)
    os_major="${os_major%%.*}"
    os_major="${os_major//\"/}"

    if [ "$os_id" = "debian" ] && [ "$os_major" -ge 11 ] 2>/dev/null; then
        return 0
    fi
    if [ "$os_id" = "ubuntu" ] && [ "$os_major" -ge 22 ] 2>/dev/null; then
        return 0
    fi
    error "${LANG[ERROR_OS]}"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "${LANG[ERROR_ROOT]}"
    fi
}

update_remnawave_reverse() {
    local remote_version
    if ! remote_version=$(fetch_remote_script_version); then
        echo -e "${COLOR_YELLOW}${LANG[VERSION_CHECK_FAILED]}${COLOR_RESET}"
        return 1
    fi
    local update_script="${DIR_REMNAWAVE}remnawave_reverse"
    local bin_link="/usr/local/bin/remnawave_reverse"

    if [ -z "$remote_version" ]; then
        echo -e "${COLOR_YELLOW}${LANG[VERSION_CHECK_FAILED]}${COLOR_RESET}"
        return 1
    fi

    if [ -f "$update_script" ]; then
        if [ "$SCRIPT_VERSION" = "$remote_version" ]; then
            printf "${COLOR_GREEN}${LANG[LATEST_VERSION]}${COLOR_RESET}\n" "$SCRIPT_VERSION"
            return 0
        fi
    else
        echo -e "${COLOR_YELLOW}${LANG[LOCAL_FILE_NOT_FOUND]}${COLOR_RESET}"
    fi

    printf "${COLOR_YELLOW}${LANG[UPDATE_AVAILABLE]}${COLOR_RESET}\n" "$remote_version" "$SCRIPT_VERSION"

    if ! reading_yn "${LANG[UPDATE_CONFIRM]}" confirm_update; then
        echo -e "${COLOR_YELLOW}${LANG[UPDATE_CANCELLED]}${COLOR_RESET}"
        return 0
    fi

    mkdir -p "${DIR_REMNAWAVE}"

    if crontab -u root -l 2>/dev/null | grep -q "cron_jobs.log"; then
        local cron_old=">> ${DIR_REMNAWAVE}cron_jobs.log 2>&1"
        local cron_new="> /dev/null 2>&1"
        crontab -u root -l 2>/dev/null \
            | awk -v old="$cron_old" -v new="$cron_new" \
                  '{ if (i = index($0, old)) print substr($0, 1, i - 1) new; else print }' \
            | crontab -u root -
    fi
    rm -f "${DIR_REMNAWAVE}remnawave_reverse.log" "${DIR_REMNAWAVE}cron_jobs.log"

    local current_lang="en"
    if [ -f "$LANG_FILE" ]; then
        case $(cat "$LANG_FILE") in
            1) current_lang="en" ;;
            2) current_lang="ru" ;;
        esac
    fi

	#Update LANG
    echo -e "${COLOR_YELLOW}${LANG[UPDATING_LANG_FILES]}${COLOR_RESET}"
    set_language "$current_lang" "true"  # force_update=true
    printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "${current_lang}.sh"
    echo -e ""

	#Update modules
    echo -e "${COLOR_YELLOW}${LANG[UPDATING_MODULES]}${COLOR_RESET}"

    local module_dir module_file module_name
    for module_dir in nginx modules caddy api; do
        for module_file in "${DIR_REMNAWAVE}${module_dir}"/*.sh; do
            [ -f "$module_file" ] || continue
            module_name=$(basename "$module_file" .sh)
            if load_module "$module_name" "$module_dir" "true"; then
                printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "${module_dir}/${module_name}.sh"
            else
                printf "${COLOR_RED}${LANG[LANG_FILE_UPDATE_FAILED]}${COLOR_RESET}\n" "${module_dir}/${module_name}.sh"
            fi
        done
    done

    echo -e ""

    local temp_script="${DIR_REMNAWAVE}remnawave_reverse.tmp"
    
    # Use download_with_mirrors for reliable script download
    if download_with_mirrors "$SCRIPT_URL" "$temp_script" "script"; then
        local downloaded_version=$(grep -m 1 "SCRIPT_VERSION=" "$temp_script" | sed -E 's/.*SCRIPT_VERSION="([^"]+)".*/\1/')
        if [ "$downloaded_version" != "$remote_version" ]; then
            echo -e "${COLOR_RED}${LANG[UPDATE_FAILED]}${COLOR_RESET}"
            rm -f "$temp_script"
            return 1
        fi

        if [ -f "$update_script" ]; then
            rm -f "$update_script"
        fi
        mv "$temp_script" "$update_script"
        chmod +x "$update_script"

        if [ -e "$bin_link" ]; then
            rm -f "$bin_link"
        fi
        ln -s "$update_script" "$bin_link"

        hash -r

        printf "${COLOR_GREEN}${LANG[UPDATE_SUCCESS]}${COLOR_RESET}\n" "$remote_version"
        echo -e ""
        echo -e "${COLOR_YELLOW}${LANG[RESTART_REQUIRED]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_GREEN} remnawave_reverse${COLOR_RESET}"
        exit 0
    else
        # Fallback: try direct download with wget
        if wget $WGET_IP_FLAGS -q -O "$temp_script" "$SCRIPT_URL" 2>/dev/null; then
            local downloaded_version=$(grep -m 1 "SCRIPT_VERSION=" "$temp_script" | sed -E 's/.*SCRIPT_VERSION="([^"]+)".*/\1/')
            if [ "$downloaded_version" != "$remote_version" ]; then
                echo -e "${COLOR_RED}${LANG[UPDATE_FAILED]}${COLOR_RESET}"
                rm -f "$temp_script"
                return 1
            fi

            if [ -f "$update_script" ]; then
                rm -f "$update_script"
            fi
            mv "$temp_script" "$update_script"
            chmod +x "$update_script"

            if [ -e "$bin_link" ]; then
                rm -f "$bin_link"
            fi
            ln -s "$update_script" "$bin_link"

            hash -r

            printf "${COLOR_GREEN}${LANG[UPDATE_SUCCESS]}${COLOR_RESET}\n" "$remote_version"
            echo -e ""
            echo -e "${COLOR_YELLOW}${LANG[RESTART_REQUIRED]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_GREEN} remnawave_reverse${COLOR_RESET}"
            exit 0
        fi
        
        echo -e "${COLOR_RED}${LANG[UPDATE_FAILED]}${COLOR_RESET}"
        rm -f "$temp_script"
        return 1
    fi
}

remove_script() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_10]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[REMOVE_SCRIPT_ONLY]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[REMOVE_SCRIPT_AND_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[CERT_PROMPT1]}" SUB_OPTION

    case $SUB_OPTION in
        1)
            echo -e "${COLOR_RED}${LANG[CONFIRM_REMOVE_SCRIPT]}${COLOR_RESET}"
            read_yn confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
            fi

            rm -rf /usr/local/remnawave_reverse 2>/dev/null
            rm -f /usr/local/bin/remnawave_reverse 2>/dev/null
            
            echo -e "${COLOR_GREEN}${LANG[SCRIPT_REMOVED]}${COLOR_RESET}"
            exit 0
            ;;
        2)
            echo -e "${COLOR_RED}${LANG[CONFIRM_REMOVE_ALL]}${COLOR_RESET}"
            read_yn confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
            fi

            wipe_compose_dir /opt/remnawave
            wipe_compose_dir /opt/remnanode
            wipe_compose_dir /opt/subscription
            docker image prune -f > /dev/null 2>&1 &
            spinner $! "${LANG[WAITING]}"
            rm -rf /usr/local/remnawave_reverse 2>/dev/null
            rm -f /usr/local/bin/remnawave_reverse 2>/dev/null

            echo -e "${COLOR_GREEN}${LANG[ALL_REMOVED]}${COLOR_RESET}"
            exit 0
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            remove_script
            ;;
    esac
}

install_script_if_missing() {
    local stamp_stored=""
    [ -f "$SOURCE_STAMP_FILE" ] && stamp_stored=$(cat "$SOURCE_STAMP_FILE" 2>/dev/null)

    if [ "$stamp_stored" != "$SOURCE_STAMP" ] || [ ! -f "${DIR_REMNAWAVE}remnawave_reverse" ] || [ ! -f "/usr/local/bin/remnawave_reverse" ]; then
        mkdir -p "${DIR_REMNAWAVE}"

        # Modules cached from another repository or another version would be
        # sourced verbatim by this script, so they go first.
        rm -rf "${DIR_REMNAWAVE}api" "${DIR_REMNAWAVE}modules" "${DIR_REMNAWAVE}nginx" "${DIR_REMNAWAVE}caddy" "${DIR_REMNAWAVE}lang"

        local self_path=""
        if [ -n "${BASH_SOURCE[0]}" ]; then
            self_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null)
        fi

        local staged="${DIR_REMNAWAVE}remnawave_reverse.new"
        rm -f "$staged"

        # A checkout or an already-installed copy beats the network, and it is
        # the only source that works before a fork has been pushed.
        if [ -n "$self_path" ] && [ -f "$self_path" ] && [ "$self_path" != "${DIR_REMNAWAVE}remnawave_reverse" ]; then
            cp -f "$self_path" "$staged" 2>/dev/null
        elif ! download_with_mirrors "$SCRIPT_URL" "$staged" "script"; then
            if command -v curl &> /dev/null; then
                curl -fsSL $CURL_IP_FLAGS "$SCRIPT_URL" -o "$staged" 2>/dev/null
            elif command -v wget &> /dev/null; then
                wget $WGET_IP_FLAGS -q -O "$staged" "$SCRIPT_URL" 2>/dev/null
            fi
        fi

        if [ -s "$staged" ] && head -1 "$staged" | grep -q "^#!/bin/bash"; then
            mv -f "$staged" "${DIR_REMNAWAVE}remnawave_reverse"
            chmod +x "${DIR_REMNAWAVE}remnawave_reverse"
            ln -sf "${DIR_REMNAWAVE}remnawave_reverse" /usr/local/bin/remnawave_reverse
            printf '%s\n' "$SOURCE_STAMP" > "$SOURCE_STAMP_FILE"
        else
            rm -f "$staged"
            if [ ! -f "${DIR_REMNAWAVE}remnawave_reverse" ]; then
                error "Failed to download $SCRIPT_URL"
            fi
            echo -e "${COLOR_RED}Failed to download $SCRIPT_URL, keeping the installed copy${COLOR_RESET}"
        fi
    fi

    local bashrc_file="/etc/bash.bashrc"
    local alias_line="alias rr='remnawave_reverse'"

    if [ ! -f "$bashrc_file" ]; then
        touch "$bashrc_file"
        chmod 644 "$bashrc_file"
    fi

    if [ -s "$bashrc_file" ] && [ "$(tail -c 1 "$bashrc_file")" != "" ]; then
        echo >> "$bashrc_file"
    fi

    if ! grep -E "^[[:space:]]*alias rr='remnawave_reverse'[[:space:]]*$" "$bashrc_file" > /dev/null; then
        echo "$alias_line" >> "$bashrc_file"
        printf "${COLOR_GREEN}${LANG[ALIAS_ADDED]}${COLOR_RESET}\n" "$bashrc_file"
        printf "${COLOR_YELLOW}${LANG[ALIAS_ACTIVATE_GLOBAL]}${COLOR_RESET}\n" "$bashrc_file"
    fi
}

generate_user() {
    local length=8
    tr -dc 'a-zA-Z' < /dev/urandom | fold -w $length | head -n 1
}

generate_password() {
    local length=24
    local password=""
    local upper_chars='A-Z'
    local lower_chars='a-z'
    local digit_chars='0-9'
    local special_chars='!@#%^&*()_+'
    local all_chars='A-Za-z0-9!@#%^&*()_+'

    password+=$(head /dev/urandom | tr -dc "$upper_chars" | head -c 1)
    password+=$(head /dev/urandom | tr -dc "$lower_chars" | head -c 1)
    password+=$(head /dev/urandom | tr -dc "$digit_chars" | head -c 1)
    password+=$(head /dev/urandom | tr -dc "$special_chars" | head -c 3)
    password+=$(head /dev/urandom | tr -dc "$all_chars" | head -c $(($length - 6)))

    password=$(echo "$password" | fold -w1 | shuf | tr -d '\n')

    echo "$password"
}

#Displaying the availability of the update in the menu
check_update_status() {
    local REMOTE_VERSION
    if ! REMOTE_VERSION=$(fetch_remote_script_version); then
        UPDATE_AVAILABLE=false
        return
    fi

    compare_versions_for_check() {
        local v1="$1"
        local v2="$2"

        local v1_num="${v1//[^0-9.]/}"
        local v2_num="${v2//[^0-9.]/}"

        local v1_sfx="${v1//$v1_num/}"
        local v2_sfx="${v2//$v2_num/}"

        if [[ "$v1_num" == "$v2_num" ]]; then
            if [[ -z "$v1_sfx" && -n "$v2_sfx" ]]; then
                return 0
            elif [[ -n "$v1_sfx" && -z "$v2_sfx" ]]; then
                return 1
            elif [[ "$v1_sfx" < "$v2_sfx" ]]; then
                return 0
            else
                return 1
            fi
        else
            if printf '%s\n' "$v1_num" "$v2_num" | sort -V | head -n1 | grep -qx "$v1_num"; then
                return 0
            else
                return 1
            fi
        fi
    }

    if compare_versions_for_check "$SCRIPT_VERSION" "$REMOTE_VERSION"; then
        UPDATE_AVAILABLE=true
    else
        UPDATE_AVAILABLE=false
    fi
}

# True when a panel is installed at $dir. Node-only boxes have /opt/remnanode
# and must not be offered panel actions.
panel_is_installed() {
    local dir="${1:-/opt/remnawave}"
    [ -f "$dir/docker-compose.yml" ] && [ -f "$dir/.env" ]
}

# True when the panel at $dir still has to be taken to 3.x. Two independent
# signals, either of which is enough:
#   - the compose still pins an old major (:2, :2.8.1, :1.6.16)
#   - .env has no APP_SECRET, which 3.x requires and refuses to boot without
# The tag alone misses a box whose compose floats on :latest or :dev, and the
# .env alone misses a box where APP_SECRET was added by hand but the tag never
# moved. Checking both leaves no panel stranded.
panel_needs_v3_migration() {
    local dir="${1:-/opt/remnawave}"
    [ -f "$dir/.env" ] || return 1

    grep -q '^APP_SECRET=' "$dir/.env" || return 0

    case "$(panel_image_tag "$dir")" in
        1|1.*|2|2.*) return 0 ;;
    esac
    return 1
}

# The backend image tag from the compose file, or empty.
panel_image_tag() {
    local compose="${1:-/opt/remnawave}/docker-compose.yml"
    [ -f "$compose" ] || return 1
    sed -n 's|^[[:space:]]*image:[[:space:]]*remnawave/backend:\([^[:space:]]*\).*|\1|p' "$compose" | head -n 1
}

# Version to show in the notice, read from the compose tag. Deliberately does
# not call docker: this runs on every menu render.
panel_installed_version() {
    local tag
    tag=$(panel_image_tag "/opt/remnawave") || return 1
    case "$tag" in
        1)      echo "1.x" ;;
        2)      echo "2.x" ;;
        1.*|2.*) echo "$tag" ;;
        *)      return 1 ;;
    esac
}

# Shown in the main menu and in the panel menu, so an outdated panel is visible
# without the operator having to go looking for it.
# Pass "nohint" from a menu that already shows the upgrade entry itself.
show_panel_upgrade_notice() {
    # Same gate as the menu entry it points at, so the two can never disagree.
    panel_is_installed || return 0
    panel_needs_v3_migration || return 0

    local version
    if version=$(panel_installed_version); then
        printf "${COLOR_RED}${LANG[PANEL_V2_NOTICE]}${COLOR_RESET}\n" "$version"
    else
        echo -e "${COLOR_RED}${LANG[PANEL_V2_NOTICE_UNKNOWN]}${COLOR_RESET}"
    fi
    if [ "${1:-}" != "nohint" ]; then
        echo -e "${COLOR_YELLOW}${LANG[PANEL_V2_NOTICE_HINT]}${COLOR_RESET}"
    fi
    echo -e ""
}

show_menu() {
    echo -e "${COLOR_GREEN}${LANG[MENU_TITLE]}${COLOR_RESET}"
    if [[ "$UPDATE_AVAILABLE" == true ]]; then
		echo -e "${COLOR_GRAY}$(printf "${LANG[VERSION_LABEL]}" "$SCRIPT_VERSION ${COLOR_RED}${LANG[AVAILABLE_UPDATE]}${COLOR_RESET}")${COLOR_RESET}"
    else
		echo -e "${COLOR_GRAY}$(printf "${LANG[VERSION_LABEL]}" "$SCRIPT_VERSION")${COLOR_RESET}"
    fi
    echo -e "${COLOR_GRAY}Wiki: https://wiki.egam.es/${COLOR_RESET}"
    echo -e ""
    show_panel_upgrade_notice
    echo -e "${COLOR_YELLOW}1. ${LANG[MENU_1]}${COLOR_RESET}" # Install Remnawave Components
    echo -e "${COLOR_YELLOW}2. ${LANG[MENU_2]}${COLOR_RESET}" # Reinstall panel/node
    echo -e "${COLOR_YELLOW}3. ${LANG[MENU_3]}${COLOR_RESET}" # Manage panel/node
    echo -e ""
    echo -e "${COLOR_YELLOW}4. ${LANG[MENU_4]}${COLOR_RESET}" # Templates for the selfsteal node
    echo -e "${COLOR_YELLOW}5. ${LANG[MENU_5]}${COLOR_RESET}" # Custom Templates legiz
    echo -e "${COLOR_YELLOW}6. ${LANG[MENU_6]}${COLOR_RESET}" # WARP Native
    echo -e "${COLOR_YELLOW}7. ${LANG[MENU_7]}${COLOR_RESET}" # Backup and Restore
    echo -e ""
    echo -e "${COLOR_YELLOW}8. ${LANG[MENU_8]}${COLOR_RESET}" # Manage IPv6
    echo -e "${COLOR_YELLOW}9. ${LANG[MENU_9]}${COLOR_RESET}" # Manage certificates domain
    echo -e ""
    if [[ "$UPDATE_AVAILABLE" == true ]]; then
        echo -e "${COLOR_YELLOW}10. ${COLOR_RED}${LANG[MENU_10_UPDATE]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}10. ${LANG[MENU_10]}${COLOR_RESET}" # Check for updates
    fi
    echo -e "${COLOR_YELLOW}11. ${LANG[MENU_11]}${COLOR_RESET}" # Remove script
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}- ${LANG[FAST_START]//remnawave_reverse/${COLOR_GREEN}remnawave_reverse${COLOR_RESET}}"
    echo -e ""
}

# Web server selection
show_webserver_select() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SELECT_WEBSERVER_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. Nginx${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. Caddy${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[SELECT_WEBSERVER_PROMPT]}" WEBSERVER_OPTION
}

#Manage Install Remnawave Components
show_install_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[INSTALL_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[INSTALL_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[INSTALL_PANEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[INSTALL_ADD_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[INSTALL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[INSTALL_PANEL_ONLY]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. ${LANG[INSTALL_SUB_ONLY]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_install() {
    show_install_menu
    reading "${LANG[INSTALL_PROMPT]}" INSTALL_OPTION
    case $INSTALL_OPTION in
        1)
            echo -e ""
            echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[PANEL_NODE_SINGLE_SERVER_WARNING]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}${LANG[PANEL_NODE_SINGLE_SERVER_RECOMMENDATION]}${COLOR_RESET}"
            echo -e ""
            if ! reading_yn "${LANG[CONFIRM_CONTINUE]}" confirm_install; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                exit 0
            fi
            
            show_webserver_select
            case $WEBSERVER_OPTION in
                1)
                    load_install_panel_node_module
                    load_api_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation
                    ;;
                2)
                    load_caddy_module
                    load_api_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_panel_node_caddy
                    ;;
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    remnawave_reverse
                    return
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                    sleep 2
                    manage_install
                    return
                    ;;
            esac
            sleep 2
            ;;
        2)
            PANEL_WITH_SUB=true
            show_webserver_select
            case $WEBSERVER_OPTION in
                1)
                    load_install_panel_module
                    load_api_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_panel
                    ;;
                2)
                    load_caddy_panel_module
                    load_api_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_panel_caddy
                    ;;
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    remnawave_reverse
                    return
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                    sleep 2
                    manage_install
                    return
                    ;;
            esac
            sleep 2
            ;;
        3)
            load_add_node_module
            load_api_module
            add_node_to_panel
            ;;
        4)
            show_webserver_select
            case $WEBSERVER_OPTION in
                1)
                    load_install_node_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_node
                    ;;
                2)
                    load_caddy_node_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_node_caddy
                    ;;
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    remnawave_reverse
                    return
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                    sleep 2
                    manage_install
                    return
                    ;;
            esac
            sleep 2
            ;;
        5)
            PANEL_WITH_SUB=false
            show_webserver_select
            case $WEBSERVER_OPTION in
                1)
                    load_install_panel_module
                    load_api_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_panel
                    ;;
                2)
                    load_caddy_panel_module
                    load_api_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_panel_caddy
                    ;;
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    remnawave_reverse
                    return
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                    sleep 2
                    manage_install
                    return
                    ;;
            esac
            sleep 2
            ;;
        6)
            show_webserver_select
            case $WEBSERVER_OPTION in
                1)
                    load_install_sub_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_sub
                    ;;
                2)
                    load_caddy_sub_module
                    if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
                        install_packages || {
                            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                            exit 1
                        }
                    fi
                    installation_sub_caddy
                    ;;
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    remnawave_reverse
                    return
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                    sleep 2
                    manage_install
                    return
                    ;;
            esac
            sleep 2
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            manage_install
            ;;
    esac
}
#Manage Install Remnawave Components

#Show Reinstall Options
show_reinstall_options() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[REINSTALL_TYPE_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[INSTALL_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[INSTALL_PANEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[INSTALL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[INSTALL_PANEL_ONLY]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[INSTALL_SUB_ONLY]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

choose_reinstall_type() {
    show_reinstall_options
    reading "${LANG[REINSTALL_PROMPT]}" REINSTALL_OPTION
    case $REINSTALL_OPTION in
        1|2|3|4)
                echo -e "${COLOR_RED}${LANG[REINSTALL_WARNING]}${COLOR_RESET}"
                read_yn confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    reinstall_remnawave
                    if [ ! -f ${DIR_REMNAWAVE}install_packages ]; then
                        install_packages
                    fi
                    show_webserver_select
                    case $WEBSERVER_OPTION in
                        1)
                            case $REINSTALL_OPTION in
                                1) load_install_panel_node_module; load_api_module; installation ;;
                                2) PANEL_WITH_SUB=true; load_install_panel_module; load_api_module; installation_panel ;;
                                3) load_install_node_module; load_api_module; installation_node ;;
                                4) PANEL_WITH_SUB=false; load_install_panel_module; load_api_module; installation_panel ;;
                            esac
                            ;;
                        2)
                            case $REINSTALL_OPTION in
                                1) load_caddy_module; load_api_module; installation_panel_node_caddy ;;
                                2) PANEL_WITH_SUB=true; load_caddy_panel_module; load_api_module; installation_panel_caddy ;;
                                3) load_caddy_node_module; installation_node_caddy ;;
                                4) PANEL_WITH_SUB=false; load_caddy_panel_module; load_api_module; installation_panel_caddy ;;
                            esac
                            ;;
                        0)
                            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                            exit 0
                            ;;
                        *)
                            echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                            exit 1
                            ;;
                    esac
                else
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    exit 0
                fi
                ;;
        5)
                echo -e "${COLOR_RED}${LANG[REINSTALL_WARNING]}${COLOR_RESET}"
                read_yn confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    reinstall_subscription
                    if [ ! -f ${DIR_REMNAWAVE}install_packages ]; then
                        install_packages
                    fi
                    show_webserver_select
                    case $WEBSERVER_OPTION in
                        1)
                            load_install_sub_module
                            installation_sub
                            ;;
                        2)
                            load_caddy_sub_module
                            installation_sub_caddy
                            ;;
                        0)
                            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                            exit 0
                            ;;
                        *)
                            echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
                            exit 1
                            ;;
                    esac
                else
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    exit 0
                fi
                ;;
            0)
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                remnawave_reverse
                ;;
            *)
                echo -e "${COLOR_YELLOW}${LANG[INVALID_REINSTALL_CHOICE]}${COLOR_RESET}"
                exit 1
                ;;
        esac
}

wipe_compose_dir() {
    local dir="$1"
    [ -d "$dir" ] || return 0

    (cd "$dir" 2>/dev/null && docker compose down -v --rmi all --remove-orphans) > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"

    rm -rf "$dir"
}

reinstall_remnawave() {
    wipe_compose_dir /opt/remnawave
    wipe_compose_dir /opt/remnanode
    wipe_compose_dir /opt/subscription
    docker image prune -f > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
}

reinstall_subscription() {
    wipe_compose_dir /opt/subscription
    docker image prune -f > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
}
#Show Reinstall Options


add_cron_rule() {
    local rule="$1"
    local logged_rule="${rule} > /dev/null 2>&1"

    if ! crontab -u root -l > /dev/null 2>&1; then
        crontab -u root -l 2>/dev/null | crontab -u root -
    fi

    if ! crontab -u root -l | grep -Fxq "$logged_rule"; then
        (crontab -u root -l 2>/dev/null; echo "$logged_rule") | crontab -u root -
    fi
}

spinner() {
  local pid=$1
  local text=$2

  export LC_ALL=C.UTF-8
  export LANG=C.UTF-8

  local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  local text_code="$COLOR_GREEN"
  local bg_code=""
  local effect_code="\033[1m"
  local delay=0.1
  local reset_code="$COLOR_RESET"

  printf "${effect_code}${text_code}${bg_code}%s${reset_code}" "$text" > /dev/tty

  while kill -0 "$pid" 2>/dev/null; do
    for (( i=0; i<${#spinstr}; i++ )); do
      printf "\r${effect_code}${text_code}${bg_code}[%s] %s${reset_code}" "$(echo -n "${spinstr:$i:1}")" "$text" > /dev/tty
      sleep $delay
    done
  done

  printf "\r\033[K" > /dev/tty
}


ensure_cron() {
    local started=0

    if ! command -v crontab >/dev/null 2>&1; then
        # Wait out the dpkg lock: unattended-upgrades is often mid-run on
        # a freshly booted box
        apt-get -o DPkg::Lock::Timeout=300 install -y cron >/dev/null 2>&1 || true
    fi

    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
        systemctl enable --now cron >/dev/null 2>&1 && started=1
    fi
    if [ "$started" -ne 1 ] && command -v service >/dev/null 2>&1; then
        service cron start >/dev/null 2>&1 && started=1
    fi
    if [ "$started" -ne 1 ] && [ -x /etc/init.d/cron ]; then
        /etc/init.d/cron start >/dev/null 2>&1 && started=1
    fi

    pgrep -x cron >/dev/null 2>&1 && started=1

    if [ "$started" -ne 1 ]; then
        echo -e "${COLOR_YELLOW}${LANG[CRON_START_WARN]}${COLOR_RESET}" >&2
    fi
    return 0
}

install_packages() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALL_PACKAGES]}${COLOR_RESET}"

    if ! apt-get -o DPkg::Lock::Timeout=300 update -y; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_LIST]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! apt-get -o DPkg::Lock::Timeout=300 install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git certbot python3-certbot-dns-cloudflare unattended-upgrades locales dnsutils coreutils grep gawk python3-pip; then
        echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_PACKAGES]}${COLOR_RESET}" >&2
        return 1
    fi

    ensure_cron

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}${LANG[DOCKER_INSTALLING]}${COLOR_RESET}"

        local docker_script="/tmp/get-docker.sh"
        local docker_script_urls=(
            "https://get.docker.com"
            "https://gh-proxy.com/https://raw.githubusercontent.com/docker/docker-install/master/install.sh"
            "https://ghfast.top/https://raw.githubusercontent.com/docker/docker-install/master/install.sh"
            "https://ghproxy.net/https://raw.githubusercontent.com/docker/docker-install/master/install.sh"
        )
        local docker_url docker_script_ok=false

        for docker_url in "${docker_script_urls[@]}"; do
            if download_script_file "$docker_url" "$docker_script" && head -1 "$docker_script" | grep -q "^#!/bin/sh"; then
                docker_script_ok=true
                break
            fi
        done

        if [ "$docker_script_ok" != "true" ]; then
            rm -f "$docker_script"
            echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOAD_DOCKER_KEY]}${COLOR_RESET}" >&2
            return 1
        fi

        if ! sh "$docker_script"; then
            echo -e "${COLOR_YELLOW}${LANG[DOCKER_MIRROR_RETRY]}${COLOR_RESET}"
            if ! sh "$docker_script" --mirror Aliyun; then
                rm -f "$docker_script"
                echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}" >&2
                return 1
            fi
        fi
        rm -f "$docker_script"
    fi

    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_DOCKER_NOT_INSTALLED]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! systemctl is-active --quiet docker; then
        if ! systemctl start docker; then
            echo -e "${COLOR_RED}${LANG[ERROR_START_DOCKER]}${COLOR_RESET}" >&2
            return 1
        fi
    fi

    if ! systemctl is-enabled --quiet docker; then
        if ! systemctl enable docker; then
            echo -e "${COLOR_RED}${LANG[ERROR_ENABLE_DOCKER]}${COLOR_RESET}" >&2
            return 1
        fi
    fi

    configure_docker_registry_mirrors

    if ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_DOCKER_NOT_WORKING]}${COLOR_RESET}" >&2
        return 1
    fi

    # BBR
    if ! grep -q "net.core.default_qdisc = fq" /etc/sysctl.conf; then
        echo "net.core.default_qdisc = fq" >> /etc/sysctl.conf
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control = bbr" /etc/sysctl.conf; then
        echo "net.ipv4.tcp_congestion_control = bbr" >> /etc/sysctl.conf
    fi
    sysctl -p >/dev/null

    # UFW
    if ! allow_ssh_ports || ! ufw allow 443/tcp comment 'HTTPS' || ! ufw --force enable; then
        echo -e "${COLOR_RED}${LANG[ERROR_CONFIGURE_UFW]}${COLOR_RESET}" >&2
        return 1
    fi

    # Unattended-upgrades
    if ! grep -q 'Unattended-Upgrade::Mail' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
        echo 'Unattended-Upgrade::Mail "root";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    fi
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    if ! dpkg-reconfigure -f noninteractive unattended-upgrades || ! systemctl restart unattended-upgrades; then
        echo -e "${COLOR_YELLOW}${LANG[UPGRADES_CONFIG_WARN]}${COLOR_RESET}" >&2
    fi

    touch ${DIR_REMNAWAVE}install_packages
    echo -e "${COLOR_GREEN}${LANG[SUCCESS_INSTALL]}${COLOR_RESET}"
    clear
}

extract_domain() {
    local SUBDOMAIN=$1
    echo "$SUBDOMAIN" | awk -F'.' '{if (NF > 2) {print $(NF-1)"."$NF} else {print $0}}'
}

check_domain() {
    local domain="$1"
    local show_warning="${2:-true}"
    local allow_cf_proxy="${3:-true}"

    local domain_ip=$(dig +short A "$domain" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n 1)
    local server_ip=$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)

    # Without this server's IP nothing can be auto-created either — keep
    # the original warning-and-confirm behaviour.
    if [ -z "$server_ip" ]; then
        if [ "$show_warning" = true ]; then
            echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_RED}${LANG[CHECK_DOMAIN_IP_FAIL]}${COLOR_RESET}"
            printf "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_IP_FAIL_INSTRUCTION]}${COLOR_RESET}\n" "$domain" "$server_ip"
            reading_yn "${LANG[CONFIRM_PROMPT]}" confirm || return 2
        fi
        return 1
    fi

    # The list barely changes, so it is cached for a week instead of being
    # fetched on every domain check. A failed refresh falls back to the
    # stale cache rather than to "not Cloudflare".
    local cf_cache="${DIR_REMNAWAVE}cloudflare_ips_v4.cache"
    local cf_ranges=""
    if [ -s "$cf_cache" ] && [ -z "$(find "$cf_cache" -mtime +7 2>/dev/null)" ]; then
        cf_ranges=$(cat "$cf_cache")
    else
        cf_ranges=$(curl -s $CURL_IP_FLAGS --connect-timeout 10 --max-time 15 https://www.cloudflare.com/ips-v4)
        if echo "$cf_ranges" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
            printf '%s\n' "$cf_ranges" > "$cf_cache"
        elif [ -s "$cf_cache" ]; then
            cf_ranges=$(cat "$cf_cache")
        fi
    fi
    local cf_array=()
    if [ -n "$cf_ranges" ]; then
        IFS=$'\n' read -r -d '' -a cf_array <<<"$cf_ranges"
    fi

    local ip_in_cloudflare=false
    local IFS='.'
    read -r a b c d <<<"$domain_ip"
    local domain_ip_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))

    if [ ${#cf_array[@]} -gt 0 ]; then
        for cidr in "${cf_array[@]}"; do
            if [[ -z "$cidr" ]]; then
                continue
            fi
            local network=$(echo "$cidr" | cut -d'/' -f1)
            local mask=$(echo "$cidr" | cut -d'/' -f2)
            read -r a b c d <<<"$network"
            local network_int=$(( (a << 24) + (b << 16) + (c << 8) + d ))
            local mask_bits=$(( 32 - mask ))
            local range_size=$(( 1 << mask_bits ))
            local min_ip_int=$network_int
            local max_ip_int=$(( network_int + range_size - 1 ))

            if [ "$domain_ip_int" -ge "$min_ip_int" ] && [ "$domain_ip_int" -le "$max_ip_int" ]; then
                ip_in_cloudflare=true
                break
            fi
        done
    fi

    if [ "$domain_ip" = "$server_ip" ]; then
        return 0
    fi
    if [ "$ip_in_cloudflare" = true ] && [ "$allow_cf_proxy" = true ]; then
        return 0
    fi

    # Missing record, wrong target, or a proxied record where proxying is
    # not allowed (Reality selfsteal): offer to create or fix it through
    # the DNS API instead of showing a bare warning.
    if [ "$show_warning" = true ]; then
        if load_dns_records_module && ensure_dns_record "$domain" "$allow_cf_proxy"; then
            return 0
        fi

        # The user skipped the fix — keep the original confirm choice.
        echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
        if [ "$ip_in_cloudflare" = true ]; then
            printf "${COLOR_RED}${LANG[CHECK_DOMAIN_CLOUDFLARE]}${COLOR_RESET}\n" "$domain" "$domain_ip"
            echo -e "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_CLOUDFLARE_INSTRUCTION]}${COLOR_RESET}"
        else
            printf "${COLOR_RED}${LANG[CHECK_DOMAIN_MISMATCH]}${COLOR_RESET}\n" "$domain" "${domain_ip:-—}" "$server_ip"
            echo -e "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_MISMATCH_INSTRUCTION]}${COLOR_RESET}"
        fi
        reading_yn "${LANG[CONFIRM_PROMPT]}" confirm || return 2
    fi
    return 1
}
# Module loader
load_module() {
    local module_name="$1"
    local module_type="${2:-modules}"
    local module_file="${DIR_REMNAWAVE}${module_type}/${module_name}.sh"
    local module_url="${SOURCE_BASE_URL}/src/${module_type}/${module_name}.sh"
    local force_update="${3:-false}"

    if [ -n "$LOCAL_SRC_DIR" ] && [ -f "${LOCAL_SRC_DIR}/${module_type}/${module_name}.sh" ]; then
        source "${LOCAL_SRC_DIR}/${module_type}/${module_name}.sh"
        return 0
    fi

    if [ "$force_update" = "true" ] || [ ! -f "$module_file" ]; then
        mkdir -p "${DIR_REMNAWAVE}${module_type}"

        local backup_file="${module_file}.bak"
        if [ -f "$module_file" ]; then
            cp "$module_file" "$backup_file"
        fi

        # Use download_with_mirrors for reliable download
        if download_with_mirrors "$module_url" "$module_file" "module"; then
            rm -f "$backup_file"
        else
            # Fallback: try direct download if mirrors fail
            if command -v curl &> /dev/null; then
                local http_code
                http_code=$(curl -sL $CURL_IP_FLAGS -w "%{http_code}" "$module_url" -o "$module_file" 2>/dev/null)
                if [ "$http_code" != "200" ] || [ ! -s "$module_file" ]; then
                    if [ -f "$backup_file" ]; then
                        mv "$backup_file" "$module_file"
                    fi
                    return 1
                fi
            elif command -v wget &> /dev/null; then
                wget $WGET_IP_FLAGS -q "$module_url" -O "$module_file" 2>/dev/null
                if [ ! -s "$module_file" ]; then
                    if [ -f "$backup_file" ]; then
                        mv "$backup_file" "$module_file"
                    fi
                    return 1
                fi
            else
                if [ -f "$backup_file" ]; then
                    mv "$backup_file" "$module_file"
                fi
                return 1
            fi
            rm -f "$backup_file"
        fi
    fi

    if [ -f "$module_file" ]; then
        source "$module_file"
        return 0
    else
        printf "${COLOR_RED}${LANG[MODULE_LOAD_FAILED]}${COLOR_RESET}\n" "$module_name"
        return 1
    fi
}

# Module loaders (wrappers for load_module)
load_install_panel_node_module() { load_module "install_panel_node" "nginx" "${1:-false}"; }
load_install_panel_module() { load_module "install_panel" "nginx" "${1:-false}"; }
load_install_node_module() { load_module "install_node" "nginx" "${1:-false}"; }
load_install_sub_module() { load_module "install_sub" "nginx" "${1:-false}"; }
load_add_node_module() { load_module "add_node" "modules" "${1:-false}"; }
load_manage_panel_module() { load_module "manage_panel" "modules" "${1:-false}"; }
load_api_module() { load_module "remnawave_api" "api" "${1:-false}"; }
load_caddy_module() { load_module "install_panel_node" "caddy" "${1:-false}"; }
load_caddy_panel_module() { load_module "install_panel" "caddy" "${1:-false}"; }
load_caddy_node_module() { load_module "install_node" "caddy" "${1:-false}"; }
load_caddy_sub_module() { load_module "install_sub" "caddy" "${1:-false}"; }
load_warp_module() { load_module "warp" "modules" "${1:-false}"; }
load_ipv6_module() { load_module "ipv6" "modules" "${1:-false}"; }
load_selfsteal_templates_module() { load_module "selfsteal_templates" "modules" "${1:-false}"; }
load_legiz_module() { load_module "legiz" "modules" "${1:-false}"; }
load_tinyauth_module() { load_module "tinyauth" "modules" "${1:-false}"; }
load_dns_records_module() { load_module "dns_records" "modules" "${1:-false}"; }
load_certificates_module() { load_module "certificates" "modules" "${1:-false}"; }


detect_broken_ipv6

if ! load_language; then
    show_language
    reading "Choose option (1-2):" LANG_OPTION

    case $LANG_OPTION in
        1) set_language en; echo "1" > "$LANG_FILE" ;;
        2) set_language ru; echo "2" > "$LANG_FILE" ;;
        *) error "Invalid choice. Please select 1-2." ;;
    esac
fi

check_root
check_os
install_script_if_missing
check_update_status
show_menu

reading "${LANG[PROMPT_ACTION]}" OPTION

case $OPTION in
    1)
        manage_install
        ;;
    2)
        choose_reinstall_type
        ;;
    3)
        load_manage_panel_module
        show_manage_panel_menu
        ;;
    4)
        load_selfsteal_templates_module
        manage_selfsteal_templates
        sleep 2
        remnawave_reverse
        ;;
    5)
        load_legiz_module
        manage_custom_legiz
        sleep 2
        remnawave_reverse
        ;;
    6)
        load_warp_module
        manage_warp_native
        sleep 2
        remnawave_reverse
        ;;
    7)
        if [ -f ~/backup-restore.sh ]; then
            rw-backup
        else
            run_backup_restore
        fi
        sleep 2
        remnawave_reverse
        ;;
    8)
        load_ipv6_module
        manage_ipv6
        sleep 2
        remnawave_reverse
        ;;
    9)
        load_certificates_module
        manage_certificates
        sleep 2
        remnawave_reverse
        ;;
    10)
        update_remnawave_reverse
        sleep 2
        remnawave_reverse
        ;;
    11)
        remove_script
        ;;
    0)
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        exit 0
        ;;
    *)
        echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
        exit 1
        ;;
esac
exit 0
