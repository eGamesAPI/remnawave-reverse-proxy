#!/bin/bash

SCRIPT_VERSION="2.0.9"
UPDATE_AVAILABLE=false
DIR_REMNAWAVE="/usr/local/remnawave_reverse/"
LANG_FILE="${DIR_REMNAWAVE}selected_language"
SCRIPT_URL="https://raw.githubusercontent.com/eGamesAPI/remnawave-reverse-proxy/refs/heads/main/install_remnawave.sh"

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
declare -A LANG=(
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
    case $1 in
        en)
            LANG=(
                #Alias
                [ALIAS_ADDED]="Alias 'rr' for 'remnawave_reverse' added to %s"
                [ALIAS_ACTIVATE_GLOBAL]="Alias 'rr' is now available for all users. Run 'source %s' or open a new terminal to apply."
                #Lang
                [CHOOSE_LANG]="Select language:"
                [LANG_EN]="English"
                [LANG_RU]="Русский"
                #check
                [ERROR_ROOT]="Script must be run as root"
                [ERROR_OS]="Supported only Debian 11/12 and Ubuntu 22.04/24.04"
                #Install Packages
                [ERROR_UPDATE_LIST]="Failed to update package list"
                [ERROR_INSTALL_PACKAGES]="Failed to install required packages"
                [ERROR_INSTALL_CRON]="Failed to install cron"
                [ERROR_START_CRON]="Failed to start cron"
                [ERROR_CONFIGURE_LOCALES]="Error: Failed to configure locales"
                [ERROR_DOWNLOAD_DOCKER_KEY]="Failed to download Docker GPG key"
                [ERROR_UPDATE_DOCKER_LIST]="Failed to update package list after adding Docker repository"
                [ERROR_INSTALL_DOCKER]="Failed to install Docker"
                [ERROR_DOCKER_NOT_INSTALLED]="Docker is not installed"
                [ERROR_START_DOCKER]="Failed to start Docker"
                [ERROR_ENABLE_DOCKER]="Failed to enable Docker auto-start"
                [ERROR_DOCKER_NOT_WORKING]="Docker is not working properly"
                [ERROR_CONFIGURE_UFW]="Failed to configure UFW"
                [ERROR_CONFIGURE_UPGRADES]="Failed to configure unattended-upgrades"
                [ERROR_DOCKER_DNS]="Error: Unable to resolve download.docker.com. Check your DNS settings."
                [ERROR_INSTALL_CERTBOT]="Error: Failed to install certbot"
                [SUCCESS_INSTALL]="All packages installed successfully"
                #Menu
                [MENU_TITLE]="REMNAWAVE REVERSE-PROXY by eGames"
				[AVAILABLE_UPDATE]="update available"
                [VERSION_LABEL]="Version: %s"
                [EXIT]="Exit"
                [MENU_1]="Install Remnawave Components"
                [MENU_2]="Reinstall panel/node"
                [MENU_3]="Manage Panel/Node"
                [MENU_4]="Install random template for selfsteal node"
                [MENU_5]="Custom Templates by legiz"
                [MENU_6]="Manage IPv6"
                [MENU_7]="Manage certificates domain"
                [MENU_8]="Check for updates script"
                [MENU_9]="Remove script"
                [PROMPT_ACTION]="Select action (0-10):"
                [INVALID_CHOICE]="Invalid choice. Please select 0-10"
                [WARNING_LABEL]="WARNING:"
                [CONFIRM_PROMPT]="Enter 'y' to continue or 'n' to exit (y/n):"
                [WARNING_NODE_PANEL]="Adding a node should only be done on the server where the panel is installed, not on the node server."
                [CONFIRM_SERVER_PANEL]="Are you sure you are on the server with the installed panel?"
                #Remove Script
                [REMOVE_SCRIPT_ONLY]="Remove script and its local files"
                [REMOVE_SCRIPT_AND_PANEL]="Remove script and remnawave panel/node data"
                [CONFIRM_REMOVE_SCRIPT]="All script data will be removed from the server. Are you sure? (y/n): "
                [CONFIRM_REMOVE_ALL]="All script and panel/node data will be removed from the server. Are you sure? (y/n): "
                [SCRIPT_REMOVED]="Script and its local files successfully removed!"
                [ALL_REMOVED]="Script and panel/node data successfully removed!"
                #Warp by distillium
                [WARP_MENU]="WARP Native by distillium"
                [WARP_MENU_TITLE]="Manage WARP Native by distillium\nOnly run on server with node"
                [WARP_INSTALL]="Install WARP Native"
                [WARP_ADD_CONFIG]="Add WARP-configuration to node configuration"
                [WARP_DELETE_WARP_SETTINGS]="Remove WARP-configuration from node configuration"
                [WARP_CONFIRM_SERVER_PANEL]="Are you sure you are on the server with the installed panel?\nAdding WARP-configuration should only be done on the server where the panel is installed, not on the node server"
                [WARP_UNINSTALL]="Uninstall WARP Native"
                [WARP_PROMPT]="Select action (0-4):"
                [WARP_PROMPT1]="Select action:"
                [WARP_INVALID_CHOICE]="Invalid choice. Please select 0-4."
                [WARP_INVALID_CHOICE2]="Invalid choice."
                [WARP_NO_NODE]="Node Remnawave not found. First install the node."
                [WARP_SELECT_CONFIG]="Select node to add WARP-configuration?"
                [WARP_SELECT_CONFIG_DELETE]="Select node to remove WARP-configuration?"
                [WARP_NO_CONFIGS]="No configurations found."
                [WARP_UPDATE_SUCCESS]="Configuration successfully updated!"
                [WARP_UPDATE_FAIL]="Failed to update configuration."
                [WARP_WARNING]="warp-out already exists in outbounds."
                [WARP_WARNING2]="warp rule already exists in routing rules."
                [WARP_REMOVED_WARP_SETTINGS1]="Removed warp-out from outbounds"
                [WARP_NO_WARP_SETTINGS1]="warp-out not found in outbounds"
                [WARP_REMOVED_WARP_SETTINGS2]="Removed warp rule from routing rules"
                [WARP_NO_WARP_SETTINGS2]="warp rule not found in routing rules"
                #Manage Panel/Node
                [START_PANEL_NODE]="Start panel/node"
                [STOP_PANEL_NODE]="Stop panel/node"
                [UPDATE_PANEL_NODE]="Update panel/node"
                [VIEW_LOGS]="View logs"
                [PRESS_ENTER_RETURN_MENU]="Press Enter to return to the menu..."
                [REMNAWAVE_CLI]="Remnawave CLI"
                [ACCESS_PANEL]="Access panel via port 8443 (Only for panel + node)"
                [MANAGE_PANEL_NODE_PROMPT]="Select action (0-6):"
                [MANAGE_PANEL_NODE_INVALID_CHOICE]="Invalid choice. Please select 0-6."
                #Manage Certificates
                [CERT_UPDATE]="Update current certificates"
                [CERT_GENERATE]="Generate new certificates for another domain"
                [CERT_PROMPT1]="Select action (0-2):"
                [CERT_INVALID_CHOICE]="Invalid choice. Please select 0-2."
                [CERT_UPDATE_CHECK]="Checking certificate generation method..."
                [CERT_UPDATE_SUCCESS]="Certificates successfully updated."
                [CERT_UPDATE_FAIL]="Failed to update certificates."
                [CERT_GENERATE_PROMPT]="Enter the domain for new certificates (e.g., example.com):"
                [CERT_METHOD_UNKNOWN]="Unknown certificate generation method."
                [CERT_NOT_DUE]="Certificate for %s is not yet due for renewal."
                #Install Remnawave Components
                [INSTALL_MENU_TITLE]="Install Remnawave Components"
                [INSTALL_PANEL_NODE]="Install panel and node on one server"
                [INSTALL_PANEL]="Install only the panel"
                [INSTALL_ADD_NODE]="Add node to panel"
                [INSTALL_NODE]="Install only the node"
                [INSTALL_PROMPT]="Select action (0-3):"
                [INSTALL_INVALID_CHOICE]="Invalid choice. Please select 0-3."
                #Manage IPv6
                [IPV6_MENU_TITLE]="Manage IPv6"
                [IPV6_ENABLE]="Enable IPv6"
                [IPV6_DISABLE]="Disable IPv6"
                [IPV6_PROMPT]="Select action (0-2):"
                [IPV6_INVALID_CHOICE]="Invalid choice. Please select 0-2."
                [IPV6_ALREADY_ENABLED]="IPv6 already enabled"
                [IPV6_ALREADY_DISABLED]="IPv6 already disabled"
                [ENABLE_IPV6]="Enabling IPv6..."
                [IPV6_ENABLED]="IPv6 has been enabled."
                [DISABLING_IPV6]="Disabling IPv6..."
                [IPV6_DISABLED]="IPv6 has been disabled."
                #Remna
                [INSTALL_PACKAGES]="Installing required packages..."
                [INSTALLING]="Installing panel and node"
                [INSTALLING_PANEL]="Installing panel"
                [INSTALLING_NODE]="Installing node"
                [ENTER_PANEL_DOMAIN]="Enter panel domain (e.g. panel.example.com):"
                [ENTER_SUB_DOMAIN]="Enter subscription domain (e.g. sub.example.com):"
                [ENTER_NODE_DOMAIN]="Enter selfsteal domain for node (e.g. node.example.com):"
                [ENTER_CF_TOKEN]="Enter your Cloudflare API token or global API key:"
                [ENTER_CF_EMAIL]="Enter your Cloudflare registered email:"
                [CHECK_CERTS]="Checking certificates..."
                [CERT_FOUND]="Certificates found in /etc/letsencrypt/live/"
                [CF_VALIDATING]="Cloudflare API key and email are valid"
                [CF_INVALID]="Invalid Cloudflare API token or email after %d attempts."
                [CF_INVALID_ATTEMPT]="Invalid Cloudflare API key or email. Attempt %d of %d."
                [WAITING]="Please wait..."
                #API
                [REGISTERING_REMNAWAVE]="Registration in Remnawave"
                [CHECK_CONTAINERS]="Checking containers availability..."
                [CONTAINERS_NOT_READY]="Containers are not ready, waiting..."
                [REGISTRATION_SUCCESS]="Registration completed successfully!"
                [GET_PUBLIC_KEY]="Getting public key..."
                [PUBLIC_KEY_SUCCESS]="Public key successfully obtained"
                [GENERATE_KEYS]="Generating x25519 keys..."
                [GENERATE_KEYS_SUCCESS]="Keys successfully generated"
                [ERROR_NO_CONFIGS]="No config profiles found"
                [NO_DEFAULT_PROFILE]="Default-Profile not found"
                [ERROR_DELETE_PROFILE]="Failed to delete profile"
                [CREATING_CONFIG_PROFILE]="Creating config profile..."
                [CONFIG_PROFILE_CREATED]="Config profile successfully created"
                [CREATING_NODE]="Creating node"
                [NODE_CREATED]="Node successfully created"
                [CREATE_HOST]="Creating host"
                [HOST_CREATED]="Host successfully created"
                [GET_DEFAULT_SQUAD]="Getting default squad"
                [UPDATE_SQUAD]="Squad successfully updated"
                [NO_SQUADS_FOUND]="No squads found"
                [INVALID_UUID_FORMAT]="Invalid UUID format"
                [NO_VALID_SQUADS_FOUND]="No valid squads found"
                [ERROR_GET_SQUAD]="Failed to get squad"
                [INVALID_SQUAD_UUID]="Invalid squad UUID"
                [INVALID_INBOUND_UUID]="Invalid inbound UUID"
                #Stop/Start/Update
                [CHANGE_DIR_FAILED]="Failed to change to directory %s"
                [DIR_NOT_FOUND]="Directory /opt/remnawave not found"
                [PANEL_RUNNING]="Panel/node already running"
                [PANEL_RUN]="Panel/node running"
                [PANEL_STOP]="Panel/node stopped"
                [PANEL_STOPPED]="Panel/node already stopped"
                [NO_UPDATE]="No updates available for panel/node"
                [UPDATING]="Updating panel/node..."
                [UPDATE_SUCCESS1]="Panel/node successfully updated"
                [STARTING_PANEL_NODE]="Starting panel and node"
                [STARTING_PANEL]="Starting panel"
                [STARTING_NODE]="Starting node"
                [STOPPING_REMNAWAVE]="Stopping panel and node"
                [IMAGES_DETECTED]="Images detected, restarting containers..."
                #Menu End
                [INSTALL_COMPLETE]="               INSTALLATION COMPLETE!"
                [PANEL_ACCESS]="Panel URL:"
                [ADMIN_CREDS]="To log into the panel, use the following data:"
                [USERNAME]="Username:"
                [PASSWORD]="Password:"
                [RELAUNCH_CMD]="To relaunch the manager, use the following command:"
                #RandomHTML
                [RANDOM_TEMPLATE]="Installing random template for camouflage site"
                [DOWNLOAD_FAIL]="Download failed, retrying..."
                [UNPACK_ERROR]="Error unpacking archive"
                [TEMPLATE_COPY]="Template copied to /var/www/html/"
                [SELECT_TEMPLATE]="Selected template:"
                #Error
                [ERROR_TOKEN]="Failed to get token."
                [ERROR_PUBLIC_KEY]="Failed to get public key."
                [ERROR_EXTRACT_PUBLIC_KEY]="Failed to extract public key from response."
                [ERROR_GENERATE_KEYS]="Failed to generate keys."
                [ERROR_EMPTY_RESPONSE_NODE]="Empty response from server when creating node."
                [ERROR_CREATE_NODE]="Failed to create node."
                [ERROR_EMPTY_RESPONSE_HOST]="Empty response from server when creating host."
                [ERROR_CREATE_HOST]="Failed to create host."
                [ERROR_EMPTY_RESPONSE_REGISTER]="Registration error - empty server response"
                [ERROR_REGISTER]="Registration error"
                [ERROR_UPDATE_SQUAD]="Failed to update squad"
                [ERROR_GET_SQUAD_LIST]="Failed to get squad list"
                [NO_SQUADS_TO_UPDATE]="No squads to update"
                #Reinstall Panel/Node
                [REINSTALL_WARNING]="All data panel/node will be deleted from the server. Are you sure? (y/n):"
                [REINSTALL_TYPE_TITLE]="Select reinstallation method:"
                [REINSTALL_PROMPT]="Select action (0-3):"
                [INVALID_REINSTALL_CHOICE]="Invalid choice. Please select 0-3."
                [POST_PANEL_MESSAGE]="Panel successfully installed!"
                [POST_PANEL_INSTRUCTION]="To install the node, follow these steps:\n1. Run this script on the server where the node will be installed.\n2. Select 'Install Remnawave Components', then 'Install only the node'."
                [SELFSTEAL_PROMPT]="Enter the selfsteal domain for the node (e.g. node.example.com):"
                [SELFSTEAL]="Enter the selfsteal domain for the node specified during panel installation:"
                [PANEL_IP_PROMPT]="Enter the IP address of the panel to establish a connection between the panel and the node:"
                [IP_ERROR]="Enter a valid IP address in the format X.X.X.X (e.g., 192.168.1.1)"
                [CERT_PROMPT]="Enter the certificate obtained from the panel, keeping the SSL_CERT= line (paste the content and press Enter twice):"
                [CERT_CONFIRM]="Are you sure the certificate is correct? (y/n):"
                [ABORT_MESSAGE]="Installation aborted by user"
                [SUCCESS_MESSAGE]="Node successfully connected"
                #Node Check
                [NODE_CHECK]="Checking node connection for %s..."
                [NODE_ATTEMPT]="Attempt %d of %d..."
                [NODE_UNAVAILABLE]="Node is unavailable on attempt %d."
                [NODE_LAUNCHED]="Node successfully launched!"
                [NODE_NOT_CONNECTED]="Node not connected after %d attempts!"
                [CHECK_CONFIG]="Check the configuration or restart the panel."
                #Add node to panel
                [ADD_NODE_TO_PANEL]="Adding node to panel"
                [ENTER_NODE_NAME]="Enter node name (e.g., Germany):"
                [USING_SAVED_TOKEN]="Using saved token..."
                [INVALID_SAVED_TOKEN]="Saved token is invalid. Requesting a new one..."
                [ENTER_PANEL_USERNAME]="Enter panel username: "
                [ENTER_PANEL_PASSWORD]="Enter panel password: "
                [TOKEN_RECEIVED_AND_SAVED]="Token successfully received and saved"
                [TOKEN_USED_SUCCESSFULLY]="Token successfully used"
                [NODE_ADDED_SUCCESS]="Node successfully added!"
                [CREATE_NEW_NODE]="Creating new node for %s..."
                [CF_INVALID_NAME]="Error: The name of the configuration profile %s is already in use.\nPlease choose another name."
                [CF_INVALID_LENGTH]="Error: The name of the configuration profile should contain from 5 to 20 characters."
                [CF_INVALID_CHARS]="Error: The name of the configuration profile should contain only English letters, numbers, and hyphens."
                #check
                [CHECK_UPDATE]="Check for updates"
                [GENERATING_CERTS]="Generating certificates for %s"
                [REQUIRED_DOMAINS]="Required domains for certificates:"
                [CHECK_DOMAIN_IP_FAIL]="Failed to determine the domain or server IP address."
                [CHECK_DOMAIN_IP_FAIL_INSTRUCTION]="Ensure that the domain %s is correctly configured and points to this server (%s)."
                [CHECK_DOMAIN_CLOUDFLARE]="The domain %s points to a Cloudflare IP (%s)."
                [CHECK_DOMAIN_CLOUDFLARE_INSTRUCTION]="Cloudflare proxying is not allowed for the selfsteal domain. Disable proxying (switch to 'DNS Only')."
                [CHECK_DOMAIN_MISMATCH]="The domain %s points to IP address %s, which differs from this server's IP (%s)."
                [CHECK_DOMAIN_MISMATCH_INSTRUCTION]="For proper operation, the domain must point to the current server."
                [NO_PANEL_NODE_INSTALLED]="Panel or node is not installed. Please install panel or node first."
                #update
                [UPDATE_AVAILABLE]="A new version of the script is available: %s (current version: %s)."
                [UPDATE_CONFIRM]="Update the script? (y/n):"
                [UPDATE_CANCELLED]="Update cancelled by user."
                [UPDATE_SUCCESS]="Script successfully updated to version %s!"
                [UPDATE_FAILED]="Error downloading the new version of the script."
                [VERSION_CHECK_FAILED]="Could not determine the version of the remote script. Skipping update."
                [LATEST_VERSION]="You already have the latest version of the script (%s)."
                [RESTART_REQUIRED]="Please restart the script to apply changes."
                [LOCAL_FILE_NOT_FOUND]="Local script file not found, downloading new version..."
                #CLI
                [RUNNING_CLI]="Running Remnawave CLI..."
                [CLI_SUCCESS]="Remnawave CLI executed successfully!"
                [CLI_FAILED]="Failed to execute Remnawave CLI. Ensure the 'remnawave' container is running."
                [CONTAINER_NOT_RUNNING]="Container 'remnawave' is not running. Please start it first."
                #Cert_choise
                [CERT_METHOD_PROMPT]="Select certificate generation method for all domains:"
                [CERT_METHOD_CF]="Cloudflare API (supports wildcard)"
                [CERT_METHOD_ACME]="ACME HTTP-01 (single domain, no wildcard)"
                [CERT_METHOD_CHOOSE]="Select option (0-2):"
                [EMAIL_PROMPT]="Enter your email for Let's Encrypt registration:"
                [CERTS_SKIPPED]="All certificates already exist. Skipping generation."
                [ACME_METHOD]="Using ACME (Let's Encrypt) with HTTP-01 challenge (no wildcard support)..."
                [CERT_GENERATION_FAILED]="Certificate generation failed. Please check your input and DNS settings."
                [ADDING_CRON_FOR_EXISTING_CERTS]="Adding cron job for certificate renewal..."
                [CRON_ALREADY_EXISTS]="Cron job for certificate renewal already exists."
                [CERT_NOT_FOUND]="Certificate not found for domain."
                [ERROR_PARSING_CERT]="Error parsing certificate expiry date."
                [CERT_EXPIRY_SOON]="Certificates will expire soon in"
                [DAYS]="days"
                [UPDATING_CRON]="Updating cron job to match certificate expiry."
                [GENERATING_WILDCARD_CERT]="Generating wildcard certificate for"
                [WILDCARD_CERT_FOUND]="Wildcard certificate found in /etc/letsencrypt/live/"
                [FOR_DOMAIN]="for"
                [START_CRON_ERROR]="Not able to start cron. Please start it manually."
                [DOMAINS_MUST_BE_UNIQUE]="Error: All domains (panel, subscription, and node) must be unique."
                [CHOOSE_TEMPLATE_SOURCE]="Select template source:"
                [SIMPLE_WEB_TEMPLATES]="Simple web templates"
                [SNI_TEMPLATES]="Sni templates"
                [CHOOSE_TEMPLATE_OPTION]="Select option (0-2):"
                [INVALID_TEMPLATE_CHOICE]="Invalid choice. Please select 0-2."
                # Manage Panel Access
                [PORT_8443_OPEN]="Open port 8443 for panel access"
                [PORT_8443_CLOSE]="Close port 8443 for panel access"
                [PORT_8443_IN_USE]="Port 8443 already in use by another process. Check which services are using the port and free it."
                [NO_PORT_CHECK_TOOLS]="Port checking tools (ss or netstat) not found. Install one of them."
                [OPEN_PANEL_LINK]="Your panel access link:"
                [PORT_8443_WARNING]="Don't forget, port 8443 is now open to the world. After fixing the panel, select the option to close port 8443."
                [PORT_8443_CLOSED]="Port 8443 has been closed."
                [NGINX_CONF_NOT_FOUND]="File nginx.conf not found in $dir"
                [NGINX_CONF_ERROR]="Failed to extract necessary parameters from nginx.conf"
                [NGINX_CONF_MODIFY_FAILED]="Failed to modify nginx.conf"
                [PORT_8443_ALREADY_CONFIGURED]="Port 8443 already configured in nginx.conf"
                [UFW_RELOAD_FAILED]="Failed to reload UFW."
                [PORT_8443_ALREADY_CLOSED]="Port 8443 already closed in UFW."
                # Sub Page Upload
                [UPLOADING_SUB_PAGE]="Uploading custom sub page template..."
                [ERROR_FETCH_SUB_PAGE]="Failed to fetch custom sub page template."
                [SUB_PAGE_UPDATED_SUCCESS]="Custom sub page template successfully updated."
                [SELECT_SUB_PAGE_CUSTOM]="Select action (0-7):"
                [SELECT_SUB_PAGE_CUSTOM1]="Custom Sub Page Templates"
                [SELECT_SUB_PAGE_CUSTOM2]="Custom Sub Page Templates\nOnly run on panel server"
                [SELECT_SUB_PAGE_CUSTOM3]="Custom App Lists for original sub page:"
                [SELECT_SUB_PAGE_CUSTOM4]="Custom Sub Page:"
                [SUB_PAGE_SELECT_CHOICE]="Invalid choice. Please select 0-7."
                [RESTORE_SUB_PAGE]="Restore default sub page"
                [CONTAINER_NOT_FOUND]="Container %s not found"
                [SUB_WITH_APPCONFIG_ASK]="Do you want to include app-config.json?"
                [SUB_WITH_APPCONFIG_OPTION1]="Yes, use config from option 1 (Simple custom app list)"
                [SUB_WITH_APPCONFIG_OPTION2]="Yes, use config from option 2 (Multiapp custom app list)"
                [SUB_WITH_APPCONFIG_OPTION3]="Yes, use config from option 3 (HWID only app list)"
                [SUB_WITH_APPCONFIG_SKIP]="No, skip app-config.json"
                [SUB_WITH_APPCONFIG_INVALID]="Invalid option, skipping app-config.json"
                [SUB_WITH_APPCONFIG_INPUT]="Select action (0-3):"
                # Custom Branding
                [BRANDING_SUPPORT_ASK]="Add branding support to subscription page?"
                [BRANDING_SUPPORT_YES]="Yes, add branding support"
                [BRANDING_SUPPORT_NO]="No, skip branding"
                [BRANDING_NAME_PROMPT]="Enter your brand name:"
                [BRANDING_SUPPORT_URL_PROMPT]="Enter your support page URL:"
                [BRANDING_LOGO_URL_PROMPT]="Enter your brand logo URL:"
                [BRANDING_ADDED_SUCCESS]="Branding configuration successfully added"
                # Template Upload
                [TEMPLATE_NOT_APPLIED]="Custom rules template not applied"
                [UPLOADING_TEMPLATE]="Uploading custom rules template..."
                [ERROR_FETCH_TEMPLATE]="Failed to fetch custom rules template."
                [ERROR_EMPTY_RESPONSE_TEMPLATE]="Empty response from API when updating template."
                [ERROR_UPDATE_TEMPLATE]="Failed to update custom rules template"
                [TEMPLATE_UPDATED_SUCCESS]="Custom rules template successfully updated."
                [SELECT_TEMPLATE_CUSTOM]="Select action (0-8):"
                [SELECT_TEMPLATE_CUSTOM1]="Custom Rules Templates"
                [SELECT_TEMPLATE_CUSTOM2]="Custom Rules Templates\nOnly run on panel server"
                [TEMPLATE_SELECT_CHOICE]="Invalid choice. Please select 0-8."
                [DOWNLOADING_CONFIG_SEED]="Downloading config.seed.ts from GitHub..."
                [EXTRACT_FAILED]="Failed to extract configuration for %s"
                [RESTORING_DEFAULT_TEMPLATES]="Restoring default custom rules templates from GitHub..."
                [DEFAULT_TEMPLATES_COMPLETED]="Default custom rules templates restoration completed"
                [RESTORING_TEMPLATE]="Restoring default custom rules template for %s..."
                [TEMPLATE_RESTORED_SUCCESS]="Default custom rules template for %s restored successfully"
                [URL_NOT_ACCESSIBLE]="URL %s is not accessible (HTTP status: %s)"
                [FAILED_TO_DOWNLOAD_TEMPLATE]="Failed to download custom rules template %s"
                [TEMPLATE_EMPTY]="Downloaded custom rules template %s is empty"
                [INVALID_YAML_TEMPLATE]="Invalid YAML custom rules template for %s"
                [INVALID_JSON_TEMPLATE]="Invalid JSON custom rules template for %s"
                [EMPTY_TEMPLATE_VALUE]="Empty custom rules template value for %s"
                [RESTORE_TEMPLATES]="Restore default custom rules templates"
                [FAILED_TO_EXTRACT_UUID]="Failed to extract UUID from subscription template"
                [RENEWAL_CONF_NOT_FOUND]="Renewal configuration file not found."
                [ARCHIVE_DIR_MISMATCH]="Archive directory mismatch in configuration."
                [CERT_VERSION_NOT_FOUND]="Failed to determine certificate version."
                [RESULTS_CERTIFICATE_UPDATES]="Results of certificate updates:"
                [CERTIFICATE_FOR]="Certificate for "
                [SUCCESSFULLY_UPDATED]="successfully updated"
                [FAILED_TO_UPDATE_CERTIFICATE_FOR]="Failed to update certificate for "
                [ERROR_CHECKING_EXPIRY_FOR]="Error checking expiry date for "
                [DOES_NOT_REQUIRE_UPDATE]="does not require updating ("
                [UPDATED]="Updated"
                [REMAINING]="Remaining"
                [ERROR_UPDATE]="Error updating"
                [ALREADY_EXPIRED]="already expired"
                [CERT_CLOUDFLARE_FILE_NOT_FOUND]="Cloudflare credentials file not found."
                [TELEGRAM_OAUTH_WARNING]="Telegram OAuth is enabled (TELEGRAM_OAUTH_ENABLED=true)."
                [CREATE_API_TOKEN_INSTRUCTION]="Go to the panel at: https://%s\nNavigate to 'API Tokens' -> 'Create New Token' and create a token.\nCopy the created token and enter it below."
                [ENTER_API_TOKEN]="Enter the API token: "
                [EMPTY_TOKEN_ERROR]="No token provided. Exiting."
                [RATE_LIMIT_EXCEEDED]="Rate limit exceeded for Let's Encrypt"
                [FAILED_TO_MODIFY_HTML_FILES]="Failed to modify HTML files"
                [INSTALLING_YQ]="Installing yq..."
                [ERROR_SETTING_YQ_PERMISSIONS]="Error setting yq permissions!"
                [YQ_SUCCESSFULLY_INSTALLED]="yq successfully installed!"
                [YQ_DOESNT_WORK_AFTER_INSTALLATION]="Error: yq doesn't work after installation!"
                [ERROR_DOWNLOADING_YQ]="Error downloading yq!"
                [FAST_START]="Quick start: remnawave_reverse"
            )
            ;;
        ru)
            LANG=(
                #Alias
                [ALIAS_ADDED]="Алиас 'rr' для 'remnawave_reverse' добавлен в %s"
                [ALIAS_ACTIVATE_GLOBAL]="Алиас 'rr' теперь доступен для всех пользователей. Выполните 'source %s' или перезапустите терминал, чтобы применить алиас."
                #Check
                [ERROR_ROOT]="Скрипт нужно запускать с правами root"
                [ERROR_OS]="Поддержка только Debian 11/12 и Ubuntu 22.04/24.04"
                [MENU_TITLE]="REMNAWAVE REVERSE-PROXY by eGames"
				[AVAILABLE_UPDATE]="доступно обновление"
                [VERSION_LABEL]="Версия: %s"
                #Install Packages
                [ERROR_UPDATE_LIST]="Ошибка: Не удалось обновить список пакетов"
                [ERROR_INSTALL_PACKAGES]="Ошибка: Не удалось установить необходимые пакеты"
                [ERROR_INSTALL_CRON]="Ошибка: Не удалось установить cron"
                [ERROR_START_CRON]="Ошибка: Не удалось запустить cron"
                [ERROR_CONFIGURE_LOCALES]="Ошибка: Не удалось настроить локали"
                [ERROR_DOWNLOAD_DOCKER_KEY]="Ошибка: Не удалось загрузить ключ Docker"
                [ERROR_UPDATE_DOCKER_LIST]="Ошибка: Не удалось обновить список пакетов после добавления репозитория Docker"
                [ERROR_INSTALL_DOCKER]="Ошибка: Не удалось установить Docker"
                [ERROR_DOCKER_NOT_INSTALLED]="Ошибка: Docker не установлен"
                [ERROR_START_DOCKER]="Ошибка: Не удалось запустить Docker"
                [ERROR_ENABLE_AUTOSTART_DOCKER]="Ошибка: Не удалось включить автозапуск Docker"
                [ERROR_DOCKER_NOT_WORKING]="Ошибка: Docker не работает корректно"
                [ERROR_CONFIGURE_UFW]="Ошибка: Не удалось настроить UFW"
                [ERROR_CONFIGURE_UPGRADES]="Ошибка: Не удалось настроить unattended-upgrades"
                [ERROR_DOCKER_DNS]="Ошибка: Не удалось разрешить домен download.docker.com. Проверьте настройки DNS."
                [ERROR_INSTALL_CERTBOT]="Ошибка: Не удалось установить certbot"
                [SUCCESSFUL_INSTALL]="Все пакеты успешно установлены"
                #Main menu
                [EXIT]="Выход"
                [MENU_1]="Установка компонентов Remnawave"
                [MENU_2]="Переустановить панель/ноду"
                [MENU_3]="Управление панелью/нодой"
                [MENU_4]="Установить случайный шаблон для selfsteal ноды"
                [MENU_5]="Кастомные шаблоны от legiz"
                [MENU_6]="Управление IPv6"
                [MENU_7]="Управление сертификатами домена"
                [MENU_8]="Проверить обновления скрипта"
                [MENU_9]="Удалить скрипт"
                [PROMPT_ACTION]="Выберите действие (0-10):"
                [INVALID_CHOICE]="Неверный выбор. Выберите 0-10."
                [WARNING_LABEL]="ВНИМАНИЕ:"
                [CONFIRM_PROMPT]="Введите 'y' для продолжения или 'n' для выхода (y/n):"
                [WARNING_NODE_PANEL]="Добавление ноды должно выполняться только на сервере, где установлена панель, а не на сервере ноды."
                [CONFIRM_SERVER_PANEL]="Вы уверены, что находитесь на сервере с установленной панелью?"
                #Remove Script
                [REMOVE_SCRIPT_ONLY]="Удалить скрипт и его локальные файлы"
                [REMOVE_SCRIPT_AND_PANEL]="Удалить скрипт и данные панели/ноды remnawave"
                [CONFIRM_REMOVE_SCRIPT]="Все данные скрипта будут удалены с сервера. Вы уверены? (y/n): "
                [CONFIRM_REMOVE_ALL]="Все данные скрипта и панели/ноды будут удалены с сервера. Вы уверены? (y/n): "
                [SCRIPT_REMOVED]="Скрипт и его локальные файлы успешно удалены!"
                [ALL_REMOVED]="Скрипт и данные панели/ноды успешно удалены!"
                #Warp by distillium
                [WARP_MENU]="WARP Native от distillium"
                [WARP_MENU_TITLE]="Управление WARP Native от distillium"
                [WARP_INSTALL]="Установить WARP Native"
                [WARP_ADD_CONFIG]="Добавить WARP-настройки в конфигурацию ноды"
                [WARP_DELETE_WARP_SETTINGS]="Удалить WARP-настройки из конфигурации ноды"
                [WARP_CONFIRM_SERVER_PANEL]="Вы уверены, что находитесь на сервере с установленной панелью?\nДобавление WARP-настроек должно выполняться только на сервере, где установлена панель, а не на сервере ноды"
                [WARP_UNINSTALL]="Удалить WARP Native"
                [WARP_PROMPT]="Выберите действие (0-4):"
                [WARP_PROMPT1]="Выберите действие:"
                [WARP_INVALID_CHOICE]="Неверный выбор. Выберите 0-4."
                [WARP_INVALID_CHOICE2]="Неверный выбор."
                [WARP_NO_NODE]="Нода Remnawave не найдена. Сначала установите ноду."
                [WARP_SELECT_CONFIG]="На какую ноду добавить WARP-настройки?"
                [WARP_SELECT_CONFIG_DELETE]="На какой ноде удалить WARP-настройки?"
                [WARP_NO_CONFIGS]="Конфигурации не найдены."
                [WARP_UPDATE_SUCCESS]="Конфигурация успешно обновлена!"
                [WARP_UPDATE_FAIL]="Не удалось обновить конфигурацию."
                [WARP_WARNING]="warp-out уже существует в outbounds."
                [WARP_WARNING2]="warp rule уже существует в routing rules."
                [WARP_REMOVED_WARP_SETTINGS1]="Удален warp-out из outbounds"
                [WARP_NO_WARP_SETTINGS1]="warp-out не найден в outbounds"
                [WARP_REMOVED_WARP_SETTINGS2]="Удален warp rule из routing rules"
                [WARP_NO_WARP_SETTINGS2]="warp rule не найден в routing rules"
                #Manage Panel/Node
                [START_PANEL_NODE]="Запустить панель/ноду"
                [STOP_PANEL_NODE]="Остановить панель/ноду"
                [UPDATE_PANEL_NODE]="Обновить панель/ноду"
                [VIEW_LOGS]="Просмотр логов"
                [PRESS_ENTER_RETURN_MENU]="Нажмите Enter для возврата в меню..."
                [REMNAWAVE_CLI]="Remnawave CLI"
                [ACCESS_PANEL]="Доступ к панели через порт 8443 (только для панели + ноды)"
                [MANAGE_PANEL_NODE_PROMPT]="Выберите действие (0-6):"
                [MANAGE_PANEL_NODE_INVALID_CHOICE]="Неверный выбор. Выберите 0-6."
                #Manage Certificates
                [CERT_UPDATE]="Обновить текущие сертификаты"
                [CERT_GENERATE]="Сгенерировать новые сертификаты для другого домена"
                [CERT_PROMPT1]="Выберите действие (0-2):"
                [CERT_INVALID_CHOICE]="Неверный выбор. Выберите 0-2."
                [CERT_UPDATE_CHECK]="Проверка метода генерации сертификата..."
                [CERT_UPDATE_SUCCESS]="Сертификаты успешно обновлены."
                [CERT_UPDATE_FAIL]="Не удалось обновить сертификаты."
                [CERT_GENERATE_PROMPT]="Введите домен для новых сертификатов (например, example.com):"
                [CERT_METHOD_UNKNOWN]="Неизвестный метод генерации сертификата."
                [CERT_NOT_DUE]="Сертификат для %s еще не требует обновления."
                #Install Remnawave Components
                [INSTALL_MENU_TITLE]="Установка компонентов Remnawave"
                [INSTALL_PANEL_NODE]="Установить панель и ноду на один сервер"
                [INSTALL_PANEL]="Установить только панель"
                [INSTALL_ADD_NODE]="Добавить ноду в панель"
                [INSTALL_NODE]="Установить только ноду"
                [INSTALL_PROMPT]="Выберите действие (0-4):"
                [INSTALL_INVALID_CHOICE]="Неверный выбор. Выберите 0-4."
                #Manage IPv6
                [IPV6_MENU_TITLE]="Управление IPv6"
                [IPV6_ENABLE]="Включить IPv6"
                [IPV6_DISABLE]="Отключить IPv6"
                [IPV6_PROMPT]="Выберите действие (0-2):"
                [IPV6_INVALID_CHOICE]="Неверный выбор. Выберите 0-2."
                [IPV6_ALREADY_ENABLED]="IPv6 уже включен"
                [ENABLE_IPV6]="Включение IPv6..."
                [IPV6_ENABLED]="IPv6 включен."
                [IPV6_ALREADY_DISABLED]="IPv6 уже отключен"
                [DISABLING_IPV6]="Отключение IPv6..."
                [IPV6_DISABLED]="IPv6 отключен."
                #Remna
                [INSTALL_PACKAGES]="Установка необходимых пакетов..."
                [INSTALLING]="Установка панели и ноды"
                [INSTALLING_PANEL]="Установка панели"
                [INSTALLING_NODE]="Установка ноды"
                [ENTER_PANEL_DOMAIN]="Введите домен панели (например, panel.example.com):"
                [ENTER_SUB_DOMAIN]="Введите домен подписки (например, sub.example.com):"
                [ENTER_NODE_DOMAIN]="Введите selfsteal домен для ноды (например, node.example.com):"
                [ENTER_CF_TOKEN]="Введите Cloudflare API токен или глобальный ключ:"
                [ENTER_CF_EMAIL]="Введите зарегистрированную почту Cloudflare:"
                [CHECK_CERTS]="Проверка сертификатов..."
                [CERT_FOUND]="Сертификаты найдены в /etc/letsencrypt/live/"
                [CF_VALIDATING]="Cloudflare API ключ и email валидны"
                [CF_INVALID]="Неверный Cloudflare API ключ или email после %d попыток."
                [CF_INVALID_ATTEMPT]="Неверный Cloudflare API ключ или email. Попытка %d из %d."
                [WAITING]="Пожалуйста, подождите..."
                #API
                [REGISTERING_REMNAWAVE]="Процесс регистрации в Remnawave"
                [CHECK_CONTAINERS]="Проверка доступности контейнеров..."
                [CONTAINERS_NOT_READY]="Контейнеры не готовы, ожидание..."
                [REGISTRATION_SUCCESS]="Регистрация прошла успешно!"
                [GET_PUBLIC_KEY]="Получаем публичный ключ..."
                [PUBLIC_KEY_SUCCESS]="Публичный ключ успешно получен"
                [GENERATE_KEYS]="Генерация ключей x25519..."
                [GENERATE_KEYS_SUCCESS]="Ключи успешно сгенерированы"
                [CREATING_CONFIG_PROFILE]="Создаем конфигурационный профиль..."
                [CONFIG_PROFILE_CREATED]="Конфигурационный профиль успешно создан"
                [CREATING_NODE]="Создание ноды"
                [NODE_CREATED]="Нода успешно создана"
                [CREATE_HOST]="Создаем хост"
                [HOST_CREATED]="Хост успешно создан"
                [GET_DEFAULT_SQUAD]="Получение default squad"
                [UPDATE_SQUAD]="Squad успешно обновлен"
                [NO_SQUADS_FOUND]="Нет squadов"
                [INVALID_UUID_FORMAT]="Неверный формат UUID"
                [NO_VALID_SQUADS_FOUND]="Нет валидных squadов"
                [ERROR_GET_SQUAD]="Не удалось получить squad"
                [INVALID_SQUAD_UUID]="Неверный UUID squad"
                [INVALID_INBOUND_UUID]="Неверный UUID inbound"
                #Stop/Start/Update
                [CHANGE_DIR_FAILED]="Не удалось перейти в директорию %s"
                [DIR_NOT_FOUND]="Директория /opt/remnawave не найдена"
                [PANEL_RUNNING]="Панель/нода уже запущена"
                [PANEL_RUN]="Панель/нода запущена"
                [PANEL_STOP]="Панель/нода остановлена"
                [PANEL_STOPPED]="Панель/нода уже остановлена"
                [NO_UPDATE]="Нет доступных обновлений для панели/ноды"
                [UPDATING]="Обновление панели/ноды..."
                [UPDATE_SUCCESS1]="Панель/нода успешно обновлена"
                [STARTING_PANEL_NODE]="Запуск панели и ноды"
                [STARTING_PANEL]="Запуск панели"
                [STARTING_NODE]="Запуск ноды"
                [STOPPING_REMNAWAVE]="Остановка панели и ноды"
                [IMAGES_DETECTED]="Обнаружены новые образы, перезапускаем контейнеры..."
                #Menu End
                [INSTALL_COMPLETE]="               УСТАНОВКА ЗАВЕРШЕНА!"
                [PANEL_ACCESS]="Панель доступна по адресу:"
                [ADMIN_CREDS]="Для входа в панель используйте следующие данные:"
                [USERNAME]="Логин:"
                [PASSWORD]="Пароль:"
                [RELAUNCH_CMD]="Для повторного запуска менеджера используйте команду:"
                #RandomHTML
                [DOWNLOAD_FAIL]="Ошибка загрузки, повторная попытка..."
                [UNPACK_ERROR]="Ошибка распаковки архива"
                [RANDOM_TEMPLATE]="Установка случайного шаблона для маскировочного сайта"
                [TEMPLATE_COPY]="Шаблон скопирован в /var/www/html/"
                [SELECT_TEMPLATE]="Выбран шаблон:"
                #Error
                [ERROR_TOKEN]="Не удалось получить токен."
                [ERROR_PUBLIC_KEY]="Не удалось получить публичный ключ."
                [ERROR_EXTRACT_PUBLIC_KEY]="Не удалось извлечь публичный ключ из ответа."
                [ERROR_GENERATE_KEYS]="Не удалось сгенерировать ключи."
                [ERROR_NO_CONFIGS]="Не найдены профили конфигураций"
                [NO_DEFAULT_PROFILE]="Default-Profile не найден"
                [ERROR_DELETE_PROFILE]="Не удалось удалить профиль"
                [ERROR_EMPTY_RESPONSE_NODE]="Пустой ответ от сервера при создании ноды."
                [ERROR_CREATE_NODE]="Не удалось создать ноду."
                [ERROR_EMPTY_RESPONSE_HOST]="Пустой ответ от сервера при создании хоста."
                [ERROR_CREATE_HOST]="Не удалось создать хост."
                [ERROR_EMPTY_RESPONSE_REGISTER]="Ошибка при регистрации - пустой ответ сервера"
                [ERROR_REGISTER]="Ошибка регистрации"
                [ERROR_UPDATE_SQUAD]="Ошибка обновления squad"
                [ERROR_GET_SQUAD_LIST]="Ошибка получения списка squadов"
                [NO_SQUADS_TO_UPDATE]="Нет сквадов для обновления"
                #Reinstall Panel/Node
                [REINSTALL_WARNING]="Все данные панели/ноды будут удалены с сервера. Вы уверены? (y/n):"
                [REINSTALL_TYPE_TITLE]="Выберите способ переустановки:"
                [REINSTALL_PROMPT]="Выберите действие (0-3):"
                [INVALID_REINSTALL_CHOICE]="Неверный выбор. Выберите 0-3."
                [POST_PANEL_MESSAGE]="Панель успешно установлена!"
                [POST_PANEL_INSTRUCTION]="Для установки ноды выполните следующие шаги:\n1. Запустите этот скрипт на сервере, где будет установлена нода.\n2. Выберите 'Установка компонентов Remnawave', а затем 'Установить только ноду'."
                [SELFSTEAL]="Введите selfsteal домен для ноды, который указали при установке панели:"
                [PANEL_IP_PROMPT]="Введите IP адрес панели, чтобы установить соединение между панелью и ноды:"
                [IP_ERROR]="Введите корректный IP-адрес в формате X.X.X.X (например, 192.168.1.1)"
                [CERT_PROMPT]="Введите сертификат, полученный от панели, сохраняя строку SSL_CERT= (вставьте содержимое и 2 раза нажмите Enter):"
                [CERT_CONFIRM]="Вы уверены, что сертификат правильный? (y/n):"
                [ABORT_MESSAGE]="Установка прервана пользователем"
                [SUCCESS_MESSAGE]="Нода успешно подключена"
                #Node Check
                [NODE_CHECK]="Проверка подключения ноды для %s..."
                [NODE_ATTEMPT]="Попытка %d из %d..."
                [NODE_UNAVAILABLE]="Нода недоступна на попытке %d."
                [NODE_LAUNCHED]="Нода успешно подключена!"
                [NODE_NOT_CONNECTED]="Нода не подключена после %d попыток!"
                [CHECK_CONFIG]="Проверьте конфигурацию или перезапустите панель."
                #Add node to panel
                [ADD_NODE_TO_PANEL]="Добавить ноду в панель"
                [ENTER_NODE_NAME]="Введите имя для вашей ноды (например, Germany):"
                [USING_SAVED_TOKEN]="Используем сохранённый токен..."
                [INVALID_SAVED_TOKEN]="Сохранённый токен недействителен. Запрашиваем новый..."
                [ENTER_PANEL_USERNAME]="Введите логин панели: "
                [ENTER_PANEL_PASSWORD]="Введите пароль панели: "
                [TOKEN_RECEIVED_AND_SAVED]="Токен успешно получен и сохранён"
                [TOKEN_USED_SUCCESSFULLY]="Токен успешно использован"
                [NODE_ADDED_SUCCESS]="Нода успешно добавлена!"
                [CREATE_NEW_NODE]="Создаём новую ноду для %s"
                [CF_INVALID_NAME]="Ошибка: Имя конфигурационного профиля %s уже используется.\nПожалуйста, выберите другое имя."
                [CF_INVALID_LENGTH]="Ошибка: Имя конфигурационного профиля должно содержать от 5 до 20 символов."
                [CF_INVALID_CHARS]="Ошибка: Имя конфигурационного профиля должно содержать только английские буквы, цифры и дефис."
                #check
                [CHECK_UPDATE]="Проверить обновления"
                [GENERATING_CERTS]="Генерируем сертификаты для %s"
                [REQUIRED_DOMAINS]="Требуемые домены для сертификатов:"
                [CHECK_DOMAIN_IP_FAIL]="Не удалось определить IP-адрес домена или сервера."
                [CHECK_DOMAIN_IP_FAIL_INSTRUCTION]="Убедитесь, что домен %s правильно настроен и указывает на этот сервер (%s)."
                [CHECK_DOMAIN_CLOUDFLARE]="Домен %s указывает на IP Cloudflare (%s)."
                [CHECK_DOMAIN_CLOUDFLARE_INSTRUCTION]="Проксирование Cloudflare недопустимо для selfsteal домена. Отключите проксирование (переключите в режим 'DNS Only')."
                [CHECK_DOMAIN_MISMATCH]="Домен %s указывает на IP-адрес %s, который отличается от IP этого сервера (%s)."
                [CHECK_DOMAIN_MISMATCH_INSTRUCTION]="Для корректной работы домен должен указывать на текущий сервер."
                [NO_PANEL_NODE_INSTALLED]="Панель или нода не установлены. Пожалуйста, сначала установите панель или ноду."
                #update
                [UPDATE_AVAILABLE]="Доступна новая версия скрипта: %s (текущая версия: %s)."
                [UPDATE_CONFIRM]="Обновить скрипт? (y/n):"
                [UPDATE_CANCELLED]="Обновление отменено пользователем."
                [UPDATE_SUCCESS]="Скрипт успешно обновлён до версии %s!"
                [UPDATE_FAILED]="Ошибка при скачивании новой версии скрипта."
                [VERSION_CHECK_FAILED]="Не удалось определить версию удалённого скрипта. Пропускаем обновление."
                [LATEST_VERSION]="У вас уже установлена последняя версия скрипта (%s)."
                [RESTART_REQUIRED]="Пожалуйста, перезапустите скрипт для применения изменений."
                [LOCAL_FILE_NOT_FOUND]="Локальный файл скрипта не найден, загружаем новую версию..."
                #CLI
                [RUNNING_CLI]="Запуск Remnawave CLI..."
                [CLI_SUCCESS]="Remnawave CLI успешно выполнен!"
                [CLI_FAILED]="Не удалось выполнить Remnawave CLI. Убедитесь, что контейнер 'remnawave' запущен."
                [CONTAINER_NOT_RUNNING]="Контейнер 'remnawave' не запущен. Пожалуйста, запустите его сначала."
                #Cert_choise
                [CERT_METHOD_PROMPT]="Выберите метод генерации сертификатов для всех доменов:"
                [CERT_METHOD_CF]="Cloudflare API (поддерживает wildcard)"
                [CERT_METHOD_ACME]="ACME HTTP-01 (один домен, без wildcard)"
                [CERT_METHOD_CHOOSE]="Выберите действие (0-2):"
                [EMAIL_PROMPT]="Введите ваш email для регистрации в Let's Encrypt:"
                [CERTS_SKIPPED]="Все сертификаты уже существуют. Пропускаем генерацию."
                [ACME_METHOD]="Используем ACME (Let's Encrypt) с HTTP-01 вызовом (без поддержки wildcard)..."
                [CERT_GENERATION_FAILED]="Не удалось сгенерировать сертификаты. Проверьте введенные данные и настройки DNS."
                [ADDING_CRON_FOR_EXISTING_CERTS]="Добавление cron-задачи для обновления сертификатов..."
                [CRON_ALREADY_EXISTS]="Задача cron для обновления сертификатов уже существует."
                [CERT_NOT_FOUND]="Сертификат для домена не найден."
                [ERROR_PARSING_CERT]="Ошибка при разборе даты истечения сертификата."
                [CERT_EXPIRY_SOON]="Сертификаты скоро истекут через"
                [DAYS]="дней"
                [UPDATING_CRON]="Обновление задачи cron в соответствии со сроком действия сертификата."
                [GENERATING_WILDCARD_CERT]="Генерация wildcard-сертификата для"
                [WILDCARD_CERT_FOUND]="Wildcard-сертификат найден в /etc/letsencrypt/live/"
                [FOR_DOMAIN]="для"
                [START_CRON_ERROR]="Не удалось запустить cron. Пожалуйста, запустите его вручную."
                [DOMAINS_MUST_BE_UNIQUE]="Ошибка: Все домены (панель, подписка, и нода) должны быть уникальными."
                [CHOOSE_TEMPLATE_SOURCE]="Выберите источник шаблонов:"
                [SIMPLE_WEB_TEMPLATES]="Simple web templates"
                [SNI_TEMPLATES]="SNI templates"
                [CHOOSE_TEMPLATE_OPTION]="Выберите действие (0-2):"
                [INVALID_TEMPLATE_CHOICE]="Неверный выбор. Выберите 0-2."
                #Manage panel access
                [PORT_8443_OPEN]="Открыть доступ к панели на порту 8443"
                [PORT_8443_CLOSE]="Закрыть доступ к панели на порту 8443"
                [PORT_8443_IN_USE]="Порт 8443 уже занят другим процессом. Проверьте, какие службы используют порт, и освободите его."
                [NO_PORT_CHECK_TOOLS]="Не найдены инструменты для проверки порта (ss или netstat). Установите один из них."
                [OPEN_PANEL_LINK]="Ваша ссылка для входа в панель:"
                [PORT_8443_WARNING]="Не забудьте, что порт 8443 сейчас открыт для внешнего доступа. После восстановления панели выберите пункт закрытия порта 8443."
                [PORT_8443_CLOSED]="Порт 8443 закрыт."
                [NGINX_CONF_NOT_FOUND]="Файл nginx.conf не найден в $dir"
                [NGINX_CONF_ERROR]="Не удалось извлечь необходимые параметры из nginx.conf"
                [NGINX_CONF_MODIFY_FAILED]="Не удалось изменить конфигурацию Nginx."
                [PORT_8443_ALREADY_CONFIGURED]="Порт 8443 уже настроен в конфигурации Nginx."
                [UFW_RELOAD_FAILED]="Не удалось перезагрузить UFW."
                [PORT_8443_ALREADY_CLOSED]="Порт 8443 уже закрыт в UFW."
                # Sub Page Upload
                [UPLOADING_SUB_PAGE]="Загрузка пользовательского шаблона страницы подписки..."
                [ERROR_FETCH_SUB_PAGE]="Не удалось получить пользовательский шаблон страницы подписки."
                [SUB_PAGE_UPDATED_SUCCESS]="Пользовательский шаблон страницы подписки успешно обновлён."
                [SELECT_SUB_PAGE_CUSTOM]="Выберите действие (0-7):"
                [SELECT_SUB_PAGE_CUSTOM1]="Шаблоны страниц подписки"
                [SELECT_SUB_PAGE_CUSTOM2]="Шаблоны страниц подписки\nЗапускать только на сервере с панелью"
                [SELECT_SUB_PAGE_CUSTOM3]="Списки приложений для оригинальной страницы подписки:"
                [SELECT_SUB_PAGE_CUSTOM4]="Кастомные страницы подписки:"
                [SUB_PAGE_SELECT_CHOICE]="Недопустимый выбор. Пожалуйста, выберите от 0 до 7."
                [RESTORE_SUB_PAGE]="Восстановить шаблон страницы подписки по умолчанию"
                [CONTAINER_NOT_FOUND]="Контейнер %s не найден"
                [SUB_WITH_APPCONFIG_ASK]="Добавить файл конфигурации app-config.json?"
                [SUB_WITH_APPCONFIG_OPTION1]="Простой список приложений clash&sing"
                [SUB_WITH_APPCONFIG_OPTION2]="Множественный список приложений"
                [SUB_WITH_APPCONFIG_OPTION3]="Список приложений с поддержкой HWID"
                [SUB_WITH_APPCONFIG_SKIP]="Нет, пропустить добавление конфигурации"
                [SUB_WITH_APPCONFIG_INVALID]="Неверный выбор, конфигурация не будет добавлена"
                [SUB_WITH_APPCONFIG_INPUT]="Выберите действие (0–3):"
                # Custom Branding
                [BRANDING_SUPPORT_ASK]="Добавить поддержку брендирования страницы подписки?"
                [BRANDING_SUPPORT_YES]="Да, добавить поддержку брендирования"
                [BRANDING_SUPPORT_NO]="Нет, пропустить брендирование"
                [BRANDING_NAME_PROMPT]="Введите название вашего бренда:"
                [BRANDING_SUPPORT_URL_PROMPT]="Введите ссылку на страницу поддержки:"
                [BRANDING_LOGO_URL_PROMPT]="Введите ссылку на логотип вашего бренда:"
                [BRANDING_ADDED_SUCCESS]="Конфигурация брендирования успешно добавлена"
                # Template Upload
                [TEMPLATE_NOT_APPLIED]="Шаблон правил не применён"
                [UPLOADING_TEMPLATE]="Загрузка шаблона правил..."
                [ERROR_FETCH_TEMPLATE]="Не удалось загрузить шаблон правил."
                [ERROR_EMPTY_RESPONSE_TEMPLATE]="Пустой ответ от API при обновлении шаблона правил."
                [ERROR_UPDATE_TEMPLATE]="Не удалось обновить шаблон правил"
                [TEMPLATE_UPDATED_SUCCESS]="Шаблон правил успешно обновлён."
                [SELECT_TEMPLATE_CUSTOM]="Выберите действие (0-8):"
                [SELECT_TEMPLATE_CUSTOM1]="Шаблоны правил"
                [SELECT_TEMPLATE_CUSTOM2]="Шаблоны правил\nЗапускать только на сервере с панелью"
                [TEMPLATE_SELECT_CHOICE]="Неверный выбор. Выберите 0-8."
                [RESTORING_DEFAULT_TEMPLATES]="Восстановление шаблонов правил по умолчанию из GitHub..."
                [DEFAULT_TEMPLATES_COMPLETED]="Восстановление шаблонов правил по умолчанию завершено"
                [RESTORING_TEMPLATE]="Восстановление шаблона по умолчанию для %s..."
                [TEMPLATE_RESTORED_SUCCESS]="Шаблон по умолчанию для %s успешно восстановлен"
                [URL_NOT_ACCESSIBLE]="URL %s недоступен (HTTP статус: %s)"
                [FAILED_TO_DOWNLOAD_TEMPLATE]="Не удалось загрузить шаблон %s"
                [TEMPLATE_EMPTY]="Загруженный шаблон %s пуст"
                [INVALID_YAML_TEMPLATE]="Недопустимый YAML-шаблон для %s"
                [INVALID_JSON_TEMPLATE]="Недопустимый JSON-шаблон для %s"
                [EMPTY_TEMPLATE_VALUE]="Пустое значение шаблона для %s"
                [RESTORE_TEMPLATES]="Восстановить шаблоны правил по умолчанию"
                [FAILED_TO_EXTRACT_UUID]="Не удалось извлечь UUID шаблона подписки"
                [RENEWAL_CONF_NOT_FOUND]="Файл конфигурации обновления сертификатов не найден."
                [ARCHIVE_DIR_MISMATCH]="Несоответствие директории архива в конфигурации."
                [CERT_VERSION_NOT_FOUND]="Не удалось определить версию сертификатов."
                [RESULTS_CERTIFICATE_UPDATES]="Результаты обновления сертификатов:"
                [CERTIFICATE_FOR]="Сертификат для "
                [SUCCESSFULLY_UPDATED]="успешно обновлен"
                [FAILED_TO_UPDATE_CERTIFICATE_FOR]="Не удалось обновить сертификат для "
                [ERROR_CHECKING_EXPIRY_FOR]="Ошибка проверки даты истечения для "
                [DOES_NOT_REQUIRE_UPDATE]="не требует обновления ("
                [UPDATED]="Обновлен"
                [REMAINING]="Осталось"
                [ERROR_UPDATE]="Ошибка обновления"
                [ALREADY_EXPIRED]="уже истек"
                [CERT_CLOUDFLARE_FILE_NOT_FOUND]="Файл учетных данных Cloudflare не найден."
                [TELEGRAM_OAUTH_WARNING]="Включена авторизация через Telegram (TELEGRAM_OAUTH_ENABLED=true)."
                [CREATE_API_TOKEN_INSTRUCTION]="Зайдите в панель по адресу: https://%s\nПерейдите в раздел 'API токены' -> 'Создать новый токен' и создайте токен.\nСкопируйте созданный токен и введите его ниже."
                [ENTER_API_TOKEN]="Введите API-токен: "
                [EMPTY_TOKEN_ERROR]="Токен не введен. Завершение работы."
                [RATE_LIMIT_EXCEEDED]="Превышен лимит выдачи сертификатов Let's Encrypt"
                [FAILED_TO_MODIFY_HTML_FILES]="Не удалось изменить HTML файлы"
                [INSTALLING_YQ]="Установка yq..."
                [ERROR_SETTING_YQ_PERMISSIONS]="Ошибка установки прав yq!"
                [YQ_SUCCESSFULLY_INSTALLED]="yq успешно установлен!"
                [YQ_DOESNT_WORK_AFTER_INSTALLATION]="Ошибка: yq не работает после установки!"
                [ERROR_DOWNLOADING_YQ]="Ошибка загрузки yq!"
                [FAST_START]="Быстрый запуск: remnawave_reverse"
            )
            ;;
    esac
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
    if ! grep -q "bullseye" /etc/os-release && ! grep -q "bookworm" /etc/os-release && ! grep -q "jammy" /etc/os-release && ! grep -q "noble" /etc/os-release; then
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

    if docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . || docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q .; then
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
    if ! docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q .; then
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
    echo -e "${COLOR_GREEN}${LANG[MENU_9]}${COLOR_RESET}"
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
    else
        printf "${COLOR_YELLOW}${LANG[ALIAS_EXISTS]}${COLOR_RESET}\n" "$bashrc_file"
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
    echo -e "${COLOR_YELLOW}6. ${LANG[WARP_MENU]}${COLOR_RESET}" # Manage Warp by distilium
    echo -e ""
    echo -e "${COLOR_YELLOW}7. ${LANG[MENU_6]}${COLOR_RESET}" # Manage IPv6
    echo -e "${COLOR_YELLOW}8. ${LANG[MENU_7]}${COLOR_RESET}" # Manage certificates domain
    echo -e ""
    echo -e "${COLOR_YELLOW}9. ${LANG[MENU_8]}${COLOR_RESET}" # Check for updates
    echo -e "${COLOR_YELLOW}10. ${LANG[MENU_9]}${COLOR_RESET}" # Remove script
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

    if ! docker ps -q --filter "ancestor=remnawave/backend:latest" | grep -q . && ! docker ps -q --filter "ancestor=remnawave/node:latest" | grep -q .; then
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
            if [ ! -f "/opt/remnawave/.env-node" ]; then
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

