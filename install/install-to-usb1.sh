#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — USB 1 (Boot Drive) Installation
# Creates a bootable, LUKS-encrypted Debian 12 USB with all
# sovereign boot infrastructure pre-installed.
#
# MUST be run as root from an existing Debian/Ubuntu system.
# Requires: debootstrap, cryptsetup, parted, grub, arch-chroot
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${NC}"
    exit 1
fi

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     USB 1 (Boot Drive) — Debian 12 Installation      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check dependencies
for cmd in debootstrap cryptsetup parted mkfs.ext4 grub-install; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Missing dependency: $cmd${NC}"
        echo "Install with: apt install debootstrap cryptsetup parted grub-pc grub-efi-amd64-bin"
        exit 1
    fi
done

# Identify device
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL
echo ""
read -rp "Enter the USB 1 device (e.g., /dev/sdb): " DEVICE

if [[ ! -b "$DEVICE" ]]; then
    echo -e "${RED}Device $DEVICE does not exist.${NC}"
    exit 1
fi

echo ""
echo -e "${RED}WARNING: This will COMPLETELY ERASE $DEVICE${NC}"
echo -e "${RED}Device: $(lsblk -ndo MODEL,SIZE "$DEVICE" 2>/dev/null)${NC}"
read -rp "Type DESTROY to continue: " confirm
if [[ "$confirm" != "DESTROY" ]]; then
    echo "Aborted."
    exit 0
fi

# ---- Partition ----
echo -e "${CYAN}Partitioning $DEVICE...${NC}"

# GPT partition table for UEFI
parted -s "$DEVICE" mklabel gpt

# EFI System Partition (512MB)
parted -s "$DEVICE" mkpart primary fat32 1MiB 513MiB
parted -s "$DEVICE" set 1 esp on

# Boot partition (512MB, unencrypted, for GRUB + kernel)
parted -s "$DEVICE" mkpart primary ext4 513MiB 1025MiB

# Root partition (remainder, will be LUKS encrypted)
parted -s "$DEVICE" mkpart primary ext4 1025MiB 100%

# Determine partition names (handle both sdX1 and sdXp1 formats)
if [[ -b "${DEVICE}1" ]]; then
    EFI_PART="${DEVICE}1"
    BOOT_PART="${DEVICE}2"
    ROOT_PART="${DEVICE}3"
elif [[ -b "${DEVICE}p1" ]]; then
    EFI_PART="${DEVICE}p1"
    BOOT_PART="${DEVICE}p2"
    ROOT_PART="${DEVICE}p3"
else
    sleep 2
    partprobe "$DEVICE"
    EFI_PART="${DEVICE}1"
    BOOT_PART="${DEVICE}2"
    ROOT_PART="${DEVICE}3"
fi

# ---- LUKS Encrypt Root ----
echo ""
echo -e "${CYAN}Encrypting root partition with LUKS2...${NC}"
echo -e "${YELLOW}You will be prompted to set the boot passphrase.${NC}"
cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    "$ROOT_PART"

cryptsetup luksOpen "$ROOT_PART" sovereign_root

# ---- Format Partitions ----
echo -e "${CYAN}Formatting partitions...${NC}"
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -L SOVEREIGN_BOOT "$BOOT_PART"
mkfs.ext4 -L SOVEREIGN_ROOT /dev/mapper/sovereign_root

# ---- Mount ----
CHROOT="/tmp/sovereign-usb1"
mkdir -p "$CHROOT"
mount /dev/mapper/sovereign_root "$CHROOT"
mkdir -p "$CHROOT/boot"
mount "$BOOT_PART" "$CHROOT/boot"
mkdir -p "$CHROOT/boot/efi"
mount "$EFI_PART" "$CHROOT/boot/efi"

# ---- Debootstrap ----
echo -e "${CYAN}Installing Debian 12 base system (this will take several minutes)...${NC}"
debootstrap --arch=amd64 bookworm "$CHROOT" http://deb.debian.org/debian

# ---- Configure ----
echo -e "${CYAN}Configuring system...${NC}"

# fstab
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/sovereign_root)
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat > "$CHROOT/etc/fstab" << FSTAB
# Sovereign Boot — /etc/fstab
UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0 1
UUID=$BOOT_UUID  /boot      ext4  defaults           0 2
UUID=$EFI_UUID   /boot/efi  vfat  umask=0077         0 1
tmpfs            /tmp       tmpfs defaults,noexec,nosuid,size=2G  0 0
FSTAB

# crypttab
cat > "$CHROOT/etc/crypttab" << CRYPTTAB
sovereign_root UUID=$LUKS_UUID none luks
CRYPTTAB

# hostname
echo "sovereign" > "$CHROOT/etc/hostname"

# Marker file (sovereign-boot.sh checks for this)
echo "sovereign-boot-v1" > "$CHROOT/etc/sovereign-boot-marker"

# Network (basic DHCP via NetworkManager)
cat > "$CHROOT/etc/network/interfaces" << NET
auto lo
iface lo inet loopback
NET

