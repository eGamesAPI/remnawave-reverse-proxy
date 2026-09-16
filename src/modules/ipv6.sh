#!/bin/bash
# Module: IPv6 Management

# One-line status for the menu header: kernel flag, interface flag,
# global address if there is one
show_ipv6_status() {
    local iface global_addr
    iface=$(ipv6_default_iface)

    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" -eq 1 ]; then
        echo -e ""
        echo -e "${COLOR_RED}${LANG[IPV6_STATUS_OFF]}${COLOR_RESET}"
        return
    fi

    if [ -n "$iface" ] && [ "$(sysctl -n "net.ipv6.conf.$iface.disable_ipv6" 2>/dev/null)" -eq 1 ]; then
        echo -e "${COLOR_RED}$(printf "${LANG[IPV6_STATUS_IFACE_OFF]}" "$iface")${COLOR_RESET}"
        return
    fi

    global_addr=$(ip -6 addr show dev "${iface:-eth0}" scope global 2>/dev/null | grep -o 'inet6 [0-9a-f:/]*' | awk '{print $2}' | head -n 1)
    if [ -n "$global_addr" ]; then
        echo -e ""
        echo -e "${COLOR_GREEN}${LANG[IPV6_STATUS_ON]} ($global_addr)${COLOR_RESET}"
    else
        echo -e "${COLOR_YELLOW}${LANG[IPV6_STATUS_ON_NOADDR]}${COLOR_RESET}"
    fi
}

show_ipv6_menu() {
    echo -e ""
    echo -e "${COLOR_GREEN}${LANG[IPV6_MENU_TITLE]}${COLOR_RESET}"
    show_ipv6_status
    echo -e ""
    echo -e "${COLOR_YELLOW}1. ${LANG[IPV6_ENABLE]}${COLOR_RESET}"
    echo -e "${COLOR_YELLOW}2. ${LANG[IPV6_DISABLE]}${COLOR_RESET}"
    echo -e ""
    echo -e "${COLOR_YELLOW}0. ${LANG[EXIT]}${COLOR_RESET}"
    echo -e ""
}

manage_ipv6() {
    while true; do
        show_ipv6_menu
        reading "${LANG[IPV6_PROMPT]}" IPV6_OPTION || return 0
        case $IPV6_OPTION in
            1)
                enable_ipv6
                sleep 2
                ;;
            2)
                disable_ipv6
                sleep 2
                ;;
            0)
                echo -e "${COLOR_YELLOW}${LANG[EXIT]}${COLOR_RESET}"
                remnawave_reverse
                return
                ;;
            *)
                echo -e "${COLOR_YELLOW}${LANG[IPV6_INVALID_CHOICE]}${COLOR_RESET}"
                sleep 2
                ;;
        esac
    done
}

# The interface the default route goes through — on docker hosts the first
# non-loopback link may well be docker0 or a veth
ipv6_default_iface() {
    local iface
    iface=$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')
    if [ -z "$iface" ] || [ "$iface" = "lo" ]; then
        iface=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v -E '^(lo|.*@)' | head -n 1)
    fi
    [ -n "$iface" ] && echo "$iface"
}

