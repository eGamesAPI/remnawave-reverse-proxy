#!/bin/bash

SCRIPT_VERSION="2.3.6 dev"
UPDATE_AVAILABLE=false
DIR_REMNAWAVE="/usr/local/remnawave_reverse/"
LANG_FILE="${DIR_REMNAWAVE}selected_language"
SCRIPT_URL="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/dev/install_remnawave.sh"
LANG_BASE_URL="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/dev/src/lang"

COLOR_RESET="\033[0m"
COLOR_GREEN="\033[1;32m"
COLOR_YELLOW="\033[1;33m"
COLOR_WHITE="\033[1;37m"
COLOR_RED="\033[1;31m"
COLOR_GRAY='\033[0;90m'

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

     unset LANG
     declare -gA LANG

     if [ ! -f "$lang_file" ]; then
         local lang_url="${LANG_BASE_URL}/${lang}.sh"
         mkdir -p "${DIR_REMNAWAVE}lang"
         if command -v curl &> /dev/null; then
             curl -sL "$lang_url" -o "$lang_file" 2>/dev/null
         elif command -v wget &> /dev/null; then
             wget -q "$lang_url" -O "$lang_file" 2>/dev/null
         fi
     fi

     if [ -f "$lang_file" ]; then
         source "$lang_file"
     else
         local en_url="${LANG_BASE_URL}/en.sh"
         if command -v curl &> /dev/null; then
             source <(curl -sL "$en_url" 2>/dev/null)
         elif command -v wget &> /dev/null; then
             source <(wget -qO- "$en_url" 2>/dev/null)
         fi
     fi
}

question() {
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}$*${COLOR_RESET}"
}

reading() {
    read -rp " $(question "$1")" "$2"
}

error() {
    echo -e "${COLOR_RED}$*${COLOR_RESET}"
    exit 1
}

check_os() {
    if ! grep -q "bullseye" /etc/os-release && ! grep -q "bookworm" /etc/os-release && ! grep -q "jammy" /etc/os-release && ! grep -q "noble" /etc/os-release && ! grep -q "trixie" /etc/os-release; then
        error "${LANG[ERROR_OS]}"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "${LANG[ERROR_ROOT]}"
    fi
}

log_clear() {
  sed -i -e 's/\x1b\[[0-9;]*[a-zA-Z]//g' "$LOGFILE"
}

log_entry() {
  mkdir -p ${DIR_REMNAWAVE}
  LOGFILE="${DIR_REMNAWAVE}remnawave_reverse.log"
  exec > >(tee -a "$LOGFILE") 2>&1
}

run_remnawave_cli() {
    if ! docker ps --format '{{.Names}}' | grep -q '^remnawave$'; then
        echo -e "${COLOR_YELLOW}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        return 1
    fi

    exec 3>&1 4>&2
    exec > /dev/tty 2>&1

    echo -e "${COLOR_YELLOW}${LANG[RUNNING_CLI]}${COLOR_RESET}"
    if docker exec -it -e TERM=xterm-256color remnawave remnawave; then
        echo -e "${COLOR_GREEN}${LANG[CLI_SUCCESS]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CLI_FAILED]}${COLOR_RESET}"
        exec 1>&3 2>&4
        return 1
    fi

    exec 1>&3 2>&4
}

start_panel_node() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    if docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . || docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q . || docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
        echo -e "${COLOR_GREEN}${LANG[PANEL_RUNNING]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[STARTING_PANEL_NODE]}...${COLOR_RESET}"
        sleep 1
        docker compose up -d > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        echo -e "${COLOR_GREEN}${LANG[PANEL_RUN]}${COLOR_RESET}"
    fi
}

stop_panel_node() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }
    if ! docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
        echo -e "${COLOR_GREEN}${LANG[PANEL_STOPPED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[STOPPING_REMNAWAVE]}...${COLOR_RESET}"
        sleep 1
        docker compose down > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        echo -e "${COLOR_GREEN}${LANG[PANEL_STOP]}${COLOR_RESET}"
    fi
}

update_panel_node() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }
    echo -e "${COLOR_YELLOW}${LANG[UPDATING]}${COLOR_RESET}"
    sleep 1

    images_before=$(docker compose config --images | sort -u)
    if [ -n "$images_before" ]; then
        before=$(echo "$images_before" | xargs -I {} docker images -q {} | sort -u)
    else
        before=""
    fi

    tmpfile=$(mktemp)
    docker compose pull > "$tmpfile" 2>&1 &
    spinner $! "${LANG[WAITING]}"
    pull_output=$(cat "$tmpfile")
    rm -f "$tmpfile"

    images_after=$(docker compose config --images | sort -u)
    if [ -n "$images_after" ]; then
        after=$(echo "$images_after" | xargs -I {} docker images -q {} | sort -u)
    else
        after=""
    fi

    if [ "$before" != "$after" ] || echo "$pull_output" | grep -q "Pull complete"; then
        echo -e ""
	echo -e "${COLOR_YELLOW}${LANG[IMAGES_DETECTED]}${COLOR_RESET}"
        docker compose down > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        sleep 5
        docker compose up -d > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        sleep 1
        docker image prune -f > /dev/null 2>&1
        echo -e "${COLOR_GREEN}${LANG[UPDATE_SUCCESS1]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[NO_UPDATE]}${COLOR_RESET}"
    fi
}

update_remnawave_reverse() {
    local remote_version=$(curl -s "$SCRIPT_URL" | grep -m 1 "SCRIPT_VERSION=" | sed -E 's/.*SCRIPT_VERSION="([^"]+)".*/\1/')
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
    reading "${LANG[UPDATE_CONFIRM]}" confirm_update

    if [[ "$confirm_update" != "y" && "$confirm_update" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}${LANG[UPDATE_CANCELLED]}${COLOR_RESET}"
        return 0
    fi

    mkdir -p "${DIR_REMNAWAVE}"

    local current_lang="en"
    if [ -f "$LANG_FILE" ]; then
        case $(cat "$LANG_FILE") in
            1) current_lang="en" ;;
            2) current_lang="ru" ;;
        esac
    fi

	#Update LANG
    echo -e "${COLOR_YELLOW}${LANG[UPDATING_LANG_FILES]}${COLOR_RESET}"
    local lang_url="${LANG_BASE_URL}/${current_lang}.sh"
    local lang_file="${DIR_REMNAWAVE}lang/${current_lang}.sh"
    mkdir -p "${DIR_REMNAWAVE}lang"
    if wget -q -O "$lang_file" "$lang_url"; then
        printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "${current_lang}.sh"
    else
        printf "${COLOR_RED}${LANG[LANG_FILE_UPDATE_FAILED]}${COLOR_RESET}\n" "${current_lang}.sh"
    fi
    echo -e ""

	#Update modules
    echo -e "${COLOR_YELLOW}${LANG[UPDATING_MODULES]}${COLOR_RESET}"
    local modules=("install_panel_node.sh" "install_panel.sh" "remnawave_api.sh")
    for module in "${modules[@]}"; do
        local module_url="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/dev/src/modules/${module}"

        if [ "$module" == "remnawave_api.sh" ]; then
            module_url="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/dev/src/api/${module}"
            local module_file="${DIR_REMNAWAVE}api/${module}"
            mkdir -p "${DIR_REMNAWAVE}api"
        else
            local module_file="${DIR_REMNAWAVE}modules/${module}"
            mkdir -p "${DIR_REMNAWAVE}modules"
        fi
        if wget -q -O "$module_file" "$module_url"; then
            printf "${COLOR_GREEN}${LANG[LANG_FILE_UPDATED]}${COLOR_RESET}\n" "$module"
        else
            printf "${COLOR_RED}${LANG[LANG_FILE_UPDATE_FAILED]}${COLOR_RESET}\n" "$module"
        fi
    done
    echo -e ""

    local temp_script="${DIR_REMNAWAVE}remnawave_reverse.tmp"
    if wget -q -O "$temp_script" "$SCRIPT_URL"; then
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
            read confirm
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
            read confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
            fi

            if [ -d "/opt/remnawave" ]; then
                cd /opt/remnawave || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} /opt/remnawave${COLOR_RESET}"; exit 1; }
                docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
                spinner $! "${LANG[WAITING]}"
                rm -rf /opt/remnawave 2>/dev/null
            fi
            docker system prune -a --volumes -f > /dev/null 2>&1 &
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
    if [ ! -f "${DIR_REMNAWAVE}remnawave_reverse" ] || [ ! -f "/usr/local/bin/remnawave_reverse" ]; then
        mkdir -p "${DIR_REMNAWAVE}"
        if ! wget -q -O "${DIR_REMNAWAVE}remnawave_reverse" "$SCRIPT_URL"; then
            exit 1
        fi
        chmod +x "${DIR_REMNAWAVE}remnawave_reverse"
        ln -sf "${DIR_REMNAWAVE}remnawave_reverse" /usr/local/bin/remnawave_reverse
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
    local TEMP_REMOTE_VERSION_FILE
    TEMP_REMOTE_VERSION_FILE=$(mktemp)

    if ! curl -fsSL "$SCRIPT_URL" 2>/dev/null | head -n 100 > "$TEMP_REMOTE_VERSION_FILE"; then
        UPDATE_AVAILABLE=false
        rm -f "$TEMP_REMOTE_VERSION_FILE"
        return
    fi

    local REMOTE_VERSION
    REMOTE_VERSION=$(grep -m 1 "^SCRIPT_VERSION=" "$TEMP_REMOTE_VERSION_FILE" | cut -d'"' -f2)
    rm -f "$TEMP_REMOTE_VERSION_FILE"

    if [[ -z "$REMOTE_VERSION" ]]; then
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

show_menu() {
    echo -e "${COLOR_GREEN}${LANG[MENU_TITLE]}${COLOR_RESET}"
    if [[ "$UPDATE_AVAILABLE" == true ]]; then
		echo -e "${COLOR_GRAY}$(printf "${LANG[VERSION_LABEL]}" "$SCRIPT_VERSION ${COLOR_RED}${LANG[AVAILABLE_UPDATE]}${COLOR_RESET}")${COLOR_RESET}"
    else
		echo -e "${COLOR_GRAY}$(printf "${LANG[VERSION_LABEL]}" "$SCRIPT_VERSION")${COLOR_RESET}"
    fi
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[MENU_1]}${COLOR_RESET}" # Install Remnawave Components
    echo -e "${COLOR_YELLOW}2. ${LANG[MENU_2]}${COLOR_RESET}" # Reinstall panel/node
    echo -e "${COLOR_YELLOW}3. ${LANG[MENU_3]}${COLOR_RESET}" # Manage panel/node
    echo -e ""
    echo -e "${COLOR_YELLOW}4. ${LANG[MENU_4]}${COLOR_RESET}" # Install random template
    echo -e "${COLOR_YELLOW}5. ${LANG[MENU_5]}${COLOR_RESET}" # Custom Templates legiz
    echo -e "${COLOR_YELLOW}6. ${LANG[MENU_6]}${COLOR_RESET}" # Extensions distilium
    echo -e ""
    echo -e "${COLOR_YELLOW}7. ${LANG[MENU_7]}${COLOR_RESET}" # Manage IPv6
    echo -e "${COLOR_YELLOW}8. ${LANG[MENU_8]}${COLOR_RESET}" # Manage certificates domain
    echo -e ""
    echo -e "${COLOR_YELLOW}9. ${LANG[MENU_9]}${COLOR_RESET}" # Check for updates
    echo -e "${COLOR_YELLOW}10. ${LANG[MENU_10]}${COLOR_RESET}" # Remove script
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}- ${LANG[FAST_START]//remnawave_reverse/${COLOR_GREEN}remnawave_reverse${COLOR_RESET}}"
    echo -e ""
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
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_install() {
    load_install_panel_node_module
    load_install_panel_module
    load_api_module

    show_install_menu
    reading "${LANG[INSTALL_PROMPT]}" INSTALL_OPTION
    case $INSTALL_OPTION in
        1)
            if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            installation
            sleep 2
            log_clear
            ;;
        2)
            if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            installation_panel
            sleep 2
            log_clear
            ;;
        3)
            add_node_to_panel
            log_clear
            ;;
        4)
            if [ ! -f "${DIR_REMNAWAVE}install_packages" ] || ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1 || ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            installation_node
            sleep 2
            log_clear
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INSTALL_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_install
            ;;
    esac
}
#Manage Install Remnawave Components

