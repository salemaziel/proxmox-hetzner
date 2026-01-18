#!/bin/bash

set -euo pipefail

CLR_RED='\033[0;31m'
CLR_GREEN='\033[0;32m'
CLR_YELLOW='\033[1;33m'
CLR_CYAN='\033[0;36m'
CLR_RESET='\033[0m'

die() {
    echo -e "${CLR_RED}✗ $*${CLR_RESET}" >&2
    exit 1
}

log() {
    echo -e "${CLR_CYAN}==> $*${CLR_RESET}"
}

confirm() {
    local prompt="$1"
    if [ "$yes_to_all" = true ]; then
        return 0
    fi
    read -r -p "$prompt (yes/no): " reply
    case "$reply" in
        yes|y) return 0;;
        *) return 1;;
    esac
}

to_mib() {
    numfmt --from=iec --to-unit=1MiB "$1"
}

cidr_to_netmask() {
    local cidr="$1"
    local full=$((cidr / 8))
    local rem=$((cidr % 8))
    local i
    local mask=""
    for i in 1 2 3 4; do
        if [ "$i" -le "$full" ]; then
            mask+="255"
        elif [ "$i" -eq $((full + 1)) ] && [ "$rem" -ne 0 ]; then
            mask+=$((256 - (1 << (8 - rem))))
        else
            mask+="0"
        fi
        [ "$i" -lt 4 ] && mask+="."
    done
    echo "$mask"
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Installs Proxmox VE 9 on Debian 13 (Trixie) with:
  mdadm RAID1 -> LUKS2 -> LVM -> ext4
Supports BIOS-only and UEFI by creating both bios_grub and ESP partitions.

Required:
  --luks-passphrase PASS       LUKS passphrase (will prompt if omitted)

Disk selection:
  --disks sda,sdb              Comma-separated disks (e.g., sda,sdb). If omitted, auto-detect.

Sizes (override defaults):
  --root-size SIZE             Default: 50G
  --swap-size SIZE             Default: 8G
  --boot-size SIZE             Default: 1G   (unencrypted /boot on RAID1)
  --efi-size SIZE              Default: 512M (ESP, FAT32 on each disk)

Names:
  --vg-name NAME               Default: pve
  --crypt-name NAME            Default: cryptroot
  --md-name NAME               Default: md0 (root RAID)
  --md-boot-name NAME          Default: md1 (boot RAID)

System:
  --hostname NAME              Default: proxmox
  --timezone TZ                Default: UTC
  --ssh-key PATH               Public key to add to dropbear and root authorized_keys
  --dropbear-port PORT         Default: 2222
  --agent-user USER            Create /home/USER/AGENT.md (or /root/AGENT.md for root)

Misc:
  --yes                        Skip confirmations (except size prompt when <100GB)
  -h, --help                   Show this help
EOF
}

disks_csv=""
luks_passphrase=""
root_size="50G"
swap_size="8G"
boot_size="1G"
efi_size="512M"
vg_name="pve"
crypt_name="cryptroot"
md_root_name="md0"
md_boot_name="md1"
hostname="proxmox"
timezone="UTC"
ssh_key_path=""
dropbear_port="2222"
agent_user="root"
yes_to_all=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disks) disks_csv="$2"; shift 2;;
        --luks-passphrase) luks_passphrase="$2"; shift 2;;
        --root-size) root_size="$2"; shift 2;;
        --swap-size) swap_size="$2"; shift 2;;
        --boot-size) boot_size="$2"; shift 2;;
        --efi-size) efi_size="$2"; shift 2;;
        --vg-name) vg_name="$2"; shift 2;;
        --crypt-name) crypt_name="$2"; shift 2;;
        --md-name) md_root_name="$2"; shift 2;;
        --md-boot-name) md_boot_name="$2"; shift 2;;
        --hostname) hostname="$2"; shift 2;;
        --timezone) timezone="$2"; shift 2;;
        --ssh-key) ssh_key_path="$2"; shift 2;;
        --dropbear-port) dropbear_port="$2"; shift 2;;
        --agent-user) agent_user="$2"; shift 2;;
        --yes) yes_to_all=true; shift;;
        -h|--help) usage; exit 0;;
        *) die "Unknown option: $1";;
    esac
done