#Custom Templates and Extensions by legiz
show_custom_legiz_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[MENU_5]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[SELECT_TEMPLATE_CUSTOM1]}${COLOR_RESET}" # Custom templates
    echo -e "${COLOR_YELLOW}2. ${LANG[SELECT_SUB_PAGE_CUSTOM1]}${COLOR_RESET}" # Custom sub page
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_custom_legiz() {
    show_custom_legiz_menu
    reading "${LANG[IPV6_PROMPT]}" LEGIZ_OPTION
    case $LEGIZ_OPTION in
        1)
            manage_template_upload
            log_clear
            manage_custom_legiz
            ;;
        2)
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

show_template_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SELECT_TEMPLATE_CUSTOM2]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}1. Xray json | without RU${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. Xray json | RU-BUNDLE${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. Xray json | RU-BUNDLE + CATEGORY-ADS-ALL BLOCK (not work on iOS)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. Mihomo    | RU-BUNDLE + RE-FILTER + OISD BIG (ADBLOCK)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. Mihomo    | full proxy without RU${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. Singbox   | RU-BUNDLE${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}7. Singbox   | RU-BUNDLE + OISD BIG (ADBLOCK)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}8. ${LANG[RESTORE_TEMPLATES]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_template_upload() {
    if ! docker ps -a --filter "name=remnawave" --format '{{.Names}}' | grep -q "^remnawave$"; then
        printf "${COLOR_RED}${LANG[CONTAINER_NOT_FOUND]}${COLOR_RESET}\n" "remnawave"
        sleep 2
        log_clear
        exit 1
    fi
    
    show_template_menu
    reading "${LANG[SELECT_TEMPLATE_CUSTOM]}" TEMPLATE_OPTION
    case $TEMPLATE_OPTION in
        1)
            update_subscription_template "XRAY_JSON" "https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/xray-json-simple-without-ru.json" "false"
            ;;
        2)
            update_subscription_template "XRAY_JSON" "https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/xray-json-ru-bundle.json" "false"
            ;;
        3)
            update_subscription_template "XRAY_JSON" "https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/xray-json-ru-bundle-category-ads-all.json" "false"
            ;;
        4)
            update_subscription_template "MIHOMO" "https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/mihomo-ru-bundle.yaml" "true"
            ;;
        5)
            update_subscription_template "MIHOMO" "https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/mihomo-simple-without-ru.yaml" "true"
            ;;
        6)
            update_subscription_template "SINGBOX" "https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/singbox-ru-bundle.json" "false"
            ;;
        7)
            update_subscription_template "SINGBOX" "https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/by-legiz/subscription-templates/singbox-ru-bundle-oisd-big.json" "false"
            ;;
        8)
            restore_default_templates
            ;;
        0)
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            return 0
            ;;
        *)
            echo -e "${COLOR_YELLOW}${LANG[TEMPLATE_SELECT_CHOICE]}${COLOR_RESET}"
            sleep 2
            log_clear
            manage_template_upload
            ;;
    esac
}

