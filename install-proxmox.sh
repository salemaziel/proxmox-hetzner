#!/bin/bash

# Color codes (can be disabled with --no-color)
CLR_RED='\033[0;31m'
CLR_GREEN='\033[0;32m'
CLR_YELLOW='\033[1;33m'
CLR_BLUE='\033[0;34m'
CLR_CYAN='\033[0;36m'
CLR_RESET='\033[0m'

# Default variables
skip_installer=false
no_shutdown=false
verbose=false
specified_iface_name=""
use_ovh=false
rescue=false
yes_to_all=false
zabbix_server_address=""
zabbix_agent_version=""
zabbix_hostname=""
ssh_port=""
ssh_key=""
acme_email=""
private_subnet=""
no_color=false
proxmox_version="latest"
automated_install=false
# Automated install parameters
pve_fqdn=""
pve_email=""
pve_timezone="Europe/Warsaw"
pve_root_password=""
pve_keyboard="en-us"
pve_country="us"
pve_filesystem="ext4"
pve_zfs_raid="raid1"
pve_disk_list=""
# ZFS Encryption parameters
zfs_encryption=false
zfs_encryption_password=""
zfs_encryption_ssh_port="2222"

# Function to show help message
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "General options:"
    echo "  --skip-installer              Skip Proxmox installer and boot directly from installed disks"
    echo "  --no-shutdown                 Do not shut down the virtual machine after finishing work"
    echo "  --rescue                      Start QEMU in rescue mode with VNC and attached disks"
    echo "  --disable PLUGIN1,PLUGIN2     Disable specified plugins"
    echo "  --list-ifaces                 List network interfaces and exit"
    echo "  --iface-name NAME             Specify the network interface name directly"
    echo "  --verbose                     Enable extra log output"
    echo "  --no-color                    Disable colored output"
    echo "  --yes                         Skip all confirmation prompts (auto-accept)"
    echo "  --proxmox-version VERSION     Specify Proxmox version (default: latest)"
    echo "                                Examples: latest, 8, 8.2, 8.2-1"
    echo "  --enable-zfs-encryption       Enable Native ZFS Encryption (requires ZFS filesystem)"
    echo "  --zfs-encryption-password PWD Password for ZFS root key (required if encryption enabled)"
    echo "  --zfs-encryption-ssh-port PORT Port for Dropbear SSH during boot unlock (default: 2222)"
    echo "  --automated-install           [EXPERIMENTAL] Use automated unattended installation"
    echo "                                Only works with Proxmox 9+, skips VNC manual setup"
    echo ""
    echo "Automated install options (required with --automated-install):"
    echo "  --pve-fqdn FQDN               Fully qualified domain name (e.g., pve.example.com)"
    echo "  --pve-email EMAIL             Admin email address"
    echo "  --pve-root-password PASSWORD  Root password for Proxmox"
    echo "  --pve-timezone TIMEZONE       Timezone (default: Europe/Warsaw)"
    echo "  --pve-keyboard LAYOUT         Keyboard layout (default: en-us)"
    echo "  --pve-country CODE            Country code (default: us)"
    echo "  --pve-filesystem TYPE         Filesystem type: ext4, xfs, zfs, btrfs (default: ext4)"
    echo "  --pve-zfs-raid LEVEL          ZFS RAID level: raid0, raid1, raid10, raidz-1, raidz-2, raidz-3"
    echo "                                (default: raid1, only used with --pve-filesystem zfs)"
    echo "  --pve-disk-list DISKS         Comma-separated list of physical disks (e.g., sda,sdb)"
    echo "                                Leave empty for auto-detection (default: auto)"
    echo ""
    echo "  -h, --help                    Show this help message and exit"
    echo ""
    echo "Optional plugins (additional options required):"

    # Output only optional plugins with indentation
    for plugin in $(echo "$plugin_list" | tr ',' '\n'); do
        if [[ "$(describe_plugin "$plugin")" == *"[Optional]"* ]]; then
            echo "  $plugin:"
            describe_plugin "$plugin" true | sed 's/^/    /' | tail -n +2
        fi
    done

    echo ""
    echo "Default plugins:"
    for plugin in $(echo "$plugin_list" | tr ',' '\n'); do
        if [[ "$(describe_plugin "$plugin")" == *"[Default]"* ]]; then
            echo "  $plugin:"
            describe_plugin "$plugin" true | sed 's/^/    /' | tail -n +2
        fi
    done

    echo ""
    echo "Examples:"
    echo "  # Standard manual installation (VNC):"
    echo "  $0"
    echo ""
    echo "  # Automated installation (Proxmox 9+ only, no VNC needed):"
    echo "  $0 --automated-install --proxmox-version 9 \\"
    echo "     --pve-fqdn pve.example.com \\"
    echo "     --pve-email admin@example.com \\"
    echo "     --pve-root-password SecurePass123"
    echo ""
    echo "  # Automated installation with ZFS RAID1 on two disks:"
    echo "  $0 --automated-install --proxmox-version 9 \\"
    echo "     --pve-fqdn pve.example.com --pve-email admin@example.com \\"
    echo "     --pve-root-password SecurePass123 --pve-filesystem zfs \\"
    echo "     --pve-zfs-raid raid1 --pve-disk-list sda,sdb"
    echo ""
    echo "  # Install specific version with custom network interface:"
    echo "  $0 --proxmox-version 8.2-1 --iface-name enp0s31f6"
}

describe_plugin() {
    case $1 in
        "run_tteck_post-pve-install")
            echo "[Default]"
            echo "Run additional post-installation tasks from https://github.com/community-scripts/ProxmoxVE"
            ;;
        "set_network")
            echo "[Default]"
            echo "Configure network settings based on Hetzner rescue network"
            ;;
        "update_locale_gen")
            echo "[Default]"
            echo "Update locale settings with your ssh_client LC_NAME: ${LC_NAME}"
            ;;
        "register_acme_account")
            echo "[Optional]"
            echo "Registers an ACME account for Let's Encrypt SSL certificate."
            echo "Required options:"
            echo "    --acme-email EMAIL     Set email for ACME account"
            ;;
        "disable_rpcbind")
            echo "[Default]"
            echo "Disable rpcbind service"
            ;;
        "snat_zone")
            echo "[Default]"
            echo "Install dnsmasq to run SNAT zone"
            ;;
        "install_iptables_rule")
            echo "[Default]"
            echo "Install custom iptables rule"
            ;;
        "add_ssh_key_to_authorized_keys")
            echo "[Optional]"
            echo "Adds SSH public key to authorized_keys."
            echo "Required options:"
            echo "    --ssh-key SSH_KEY     Add SSH public key to authorized_keys (must be a path to .pub file)"
            ;;
        "change_ssh_port")
            echo "[Optional]"
            echo "Changes the default SSH port for Proxmox server."
            echo "Required options:"
            echo "    --port PORT           Set the new SSH port"
            ;;
        "add_tun_lxc_device")
            echo "[Default]"
            echo "Add default configuration to LXC containers to create a tun interface"
            ;;
        "zabbix_agent")
            echo "[Optional]"
            echo "Installs and configures Zabbix Agent."
            echo "Required options:"
            echo "    --zabbix-server ADDRESS          Set Zabbix Server address"
            echo "Optional parameters:"
            echo "    --zabbix-agent-version VERSION   Specify Zabbix Agent version"
            echo "    --zabbix-hostname HOSTNAME       Set hostname for Zabbix Agent"
            ;;
        "setup_private_subnet")
            echo "[Optional]"
            echo "Configures private subnet bridge (vmbr1) with NAT for LXC/VM containers."
            echo "Required options:"
            echo "    --private-subnet CIDR            Set private subnet (e.g., 192.168.20.0/24)"
            ;;
        "enable_zfs_encryption")
            echo "[Optional]"
            echo "Enables native ZFS encryption and Dropbear SSH for remote unlocking."
            echo "Required options:"
            echo "    --enable-zfs-encryption         Enable this feature"
            echo "    --zfs-encryption-password PWD   Set root encryption password"
            echo "    --pve-filesystem zfs            Must use ZFS filesystem"
            ;;
        *)
            echo "No description available"
            echo
            ;;
    esac
}


# Function to run the specified plugin
run_plugin() {
    case $1 in
        "run_tteck_post-pve-install")
            run_tteck_post-pve-install
            ;;
        "set_network")
            set_network
            ;;
        "update_locale_gen")
            update_locale_gen
            ;;
        "register_acme_account")
            register_acme_account
            ;;
        "disable_rpcbind")
            disable_rpcbind
            ;;
        "install_iptables_rule")
            install_iptables_rule
            ;;
        "snat_zone")
            snat_zone
            ;;
        "add_ssh_key_to_authorized_keys")
            add_ssh_key_to_authorized_keys
            ;;
        "change_ssh_port")
            change_ssh_port
            ;;
        "add_tun_lxc_device")
            add_tun_lxc_device
            ;;
        "zabbix_agent")
            install_zabbix_agent
            ;;
        "setup_private_subnet")
            setup_private_subnet
            ;;
        "enable_zfs_encryption")
            enable_zfs_encryption
            ;;
        *)
            echo "Unknown plugin: $1"
            ;;
    esac
}

# Default list of plugins
plugin_list="update_locale_gen,set_network,enable_zfs_encryption,run_tteck_post-pve-install,register_acme_account,disable_rpcbind,install_iptables_rule,snat_zone,add_ssh_key_to_authorized_keys,change_ssh_port,add_tun_lxc_device,zabbix_agent,setup_private_subnet"

