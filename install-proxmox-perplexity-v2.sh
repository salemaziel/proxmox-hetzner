#!/bin/bash

# ============================================================================
# Proxmox Installation Script with ZFS Full Disk Encryption Support
# ============================================================================
# This script automates Proxmox VE installation on Hetzner dedicated servers
# with optional ZFS full-disk encryption and remote unlock via Dropbear SSH.
#
# ZFS Encryption Architecture:
# - rpool/ROOT: Passphrase-encrypted (manual unlock at boot)
# - rpool/data: Keyfile-encrypted (auto-unlock via systemd service)
# - rpool/var-lib-vz: Keyfile-encrypted (auto-unlock via systemd service)
#
# Version: 2.0 (with ZFS encryption support for Proxmox 9)
# ============================================================================

# Color codes (can be disabled with --no-color)
CLR_RED='\033[0;31m'
CLR_GREEN='\033[0;32m'
CLR_YELLOW='\033[1;33m'
CLR_BLUE='\033[0;34m'
CLR_CYAN='\033[0;36m'
CLR_RESET='\033[0m'

# ============================================================================
# Default variables
# ============================================================================
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

# ============================================================================
# ZFS Encryption parameters (NEW)
# ============================================================================
enable_zfs_encryption=false        # Master switch for ZFS encryption
zfs_root_passphrase=""              # Passphrase for rpool/ROOT (required for encryption)
zfs_encryption_algorithm="aes-256-gcm"  # Encryption algorithm
zfs_compression="zstd-3"            # Compression algorithm
zfs_checksum="blake3"               # Checksum algorithm (blake3 for Proxmox 9)
enable_dropbear=false               # Enable dropbear for remote unlock
dropbear_port="2222"                # Dropbear SSH port for initramfs
dropbear_authorized_keys=""         # Path to authorized_keys file for dropbear
zfs_backup_keys_path="/root/zfs-encryption-keys-backup"  # Backup location for encryption keys

# Logging configuration
ZFS_ENCRYPTION_LOG="/var/log/proxmox-zfs-encryption.log"

# ============================================================================
# Function to show help message (ENHANCED)
# ============================================================================
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
    echo "                                Examples: latest, 9, 9.1, 9.1-1"
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
    echo "=== ZFS ENCRYPTION OPTIONS (NEW) ==="
    echo "  --enable-zfs-encryption       Enable ZFS full disk encryption"
    echo "                                Only works with --pve-filesystem zfs and --automated-install"
    echo "  --zfs-root-passphrase PASS    Passphrase for root pool encryption (required with encryption)"
    echo "                                This passphrase will be needed at every boot to unlock the system"
    echo "  --zfs-encryption-algo ALGO    Encryption algorithm (default: aes-256-gcm)"
    echo "                                Options: aes-128-ccm, aes-192-ccm, aes-256-ccm,"
    echo "                                         aes-128-gcm, aes-192-gcm, aes-256-gcm"
    echo "  --zfs-compression ALGO        Compression algorithm (default: zstd-3)"
    echo "                                Options: lz4, gzip-[1-9], zstd-[1-19], zstd-fast-[1-10]"
    echo "  --zfs-checksum ALGO           Checksum algorithm (default: blake3)"
    echo "                                Options: on, off, fletcher2, fletcher4, sha256, sha512, blake3"
    echo "  --enable-dropbear             Enable dropbear SSH server in initramfs for remote unlock"
    echo "  --dropbear-port PORT          Dropbear SSH port in initramfs (default: 2222)"
    echo "  --dropbear-keys FILE          Path to authorized_keys file for dropbear remote access"
    echo "  --zfs-backup-keys-path PATH   Path to backup encryption keys (default: /root/zfs-encryption-keys-backup)"
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
    echo "  # Automated installation with ZFS RAID1 encryption:"
    echo "  $0 --automated-install --proxmox-version 9 \\"
    echo "     --pve-fqdn pve.example.com --pve-email admin@example.com \\"
    echo "     --pve-root-password SecurePass123 --pve-filesystem zfs \\"
    echo "     --pve-zfs-raid raid1 --pve-disk-list sda,sdb \\"
    echo "     --enable-zfs-encryption --zfs-root-passphrase 'MySecurePassphrase123!' \\"
    echo "     --enable-dropbear --dropbear-keys /root/.ssh/authorized_keys"
    echo ""
    echo "  # Install with custom ZFS encryption parameters:"
    echo "  $0 --automated-install --proxmox-version 9 \\"
    echo "     --pve-fqdn pve.example.com --pve-email admin@example.com \\"
    echo "     --pve-root-password SecurePass123 --pve-filesystem zfs \\"
    echo "     --enable-zfs-encryption --zfs-root-passphrase 'MyPass123' \\"
    echo "     --zfs-encryption-algo aes-128-gcm --zfs-compression lz4 \\"
    echo "     --zfs-checksum sha512"
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
        "setup_zfs_encryption")
            echo "[Optional - Auto-enabled with --enable-zfs-encryption]"
            echo "Encrypts ZFS pools post-installation with full disk encryption."
            echo "Required options:"
            echo "    --enable-zfs-encryption          Enable ZFS encryption"
            echo "    --zfs-root-passphrase PASS       Root pool passphrase"
            ;;
        *)
            echo "No description available"
            echo
            ;;
    esac
}