restore_default_templates() {
    echo -e "${COLOR_YELLOW}${LANG[RESTORING_DEFAULT_TEMPLATES]}${COLOR_RESET}"

    local domain_url="127.0.0.1:3000"
    TEMP_DIR="/tmp/remnawave_templates"

    get_panel_token
    token=$(cat "$TOKEN_FILE")

    mkdir -p "$TEMP_DIR"

    local template_configs=(
        "CLASH|https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/remnawave-default/subscription-templates/clash.yaml|yaml"
        "MIHOMO|https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/remnawave-default/subscription-templates/mihomo.yaml|yaml"
        "STASH|https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/remnawave-default/subscription-templates/stash.yaml|yaml"
        "SINGBOX|https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/remnawave-default/subscription-templates/singbox.json|json"
        "SINGBOX_LEGACY|https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/remnawave-default/subscription-templates/singbox-legacy.json|json"
        "XRAY_JSON|https://raw.githubusercontent.com/remnawave/templates/refs/heads/main/remnawave-default/subscription-templates/xray-json.json|json"
    )

    for template_entry in "${template_configs[@]}"; do
        IFS='|' read -r template_type template_url template_format <<< "$template_entry"
        printf "${COLOR_YELLOW}${LANG[RESTORING_TEMPLATE]}${COLOR_RESET}\n" "$template_type"

        local http_status=$(curl -s -L --write-out "%{http_code}" --output /dev/null "$template_url")
        if [ "$http_status" != "200" ]; then
            printf "${COLOR_RED}${LANG[URL_NOT_ACCESSIBLE]}${COLOR_RESET}\n" "$template_url" "$http_status"
            continue
        fi

        local temp_file="$TEMP_DIR/$template_type.$template_format"
        if ! curl -s -L -o "$temp_file" "$template_url"; then
            printf "${COLOR_RED}${LANG[FAILED_TO_DOWNLOAD_TEMPLATE]}${COLOR_RESET}\n" "$template_type"
            rm -f "$temp_file"
            continue
        fi

        if [ ! -s "$temp_file" ]; then
            printf "${COLOR_RED}${LANG[TEMPLATE_EMPTY]}${COLOR_RESET}\n" "$template_type"
            rm -f "$temp_file"
            continue
        fi

        local template_content
        template_content=$(cat "$temp_file")

        local template_field template_value
        if [ "$template_format" = "yaml" ]; then
            if command -v yq >/dev/null 2>&1; then
                if ! echo "$template_content" | yq e '.' - >/dev/null 2>&1; then
                    printf "${COLOR_RED}${LANG[INVALID_YAML_TEMPLATE]}${COLOR_RESET}\n" "$template_type"
                    rm -f "$temp_file"
                    continue
                fi
            fi
            template_field="encodedTemplateYaml"
            template_value=$(echo "$template_content" | base64 -w 0)
        else
            if ! echo "$template_content" | jq . >/dev/null 2>&1; then
                printf "${COLOR_RED}${LANG[INVALID_JSON_TEMPLATE]}${COLOR_RESET}\n" "$template_type"
                rm -f "$temp_file"
                continue
            fi
            template_field="templateJson"
            template_value=$(echo "$template_content" | jq -c .)
        fi

        if [ -z "$template_value" ]; then
            printf "${COLOR_RED}${LANG[EMPTY_TEMPLATE_VALUE]}${COLOR_RESET}\n" "$template_type"
            rm -f "$temp_file"
            continue
        fi

        local get_response=$(make_api_request "GET" "http://$domain_url/api/subscription-templates/$template_type" "$token")
        if [ -z "$get_response" ]; then
            echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_TEMPLATE]}${COLOR_RESET}"
            rm -f "$temp_file"
            continue
        fi

        if ! echo "$get_response" | jq -e '.response' > /dev/null; then
            echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_TEMPLATE]}: $get_response${COLOR_RESET}"
            rm -f "$temp_file"
            continue
        fi

        local uuid=$(echo "$get_response" | jq -r '.response.uuid // null')
        if [ -z "$uuid" ] || [ "$uuid" == "null" ]; then
            echo -e "${COLOR_RED}Не удалось извлечь UUID для шаблона $template_type${COLOR_RESET}"
            rm -f "$temp_file"
            continue
        fi

        if [ "$template_format" = "yaml" ]; then
            local request_body=$(jq -n --arg template "$template_value" \
                                      --arg type "$template_type" \
                                      --arg uuid "$uuid" \
                                      '{encodedTemplateYaml: $template, templateType: $type, templateJson: {}, uuid: $uuid}')
        else
            local request_body=$(jq -n --argjson template "$template_value" \
                                      --arg type "$template_type" \
                                      --arg uuid "$uuid" \
                                      '{templateJson: $template, templateType: $type, encodedTemplateYaml: "", uuid: $uuid}')
        fi

        local response=$(make_api_request "PUT" "http://$domain_url/api/subscription-templates" "$token" "$request_body")
        if [ -z "$response" ]; then
            echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_TEMPLATE]}${COLOR_RESET}"
            rm -f "$temp_file"
            continue
        fi

        if echo "$response" | jq -e '.response | select(.uuid != null)' > /dev/null; then
            printf "${COLOR_GREEN}${LANG[TEMPLATE_RESTORED_SUCCESS]}${COLOR_RESET}\n" "$template_type"
        else
            echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_TEMPLATE]}: Шаблон для $template_type не применён${COLOR_RESET}"
        fi

        rm -f "$temp_file"
    done

    rm -rf "$TEMP_DIR"
    echo -e "${COLOR_GREEN}${LANG[DEFAULT_TEMPLATES_COMPLETED]}${COLOR_RESET}"
    return 0
}