# Parsing command line options
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --skip-installer)
            skip_installer=true
            shift
            ;;
        --no-shutdown)
            no_shutdown=true
            shift
            ;;
        --disable)
            disabled_plugins="$2"
            IFS=',' read -ra plugins_to_disable <<< "$disabled_plugins"
            for plugin in "${plugins_to_disable[@]}"; do
                plugin_list="${plugin_list//$plugin/}"
            done
            shift
            shift
            ;;
        --list-ifaces)
            print_interface_names
            exit 0
            ;;
        --iface-name)
            specified_iface_name="$2"
            shift
            shift
            ;;
        --verbose)
            verbose=true
            shift
            ;;
        --no-color)
            no_color=true
            shift
            ;;
        --yes)
            yes_to_all=true
            shift
            ;;
        --rescue)
            rescue=true
            shift
            ;;
        --private-subnet)
            private_subnet="$2"
            shift
            shift
            ;;
        --zabbix-server)
            zabbix_server_address="$2"
            shift
            shift
            ;;
        --zabbix-agent-version)
            zabbix_agent_version="$2"
            shift
            shift
            ;;
        --zabbix-hostname)
            zabbix_hostname="$2"
            shift
            shift
            ;;
        -P|--port)
            ssh_port="$2"
            shift
            shift
            ;;
        -k|--ssh-key)
            ssh_key="$2"
            shift
            shift
            ;;
        -e|--acme-email)
            acme_email="$2"
            shift
            shift
            ;;
        --proxmox-version)
            proxmox_version="$2"
            shift
            shift
            ;;
        --automated-install)
            automated_install=true
            shift
            ;;
        --pve-fqdn)
            pve_fqdn="$2"
            shift
            shift
            ;;
        --pve-email)
            pve_email="$2"
            shift
            shift
            ;;
        --pve-root-password)
            pve_root_password="$2"
            shift
            shift
            ;;
        --pve-timezone)
            pve_timezone="$2"
            shift
            shift
            ;;
        --pve-keyboard)
            pve_keyboard="$2"
            shift
            shift
            ;;
        --pve-country)
            pve_country="$2"
            shift
            shift
            ;;
        --pve-filesystem)
            pve_filesystem="$2"
            shift
            shift
            ;;
        --pve-zfs-raid)
            pve_zfs_raid="$2"
            shift
            shift
            ;;
        --pve-disk-list)
            pve_disk_list="$2"
            shift
            shift
            ;;
        --enable-zfs-encryption)
            zfs_encryption=true
            shift
            ;;
        --zfs-encryption-password)
            zfs_encryption_password="$2"
            shift
            shift
            ;;
        --zfs-encryption-ssh-port)
            zfs_encryption_ssh_port="$2"
            shift
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# Disable colors if requested or if not in terminal
if [ "$no_color" = true ] || [ ! -t 1 ]; then
    CLR_RED=''
    CLR_GREEN=''
    CLR_YELLOW=''
    CLR_BLUE=''
    CLR_CYAN=''
    CLR_RESET=''
fi

# Validate automated install requirements
if [ "$automated_install" = true ]; then
    echo -e "${CLR_YELLOW}⚠ WARNING: Automated install is EXPERIMENTAL${CLR_RESET}"
    echo -e "${CLR_YELLOW}This feature uses Proxmox auto-install-assistant (Proxmox 9+ only)${CLR_RESET}"

    # Check if version is Proxmox 9+
    if [[ "$proxmox_version" =~ ^[0-9]+$ ]]; then
        if [ "$proxmox_version" -lt 9 ]; then
            echo -e "${CLR_RED}✗ Error: --automated-install requires Proxmox 9 or higher${CLR_RESET}"
            echo "Current version selection: $proxmox_version"
            echo "Use --proxmox-version 9 or --proxmox-version latest"
            exit 1
        fi
    elif [[ "$proxmox_version" =~ ^[0-9]+\.[0-9]+ ]]; then
        major_ver=$(echo "$proxmox_version" | cut -d'.' -f1)
        if [ "$major_ver" -lt 9 ]; then
            echo -e "${CLR_RED}✗ Error: --automated-install requires Proxmox 9 or higher${CLR_RESET}"
            echo "Current version selection: $proxmox_version"
            exit 1
        fi
    fi
    echo -e "${CLR_GREEN}✓ Proxmox version check passed${CLR_RESET}"

    # Validate required parameters
    missing_params=()
    [ -z "$pve_fqdn" ] && missing_params+=("--pve-fqdn")
    [ -z "$pve_email" ] && missing_params+=("--pve-email")
    [ -z "$pve_root_password" ] && missing_params+=("--pve-root-password")

    if [ ${#missing_params[@]} -gt 0 ]; then
        echo -e "${CLR_RED}✗ Error: --automated-install requires the following parameters:${CLR_RESET}"
        for param in "${missing_params[@]}"; do
            echo "  $param"
        done
        exit 1
    fi

    # Validate email format
    if ! echo "$pve_email" | grep -qE '^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$'; then
        echo -e "${CLR_RED}✗ Error: Invalid email format: $pve_email${CLR_RESET}"
        exit 1
    fi

    # Validate FQDN format (at least one dot)
    if ! echo "$pve_fqdn" | grep -q '\.'; then
        echo -e "${CLR_RED}✗ Error: FQDN must contain at least one dot (e.g., pve.example.com)${CLR_RESET}"
        exit 1
    fi

    # Validate filesystem type
    case "$pve_filesystem" in
        ext4|xfs|zfs|btrfs)
            # Valid filesystem
            ;;
        *)
            echo -e "${CLR_RED}✗ Error: Invalid filesystem type: $pve_filesystem${CLR_RESET}"
            echo "Valid options: ext4, xfs, zfs, btrfs"
            exit 1
            ;;
    esac

    # Validate ZFS RAID level if ZFS is selected
    if [ "$pve_filesystem" = "zfs" ]; then
        case "$pve_zfs_raid" in
            raid0|raid1|raid10|raidz-1|raidz-2|raidz-3)
                # Valid ZFS RAID level
                ;;
            *)
                echo -e "${CLR_RED}✗ Error: Invalid ZFS RAID level: $pve_zfs_raid${CLR_RESET}"
                echo "Valid options: raid0, raid1, raid10, raidz-1, raidz-2, raidz-3"
                exit 1
                ;;
        esac
    fi

    echo -e "${CLR_GREEN}✓ Required parameters validated${CLR_RESET}"
fi

validate_zfs_encryption_request() {
    [ "$zfs_encryption" != true ] && return 0

    if [ -z "$zfs_encryption_password" ]; then
        echo -e "${CLR_RED}✗ Error: --enable-zfs-encryption requires --zfs-encryption-password${CLR_RESET}"
        exit 1
    fi

    if [ "$automated_install" = true ] && [ "$pve_filesystem" != "zfs" ]; then
        echo -e "${CLR_RED}✗ Error: --enable-zfs-encryption requires a ZFS install.${CLR_RESET}"
        echo "Use --pve-filesystem zfs for automated installs."
        exit 1
    fi
}

validate_zfs_encryption_request

WAN_IFACE=$(ip route show default | awk '/default/ {print $5}')
PUBLIC_IPV4=$(ip -f inet addr show ${WAN_IFACE} | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')

print_interface_names() {
    echo "Available network interfaces:"
    echo "================================"

    for iface in $(ls /sys/class/net | grep -v lo); do
        echo ""
        echo "Interface: $iface"

        # MAC address
        mac=$(cat /sys/class/net/${iface}/address 2>/dev/null)
        [ -n "$mac" ] && echo "  MAC: $mac"

        # Alternative names (altnames)
        altnames=$(ip -d link show $iface 2>/dev/null | grep -oP 'altname \K[^ ]+' | tr '\n' ',' | sed 's/,$//')
        [ -n "$altnames" ] && echo "  Altnames: $altnames"

        # Path-based name
        path_name=$(udevadm info -e 2>/dev/null | grep -m1 -A20 "^P.*${iface}" | grep 'ID_NET_NAME_PATH' | awk -F'=' '{print $2}')
        [ -n "$path_name" ] && echo "  Path name: $path_name"

        # Onboard name
        onboard_name=$(udevadm info -e 2>/dev/null | grep -m1 -A20 "^P.*${iface}" | grep 'ID_NET_NAME_ONBOARD' | awk -F'=' '{print $2}')
        [ -n "$onboard_name" ] && echo "  Onboard name: $onboard_name"
    done

    echo ""
    exit 0
}

# Function to add SSH public key to authorized_keys
add_ssh_key_to_authorized_keys() {
    if [ -n "$ssh_key" ]; then
        if [ -f "$ssh_key" ]; then
            # Copy SSH key to local host via scp
            if ssh-copy-id -f -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "$ssh_key" -p $SSHPORT root@$SSHIP 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"; then
                echo -e "${CLR_GREEN}✓ Added SSH public key to authorized_keys${CLR_RESET}"

                # Disable password authentication for SSH
                ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "sed -i 's/^PasswordAuthentication yes$/PasswordAuthentication no/' /etc/ssh/sshd_config" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
                echo -e "${CLR_GREEN}✓ Password authentication disabled for SSH${CLR_RESET}"
            else
                echo "Error: Failed to copy SSH public key to authorized_keys."
                exit 1
            fi
        else
            echo "Error: File '$ssh_key' does not exist."
            exit 1
        fi
    fi
}


change_ssh_port() {
    if [ -z "$ssh_port" ]; then
        return 0  # Opcjonalny parametr, brak = skip
    fi

    if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
        echo "Error: Invalid SSH port '$ssh_port'. Must be a number between 1-65535."
        exit 1
    fi

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "sed -i 's/^#Port.*$/Port $ssh_port/' /etc/ssh/sshd_config"  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "echo 'Port $ssh_port' >> /root/.ssh/config"  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    echo -e "${CLR_GREEN}✓ SSH port changed to $ssh_port on proxmox server${CLR_RESET}"
}

disable_rpcbind() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "systemctl disable --now rpcbind rpcbind.socket && systemctl mask rpcbind"  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    echo -e "${CLR_GREEN}✓ rpcbind disabled on proxmox server${CLR_RESET}"
}