if [ -z "$luks_passphrase" ]; then
    read -r -s -p "Enter LUKS passphrase: " luks_passphrase
    echo
    read -r -s -p "Confirm LUKS passphrase: " luks_passphrase_confirm
    echo
    [ "$luks_passphrase" = "$luks_passphrase_confirm" ] || die "Passphrases do not match"
fi

if ! command -v numfmt >/dev/null 2>&1; then
    die "numfmt not found (coreutils). Please install coreutils."
fi

if [ -z "$disks_csv" ]; then
    mapfile -t detected_disks < <(lsblk -dn -o NAME,TYPE,RM | awk '$2=="disk" && $3==0 {print "/dev/"$1}')
    if [ "${#detected_disks[@]}" -ne 2 ]; then
        echo "Detected disks:"
        printf '  %s\n' "${detected_disks[@]}"
        die "Please specify exactly two disks with --disks sda,sdb"
    fi
    disk1="${detected_disks[0]}"
    disk2="${detected_disks[1]}"
else
    IFS=',' read -r d1 d2 <<<"$disks_csv"
    [ -n "$d1" ] && [ -n "$d2" ] || die "Provide two disks via --disks sda,sdb"
    disk1="/dev/$d1"
    disk2="/dev/$d2"
fi

[ -b "$disk1" ] || die "Disk not found: $disk1"
[ -b "$disk2" ] || die "Disk not found: $disk2"
[ "$disk1" != "$disk2" ] || die "Disks must be different"

disk1_bytes=$(lsblk -dn -b -o SIZE "$disk1")
disk2_bytes=$(lsblk -dn -b -o SIZE "$disk2")
min_bytes="$disk1_bytes"
[ "$disk2_bytes" -lt "$min_bytes" ] && min_bytes="$disk2_bytes"
min_gb=$((min_bytes / 1024 / 1024 / 1024))

bios_mib=2
efi_mib=$(to_mib "$efi_size")
boot_mib=$(to_mib "$boot_size")
root_mib=$(to_mib "$root_size")
swap_mib=$(to_mib "$swap_size")
disk_mib=$((min_bytes / 1024 / 1024))

if [ "$min_gb" -lt 100 ]; then
    echo -e "${CLR_YELLOW}Available disk size is < 100GB. You must confirm root and swap sizes.${CLR_RESET}"
    read -r -p "Root size (e.g., 20G): " root_size
    read -r -p "Swap size (e.g., 2G): " swap_size
    root_mib=$(to_mib "$root_size")
    swap_mib=$(to_mib "$swap_size")
fi

required_mib=$((bios_mib + efi_mib + boot_mib + root_mib + swap_mib + 10))
if [ "$required_mib" -ge "$disk_mib" ]; then
    die "Sizes exceed disk capacity. Adjust root/swap/boot sizes."
fi

echo "Target disks: $disk1, $disk2"
echo "Layout: BIOS+UEFI GPT, /boot on RAID1, root on RAID1->LUKS2->LVM"
echo "Sizes: /boot=$boot_size, ESP=$efi_size, root=$root_size, swap=$swap_size"

confirm "This will ERASE all data on $disk1 and $disk2. Continue?" || die "Aborted"

log "Installing prerequisites in rescue environment..."
apt-get update -qq
apt-get install -y --no-install-recommends \
    mdadm lvm2 cryptsetup debootstrap dosfstools gdisk grub-pc-bin grub-efi-amd64-bin \
    iproute2 iputils-ping

log "Wiping disks and creating GPT partitions..."
for disk in "$disk1" "$disk2"; do
    wipefs -a "$disk"
    parted --script --align=optimal "$disk" mklabel gpt
    bios_start=1
    bios_end=$((bios_start + bios_mib))
    efi_start=$bios_end
    efi_end=$((efi_start + efi_mib))
    boot_start=$efi_end
    boot_end=$((boot_start + boot_mib))
    raid_start=$boot_end
    parted --script --align=optimal "$disk" mkpart bios_grub "${bios_start}MiB" "${bios_end}MiB"
    parted --script --align=optimal "$disk" set 1 bios_grub on
    parted --script --align=optimal "$disk" mkpart ESP fat32 "${efi_start}MiB" "${efi_end}MiB"
    parted --script --align=optimal "$disk" set 2 esp on
    parted --script --align=optimal "$disk" mkpart boot ext4 "${boot_start}MiB" "${boot_end}MiB"
    parted --script --align=optimal "$disk" mkpart raid ext4 "${raid_start}MiB" 100%