update_subscription_template() {
    local template_type="$1"
    local template_url="$2"
    local is_yaml_template="$3" # "true" for YAML, "false" for JSON
    local domain_url="127.0.0.1:3000"

    echo -e "${COLOR_YELLOW}${LANG[UPLOADING_TEMPLATE]}${COLOR_RESET}"

    local template_content=$(curl -s "$template_url")
    if [ -z "$template_content" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_FETCH_TEMPLATE]}${COLOR_RESET}"
        return 1
    fi

    if [ "$is_yaml_template" = "true" ]; then
        if command -v yq >/dev/null 2>&1; then
            if ! echo "$template_content" | yq e '.' - >/dev/null 2>&1; then
                echo -e "${COLOR_RED}Invalid YAML template from $template_url${COLOR_RESET}"
                return 1
            fi
        else
            if [ -z "$template_content" ]; then
                echo -e "${COLOR_RED}Invalid YAML template: empty content from $template_url${COLOR_RESET}"
                return 1
            fi
        fi
        template_field="encodedTemplateYaml"
        template_value=$(echo "$template_content" | base64 -w 0)
    else
        if ! echo "$template_content" | jq . >/dev/null 2>&1; then
            echo -e "${COLOR_RED}Invalid JSON template from $template_url${COLOR_RESET}"
            return 1
        fi
        template_field="templateJson"
        template_value="$template_content"
    fi

    get_panel_token
    token=$(cat "$TOKEN_FILE")

    local get_response=$(make_api_request "GET" "http://$domain_url/api/subscription-templates/$template_type" "$token")
    if [ -z "$get_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_TEMPLATE]}${COLOR_RESET}"
        return 1
    fi

    if ! echo "$get_response" | jq -e '.response' > /dev/null; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_TEMPLATE]}: $get_response${COLOR_RESET}"
        return 1
    fi
    local uuid=$(echo "$get_response" | jq -r '.response.uuid // null')
    if [ -z "$uuid" ] || [ "$uuid" == "null" ]; then
        echo -e "${COLOR_RED}${LANG[FAILED_TO_EXTRACT_UUID]}${COLOR_RESET}"
        return 1
    fi

    if [ "$is_yaml_template" = "true" ]; then
        local request_body=$(jq -n --arg template "$template_value" \
                                  --arg type "$template_type" \
                                  --arg uuid "$uuid" \
                                  '{encodedTemplateYaml: $template, templateType: $type, templateJson: {}, uuid: $uuid}')
    else
        local request_body=$(jq -n --argjson template "$template_value" \
                                  --arg type "$template_type" \
                                  --arg uuid "$uuid" \
                                  '{templateJson: $template, templateType: $type, encodedTemplateYaml: "", uuid: $uuid}')
    fi

    local response=$(make_api_request "PUT" "http://$domain_url/api/subscription-templates" "$token" "$request_body")

    if [ -z "$response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_TEMPLATE]}${COLOR_RESET}"
        return 1
    fi

    if echo "$response" | jq -e '.response | select(.uuid != null)' > /dev/null; then
        echo -e "${COLOR_GREEN}${LANG[TEMPLATE_UPDATED_SUCCESS]}${COLOR_RESET}"
        return 0
    else
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_TEMPLATE]}: ${LANG[TEMPLATE_NOT_APPLIED]}${COLOR_RESET}"
        return 1
    fi
}