snat_zone() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP "
        apt-get install -y dnsmasq
        systemctl disable --now dnsmasq
    "  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
}

install_iptables_rule() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP "
        echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections &&
        echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections &&
        apt-get install -y iptables-persistent &&
        iptables -I INPUT -i vmbr0 -p tcp -m tcp --dport 3128 -j DROP && iptables -I INPUT -i vmbr0 -p tcp -m tcp --dport 111 -j DROP &&
        netfilter-persistent save
    "  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
}

update_locale_gen() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP "
        if grep -q \"^# *\$LC_NAME\" /etc/locale.gen; then
            sed -i \"s/^# *\$LC_NAME/\$LC_NAME/\" /etc/locale.gen
            locale-gen
            echo \"Updated /etc/locale.gen and generated locales for \$LC_NAME\"
        fi
        update-locale LANG=en_US.UTF-8
    "  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
}

set_network() {
    curl -L "https://raw.githubusercontent.com/WMP/proxmox-hetzner/refs/heads/main/files/main_vmbr0_basic_template.txt" -o ~/interfaces_sample

    # if [ "$specified_iface_name" ]; then
    #     IFACE_NAME=$specified_iface_name
    # else
    #     IFACE_NAME="$(udevadm info -e | grep -m1 -A 20 ^P.*${WAN_IFACE} | grep ID_NET_NAME_PATH | cut -d'=' -f2)"
    # fi

    # Continue with setting up the network using the chosen IFACE_NAME
    MAIN_IPV4_CIDR="$(ip address show ${WAN_IFACE} | grep global | grep "inet "| xargs | cut -d" " -f2)"
    MAIN_IPV4_GW="$(ip route | grep default | xargs | cut -d" " -f3)"
    MAIN_IPV6_CIDR="$(ip address show ${WAN_IFACE} | grep global | grep "inet6 "| xargs | cut -d" " -f2)"
    MAIN_MAC_ADDR="$(cat /sys/class/net/${WAN_IFACE}/address)"

    # Check if the MAIN_IPV4_CIDR variable has a value
    if [ -z "$MAIN_IPV4_CIDR" ]; then
        echo "Enter the value for MAIN_IPV4_CIDR manually:"
        read -r MAIN_IPV4_CIDR
    fi

    # Check if the MAIN_IPV4_GW variable has a value
    if [ -z "$MAIN_IPV4_GW" ]; then
        echo "Enter the value for MAIN_IPV4_GW manually:"
        read -r MAIN_IPV4_GW
    fi

    # Check if the MAIN_IPV6_CIDR variable has a value
    if [ -z "$MAIN_IPV6_CIDR" ]; then
        echo "Enter the value for MAIN_IPV6_CIDR manually:"
        read -r MAIN_IPV6_CIDR
    fi

    # Check if the MAIN_MAC_ADDR variable has a value
    if [ -z "$MAIN_MAC_ADDR" ]; then
        echo "Enter the value for MAIN_MAC_ADDR manually:"
        read -r MAIN_MAC_ADDR
    fi

    # sed -i "s|#IFACE_NAME#|$IFACE_NAME|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV4_CIDR#|$MAIN_IPV4_CIDR|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV4_GW#|$MAIN_IPV4_GW|g" ~/interfaces_sample
    sed -i "s|#MAIN_MAC_ADDR#|$MAIN_MAC_ADDR|g" ~/interfaces_sample
    sed -i "s|#MAIN_IPV6_CIDR#|$MAIN_IPV6_CIDR|g" ~/interfaces_sample

    # Choose DNS based on platform (OVH or Hetzner)
    if [ "$use_ovh" = true ]; then
        DNS1="213.186.33.99"  # OVH DNS
        DNS2="8.8.8.8"        # Google DNS as backup
    else
        DNS1="185.12.64.1"    # Hetzner DNS
        DNS2="185.12.64.2"    # Hetzner secondary DNS
    fi

    # Display the configuration for user verification
    if [ "$verbose" = true ]; then
        echo "The generated network configuration is as follows:"
        cat ~/interfaces_sample
    fi

    # Apply the configuration
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSHPORT ~/interfaces_sample root@$SSHIP:/etc/network/interfaces  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    # Configure DNS on the remote machine
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP "printf 'nameserver $DNS1\nnameserver $DNS2\n' > /etc/resolv.conf; sed -i 's/10.0.2.15/$PUBLIC_IPV4/' /etc/hosts;"  2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    configure_network_interface
}

configure_network_interface() {
    # Create the configuration script locally
    cat <<EOF > /root/configure_network_interface.sh
#!/bin/bash

# Target MAC address from the main script
TARGET_MAC="$MAIN_MAC_ADDR"

# Find the interface with the specified MAC address
INTERFACE=\$(ip -o link | grep "\$TARGET_MAC" | awk '{print \$2}' | sed 's/://')

# Check if the interface was found
if [ -n "\$INTERFACE" ]; then
    echo "Found network interface \$INTERFACE with MAC \$TARGET_MAC"

    # Update the network configuration by replacing placeholder INTERFACE_NAME
    sed -i "s/#IFACE_NAME#/\$INTERFACE/" /etc/network/interfaces

    # Start the network initialization unit
    # systemctl start systemd-networkd
else
    echo "No network interface found with MAC \$TARGET_MAC"
    exit 1
fi

# Disable and remove this unit after execution
systemctl disable configure-network-interface.service
rm -f /etc/systemd/system/configure-network-interface.service
EOF

    # Make the script executable locally
    chmod +x /root/configure_network_interface.sh

    # Transfer the configuration script to the remote server
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSHPORT /root/configure_network_interface.sh $SSHIP:/root/configure_network_interface.sh 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    # Create the systemd service file locally
    cat <<EOF > /etc/systemd/system/configure-network-interface.service
[Unit]
Description=Configure network interface with specific MAC address
DefaultDependencies=no
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/root/configure_network_interface.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

    # Transfer the systemd service file to the remote server
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSHPORT /etc/systemd/system/configure-network-interface.service $SSHIP:/etc/systemd/system/configure-network-interface.service 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    # Enable the service remotely
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP "
        chmod +x /root/configure_network_interface.sh
        systemctl enable configure-network-interface.service
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
}

# Function to show block devices with detailed information
show_block_devices() {
    echo -e "${CLR_CYAN}=== Block Devices ===${CLR_RESET}"
    echo ""

    # Show detailed information using lsblk
    if command -v lsblk &> /dev/null; then
        lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL,WWN | grep -v loop || true
    fi

    echo ""
    echo -e "${CLR_CYAN}=== Detailed Disk Information ===${CLR_RESET}"

    # Additional details from /sys
    for disk in /sys/block/sd* /sys/block/nvme*; do
        [ -e "$disk" ] || continue
        disk_name=$(basename "$disk")

        echo ""
        echo "Device: /dev/$disk_name"

        # Size
        if [ -f "$disk/size" ]; then
            size_sectors=$(cat "$disk/size")
            size_gb=$((size_sectors * 512 / 1024 / 1024 / 1024))
            echo "  Size: ${size_gb}GB"
        fi

        # Model
        if [ -f "$disk/device/model" ]; then
            model=$(cat "$disk/device/model" | tr -d ' ')
            echo "  Model: $model"
        fi

        # Vendor
        if [ -f "$disk/device/vendor" ]; then
            vendor=$(cat "$disk/device/vendor" | tr -d ' ')
            echo "  Vendor: $vendor"
        fi

        # Serial
        if [ -f "$disk/device/serial" ]; then
            serial=$(cat "$disk/device/serial")
            echo "  Serial: $serial"
        fi

        # WWN
        if [ -f "$disk/device/wwid" ]; then
            wwn=$(cat "$disk/device/wwid")
            echo "  WWN: $wwn"
        fi
    done

    echo ""
}

# Function to show network interfaces with detailed information
show_network_interfaces() {
    echo -e "${CLR_CYAN}=== Network Interfaces ===${CLR_RESET}"
    echo ""

    for iface in $(ls /sys/class/net | grep -v lo); do
        echo "Interface: $iface"

        # MAC address
        if [ -f /sys/class/net/$iface/address ]; then
            mac=$(cat /sys/class/net/$iface/address)
            echo "  MAC: $mac"
        fi

        # Speed
        if [ -f /sys/class/net/$iface/speed ]; then
            speed=$(cat /sys/class/net/$iface/speed 2>/dev/null)
            [ -n "$speed" ] && [ "$speed" != "-1" ] && echo "  Speed: ${speed}Mbps"
        fi

        # Driver
        if [ -L /sys/class/net/$iface/device/driver ]; then
            driver=$(basename $(readlink /sys/class/net/$iface/device/driver))
            echo "  Driver: $driver"
        fi

        # PCI ID
        if [ -f /sys/class/net/$iface/device/vendor ]; then
            vendor=$(cat /sys/class/net/$iface/device/vendor)
            device=$(cat /sys/class/net/$iface/device/device 2>/dev/null)
            echo "  PCI: $vendor:$device"
        fi

        echo ""
    done
}