#Manage Panel Access
show_panel_access() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_9]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[PORT_8443_OPEN]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[PORT_8443_CLOSE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_panel_access() {
    show_panel_access
    reading "${LANG[IPV6_PROMPT]}" ACCESS_OPTION
    case $ACCESS_OPTION in
        1)
            open_panel_access
            sleep 2
            log_clear
            manage_panel_access
            ;;
        2)
            close_panel_access
            sleep 2
            log_clear
            manage_panel_access
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_panel_access
            ;;
    esac
}

open_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    if [ ! -f "nginx.conf" ]; then
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_NOT_FOUND]} $dir${COLOR_RESET}"
        exit 1
    fi

    PANEL_DOMAIN=$(grep -B 20 "proxy_pass http://remnawave" "$dir/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)

    cookie_line=$(grep -A 2 "map \$http_cookie \$auth_cookie" "$dir/nginx.conf" | grep "~*\w\+.*=")
    cookies_random1=$(echo "$cookie_line" | grep -oP '~*\K\w+(?==)')
    cookies_random2=$(echo "$cookie_line" | grep -oP '=\K\w+(?=")')

    if [ -z "$PANEL_DOMAIN" ] || [ -z "$cookies_random1" ] || [ -z "$cookies_random2" ]; then
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
        exit 1
    fi

    if command -v ss >/dev/null 2>&1; then
        if ss -tuln | grep -q ":8443"; then
            echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
            exit 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln | grep -q ":8443"; then
            echo -e "${COLOR_RED}${LANG[PORT_8443_IN_USE]}${COLOR_RESET}"
            exit 1
        fi
    else
        echo -e "${COLOR_RED}${LANG[NO_PORT_CHECK_TOOLS]}${COLOR_RESET}"
        exit 1
    fi

    sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
    sed -i "/server_name $PANEL_DOMAIN;/a \    listen 8443 ssl;" "$dir/nginx.conf"
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_MODIFY_FAILED]}${COLOR_RESET}"
        exit 1
    fi

    docker compose down remnawave-nginx > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    
    docker compose up -d remnawave-nginx > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    
    ufw allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
    ufw reload > /dev/null 2>&1
    sleep 1

    local panel_link="https://${PANEL_DOMAIN}:8443/auth/login?${cookies_random1}=${cookies_random2}"
    echo -e "${COLOR_YELLOW}${LANG[OPEN_PANEL_LINK]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}${panel_link}${COLOR_RESET}"
    echo -e "${COLOR_RED}${LANG[PORT_8443_WARNING]}${COLOR_RESET}"

    sleep 2
    log_clear
}

close_panel_access() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    echo -e "${COLOR_YELLOW}${LANG[PORT_8443_CLOSE]}${COLOR_RESET}"

    if [ ! -f "nginx.conf" ]; then
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_NOT_FOUND]} $dir${COLOR_RESET}"
        exit 1
    fi

    PANEL_DOMAIN=$(grep -B 20 "proxy_pass http://remnawave" "$dir/nginx.conf" | grep "server_name" | grep -v "server_name _" | awk '{print $2}' | sed 's/;//' | head -n 1)

    if [ -z "$PANEL_DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[NGINX_CONF_ERROR]}${COLOR_RESET}"
        exit 1
    fi

    if grep -A 10 "server_name $PANEL_DOMAIN;" "$dir/nginx.conf" | grep -q "listen 8443 ssl;"; then
        sed -i "/server_name $PANEL_DOMAIN;/,/}/{/^[[:space:]]*$/d; s/listen 8443 ssl;//}" "$dir/nginx.conf"
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}${LANG[NGINX_CONF_MODIFY_FAILED]}${COLOR_RESET}"
            exit 1
        fi

        docker compose down remnawave-nginx > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        docker compose up -d remnawave-nginx > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
    else
        echo -e "${COLOR_YELLOW}${LANG[PORT_8443_NOT_CONFIGURED]}${COLOR_RESET}"
    fi

    if ufw status | grep -q "8443.*ALLOW"; then
        ufw delete allow from 0.0.0.0/0 to any port 8443 proto tcp > /dev/null 2>&1
        ufw reload > /dev/null 2>&1
        if [ $? -ne 0 ]; then
            echo -e "${COLOR_RED}${LANG[UFW_RELOAD_FAILED]}${COLOR_RESET}"
            exit 1
        fi
        echo -e "${COLOR_GREEN}${LANG[PORT_8443_CLOSED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[PORT_8443_ALREADY_CLOSED]}${COLOR_RESET}"
    fi

    sleep 2
    log_clear
}

view_logs() {
    local dir=""
    if [ -d "/opt/remnawave" ]; then
        dir="/opt/remnawave"
    else
        echo -e "${COLOR_RED}${LANG[DIR_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    cd "$dir" || { echo -e "${COLOR_RED}${LANG[CHANGE_DIR_FAILED]} $dir${COLOR_RESET}"; exit 1; }

    if ! docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/backend:2" | grep -q .; then
        echo -e "${COLOR_RED}${LANG[CONTAINER_NOT_RUNNING]}${COLOR_RESET}"
        exit 1
    fi

    echo -e "${COLOR_YELLOW}${LANG[VIEW_LOGS]}${COLOR_RESET}"
    docker compose logs -f -t
}
#Manage Panel Access

#Show Reinstall Options
show_reinstall_options() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[REINSTALL_TYPE_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[INSTALL_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[INSTALL_PANEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[INSTALL_NODE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

choose_reinstall_type() {
    show_reinstall_options
    reading "${LANG[REINSTALL_PROMPT]}" REINSTALL_OPTION
    case $REINSTALL_OPTION in
        1|2|3)
                echo -e "${COLOR_RED}${LANG[REINSTALL_WARNING]}${COLOR_RESET}"
                read confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    reinstall_remnawave
                    if [ ! -f ${DIR_REMNAWAVE}install_packages ]; then
                        install_packages
                    fi
                    case $REINSTALL_OPTION in
                        1) installation ;;
                        2) installation_panel ;;
                        3) installation_node ;;
                    esac
                    log_clear
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

reinstall_remnawave() {
    if [ -d "/opt/remnawave" ]; then
        cd /opt/remnawave || return
        docker compose down -v --rmi all --remove-orphans > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
    fi
    docker system prune -a --volumes -f > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    rm -rf /opt/remnawave 2>/dev/null
}
#Show Reinstall Options

#Show Panel Node Menu
show_panel_node_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_3]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[START_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[STOP_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[UPDATE_PANEL_NODE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[VIEW_LOGS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. ${LANG[REMNAWAVE_CLI]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. ${LANG[ACCESS_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[MANAGE_PANEL_NODE_PROMPT]}" SUB_OPTION

    case $SUB_OPTION in
        1)
            start_panel_node
            sleep 2
            log_clear
            show_panel_node_menu
            ;;
        2)
            stop_panel_node
            sleep 2
            log_clear
            show_panel_node_menu
            ;;
        3)
            update_panel_node
            sleep 2
            log_clear
            show_panel_node_menu
            ;;
        4)
            view_logs
            sleep 2
            log_clear
            show_panel_node_menu
            ;;
        5)
            run_remnawave_cli
            sleep 2
            log_clear
            show_panel_node_menu
            ;;
        6)
            manage_panel_access
            sleep 2
            log_clear
            show_panel_node_menu
            ;;
        0)
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[MANAGE_PANEL_NODE_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 1
            show_panel_node_menu
            ;;
    esac
}
#Manage Panel Node Menu

manage_extensions() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[EXTENSIONS_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[WARP_MENU]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[BACKUP_RESTORE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[EXTENSIONS_PROMPT]}" EXTENSION_OPTION

    case $EXTENSION_OPTION in
        1)
            manage_warp
            log_clear
            manage_extensions
            ;;
        2)
            if [ -f ~/backup-restore.sh ]; then
                rw-backup
            else
                curl -o ~/backup-restore.sh https://raw.githubusercontent.com/distillium/remnawave-backup-restore/main/backup-restore.sh && chmod +x ~/backup-restore.sh && ~/backup-restore.sh
            fi
            log_clear
            manage_extensions
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_RED}${LANG[EXTENSIONS_INVALID_CHOICE]}${COLOR_RESET}"
            ;;
    esac
}