show_sub_page_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SELECT_SUB_PAGE_CUSTOM2]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SELECT_SUB_PAGE_CUSTOM3]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}1. Simple custom app list (clash and sing)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. Multiapp custom app list${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}3. HWID only custom app list${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[SELECT_SUB_PAGE_CUSTOM4]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}4. Orion web page template (support custom app list)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}5. Material web page template (support custom app list)${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}6. Marzbanify web page template (clash and sing)${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}7. ${LANG[RESTORE_SUB_PAGE]}${COLOR_RESET}"
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
    reading "Select option (1-2):" BRANDING_OPTION

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
        1|2|3)
            [ -f "$index_file" ] && rm -f "$index_file"

            echo -e "${COLOR_YELLOW}${LANG[UPLOADING_SUB_PAGE]}${COLOR_RESET}"
            local primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/app-config.json"
            local fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/app-config.json"
            if [ "$SUB_PAGE_OPTION" == "2" ]; then
                primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/multiapp/app-config.json"
                fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/multiapp/app-config.json"
            elif [ "$SUB_PAGE_OPTION" == "3" ]; then
                primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/hwid/app-config.json"
                fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/hwid/app-config.json"
            fi

            if ! download_with_fallback "$primary_url" "$fallback_url" "$config_file"; then
                echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                sleep 2
                log_clear
                return 1
            fi

            branding_add_to_appconfig "$config_file"

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./app-config.json:/opt/app/frontend/assets/app-config.json"]' -i "$docker_compose_file"
            ;;

        4)
            [ -f "$config_file" ] && rm -f "$config_file"
            [ -f "$index_file" ] && rm -f "$index_file"

            echo -e "${COLOR_YELLOW}${LANG[UPLOADING_SUB_PAGE]}${COLOR_RESET}"
            local primary_index_url="https://raw.githubusercontent.com/legiz-ru/Orion/refs/heads/main/index.html"
            local fallback_index_url="https://cdn.jsdelivr.net/gh/legiz-ru/Orion@main/index.html"
            if ! download_with_fallback "$primary_index_url" "$fallback_index_url" "$index_file"; then
                echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                sleep 2
                log_clear
                return 1
            fi

            echo -e "${COLOR_GREEN}${LANG[SUB_WITH_APPCONFIG_ASK]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}1. ${LANG[SUB_WITH_APPCONFIG_OPTION1]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}2. ${LANG[SUB_WITH_APPCONFIG_OPTION2]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}3. ${LANG[SUB_WITH_APPCONFIG_OPTION3]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}0. ${LANG[SUB_WITH_APPCONFIG_SKIP]}${COLOR_RESET}"
            echo -e ""
            reading "${LANG[SUB_WITH_APPCONFIG_INPUT]}" SUB_WITH_APPCONFIG

            case $SUB_WITH_APPCONFIG in
                1|2|3)
                    local primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/app-config.json"
                    local fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/app-config.json"
                    if [ "$SUB_WITH_APPCONFIG" == "2" ]; then
                        primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/multiapp/app-config.json"
                        fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/multiapp/app-config.json"
                    elif [ "$SUB_WITH_APPCONFIG" == "3" ]; then
                        primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/hwid/app-config.json"
                        fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/hwid/app-config.json"
                    fi
                    
                    if ! download_with_fallback "$primary_config_url" "$fallback_config_url" "$config_file"; then
                        echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                        sleep 2
                        log_clear
                        return 1
                    fi

                    branding_add_to_appconfig "$config_file"
                    ;;
                0)
                    [ -f "$config_file" ] && rm -f "$config_file"
                    [ -f "$index_file" ] && rm -f "$index_file"
                    ;;
                *)
                    echo -e "${COLOR_RED}${LANG[SUB_WITH_APPCONFIG_INVALID]}${COLOR_RESET}"
                    [ -f "$config_file" ] && rm -f "$config_file"
                    ;;
            esac

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"

            if [ -f "$config_file" ]; then
                /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./app-config.json:/opt/app/frontend/assets/app-config.json"]' -i "$docker_compose_file"
            fi
            ;;

        5)
            [ -f "$config_file" ] && rm -f "$config_file"
            [ -f "$index_file" ] && rm -f "$index_file"

            echo -e "${COLOR_YELLOW}${LANG[UPLOADING_SUB_PAGE]}${COLOR_RESET}"
            local primary_index_url="https://raw.githubusercontent.com/legiz-ru/material-remnawave-subscription-page/refs/heads/main/index.html"
            local fallback_index_url="https://cdn.jsdelivr.net/gh/legiz-ru/material-remnawave-subscription-page@main/index.html"
            if ! download_with_fallback "$primary_index_url" "$fallback_index_url" "$index_file"; then
                echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                sleep 2
                log_clear
                return 1
            fi

            echo -e "${COLOR_GREEN}${LANG[SUB_WITH_APPCONFIG_ASK]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}1. ${LANG[SUB_WITH_APPCONFIG_OPTION1]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}2. ${LANG[SUB_WITH_APPCONFIG_OPTION2]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}3. ${LANG[SUB_WITH_APPCONFIG_OPTION3]}${COLOR_RESET}"
            echo -e ""
            echo -e "${COLOR_YELLOW}0. ${LANG[SUB_WITH_APPCONFIG_SKIP]}${COLOR_RESET}"
            echo -e ""
            reading "${LANG[SUB_WITH_APPCONFIG_INPUT]}" SUB_WITH_APPCONFIG

            case $SUB_WITH_APPCONFIG in
                1|2|3)
                    local primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/app-config.json"
                    local fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/app-config.json"
                    if [ "$SUB_WITH_APPCONFIG" == "2" ]; then
                        primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/multiapp/app-config.json"
                        fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/multiapp/app-config.json"
                    elif [ "$SUB_WITH_APPCONFIG" == "3" ]; then
                        primary_config_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/hwid/app-config.json"
                        fallback_config_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/hwid/app-config.json"
                    fi

                    if ! download_with_fallback "$primary_config_url" "$fallback_config_url" "$config_file"; then
                        echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                        sleep 2
                        log_clear
                        return 1
                    fi
                    branding_add_to_appconfig "$config_file"
                    ;;
                0)
                    [ -f "$config_file" ] && rm -f "$config_file"
                    [ -f "$index_file" ] && rm -f "$index_file"
                    ;;
                *)
                    echo -e "${COLOR_RED}${LANG[SUB_WITH_APPCONFIG_INVALID]}${COLOR_RESET}"
                    [ -f "$config_file" ] && rm -f "$config_file"
                    ;;
            esac

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"

            if [ -f "$config_file" ]; then
                /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./app-config.json:/opt/app/frontend/assets/app-config.json"]' -i "$docker_compose_file"
            fi
            ;;

        6)
            [ -f "$config_file" ] && rm -f "$config_file"

            echo -e "${COLOR_YELLOW}${LANG[UPLOADING_SUB_PAGE]}${COLOR_RESET}"
            local primary_url="https://raw.githubusercontent.com/legiz-ru/my-remnawave/refs/heads/main/sub-page/customweb/clash-sing/index.html"
            local fallback_url="https://cdn.jsdelivr.net/gh/legiz-ru/my-remnawave@main/sub-page/customweb/clash-sing/index.html"
            if ! download_with_fallback "$primary_url" "$fallback_url" "$index_file"; then
                echo -e "${COLOR_RED}${LANG[ERROR_FETCH_SUB_PAGE]}${COLOR_RESET}"
                sleep 2
                log_clear
                return 1
            fi

            /usr/bin/yq eval 'del(.services."remnawave-subscription-page".volumes)' -i "$docker_compose_file"
            /usr/bin/yq eval '.services."remnawave-subscription-page".volumes += ["./index.html:/opt/app/frontend/index.html"]' -i "$docker_compose_file"
            ;;
        
        7)
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
#Custom Templates and Extensions by legiz

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

  export LC_ALL=en_US.UTF-8
  export LANG=en_US.UTF-8

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
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

randomhtml() {
    local template_source="$1"

    cd /opt/ || { echo "${LANG[UNPACK_ERROR]}"; exit 1; }

    rm -f main.zip 2>/dev/null
    rm -rf simple-web-templates-main/ sni-templates-main/ 2>/dev/null

    echo -e "${COLOR_YELLOW}${LANG[RANDOM_TEMPLATE]}${COLOR_RESET}"
    sleep 1
    spinner $$ "${LANG[WAITING]}" &
    spinner_pid=$!

    template_urls=(
        "https://github.com/eGamesAPI/simple-web-templates/archive/refs/heads/main.zip"
        "https://github.com/SmallPoppa/sni-templates/archive/refs/heads/main.zip"
    )

    if [ -z "$template_source" ]; then
        selected_url=${template_urls[$RANDOM % ${#template_urls[@]}]}
    else
        if [ "$template_source" = "simple" ]; then
            selected_url=${template_urls[0]}  # Simple web templates
        else
            selected_url=${template_urls[1]}  # Sni templates
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
    else
        cd sni-templates-main/ || { echo "${LANG[UNPACK_ERROR]}"; exit 0; }
        rm -rf assets "README.md" "index.html" 2>/dev/null
    fi

    mapfile -t templates < <(find . -maxdepth 1 -type d -not -path . | sed 's|./||')

    RandomHTML="${templates[$RANDOM % ${#templates[@]}]}"

    if [[ "$selected_url" == *"SmallPoppa"* && "$RandomHTML" == "503 error pages" ]]; then
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
    local random_meta_name=${meta_names[$RANDOM % ${#meta_names[@]}]}

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
    else
        echo "${LANG[UNPACK_ERROR]}" && exit 1
    fi

    if ! find "/var/www/html" -type f -name "*.html" -exec grep -q "$random_meta_name" {} \; 2>/dev/null; then
        echo -e "${COLOR_RED}${LANG[FAILED_TO_MODIFY_HTML_FILES]}${COLOR_RESET}"
        return 1
    fi

    cd /opt/
    rm -rf simple-web-templates-main/ sni-templates-main/
}
#Manage Template for steal

install_packages() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALL_PACKAGES]}${COLOR_RESET}"
    
    if ! apt-get update -y; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_LIST]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! apt-get install -y ca-certificates curl jq ufw wget gnupg unzip nano dialog git certbot python3-certbot-dns-cloudflare unattended-upgrades locales dnsutils coreutils grep gawk; then
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

    if [ ! -f /etc/locale.gen ]; then
        echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    fi
    if ! grep -q "^en_US.UTF-8 UTF-8" /etc/locale.gen; then
        if grep -q "^# en_US.UTF-8 UTF-8" /etc/locale.gen; then
            sed -i 's/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        else
            echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
        fi
    fi
    if ! locale-gen || ! update-locale LANG=en_US.UTF-8; then
        echo -e "${COLOR_RED}${LANG[ERROR_CONFIGURE_LOCALES]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! ping -c 1 download.docker.com >/dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_DOCKER_DNS]}${COLOR_RESET}" >&2
        return 1
    fi

    if grep -q "Ubuntu" /etc/os-release; then
        install -m 0755 -d /etc/apt/keyrings
        if ! curl -fsSL https://download.docker.com/linux/ubuntu/gpg | tee /etc/apt/keyrings/docker.asc > /dev/null; then
            echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOAD_DOCKER_KEY]}${COLOR_RESET}" >&2
            return 1
        fi
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    elif grep -q "Debian" /etc/os-release; then
        install -m 0755 -d /etc/apt/keyrings
        if ! curl -fsSL https://download.docker.com/linux/debian/gpg | tee /etc/apt/keyrings/docker.asc > /dev/null; then
            echo -e "${COLOR_RED}${LANG[ERROR_DOWNLOAD_DOCKER_KEY]}${COLOR_RESET}" >&2
            return 1
        fi
        chmod a+r /etc/apt/keyrings/docker.asc
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi

    if ! apt-get update; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_DOCKER_LIST]}${COLOR_RESET}" >&2
        return 1
    fi

    if ! apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; then
        echo -e "${COLOR_RED}${LANG[ERROR_INSTALL_DOCKER]}${COLOR_RESET}" >&2
        return 1
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
    echo -e "${COLOR_GREEN}${LANG[MENU_7]}${COLOR_RESET}"
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
            local cert_domain=$(echo "$domain" | sed -E 's/(-[0-9]+)$//')
            unique_domains["$cert_domain"]="$domain_dir"
        fi
    done

    for cert_domain in "${!unique_domains[@]}"; do
        local domain_dir="${unique_domains[$cert_domain]}"
        local domain=$(basename "$domain_dir")
        local cert_method="2" # Default ACME
        local renewal_conf="/etc/letsencrypt/renewal/$domain.conf"
        if [ -f "$renewal_conf" ] && grep -q "dns_cloudflare" "$renewal_conf"; then
            cert_method="1" # Cloudflare
        fi

        local cert_file="$domain_dir/fullchain.pem"
        local cert_mtime_before=$(stat -c %Y "$cert_file" 2>/dev/null || echo 0)

        fix_letsencrypt_structure "$cert_domain"

        local days_left=$(check_cert_expiry "$domain")
        if [ $? -ne 0 ]; then
            cert_status["$cert_domain"]="${LANG[ERROR_PARSING_CERT]}"
            continue
        fi

        if [ "$cert_method" == "1" ]; then
            local cf_credentials_file=$(grep "dns_cloudflare_credentials" "$renewal_conf" | cut -d'=' -f2 | tr -d ' ')
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

            local new_cert_dir=$(find "$cert_dir" -maxdepth 1 -type d -name "$cert_domain*" | sort -V | tail -n 1)
            local new_domain=$(basename "$new_cert_dir")
            local cert_mtime_after=$(stat -c %Y "$new_cert_dir/fullchain.pem" 2>/dev/null || echo 0)
            if check_certificates "$new_domain" > /dev/null 2>&1 && [ "$cert_mtime_before" != "$cert_mtime_after" ]; then
                local new_days_left=$(check_cert_expiry "$new_domain")
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
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
    reading "${LANG[CERT_METHOD_CHOOSE]}" CERT_METHOD

    if [ "$CERT_METHOD" == "0" ]; then
        echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
        exit 1
    fi

    local LETSENCRYPT_EMAIL=""
    if [ "$CERT_METHOD" == "2" ]; then
        reading "${LANG[EMAIL_PROMPT]}" LETSENCRYPT_EMAIL
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        echo -e "${COLOR_YELLOW}${LANG[GENERATING_WILDCARD_CERT]} *.$NEW_DOMAIN...${COLOR_RESET}"
        get_certificates "$NEW_DOMAIN" "1" "" "*.$NEW_DOMAIN"
    elif [ "$CERT_METHOD" == "2" ]; then
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