# 0 when IPv6 is fully enabled for both all and the uplink interface:
# a per-interface disable_ipv6=1 keeps the interface dead even at all=0
ipv6_is_enabled() {
    local iface="$1"
    [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" -eq 0 ] || return 1
    [ -z "$iface" ] && return 0
    [ "$(sysctl -n "net.ipv6.conf.$iface.disable_ipv6" 2>/dev/null)" -eq 0 ]
}

set_ipv6_sysctl() {
    local value="$1" iface="$2"

    sed -i '/net\.ipv6\.conf\.all\.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net\.ipv6\.conf\.default\.disable_ipv6/d' /etc/sysctl.conf
    sed -i '/net\.ipv6\.conf\.lo\.disable_ipv6/d' /etc/sysctl.conf
    [ -n "$iface" ] && sed -i "\|net\.ipv6\.conf\.$iface\.disable_ipv6|d" /etc/sysctl.conf

    echo "net.ipv6.conf.all.disable_ipv6 = $value" >> /etc/sysctl.conf
    echo "net.ipv6.conf.default.disable_ipv6 = $value" >> /etc/sysctl.conf
    echo "net.ipv6.conf.lo.disable_ipv6 = $value" >> /etc/sysctl.conf
    [ -n "$iface" ] && echo "net.ipv6.conf.$iface.disable_ipv6 = $value" >> /etc/sysctl.conf

    sysctl -p > /dev/null 2>&1
}

enable_ipv6() {
    local interface_name
    interface_name=$(ipv6_default_iface)

    if ipv6_is_enabled "$interface_name"; then
        echo -e "${COLOR_YELLOW}${LANG[IPV6_ALREADY_ENABLED]}${COLOR_RESET}"
        return 0
    fi

    set_ipv6_sysctl 0 "$interface_name"

    # sysctl silently fails when IPv6 is disabled at the bootloader
    # (ipv6.disable=1 in GRUB) — verify instead of declaring success
    if ! ipv6_is_enabled "$interface_name"; then
        echo -e "${COLOR_RED}${LANG[IPV6_VERIFY_FAILED]}${COLOR_RESET}"
        return 1
    fi

    echo -e "${COLOR_GREEN}${LANG[IPV6_ENABLED]}${COLOR_RESET}"

    # The interface comes up without an address until networking is
    # refreshed; there is no need to bother when a global address exists
    if [ -n "$interface_name" ] \
        && ! ip -6 addr show dev "$interface_name" scope global 2>/dev/null | grep -q inet6; then
        local refresh
        echo -e "${COLOR_YELLOW}${LANG[IPV6_REFRESH_ASK]}${COLOR_RESET}"
        read_yn refresh || {
            echo -e "${COLOR_YELLOW}${LANG[IPV6_REFRESH_SKIP]}${COLOR_RESET}"
            return 0
        }
        if [ -d /etc/netplan ]; then
            netplan apply 2>/dev/null
        elif [ -f /etc/network/interfaces ] || [ -d /etc/network/interfaces.d ]; then
            ifdown "$interface_name" 2>/dev/null; ifup "$interface_name" 2>/dev/null
        else
            systemctl restart systemd-networkd 2>/dev/null
        fi
        if ip -6 addr show dev "$interface_name" scope global 2>/dev/null | grep -q inet6; then
            echo -e "${COLOR_GREEN}${LANG[IPV6_REFRESH_DONE]}${COLOR_RESET}"
            # Right after ifup the address sits in "tentative" (duplicate
            # address detection) — re-read it once DAD has settled
            sleep 2
            ip -6 addr show dev "$interface_name" scope global | grep inet6
        else
            # Point at the config file the distro actually uses
            if [ -d /etc/netplan ]; then
                echo -e "${COLOR_YELLOW}$(printf "${LANG[IPV6_NOADDR_NETPLAN]}" "$interface_name")${COLOR_RESET}"
            else
                echo -e "${COLOR_YELLOW}$(printf "${LANG[IPV6_NOADDR_INTERFACES]}" "$interface_name")${COLOR_RESET}"
            fi
            echo -e "${COLOR_YELLOW}${LANG[IPV6_REFRESH_NOADDR]}${COLOR_RESET}"
            # Give the user time to check the address before the menu redraws
            local pause_ack
            reading "${LANG[IPV6_CHECK_PAUSE]}" pause_ack
        fi
    fi
}

disable_ipv6() {
    if [ "$(sysctl -n net.ipv6.conf.all.disable_ipv6)" -eq 1 ]; then
        echo -e "${COLOR_YELLOW}${LANG[IPV6_ALREADY_DISABLED]}${COLOR_RESET}"
        return 0
    fi

    local interface_name
    interface_name=$(ipv6_default_iface)

    set_ipv6_sysctl 1 "$interface_name"
    echo -e "${COLOR_GREEN}${LANG[IPV6_DISABLED]}${COLOR_RESET}"
}