# ============================================================================
# Function to run the specified plugin (ENHANCED)
# ============================================================================
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
        "setup_zfs_encryption")
            setup_zfs_encryption
            ;;
        *)
            echo "Unknown plugin: $1"
            ;;
    esac
}

# Default list of plugins
plugin_list="update_locale_gen,set_network,run_tteck_post-pve-install,register_acme_account,disable_rpcbind,install_iptables_rule,snat_zone,add_ssh_key_to_authorized_keys,change_ssh_port,add_tun_lxc_device,zabbix_agent,setup_private_subnet,setup_zfs_encryption"

# ============================================================================
# Parsing command line options (ENHANCED with ZFS encryption options)
# ============================================================================
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
        # ====================================================================
        # NEW: ZFS Encryption Options
        # ====================================================================
        --enable-zfs-encryption)
            enable_zfs_encryption=true
            shift
            ;;
        --zfs-root-passphrase)
            zfs_root_passphrase="$2"
            shift
            shift
            ;;
        --zfs-encryption-algo)
            zfs_encryption_algorithm="$2"
            shift
            shift
            ;;
        --zfs-compression)
            zfs_compression="$2"
            shift
            shift
            ;;
        --zfs-checksum)
            zfs_checksum="$2"
            shift
            shift
            ;;
        --enable-dropbear)
            enable_dropbear=true
            shift
            ;;
        --dropbear-port)
            dropbear_port="$2"
            shift
            shift
            ;;
        --dropbear-keys)
            dropbear_authorized_keys="$2"
            shift
            shift
            ;;
        --zfs-backup-keys-path)
            zfs_backup_keys_path="$2"
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