### API Functions ###
make_api_request() {
    local method=$1
    local url=$2
    local token=$3
    local data=$4

    local headers=(
        -H "Authorization: Bearer $token"
        -H "Content-Type: application/json"
        -H "X-Forwarded-For: ${url#http://}"
        -H "X-Forwarded-Proto: https"
        -H "X-Remnawave-Client-Type: browser"
    )

    if [ -n "$data" ]; then
        curl -s -X "$method" "$url" "${headers[@]}" -d "$data"
    else
        curl -s -X "$method" "$url" "${headers[@]}"
    fi
}


register_remnawave() {
    local domain_url=$1
    local username=$2
    local password=$3
    local token=$4

    local register_data='{"username":"'"$username"'","password":"'"$password"'"}'
    local register_response=$(make_api_request "POST" "http://$domain_url/api/auth/register" "$token" "$register_data")

    if [ -z "$register_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_REGISTER]}${COLOR_RESET}"
    elif [[ "$register_response" == *"accessToken"* ]]; then
        echo "$register_response" | jq -r '.response.accessToken'
    else
        echo -e "${COLOR_RED}${LANG[ERROR_REGISTER]}: $register_response${COLOR_RESET}"
    fi
}

get_panel_token() {
    TOKEN_FILE="${DIR_REMNAWAVE}/token"
    ENV_FILE="/opt/remnawave/.env"
    local domain_url="127.0.0.1:3000"
    
    local oauth_enabled=false
    if [ -f "$ENV_FILE" ]; then
        if grep -q "^TELEGRAM_OAUTH_ENABLED=true" "$ENV_FILE" || \
           grep -q "^OAUTH2_GITHUB_ENABLED=true" "$ENV_FILE" || \
           grep -q "^OAUTH2_POCKETID_ENABLED=true" "$ENV_FILE" || \
           grep -q "^OAUTH2_YANDEX_ENABLED=true" "$ENV_FILE"; then
            oauth_enabled=true
        fi
    fi
    
    if [ -f "$TOKEN_FILE" ]; then
        token=$(cat "$TOKEN_FILE")
        echo -e "${COLOR_YELLOW}${LANG[USING_SAVED_TOKEN]}${COLOR_RESET}"
        local test_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
        
        if [ -z "$test_response" ] || ! echo "$test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
            if echo "$test_response" | grep -q '"statusCode":401' || \
               echo "$test_response" | jq -e '.message | test("Unauthorized")' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}${COLOR_RESET}"
            else
                echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}: $test_response${COLOR_RESET}"
            fi
            token=""
        fi
    fi
    
    if [ -z "$token" ]; then
        if [ "$oauth_enabled" = true ]; then
            echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
            echo -e "${COLOR_RED}${LANG[WARNING_LABEL]}${COLOR_RESET}"
            echo -e "${COLOR_YELLOW}${LANG[TELEGRAM_OAUTH_WARNING]}${COLOR_RESET}"
            printf "${COLOR_YELLOW}${LANG[CREATE_API_TOKEN_INSTRUCTION]}${COLOR_RESET}\n" "$PANEL_DOMAIN"
            reading "${LANG[ENTER_API_TOKEN]}" token
            if [ -z "$token" ]; then
                echo -e "${COLOR_RED}${LANG[EMPTY_TOKEN_ERROR]}${COLOR_RESET}"
                return 1
            fi
            
            local test_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
            if [ -z "$test_response" ] || ! echo "$test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
                echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}: $test_response${COLOR_RESET}"
                return 1
            fi
        else
            reading "${LANG[ENTER_PANEL_USERNAME]}" username
            reading "${LANG[ENTER_PANEL_PASSWORD]}" password
            
            local login_response=$(make_api_request "POST" "${domain_url}/api/auth/login" "" "{\"username\":\"$username\",\"password\":\"$password\"}")
            token=$(echo "$login_response" | jq -r '.response.accessToken // .accessToken // ""')
            if [ -z "$token" ] || [ "$token" == "null" ]; then
                echo -e "${COLOR_RED}${LANG[ERROR_TOKEN]}: $login_response${COLOR_RESET}"
                return 1
            fi
        fi
        
        echo "$token" > "$TOKEN_FILE"
        echo -e "${COLOR_GREEN}${LANG[TOKEN_RECEIVED_AND_SAVED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_GREEN}${LANG[TOKEN_USED_SUCCESSFULLY]}${COLOR_RESET}"
    fi
    
    local final_test_response=$(make_api_request "GET" "${domain_url}/api/config-profiles" "$token")
    if [ -z "$final_test_response" ] || ! echo "$final_test_response" | jq -e '.response.configProfiles' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[INVALID_SAVED_TOKEN]}: $final_test_response${COLOR_RESET}"
        return 1
    fi
}

get_public_key() {
    local domain_url=$1
    local token=$2
    local target_dir=$3

    local api_response=$(make_api_request "GET" "http://$domain_url/api/keygen" "$token")

    if [ -z "$api_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_PUBLIC_KEY]}${COLOR_RESET}"
    fi

    local pubkey=$(echo "$api_response" | jq -r '.response.pubKey')
    if [ -z "$pubkey" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EXTRACT_PUBLIC_KEY]}${COLOR_RESET}"
    fi

    local env_node_file="$target_dir/.env-node"
    cat > "$env_node_file" <<EOL
### APP ###
APP_PORT=2222

### XRAY ###
SSL_CERT="$pubkey"
EOL
    echo -e "${COLOR_YELLOW}${LANG[PUBLIC_KEY_SUCCESS]}${COLOR_RESET}"
    echo "$pubkey"
}

generate_xray_keys() {
    docker run --rm ghcr.io/xtls/xray-core x25519 > /tmp/xray_keys.txt 2>&1 &
    spinner $! "${LANG[WAITING]}"
    wait $!

    local keys=$(cat /tmp/xray_keys.txt)
    rm -f /tmp/xray_keys.txt

    if [ -z "$keys" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_GENERATE_KEYS]}${COLOR_RESET}"
    fi

    local private_key=$(echo "$keys" | grep "Private key:" | awk '{print $3}')
    local public_key=$(echo "$keys" | grep "Public key:" | awk '{print $3}')

    echo "$private_key $public_key"
}

create_node() {
    local domain_url=$1
    local token=$2
    local config_profile_uuid=$3
    local inbound_uuid=$4
    local node_address="${5:-$(curl -s -4 ifconfig.me || curl -s -4 api.ipify.org || curl -s -4 ipinfo.io/ip)}"
    local node_name="${6:-Steal}"

    local node_data=$(cat <<EOF
{
    "name": "$node_name",
    "address": "$node_address",
    "port": 2222,
    "configProfile": {
        "activeConfigProfileUuid": "$config_profile_uuid",
        "activeInbounds": ["$inbound_uuid"]
    },
    "isTrafficTrackingActive": false,
    "trafficLimitBytes": 0,
    "notifyPercent": 0,
    "trafficResetDay": 31,
    "excludedInbounds": [],
    "countryCode": "XX",
    "consumptionMultiplier": 1.0
}
EOF
)

    local node_response=$(make_api_request "POST" "http://$domain_url/api/nodes" "$token" "$node_data")

    if [ -z "$node_response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_NODE]}${COLOR_RESET}"
    fi

    if echo "$node_response" | jq -e '.response.uuid' > /dev/null; then
        printf "${COLOR_GREEN}${LANG[NODE_CREATED]}${COLOR_RESET}\n"
    else
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_NODE]}${COLOR_RESET}"
    fi
}

get_config_profiles() {
    local domain_url="$1"
    local token="$2"

    local config_response=$(make_api_request "GET" "http://$domain_url/api/config-profiles" "$token")
    if [ -z "$config_response" ] || ! echo "$config_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_NO_CONFIGS]}${COLOR_RESET}"
        return 1
    fi

    local profile_uuid=$(echo "$config_response" | jq -r '.response.configProfiles[] | select(.name == "Default-Profile") | .uuid' 2>/dev/null)
    if [ -z "$profile_uuid" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_DEFAULT_PROFILE]}${COLOR_RESET}"
        return 0
    fi

    echo "$profile_uuid"
    return 0
}

delete_config_profile() {
    local domain_url="$1"
    local token="$2"
    local profile_uuid="$3"

    if [ -z "$profile_uuid" ]; then
        profile_uuid=$(get_config_profiles "$domain_url" "$token")
        if [ $? -ne 0 ] || [ -z "$profile_uuid" ]; then
            return 0
        fi
    fi

    local delete_response=$(make_api_request "DELETE" "http://$domain_url/api/config-profiles/$profile_uuid" "$token")
    if [ -z "$delete_response" ] || ! echo "$delete_response" | jq -e '.' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_DELETE_PROFILE]}${COLOR_RESET}"
        return 1
    fi

    return 0
}

create_config_profile() {
    local domain_url=$1
    local token=$2
    local name=$3
    local domain=$4
    local public_key=$5
    local private_key=$6
    local inbound_tag="${7:-Steal}"

    local short_id=$(openssl rand -hex 8)

    local request_body=$(jq -n --arg name "$name" --arg domain "$domain" --arg public_key "$public_key" --arg private_key "$private_key" --arg short_id "$short_id" --arg inbound_tag "$inbound_tag" '{
        name: $name,
        config: {
            log: { loglevel: "warning" },
            dns: {
                queryStrategy: "ForceIPv4",
                servers: [{ address: "https://dns.google/dns-query", skipFallback: false }]
            },
            inbounds: [{
                tag: $inbound_tag,
                port: 443,
                protocol: "vless",
                settings: { clients: [], decryption: "none" },
                sniffing: { enabled: true, destOverride: ["http", "tls"] },
                streamSettings: {
                    network: "tcp",
                    security: "reality",
                    realitySettings: {
                        show: false,
                        xver: 1,
                        dest: "/dev/shm/nginx.sock",
                        spiderX: "",
                        shortIds: [$short_id],
                        publicKey: $public_key,
                        privateKey: $private_key,
                        serverNames: [$domain]
                    }
                }
            }],
            outbounds: [
                { tag: "DIRECT", protocol: "freedom" },
                { tag: "BLOCK", protocol: "blackhole" }
            ],
            routing: {
                rules: [
                    { ip: ["geoip:private"], type: "field", outboundTag: "BLOCK" },
                    { type: "field", protocol: ["bittorrent"], outboundTag: "BLOCK" }
                ]
            }
        }
    }')

    local response=$(make_api_request "POST" "http://$domain_url/api/config-profiles" "$token" "$request_body")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' > /dev/null; then
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_CONFIG_PROFILE]}: $response${COLOR_RESET}"
    fi

    local config_uuid=$(echo "$response" | jq -r '.response.uuid')
    local inbound_uuid=$(echo "$response" | jq -r '.response.inbounds[0].uuid')
    if [ -z "$config_uuid" ] || [ "$config_uuid" = "null" ] || [ -z "$inbound_uuid" ] || [ "$inbound_uuid" = "null" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_CONFIG_PROFILE]}: Invalid UUIDs in response: $response${COLOR_RESET}"
    fi

    echo "$config_uuid $inbound_uuid"
}

create_host() {
    local domain_url=$1
    local token=$2
    local inbound_uuid=$3
    local address=$4
    local config_uuid=$5
    local host_remark="${6:-Steal}"

    local request_body=$(jq -n --arg config_uuid "$config_uuid" --arg inbound_uuid "$inbound_uuid" --arg remark "$host_remark" --arg address "$address" '{
        inbound: {
            configProfileUuid: $config_uuid,
            configProfileInboundUuid: $inbound_uuid
        },
        remark: $remark,
        address: $address,
        port: 443,
        path: "",
        sni: $address,
        host: "",
        alpn: null,
        fingerprint: "chrome",
        allowInsecure: false,
        isDisabled: false,
        securityLayer: "DEFAULT"
    }')

    local response=$(make_api_request "POST" "http://$domain_url/api/hosts" "$token" "$request_body")

    if [ -z "$response" ]; then
        echo -e "${COLOR_RED}${LANG[ERROR_EMPTY_RESPONSE_HOST]}${COLOR_RESET}"
    fi

    if echo "$response" | jq -e '.response.uuid' > /dev/null; then
        echo -e "${COLOR_GREEN}${LANG[HOST_CREATED]}${COLOR_RESET}"
    else
        echo -e "${COLOR_RED}${LANG[ERROR_CREATE_HOST]}${COLOR_RESET}"
    fi
}

