# Proxmox Hetzner Instructions

This project installs Proxmox VE on Hetzner (and similar) dedicated servers. It supports a full software stack:

- mdadm RAID1 -> LUKS2 -> LVM -> ext4
- Debian 13 (Trixie) base via debootstrap
- Proxmox VE 9 packages
- BIOS + UEFI boot support (GPT with bios_grub + ESP)
- Remote unlock via dropbear-initramfs

## Quick Start (RAID1 + LUKS + LVM, no ISO/QEMU)

Run from the Hetzner rescue system:

```
./install-proxmox.sh --raid-luks-install \
  --disks sda,sdb \
  --luks-passphrase 'YOUR-LUKS-PASSPHRASE' \
  --ssh-key /root/.ssh/id_rsa.pub
```

This will:
- Wipe both disks
- Create BIOS + UEFI boot partitions
- Create RAID1 arrays for /boot and root
- Encrypt root with LUKS2
- Create LVM volumes (root/swap/data)
- Bootstrap Debian 13 and install Proxmox VE 9
- Configure GRUB + initramfs + dropbear

## Disk Layout (per disk)

GPT partitions on each disk:

1) bios_grub (1–2 MiB, no FS)
2) ESP (512 MiB, FAT32)
3) /boot RAID1 member (ext4, 1 GiB)
4) root RAID1 member (rest of disk)

Arrays:
- /dev/md1 -> /boot (RAID1, metadata 1.0)
- /dev/md0 -> LUKS2 -> LVM (root/swap/data)

## Defaults and Size Logic

Defaults:
- /boot: 1G
- ESP: 512M
- root: 50G
- swap: 8G

If total usable disk size (after RAID) is < 100G, the script prompts for root/swap sizes even if defaults are provided.

Override with:
- `--root-size 60G`
- `--swap-size 16G`
- `--boot-size 2G`
- `--efi-size 1G`

## Core Flags (Helper Script)

```
--disks sda,sdb
--luks-passphrase PASS
--root-size SIZE
--swap-size SIZE
--boot-size SIZE
--efi-size SIZE
--vg-name NAME
--crypt-name NAME
--md-name NAME          # root RAID (default md0)
--md-boot-name NAME     # /boot RAID (default md1)
--hostname NAME
--timezone TZ
--ssh-key /path/to/key.pub
--dropbear-port PORT    # default 2222
--agent-user USER       # writes /home/USER/AGENT.md (or /root/AGENT.md)
--yes                   # skip confirmations (except size prompt <100G)
```

## Proxmox Repository

The helper script enforces **pve-no-subscription** only and removes any enterprise repo entries in the target install.

## Remote Unlock (Dropbear)

After reboot:

```
ssh -p 2222 root@<server-ip>
cryptroot-unlock
```

If you pass `--dropbear-port`, adjust the port accordingly.

## IPv6 Support

If a global IPv6 address and gateway are detected in rescue, the helper script:

- Writes IPv6 config for `vmbr0`
- Adds an initramfs script to bring IPv6 up before dropbear

If no IPv6 is detected, only IPv4 is configured.

## AGENT.md Location

`AGENT.md` is created on the **installed server**, not in the repo:

- root user: `/root/AGENT.md`
- other user: `/home/<user>/AGENT.md` when `--agent-user` is set

If you ran `cat AGENT.md` in the repo, it will not exist there by design.

## Safety Notes

- This is a destructive install. All data on target disks will be erased.
- Always install GRUB to **both disks** after disk changes.
- Always run `update-initramfs` after mdadm/crypt/dropbear changes.
- Test dropbear unlock before rebooting a remote-only system.

## Troubleshooting Hints

- If dropbear doesn’t come up: confirm `/etc/crypttab` has `luks,initramfs` and re-run `update-initramfs -u -k all`.
- If boot fails: check `/etc/mdadm/mdadm.conf`, re-install GRUB to both disks.
- If IPv6 unlock fails: IPv4 unlock still works; verify IPv6 gateway and initramfs scripts.