# Sources list
cat > "$CHROOT/etc/apt/sources.list" << SOURCES
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
SOURCES

# ---- Chroot and install packages ----
mount --bind /dev "$CHROOT/dev"
mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"

chroot "$CHROOT" /bin/bash << 'CHROOTSCRIPT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Update and install packages
apt-get update
apt-get install -y \
    linux-image-amd64 \
    grub-efi-amd64 \
    cryptsetup \
    cryptsetup-initramfs \
    lvm2 \
    docker.io \
    docker-compose-plugin \
    nftables \
    xfce4 \
    xfce4-terminal \
    xfce4-screensaver \
    lightdm \
    firefox-esr \
    network-manager \
    sudo \
    udev \
    coreutils \
    shred \
    openssh-client \
    gnupg \
    curl \
    git \
    python3 \
    --no-install-recommends

# Remove unnecessary services
apt-get remove -y --purge \
    avahi-daemon \
    cups \
    bluetooth \
    bluez \
    2>/dev/null || true
apt-get autoremove -y

# Create sovereign user
useradd -m -s /bin/bash -G sudo,docker sovereign
echo "sovereign:sovereign" | chpasswd

# Configure sudo without password for specific commands
cat > /etc/sudoers.d/sovereign << 'SUDO'
sovereign ALL=(ALL) NOPASSWD: /sbin/cryptsetup, /bin/mount, /bin/umount, /sbin/nft, /bin/chmod, /sbin/swapoff, /bin/cp, /bin/chown, /bin/mkdir, /sbin/udevadm, /bin/systemctl start docker, /bin/systemctl stop docker
SUDO

# LightDM auto-login
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-sovereign.conf << 'LDM'
[Seat:*]
autologin-user=sovereign
autologin-user-timeout=0
user-session=xfce
LDM

# Disable IPv6 (Tor uses IPv4)
cat >> /etc/sysctl.d/99-sovereign.conf << 'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL

# Disable Bluetooth
systemctl disable bluetooth.service 2>/dev/null || true
systemctl mask bluetooth.service 2>/dev/null || true

# Enable Docker and NetworkManager
systemctl enable docker
systemctl enable NetworkManager

# Enable nftables
systemctl enable nftables

# Update initramfs (includes cryptsetup for LUKS boot)
update-initramfs -u -k all

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=sovereign --removable
update-grub

CHROOTSCRIPT

# ---- Install sovereign-boot files ----
echo -e "${CYAN}Installing sovereign boot scripts...${NC}"

SOVEREIGN_HOME="$CHROOT/home/sovereign"

# Scripts
mkdir -p "$SOVEREIGN_HOME/.local/bin"
cp "$PROJECT_DIR/scripts/sovereign-boot.sh"        "$SOVEREIGN_HOME/.local/bin/"
cp "$PROJECT_DIR/scripts/sovereign-health-check.sh" "$SOVEREIGN_HOME/.local/bin/"
cp "$PROJECT_DIR/scripts/unmount-all.sh"            "$SOVEREIGN_HOME/.local/bin/"
chmod +x "$SOVEREIGN_HOME/.local/bin/"*.sh

# Config
mkdir -p "$SOVEREIGN_HOME/.config/sovereign/compose"
cp "$PROJECT_DIR/config/drive-uuids.conf"        "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/mount-points.conf"        "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/sovereign-firewall.nft"   "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/99-sovereign-usb.rules"   "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/compose/docker-compose.sovereign.yml" "$SOVEREIGN_HOME/.config/sovereign/compose/"

# XDG autostart
mkdir -p "$SOVEREIGN_HOME/.config/autostart"
cp "$PROJECT_DIR/desktop/sovereign-boot.desktop"  "$SOVEREIGN_HOME/.config/autostart/"

# Set ownership
chroot "$CHROOT" chown -R sovereign:sovereign /home/sovereign

# ---- Cleanup ----
echo -e "${CYAN}Cleaning up...${NC}"
umount "$CHROOT/dev/pts"
umount "$CHROOT/dev"
umount "$CHROOT/proc"
umount "$CHROOT/sys"
umount "$CHROOT/boot/efi"
umount "$CHROOT/boot"
umount "$CHROOT"
cryptsetup luksClose sovereign_root
rmdir "$CHROOT"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          USB 1 INSTALLATION COMPLETE                 ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║  Boot from this USB via F12 boot menu.               ║${NC}"
echo -e "${GREEN}║  LUKS passphrase required at GRUB.                   ║${NC}"
echo -e "${GREEN}║  Auto-login → Xfce → sovereign-boot.sh              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  1. Boot from USB 1 to test it works"
echo "  2. Run provision-usb2.sh to set up the program drive"
echo "  3. Run provision-usb3.sh to set up the Apricorn data drive"
echo "  4. Update config/drive-uuids.conf with discovered UUIDs"
echo "  5. Update config/99-sovereign-usb.rules with drive serial numbers"