done

partprobe
udevadm settle --timeout=5 || true

log "Creating RAID1 arrays..."
mdadm --zero-superblock --force "${disk1}3" "${disk2}3" "${disk1}4" "${disk2}4" || true
mdadm --create "/dev/$md_boot_name" --metadata=1.0 --level=1 --raid-devices=2 "${disk1}3" "${disk2}3"
mdadm --create "/dev/$md_root_name" --metadata=1.2 --level=1 --raid-devices=2 "${disk1}4" "${disk2}4"

sleep 2

log "Formatting ESPs and /boot RAID..."
mkfs.vfat -F32 "${disk1}2"
mkfs.vfat -F32 "${disk2}2"
mkfs.ext4 -F "/dev/$md_boot_name"

log "Setting up LUKS2 on /dev/$md_root_name..."
echo -n "$luks_passphrase" | cryptsetup luksFormat --type luks2 "/dev/$md_root_name" -
echo -n "$luks_passphrase" | cryptsetup open "/dev/$md_root_name" "$crypt_name" -

log "Creating LVM volumes..."
pvcreate "/dev/mapper/$crypt_name"
vgcreate "$vg_name" "/dev/mapper/$crypt_name"
lvcreate -L "$root_size" -n root "$vg_name"
lvcreate -L "$swap_size" -n swap "$vg_name"
lvcreate --type thin-pool -l 100%FREE -n data "$vg_name"

log "Formatting filesystems..."
mkfs.ext4 -F "/dev/$vg_name/root"
mkswap -f "/dev/$vg_name/swap"

log "Mounting target filesystem..."
mount "/dev/$vg_name/root" /mnt
mkdir -p /mnt/boot /mnt/boot/efi /mnt/boot/efi2
mount "/dev/$md_boot_name" /mnt/boot
mount "${disk1}2" /mnt/boot/efi
mount "${disk2}2" /mnt/boot/efi2
swapon "/dev/$vg_name/swap"

log "Bootstrapping Debian 13 (Trixie)..."
debootstrap --arch amd64 trixie /mnt http://deb.debian.org/debian

for fs in /dev /dev/pts /proc /sys /run; do
    mount --bind "$fs" "/mnt$fs"
done

cp /etc/resolv.conf /mnt/etc/resolv.conf

log "Configuring base system..."
cat > /mnt/etc/hostname <<EOF
$hostname
EOF

cat >> /mnt/etc/hosts <<EOF
127.0.0.1 localhost
127.0.1.1 $hostname
EOF

chroot /mnt /bin/bash -c "apt-get update -qq && apt-get install -y locales"
chroot /mnt /bin/bash -c "echo 'en_US.UTF-8 UTF-8' >> /etc/locale.gen && locale-gen && update-locale LANG=en_US.UTF-8"
chroot /mnt /bin/bash -c "ln -sf /usr/share/zoneinfo/$timezone /etc/localtime && echo '$timezone' > /etc/timezone"

log "Configuring APT repositories for Proxmox VE 9..."
chroot /mnt /bin/bash -c "install -d -m 0755 /usr/share/keyrings"
chroot /mnt /bin/bash -c "wget -q https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg -O /usr/share/keyrings/proxmox-archive-keyring.gpg"
chroot /mnt /bin/bash -c "rm -f /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-install-repo.list"
cat > /mnt/etc/apt/sources.list.d/pve-install-repo.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: trixie
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF

log "Installing Proxmox VE 9 packages..."
chroot /mnt /bin/bash -c "apt-get update -qq && apt-get full-upgrade -y"
chroot /mnt /bin/bash -c "echo 'postfix postfix/main_mailer_type select No configuration' | debconf-set-selections"
chroot /mnt /bin/bash -c "apt-get install -y proxmox-default-kernel proxmox-ve postfix open-iscsi ifupdown2 chrony mdadm lvm2 cryptsetup-initramfs dropbear-initramfs grub-pc grub-efi-amd64 efibootmgr iproute2"

log "Configuring RAID and encryption for boot..."
md_uuid=$(blkid -s UUID -o value "/dev/$md_root_name")
boot_uuid=$(blkid -s UUID -o value "/dev/$md_boot_name")
efi1_uuid=$(blkid -s UUID -o value "${disk1}2")
swap_uuid=$(blkid -s UUID -o value "/dev/$vg_name/swap")