# Function to generate answer.toml for automated Proxmox installation
generate_answer_toml() {
    local toml_file="$1"

    echo -e "${CLR_CYAN}Generating answer.toml for automated installation${CLR_RESET}"

    # Map physical disk names to QEMU virtio names
    # Physical disks (sda, sdb, nvme0n1, etc.) are passed to QEMU as virtio: vda, vdb, vdc...
    local disk_list_toml=""

    if [ -n "$pve_disk_list" ]; then
        # User provided disk list - map to virtio devices
        # Count number of disks being passed to QEMU from hard_disks array
        local disk_index=0
        local toml_disks=()

        IFS=',' read -ra USER_DISKS <<< "$pve_disk_list"
        for user_disk in "${USER_DISKS[@]}"; do
            # Map to virtio device: first disk -> vda, second -> vdb, etc.
            local virt_letter=$(printf "\x$(printf %x $((97 + disk_index)))")  # 97 = 'a' in ASCII
            toml_disks+=("/dev/vd${virt_letter}")
            ((disk_index++))
        done

        # Format as TOML array
        disk_list_toml=$(printf '"%s", ' "${toml_disks[@]}" | sed 's/, $//')
    else
        # Auto-detection: use first virtio disk
        disk_list_toml="/dev/vda"
    fi

    # Get network configuration from set_network variables
    local gateway="${MAIN_IPV4_GATEWAY}"
    local cidr="${MAIN_IPV4_CIDR}"
    local interface="${MAIN_IFACE_NAME}"

    # DNS servers based on platform
    local dns1 dns2
    if [ "$use_ovh" = true ]; then
        dns1="213.186.33.99"
        dns2="8.8.8.8"
    else
        dns1="185.12.64.1"
        dns2="185.12.64.2"
    fi

    # Extract last 12 hex chars from MAC address (removes colons)
    # MAC format: aa:bb:cc:dd:ee:ff -> filter needs last 6 bytes: *ddeeff (without colons)
    local mac_filter="*$(echo "$MAIN_MAC_ADDR" | tr -d ':' | tail -c 13)"

    # Read SSH public key if it exists
    local ssh_pub_key=""
    if [ -f /root/.ssh/id_rsa.pub ]; then
        ssh_pub_key=$(cat /root/.ssh/id_rsa.pub)
    fi

    # Create answer.toml with proper UDEV filter syntax for network interface
    cat > "$toml_file" <<EOF
[global]
keyboard = "$pve_keyboard"
country = "$pve_country"
fqdn = "$pve_fqdn"
mailto = "$pve_email"
timezone = "$pve_timezone"
root_password = "$pve_root_password"
EOF

    # Add SSH keys if available
    if [ -n "$ssh_pub_key" ]; then
        cat >> "$toml_file" <<EOF
root_ssh_keys = [
    "$ssh_pub_key"
]
EOF
    else
        cat >> "$toml_file" <<EOF
root_ssh_keys = []
EOF
    fi

    # Continue with network and disk setup
    cat >> "$toml_file" <<EOF

[network]
source = "from-answer"
cidr = "$cidr"
dns = "$dns1"
gateway = "$gateway"
filter.ID_NET_NAME_MAC = "$mac_filter"

[disk-setup]
filesystem = "$pve_filesystem"
disk_list = [$disk_list_toml]
EOF

    # Add ZFS-specific configuration if ZFS is selected
    if [ "$pve_filesystem" = "zfs" ]; then
        cat >> "$toml_file" <<EOF
zfs.raid = "$pve_zfs_raid"
EOF
    fi

    echo -e "${CLR_GREEN}✓ Generated answer.toml${CLR_RESET}"

    if [ "$verbose" = true ]; then
        echo "Answer.toml contents:"
        cat "$toml_file"
    fi
}

# Function to check if system is booted in UEFI mode
is_uefi_mode() {
    [ -d /sys/firmware/efi ]
}

# Function to download the latest Proxmox ISO if not already downloaded
download_latest_proxmox_iso() {
    # URL from which we fetch Proxmox ISO images
    ISO_URL="https://enterprise.proxmox.com/iso/"

    # Fetching the list of ISO images
    iso_list=$(curl -s "$ISO_URL")

    # Extracting the name of the ISO file based on version specification
    if [ "$proxmox_version" = "latest" ]; then
        # Get the absolute latest version
        latest_iso_name=$(echo "$iso_list" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sort -V | tail -n 1)
    elif [[ "$proxmox_version" =~ ^[0-9]+\.[0-9]+-[0-9]+$ ]]; then
        # Exact version specified (e.g., 8.2-1)
        latest_iso_name="proxmox-ve_${proxmox_version}.iso"
        # Verify it exists in the list
        if ! echo "$iso_list" | grep -q "$latest_iso_name"; then
            echo -e "${CLR_RED}✗ Error: Proxmox version $proxmox_version not found${CLR_RESET}"
            echo "Available versions:"
            echo "$iso_list" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sed 's/proxmox-ve_/  /' | sed 's/\.iso//' | sort -uV
            exit 1
        fi
    elif [[ "$proxmox_version" =~ ^[0-9]+\.[0-9]+$ ]]; then
        # Minor version specified (e.g., 8.2) - get latest patch
        latest_iso_name=$(echo "$iso_list" | grep -oE "proxmox-ve_${proxmox_version}-[0-9]+\.iso" | sort -V | tail -n 1)
        if [ -z "$latest_iso_name" ]; then
            echo -e "${CLR_RED}✗ Error: No Proxmox version matching $proxmox_version found${CLR_RESET}"
            echo "Available versions:"
            echo "$iso_list" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sed 's/proxmox-ve_/  /' | sed 's/\.iso//' | sort -uV
            exit 1
        fi
    elif [[ "$proxmox_version" =~ ^[0-9]+$ ]]; then
        # Major version specified (e.g., 8) - get latest minor.patch
        latest_iso_name=$(echo "$iso_list" | grep -oE "proxmox-ve_${proxmox_version}\.[0-9]+-[0-9]+\.iso" | sort -V | tail -n 1)
        if [ -z "$latest_iso_name" ]; then
            echo -e "${CLR_RED}✗ Error: No Proxmox version matching $proxmox_version found${CLR_RESET}"
            echo "Available versions:"
            echo "$iso_list" | grep -oE 'proxmox-ve_[0-9]+\.[0-9]+-[0-9]+\.iso' | sed 's/proxmox-ve_/  /' | sed 's/\.iso//' | sort -uV
            exit 1
        fi
    else
        echo -e "${CLR_RED}✗ Error: Invalid version format '$proxmox_version'${CLR_RESET}"
        echo "Valid formats: latest, 8, 8.2, 8.2-1"
        exit 1
    fi

    echo -e "${CLR_CYAN}Selected Proxmox version: $latest_iso_name${CLR_RESET}"

    # Check if ISO already exists
    if [ -f "$latest_iso_name" ]; then
        echo "ISO already exists at $latest_iso_name"
        return
    fi

    echo "Downloading the latest ISO file"
    if curl --help all | grep -q -- --remove-on-error; then
        curl --remove-on-error -o "$latest_iso_name" "$ISO_URL/$latest_iso_name"
    else
        curl -o "$latest_iso_name" "$ISO_URL/$latest_iso_name"
    fi

    if [ $? -eq 0 ]; then
        echo -e "${CLR_GREEN}✓ Downloaded the latest ISO image: $latest_iso_name${CLR_RESET}"
    else
        echo -e "${CLR_RED}✗ Error downloading the ISO image.${CLR_RESET}"
        exit 1
    fi
}

# Function to create auto-install ISO using proxmox-auto-install-assistant
create_autoinstall_iso() {
    local source_iso="$1"
    local answer_toml="$2"
    local output_iso="${source_iso%.iso}-auto.iso"

    echo -e "${CLR_CYAN}Creating auto-install ISO from $source_iso${CLR_RESET}"

    # Check if proxmox-auto-install-assistant is available
    if ! command -v proxmox-auto-install-assistant &> /dev/null; then
        echo -e "${CLR_YELLOW}⚠ proxmox-auto-install-assistant not found, installing...${CLR_RESET}"

        # Mount the ISO to extract the assistant tool
        mkdir -p /mnt/pve-iso
        mount -o loop "$source_iso" /mnt/pve-iso

        # The assistant is usually in the ISO
        if [ -f /mnt/pve-iso/proxmox-auto-install-assistant ]; then
            cp /mnt/pve-iso/proxmox-auto-install-assistant /usr/local/bin/
            chmod +x /usr/local/bin/proxmox-auto-install-assistant
            echo -e "${CLR_GREEN}✓ Installed proxmox-auto-install-assistant${CLR_RESET}"
        else
            umount /mnt/pve-iso
            echo -e "${CLR_RED}✗ Error: proxmox-auto-install-assistant not found in ISO${CLR_RESET}"
            echo "This feature requires Proxmox 9.0 or higher"
            exit 1
        fi

        umount /mnt/pve-iso
    fi

    # Create the auto-install ISO
    echo -e "${CLR_CYAN}Running proxmox-auto-install-assistant...${CLR_RESET}"

    if proxmox-auto-install-assistant prepare-iso "$source_iso" --answer-file "$answer_toml" --output "$output_iso"; then
        echo -e "${CLR_GREEN}✓ Created auto-install ISO: $output_iso${CLR_RESET}"
        echo "$output_iso"
    else
        echo -e "${CLR_RED}✗ Error creating auto-install ISO${CLR_RESET}"
        exit 1
    fi
}