manage_warp() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[WARP_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[WARP_INSTALL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[WARP_UNINSTALL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}3. ${LANG[WARP_ADD_CONFIG]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. ${LANG[WARP_DELETE_WARP_SETTINGS]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[WARP_PROMPT]}" WARP_OPTION

    case $WARP_OPTION in
        1)
            if ! grep -q "remnanode:" /opt/remnawave/docker-compose.yml; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_NODE]}${COLOR_RESET}"
                exit 1
            fi
            bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/install.sh)
            ;;
        2)
            bash <(curl -fsSL https://raw.githubusercontent.com/distillium/warp-native/main/uninstall.sh)
            ;;
        3)
            local domain_url="127.0.0.1:3000"
            
            echo -e ""
            echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[WARP_CONFIRM_SERVER_PANEL]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}${LANG[CONFIRM_PROMPT]}${COLOR_RESET}"
            read confirm
            echo

            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                exit 0
            fi
            
            get_panel_token
            token=$(cat "$TOKEN_FILE")

            local config_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
            if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Invalid response${COLOR_RESET}"
            fi

            if ! echo "$config_response" | jq -e '.response.configProfiles | type == "array"' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Response does not contain configProfiles array${COLOR_RESET}"
            fi

            local config_count=$(echo "$config_response" | jq '.response.configProfiles | length')
            if [ "$config_count" -eq 0 ]; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Empty configuration list${COLOR_RESET}"
            fi
            local configs=$(echo "$config_response" | jq -r '.response.configProfiles[] | select(.uuid and .name) | "\(.name) \(.uuid)"' 2>/dev/null)
            if [ -z "$configs" ]; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: No valid configurations found in response${COLOR_RESET}"
            fi

            echo -e ""
            echo -e "${COLOR_YELLOW}${LANG[WARP_SELECT_CONFIG]}${COLOR_RESET}"
            echo -e ""
            local i=1
            declare -A config_map
            while IFS=' ' read -r name uuid; do
                echo -e "${COLOR_YELLOW}$i. $name${COLOR_RESET}"
                config_map[$i]="$uuid"
                ((i++))
            done <<< "$configs"
            echo -e ""
            echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
            echo -e ""
            reading "${LANG[WARP_PROMPT1]}" CONFIG_OPTION

            if [ "$CONFIG_OPTION" == "0" ]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
            fi

            if [ -z "${config_map[$CONFIG_OPTION]}" ]; then
                echo -e "${COLOR_RED}${LANG[WARP_INVALID_CHOICE2]}${COLOR_RESET}"
                return 1
            fi

            local selected_uuid=${config_map[$CONFIG_OPTION]}

            local config_data=$(make_api_request "GET" "${domain_url}/api/config-profiles/$selected_uuid" "$token")
            if [ -z "$config_data" ] || ! echo "$config_data" | jq -e '.' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
            fi

            local config_json
            if echo "$config_data" | jq -e '.response.config' > /dev/null 2>&1; then
                config_json=$(echo "$config_data" | jq -r '.response.config')
            else
                config_json=$(echo "$config_data" | jq -r '.config // ""')
            fi

            if [ -z "$config_json" ] || [ "$config_json" == "null" ]; then
                echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: No config found in response${COLOR_RESET}"
            fi

            if echo "$config_json" | jq -e '.outbounds[] | select(.tag == "warp-out")' > /dev/null 2>&1; then
                echo -e "${COLOR_YELLOW}${LANG[WARP_WARNING]}${COLOR_RESET}"
            else
                local warp_outbound='{
                    "tag": "warp-out",
                    "protocol": "freedom",
                    "settings": {
					    "domainStrategy": "UseIP"
					},
                    "streamSettings": {
                        "sockopt": {
                            "interface": "warp",
                            "tcpFastOpen": true
                        }
                    }
                }'
                config_json=$(echo "$config_json" | jq --argjson warp_out "$warp_outbound" '.outbounds += [$warp_out]' 2>/dev/null)
            fi

            if echo "$config_json" | jq -e '.routing.rules[] | select(.outboundTag == "warp-out")' > /dev/null 2>&1; then
                echo -e "${COLOR_YELLOW}${LANG[WARP_WARNING2]}${COLOR_RESET}"
            else
                local warp_rule='{
                    "type": "field",
                    "domain": ["whoer.net", "browserleaks.com", "2ip.io", "2ip.ru"],
                    "outboundTag": "warp-out"
                }'
                config_json=$(echo "$config_json" | jq --argjson warp_rule "$warp_rule" '.routing.rules += [$warp_rule]' 2>/dev/null)
            fi

            local update_response=$(make_api_request "PATCH" "${domain_url}/api/config-profiles" "$token" "{\"uuid\": \"$selected_uuid\", \"config\": $config_json}")
            if [ -z "$update_response" ] || ! echo "$update_response" | jq -e '.' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
            fi

            echo -e "${COLOR_GREEN}${LANG[WARP_UPDATE_SUCCESS]}${COLOR_RESET}"
            log_clear
            manage_warp
            ;;
        4)
            local domain_url="127.0.0.1:3000"
            
            echo -e ""
            echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[WARP_CONFIRM_SERVER_PANEL]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}${LANG[CONFIRM_PROMPT]}${COLOR_RESET}"
            read confirm
            echo

            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                exit 0
            fi
            
            get_panel_token
            token=$(cat "$TOKEN_FILE")

            local config_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
            if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Invalid response${COLOR_RESET}"
                return 1
            fi

            if ! echo "$config_response" | jq -e '.response.configProfiles | type == "array"' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Response does not contain configProfiles array${COLOR_RESET}"
                return 1
            fi

            local config_count=$(echo "$config_response" | jq '.response.configProfiles | length')
            if [ "$config_count" -eq 0 ]; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: Empty configuration list${COLOR_RESET}"
                return 1
            fi

            local configs=$(echo "$config_response" | jq -r '.response.configProfiles[] | select(.uuid and .name) | "\(.name) \(.uuid)"' 2>/dev/null)
            if [ -z "$configs" ]; then
                echo -e "${COLOR_RED}${LANG[WARP_NO_CONFIGS]}: No valid configurations found in response${COLOR_RESET}"
                return 1
            fi

            echo -e ""
            echo -e "${COLOR_YELLOW}${LANG[WARP_SELECT_CONFIG_DELETE]}${COLOR_RESET}"
            echo -e ""
            local i=1
            declare -A config_map
            while IFS=' ' read -r name uuid; do
                echo -e "${COLOR_YELLOW}$i. $name${COLOR_RESET}"
                config_map[$i]="$uuid"
                ((i++))
            done <<< "$configs"
            echo -e ""
            echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
            echo -e ""
            reading "${LANG[WARP_PROMPT1]}" CONFIG_OPTION

            if [ "$CONFIG_OPTION" == "0" ]; then
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                return 0
            fi

            if [ -z "${config_map[$CONFIG_OPTION]}" ]; then
                echo -e "${COLOR_RED}${LANG[WARP_INVALID_CHOICE2]}${COLOR_RESET}"
                return 1
            fi

            local selected_uuid=${config_map[$CONFIG_OPTION]}

            local config_data=$(make_api_request "GET" "${domain_url}/api/config-profiles/$selected_uuid" "$token")
            if [ -z "$config_data" ] || ! echo "$config_data" | jq -e '.' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
                return 1
            fi

            local config_json
            if echo "$config_data" | jq -e '.response.config' > /dev/null 2>&1; then
                config_json=$(echo "$config_data" | jq -r '.response.config')
            else
                config_json=$(echo "$config_data" | jq -r '.config // ""')
            fi

            if [ -z "$config_json" ] || [ "$config_json" == "null" ]; then
                echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: No config found in response${COLOR_RESET}"
                return 1
            fi
            
            if echo "$config_json" | jq -e '.outbounds[] | select(.tag == "warp-out")' > /dev/null 2>&1; then
                config_json=$(echo "$config_json" | jq 'del(.outbounds[] | select(.tag == "warp-out"))' 2>/dev/null)
                echo -e "${COLOR_YELLOW}${LANG[WARP_REMOVED_WARP_SETTINGS1]}${COLOR_RESET}"
            else
                echo -e "${COLOR_YELLOW}${LANG[WARP_NO_WARP_SETTINGS1]}${COLOR_RESET}"
            fi

            if echo "$config_json" | jq -e '.routing.rules[] | select(.outboundTag == "warp-out")' > /dev/null 2>&1; then
                config_json=$(echo "$config_json" | jq 'del(.routing.rules[] | select(.outboundTag == "warp-out"))' 2>/dev/null)
                echo -e "${COLOR_YELLOW}${LANG[WARP_REMOVED_WARP_SETTINGS2]}${COLOR_RESET}"
            else
                echo -e "${COLOR_YELLOW}${LANG[WARP_NO_WARP_SETTINGS2]}${COLOR_RESET}"
            fi

            local update_response=$(make_api_request "PATCH" "${domain_url}/api/config-profiles" "$token" "{\"uuid\": \"$selected_uuid\", \"config\": $config_json}")
            if [ -z "$update_response" ] || ! echo "$update_response" | jq -e '.' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[WARP_UPDATE_FAIL]}: Invalid response${COLOR_RESET}"
                return 1
            fi

            echo -e "${COLOR_GREEN}${LANG[WARP_DELETE_SUCCESS]}${COLOR_RESET}"
            log_clear
            manage_warp
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_RED}${LANG[WARP_INVALID_CHOICE]}${COLOR_RESET}"
            ;;
    esac
}

#Manage IPv6
show_ipv6_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[IPV6_MENU_TITLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[IPV6_ENABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[IPV6_DISABLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_ipv6() {
    show_ipv6_menu
    reading "${LANG[IPV6_PROMPT]}" IPV6_OPTION
    case $IPV6_OPTION in
        1)
            enable_ipv6
            sleep 2
            log_clear
            manage_ipv6
            ;;
        2)
            disable_ipv6
            sleep 2
            log_clear
            manage_ipv6
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_ipv6
            ;;
    esac
}

enable_ipv6() {
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" -eq 0 ]; then
        echo -e "${COLOR_YELLOW}${LANG[IPV6_ALREADY_ENABLED]}${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_YELLOW}${LANG[ENABLE_IPV6]}${COLOR_RESET}"
    interface_name=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)

    sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
    sed -i "/net.ipv6.conf.$interface_name.disable_ipv6/d" /etc/sysctl.conf

    echo "net.ipv6.conf.all.disable_ipv6 = 0" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 0" >> /etc/sysctl.conf
    echo "net.ipv6.conf.lo.disable_ipv6 = 0" >> /etc/sysctl.conf
    echo "net.ipv6.conf.$interface_name.disable_ipv6 = 0" >> /etc/sysctl.conf

    sysctl -p > /dev/null 2>&1
    echo -e "${COLOR_GREEN}${LANG[IPV6_ENABLED]}${COLOR_RESET}"
}

disable_ipv6() {
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" -eq 1 ]; then
        echo -e "${COLOR_YELLOW}${LANG[IPV6_ALREADY_DISABLED]}${COLOR_RESET}"
        return 0
    fi

    echo -e "${COLOR_YELLOW}${LANG[DISABLING_IPV6]}${COLOR_RESET}"
    interface_name=$(ip -o link show | awk -F': ' '{print $2}' | grep -v lo | head -n 1)

    sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
    sed -i "/net.ipv6.conf.$interface_name.disable_ipv6/d" /etc/sysctl.conf

    echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.lo.disable_ipv6 = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.$interface_name.disable_ipv6 = 1" >> /etc/sysctl.conf

    sysctl -p > /dev/null 2>&1
    echo -e "${COLOR_GREEN}${LANG[IPV6_DISABLED]}${COLOR_RESET}"
}
#Manage IPv6

#Extensions by legiz
show_custom_legiz_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_5]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SELECT_SUB_PAGE_CUSTOM1]}${COLOR_RESET}" # Custom sub page
    echo -e "${COLOR_YELLOW}2. ${LANG[CUSTOM_APP_LIST_MENU]}${COLOR_RESET}" # Edit custom app list and branding
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_custom_legiz() {
    show_custom_legiz_menu
    reading "${LANG[LEGIZ_EXTENSIONS_PROMPT]}" LEGIZ_OPTION
    case $LEGIZ_OPTION in
        1)
            if ! command -v yq >/dev/null 2>&1; then
                echo -e "${COLOR_YELLOW}${LANG[INSTALLING_YQ]}${COLOR_RESET}"
                
                if ! wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq >/dev/null 2>&1; then
                    echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOADING_YQ]}${COLOR_RESET}"
                    sleep 2
                    log_clear
                    manage_custom_legiz
                    return 1
                fi
                
                if ! chmod +x /usr/bin/yq; then
                    echo -e "${COLOR_RED}${LANG[ERROR_SETTING_YQ_PERMISSIONS]}${COLOR_RESET}"
                    sleep 2
                    log_clear
                    manage_custom_legiz
                    return 1
                fi
                
                echo -e "${COLOR_GREEN}${LANG[YQ_SUCCESSFULLY_INSTALLED]}${COLOR_RESET}"
                sleep 1
            fi
            
            if ! /usr/bin/yq --version >/dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[YQ_DOESNT_WORK_AFTER_INSTALLATION]}${COLOR_RESET}"
                sleep 2
                log_clear
                manage_custom_legiz
                return 1
            fi
            
            manage_sub_page_upload
            log_clear
            manage_custom_legiz
            ;;
        2)
            echo -e ""
            echo -e "${COLOR_GREEN}${LANG[CUSTOM_APP_LIST_PANEL_MESSAGE]}${COLOR_RESET}"
            echo -e ""
            sleep 2
            log_clear
            manage_custom_legiz
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_custom_legiz
            ;;
    esac
}

show_sub_page_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SELECT_SUB_PAGE_CUSTOM2]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. Orion web page template (support custom app list)${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}2. ${LANG[RESTORE_SUB_PAGE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

download_with_fallback() {
    local primary_url="$1"
    local fallback_url="$2"
    local output_file="$3"

    if curl -s -L -f -o "$output_file" "$primary_url"; then
        return 0
    else
        echo -e "${COLOR_YELLOW}${LANG[DOWNLOAD_FALLBACK]}${COLOR_RESET}"
        if curl -s -L -f -o "$output_file" "$fallback_url"; then
            return 0
        else
            return 1
        fi
    fi
}

branding_add_to_appconfig() {
    local config_file="$1"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${COLOR_RED}Config file not found: $config_file${COLOR_RESET}"
        return 1
    fi
    
    echo -e "${COLOR_GREEN}${LANG[BRANDING_SUPPORT_ASK]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[BRANDING_SUPPORT_YES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[BRANDING_SUPPORT_NO]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[EXTENSIONS_PROMPT]}" BRANDING_OPTION

    case $BRANDING_OPTION in
        1)
            reading "${LANG[BRANDING_NAME_PROMPT]}" BRAND_NAME
            reading "${LANG[BRANDING_SUPPORT_URL_PROMPT]}" SUPPORT_URL
            reading "${LANG[BRANDING_LOGO_URL_PROMPT]}" LOGO_URL
            
            jq --arg name "$BRAND_NAME" \
               --arg supportUrl "$SUPPORT_URL" \
               --arg logoUrl "$LOGO_URL" \
               '.config.branding = {
                   "name": $name,
                   "supportUrl": $supportUrl,
                   "logoUrl": $logoUrl
               }' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
            
            echo -e ""
            echo -e "${COLOR_GREEN}${LANG[BRANDING_ADDED_SUCCESS]}${COLOR_RESET}"
            ;;
        2)
            echo -e "${COLOR_YELLOW}${LANG[BRANDING_SUPPORT_NO]}${COLOR_RESET}"
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
            ;;
    esac
}