cat > /mnt/etc/crypttab <<EOF
$crypt_name UUID=$md_uuid none luks,initramfs
EOF

cat > /mnt/etc/fstab <<EOF
UUID=$(blkid -s UUID -o value "/dev/$vg_name/root") / ext4 errors=remount-ro 0 1
UUID=$boot_uuid /boot ext4 defaults 0 2
UUID=$efi1_uuid /boot/efi vfat defaults 0 1
UUID=$swap_uuid none swap sw 0 0
EOF

chroot /mnt /bin/bash -c "mdadm --detail --scan > /etc/mdadm/mdadm.conf"

cat > /mnt/etc/default/grub.d/crypt.cfg <<EOF
GRUB_ENABLE_CRYPTODISK=y
GRUB_CMDLINE_LINUX=\"cryptdevice=/dev/$md_root_name:$crypt_name root=/dev/mapper/$vg_name-root\"
GRUB_PRELOAD_MODULES=\"part_gpt mdraid1x lvm\"
EOF

log "Configuring initramfs dropbear..."
dropbear_dir="/mnt/etc/dropbear/initramfs"
alt_dropbear_dir="/mnt/etc/dropbear-initramfs"
mkdir -p "$dropbear_dir" "$alt_dropbear_dir"
if [ -n "$ssh_key_path" ] && [ -f "$ssh_key_path" ]; then
    cat "$ssh_key_path" >> "$dropbear_dir/authorized_keys"
    cat "$ssh_key_path" >> "$alt_dropbear_dir/authorized_keys"
    chmod 600 "$dropbear_dir/authorized_keys" "$alt_dropbear_dir/authorized_keys"
    mkdir -p /mnt/root/.ssh
    cat "$ssh_key_path" >> /mnt/root/.ssh/authorized_keys
    chmod 600 /mnt/root/.ssh/authorized_keys
fi

default_iface=$(ip -4 route show default | awk '/default/ {print $5; exit}')
main_cidr=$(ip -4 -o addr show dev "$default_iface" | awk '{print $4; exit}')
main_ip=$(echo "$main_cidr" | cut -d'/' -f1)
main_mask_cidr=$(echo "$main_cidr" | cut -d'/' -f2)
main_gw=$(ip -4 route show default | awk '/default/ {print $3; exit}')
main_mask=$(cidr_to_netmask "$main_mask_cidr")

ipv6_cidr=$(ip -6 -o addr show dev "$default_iface" scope global | awk '{print $4; exit}')
ipv6_ip=""
ipv6_prefix=""
ipv6_gw=""
if [ -n "$ipv6_cidr" ]; then
    ipv6_ip=$(echo "$ipv6_cidr" | cut -d'/' -f1)
    ipv6_prefix=$(echo "$ipv6_cidr" | cut -d'/' -f2)
    ipv6_gw=$(ip -6 route show default | awk '/default/ {print $3; exit}')
fi

cat > /mnt/etc/initramfs-tools/conf.d/ip <<EOF
IP=${main_ip}::${main_gw}:${main_mask}:${hostname}:${default_iface}:off
EOF

echo "DROPBEAR_OPTIONS=\"-p $dropbear_port -s -j -k -I 60 -c cryptroot-unlock\"" > "$dropbear_dir/dropbear.conf"
echo "DROPBEAR_OPTIONS=\"-p $dropbear_port -s -j -k -I 60 -c cryptroot-unlock\"" > "$alt_dropbear_dir/config"

if [ -n "$ipv6_ip" ] && [ -n "$ipv6_prefix" ] && [ -n "$ipv6_gw" ]; then
    log "Adding static IPv6 initramfs setup for $ipv6_ip/$ipv6_prefix via $ipv6_gw"
    mkdir -p /mnt/etc/initramfs-tools/hooks /mnt/etc/initramfs-tools/scripts/init-top
    cat > /mnt/etc/initramfs-tools/hooks/iproute2 <<'EOF'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0;;
esac
. /usr/share/initramfs-tools/hook-functions
copy_exec /sbin/ip /sbin
EOF
    chmod +x /mnt/etc/initramfs-tools/hooks/iproute2

    cat > /mnt/etc/initramfs-tools/scripts/init-top/ipv6-static <<EOF