# ============================================================================
# Validate ZFS encryption requirements (NEW)
# ============================================================================
if [ "$enable_zfs_encryption" = true ]; then
    echo -e "${CLR_CYAN}=== ZFS Encryption Configuration ===${CLR_RESET}"
    
    # Validation: Encryption requires ZFS filesystem
    if [ "$pve_filesystem" != "zfs" ]; then
        echo -e "${CLR_RED}✗ Error: --enable-zfs-encryption requires --pve-filesystem zfs${CLR_RESET}"
        exit 1
    fi
    
    # Validation: Encryption requires automated install
    if [ "$automated_install" != true ]; then
        echo -e "${CLR_RED}✗ Error: --enable-zfs-encryption requires --automated-install${CLR_RESET}"
        echo "ZFS encryption is only supported with automated installation mode"
        exit 1
    fi
    
    # Validation: Root passphrase is required
    if [ -z "$zfs_root_passphrase" ]; then
        echo -e "${CLR_RED}✗ Error: --zfs-root-passphrase is required when encryption is enabled${CLR_RESET}"
        echo "This passphrase will be used to encrypt the root ZFS pool (rpool/ROOT)"
        exit 1
    fi
    
    # Validation: Passphrase strength check
    if [ ${#zfs_root_passphrase} -lt 12 ]; then
        echo -e "${CLR_YELLOW}⚠ WARNING: Passphrase is less than 12 characters${CLR_RESET}"
        echo "For security, a passphrase of at least 12 characters is recommended"
        if [ "$yes_to_all" = false ]; then
            read -p "Continue anyway? (yes/no): " confirmation
            if [ "$confirmation" != "yes" ] && [ "$confirmation" != "y" ]; then
                echo -e "${CLR_RED}Installation cancelled${CLR_RESET}"
                exit 0
            fi
        fi
    fi
    
    # Validation: Check encryption algorithm
    valid_algos="aes-128-ccm aes-192-ccm aes-256-ccm aes-128-gcm aes-192-gcm aes-256-gcm"
    if ! echo "$valid_algos" | grep -qw "$zfs_encryption_algorithm"; then
        echo -e "${CLR_RED}✗ Error: Invalid encryption algorithm: $zfs_encryption_algorithm${CLR_RESET}"
        echo "Valid options: $valid_algos"
        exit 1
    fi
    
    # Validation: Dropbear requirements
    if [ "$enable_dropbear" = true ]; then
        if [ -n "$dropbear_authorized_keys" ] && [ ! -f "$dropbear_authorized_keys" ]; then
            echo -e "${CLR_RED}✗ Error: Dropbear authorized_keys file not found: $dropbear_authorized_keys${CLR_RESET}"
            exit 1
        fi
        
        # Validate port number
        if ! [[ "$dropbear_port" =~ ^[0-9]+$ ]] || [ "$dropbear_port" -lt 1 ] || [ "$dropbear_port" -gt 65535 ]; then
            echo -e "${CLR_RED}✗ Error: Invalid dropbear port: $dropbear_port${CLR_RESET}"
            exit 1
        fi
    fi
    
    echo -e "${CLR_GREEN}✓ ZFS encryption configuration validated${CLR_RESET}"
    echo -e "${CLR_YELLOW}  Encryption algorithm: $zfs_encryption_algorithm${CLR_RESET}"
    echo -e "${CLR_YELLOW}  Compression: $zfs_compression${CLR_RESET}"
    echo -e "${CLR_YELLOW}  Checksum: $zfs_checksum${CLR_RESET}"
    echo -e "${CLR_YELLOW}  Dropbear remote unlock: $([ "$enable_dropbear" = true ] && echo "enabled" || echo "disabled")${CLR_RESET}"
    echo ""
fi

# ============================================================================
# Validate automated install requirements (EXISTING - kept intact)
# ============================================================================
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

# [... Continue with existing functions from original script ...]
# Including: print_interface_names, add_ssh_key_to_authorized_keys, change_ssh_port, etc.

# ============================================================================
# NEW FUNCTION: Setup ZFS Encryption (Post-Installation)
# ============================================================================
setup_zfs_encryption() {
    # Skip if encryption not enabled
    if [ "$enable_zfs_encryption" != true ]; then
        return 0
    fi

    echo -e "${CLR_CYAN}==================================================================${CLR_RESET}"
    echo -e "${CLR_CYAN}        Setting up ZFS Full Disk Encryption${CLR_RESET}"
    echo -e "${CLR_CYAN}==================================================================${CLR_RESET}"
    echo ""
    
    # Initialize logging
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "mkdir -p /var/log && touch $ZFS_ENCRYPTION_LOG" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    log_message() {
        local message="$1"
        echo -e "${CLR_CYAN}[ZFS-ENCRYPT]${CLR_RESET} $message"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] $message\" >> $ZFS_ENCRYPTION_LOG" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    }
    
    log_error() {
        local message="$1"
        echo -e "${CLR_RED}[ERROR]${CLR_RESET} $message"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "echo \"[\$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $message\" >> $ZFS_ENCRYPTION_LOG" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    }
    
    log_message "Starting ZFS encryption process"
    log_message "Encryption algorithm: $zfs_encryption_algorithm"
    log_message "Compression: $zfs_compression"
    log_message "Checksum: $zfs_checksum"
    
    # ========================================================================
    # PHASE 1: Verify ZFS installation and pool status
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 1: Verifying ZFS installation...${CLR_RESET}"
    
    # Check if rpool exists and is imported
    if ! ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "zpool list rpool" 2>&1 | grep -q "rpool"; then
        log_error "ZFS root pool (rpool) not found or not imported"
        echo -e "${CLR_RED}✗ Failed: rpool not found${CLR_RESET}"
        return 1
    fi
    
    log_message "Root pool (rpool) detected and accessible"
    echo -e "${CLR_GREEN}✓ rpool verified${CLR_RESET}"
    
    # Display current pool configuration
    if [ "$verbose" = true ]; then
        echo -e "${CLR_CYAN}Current ZFS pool configuration:${CLR_RESET}"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "zpool status rpool" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
        echo ""
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "zfs list -r rpool" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
        echo ""
    fi
    
    # ========================================================================
    # PHASE 2: Set pool-level options for optimization
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 2: Configuring pool-level options...${CLR_RESET}"
    
    log_message "Setting autoexpand=on for pool"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "zpool set autoexpand=on rpool" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    log_message "Setting autotrim=on for pool"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "zpool set autotrim=on rpool" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    log_message "Setting failmode=wait for pool"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "zpool set failmode=wait rpool" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    echo -e "${CLR_GREEN}✓ Pool options configured${CLR_RESET}"
    
    # ========================================================================
    # PHASE 3: Encrypt rpool/ROOT (Root filesystem - passphrase-based)
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 3: Encrypting root filesystem (rpool/ROOT)...${CLR_RESET}"
    echo -e "${CLR_YELLOW}This process will:${CLR_RESET}"
    echo -e "${CLR_YELLOW}  1. Take a recursive snapshot of rpool/ROOT${CLR_RESET}"
    echo -e "${CLR_YELLOW}  2. Copy the snapshot to temporary location${CLR_RESET}"
    echo -e "${CLR_YELLOW}  3. Destroy the unencrypted rpool/ROOT${CLR_RESET}"
    echo -e "${CLR_YELLOW}  4. Recreate rpool/ROOT with encryption enabled${CLR_RESET}"
    echo -e "${CLR_YELLOW}  5. Restore data from snapshot${CLR_RESET}"
    echo ""
    
    # Create encryption script on remote host
    # This approach avoids issues with passing passphrases through SSH
    cat << 'ENCRYPT_ROOT_SCRIPT' | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "cat > /tmp/encrypt_root.sh && chmod +x /tmp/encrypt_root.sh"
#!/bin/bash
# ZFS Root Pool Encryption Script
# This script encrypts the root filesystem pool

set -e  # Exit on any error

LOG_FILE="$1"
PASSPHRASE="$2"
ENCRYPTION_ALGO="$3"
COMPRESSION="$4"
CHECKSUM="$5"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

log "=== Starting Root Pool Encryption ==="

# Step 1: Create recursive snapshot
log "Creating recursive snapshot of rpool/ROOT"
if ! zfs snapshot -r rpool/ROOT@encrypt_copy; then
    error_exit "Failed to create snapshot of rpool/ROOT"
fi
log "✓ Snapshot created: rpool/ROOT@encrypt_copy"

# Step 2: Send snapshot to temporary location
log "Copying snapshot to temporary location (rpool/copyroot)"
if ! zfs send -R rpool/ROOT@encrypt_copy | zfs receive rpool/copyroot; then
    log "Cleaning up snapshot..."
    zfs destroy -r rpool/ROOT@encrypt_copy
    error_exit "Failed to copy snapshot to rpool/copyroot"
fi
log "✓ Data copied to rpool/copyroot"

# Step 3: Destroy unencrypted ROOT
log "Destroying unencrypted rpool/ROOT (data is safe in rpool/copyroot)"
if ! zfs destroy -r rpool/ROOT; then
    log "Cleaning up temporary data..."
    zfs destroy -r rpool/copyroot
    error_exit "Failed to destroy unencrypted rpool/ROOT"
fi
log "✓ Unencrypted rpool/ROOT destroyed"

# Step 4: Create encrypted ROOT with passphrase
log "Creating encrypted rpool/ROOT with algorithm: $ENCRYPTION_ALGO"
if ! echo "$PASSPHRASE" | zfs create \
    -o acltype=posix \
    -o atime=off \
    -o compression="$COMPRESSION" \
    -o checksum="$CHECKSUM" \
    -o dnodesize=auto \
    -o encryption=on \
    -o keyformat=passphrase \
    -o keylocation=prompt \
    -o overlay=off \
    -o xattr=sa \
    rpool/ROOT; then
    log "CRITICAL ERROR: Failed to create encrypted rpool/ROOT"
    log "Manual recovery required: zfs send -R rpool/copyroot/pve-1@encrypt_copy | zfs receive rpool/ROOT/pve-1"
    exit 1
fi
log "✓ Encrypted rpool/ROOT created"

# Step 5: Restore data from temporary copy
log "Restoring data from rpool/copyroot to encrypted rpool/ROOT/pve-1"
if ! echo "$PASSPHRASE" | zfs send -R rpool/copyroot/pve-1@encrypt_copy | zfs receive -o encryption=on rpool/ROOT/pve-1; then
    log "CRITICAL ERROR: Failed to restore data to encrypted pool"
    log "Temporary data still available at rpool/copyroot for manual recovery"
    exit 1
fi
log "✓ Data restored to encrypted rpool/ROOT/pve-1"

# Step 6: Set mountpoint
log "Setting mountpoint=/ for rpool/ROOT/pve-1"
if ! zfs set mountpoint=/ rpool/ROOT/pve-1; then
    error_exit "Failed to set mountpoint for rpool/ROOT/pve-1"
fi
log "✓ Mountpoint configured"

# Step 7: Cleanup temporary data
log "Cleaning up temporary snapshots and datasets"
if ! zfs destroy -r rpool/copyroot; then
    log "WARNING: Failed to destroy rpool/copyroot - manual cleanup may be needed"
fi

if ! zfs destroy rpool/ROOT/pve-1@encrypt_copy; then
    log "WARNING: Failed to destroy snapshot rpool/ROOT/pve-1@encrypt_copy"
fi
log "✓ Temporary data cleaned up"

log "=== Root Pool Encryption Complete ==="
ENCRYPT_ROOT_SCRIPT

    # Execute the encryption script
    log_message "Executing root pool encryption (this may take several minutes)"
    
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "/tmp/encrypt_root.sh '$ZFS_ENCRYPTION_LOG' '$zfs_root_passphrase' '$zfs_encryption_algorithm' '$zfs_compression' '$zfs_checksum'" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"; then
        log_message "Root pool encryption completed successfully"
        echo -e "${CLR_GREEN}✓ rpool/ROOT encrypted with passphrase${CLR_RESET}"
    else
        log_error "Root pool encryption failed"
        echo -e "${CLR_RED}✗ Failed to encrypt rpool/ROOT${CLR_RESET}"
        echo -e "${CLR_YELLOW}Check logs at $ZFS_ENCRYPTION_LOG on the server${CLR_RESET}"
        return 1
    fi
    
    # Cleanup encryption script
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "rm -f /tmp/encrypt_root.sh" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    # ========================================================================
    # PHASE 4: Generate keyfiles for child pools
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 4: Generating encryption keyfiles for child pools...${CLR_RESET}"
    
    log_message "Generating 64-byte random keyfile for rpool/data"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "tr -dc '[:alnum:]' < /dev/urandom | head -c 64 > /.data.key && chmod 400 /.data.key && chattr +i /.data.key" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    echo -e "${CLR_GREEN}✓ Keyfile created: /.data.key${CLR_RESET}"
    
    log_message "Generating 64-byte random keyfile for rpool/var-lib-vz"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "tr -dc '[:alnum:]' < /dev/urandom | head -c 64 > /.var-lib-vz.key && chmod 400 /.var-lib-vz.key && chattr +i /.var-lib-vz.key" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    echo -e "${CLR_GREEN}✓ Keyfile created: /.var-lib-vz.key${CLR_RESET}"
    
    # ========================================================================
    # PHASE 5: Encrypt rpool/data (VM/CT disk storage - keyfile-based)
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 5: Encrypting rpool/data (VM/CT storage)...${CLR_RESET}"
    
    cat << 'ENCRYPT_DATA_SCRIPT' | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "cat > /tmp/encrypt_data.sh && chmod +x /tmp/encrypt_data.sh"
#!/bin/bash
# ZFS Data Pool Encryption Script
set -e

LOG_FILE="$1"
ENCRYPTION_ALGO="$2"
COMPRESSION="$3"
CHECKSUM="$4"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

log "=== Starting Data Pool Encryption ==="

# Check if data pool exists, create if it doesn't
if ! zfs list rpool/data >/dev/null 2>&1; then
    log "Creating rpool/data pool (did not exist)"
    if ! zfs create rpool/data; then
        error_exit "Failed to create rpool/data"
    fi
fi

# Step 1: Snapshot
log "Creating recursive snapshot of rpool/data"
if ! zfs snapshot -r rpool/data@encrypt_copy; then
    error_exit "Failed to create snapshot of rpool/data"
fi

# Step 2: Copy to temp
log "Copying snapshot to rpool/copydata"
if ! zfs send -R rpool/data@encrypt_copy | zfs receive rpool/copydata; then
    zfs destroy -r rpool/data@encrypt_copy
    error_exit "Failed to copy data to rpool/copydata"
fi

# Step 3: Destroy unencrypted
log "Destroying unencrypted rpool/data"
if ! zfs destroy -r rpool/data; then
    zfs destroy -r rpool/copydata
    error_exit "Failed to destroy unencrypted rpool/data"
fi

# Step 4: Create encrypted with keyfile
log "Creating encrypted rpool/data with keyfile"
if ! zfs create \
    -o acltype=posix \
    -o atime=off \
    -o compression="$COMPRESSION" \
    -o checksum="$CHECKSUM" \
    -o dnodesize=auto \
    -o encryption=on \
    -o keyformat=passphrase \
    -o keylocation=file:///.data.key \
    -o overlay=off \
    -o xattr=sa \
    rpool/data; then
    log "CRITICAL ERROR: Failed to create encrypted rpool/data"
    log "Temporary data at rpool/copydata for recovery"
    exit 1
fi

# Step 5: Check if there are any VM disks to transfer
log "Checking for existing VM/CT disks to transfer"
vm_disks=$(zfs list -H -o name | grep "^rpool/copydata/vm-" | grep -v "@encrypt_copy$" || true)

if [ -n "$vm_disks" ]; then
    log "Found VM/CT disks to transfer:"
    echo "$vm_disks" | while read disk; do
        log "  - $disk"
        # Extract disk name (e.g., vm-100-disk-0 from rpool/copydata/vm-100-disk-0)
        disk_name=$(basename "$disk")
        log "Transferring $disk_name to encrypted pool"
        
        if ! zfs send -R "${disk}@encrypt_copy" | zfs receive -o encryption=on "rpool/data/${disk_name}"; then
            log "WARNING: Failed to transfer $disk_name"
        else
            log "✓ Transferred: $disk_name"
        fi
    done
else
    log "No existing VM/CT disks found (normal for fresh installation)"
fi

# Step 6: Cleanup
log "Cleaning up temporary data"
zfs destroy -r rpool/copydata || log "WARNING: Failed to cleanup rpool/copydata"

log "=== Data Pool Encryption Complete ==="
ENCRYPT_DATA_SCRIPT

    log_message "Executing data pool encryption"
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "/tmp/encrypt_data.sh '$ZFS_ENCRYPTION_LOG' '$zfs_encryption_algorithm' '$zfs_compression' '$zfs_checksum'" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"; then
        log_message "Data pool encryption completed successfully"
        echo -e "${CLR_GREEN}✓ rpool/data encrypted with keyfile${CLR_RESET}"
    else
        log_error "Data pool encryption failed"
        echo -e "${CLR_RED}✗ Failed to encrypt rpool/data${CLR_RESET}"
    fi
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "rm -f /tmp/encrypt_data.sh" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    # ========================================================================
    # PHASE 6: Encrypt rpool/var-lib-vz (Template/ISO storage - keyfile-based)
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 6: Encrypting rpool/var-lib-vz (template/ISO storage)...${CLR_RESET}"
    
    cat << 'ENCRYPT_VARLIBVZ_SCRIPT' | ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "cat > /tmp/encrypt_varlibvz.sh && chmod +x /tmp/encrypt_varlibvz.sh"
#!/bin/bash
# ZFS var-lib-vz Pool Encryption Script
set -e

LOG_FILE="$1"
ENCRYPTION_ALGO="$2"
COMPRESSION="$3"
CHECKSUM="$4"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

error_exit() {
    log "ERROR: $1"
    exit 1
}

log "=== Starting var-lib-vz Pool Encryption ==="

# Check if pool exists
if ! zfs list rpool/var-lib-vz >/dev/null 2>&1; then
    log "Creating rpool/var-lib-vz pool (did not exist)"
    if ! zfs create rpool/var-lib-vz; then
        error_exit "Failed to create rpool/var-lib-vz"
    fi
fi

# Step 1: Snapshot
log "Creating snapshot of rpool/var-lib-vz"
if ! zfs snapshot -r rpool/var-lib-vz@encrypt_copy; then
    error_exit "Failed to create snapshot"
fi

# Step 2: Copy
log "Copying to rpool/copy-var"
if ! zfs send -R rpool/var-lib-vz@encrypt_copy | zfs receive rpool/copy-var; then
    zfs destroy -r rpool/var-lib-vz@encrypt_copy
    error_exit "Failed to copy data"
fi

# Step 3: Unmount and destroy
log "Unmounting /var/lib/vz"
umount /var/lib/vz 2>/dev/null || log "WARNING: /var/lib/vz not mounted"

log "Destroying unencrypted rpool/var-lib-vz"
if ! zfs destroy -r rpool/var-lib-vz; then
    zfs destroy -r rpool/copy-var
    error_exit "Failed to destroy unencrypted pool"
fi

# Step 4: Create encrypted
log "Creating encrypted rpool/var-lib-vz"
if ! zfs create \
    -o acltype=posix \
    -o atime=off \
    -o compression="$COMPRESSION" \
    -o checksum="$CHECKSUM" \
    -o dnodesize=auto \
    -o encryption=on \
    -o keyformat=passphrase \
    -o keylocation=file:///.var-lib-vz.key \
    -o overlay=off \
    -o xattr=sa \
    rpool/var-lib-vz; then
    log "CRITICAL ERROR: Failed to create encrypted pool"
    log "Backup at rpool/copy-var for recovery"
    exit 1
fi

# Step 5: Restore data manually (copy-based approach for compatibility)
log "Setting up temporary mount for data transfer"
mkdir -p /mnt/varlibvz

log "Setting temporary mountpoint for rpool/copy-var"
zfs set mountpoint=/mnt/varlibvz rpool/copy-var

log "Mounting filesystems"
mount -a || log "WARNING: Some mounts failed"

log "Copying data from temporary location to encrypted pool"
# Create directory structure
mkdir -p /var/lib/vz/{images,dump,template/iso}

# Copy data if it exists
if [ -d /mnt/varlibvz/images ]; then
    log "Copying images directory"
    rsync -a /mnt/varlibvz/images/ /var/lib/vz/images/ || log "WARNING: No images to copy"
fi

if [ -d /mnt/varlibvz/dump ]; then
    log "Copying dump directory"
    rsync -a /mnt/varlibvz/dump/ /var/lib/vz/dump/ || log "WARNING: No dumps to copy"
fi

if [ -d /mnt/varlibvz/template/iso ]; then
    log "Copying ISO templates"
    rsync -a /mnt/varlibvz/template/iso/ /var/lib/vz/template/iso/ || log "WARNING: No ISOs to copy"
fi

# Step 6: Cleanup
log "Unmounting temporary location"
umount /mnt/varlibvz 2>/dev/null || log "WARNING: Failed to unmount /mnt/varlibvz"
rmdir /mnt/varlibvz

log "Destroying temporary copy"
zfs destroy -r rpool/copy-var || log "WARNING: Failed to cleanup rpool/copy-var"

log "=== var-lib-vz Pool Encryption Complete ==="
ENCRYPT_VARLIBVZ_SCRIPT

    log_message "Executing var-lib-vz pool encryption"
    if ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "/tmp/encrypt_varlibvz.sh '$ZFS_ENCRYPTION_LOG' '$zfs_encryption_algorithm' '$zfs_compression' '$zfs_checksum'" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"; then
        log_message "var-lib-vz pool encryption completed successfully"
        echo -e "${CLR_GREEN}✓ rpool/var-lib-vz encrypted with keyfile${CLR_RESET}"
    else
        log_error "var-lib-vz pool encryption failed"
        echo -e "${CLR_RED}✗ Failed to encrypt rpool/var-lib-vz${CLR_RESET}"
    fi
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "rm -f /tmp/encrypt_varlibvz.sh" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    # ========================================================================
    # PHASE 7: Verify encryption status
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 7: Verifying encryption status...${CLR_RESET}"
    
    log_message "Checking encryption status of all pools"
    encryption_status=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "zfs get encryption -r rpool" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)")
    
    echo "$encryption_status"
    log_message "Encryption status:\n$encryption_status"
    
    # Verify that encryption is enabled on critical pools
    if echo "$encryption_status" | grep -q "rpool/ROOT.*aes-256-gcm"; then
        echo -e "${CLR_GREEN}✓ rpool/ROOT encryption verified${CLR_RESET}"
    else
        echo -e "${CLR_RED}✗ WARNING: rpool/ROOT encryption not confirmed${CLR_RESET}"
    fi
    
    if echo "$encryption_status" | grep -q "rpool/data.*aes-256-gcm"; then
        echo -e "${CLR_GREEN}✓ rpool/data encryption verified${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}⚠ rpool/data encryption status unclear (may not exist yet)${CLR_RESET}"
    fi
    
    if echo "$encryption_status" | grep -q "rpool/var-lib-vz.*aes-256-gcm"; then
        echo -e "${CLR_GREEN}✓ rpool/var-lib-vz encryption verified${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}⚠ rpool/var-lib-vz encryption status unclear (may not exist yet)${CLR_RESET}"
    fi
    
    # ========================================================================
    # PHASE 8: Setup automatic key loading systemd service
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 8: Configuring automatic keyfile loading...${CLR_RESET}"
    
    log_message "Creating zfs-load-keys systemd service"
    
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "cat > /etc/systemd/system/zfs-load-keys.service << 'EOF'
[Unit]
Description=Load ZFS encryption keys from keyfiles
DefaultDependencies=no
After=zfs-import.target
Before=zfs-mount.service

[Service]
Type=oneshot
RemainAfterExit=yes
# Load all keys (keyfile-based pools will load automatically)
ExecStart=/usr/sbin/zfs load-key -a
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=zfs-mount.service
EOF
" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

    log_message "Enabling zfs-load-keys service"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "systemctl enable zfs-load-keys.service" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    echo -e "${CLR_GREEN}✓ Auto-load service configured${CLR_RESET}"
    
    # ========================================================================
    # PHASE 9: Backup encryption keys
    # ========================================================================
    echo -e "${CLR_YELLOW}Phase 9: Backing up encryption keys...${CLR_RESET}"
    
    log_message "Creating backup directory for encryption keys"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "mkdir -p $zfs_backup_keys_path && chmod 700 $zfs_backup_keys_path" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    log_message "Copying encryption keys to backup location"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "cp /.data.key $zfs_backup_keys_path/ && cp /.var-lib-vz.key $zfs_backup_keys_path/" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    log_message "Creating passphrase reminder file"
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
        "echo 'Root pool (rpool/ROOT) passphrase: [MANUALLY RECORDED BY ADMINISTRATOR]' > $zfs_backup_keys_path/README.txt && echo 'Keyfiles: /.data.key and /.var-lib-vz.key' >> $zfs_backup_keys_path/README.txt" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
    
    echo -e "${CLR_GREEN}✓ Encryption keys backed up to $zfs_backup_keys_path${CLR_RESET}"
    echo -e "${CLR_RED}CRITICAL: Download these keys to a secure location!${CLR_RESET}"
    echo -e "${CLR_YELLOW}Keyfiles location on server:${CLR_RESET}"
    echo -e "${CLR_YELLOW}  - /.data.key (rpool/data encryption)${CLR_RESET}"
    echo -e "${CLR_YELLOW}  - /.var-lib-vz.key (rpool/var-lib-vz encryption)${CLR_RESET}"
    echo -e "${CLR_YELLOW}  - Backup: $zfs_backup_keys_path/${CLR_RESET}"
    
    # ========================================================================
    # PHASE 10: Setup dropbear for remote unlock (if enabled)
    # ========================================================================
    if [ "$enable_dropbear" = true ]; then
        echo -e "${CLR_YELLOW}Phase 10: Setting up Dropbear SSH for remote unlock...${CLR_RESET}"
        
        log_message "Installing dropbear-initramfs"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
            "DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends dropbear-initramfs" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
        
        echo -e "${CLR_GREEN}✓ Dropbear installed${CLR_RESET}"
        
        # Configure dropbear authorized keys
        if [ -n "$dropbear_authorized_keys" ] && [ -f "$dropbear_authorized_keys" ]; then
            log_message "Copying authorized_keys for dropbear"
            scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P $SSHPORT \
                "$dropbear_authorized_keys" root@$SSHIP:/etc/dropbear/initramfs/authorized_keys 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
            echo -e "${CLR_GREEN}✓ Dropbear authorized_keys configured${CLR_RESET}"
        else
            log_message "Copying root SSH keys to dropbear"
            ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
                "mkdir -p /etc/dropbear/initramfs && cp /root/.ssh/authorized_keys /etc/dropbear/initramfs/authorized_keys 2>/dev/null || echo 'WARNING: No authorized_keys found'" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
        fi
        
        # Configure dropbear port
        log_message "Configuring dropbear port: $dropbear_port"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
            "echo 'DROPBEAR_OPTIONS=\"-p $dropbear_port\"' > /etc/dropbear/initramfs/dropbear.conf" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
        
        # Get network configuration for initramfs
        log_message "Configuring initramfs network settings"
        
        # Extract network info from current configuration
        INIT_IP="$MAIN_IPV4_CIDR"
        INIT_GW="$MAIN_IPV4_GW"
        INIT_HOSTNAME=$(ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "hostname" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)")
        
        # Calculate netmask from CIDR
        if [[ "$INIT_IP" =~ /([0-9]+)$ ]]; then
            CIDR_BITS="${BASH_REMATCH[1]}"
            # Convert CIDR to netmask (simplified for common values)
            case "$CIDR_BITS" in
                24) INIT_NETMASK="255.255.255.0" ;;
                25) INIT_NETMASK="255.255.255.128" ;;
                26) INIT_NETMASK="255.255.255.192" ;;
                27) INIT_NETMASK="255.255.255.224" ;;
                28) INIT_NETMASK="255.255.255.240" ;;
                29) INIT_NETMASK="255.255.255.248" ;;
                30) INIT_NETMASK="255.255.255.252" ;;
                *) INIT_NETMASK="255.255.255.0" ;;  # Default fallback
            esac
            INIT_IP="${INIT_IP%/*}"  # Remove CIDR notation
        fi
        
        log_message "Initramfs network config: IP=$INIT_IP, GW=$INIT_GW, Netmask=$INIT_NETMASK"
        
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
            "echo -e '\n# Network configuration for Dropbear remote unlock\nIP=${INIT_IP}::${INIT_GW}:${INIT_NETMASK}:${INIT_HOSTNAME}' >> /etc/initramfs-tools/initramfs.conf" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
        
        echo -e "${CLR_GREEN}✓ Dropbear network configured${CLR_RESET}"
        
        # Create unlock helper script
        log_message "Creating zfsunlock helper script"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP "cat > /usr/local/bin/zfsunlock << 'UNLOCK_EOF'