# Function to check if SSH server is up with a timeout of 60 seconds
check_ssh_server() {
    local server="$SSHIP"
    local port="$SSHPORT"
    local timeout=60
    local end_time=$((SECONDS + timeout))

    while [ $SECONDS -lt $end_time ]; do
        if nc -z "$server" "$port" </dev/null; then
            return 0
        fi
        sleep 1
    done
    return 1
}

order_acme_certificate() {
    cat <<EOF > /root/acme_certificate_order_script.sh
#!/bin/bash

# Determine WAN Interface and Public IP
WAN_IFACE=\$(ip route show default | awk '/default/ {print \$5}')
PUBLIC_IPV4=\$(ip -f inet addr show \${WAN_IFACE} | sed -En -e 's/.*inet ([0-9.]+).*/\1/p')

# Function to check if DNS record matches the server's public IP
check_dns_record() {
    DNS_IP=\$(dig +short "\$(hostname -f)")
    if [[ "\$DNS_IP" == "\$PUBLIC_IPV4" ]]; then
        echo "DNS record matches server's public IP: \$PUBLIC_IPV4"
        return 0
    else
        echo "Waiting for DNS record to update. Current DNS IP: \$DNS_IP"
        return 1
    fi
}

# Check DNS record, order ACME certificate if matching, and clean up
if check_dns_record; then
    pvenode acme cert order

    # Remove the cron job and cleanup the script
    rm -f /etc/cron.d/acme_certificate_order_cron
    rm -f /root/acme_certificate_order_script.sh
fi
EOF

    # Make the script executable and copy it to the remote server
    chmod +x /root/acme_certificate_order_script.sh
    scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSHPORT /root/acme_certificate_order_script.sh $SSHIP:/root/acme_certificate_order_script.sh 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    # Set up cron to run the script every minute and log output
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP "
        echo -e \"* * * * * root /root/acme_certificate_order_script.sh > /var/log/acme_certificate_order_script.log 2>&1\n\" > /etc/cron.d/acme_certificate_order_cron && \
        chmod 644 /etc/cron.d/acme_certificate_order_cron
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
}



register_acme_account() {
    # Exit the function if acme_email is not set
    [ -z "$acme_email" ] && return 1

    # Prosta walidacja email
    if ! [[ "$acme_email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
        echo "Error: Invalid email format '$acme_email'"
        exit 1
    fi

    ssh -o CheckHostIP=no -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP "
        apt update && apt install -y expect &&
        expect -c \"
            spawn pvenode acme account register default $acme_email --directory https://acme-v02.api.letsencrypt.org/directory
            expect -re {Do you agree}
            send \"y\\\r\"
            interact
        \" && pvenode config set --acme domains=\$(hostname -f)
    "  2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    order_acme_certificate
}

add_tun_lxc_device() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "
        mkdir -p /usr/share/lxc/config/common.conf.d
        cat <<'EOF' >/usr/share/lxc/config/common.conf.d/10-tun.conf
lxc.cgroup2.devices.allow = c 10:200 rwm
lxc.hook.pre-start = sh -c \"/usr/sbin/modprobe tun && [ ! -e /dev/net/tun-lxc ] && /usr/bin/mknod /dev/net/tun-lxc c 10 200 || true && /usr/bin/chown 100000:100000 /dev/net/tun-lxc\"
lxc.mount.entry = /dev/net/tun-lxc dev/net/tun none bind,create=file
EOF
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
}

run_tteck_post-pve-install() {
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP  -t  'bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/tools/pve/post-pve-install.sh)"'
}


setup_private_subnet() {
    [ -z "$private_subnet" ] && return 0

    echo -e "${CLR_CYAN}Configuring private subnet: $private_subnet${CLR_RESET}"

    # Calculate network details
    PRIVATE_CIDR=$(echo "$private_subnet" | cut -d'/' -f1 | rev | cut -d'.' -f2- | rev)
    PRIVATE_IP="${PRIVATE_CIDR}.1"
    SUBNET_MASK=$(echo "$private_subnet" | cut -d'/' -f2)

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "
        cat >> /etc/network/interfaces <<'EOF'

# Private subnet bridge
auto vmbr1
iface vmbr1 inet static
    address ${PRIVATE_IP}/${SUBNET_MASK}
    bridge-ports none
    bridge-stp off
    bridge-fd 0
    post-up   iptables -t nat -A POSTROUTING -s '${private_subnet}' -o vmbr0 -j MASQUERADE
    post-down iptables -t nat -D POSTROUTING -s '${private_subnet}' -o vmbr0 -j MASQUERADE
    post-up   iptables -t raw -I PREROUTING -i fwbr+ -j CT --zone 1
    post-down iptables -t raw -D PREROUTING -i fwbr+ -j CT --zone 1
EOF
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    echo -e "${CLR_GREEN}✓ Private subnet configured on vmbr1${CLR_RESET}"
}

enable_zfs_encryption() {
    # Check if encryption is requested
    [ "$zfs_encryption" != true ] && return 0

    echo -e "${CLR_CYAN}Setting up ZFS native encryption...${CLR_RESET}"

    echo -e "${CLR_CYAN}Installing required packages for remote unlock (dropbear-initramfs)...${CLR_RESET}"
    
    # 1. Install dropbear-initramfs
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSHPORT" "$SSHIP" "
        set -e
        apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y dropbear-initramfs zfs-initramfs busybox
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to.*closed)"; then
        echo -e "${CLR_RED}Error: Failed to install required packages${CLR_RESET}"
        return 1
    fi

    # 2. Configure Dropbear
    echo -e "${CLR_CYAN}Configuring Dropbear SSH for initramfs...${CLR_RESET}"
    
    # Get public key to authorize (use the one we found/generated earlier)
    local pub_key=""
    if [ -f /root/.ssh/id_rsa.pub ]; then
        pub_key=$(cat /root/.ssh/id_rsa.pub)
    elif [ -f "$ssh_key" ]; then
         pub_key=$(cat "$ssh_key")
    else
         echo -e "${CLR_YELLOW}Warning: No local public SSH key found to authorize for Dropbear. Trying to generate one...${CLR_RESET}"
         mkdir -p /root/.ssh
         ssh-keygen -t rsa -N "" -f /root/.ssh/id_rsa
         pub_key=$(cat /root/.ssh/id_rsa.pub)
    fi

    # Validate we have a public key
    if [ -z "$pub_key" ]; then
        echo -e "${CLR_RED}Error: No SSH public key available${CLR_RESET}"
        return 1
    fi

    # Configure remote server
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSHPORT" "$SSHIP" "
        set -e
        # Add public key to dropbear authorized_keys
        mkdir -p /etc/dropbear-initramfs
        touch /etc/dropbear-initramfs/authorized_keys
        grep -qxF '$pub_key' /etc/dropbear-initramfs/authorized_keys || echo '$pub_key' >> /etc/dropbear-initramfs/authorized_keys
        chmod 700 /etc/dropbear-initramfs
        chmod 600 /etc/dropbear-initramfs/authorized_keys

        # Configure Dropbear options (port, etc)
        # We ensure it listens on the specified port and forces the zfsunlock command on login
        
        # Create the zfsunlock script
        cat <<'UNLOCK' > /usr/local/bin/zfsunlock
#!/bin/sh
echo "Unlocking ZFS datasets..."
if zfs load-key -a; then
    echo "Keys loaded successfully."
    if zfs get -H -o value keystatus rpool/ROOT 2>/dev/null | grep -q available; then
        echo "Root dataset unlocked. Killing dropbear to resume boot..."
        killall dropbear 2>/dev/null
        exit 0
    else
        echo "Warning: Root dataset status unclear"
        exit 0
    fi
else
    echo "Failed to load keys. Please check your passphrase."
    exit 1
fi
UNLOCK
        chmod +x /usr/local/bin/zfsunlock

        # Create hook to include zfsunlock in initramfs
        if [ ! -f /etc/initramfs-tools/hooks/zfsunlock_hook ]; then
            cat <<'HOOK' > /etc/initramfs-tools/hooks/zfsunlock_hook
#!/bin/sh
PREREQ=""
prereqs() {
    echo "\$PREREQ"
}
case \$1 in
    prereqs)
        prereqs
        exit 0
        ;;
esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /usr/local/bin/zfsunlock /bin/zfsunlock
HOOK
            chmod +x /etc/initramfs-tools/hooks/zfsunlock_hook
        fi

        # Update Dropbear config to force this command
        # Note: Using $zfs_encryption_ssh_port from outer shell scope
        if grep -q '^#\?DROPBEAR_OPTIONS=' /etc/dropbear-initramfs/config 2>/dev/null; then
            sed -i 's|^#\?DROPBEAR_OPTIONS=.*|DROPBEAR_OPTIONS=\"-p $zfs_encryption_ssh_port -j -k -c /bin/zfsunlock\"|' /etc/dropbear-initramfs/config
        else
            echo 'DROPBEAR_OPTIONS=\"-p $zfs_encryption_ssh_port -j -k -c /bin/zfsunlock\"' >> /etc/dropbear-initramfs/config
        fi

        # Configure static IP in initramfs
        echo 'Configuring network for initramfs...'
        
        # Extract IP/CIDR and Gateway from interfaces file
        IP_CIDR=\$(grep -E '^\s*address' /etc/network/interfaces | awk '{print \$2}' | head -n1)
        GW=\$(grep -E '^\s*gateway' /etc/network/interfaces | awk '{print \$2}' | head -n1)
        
        if [ -n "\$IP_CIDR" ] && [ -n "\$GW" ]; then
            IP=\${IP_CIDR%/*}
            CIDR=\${IP_CIDR#*/}
            
            # Default CIDR to 24 if extraction failed
            [ -z "\$CIDR" ] && CIDR=24
            
            # Calculate netmask from CIDR using pure shell
            FULL_OCTETS=\$((CIDR / 8))
            REM_BITS=\$((CIDR % 8))
            MASK=""
            
            for i in 1 2 3 4; do
                if [ \$i -le \$FULL_OCTETS ]; then
                    VAL=255
                elif [ \$i -eq \$((FULL_OCTETS + 1)) ]; then
                    VAL=\$(( 256 - (1 << (8 - REM_BITS)) ))
                else
                    VAL=0
                fi
                [ -z "\$MASK" ] && MASK="\$VAL" || MASK="\${MASK}.\$VAL"
            done
            
            # Add kernel parameter to initramfs.conf
            IP_PARAM="IP=\${IP}::\${GW}:\${MASK}:proxmox::off"
            echo "Network config: \$IP_PARAM"
            if grep -q '^IP=' /etc/initramfs-tools/initramfs.conf 2>/dev/null; then
                sed -i "s|^IP=.*|\$IP_PARAM|" /etc/initramfs-tools/initramfs.conf
            else
                echo "\$IP_PARAM" >> /etc/initramfs-tools/initramfs.conf
            fi
        else
            echo 'Warning: Could not detect network config. Manual configuration may be needed.'
        fi

        # Enable zfs-load-key service
        cat <<'SERVICE' > /etc/systemd/system/zfs-load-keys.service
[Unit]
Description=Load ZFS encryption keys
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/zfs load-key rpool/data