get_default_squad() {
    local domain_url=$1
    local token=$2

    local response=$(make_api_request "GET" "http://$domain_url/api/internal-squads" "$token")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.internalSquads' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_GET_SQUAD]}: $response${COLOR_RESET}"
        return 1
    fi

    local squad_uuids=$(echo "$response" | jq -r '.response.internalSquads[].uuid' 2>/dev/null)
    if [ -z "$squad_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_SQUADS_FOUND]}${COLOR_RESET}"
        return 0
    fi

    local valid_uuids=""
    while IFS= read -r uuid; do
        if [ -z "$uuid" ]; then
            continue
        fi
        if [[ $uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
            valid_uuids+="$uuid\n"
        else
            echo -e "${COLOR_RED}${LANG[INVALID_UUID_FORMAT]}: $uuid${COLOR_RESET}"
        fi
    done <<< "$squad_uuids"

    if [ -z "$valid_uuids" ]; then
        echo -e "${COLOR_YELLOW}${LANG[NO_VALID_SQUADS_FOUND]}${COLOR_RESET}"
        return 0
    fi

    echo -e "$valid_uuids" | sed '/^$/d'
    return 0
}

update_squad() {
    local domain_url=$1
    local token=$2
    local squad_uuid=$3
    local inbound_uuid=$4

    if [[ ! $squad_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${COLOR_RED}${LANG[INVALID_SQUAD_UUID]}: $squad_uuid${COLOR_RESET}"
        return 1
    fi

    if [[ ! $inbound_uuid =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        echo -e "${COLOR_RED}${LANG[INVALID_INBOUND_UUID]}: $inbound_uuid${COLOR_RESET}"
        return 1
    fi

    local squad_response=$(make_api_request "GET" "http://$domain_url/api/internal-squads" "$token")
    if [ -z "$squad_response" ] || ! echo "$squad_response" | jq -e '.response.internalSquads' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_GET_SQUAD]}: $squad_response${COLOR_RESET}"
        return 1
    fi

    local existing_inbounds=$(echo "$squad_response" | jq -r --arg uuid "$squad_uuid" '.response.internalSquads[] | select(.uuid == $uuid) | .inbounds[].uuid' 2>/dev/null)
    if [ -z "$existing_inbounds" ]; then
        existing_inbounds="[]"
    else
        existing_inbounds=$(echo "$existing_inbounds" | jq -R . | jq -s .)
    fi

    local inbounds_array=$(jq -n --argjson existing "$existing_inbounds" --arg new "$inbound_uuid" '$existing + [$new] | unique')

    local request_body=$(jq -n --arg uuid "$squad_uuid" --argjson inbounds "$inbounds_array" '{
        uuid: $uuid,
        inbounds: $inbounds
    }')

    local response=$(make_api_request "PATCH" "http://$domain_url/api/internal-squads" "$token" "$request_body")
    if [ -z "$response" ] || ! echo "$response" | jq -e '.response.uuid' > /dev/null 2>&1; then
        echo -e "${COLOR_RED}${LANG[ERROR_UPDATE_SQUAD]}: $response${COLOR_RESET}"
        return 1
    fi

    return 0
}

### API Functions ###

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
        echo -e ""
        echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
        echo -e ""
        reading "${LANG[CERT_METHOD_CHOOSE]}" cert_method

        if [ "$cert_method" == "0" ]; then
            echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
            exit 1
        elif [ "$cert_method" == "2" ]; then
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
            local base_domain=$(extract_domain "$domain")
            unique_domains["$base_domain"]="1"
        done

        for domain in "${!unique_domains[@]}"; do
            get_certificates "$domain" "$cert_method" ""
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
            get_certificates "$domain" "$cert_method" "$letsencrypt_email"
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
            local base_domain=$(extract_domain "$domain")
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
        cron_command="ufw allow 80 && /usr/bin/certbot renew --quiet && ufw delete allow 80 && ufw reload"
    else
        cron_command="/usr/bin/certbot renew --quiet"
    fi

    if ! crontab -u root -l 2>/dev/null | grep -q "/usr/bin/certbot renew"; then
        echo -e "${COLOR_YELLOW}${LANG[ADDING_CRON_FOR_EXISTING_CERTS]}${COLOR_RESET}"
        if [ "$min_days_left" -le 30 ]; then
            echo -e "${COLOR_YELLOW}${LANG[CERT_EXPIRY_SOON]} $min_days_left ${LANG[DAYS]}${COLOR_RESET}"
            add_cron_rule "0 5 * * * $cron_command"
        else
            add_cron_rule "0 5 1 */2 * $cron_command"
        fi
    elif [ "$min_days_left" -le 30 ] && ! crontab -u root -l 2>/dev/null | grep -q "0 5 * * *.*$cron_command"; then
        echo -e "${COLOR_YELLOW}${LANG[CERT_EXPIRY_SOON]} $min_days_left ${LANG[DAYS]}${COLOR_RESET}"
        echo -e "${COLOR_YELLOW}${LANG[UPDATING_CRON]}${COLOR_RESET}"
        crontab -u root -l 2>/dev/null | grep -v "/usr/bin/certbot renew" | crontab -u root -
        add_cron_rule "0 5 * * * $cron_command"
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

#Install Panel + Node
install_remnawave() {
    mkdir -p /opt/remnawave && cd /opt/remnawave

    reading "${LANG[ENTER_PANEL_DOMAIN]}" PANEL_DOMAIN
    check_domain "$PANEL_DOMAIN" true true
    local panel_check_result=$?
    if [ $panel_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    reading "${LANG[ENTER_SUB_DOMAIN]}" SUB_DOMAIN
    check_domain "$SUB_DOMAIN" true true
    local sub_check_result=$?
    if [ $sub_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    reading "${LANG[ENTER_NODE_DOMAIN]}" SELFSTEAL_DOMAIN
    check_domain "$SELFSTEAL_DOMAIN" true false
    local node_check_result=$?
    if [ $node_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    if [ "$PANEL_DOMAIN" = "$SUB_DOMAIN" ] || [ "$PANEL_DOMAIN" = "$SELFSTEAL_DOMAIN" ] || [ "$SUB_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[DOMAINS_MUST_BE_UNIQUE]}${COLOR_RESET}"
        exit 1
    fi

    PANEL_BASE_DOMAIN=$(extract_domain "$PANEL_DOMAIN")
    SUB_BASE_DOMAIN=$(extract_domain "$SUB_DOMAIN")
    SELFSTEAL_BASE_DOMAIN=$(extract_domain "$SELFSTEAL_DOMAIN")

    unique_domains["$PANEL_BASE_DOMAIN"]=1
    unique_domains["$SUB_BASE_DOMAIN"]=1
    unique_domains["$SELFSTEAL_BASE_DOMAIN"]=1

    SUPERADMIN_USERNAME=$(generate_user)
    SUPERADMIN_PASSWORD=$(generate_password)

    cookies_random1=$(generate_user)
    cookies_random2=$(generate_user)

    METRICS_USER=$(generate_user)
    METRICS_PASS=$(generate_user)

    JWT_AUTH_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
    JWT_API_TOKENS_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)

    cat > .env-node <<EOL
### APP ###
APP_PORT=2222

### XRAY ###
SSL_CERT="PUBLIC KEY FROM REMNAWAVE-PANEL"
EOL

    cat > .env <<EOL
### APP ###
APP_PORT=3000
METRICS_PORT=3001

### API ###
# Possible values: max (start instances on all cores), number (start instances on number of cores), -1 (start instances on all cores - 1)
# !!! Do not set this value more than physical cores count in your machine !!!
# Review documentation: https://remna.st/docs/install/environment-variables#scaling-api
API_INSTANCES=1

### DATABASE ###
# FORMAT: postgresql://{user}:{password}@{host}:{port}/{database}
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### REDIS ###
REDIS_HOST=remnawave-redis
REDIS_PORT=6379

### JWT ###
JWT_AUTH_SECRET=$JWT_AUTH_SECRET
JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET

# Set the session idle timeout in the panel to avoid daily logins.
# Value in hours: 12–168
JWT_AUTH_LIFETIME=168

### TELEGRAM NOTIFICATIONS ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
TELEGRAM_NOTIFY_USERS_CHAT_ID=change_me
TELEGRAM_NOTIFY_NODES_CHAT_ID=change_me

### Telegram Oauth (Login with Telegram)
### Docs https://remna.st/docs/features/telegram-oauth
### true/false
TELEGRAM_OAUTH_ENABLED=false
### Array of Admin Chat Ids. These ids will be allowed to login.
TELEGRAM_OAUTH_ADMIN_IDS=[123, 321]

# Optional
# Only set if you want to use topics
TELEGRAM_NOTIFY_USERS_THREAD_ID=
TELEGRAM_NOTIFY_NODES_THREAD_ID=
TELEGRAM_NOTIFY_CRM_THREAD_ID=

# Enable Github OAuth2, possible values: true, false
OAUTH2_GITHUB_ENABLED=false
# Github client ID, you can get it from Github application settings
OAUTH2_GITHUB_CLIENT_ID="REPLACE_WITH_YOUR_CLIENT_ID"
# Github client secret, you can get it from Github application settings
OAUTH2_GITHUB_CLIENT_SECRET="REPLACE_WITH_YOUR_CLIENT_SECRET"
# List of allowed emails, separated by commas
OAUTH2_GITHUB_ALLOWED_EMAILS=["admin@example.com", "user@example.com"]

# Enable PocketID OAuth2, possible values: true, false
OAUTH2_POCKETID_ENABLED=false
# PocketID Client ID, you can get it from OIDC Client settings
OAUTH2_POCKETID_CLIENT_ID="REPLACE_WITH_YOUR_CLIENT_ID"
# PocketID Client Secret, you can get it from OIDC Client settings
OAUTH2_POCKETID_CLIENT_SECRET="REPLACE_WITH_YOUR_CLIENT_SECRET"
# Plain domain where PocketID is hosted, do not place any paths here. Just plain domain.
OAUTH2_POCKETID_PLAIN_DOMAIN="pocketid.domain.com"
# List of allowed emails, separated by commas
OAUTH2_POCKETID_ALLOWED_EMAILS=["admin@example.com", "user@example.com"]

# Enable Yandex OAuth2, possible values: true, false
OAUTH2_YANDEX_ENABLED=false
# Yandex Client ID, you can get it from OIDC Client settings
OAUTH2_YANDEX_CLIENT_ID="REPLACE_WITH_YOUR_CLIENT_ID"
# Yandex Client Secret, you can get it from OIDC Client settings
OAUTH2_YANDEX_CLIENT_SECRET="REPLACE_WITH_YOUR_CLIENT_SECRET"
# List of allowed emails, separated by commas
OAUTH2_YANDEX_ALLOWED_EMAILS=["admin@example.com", "user@example.com"]

### FRONT_END ###
# Used by CORS, you can leave it as * or place your domain there
FRONT_END_DOMAIN=$PANEL_DOMAIN

### SUBSCRIPTION PUBLIC DOMAIN ###
### DOMAIN, WITHOUT HTTP/HTTPS, DO NOT ADD / AT THE END ###
### Used in "profile-web-page-url" response header and in UI/API ###
### Review documentation: https://remna.st/docs/install/environment-variables#domains
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN

### If CUSTOM_SUB_PREFIX is set in @remnawave/subscription-page, append the same path to SUB_PUBLIC_DOMAIN. Example: SUB_PUBLIC_DOMAIN=sub-page.example.com/sub ###

### SWAGGER ###
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=true

### PROMETHEUS ###
### Metrics are available at /api/metrics
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS

### WEBHOOK ###
WEBHOOK_ENABLED=false
### Only https:// is allowed
WEBHOOK_URL=https://webhook.site/1234567890
### This secret is used to sign the webhook payload, must be exact 64 characters. Only a-z, 0-9, A-Z are allowed.
WEBHOOK_SECRET_HEADER=vsmu67Kmg6R8FjIOF1WUY8LWBHie4scdEqrfsKmyf4IAf8dY3nFS0wwYHkhh6ZvQ

### HWID DEVICE DETECTION AND LIMITATION ###
# Don't enable this if you don't know what you are doing.
# Review documentation before enabling this feature.
# https://remna.st/docs/features/hwid-device-limit/
HWID_DEVICE_LIMIT_ENABLED=false
HWID_FALLBACK_DEVICE_LIMIT=5
HWID_MAX_DEVICES_ANNOUNCE="You have reached the maximum number of devices for your subscription."

### Bandwidth usage reached notifications
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
# Only in ASC order (example: [60, 80]), must be valid array of integer(min: 25, max: 95) numbers. No more than 5 values.
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]

### CLOUDFLARE ###
# USED ONLY FOR docker-compose-prod-with-cf.yml
# NOT USED BY THE APP ITSELF
CLOUDFLARE_TOKEN=ey...

### Database ###
### For Postgres Docker container ###
# NOT USED BY THE APP ITSELF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOL

    cat > docker-compose.yml <<EOL
services:
  remnawave-db:
    image: postgres:17
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file:
      - .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave:
    image: remnawave/backend:latest
    container_name: remnawave
    hostname: remnawave
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3000:3000'
    networks:
      - remnawave-network
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-redis:
    image: valkey/valkey:8.1.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data
    healthcheck:
      test: [ "CMD", "valkey-cli", "ping" ]
      interval: 3s
      timeout: 10s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    network_mode: host
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL
}

installation() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING]}${COLOR_RESET}"
    sleep 1

    declare -A unique_domains
    install_remnawave

    declare -A domains_to_check
    domains_to_check["$PANEL_DOMAIN"]=1
    domains_to_check["$SUB_DOMAIN"]=1
    domains_to_check["$SELFSTEAL_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL"

    if [ -z "$CERT_METHOD" ]; then
        local base_domain=$(extract_domain "$PANEL_DOMAIN")
        if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
            CERT_METHOD="1"
        else
            CERT_METHOD="2"
        fi
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        local base_domain=$(extract_domain "$PANEL_DOMAIN")
        PANEL_CERT_DOMAIN="$base_domain"
        SUB_CERT_DOMAIN="$base_domain"
        NODE_CERT_DOMAIN="$base_domain"
    else
        PANEL_CERT_DOMAIN="$PANEL_DOMAIN"
        SUB_CERT_DOMAIN="$SUB_DOMAIN"
        NODE_CERT_DOMAIN="$SELFSTEAL_DOMAIN"
    fi

    cat >> /opt/remnawave/docker-compose.yml <<EOL
      - /dev/shm:/dev/shm:rw
      - /var/www/html:/var/www/html:ro
    command: sh -c 'rm -f /dev/shm/nginx.sock && nginx -g "daemon off;"'
    depends_on:
      - remnawave
      - remnawave-subscription-page
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - META_TITLE=Remnawave Subscription
      - META_DESCRIPTION=page
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
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
    network_mode: host
    env_file:
      - .env-node
    volumes:
      - /dev/shm:/dev/shm:rw
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    ipam:
      config:
        - subnet: 172.30.0.0/16
    external: false

volumes:
  remnawave-db-data:
    driver: local
    external: false
    name: remnawave-db-data
  remnawave-redis-data:
    driver: local
    external: false
    name: remnawave-redis-data
EOL

    cat > /opt/remnawave/nginx.conf <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;
ssl_session_tickets off;

server {
    server_name $PANEL_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/fullchain.pem";

    add_header Set-Cookie \$set_cookie_header;

    location / {
        error_page 418 = @unauthorized;
        recursive_error_pages on;
        if (\$authorized = 0) {
            return 418;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }

    location @unauthorized {
        root /var/www/html;
        index index.html;
    }
}

server {
    server_name $SUB_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$SUB_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$SUB_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$SUB_CERT_DOMAIN/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 404;
    }
}

server {
    server_name $SELFSTEAL_DOMAIN;
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$NODE_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$NODE_CERT_DOMAIN/fullchain.pem";

    root /var/www/html;
    index index.html;
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
    ssl_reject_handshake on;
    return 444;
}
EOL

    echo -e "${COLOR_YELLOW}${LANG[STARTING_PANEL_NODE]}${COLOR_RESET}"
    sleep 1
    cd /opt/remnawave
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    remnawave_network_subnet=172.30.0.0/16
    ufw allow from "$remnawave_network_subnet" to any port 2222 proto tcp > /dev/null 2>&1

    local domain_url="127.0.0.1:3000"
    local target_dir="/opt/remnawave"

    echo -e "${COLOR_YELLOW}${LANG[REGISTERING_REMNAWAVE]}${COLOR_RESET}"
    sleep 20

    echo -e "${COLOR_YELLOW}${LANG[CHECK_CONTAINERS]}${COLOR_RESET}"
    until curl -s "http://$domain_url/api/auth/register" \
        --header 'X-Forwarded-For: 127.0.0.1' \
        --header 'X-Forwarded-Proto: https' \
        > /dev/null; do
        echo -e "${COLOR_RED}${LANG[CONTAINERS_NOT_READY]}${COLOR_RESET}"
        sleep 10
    done

    # Register Remnawave
    local token=$(register_remnawave "$domain_url" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD")
    echo -e "${COLOR_GREEN}${LANG[REGISTRATION_SUCCESS]}${COLOR_RESET}"

    # Get public key
    echo -e "${COLOR_YELLOW}${LANG[GET_PUBLIC_KEY]}${COLOR_RESET}"
    sleep 1
    local pubkey=$(get_public_key "$domain_url" "$token" "$target_dir")
    echo -e "${COLOR_GREEN}${LANG[PUBLIC_KEY_SUCCESS]}${COLOR_RESET}"

    # Generate Xray keys
    echo -e "${COLOR_YELLOW}${LANG[GENERATE_KEYS]}${COLOR_RESET}"
    sleep 1
    local keys=$(generate_xray_keys)
    local private_key=$(echo "$keys" | awk '{print $1}')
    local public_key=$(echo "$keys" | awk '{print $2}')
    printf "${COLOR_GREEN}${LANG[GENERATE_KEYS_SUCCESS]}${COLOR_RESET}\n"

    # Delete default config profile
    delete_config_profile "$domain_url" "$token"

    # Create config profile
    echo -e "${COLOR_YELLOW}${LANG[CREATING_CONFIG_PROFILE]}${COLOR_RESET}"
    read config_profile_uuid inbound_uuid <<< $(create_config_profile "$domain_url" "$token" "StealConfig" "$SELFSTEAL_DOMAIN" "$public_key" "$private_key")
    echo -e "${COLOR_GREEN}${LANG[CONFIG_PROFILE_CREATED]}${COLOR_RESET}"

    # Create node with config profile binding
    echo -e "${COLOR_YELLOW}${LANG[CREATING_NODE]}${COLOR_RESET}"
    create_node "$domain_url" "$token" "$config_profile_uuid" "$inbound_uuid"

    # Create host
    echo -e "${COLOR_YELLOW}${LANG[CREATE_HOST]}${COLOR_RESET}"
    create_host "$domain_url" "$token" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$config_profile_uuid"

    # Get UUID default squad
    echo -e "${COLOR_YELLOW}${LANG[GET_DEFAULT_SQUAD]}${COLOR_RESET}"
    local squad_uuid=$(get_default_squad "$domain_url" "$token")

    # Update squad
    update_squad "$domain_url" "$token" "$squad_uuid" "$inbound_uuid"
    echo -e "${COLOR_GREEN}${LANG[UPDATE_SQUAD]}${COLOR_RESET}"

    # Stop and start Remnawave
    echo -e "${COLOR_YELLOW}${LANG[STOPPING_REMNAWAVE]}${COLOR_RESET}"
    sleep 1
    docker compose down > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"

    echo -e "${COLOR_YELLOW}${LANG[STARTING_PANEL_NODE]}${COLOR_RESET}"
    sleep 1
    docker compose up -d > /dev/null 2>&1 &
    spinner $! "${LANG[WAITING]}"

    clear

    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${LANG[INSTALL_COMPLETE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PANEL_ACCESS]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}https://${PANEL_DOMAIN}/auth/login?${cookies_random1}=${cookies_random2}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[ADMIN_CREDS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[USERNAME]} ${COLOR_WHITE}$SUPERADMIN_USERNAME${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PASSWORD]} ${COLOR_WHITE}$SUPERADMIN_PASSWORD${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_RESET}"
    echo -e "${COLOR_GREEN}remnawave_reverse${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"

    randomhtml
}
#Install Panel + Node

#Install Panel
install_remnawave_panel() {
    mkdir -p /opt/remnawave && cd /opt/remnawave

    reading "${LANG[ENTER_PANEL_DOMAIN]}" PANEL_DOMAIN
    check_domain "$PANEL_DOMAIN" true true
    local panel_check_result=$?
    if [ $panel_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    reading "${LANG[ENTER_SUB_DOMAIN]}" SUB_DOMAIN
    check_domain "$SUB_DOMAIN" true true
    local sub_check_result=$?
    if [ $sub_check_result -eq 2 ]; then
        echo -e "${COLOR_RED}${LANG[ABORT_MESSAGE]}${COLOR_RESET}"
        exit 1
    fi

    reading "${LANG[ENTER_NODE_DOMAIN]}" SELFSTEAL_DOMAIN

    if [ "$PANEL_DOMAIN" = "$SUB_DOMAIN" ] || [ "$PANEL_DOMAIN" = "$SELFSTEAL_DOMAIN" ] || [ "$SUB_DOMAIN" = "$SELFSTEAL_DOMAIN" ]; then
        echo -e "${COLOR_RED}${LANG[DOMAINS_MUST_BE_UNIQUE]}${COLOR_RESET}"
        exit 1
    fi

    PANEL_BASE_DOMAIN=$(extract_domain "$PANEL_DOMAIN")
    SUB_BASE_DOMAIN=$(extract_domain "$SUB_DOMAIN")

    unique_domains["$PANEL_BASE_DOMAIN"]=1
    unique_domains["$SUB_BASE_DOMAIN"]=1

    SUPERADMIN_USERNAME=$(generate_user)
    SUPERADMIN_PASSWORD=$(generate_password)

    cookies_random1=$(generate_user)
    cookies_random2=$(generate_user)

    METRICS_USER=$(generate_user)
    METRICS_PASS=$(generate_user)

    JWT_AUTH_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)
    JWT_API_TOKENS_SECRET=$(openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c 64)

    cat > .env <<EOL
### APP ###
APP_PORT=3000
METRICS_PORT=3001

### API ###
# Possible values: max (start instances on all cores), number (start instances on number of cores), -1 (start instances on all cores - 1)
# !!! Do not set this value more than physical cores count in your machine !!!
# Review documentation: https://remna.st/docs/install/environment-variables#scaling-api
API_INSTANCES=1

### DATABASE ###
# FORMAT: postgresql://{user}:{password}@{host}:{port}/{database}
DATABASE_URL="postgresql://postgres:postgres@remnawave-db:5432/postgres"

### REDIS ###
REDIS_HOST=remnawave-redis
REDIS_PORT=6379

### JWT ###
JWT_AUTH_SECRET=$JWT_AUTH_SECRET
JWT_API_TOKENS_SECRET=$JWT_API_TOKENS_SECRET

# Set the session idle timeout in the panel to avoid daily logins.
# Value in hours: 12–168
JWT_AUTH_LIFETIME=168

### TELEGRAM NOTIFICATIONS ###
IS_TELEGRAM_NOTIFICATIONS_ENABLED=false
TELEGRAM_BOT_TOKEN=change_me
TELEGRAM_NOTIFY_USERS_CHAT_ID=change_me
TELEGRAM_NOTIFY_NODES_CHAT_ID=change_me

### Telegram Oauth (Login with Telegram)
### Docs https://remna.st/docs/features/telegram-oauth
### true/false
TELEGRAM_OAUTH_ENABLED=false
### Array of Admin Chat Ids. These ids will be allowed to login.
TELEGRAM_OAUTH_ADMIN_IDS=[123, 321]

# Optional
# Only set if you want to use topics
TELEGRAM_NOTIFY_USERS_THREAD_ID=
TELEGRAM_NOTIFY_NODES_THREAD_ID=
TELEGRAM_NOTIFY_CRM_THREAD_ID=

# Enable Github OAuth2, possible values: true, false
OAUTH2_GITHUB_ENABLED=false
# Github client ID, you can get it from Github application settings
OAUTH2_GITHUB_CLIENT_ID="REPLACE_WITH_YOUR_CLIENT_ID"
# Github client secret, you can get it from Github application settings
OAUTH2_GITHUB_CLIENT_SECRET="REPLACE_WITH_YOUR_CLIENT_SECRET"
# List of allowed emails, separated by commas
OAUTH2_GITHUB_ALLOWED_EMAILS=["admin@example.com", "user@example.com"]

# Enable PocketID OAuth2, possible values: true, false
OAUTH2_POCKETID_ENABLED=false
# PocketID Client ID, you can get it from OIDC Client settings
OAUTH2_POCKETID_CLIENT_ID="REPLACE_WITH_YOUR_CLIENT_ID"
# PocketID Client Secret, you can get it from OIDC Client settings
OAUTH2_POCKETID_CLIENT_SECRET="REPLACE_WITH_YOUR_CLIENT_SECRET"
# Plain domain where PocketID is hosted, do not place any paths here. Just plain domain.
OAUTH2_POCKETID_PLAIN_DOMAIN="pocketid.domain.com"
# List of allowed emails, separated by commas
OAUTH2_POCKETID_ALLOWED_EMAILS=["admin@example.com", "user@example.com"]

# Enable Yandex OAuth2, possible values: true, false
OAUTH2_YANDEX_ENABLED=false
# Yandex Client ID, you can get it from OIDC Client settings
OAUTH2_YANDEX_CLIENT_ID="REPLACE_WITH_YOUR_CLIENT_ID"
# Yandex Client Secret, you can get it from OIDC Client settings
OAUTH2_YANDEX_CLIENT_SECRET="REPLACE_WITH_YOUR_CLIENT_SECRET"
# List of allowed emails, separated by commas
OAUTH2_YANDEX_ALLOWED_EMAILS=["admin@example.com", "user@example.com"]

### FRONT_END ###
# Used by CORS, you can leave it as * or place your domain there
FRONT_END_DOMAIN=$PANEL_DOMAIN

### SUBSCRIPTION PUBLIC DOMAIN ###
### DOMAIN, WITHOUT HTTP/HTTPS, DO NOT ADD / AT THE END ###
### Used in "profile-web-page-url" response header and in UI/API ###
### Review documentation: https://remna.st/docs/install/environment-variables#domains
SUB_PUBLIC_DOMAIN=$SUB_DOMAIN

### If CUSTOM_SUB_PREFIX is set in @remnawave/subscription-page, append the same path to SUB_PUBLIC_DOMAIN. Example: SUB_PUBLIC_DOMAIN=sub-page.example.com/sub ###

### SWAGGER ###
SWAGGER_PATH=/docs
SCALAR_PATH=/scalar
IS_DOCS_ENABLED=true

### PROMETHEUS ###
### Metrics are available at /api/metrics
METRICS_USER=$METRICS_USER
METRICS_PASS=$METRICS_PASS

### WEBHOOK ###
WEBHOOK_ENABLED=false
### Only https:// is allowed
WEBHOOK_URL=https://webhook.site/1234567890
### This secret is used to sign the webhook payload, must be exact 64 characters. Only a-z, 0-9, A-Z are allowed.
WEBHOOK_SECRET_HEADER=vsmu67Kmg6R8FjIOF1WUY8LWBHie4scdEqrfsKmyf4IAf8dY3nFS0wwYHkhh6ZvQ

### HWID DEVICE DETECTION AND LIMITATION ###
# Don't enable this if you don't know what you are doing.
# Review documentation before enabling this feature.
# https://remna.st/docs/features/hwid-device-limit/
HWID_DEVICE_LIMIT_ENABLED=false
HWID_FALLBACK_DEVICE_LIMIT=5
HWID_MAX_DEVICES_ANNOUNCE="You have reached the maximum number of devices for your subscription."

### Bandwidth usage reached notifications
BANDWIDTH_USAGE_NOTIFICATIONS_ENABLED=false
# Only in ASC order (example: [60, 80]), must be valid array of integer(min: 25, max: 95) numbers. No more than 5 values.
BANDWIDTH_USAGE_NOTIFICATIONS_THRESHOLD=[60, 80]

### CLOUDFLARE ###
# USED ONLY FOR docker-compose-prod-with-cf.yml
# NOT USED BY THE APP ITSELF
CLOUDFLARE_TOKEN=ey...

### Database ###
### For Postgres Docker container ###
# NOT USED BY THE APP ITSELF
POSTGRES_USER=postgres
POSTGRES_PASSWORD=postgres
POSTGRES_DB=postgres
EOL

    cat > docker-compose.yml <<EOL
services:
  remnawave-db:
    image: postgres:17
    container_name: 'remnawave-db'
    hostname: remnawave-db
    restart: always
    env_file:
      - .env
    environment:
      - POSTGRES_USER=\${POSTGRES_USER}
      - POSTGRES_PASSWORD=\${POSTGRES_PASSWORD}
      - POSTGRES_DB=\${POSTGRES_DB}
      - TZ=UTC
    ports:
      - '127.0.0.1:6767:5432'
    volumes:
      - remnawave-db-data:/var/lib/postgresql/data
    networks:
      - remnawave-network
    healthcheck:
      test: ['CMD-SHELL', 'pg_isready -U \$\${POSTGRES_USER} -d \$\${POSTGRES_DB}']
      interval: 3s
      timeout: 10s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave:
    image: remnawave/backend:latest
    container_name: remnawave
    hostname: remnawave
    restart: always
    env_file:
      - .env
    ports:
      - '127.0.0.1:3000:3000'
    networks:
      - remnawave-network
    depends_on:
      remnawave-db:
        condition: service_healthy
      remnawave-redis:
        condition: service_healthy
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-redis:
    image: valkey/valkey:8.1.3-alpine
    container_name: remnawave-redis
    hostname: remnawave-redis
    restart: always
    networks:
      - remnawave-network
    volumes:
      - remnawave-redis-data:/data
    healthcheck:
      test: [ "CMD", "valkey-cli", "ping" ]
      interval: 3s
      timeout: 10s
      retries: 3
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
    volumes:
      - ./nginx.conf:/etc/nginx/conf.d/default.conf:ro
EOL
}

installation_panel() {
    echo -e "${COLOR_YELLOW}${LANG[INSTALLING_PANEL]}${COLOR_RESET}"
    sleep 1

    declare -A unique_domains
    install_remnawave_panel

    declare -A domains_to_check
    domains_to_check["$PANEL_DOMAIN"]=1
    domains_to_check["$SUB_DOMAIN"]=1

    handle_certificates domains_to_check "$CERT_METHOD" "$LETSENCRYPT_EMAIL"
    
    if [ -z "$CERT_METHOD" ]; then
        local base_domain=$(extract_domain "$PANEL_DOMAIN")
        if [ -d "/etc/letsencrypt/live/$base_domain" ] && is_wildcard_cert "$base_domain"; then
            CERT_METHOD="1"
        else
            CERT_METHOD="2"
        fi
    fi

    if [ "$CERT_METHOD" == "1" ]; then
        local base_domain=$(extract_domain "$PANEL_DOMAIN")
        PANEL_CERT_DOMAIN="$base_domain"
        SUB_CERT_DOMAIN="$base_domain"
    else
        PANEL_CERT_DOMAIN="$PANEL_DOMAIN"
        SUB_CERT_DOMAIN="$SUB_DOMAIN"
    fi

    cat >> /opt/remnawave/docker-compose.yml <<EOL
    network_mode: host
    depends_on:
      - remnawave
      - remnawave-subscription-page
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

  remnawave-subscription-page:
    image: remnawave/subscription-page:latest
    container_name: remnawave-subscription-page
    hostname: remnawave-subscription-page
    restart: always
    environment:
      - REMNAWAVE_PANEL_URL=http://remnawave:3000
      - APP_PORT=3010
      - META_TITLE=Remnawave Subscription
      - META_DESCRIPTION=page
    ports:
      - '127.0.0.1:3010:3010'
    networks:
      - remnawave-network
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'

networks:
  remnawave-network:
    name: remnawave-network
    driver: bridge
    external: false

volumes:
  remnawave-db-data:
    driver: local
    external: false
    name: remnawave-db-data
  remnawave-redis-data:
    driver: local
    external: false
    name: remnawave-redis-data
EOL

    cat > /opt/remnawave/nginx.conf <<EOL
upstream remnawave {
    server 127.0.0.1:3000;
}

upstream json {
    server 127.0.0.1:3010;
}

map \$http_upgrade \$connection_upgrade {
    default upgrade;
    ""      close;
}

map \$http_cookie \$auth_cookie {
    default 0;
    "~*${cookies_random1}=${cookies_random2}" 1;
}

map \$arg_${cookies_random1} \$auth_query {
    default 0;
    "${cookies_random2}" 1;
}

map "\$auth_cookie\$auth_query" \$authorized {
    "~1" 1;
    default 0;
}

map \$arg_${cookies_random1} \$set_cookie_header {
    "${cookies_random2}" "${cookies_random1}=${cookies_random2}; Path=/; HttpOnly; Secure; SameSite=Strict; Max-Age=31536000";
    default "";
}

ssl_protocols TLSv1.2 TLSv1.3;
ssl_ecdh_curve X25519:prime256v1:secp384r1;
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:DHE-RSA-CHACHA20-POLY1305;
ssl_prefer_server_ciphers on;
ssl_session_timeout 1d;
ssl_session_cache shared:MozSSL:10m;

server {
    server_name $PANEL_DOMAIN;
    listen 443 ssl;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$PANEL_CERT_DOMAIN/fullchain.pem";

    add_header Set-Cookie \$set_cookie_header;

    location / {
        if (\$authorized = 0) {
            return 444;
        }
        proxy_http_version 1.1;
        proxy_pass http://remnawave;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}

server {
    server_name $SUB_DOMAIN;
    listen 443 ssl;
    http2 on;

    ssl_certificate "/etc/nginx/ssl/$SUB_CERT_DOMAIN/fullchain.pem";
    ssl_certificate_key "/etc/nginx/ssl/$SUB_CERT_DOMAIN/privkey.pem";
    ssl_trusted_certificate "/etc/nginx/ssl/$SUB_CERT_DOMAIN/fullchain.pem";

    location / {
        proxy_http_version 1.1;
        proxy_pass http://json;
        proxy_set_header Host \$host;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$connection_upgrade;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_set_header X-Forwarded-Port \$server_port;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
        proxy_intercept_errors on;
        error_page 400 404 500 502 @redirect;
    }

    location @redirect {
        return 404;
    }
}

server {
    listen 443 ssl default_server;
    server_name _;
    ssl_reject_handshake on;
}
EOL

    echo -e "${COLOR_YELLOW}${LANG[STARTING_PANEL]}${COLOR_RESET}"
    sleep 1
    cd /opt/remnawave
    docker compose up -d > /dev/null 2>&1 &

    spinner $! "${LANG[WAITING]}"

    echo -e "${COLOR_YELLOW}${LANG[REGISTERING_REMNAWAVE]}${COLOR_RESET}"
    sleep 20

    local domain_url="127.0.0.1:3000"
    echo -e "${COLOR_YELLOW}${LANG[CHECK_CONTAINERS]}${COLOR_RESET}"
    until curl -s "http://$domain_url/api/auth/register" \
        --header 'X-Forwarded-For: 127.0.0.1' \
        --header 'X-Forwarded-Proto: https' \
        > /dev/null; do
        echo -e "${COLOR_RED}${LANG[CONTAINERS_NOT_READY]}${COLOR_RESET}"
        sleep 5
    done

    # Register Remnawave
    local token=$(register_remnawave "$domain_url" "$SUPERADMIN_USERNAME" "$SUPERADMIN_PASSWORD")
    echo -e "${COLOR_GREEN}${LANG[REGISTRATION_SUCCESS]}${COLOR_RESET}"

    # Generate Xray keys
    echo -e "${COLOR_YELLOW}${LANG[GENERATE_KEYS]}${COLOR_RESET}"
    sleep 1
    local keys=$(generate_xray_keys)
    local private_key=$(echo "$keys" | awk '{print $1}')
    local public_key=$(echo "$keys" | awk '{print $2}')
    printf "${COLOR_GREEN}${LANG[GENERATE_KEYS_SUCCESS]}${COLOR_RESET}\n"

    # Delete default config profile
    delete_config_profile "$domain_url" "$token"

    # Create config profile
    echo -e "${COLOR_YELLOW}${LANG[CREATING_CONFIG_PROFILE]}${COLOR_RESET}"
    read config_profile_uuid inbound_uuid <<< $(create_config_profile "$domain_url" "$token" "StealConfig" "$SELFSTEAL_DOMAIN" "$public_key" "$private_key")
    echo -e "${COLOR_GREEN}${LANG[CONFIG_PROFILE_CREATED]}${COLOR_RESET}"

    # Create node with config profile binding
    echo -e "${COLOR_YELLOW}${LANG[CREATING_NODE]}${COLOR_RESET}"
    create_node "$domain_url" "$token" "$config_profile_uuid" "$inbound_uuid" "$SELFSTEAL_DOMAIN"

    # Create host
    echo -e "${COLOR_YELLOW}${LANG[CREATE_HOST]}${COLOR_RESET}"
    create_host "$domain_url" "$token" "$inbound_uuid" "$SELFSTEAL_DOMAIN" "$config_profile_uuid"

    # Get UUID default squad
    echo -e "${COLOR_YELLOW}${LANG[GET_DEFAULT_SQUAD]}${COLOR_RESET}"
    local squad_uuid=$(get_default_squad "$domain_url" "$token")

    # Update squad
    update_squad "$domain_url" "$token" "$squad_uuid" "$inbound_uuid"
    echo -e "${COLOR_GREEN}${LANG[UPDATE_SQUAD]}${COLOR_RESET}"

    clear

    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_GREEN}${LANG[INSTALL_COMPLETE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PANEL_ACCESS]}${COLOR_RESET}"
    echo -e "${COLOR_WHITE}https://${PANEL_DOMAIN}/auth/login?${cookies_random1}=${cookies_random2}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[ADMIN_CREDS]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[USERNAME]} ${COLOR_WHITE}$SUPERADMIN_USERNAME${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[PASSWORD]} ${COLOR_WHITE}$SUPERADMIN_PASSWORD${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}-------------------------------------------------${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}${LANG[RELAUNCH_CMD]}${COLOR_RESET}"
    echo -e "${COLOR_GREEN}remnawave_reverse${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}=================================================${COLOR_RESET}"
    echo -e "${COLOR_RED}${LANG[POST_PANEL_INSTRUCTION]}${COLOR_RESET}"
}
#Install Panel

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

cat > .env-node <<EOL
### APP ###
APP_PORT=2222

### XRAY ###
$(echo -e "$CERTIFICATE" | sed 's/\\n$//')
EOL

SELFSTEAL_BASE_DOMAIN=$(extract_domain "$SELFSTEAL_DOMAIN")

unique_domains["$SELFSTEAL_BASE_DOMAIN"]=1

cat > docker-compose.yml <<EOL
services:
  remnawave-nginx:
    image: nginx:1.28
    container_name: remnawave-nginx
    hostname: remnawave-nginx
    restart: always
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
    command: sh -c 'rm -f /dev/shm/nginx.sock && nginx -g "daemon off;"'
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
    network_mode: host
    env_file:
      - path: /opt/remnawave/.env-node
        required: false
    volumes:
      - /dev/shm:/dev/shm:rw
    logging:
      driver: 'json-file'
      options:
        max-size: '30m'
        max-file: '5'
EOL

cat > /opt/remnawave/nginx.conf <<EOL
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
}

server {
    listen unix:/dev/shm/nginx.sock ssl proxy_protocol default_server;
    server_name _;
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

    reading "${LANG[ENTER_NODE_DOMAIN]}" SELFSTEAL_DOMAIN
    
        while true; do
        reading "${LANG[ENTER_NODE_NAME]}" entity_name
        if [[ "$entity_name" =~ ^[a-zA-Z0-9-]+$ ]]; then
            if [ ${#entity_name} -ge 5 ] && [ ${#entity_name} -le 20 ]; then
                get_panel_token
                token=$(cat "$TOKEN_FILE")
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
    local keys=$(generate_xray_keys)
    local private_key=$(echo "$keys" | awk '{print $1}')
    local public_key=$(echo "$keys" | awk '{print $2}')
    printf "${COLOR_GREEN}${LANG[GENERATE_KEYS_SUCCESS]}${COLOR_RESET}\n"

    echo -e "${COLOR_YELLOW}${LANG[CREATING_CONFIG_PROFILE]}${COLOR_RESET}"
    read config_profile_uuid inbound_uuid <<< $(create_config_profile "$domain_url" "$token" "$entity_name" "$SELFSTEAL_DOMAIN" "$public_key" "$private_key" "$entity_name")
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
        manage_warp
        log_clear
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