manage_sub_page_upload() {
    if [ -d "/opt/remnawave/index.html" ] || [ -d "/opt/remnawave/app-config.json" ]; then
        rm -rf "/opt/remnawave/index.html" "/opt/remnawave/app-config.json"
    fi
    
    if ! docker ps -a --filter "name=remnawave-subscription-page" --format '{{.Names}}' | grep -q "^remnawave-subscription-page$"; then
        printf "${COLOR_RED}${LANG[CONTAINER_NOT_FOUND]}${COLOR_RESET}\n" "remnawave-subscription-page"
        sleep 2
        log_clear
        exit 1
    fi
    
    show_sub_page_menu
    reading "${LANG[SELECT_SUB_PAGE_CUSTOM]}" SUB_PAGE_OPTION

    local config_file="/opt/remnawave/app-config.json"
    local index_file="/opt/remnawave/index.html"
    local docker_compose_file="/opt/remnawave/docker-compose.yml"

    case $SUB_PAGE_OPTION in
        1)
            [ -f "$config_file" ] && rm -f "$config_file"
            [ -f "$index_file" ] && rm -f "$index_file"

            echo -e "${COLOR_YELLOW}${LANG[UPLOADING_SUB_PAGE]}${COLOR_RESET}"
            echo -e ""
            local primary_index_url="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
            local fallback_index_url="https://cdn.jsdelivr.net/gh/legiz-ru/Orion@main/index.html"
            if ! download_with_fallback "$primary_index_url" "$fallback_index_url" "$index_file"; then
                echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                sleep 2
                log_clear
                return 1
            fi

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"
            ;;

        2)
            [ -f "$config_file" ] && rm -f "$config_file"
            [ -f "$index_file" ] && rm -f "$index_file"

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            ;;

        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            log_clear
            manage_custom_legiz
            ;;

        *)
            echo -e "${COLOR_YELLOW}${LANG[SUB_PAGE_SELECT_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_sub_page_upload
            return 1
            ;;
    esac

    /usr/bin/yq eval -i '... comments=""' "$docker_compose_file" 
    
    sed -i -e '/^  [a-zA-Z-]\+:$/ { x; p; x; }' "$docker_compose_file"
    
    sed -i '/./,$!d' "$docker_compose_file"
    
    sed -i -e '/^networks:/i\' -e '' "$docker_compose_file"
    sed -i -e '/^volumes:/i\' -e '' "$docker_compose_file"

    cd /opt/remnawave || return 1
    docker compose down remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"
    echo -e "${COLOR_GREEN}${LANG[SUB_PAGE_UPDATED_SUCCESS]}${COLOR_RESET}"
}

show_custom_app_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CUSTOM_APP_LIST_MENU]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[EDIT_BRANDING]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[DELETE_APPS]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_custom_app_list() {
    local config_file="/opt/remnawave/app-config.json"
    
    if [ ! -f "$config_file" ]; then
        echo -e "${COLOR_RED}${LANG[CUSTOM_APP_LIST_NOT_FOUND]}${COLOR_RESET}"
        sleep 2
        return 1
    fi
    
    show_custom_app_menu
    reading "${LANG[IPV6_PROMPT]}" APP_OPTION
    
    case $APP_OPTION in
        1)
            edit_branding "$config_file"
            ;;
        2)
            delete_applications "$config_file"
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            manage_custom_app_list
            ;;
    esac
}

edit_branding() {
    local config_file="$1"
    local needs_restart=false
    
    # Check if branding exists
    if jq -e '.config.branding' "$config_file" > /dev/null 2>&1; then
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[BRANDING_CURRENT_VALUES]}${COLOR_RESET}"
        local logo_url=$(jq -r '.config.branding.logoUrl // "N/A"' "$config_file")
        local name=$(jq -r '.config.branding.name // "N/A"' "$config_file")
        local support_url=$(jq -r '.config.branding.supportUrl // "N/A"' "$config_file")
        
        echo -e "${COLOR_YELLOW}${LANG[BRANDING_LOGO_URL]} ${COLOR_WHITE}$logo_url${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[BRANDING_NAME]} ${COLOR_WHITE}$name${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[BRANDING_SUPPORT_URL]} ${COLOR_WHITE}$support_url${COLOR_RESET}"
    fi
    
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[EDIT_BRANDING]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[EDIT_LOGO]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[EDIT_NAME]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[EDIT_SUPPORT_URL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[IPV6_PROMPT]}" BRANDING_OPTION
    
    case $BRANDING_OPTION in
        1)
            reading "${LANG[ENTER_NEW_LOGO]}" new_logo
            reading "${LANG[CONFIRM_CHANGE]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                jq --arg logo "$new_logo" '.config.branding.logoUrl = $logo' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        2)
            reading "${LANG[ENTER_NEW_NAME]}" new_name
            reading "${LANG[CONFIRM_CHANGE]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                jq --arg name "$new_name" '.config.branding.name = $name' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        3)
            reading "${LANG[ENTER_NEW_SUPPORT]}" new_support
            reading "${LANG[CONFIRM_CHANGE]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                jq --arg support "$new_support" '.config.branding.supportUrl = $support' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
                needs_restart=true
            fi
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
            sleep 2
            edit_branding "$config_file"
            ;;
    esac
    
    # Restart container if changes were made
    if [ "$needs_restart" = true ]; then
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[BRANDING_ADDED_SUCCESS]}${COLOR_RESET}"
        
        # Restart subscription page container
        cd /opt/remnawave || return 1
        docker compose down remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
    fi
}