[Install]
WantedBy=zfs-mount.service
SERVICE
        
        systemctl enable zfs-load-keys.service 2>&1 || true
        
        echo 'Updating initramfs...'
        update-initramfs -u -k all
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to.*closed)"

    # 3. Perform the ZFS Encryption Migration
    echo -e "${CLR_CYAN}Starting ZFS encryption migration (ROOT dataset)...${CLR_RESET}"
    echo -e "${CLR_YELLOW}Migrating ROOT with staged copies and rollback protection. Do not interrupt!${CLR_RESET}"

    local pass_stage_output=""
    if ! pass_stage_output=$(printf '%s\n' "$zfs_encryption_password" | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSHPORT" "$SSHIP" "
        set -eu
        umask 077
        cat > /tmp/zfs_pass
        chmod 600 /tmp/zfs_pass
    " 2>&1); then
        printf '%s\n' "$pass_stage_output" | grep -E -v "(Warning: Permanently added |Connection to.*closed)" || true
        echo -e "${CLR_RED}Error: Failed to stage ZFS encryption passphrase${CLR_RESET}"
        return 1
    fi
    printf '%s\n' "$pass_stage_output" | grep -E -v "(Warning: Permanently added |Connection to.*closed)" || true
    
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSHPORT" "$SSHIP" "
        set -eu
        set -o pipefail

        ROOT_SNAPSHOT='encroot-prep'
        ROOT_STAGE='rpool/ROOT-copy-pre-encryption'
        ROOT_BACKUP='rpool/ROOT-backup-pre-encryption'
        PASSFILE='/tmp/zfs_pass'
        ROOT_RENAMED=false
        ROOT_CREATED=false
        ROOT_DESCENDANT_COUNT=0

        log_root() {
            printf '[zfs-root] %s\n' \"\$1\"
        }

        cleanup_root() {
            rm -f \"\$PASSFILE\"
        }

        rollback_root() {
            log_root 'Rolling back ROOT migration...'
            if [ \"\$ROOT_CREATED\" = true ] && zfs list rpool/ROOT >/dev/null 2>&1; then
                zfs destroy -r rpool/ROOT || true
            fi
            if [ \"\$ROOT_RENAMED\" = true ] && zfs list \"\$ROOT_BACKUP\" >/dev/null 2>&1; then
                zfs rename \"\$ROOT_BACKUP\" rpool/ROOT || true
            fi
        }

        trap 'status=\$?; if [ \$status -ne 0 ]; then rollback_root; fi; cleanup_root; exit \$status' EXIT

        if [ ! -s \"\$PASSFILE\" ]; then
            echo 'Error: ZFS passphrase file was not staged'
            exit 1
        fi
        chmod 600 \"\$PASSFILE\"

        zpool import -f rpool 2>/dev/null || true

        if ! zfs list rpool/ROOT >/dev/null 2>&1; then
            echo 'Error: rpool/ROOT dataset not found'
            exit 1
        fi

        if zfs get -H -o value encryption rpool/ROOT 2>/dev/null | grep -qv '^off$'; then
            echo 'Error: rpool/ROOT is already encrypted; refusing to rerun migration'
            exit 1
        fi

        if zfs list -H -r -t snapshot -o name rpool/ROOT 2>/dev/null | grep -Eq '@\${ROOT_SNAPSHOT}$'; then
            echo 'Error: Existing ROOT preparation snapshot found. Resolve prior encryption attempt first.'
            exit 1
        fi

        if zfs list \"\$ROOT_STAGE\" >/dev/null 2>&1 || zfs list \"\$ROOT_BACKUP\" >/dev/null 2>&1; then
            echo 'Error: Existing ROOT backup or staging dataset found. Resolve prior encryption attempt first.'
            exit 1
        fi

        BOOTFS=\$(zpool get -H -o value bootfs rpool 2>/dev/null || true)
        if [ -z \"\$BOOTFS\" ] || [ \"\$BOOTFS\" = '-' ] || ! zfs list \"\$BOOTFS\" >/dev/null 2>&1; then
            BOOTFS=\$(zfs list -H -r -o name rpool/ROOT | awk 'NR==2 {print; exit}')
        fi

        if [ -z \"\$BOOTFS\" ] || ! zfs list \"\$BOOTFS\" >/dev/null 2>&1; then
            echo 'Error: Could not determine active ROOT child dataset'
            exit 1
        fi

        ROOT_CHILD_NAME=\${BOOTFS##*/}
        ROOT_DESCENDANT_COUNT=\$(zfs list -H -r -o name rpool/ROOT | wc -l)

        log_root 'Creating snapshot of ROOT dataset...'
        zfs snapshot -r rpool/ROOT@\"\$ROOT_SNAPSHOT\"

        log_root 'Copying ROOT to staging dataset...'
        zfs send -R rpool/ROOT@\"\$ROOT_SNAPSHOT\" | zfs receive -u \"\$ROOT_STAGE\"

        if ! zfs list \"\$ROOT_STAGE/\$ROOT_CHILD_NAME\" >/dev/null 2>&1; then
            echo 'Error: Staged ROOT copy missing active child dataset'
            exit 1
        fi

        log_root 'Renaming original ROOT dataset to backup...'
        zfs rename rpool/ROOT \"\$ROOT_BACKUP\"
        ROOT_RENAMED=true

        log_root 'Creating encrypted replacement ROOT dataset...'
        zfs create -o encryption=on -o keyformat=passphrase -o keylocation=prompt -o compression=on -o acltype=posixacl -o xattr=sa -o dnodesize=auto rpool/ROOT < \"\$PASSFILE\"
        ROOT_CREATED=true

        log_root 'Restoring ROOT datasets into encrypted parent...'
        zfs send -R \"\$ROOT_STAGE@\$ROOT_SNAPSHOT\" | zfs receive -u -F -x encryption rpool/ROOT

        RESTORED_BOOTFS=\"rpool/ROOT/\$ROOT_CHILD_NAME\"
        if ! zfs list \"\$RESTORED_BOOTFS\" >/dev/null 2>&1; then
            echo 'Error: Restored encrypted ROOT child not found'
            exit 1
        fi

        log_root 'Configuring boot settings...'
        zfs set mountpoint=/ \"\$RESTORED_BOOTFS\"
        zpool set bootfs=\"\$RESTORED_BOOTFS\" rpool

        zpool export rpool
        zpool import -f -N rpool
        zfs load-key rpool/ROOT < \"\$PASSFILE\"
        zfs mount \"\$RESTORED_BOOTFS\"

        if ! zfs get -H -o value encryption rpool/ROOT 2>/dev/null | grep -qv '^off$'; then
            echo 'Error: Encryption is not enabled on rpool/ROOT'
            exit 1
        fi

        if ! zpool get -H -o value bootfs rpool 2>/dev/null | grep -qx \"\$RESTORED_BOOTFS\"; then
            echo 'Error: bootfs does not point to restored ROOT child'
            exit 1
        fi

        if ! zfs list \"\$RESTORED_BOOTFS\" >/dev/null 2>&1; then
            echo 'Error: Restored ROOT child missing after pool re-import'
            exit 1
        fi

        if [ \"\$(zfs list -H -r -o name rpool/ROOT | wc -l)\" -ne \"\$ROOT_DESCENDANT_COUNT\" ]; then
            echo 'Error: Restored ROOT dataset tree does not match the pre-migration dataset count'
            exit 1
        fi

        if ! zfs get -H -o value keystatus rpool/ROOT 2>/dev/null | grep -qx 'available'; then
            echo 'Error: Restored ROOT key is not loaded after migration'
            exit 1
        fi

        log_root 'Cleaning up staging datasets and snapshots...'
        zfs destroy -r \"\$ROOT_STAGE\"
        zfs destroy -r \"\$ROOT_BACKUP\"
        zfs destroy -r rpool/ROOT@\"\$ROOT_SNAPSHOT\"

        trap - EXIT
        cleanup_root
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to.*closed)"; then
        echo -e "${CLR_RED}Error: ROOT dataset encryption failed${CLR_RESET}"
        return 1
    fi

    echo -e "${CLR_GREEN}✓ ZFS ROOT encryption complete.${CLR_RESET}"
    
    # 4. Encrypt rpool/data (VM storage)
    echo -e "${CLR_CYAN}Encrypting rpool/data (VM storage)...${CLR_RESET}"
    
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSHPORT" "$SSHIP" "
        set -eu
        set -o pipefail

        DATA_SNAPSHOT='encdata-prep'
        DATA_STAGE='rpool/data-copy-pre-encryption'
        DATA_BACKUP='rpool/data-backup-pre-encryption'
        DATA_CREATED=false
        DATA_RENAMED=false
        DATA_DESCENDANT_COUNT=0

        log_data() {
            printf '[zfs-data] %s\n' \"\$1\"
        }

        rollback_data() {
            log_data 'Rolling back data migration...'
            if [ \"\$DATA_CREATED\" = true ] && zfs list rpool/data >/dev/null 2>&1; then
                zfs destroy -r rpool/data || true
            fi
            if [ \"\$DATA_RENAMED\" = true ] && zfs list \"\$DATA_BACKUP\" >/dev/null 2>&1; then
                zfs rename \"\$DATA_BACKUP\" rpool/data || true
            fi
        }

        trap 'status=\$?; if [ \$status -ne 0 ]; then rollback_data; fi; exit \$status' EXIT

        if ! zfs list rpool/data >/dev/null 2>&1; then
            echo 'Dataset rpool/data does not exist, skipping'
            trap - EXIT
            exit 0
        fi

        if zfs get -H -o value encryption rpool/data 2>/dev/null | grep -qv '^off$'; then
            echo 'Error: rpool/data is already encrypted; refusing to rerun migration'
            exit 1
        fi

        if zfs list -H -r -t snapshot -o name rpool/data 2>/dev/null | grep -Eq '@\${DATA_SNAPSHOT}$'; then
            echo 'Error: Existing data preparation snapshot found. Resolve prior encryption attempt first.'
            exit 1
        fi

        if zfs list \"\$DATA_STAGE\" >/dev/null 2>&1 || zfs list \"\$DATA_BACKUP\" >/dev/null 2>&1; then
            echo 'Error: Existing data backup or staging dataset found. Resolve prior encryption attempt first.'
            exit 1
        fi

        if [ -f /root/pve-data.key ]; then
            echo 'Error: /root/pve-data.key already exists. Refusing to overwrite an existing data-encryption key.'
            exit 1
        fi

        umask 077
        DATA_DESCENDANT_COUNT=\$(zfs list -H -r -o name rpool/data | wc -l)
        openssl rand -hex 32 > /root/pve-data.key
        chmod 600 /root/pve-data.key

        log_data 'Snapshotting data dataset...'
        zfs snapshot -r rpool/data@\"\$DATA_SNAPSHOT\"

        log_data 'Copying data dataset to staging...'
        zfs send -R rpool/data@\"\$DATA_SNAPSHOT\" | zfs receive -u \"\$DATA_STAGE\"

        log_data 'Renaming original data dataset to backup...'
        zfs rename rpool/data \"\$DATA_BACKUP\"
        DATA_RENAMED=true

        log_data 'Creating encrypted data dataset...'
        zfs create -o encryption=on -o keyformat=hex -o keylocation=file:///root/pve-data.key -o compression=on rpool/data
        DATA_CREATED=true

        log_data 'Restoring data datasets into encrypted parent...'
        zfs send -R \"\$DATA_STAGE@\$DATA_SNAPSHOT\" | zfs receive -u -F -x encryption rpool/data

        if ! zfs list rpool/data >/dev/null 2>&1; then
            echo 'Error: Restored rpool/data dataset not found'
            exit 1
        fi

        zfs load-key rpool/data

        if ! zfs get -H -o value encryption rpool/data 2>/dev/null | grep -qv '^off$'; then
            echo 'Error: Encryption is not enabled on rpool/data'
            exit 1
        fi

        if ! zfs get -H -o value keylocation rpool/data 2>/dev/null | grep -qx 'file:///root/pve-data.key'; then
            echo 'Error: rpool/data keylocation is not set to /root/pve-data.key'
            exit 1
        fi

        if ! zfs get -H -o value keystatus rpool/data 2>/dev/null | grep -qx 'available'; then
            echo 'Error: rpool/data key is not loaded after migration'
            exit 1
        fi

        if [ \"\$(zfs list -H -r -o name rpool/data | wc -l)\" -ne \"\$DATA_DESCENDANT_COUNT\" ]; then
            echo 'Error: Restored rpool/data tree does not match the pre-migration dataset count'
            exit 1
        fi

        log_data 'Cleaning up staging datasets and snapshots...'
        zfs destroy -r \"\$DATA_STAGE\"
        zfs destroy -r \"\$DATA_BACKUP\"
        zfs destroy -r rpool/data@\"\$DATA_SNAPSHOT\"

        trap - EXIT
        echo 'Data dataset encryption complete'
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to.*closed)"; then
        echo -e "${CLR_RED}Error: Data dataset encryption failed${CLR_RESET}"
        return 1
    fi
     
    echo -e "${CLR_GREEN}✓ ZFS data encryption complete.${CLR_RESET}"
    echo -e ""
    echo -e "${CLR_GREEN}═══════════════════════════════════════════════════════${CLR_RESET}"
    echo -e "${CLR_GREEN}  ZFS Encryption Setup Complete${CLR_RESET}"
    echo -e "${CLR_GREEN}═══════════════════════════════════════════════════════${CLR_RESET}"
    echo -e "${CLR_YELLOW}IMPORTANT: On first boot, unlock the disk remotely:${CLR_RESET}"
    echo -e "  ${CLR_CYAN}ssh -p $zfs_encryption_ssh_port root@<server-ip>${CLR_RESET}"
    echo -e "  (will auto-run zfsunlock and prompt for passphrase)"
    echo -e ""
    echo -e "${CLR_YELLOW}Save your encryption password securely!${CLR_RESET}"
    echo -e "${CLR_GREEN}═══════════════════════════════════════════════════════${CLR_RESET}"
}

install_zabbix_agent() {
    if [[ -z "$zabbix_server_address" ]]; then
        echo "Error: zabbix_agent plugin requires --zabbix-server option."
        exit 1
    fi

    # Walidacja czy to IP lub hostname (prosta walidacja)
    if ! [[ "$zabbix_server_address" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*[a-zA-Z0-9]$ ]]; then
        echo "Error: Invalid zabbix server address format '$zabbix_server_address'"
        exit 1
    fi

    agent_version_param=${zabbix_agent_version:+$zabbix_agent_version}
    hostname_param=${zabbix_hostname:+$zabbix_hostname}

    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "
        curl -fsSL https://wmp.github.io/zabbix/install.sh | bash -s -- $zabbix_server_address $agent_version_param $hostname_param
    " 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
}

validate_post_install_plugins() {
    [ "$zfs_encryption" != true ] && return 0

    echo -e "${CLR_CYAN}Validating installed system for ZFS encryption...${CLR_RESET}"

    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p "$SSHPORT" "$SSHIP" "
        set -eu
        zpool list rpool >/dev/null 2>&1
        zfs list rpool/ROOT >/dev/null 2>&1
        BOOTFS=\$(zpool get -H -o value bootfs rpool 2>/dev/null || true)
        if [ -z \"\$BOOTFS\" ] || [ \"\$BOOTFS\" = '-' ]; then
            BOOTFS=\$(zfs list -H -r -o name rpool/ROOT | awk 'NR==2 {print; exit}')
        fi
        [ -n \"\$BOOTFS\" ] && zfs list \"\$BOOTFS\" >/dev/null 2>&1
    "; then
        echo -e "${CLR_RED}✗ Error: --enable-zfs-encryption only works on Proxmox systems installed on ZFS.${CLR_RESET}"
        echo "Manual installs must select ZFS in the installer. Automated installs must use --pve-filesystem zfs."
        exit 1
    fi
}


## EXECUTION ##
if ! dpkg -s qemu-system netcat-traditional ovmf >/dev/null 2>&1; then
  apt-get update
  apt-get install -y qemu-system netcat-traditional ovmf
fi


# Check if we are in an OVH environment by detecting /etc/ovh
if [ -f /etc/ovh ]; then
    use_ovh=true
    echo "Detected OVH environment."
    SSHPORT=22
    SSHIP="10.0.2.15"
else
    echo "Detected Hetzner environment."
    SSHPORT=5555
    SSHIP="127.0.0.1"
fi

# Detecting EFI/UEFI system
if is_uefi_mode; then
    bios="-bios /usr/share/ovmf/OVMF.fd"
else
    bios=""
fi

# Display the list of disks with the added device path
if [ "$verbose" = true ]; then
    # Array to store disk information as text
    hard_disks_text=()

    # Read disk information using lsblk and store it in the array
    first_line=true
    while read -r line; do
        if $first_line; then
            first_line=false
            continue
        fi
        hard_disks_text+=("$line")
    done < <(lsblk -o NAME,SIZE,SERIAL,VENDOR,MODEL,PARTTYPE -d -p | grep -v 'loop' | grep -v 'sr')

    # Add a column with device path /dev/vd*
    device_path="/dev/vd"
    counter=97  # ASCII code for 'a'
    for ((i = 0; i < ${#hard_disks_text[@]}; i++)); do
        if (( $counter > 122 )); then  # If ASCII code exceeds 'z'
            echo "Too many disks to assign"
            break
        fi
        # Append device path to each disk entry
        hard_disks_text[$i]="${hard_disks_text[$i]} $device_path$(printf "\x$(printf %x $counter)")"
        ((counter++))
    done

    echo "Disk mapping table:"
    for disk_info in "${hard_disks_text[@]}"; do
        echo "$disk_info"
    done
fi

hard_disks=()
while read -r line; do
    hard_disks+=("$line")
done < <(lsblk -o NAME -d -n -p | grep -v 'loop' | grep -v 'sr')

latest_machine=$(qemu-system-x86_64 -machine help | grep -oP "pc-q35-\d+\.\d+" | sort -V | tail -n 1)

if [ ! -n "$vnc_password" ]; then
    # Generate random VNC password
    vnc_password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
fi

# Build the QEMU command with VNC and mounted disks if --rescue is specified
if [ "$rescue" = true ]; then
    # Construct the QEMU command in rescue mode
    echo "Starting QEMU in rescue mode with VNC access"
    echo
    echo "Connecto to vnc://$PUBLIC_IPV4:5900 with password: $vnc_password"
    echo "If VNC stuck before open installator, try to reconnect VNC client"
    echo

    qemu_command="printf \"change vnc password\n%s\n\" $vnc_password | qemu-system-x86_64 -machine $latest_machine -enable-kvm $bios -cpu host -smp 4 -m 4096 -vnc :0,password -monitor stdio -no-reboot"

    # Mount each detected hard disk
    for disk in "${hard_disks[@]}"; do
        qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
    done

    # Run the rescue QEMU command
    if [ "$verbose" = true ]; then
        echo "$qemu_command"
        eval "$qemu_command"
    else
        eval "$qemu_command > /dev/null 2>&1"
    fi
    exit 0  # Exit the script after starting in rescue mode
fi

if [ "$skip_installer" = false ]; then
    # Call the function to download the latest Proxmox ISO
    download_latest_proxmox_iso

    # Generate auto-install ISO if automated install is enabled
    if [ "$automated_install" = true ]; then
        echo -e "${CLR_CYAN}Preparing automated installation${CLR_RESET}"
        echo ""

        # Generate SSH key if it doesn't exist (needed for root-ssh-keys in answer.toml)
        if [ ! -f /root/.ssh/id_rsa ]; then
            echo -e "${CLR_CYAN}Generating SSH key pair...${CLR_RESET}"
            mkdir -p /root/.ssh
            ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
            echo -e "${CLR_GREEN}✓ SSH key generated${CLR_RESET}"
        fi

        # Show hardware information
        show_block_devices
        show_network_interfaces

        # Generate answer.toml
        answer_toml="/tmp/answer.toml"
        generate_answer_toml "$answer_toml"

        # Display generated TOML
        echo -e "${CLR_CYAN}=== Generated answer.toml ===${CLR_RESET}"
        echo ""
        cat "$answer_toml"
        echo ""

        # Ask for confirmation unless --yes is specified
        if [ "$yes_to_all" = false ]; then
            echo -e "${CLR_YELLOW}Review the configuration above.${CLR_RESET}"
            echo -e "${CLR_YELLOW}This will perform an automated installation on the selected disks.${CLR_RESET}"
            echo -e "${CLR_RED}WARNING: All data on the selected disks will be erased!${CLR_RESET}"
            echo ""
            read -p "Do you want to continue? (yes/no): " confirmation

            if [ "$confirmation" != "yes" ] && [ "$confirmation" != "y" ]; then
                echo -e "${CLR_RED}Installation cancelled by user${CLR_RESET}"
                exit 0
            fi
        else
            echo -e "${CLR_YELLOW}Skipping confirmation (--yes flag)${CLR_RESET}"
        fi

        echo ""

        # Create auto-install ISO
        auto_iso=$(create_autoinstall_iso "$latest_iso_name" "$answer_toml")

        # Use the auto-install ISO for installation
        install_iso="$auto_iso"

        echo -e "${CLR_GREEN}✓ Automated installation prepared${CLR_RESET}"
        echo -e "${CLR_YELLOW}Starting automated installation (no VNC interaction needed)${CLR_RESET}"
        echo
    else
        # Use regular ISO for manual VNC installation
        install_iso="$latest_iso_name"

        if [ ! -n "$vnc_password" ]; then
            # Generate random VNC password
            vnc_password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 16)
        fi

        echo
        echo "Connecto to vnc://$PUBLIC_IPV4:5900 with password: $vnc_password"
        echo "If VNC stuck before open installator, try to reconnect VNC client"
        echo
        echo "In the network settings window, make sure to set the correct hostname and DO NOT change the IP addresses. There IP addresses are needed only for the system installation process."
        echo
    fi

    # Building QEMU command with detected hard disks
    if [ "$automated_install" = true ]; then
        # Automated install - no VNC password needed, runs in background
        qemu_command="qemu-system-x86_64 -machine $latest_machine -enable-kvm $bios -cpu host -smp 4 -m 4096 -boot d -cdrom $install_iso -nographic -serial mon:stdio -no-reboot"
    else
        # Manual install - VNC with password
        qemu_command="printf \"change vnc password\n%s\n\" $vnc_password | qemu-system-x86_64 -machine $latest_machine -enable-kvm $bios -cpu host -smp 4 -m 4096 -boot d -cdrom $install_iso -vnc :0,password -monitor stdio -no-reboot"
    fi

    for disk in "${hard_disks[@]}"; do
        qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
    done

    # Running QEMU
    if [ "$verbose" = true ]; then
        echo "$qemu_command"
        eval "$qemu_command"
    else
        eval "$qemu_command > /dev/null 2>&1"
    fi
fi

# Set up bridge networking if --ovh is specified
if [ "$use_ovh" = true ]; then
  BRIDGE_NAME="br0"
  BRIDGE_IP="10.0.2.2"
  SUBNET="10.0.2.0/24"
  OUT_INTERFACE="eth0"  # Replace with actual outgoing interface

  # Create and configure bridge if it doesn't exist
  if ! ip link show $BRIDGE_NAME > /dev/null 2>&1; then
    echo "Creating bridge $BRIDGE_NAME..."
    ip link add name $BRIDGE_NAME type bridge
    ip addr add $BRIDGE_IP/24 dev $BRIDGE_NAME
    ip link set $BRIDGE_NAME up

    # Enable IP forwarding
    echo 1 > /proc/sys/net/ipv4/ip_forward

    # Set up NAT for the bridge network
    iptables -t nat -A POSTROUTING -s $SUBNET -o $OUT_INTERFACE -j MASQUERADE

    # iptables -t nat -A PREROUTING -p tcp --dport 5555 -j REDIRECT --to-port 22

    # Configure bridge permissions for QEMU
    sudo mkdir -p /etc/qemu
    echo "allow $BRIDGE_NAME" | sudo tee /etc/qemu/bridge.conf
  fi

  # Construct QEMU command with bridge networking
  qemu_command="printf \"change vnc password\n%s\n\" $vnc_password | qemu-system-x86_64 -machine $latest_machine -enable-kvm $bios -cpu host \
  -netdev bridge,id=net0,br=$BRIDGE_NAME -device virtio-net-pci,netdev=net0 -smp 4 -m 4096 -vnc :0,password -monitor stdio"
else
  # Default QEMU command with user networking
  qemu_command="printf \"change vnc password\n%s\n\" $vnc_password | qemu-system-x86_64 -machine $latest_machine -enable-kvm $bios -cpu host \
  -device e1000,netdev=net0 -netdev user,id=net0,hostfwd=tcp::5555-:22 -smp 4 -m 4096 -vnc :0,password -monitor stdio"
fi

for disk in "${hard_disks[@]}"; do
    qemu_command+=" -drive file=$disk,format=raw,media=disk,if=virtio"
done

# Running QEMU
if [ "$verbose" = true ]; then
    echo "$qemu_command"
    eval "$qemu_command &"
else
    eval "$qemu_command > /dev/null 2>&1 &"
fi

bg_pid=$!

# Performing SSH operations
if [ ! -f /root/.ssh/id_rsa ]; then
    ssh-keygen -b 2048 -t rsa -f /root/.ssh/id_rsa -q -N ""
fi

echo -e "${CLR_CYAN}Waiting for start SSH server on proxmox...${CLR_RESET}"
check_ssh_server || { echo -e "${CLR_RED}✗ Fatal: Proxmox may not have started properly because SSH on socket $SSHIP:$SSHPORT is not working.${CLR_RESET}"; exit 1; }
echo
echo "Please enter the password for the root user that you set during the Proxmox installation."
echo "Remember not to select the reboot option in the 'run_tteck_post-pve-install' plugin!"
echo

ssh-copy-id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT $SSHIP -C exit 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

validate_post_install_plugins

# Run enabled plugins
for plugin in $(echo "$plugin_list" | tr ',' '\n'); do
    run_plugin "$plugin"
done

# Shut down the virtual machine if --no-shutdown option is not used
if [ "$no_shutdown" = false ]; then
    echo "Shutting down the virtual machine..."
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "poweroff" 2>&1  | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
fi