#!/bin/sh
# Helper script for ZFS unlock in initramfs environment
echo \"Unlocking encrypted ZFS filesystems...\"
echo \"Enter the password or press Ctrl-C to exit.\"
echo \"\"
echo \"🔐 Encrypted ZFS password for rpool/ROOT:\"
zfs load-key -a && echo \"Password for rpool/ROOT accepted.\" || echo \"Failed to unlock. Please try again.\"
echo \"Unlocking complete. Resuming boot sequence...\"
echo \"Please reconnect in a while.\"
killall dropbear
UNLOCK_EOF
chmod +x /usr/local/bin/zfsunlock" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"

        echo -e "${CLR_GREEN}✓ zfsunlock helper script created${CLR_RESET}"
        
        # Update initramfs
        log_message "Updating initramfs with Dropbear configuration"
        echo -e "${CLR_CYAN}Updating initramfs (this may take a few minutes)...${CLR_RESET}"
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p $SSHPORT root@$SSHIP \
            "update-initramfs -u -k all" 2>&1 | grep -E -v "(Warning: Permanently added |Connection to $SSHIP closed)"
        
        echo -e "${CLR_GREEN}✓ Dropbear configured for remote unlock${CLR_RESET}"
        echo -e "${CLR_YELLOW}Remote unlock details:${CLR_RESET}"
        echo -e "${CLR_YELLOW}  - SSH to: $PUBLIC_IPV4 -p $dropbear_port${CLR_RESET}"
        echo -e "${CLR_YELLOW}  - Run: zfsunlock${CLR_RESET}"
        echo -e "${CLR_YELLOW}  - Enter your root passphrase${CLR_RESET}"
    else
        echo -e "${CLR_YELLOW}Phase 10: Dropbear remote unlock disabled${CLR_RESET}"
    fi
    
    # ========================================================================
    # PHASE 11: Final summary and instructions
    # ========================================================================
    echo ""
    echo -e "${CLR_GREEN}==================================================================${CLR_RESET}"
    echo -e "${CLR_GREEN}     ZFS Full Disk Encryption Setup Complete!${CLR_RESET}"
    echo -e "${CLR_GREEN}==================================================================${CLR_RESET}"
    echo ""
    echo -e "${CLR_CYAN}Encryption Summary:${CLR_RESET}"
    echo -e "${CLR_YELLOW}  ✓ rpool/ROOT:      Passphrase-encrypted (manual unlock required at boot)${CLR_RESET}"
    echo -e "${CLR_YELLOW}  ✓ rpool/data:      Keyfile-encrypted (auto-unlock on boot)${CLR_RESET}"
    echo -e "${CLR_YELLOW}  ✓ rpool/var-lib-vz: Keyfile-encrypted (auto-unlock on boot)${CLR_RESET}"
    echo ""
    echo -e "${CLR_RED}⚠️  CRITICAL INFORMATION - READ CAREFULLY ⚠️${CLR_RESET}"
    echo ""
    echo -e "${CLR_YELLOW}1. Root Pool Passphrase:${CLR_RESET}"
    echo -e "   Your root pool is encrypted with the passphrase you provided."
    echo -e "   ${CLR_RED}YOU MUST ENTER THIS PASSPHRASE AT EVERY BOOT${CLR_RESET}"
    echo -e "   ${CLR_RED}IF YOU LOSE THIS PASSPHRASE, YOUR DATA IS UNRECOVERABLE!${CLR_RESET}"
    echo ""
    echo -e "${CLR_YELLOW}2. Encryption Keyfiles:${CLR_RESET}"
    echo -e "   Keyfiles are stored at:"
    echo -e "   - /.data.key"
    echo -e "   - /.var-lib-vz.key"
    echo -e "   ${CLR_RED}BACKUP THESE FILES IMMEDIATELY to a secure, offline location!${CLR_RESET}"
    echo -e "   Backup location on server: $zfs_backup_keys_path"
    echo ""
    echo -e "${CLR_YELLOW}3. Boot Process:${CLR_RESET}"
    if [ "$enable_dropbear" = true ]; then
        echo -e "   At boot, the server will wait for root pool unlock:"
        echo -e "   - SSH to: ${CLR_CYAN}ssh root@$PUBLIC_IPV4 -p $dropbear_port${CLR_RESET}"
        echo -e "   - Run: ${CLR_CYAN}zfsunlock${CLR_RESET}"
        echo -e "   - Enter your root passphrase"
        echo -e "   - Wait for system to complete boot"
    else
        echo -e "   ${CLR_RED}Dropbear is NOT configured - you will need console/KVM access to unlock!${CLR_RESET}"
        echo -e "   Consider running with --enable-dropbear for remote unlock capability"
    fi
    echo ""
    echo -e "${CLR_YELLOW}4. Testing Encryption:${CLR_RESET}"
    echo -e "   Before shutting down, verify encryption with:"
    echo -e "   ${CLR_CYAN}zfs get encryption -r rpool${CLR_RESET}"
    echo ""
    echo -e "${CLR_YELLOW}5. Log File:${CLR_RESET}"
    echo -e "   Detailed logs available at: ${CLR_CYAN}$ZFS_ENCRYPTION_LOG${CLR_RESET}"
    echo ""
    echo -e "${CLR_GREEN}==================================================================${CLR_RESET}"
    
    log_message "ZFS encryption setup completed successfully"
    
    return 0
}

# [... Continue with all other existing functions from original script ...]
# These remain unchanged: add_ssh_key_to_authorized_keys, change_ssh_port,
# disable_rpcbind, snat_zone, install_iptables_rule, update_locale_gen,
# set_network, configure_network_interface, show_block_devices,
# show_network_interfaces, generate_answer_toml, is_uefi_mode,
# download_latest_proxmox_iso, create_autoinstall_iso, check_ssh_server,
# order_acme_certificate, register_acme_account, add_tun_lxc_device,
# run_tteck_post-pve-install, setup_private_subnet, install_zabbix_agent

# [Copy all existing functions here - they remain unchanged]

# NOTE: In the plugin execution section at the end of the script,
# the setup_zfs_encryption plugin will be automatically called if encryption is enabled