delete_applications() {
    local config_file="$1"
    
    # Get platforms with non-empty arrays
    local platforms=$(jq -r '.platforms | to_entries[] | select(.value | length > 0) | .key' "$config_file" 2>/dev/null)
    
    if [ -z "$platforms" ]; then
        echo -e "${COLOR_RED}${LANG[NO_APPS_FOUND]}${COLOR_RESET}"
        sleep 2
        return 1
    fi
    
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[PLATFORM_SELECT]}${COLOR_RESET}"
    echo -e ""
    
    local i=1
    declare -A platform_map
    while IFS= read -r platform; do
        echo -e "${COLOR_YELLOW}$i. $platform${COLOR_RESET}"
        platform_map[$i]="$platform"
        ((i++))
    done <<< "$platforms"
    
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[IPV6_PROMPT]}" PLATFORM_OPTION
    
    if [ "$PLATFORM_OPTION" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi
    
    if [ -z "${platform_map[$PLATFORM_OPTION]}" ]; then
        echo -e "${COLOR_RED}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
        sleep 2
        delete_applications "$config_file"
        return 1
    fi
    
    local selected_platform=${platform_map[$PLATFORM_OPTION]}
    
    # Get applications from selected platform
    local apps=$(jq -r --arg platform "$selected_platform" '.platforms[$platform][] | .name // .id' "$config_file" 2>/dev/null)
    
    if [ -z "$apps" ]; then
        echo -e "${COLOR_RED}${LANG[NO_APPS_FOUND]}${COLOR_RESET}"
        sleep 2
        return 1
    fi
    
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[APP_SELECT]}${COLOR_RESET}"
    echo -e ""
    
    local j=1
    declare -A app_map
    while IFS= read -r app; do
        echo -e "${COLOR_YELLOW}$j. $app${COLOR_RESET}"
        app_map[$j]="$app"
        ((j++))
    done <<< "$apps"
    
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[IPV6_PROMPT]}" APP_DELETE_OPTION
    
    if [ "$APP_DELETE_OPTION" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        return 0
    fi
    
    if [ -z "${app_map[$APP_DELETE_OPTION]}" ]; then
        echo -e "${COLOR_RED}${LANG[INVALID_CHOICE]}${COLOR_RESET}"
        sleep 2
        delete_applications "$config_file"
        return 1
    fi
    
    local selected_app=${app_map[$APP_DELETE_OPTION]}
    
    printf "${COLOR_YELLOW}${LANG[CONFIRM_DELETE_APP]}${COLOR_RESET}\n" "$selected_app" "$selected_platform"
    read confirm
    
    if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
        # Remove the application from the platform array
        jq --arg platform "$selected_platform" --arg app_name "$selected_app" '
        .platforms[$platform] = [.platforms[$platform][] | select((.name // .id) != $app_name)]
        ' "$config_file" > "${config_file}.tmp" && mv "${config_file}.tmp" "$config_file"
        
        echo -e "${COLOR_GREEN}${LANG[APP_DELETED_SUCCESS]}${COLOR_RESET}"
        
        # Restart subscription page container
        cd /opt/remnawave || return 1
        docker compose down remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
        docker compose up -d remnawave-subscription-page > /dev/null 2>&1 &
        spinner $! "${LANG[WAITING]}"
    else
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
    fi
}
#Extensions by legiz

add_cron_rule() {
    local rule="$1"
    local logged_rule="${rule} >> ${DIR_REMNAWAVE}cron_jobs.log 2>&1"

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

#Manage Template for steal
show_template_source_options() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[CHOOSE_TEMPLATE_SOURCE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SIMPLE_WEB_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[SNI_TEMPLATES]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[NOTHING_TEMPLATES]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

randomhtml() {
    local template_source="$1"

    cd /opt/ || { echo "${LANG[UNPACK_ERROR]}"; exit 1; }

    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/ 2>/dev/null

    echo -e "${COLOR_YELLOW}${LANG[RANDOM_TEMPLATE]}${COLOR_RESET}"
    sleep 1
    spinner $$ "${LANG[WAITING]}" &
    spinner_pid=$!

    template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/distillium/sni-templates/archive/refs/heads/main.zip"
        "https://github.com/prettyleaf/nothing-sni/archive/refs/heads/main.zip"
    )

    if [ -z "$template_source" ]; then
        selected_url=${template_urls[$RANDOM % ${#template_urls[@]}]}
    else
        if [ "$template_source" = "simple" ]; then
            selected_url=${template_urls[0]}  # Simple web templates
        elif [ "$template_source" = "sni" ]; then
            selected_url=${template_urls[1]}  # Sni templates
        elif [ "$template_source" = "nothing" ]; then
            selected_url=${template_urls[2]}  # Nothing templates
        else
            selected_url=${template_urls[1]}  # Default to Sni templates
        fi
    fi

    while ! wget -q --timeout=30 --tries=10 --retry-connrefused "$selected_url"; do
        echo "${LANG[DOWNLOAD_FAIL]}"
        sleep 3
    done

    unzip -o main.zip &>/dev/null || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
    rm -f main.zip

    if [[ "$selected_url" == *"eGamesAPI"* ]]; then
        cd simple-web-templates-main/ || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        rm -rf assets ".gitattributes" "README.md" "_config.yml" 2>/dev/null
    elif [[ "$selected_url" == *"nothing-sni"* ]]; then
        cd nothing-sni-main/ || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        rm -rf .github README.md 2>/dev/null
    else
        cd sni-templates-main/ || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi

    # Special handling for nothing-sni - select random HTML file
    if [[ "$selected_url" == *"nothing-sni"* ]]; then
        # Randomly select one HTML file from 1-8.html
        selected_number=$((RANDOM % 8 + 1))
        RandomHTML="${selected_number}.html"
    else
        mapfile -t templates < <(find . -maxdepth 1 -type d -not -path . | sed 's|./||')

        RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"
    fi

    if [[ "$selected_url" == *"distillium"* && "$RandomHTML" == "503 error pages" ]]; then
        cd "$RandomHTML" || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        versions=("v1" "v2")
        RandomVersion="${versions[$RANDOM % ${#versions[@]}]}"
        RandomHTML="$RandomHTML/$RandomVersion"
        cd ..
    fi

    local random_meta_id=$(openssl rand -hex 16)
    local random_comment=$(openssl rand -hex 8)
    local random_class_suffix=$(openssl rand -hex 4)
    local random_title_prefix="Page_"
    local random_title_suffix=$(openssl rand -hex 4)
    local random_footer_text="Designed by RandomSite_${random_title_suffix}"
    local random_id_suffix=$(openssl rand -hex 4)

    local meta_names=("viewport-id" "session-id" "track-id" "render-id" "page-id" "config-id")
    local meta_usernames=("Payee6296" "UserX1234" "AlphaBeta" "GammaRay" "DeltaForce" "EchoZulu" "Foxtrot99" "HotelCalifornia" "IndiaInk" "JulietBravo")
    local random_meta_name=${meta_names[$RANDOM % ${#meta_names[@]}]}
    local random_username=${meta_usernames[$RANDOM % ${#meta_usernames[@]}]}

    local class_prefixes=("style" "data" "ui" "layout" "theme" "view")
    local random_class_prefix=${class_prefixes[$RANDOM % ${#class_prefixes[@]}]}
    local random_class="$random_class_prefix-$random_class_suffix"
    local random_title="${random_title_prefix}${random_title_suffix}"

    find "./$RandomHTML" -type f -name "*.html" -exec sed -i \
        -e "s|<!-- Website template by freewebsitetemplates.com -->||" \
        -e "s|<!-- Theme by: WebThemez.com -->||" \
        -e "s|<a href=\"http://freewebsitetemplates.com\">Free Website Templates</a>|<span>${random_footer_text}</span>|" \
        -e "s|<a href=\"http://webthemez.com\" alt=\"webthemez\">WebThemez.com</a>|<span>${random_footer_text}</span>|" \
        -e "s|id=\"Content\"|id=\"rnd_${random_id_suffix}\"|" \
        -e "s|id=\"subscribe\"|id=\"sub_${random_id_suffix}\"|" \
        -e "s|<title>.*</title>|<title>${random_title}</title>|" \
        -e "s/<\/head>/<meta name=\"$random_meta_name\" content=\"$random_meta_id\">\n<!-- $random_comment -->\n<\/head>/" \
        -e "s/<body/<body class=\"$random_class\"/" \
        -e "s/CHANGEMEPLS/$random_username/g" \
        {} \;

    find "./$RandomHTML" -type f -name "*.css" -exec sed -i \
        -e "1i\/* $random_comment */" \
        -e "1i.$random_class { display: block; }" \
        {} \;

    kill "$spinner_pid" 2>/dev/null
    wait "$spinner_pid" 2>/dev/null
    printf "\r\033[K" > /dev/tty

    echo "${LANG[SELECT_TEMPLATE]}" "${RandomHTML}"

    if [[ -d "${RandomHTML}" ]]; then
        if [[ ! -d "/var/www/html/" ]]; then
            mkdir -p "/var/www/html/" || { echo "Failed to create /var/www/html/"; exit 1; }
        fi
        rm -rf /var/www/html/*
        cp -a "${RandomHTML}"/. "/var/www/html/"
        echo "${LANG[TEMPLATE_COPY]}"
    elif [[ -f "${RandomHTML}" ]]; then
        cp "${RandomHTML}" "/var/www/html/index.html"
        echo "${LANG[TEMPLATE_COPY]}"
    else
        echo "${LANG[UNPACK_ERROR]}" && exit 1
    fi

    if ! find "/var/www/html" -type f -name "*.html" -exec grep -q "$random_meta_name" {} \; 2>/dev/null; then
        echo -e "${COLOR_RED}${LANG[FAILED_TO_MODIFY_HTML_FILES]}${COLOR_RESET}"
        return 1
    fi

    cd /opt/
    rm -rf simple-web-templates-main/ sni-templates-main/ nothing-sni-main/
}
#Manage Template for steal

install_packages() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALL_PACKAGES]}${COLOR_RESET}"
    
    if ! apt-get update -y; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_LIST]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! apt-get install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git certbot python3-certbot-dns-cloudflare unattended-upgrades locales dnsutils coreutils grep gawk python3-pip; then
        echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_PACKAGES]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! dpkg -l | grep -q '^ii.*cron '; then
        if ! apt-get install -y cron; then
            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CRON]}" "${COLOR_RESET}" >&2
            return 1
        fi
    fi

    if ! systemctl is-active --quiet cron; then
        if ! systemctl start cron; then
            echo -e "${COLOR_RED}${LANG[START_CRON_ERROR]}${COLOR_RESET}" >&2
            return 1
        fi
    fi
    if ! systemctl is-enabled --quiet cron; then
        if ! systemctl enable cron; then
            echo -e "${COLOR_RED}${LANG[START_CRON_ERROR]}${COLOR_RESET}" >&2
            return 1
        fi
    fi

    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
        echo -e "${COLOR_YELLOW}Installing Docker via get.docker.com...${COLOR_RESET}"

        if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
            echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOAD_DOCKER_KEY]}${COLOR_RESET}" >&2
            return 1
        fi

        if ! sh /tmp/get-docker.sh; then
            echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}" >&2
            return 1
        fi
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
    if ! ufw allow 22/tcp comment 'SSH' || ! ufw allow 443/tcp comment 'HTTPS' || ! ufw --force enable; then
        echo -e "${COLOR_RED}${LANG[ERROR_CONFIGURE_UFW]}${COLOR_RESET}" >&2
        return 1
    fi

    # Unattended-upgrades
    echo 'Unattended-Upgrade::Mail "root";' >> /etc/apt/apt.conf.d/50unattended-upgrades
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true | debconf-set-selections
    if ! dpkg-reconfigure -f noninteractive unattended-upgrades || ! systemctl restart unattended-upgrades; then
        echo -e "${COLOR_RED}${LANG[ERROR_CONFIGURE_UPGRADES]}" "${COLOR_RESET}" >&2
        return 1
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

    if [ -z "$domain_ip" ] || [ -z "$server_ip" ]; then
        if [ "$show_warning" = true ]; then
            echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_RED}${LANG[CHECK_DOMAIN_IP_FAIL]}${COLOR_RESET}"
            printf "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_IP_FAIL_INSTRUCTION]}${COLOR_RESET}\n" "$domain" "$server_ip"
            reading "${LANG[CONFIRM_PROMPT]}" confirm
            if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
                return 2
            fi
        fi
        return 1
    fi

    local cf_ranges=$(curl -s https://www.cloudflare.com/ips-v4)
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
    elif [ "$ip_in_cloudflare" = true ]; then
        if [ "$allow_cf_proxy" = true ]; then
            return 0
        else
            if [ "$show_warning" = true ]; then
                echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
                printf "${COLOR_RED}${LANG[CHECK_DOMAIN_CLOUDFLARE]}${COLOR_RESET}\n" "$domain" "$domain_ip"
                echo -e "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_CLOUDFLARE_INSTRUCTION]}${COLOR_RESET}"
                reading "${LANG[CONFIRM_PROMPT]}" confirm
                if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                    return 1
                else
                    return 2
                fi
            fi
            return 1
        fi
    else
        if [ "$show_warning" = true ]; then
            echo -e "${COLOR_YELLOW}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            printf "${COLOR_RED}${LANG[CHECK_DOMAIN_MISMATCH]}${COLOR_RESET}\n" "$domain" "$domain_ip" "$server_ip"
            echo -e "${COLOR_YELLOW}${LANG[CHECK_DOMAIN_MISMATCH_INSTRUCTION]}${COLOR_RESET}"
            reading "${LANG[CONFIRM_PROMPT]}" confirm
            if [[ "$confirm" == "y" || "$confirm" == "Y" ]]; then
                return 1
            else
                return 2
            fi
        fi
        return 1
    fi

    return 0
}

is_wildcard_cert() {
    local domain=$1
    local cert_path="/etc/letsencrypt/live/$domain/fullchain.pem"

    if [ ! -f "$cert_path" ]; then
        return 1
    fi

    if openssl x509 -noout -text -in "$cert_path" | grep -q "\*\.$domain"; then
        return 0
    else
        return 1
    fi
}

check_certificates() {
    local DOMAIN=$1
    local cert_dir="/etc/letsencrypt/live"

    if [ ! -d "$cert_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN${COLOR_RESET}"
        return 1
    fi

    local live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${DOMAIN}*" 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$live_dir" ] && [ -d "$live_dir" ]; then
        local files=("cert.pem" "chain.pem" "fullchain.pem" "privkey.pem")
        for file in "${files[@]}"; do
            local file_path="$live_dir/$file"
            if [ ! -f "$file_path" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN (missing $file)${COLOR_RESET}"
                return 1
            fi
            if [ ! -L "$file_path" ]; then
                fix_letsencrypt_structure "$(basename "$live_dir")"
                if [ $? -ne 0 ]; then
                    echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN (failed to fix structure)${COLOR_RESET}"
                    return 1
                fi
            fi
        done
        echo -e "${COLOR_GREEN}${LANG[CERT_FOUND]}$(basename "$live_dir")${COLOR_RESET}"
        return 0
    fi

    local base_domain=$(extract_domain "$DOMAIN")
    if [ "$base_domain" != "$DOMAIN" ]; then
        live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${base_domain}*" 2>/dev/null | sort -V | tail -n 1)
        if [ -n "$live_dir" ] && [ -d "$live_dir" ] && is_wildcard_cert "$base_domain"; then
            echo -e "${COLOR_GREEN}${LANG[WILDCARD_CERT_FOUND]}$base_domain ${LANG[FOR_DOMAIN]} $DOMAIN${COLOR_RESET}"
            return 0
        fi
    fi

    echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]} $DOMAIN${COLOR_RESET}"
    return 1
}

check_api() {
    local attempts=3
    local attempt=1

    while [ $attempt -le $attempts ]; do
        if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "Authorization: Bearer ${CLOUDFLARE_API_KEY}" --header "Content-Type: application/json")
        else
            api_response=$(curl --silent --request GET --url https://api.cloudflare.com/client/v4/zones --header "X-Auth-Key: ${CLOUDFLARE_API_KEY}" --header "X-Auth-Email: ${CLOUDFLARE_EMAIL}" --header "Content-Type: application/json")
        fi

        if echo "$api_response" | grep -q '"success":true'; then
            echo -e "${COLOR_GREEN}${LANG[CF_VALIDATING]}${COLOR_RESET}"
            return 0
        else
            echo -e "${COLOR_RED}$(printf "${LANG[CF_INVALID_ATTEMPT]}" "$attempt" "$attempts")${COLOR_RESET}"
            if [ $attempt -lt $attempts ]; then
                reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
                reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL
            fi
            attempt=$((attempt + 1))
        fi
    done
    error "$(printf "${LANG[CF_INVALID]}" "$attempts")"
}

get_certificates() {
    local DOMAIN=$1
    local CERT_METHOD=$2
    local LETSENCRYPT_EMAIL=$3
    local BASE_DOMAIN=$(extract_domain "$DOMAIN")
    local WILDCARD_DOMAIN="*.$BASE_DOMAIN"

    printf "${COLOR_YELLOW}${LANG[GENERATING_CERTS]}${COLOR_RESET}\n" "$DOMAIN"

    case $CERT_METHOD in
        1)
            # Cloudflare API (DNS-01 support wildcard)
            reading "${LANG[ENTER_CF_TOKEN]}" CLOUDFLARE_API_KEY
            reading "${LANG[ENTER_CF_EMAIL]}" CLOUDFLARE_EMAIL

            check_api

            mkdir -p ~/.secrets/certbot
            if [[ $CLOUDFLARE_API_KEY =~ [A-Z] ]]; then
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_api_token = $CLOUDFLARE_API_KEY
EOL
            else
                cat > ~/.secrets/certbot/cloudflare.ini <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
            fi
            chmod 600 ~/.secrets/certbot/cloudflare.ini

            certbot certonly \
                --dns-cloudflare \
                --dns-cloudflare-credentials ~/.secrets/certbot/cloudflare.ini \
                --dns-cloudflare-propagation-seconds 60 \
                -d "$BASE_DOMAIN" \
                -d "$WILDCARD_DOMAIN" \
                --email "$CLOUDFLARE_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            ;;
        2)
            # ACME HTTP-01 (without wildcard)
            ufw allow 80/tcp comment 'HTTP for ACME challenge' > /dev/null 2>&1

            certbot certonly \
                --standalone \
                -d "$DOMAIN" \
                --email "$LETSENCRYPT_EMAIL" \
                --agree-tos \
                --non-interactive \
                --http-01-port 80 \
                --key-type ecdsa \
                --elliptic-curve secp384r1

            ufw delete allow 80/tcp > /dev/null 2>&1
            ufw reload > /dev/null 2>&1
            ;;
        3)
            # Gcore DNS-01 (wildcard)

            if ! certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                echo -e "${COLOR_YELLOW}Installing certbot-dns-gcore plugin...${COLOR_RESET}"
                
                if python3 -m pip install --help 2>&1 | grep -q "break-system-packages"; then
                    python3 -m pip install --break-system-packages certbot-dns-gcore >/dev/null 2>&1
                else
                python3 -m pip install certbot-dns-gcore >/dev/null 2>&1
                fi
                    
                if certbot plugins 2>/dev/null | grep -q "dns-gcore"; then
                    echo -e "${COLOR_GREEN}Plugin installed successfully.${COLOR_RESET}"
                else
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_GCORE_PLUGIN]}${COLOR_RESET}"
                    exit 1
                fi
            else
                echo -e "${COLOR_GREEN}Gcore plugin already available.${COLOR_RESET}"
            fi

            reading "${LANG[ENTER_GCORE_TOKEN]}" GCORE_API_KEY

            mkdir -p ~/.secrets/certbot
            cat > ~/.secrets/certbot/gcore.ini <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
            chmod 600 ~/.secrets/certbot/gcore.ini

            certbot certonly \
                --authenticator dns-gcore \
                --dns-gcore-credentials ~/.secrets/certbot/gcore.ini \
                --dns-gcore-propagation-seconds 80 \
                -d "$BASE_DOMAIN" \
                -d "$WILDCARD_DOMAIN" \
                --email "$LETSENCRYPT_EMAIL" \
                --agree-tos \
                --non-interactive \
                --key-type ecdsa \
                --elliptic-curve secp384r1
            ;;
        *)
            echo -e "${COLOR_RED}${LANG[INVALID_CERT_METHOD]}${COLOR_RESET}"
            exit 1
            ;;
    esac

    if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $DOMAIN${COLOR_RESET}"
        exit 1
    fi
}

#Manage Certificates
show_manage_certificates() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_8]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[CERT_UPDATE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[CERT_GENERATE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_certificates() {
    show_manage_certificates
    reading "${LANG[CERT_PROMPT1]}" CERT_OPTION
    case $CERT_OPTION in
        1)
            if ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CERTBOT]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            update_current_certificates
            log_clear
            ;;
        2)
            if ! command -v certbot >/dev/null 2>&1; then
                install_packages || {
                    echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_CERTBOT]}${COLOR_RESET}"
                    log_clear
                    exit 1
                }
            fi
            generate_new_certificates
            log_clear
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            remnawave_reverse
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
            exit 1
            ;;
    esac
}

update_current_certificates() {
    local cert_dir="/etc/letsencrypt/live"
    if [ ! -d "$cert_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]}${COLOR_RESET}"
        exit 1
    fi

    declare -A unique_domains
    declare -A cert_status
    local renew_threshold=30
    local log_dir="/var/log/letsencrypt"

    if [ ! -d "$log_dir" ]; then
        mkdir -p "$log_dir"
        chmod 755 "$log_dir"
    fi

    for domain_dir in "$cert_dir"/*; do
        if [ -d "$domain_dir" ]; then
            local domain=$(basename "$domain_dir")
            local cert_domain
            cert_domain=$(echo "$domain" | sed -E 's/(-[0-9]+)$//')
            unique_domains["$cert_domain"]="$domain_dir"
        fi
    done

    for cert_domain in "${!unique_domains[@]}"; do
        local domain_dir="${unique_domains[$cert_domain]}"
        local domain
        domain=$(basename "$domain_dir")

        local cert_method="2" # 2 = ACME HTTP-01
        local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"

        if [ -f "$renewal_conf" ]; then
            if grep -q "dns_cloudflare" "$renewal_conf"; then
                cert_method="1" # Cloudflare DNS-01
            elif grep -q "dns-gcore" "$renewal_conf"; then
                cert_method="3" # Gcore DNS-01
            fi
        fi

        local cert_file="$domain_dir/fullchain.pem"
        local cert_mtime_before
        cert_mtime_before=$(stat -c %Y "$cert_file" 2>/dev/null || echo 0)

        fix_letsencrypt_structure "$cert_domain"

        local days_left
        days_left=$(check_cert_expiry "$domain")
        if [ $? -ne 0 ]; then
            cert_status["$cert_domain"]="${LANG[ERROR_PARSING_CERT]}"
            continue
        fi

        if [ "$cert_method" == "1" ]; then
            # Cloudflare
            local cf_credentials_file
            cf_credentials_file=$(grep "dns_cloudflare_credentials" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$cf_credentials_file" ] && [ ! -f "$cf_credentials_file" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_CLOUDFLARE_FILE_NOT_FOUND]}${COLOR_RESET}"
                reading "${COLOR_YELLOW}${LANG[ENTER_CF_EMAIL]}${COLOR_RESET}" CLOUDFLARE_EMAIL
                reading "${COLOR_YELLOW}${LANG[ENTER_CF_TOKEN]}${COLOR_RESET}" CLOUDFLARE_API_KEY

                check_api

                mkdir -p "$(dirname "$cf_credentials_file")"
                cat > "$cf_credentials_file" <<EOL
dns_cloudflare_email = $CLOUDFLARE_EMAIL
dns_cloudflare_api_key = $CLOUDFLARE_API_KEY
EOL
                chmod 600 "$cf_credentials_file"
            fi
        elif [ "$cert_method" == "3" ]; then
            # Gcore
            local gcore_credentials_file
            gcore_credentials_file=$(grep "dns-gcore-credentials" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
            if [ -n "$gcore_credentials_file" ] && [ ! -f "$gcore_credentials_file" ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GCORE_FILE_NOT_FOUND]}${COLOR_RESET}"
                reading "${COLOR_YELLOW}${LANG[ENTER_GCORE_TOKEN]}${COLOR_RESET}" GCORE_API_KEY

                mkdir -p "$(dirname "$gcore_credentials_file")"
                cat > "$gcore_credentials_file" <<EOL
dns_gcore_apitoken = $GCORE_API_KEY
EOL
                chmod 600 "$gcore_credentials_file"
            fi
        fi

        if [ "$days_left" -le "$renew_threshold" ]; then
            if [ "$cert_method" == "2" ]; then
                ufw allow 80/tcp && ufw reload >/dev/null 2>&1
            fi

            certbot renew --cert-name "$domain" --no-random-sleep-on-renew >> /var/log/letsencrypt/letsencrypt.log 2>&1 &
            local cert_pid=$!
            spinner $cert_pid "${LANG[WAITING]}"
            wait $cert_pid
            local certbot_exit_code=$?

            if [ "$cert_method" == "2" ]; then
                ufw delete allow 80/tcp && ufw reload >/dev/null 2>&1
            fi

            if [ "$certbot_exit_code" -ne 0 ]; then
                cert_status["$cert_domain"]="${LANG[ERROR_UPDATE]}: ${LANG[RATE_LIMIT_EXCEEDED]}"
                continue
            fi

            local new_cert_dir
            new_cert_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "$cert_domain*" | sort -V | tail -n 1)
            local new_domain
            new_domain=$(basename "$new_cert_dir")
            local cert_mtime_after
            cert_mtime_after=$(stat -c %Y "$new_cert_dir/fullchain.pem" 2>/dev/null || echo 0)

            if check_certificates "$new_domain" > /dev/null 2>&1 && [ "$cert_mtime_before" != "$cert_mtime_after" ]; then
                local new_days_left
                new_days_left=$(check_cert_expiry "$new_domain")
                if [ $? -eq 0 ]; then
                    cert_status["$cert_domain"]="${LANG[UPDATED]}"
                else
                    cert_status["$cert_domain"]="${LANG[ERROR_PARSING_CERT]}"
                fi
            else
                cert_status["$cert_domain"]="${LANG[ERROR_UPDATE]}"
            fi
        else
            cert_status["$cert_domain"]="${LANG[REMAINING]} $days_left ${LANG[DAYS]}"
            continue
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[RESULTS_CERTIFICATE_UPDATES]}${COLOR_RESET}"
    for cert_domain in "${!cert_status[@]}"; do
        if [[ "${cert_status[$cert_domain]}" == "${LANG[UPDATED]}" ]]; then
            echo -e "${COLOR_GREEN}${LANG[CERTIFICATE_FOR]}$cert_domain ${LANG[SUCCESSFULLY_UPDATED]}${COLOR_RESET}"
        elif [[ "${cert_status[$cert_domain]}" =~ "${LANG[ERROR_UPDATE]}" ]]; then
            echo -e "${COLOR_RED}${LANG[FAILED_TO_UPDATE_CERTIFICATE_FOR]}$cert_domain: ${cert_status[$cert_domain]}${COLOR_RESET}"
        elif [[ "${cert_status[$cert_domain]}" == "${LANG[ERROR_PARSING_CERT]}" ]]; then
            echo -e "${COLOR_RED}${LANG[ERROR_CHECKING_EXPIRY_FOR]}$cert_domain${COLOR_RESET}"
        else
            echo -e "${COLOR_YELLOW}${LANG[CERTIFICATE_FOR]}$cert_domain ${LANG[DOES_NOT_REQUIRE_UPDATE]}${cert_status[$cert_domain]})${COLOR_RESET}"
        fi
    done

    sleep 2
    log_clear
    remnawave_reverse
}

generate_new_certificates() {
    reading "${LANG[CERT_GENERATE_PROMPT]}" NEW_DOMAIN

    echo -e "${COLOR_YELLOW}${LANG[CERT_METHOD_PROMPT]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[CERT_METHOD_CF]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[CERT_METHOD_ACME]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. ${LANG[CERT_METHOD_GCORE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[CERT_METHOD_CHOOSE]}" CERT_METHOD

    if [ "$CERT_METHOD" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        exit 1
    fi

    local LETSENCRYPT_EMAIL=""
    if [ "$CERT_METHOD" == "2" ] || [ "$CERT_METHOD" == "3" ]; then
        reading "${LANG[EMAIL_PROMPT]}" LETSENCRYPT_EMAIL
    fi

    if [ "$CERT_METHOD" == "1" ] || [ "$CERT_METHOD" == "3" ]; then
        # 1 = CF DNS-01, 3 = Gcore DNS-01 — wildcard
        echo -e "${COLOR_YELLOW}${LANG[GENERATING_WILDCARD_CERT]} *.$NEW_DOMAIN...${COLOR_RESET}"
        get_certificates "$NEW_DOMAIN" "$CERT_METHOD" "$LETSENCRYPT_EMAIL"
    elif [ "$CERT_METHOD" == "2" ]; then
        # 2 = ACME HTTP-01
        echo -e "${COLOR_YELLOW}${LANG[GENERATING_CERTS]} $NEW_DOMAIN...${COLOR_RESET}"
        get_certificates "$NEW_DOMAIN" "2" "$LETSENCRYPT_EMAIL"
    else
        echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
        exit 1
    fi

    if check_certificates "$NEW_DOMAIN"; then
        echo -e "${COLOR_GREEN}${LANG[CERT_UPDATE_SUCCESS]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]}${COLOR_RESET}"
    fi

    sleep 2
    log_clear
    remnawave_reverse
}

check_cert_expiry() {
    local domain="$1"
    local cert_dir="/etc/letsencrypt/live"
    local live_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "${domain}*" | sort -V | tail -n 1)
    if [ -z "$live_dir" ] || [ ! -d "$live_dir" ]; then
        return 1
    fi
    local cert_file="$live_dir/fullchain.pem"
    if [ ! -f "$cert_file" ]; then
        return 1
    fi
    local expiry_date=$(openssl x509 -in "$cert_file" -noout -enddate | sed 's/notAfter=//')
    if [ -z "$expiry_date" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PARSING_CERT]}${COLOR_RESET}"
        return 1
    fi
    local expiry_epoch=$(TZ=UTC date -d "$expiry_date" +%s 2>/dev/null)
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PARSING_CERT]}${COLOR_RESET}"
        return 1
    fi
    local current_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - current_epoch) / 86400 ))
    echo "$days_left"
    return 0
}

fix_letsencrypt_structure() {
    local domain=$1
    local live_dir="/etc/letsencrypt/live/$domain"
    local archive_dir="/etc/letsencrypt/archive/$domain"
    local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"

    if [ ! -d "$live_dir" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi
    if [ ! -d "$archive_dir" ]; then
        echo -e "${COLOR_RED}${LANG[ARCHIVE_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi
    if [ ! -f "$renewal_conf" ]; then
        echo -e "${COLOR_RED}${LANG[RENEWAL_CONF_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi

    local conf_archive_dir=$(grep "^archive_dir" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
    if [ "$conf_archive_dir" != "$archive_dir" ]; then
        echo -e "${COLOR_RED}${LANG[ARCHIVE_DIR_MISMATCH]}${COLOR_RESET}"
        return 1
    fi

    local latest_version=$(ls -1 "$archive_dir" | grep -E 'cert[0-9]+.pem' | sort -V | tail -n 1 | sed -E 's/.*cert([0-9]+)\.pem/\1/')
    if [ -z "$latest_version" ]; then
        echo -e "${COLOR_RED}${LANG[CERT_VERSION_NOT_FOUND]}${COLOR_RESET}"
        return 1
    fi

    local files=("cert" "chain" "fullchain" "privkey")
    for file in "${files[@]}"; do
        local archive_file="$archive_dir/$file$latest_version.pem"
        local live_file="$live_dir/$file.pem"
        if [ ! -f "$archive_file" ]; then
            echo -e "${COLOR_RED}${LANG[FILE_NOT_FOUND]} $archive_file${COLOR_RESET}"
            return 1
        fi
        if [ -f "$live_file" ] && [ ! -L "$live_file" ]; then
            rm "$live_file"
        fi
        ln -sf "$archive_file" "$live_file"
    done

    local cert_path="$live_dir/cert.pem"
    local chain_path="$live_dir/chain.pem"
    local fullchain_path="$live_dir/fullchain.pem"
    local privkey_path="$live_dir/privkey.pem"
    if ! grep -q "^cert = $cert_path" "$renewal_conf"; then
        sed -i "s|^cert =.*|cert = $cert_path|" "$renewal_conf"
    fi
    if ! grep -q "^chain = $chain_path" "$renewal_conf"; then
        sed -i "s|^chain =.*|chain = $chain_path|" "$renewal_conf"
    fi
    if ! grep -q "^fullchain = $fullchain_path" "$renewal_conf"; then
        sed -i "s|^fullchain =.*|fullchain = $fullchain_path|" "$renewal_conf"
    fi
    if ! grep -q "^privkey = $privkey_path" "$renewal_conf"; then
        sed -i "s|^privkey =.*|privkey = $privkey_path|" "$renewal_conf"
    fi

    local expected_hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx && docker compose exec remnawave-nginx nginx -s reload'"
    sed -i '/^renew_hook/d' "$renewal_conf"
    echo "$expected_hook" >> "$renewal_conf"

    chmod 644 "$live_dir/cert.pem" "$live_dir/chain.pem" "$live_dir/fullchain.pem"
    chmod 600 "$live_dir/privkey.pem"
    return 0
}
#Manage Certificates

handle_certificates() {
    local -n domains_to_check_ref=$1
    local cert_method="$2"
    local letsencrypt_email="$3"
    local target_dir="/opt/remnawave"

    declare -A unique_domains
    local need_certificates=false
    local min_days_left=9999

    echo -e "${COLOR_YELLOW}${LANG[CHECK_CERTS]}${COLOR_RESET}"
    sleep 1

    echo -e "${COLOR_YELLOW}${LANG[REQUIRED_DOMAINS]}${COLOR_RESET}"
    for domain in "${!domains_to_check_ref[@]}"; do
        echo -e "${COLOR_WHITE}- $domain${COLOR_RESET}"
    done

    for domain in "${!domains_to_check_ref[@]}"; do
        if ! check_certificates "$domain"; then
            need_certificates=true
        else
            days_left=$(check_cert_expiry "$domain")
            if [ $? -eq 0 ] && [ "$days_left" -lt "$min_days_left" ]; then
                min_days_left=$days_left
            fi
        fi
    done

    if [ "$need_certificates" = true ]; then
        echo -e ""
        echo -e "${COLOR_YELLOW}${LANG[CERT_METHOD_PROMPT]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}1. ${LANG[CERT_METHOD_CF]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}2. ${LANG[CERT_METHOD_ACME]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}3. ${LANG[CERT_METHOD_GCORE]}${COLOR_RESET}"
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "${LANG[CERT_METHOD_CHOOSE]}" cert_method

        if [ "$cert_method" == "0" ]; then
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            exit 1
        elif [ "$cert_method" == "2" ] || [ "$cert_method" == "3" ]; then
            reading "${LANG[EMAIL_PROMPT]}" letsencrypt_email
        elif [ "$cert_method" != "1" ]; then
            echo -e "${COLOR_RED}${LANG[CERT_INVALID_CHOICE]}${COLOR_RESET}"
            exit 1
        fi
    else
        echo -e "${COLOR_GREEN}${LANG[CERTS_SKIPPED]}${COLOR_RESET}"
        cert_method="1"
    fi

    declare -A cert_domains_added

    if [ "$need_certificates" = true ] && [ "$cert_method" == "1" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        for domain in "${!unique_domains[@]}"; do
            get_certificates "$domain" "1" ""
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                return 1
            fi
            min_days_left=90
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done

    elif [ "$need_certificates" = true ] && [ "$cert_method" == "3" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        for domain in "${!unique_domains[@]}"; do
            get_certificates "$domain" "3" "$letsencrypt_email"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                return 1
            fi
            min_days_left=90
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done

    elif [ "$need_certificates" = true ] && [ "$cert_method" == "2" ]; then
        for domain in "${!domains_to_check_ref[@]}"; do
            get_certificates "$domain" "2" "$letsencrypt_email"
            if [ $? -ne 0 ]; then
                echo -e "${COLOR_RED}${LANG[CERT_GENERATION_FAILED]} $domain${COLOR_RESET}"
                continue
            fi
            if [ -z "${cert_domains_added[$domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$domain/fullchain.pem:/etc/nginx/ssl/$domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$domain/privkey.pem:/etc/nginx/ssl/$domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$domain"]="1"
            fi
        done
    else
        for domain in "${!domains_to_check_ref[@]}"; do
            local base_domain
            base_domain=$(extract_domain "$domain")
            local cert_domain="$domain"
            if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
                cert_domain="$base_domain"
            fi
            if [ -z "${cert_domains_added[$cert_domain]}" ]; then
                echo "      - /etc/letsencrypt/live/$cert_domain/fullchain.pem:/etc/nginx/ssl/$cert_domain/fullchain.pem:ro" >> "$target_dir/docker-compose.yml"
                echo "      - /etc/letsencrypt/live/$cert_domain/privkey.pem:/etc/nginx/ssl/$cert_domain/privkey.pem:ro" >> "$target_dir/docker-compose.yml"
                cert_domains_added["$cert_domain"]="1"
            fi
        done
    fi

    local cron_command
    if [ "$cert_method" == "2" ]; then
        cron_command="ufw allow 80 && /usr/bin/certbot renew --quiet && ufw delete allow 80 && ufw reload && cd /opt/remnawave && docker compose down && docker compose up"
    else
        cron_command="/usr/bin/certbot renew --quiet"
    fi

    if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew"; then
        echo -e "${COLOR_YELLOW}${LANG[ADDING_CRON_FOR_EXISTING_CERTS]}${COLOR_RESET}"
        add_cron_rule "0 5 * * 0 $cron_command"
    elif [ "$min_days_left" -le 30 ] && ! crontab -u root -l 2>/dev/null | grep -q "0 5 * * 0.*$cron_command"; then
        echo -e "${COLOR_YELLOW}${LANG[CERT_EXPIRY_SOON]} $min_days_left ${LANG[DAYS]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[UPDATING_CRON]}${COLOR_RESET}"
        crontab -u root -l 2>/dev/null | grep -v "/usr/bin/certbot renew" | crontab -u root -
        add_cron_rule "0 5 * * 0 $cron_command"
    else
        echo -e "${COLOR_YELLOW}${LANG[CRON_ALREADY_EXISTS]}${COLOR_RESET}"
    fi

    for domain in "${!unique_domains[@]}"; do
        if [ -f "/etc/letsencrypt/renewal/$domain.conf" ]; then
            desired_hook="renew_hook = sh -c 'cd /opt/remnawave && docker compose down remnawave-nginx && docker compose up -d remnawave-nginx'"
            if ! grep -q "renew_hook" "/etc/letsencrypt/renewal/$domain.conf"; then
                echo "$desired_hook" >> "/etc/letsencrypt/renewal/$domain.conf"
            elif ! grep -Fx "$desired_hook" "/etc/letsencrypt/renewal/$domain.conf"; then
                sed -i "/renew_hook/c\\$desired_hook" "/etc/letsencrypt/renewal/$domain.conf"
                echo -e "${COLOR_YELLOW}${LANG[UPDATED_RENEW_AUTH]}${COLOR_RESET}"
            fi
        fi
    done
}

# Module: Install Panel + Node
load_install_panel_node_module() {
    local module_file="${DIR_REMNAWAVE}modules/install_panel_node.sh"

    if [ ! -f "$module_file" ]; then
        local module_url="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/dev/src/modules/install_panel_node.sh"
        mkdir -p "${DIR_REMNAWAVE}modules"
        if command -v curl &> /dev/null; then
            curl -sL "$module_url" -o "$module_file" 2>/dev/null
        elif command -v wget &> /dev/null; then
            wget -q "$module_url" -O "$module_file" 2>/dev/null
        fi
    fi

    if [ -f "$module_file" ]; then
        source "$module_file"
    else
        error "Failed to load install panel/node module"
        exit 1
    fi
}

# Module: Install Panel Only
load_install_panel_module() {
    local module_file="${DIR_REMNAWAVE}modules/install_panel.sh"

    if [ ! -f "$module_file" ]; then
        local module_url="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/dev/src/modules/install_panel.sh"
        mkdir -p "${DIR_REMNAWAVE}modules"
        if command -v curl &> /dev/null; then
            curl -sL "$module_url" -o "$module_file" 2>/dev/null
        elif command -v wget &> /dev/null; then
            wget -q "$module_url" -O "$module_file" 2>/dev/null
        fi
    fi

    if [ -f "$module_file" ]; then
        source "$module_file"
    else
        error "Failed to load install panel module"
        exit 1
    fi
}

# Module: Remnawave API
load_api_module() {
    local api_file="${DIR_REMNAWAVE}api/remnawave_api.sh"

    if [ ! -f "$api_file" ]; then
        local api_url="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/dev/src/api/remnawave_api.sh"
        mkdir -p "${DIR_REMNAWAVE}api"
        if command -v curl &> /dev/null; then
            curl -sL "$api_url" -o "$api_file" 2>/dev/null
        elif command -v wget &> /dev/null; then
            wget -q "$api_url" -O "$api_file" 2>/dev/null
        fi
    fi

    if [ -f "$api_file" ]; then
        source "$api_file"
    else
        error "Failed to load Remnawave API module"
        exit 1
    fi
}

#Install Node
install_remnawave_node() {
    mkdir -p /opt/remnawave && cd /opt/remnawave

    reading "${LANG[SELFSTEAL]}" SELFSTEAL_DOMAIN

    check_domain "$SELFSTEAL_DOMAIN" true false
    local domain_check_result=$?
    if [ $domain_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    while true; do
        reading "${LANG[PANEL_IP_PROMPT]}" PANEL_IP
        if echo "$PANEL_IP" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' >/dev/null && \
           [[ $(echo "$PANEL_IP" | tr '.' '\n' | wc -l) -eq 4 ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -vE '^[0-9]{1,3}$') ]] && \
           [[ ! $(echo "$PANEL_IP" | tr '.' '\n' | grep -E '^(25[6-9]|2[6-9][0-9]|[3-9][0-9]{2})$') ]]; then
            break
        else
            echo -e "${COLOR_RED}${LANG[IP_ERROR]}${COLOR_RESET}"
        fi
    done

    echo -n "$(question "${LANG[CERT_PROMPT]}")"
    CERTIFICATE=""
    while IFS= read -r line; do
        if [ -z "$line" ]; then
            if [ -n "$CERTIFICATE" ]; then
                break
            fi
        else
            CERTIFICATE="$CERTIFICATE$line\n"
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[CERT_CONFIRM]}${COLOR_RESET}"
    read confirm
    echo

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

SELFSTEAL_BASE_DOMAIN=$(extract_domain "$SELFSTEAL_DOMAIN")

unique_domains["$SELFSTEAL_BASE_DOMAIN"]=1

cat > docker-compose.yml <<EOL
services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL
}

installation_node() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_NODE]}${COLOR_RESET}"
    sleep 1

    declare -A unique_domains
    install_remnawave_node

    declare -A domains_to_check
    domains_to_check["$SELFSTEAL_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL"

    if [ -z "$CERT_METHOD" ]; then
        local base_domain=$(extract_domain "$SELFSTEAL_DOMAIN")
        if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
            CERT_METHOD="1"
        else
            CERT_METHOD="2"
        fi
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        local base_domain=$(extract_domain "$SELFSTEAL_DOMAIN")
        NODE_CERT_DOMAIN="$base_domain"
    else
        NODE_CERT_DOMAIN="$SELFSTEAL_DOMAIN"
    fi

    cat >> /opt/remnawave/docker-compose.yml <<EOL
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && exec nginx -g "daemon off;"'
    network_mode: host
    depends_on:
      - remnanode
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnanode:
    image: remnawave/node:latest
    container_name: remnanode
    hostname: remnanode
    restart: always
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    network_mode: host
    environment:
      - NODE_PORT=2222
      - SECRET_KEY=$(echo -e "$CERTIFICATE")
    volumes:
      - /dev/shm:/dev/shm:rw
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'
EOL

cat > /opt/remnawave/nginx.conf <<EOL
server_names_hash_bucket_size 64;

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name $SELFSTEAL_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";

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

    ufw allow from $PANEL_IP to any port 2222 > /dev/null 2>&1
    ufw reload > /dev/null 2>&1

    echo -e "${COLOR_YELLOW}${LANG[STARTING_NODE]}${COLOR_RESET}"
    sleep 3
    cd /opt/remnawave
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    randomhtml

    printf "${COLOR_YELLOW}${LANG[NODE_CHECK]}${COLOR_RESET}\n" "$SELFSTEAL_DOMAIN"
    local max_attempts=5
    local attempt=1
    local delay=15

    while [ $attempt -le $max_attempts ]; do
        printf "${COLOR_YELLOW}${LANG[NODE_ATTEMPT]}${COLOR_RESET}\n" "$attempt" "$max_attempts"
        if curl -s --fail --max-time 10 "https://$SELFSTEAL_DOMAIN" | grep -q "html"; then
            echo -e "${COLOR_GREEN}${LANG[NODE_LAUNCHED]}${COLOR_RESET}"
            break
        else
            printf "${COLOR_RED}${LANG[NODE_UNAVAILABLE]}${COLOR_RESET}\n" "$attempt"
            if [ $attempt -eq $max_attempts ]; then
                printf "${COLOR_RED}${LANG[NODE_NOT_CONNECTED]}${COLOR_RESET}\n" "$max_attempts"
                echo -e "${COLOR_YELLOW}${LANG[CHECK_CONFIG]}${COLOR_RESET}"
                exit 1
            fi
            sleep $delay
        fi
        ((attempt++))
    done

}
#Install Node

#Add Node to Panel
add_node_to_panel() {
    local domain_url="127.0.0.1:3000"

    echo -e ""
    echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[WARNING_NODE_PANEL]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[CONFIRM_SERVER_PANEL]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}[?]${COLOR_RESET} ${COLOR_YELLOW}${LANG[CONFIRM_PROMPT]}${COLOR_RESET}"
    read confirm
    echo

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        exit 0
    fi

    echo -e "${COLOR_YELLOW}${LANG[ADD_NODE_TO_PANEL]}${COLOR_RESET}"
    sleep 1

    get_panel_token
    token=$(cat "$TOKEN_FILE")
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}${COLOR_RESET}"
        return 1
    fi

    while true; do
        reading "${LANG[ENTER_NODE_DOMAIN]}" SELFSTEAL_DOMAIN
        check_node_domain "$domain_url" "$token" "$SELFSTEAL_DOMAIN"
        if [ $? -eq 0 ]; then
            break
        fi
        echo -e "${COLOR_YELLOW}${LANG[TRY_ANOTHER_DOMAIN]}${COLOR_RESET}"
    done
    
    while true; do
        reading "${LANG[ENTER_NODE_NAME]}" entity_name
        if [[ "$entity_name" =~ ^[a-zA-Z0-9-]+$ ]]; then
            if [ ${#entity_name} -ge 3 ] && [ ${#entity_name} -le 20 ]; then
                local response=$(make_api_request "GET" "http://$domain_url/api/config-profiles" "$token")
                
                if echo "$response" | jq -e ".response.configProfiles[] | select(.name == \"$entity_name\")" > /dev/null; then
                    echo -e "${COLOR_RED}$(printf "${LANG[CF_INVALID_NAME]}" "$entity_name")${COLOR_RESET}"
                else
                    break
                fi
            else
                echo -e "${COLOR_RED}${LANG[CF_INVALID_LENGTH]}${COLOR_RESET}"
            fi
        else
            echo -e "${COLOR_RED}${LANG[CF_INVALID_CHARS]}${COLOR_RESET}"
        fi
    done

    echo -e "${COLOR_YELLOW}${LANG[GENERATE_KEYS]}${COLOR_RESET}"
    local private_key=$(generate_xray_keys "$domain_url" "$token")
    printf "${COLOR_GREEN}${LANG[GENERATE_KEYS_SUCCESS]}${COLOR_RESET}\n"

    echo -e "${COLOR_YELLOW}${LANG[CREATING_CONFIG_PROFILE]}${COLOR_RESET}"
    read config_profile_uuid inbound_uuid <<< $(create_config_profile "$domain_url" "$token" "$entity_name" "$SELFSTEAL_DOMAIN" "$private_key" "$entity_name")
    echo -e "${COLOR_GREEN}${LANG[CONFIG_PROFILE_CREATED]}: $entity_name${COLOR_RESET}"

    printf "${COLOR_YELLOW}${LANG[CREATE_NEW_NODE]}$SELFSTEAL_DOMAIN${COLOR_RESET}\n"
    create_node "$domain_url" "$token" "$config_profile_uuid" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$entity_name"

    echo -e "${COLOR_YELLOW}${LANG[CREATE_HOST]}${COLOR_RESET}"
    create_host "$domain_url" "$token" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$config_profile_uuid" "$entity_name"

    echo -e "${COLOR_YELLOW}${LANG[GET_DEFAULT_SQUAD]}${COLOR_RESET}"
    local squad_uuids=$(get_default_squad "$domain_url" "$token")
    if [ $? -ne 0 ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_GET_SQUAD_LIST]}${COLOR_RESET}"
    elif [ -z "$squad_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_SQUADS_TO_UPDATE]}${COLOR_RESET}"
    else
        for squad_uuid in $squad_uuids; do
            echo -e "${COLOR_YELLOW}${LANG[UPDATING_SQUAD]} $squad_uuid${COLOR_RESET}"
            update_squad "$domain_url" "$token" "$squad_uuid" "$inbound_uuid"
            if [ $? -eq 0 ]; then
                echo -e "${COLOR_GREEN}${LANG[UPDATE_SQUAD]} $squad_uuid${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_SQUAD]} $squad_uuid${COLOR_RESET}"
            fi
        done
    fi

    echo -e "${COLOR_GREEN}${LANG[NODE_ADDED_SUCCESS]}${COLOR_RESET}"
    echo -e "${COLOR_RED}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_RED}${LANG[POST_PANEL_INSTRUCTION]}${COLOR_RESET}"
    echo -e "${COLOR_RED}-------------------------------------------------${COLOR_RESET}"
}
#Add Node to Panel

log_entry

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
        show_panel_node_menu
        ;;
    4)
        if [ ! -d "/opt/remnawave" ]; then
            echo -e "${COLOR_YELLOW}${LANG[NO_PANEL_NODE_INSTALLED]}${COLOR_RESET}"
            exit 1
        else
            show_template_source_options
            reading "${LANG[CHOOSE_TEMPLATE_OPTION]}" TEMPLATE_OPTION
            case $TEMPLATE_OPTION in
                1)
                    randomhtml "simple"
                    sleep 2
                    log_clear
                    remnawave_reverse
                    ;;
                2)
                    randomhtml "sni"
                    sleep 2
                    log_clear
                    remnawave_reverse
                    ;;
                3)
                    randomhtml "nothing"
                    sleep 2
                    log_clear
                    remnawave_reverse
                    ;;
                0)
                    echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                    remnawave_reverse
                    ;;
                *)
                    echo -e "${COLOR_YELLOW}${LANG[INVALID_TEMPLATE_CHOICE]}${COLOR_RESET}"
                    exit 1
                    ;;
            esac
        fi
        ;;
    5)
        manage_custom_legiz
        sleep 2
        log_clear
        remnawave_reverse
        ;;
    6)
        manage_extensions
        sleep 2
        log_clear
        remnawave_reverse
        ;;
    7)
        manage_ipv6
        sleep 2
        log_clear
        remnawave_reverse
        ;;
    8)
        manage_certificates
        sleep 2
        log_clear
        remnawave_reverse
        ;;
    9)
        update_remnawave_reverse
        sleep 2
        log_clear
        remnawave_reverse
        ;;
    10)
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