#!/bin/sh
PREREQ=""
prereqs() { echo "\$PREREQ"; }
case "\$1" in
    prereqs) prereqs; exit 0;;
esac
IPV6_ADDR="$ipv6_ip"
IPV6_PREFIX="$ipv6_prefix"
IPV6_GW="$ipv6_gw"
IPV6_IFACE="$default_iface"
if [ -n "\$IPV6_ADDR" ] && [ -n "\$IPV6_PREFIX" ] && [ -n "\$IPV6_GW" ] && [ -n "\$IPV6_IFACE" ]; then
    ip link set "\$IPV6_IFACE" up || true
    ip -6 addr add "\$IPV6_ADDR/\$IPV6_PREFIX" dev "\$IPV6_IFACE" || true
    ip -6 route add default via "\$IPV6_GW" dev "\$IPV6_IFACE" || true
fi
EOF
    chmod +x /mnt/etc/initramfs-tools/scripts/init-top/ipv6-static
fi

log "Updating initramfs and installing GRUB..."
chroot /mnt /bin/bash -c "update-initramfs -u -k all"
chroot /mnt /bin/bash -c "update-grub"
chroot /mnt /bin/bash -c "grub-install --target=i386-pc --recheck $disk1"
chroot /mnt /bin/bash -c "grub-install --target=i386-pc --recheck $disk2"
chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi --removable --no-nvram --recheck"
chroot /mnt /bin/bash -c "grub-install --target=x86_64-efi --efi-directory=/boot/efi2 --removable --no-nvram --recheck"

log "Writing network configuration for Proxmox bridge..."
cat > /mnt/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto $default_iface
iface $default_iface inet manual
iface $default_iface inet6 manual

auto vmbr0
iface vmbr0 inet static
    address $main_ip/$main_mask_cidr
    gateway $main_gw
    bridge-ports $default_iface
    bridge-stp off
    bridge-fd 0
EOF

if [ -n "$ipv6_ip" ] && [ -n "$ipv6_prefix" ] && [ -n "$ipv6_gw" ]; then
    cat >> /mnt/etc/network/interfaces <<EOF

iface vmbr0 inet6 static
    address $ipv6_ip/$ipv6_prefix
    gateway $ipv6_gw
EOF
fi

log "Writing AGENT.md for SSH user..."
agent_home="/root"
if [ "$agent_user" != "root" ]; then
    agent_home="/home/$agent_user"
    mkdir -p "/mnt$agent_home"
fi
cat > "/mnt$agent_home/AGENT.md" <<EOF
# AGENT

This host is Proxmox VE 9 on Debian 13 (Trixie).
Storage stack: mdadm RAID1 -> LUKS2 -> LVM -> ext4
Boot: GPT with bios_grub + ESP, /boot on RAID1, root encrypted

Remote unlock:
  - dropbear-initramfs port: $dropbear_port
  - command: cryptroot-unlock

Key config files:
  - /etc/crypttab
  - /etc/mdadm/mdadm.conf
  - /etc/default/grub.d/crypt.cfg
  - /etc/initramfs-tools/conf.d/ip

Warnings:
  - Install GRUB on both disks after disk changes.
  - Run update-initramfs after crypt/mdadm/dropbear changes.
  - Test remote unlock before rebooting remotely.
EOF

if [ -n "$ipv6_ip" ]; then
    cat >> "/mnt$agent_home/AGENT.md" <<EOF

IPv6:
  - address: $ipv6_ip/$ipv6_prefix
  - gateway: $ipv6_gw
EOF
fi

log "Cleanup..."
for fs in /mnt/dev/pts /mnt/dev /mnt/proc /mnt/sys /mnt/run; do
    umount -l "$fs" || true
done
umount /mnt/boot/efi2 || true
umount /mnt/boot/efi || true
umount /mnt/boot || true
umount /mnt || true
cryptsetup close "$crypt_name" || true
mdadm --stop "/dev/$md_root_name" || true
mdadm --stop "/dev/$md_boot_name" || true

echo -e "${CLR_GREEN}✓ Installation complete.${CLR_RESET}"
echo "Reboot the server. To unlock, SSH to dropbear on port $dropbear_port and run: cryptroot-unlock"
