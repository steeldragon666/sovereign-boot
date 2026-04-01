#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — Post-Install Setup
# Run this ONCE after installing Debian 12 normally onto USB 1.
# It installs Docker, copies all sovereign-boot files, and
# configures auto-login + autostart.
#
# Usage: sudo bash setup-sovereign.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root (use sudo).${NC}"
    exit 1
fi

# Detect the main user (whoever ran sudo)
MAIN_USER="${SUDO_USER:-$(logname 2>/dev/null || echo '')}"
if [[ -z "$MAIN_USER" || "$MAIN_USER" == "root" ]]; then
    echo -e "${YELLOW}Enter the username you created during Debian install:${NC}"
    read -r MAIN_USER
fi
MAIN_HOME="/home/$MAIN_USER"

if [[ ! -d "$MAIN_HOME" ]]; then
    echo -e "${RED}Home directory $MAIN_HOME not found. Check the username.${NC}"
    exit 1
fi

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       Sovereign Security — Post-Install Setup         ║"
echo "║       Installing to user: $MAIN_USER"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ---- Step 1: Install packages ----
echo -e "${CYAN}[1/6] Installing packages...${NC}"
apt-get update
apt-get install -y \
    docker.io \
    docker-compose \
    nftables \
    cryptsetup \
    firefox-esr \
    git \
    curl \
    python3 \
    coreutils \
    --no-install-recommends

# ---- Step 2: Add user to docker group ----
echo -e "${CYAN}[2/6] Configuring Docker...${NC}"
usermod -aG docker "$MAIN_USER"
systemctl enable docker
systemctl start docker

# ---- Step 3: Create sovereign marker file ----
echo -e "${CYAN}[3/6] Creating sovereign boot marker...${NC}"
echo "sovereign-boot-v1" > /etc/sovereign-boot-marker

# ---- Step 4: Copy sovereign-boot scripts ----
echo -e "${CYAN}[4/6] Installing sovereign-boot scripts...${NC}"

# Scripts
mkdir -p "$MAIN_HOME/.local/bin"
cp "$PROJECT_DIR/scripts/sovereign-boot.sh"         "$MAIN_HOME/.local/bin/"
cp "$PROJECT_DIR/scripts/sovereign-health-check.sh"  "$MAIN_HOME/.local/bin/"
cp "$PROJECT_DIR/scripts/unmount-all.sh"             "$MAIN_HOME/.local/bin/"
chmod +x "$MAIN_HOME/.local/bin/"*.sh

# Config
mkdir -p "$MAIN_HOME/.config/sovereign/compose"
cp "$PROJECT_DIR/config/drive-uuids.conf"            "$MAIN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/mount-points.conf"           "$MAIN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/sovereign-firewall.nft"      "$MAIN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/99-sovereign-usb.rules"      "$MAIN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/compose/docker-compose.sovereign.yml" "$MAIN_HOME/.config/sovereign/compose/"

# XDG autostart
mkdir -p "$MAIN_HOME/.config/autostart"
cp "$PROJECT_DIR/desktop/sovereign-boot.desktop"     "$MAIN_HOME/.config/autostart/"

# Fix the desktop entry to use the correct user home path
sed -i "s|/home/sovereign|$MAIN_HOME|g" "$MAIN_HOME/.config/autostart/sovereign-boot.desktop"

# Fix the boot script to use correct config dir
sed -i "s|/home/sovereign|$MAIN_HOME|g" "$MAIN_HOME/.local/bin/sovereign-boot.sh"

# Set ownership
chown -R "$MAIN_USER:$MAIN_USER" "$MAIN_HOME/.local" "$MAIN_HOME/.config"

# ---- Step 5: System hardening ----
echo -e "${CYAN}[5/6] Hardening system...${NC}"

# Disable Bluetooth
systemctl disable bluetooth.service 2>/dev/null || true
systemctl mask bluetooth.service 2>/dev/null || true

# Disable IPv6
if ! grep -q "disable_ipv6" /etc/sysctl.d/99-sovereign.conf 2>/dev/null; then
    cat > /etc/sysctl.d/99-sovereign.conf << 'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
fi

# Disable swap permanently
swapoff -a 2>/dev/null || true
sed -i '/swap/d' /etc/fstab 2>/dev/null || true

# Enable nftables
systemctl enable nftables 2>/dev/null || true

# Configure sudo for sovereign commands (no password for mount/cryptsetup)
cat > "/etc/sudoers.d/sovereign" << SUDO
$MAIN_USER ALL=(ALL) NOPASSWD: /sbin/cryptsetup, /bin/mount, /bin/umount, /sbin/nft, /bin/chmod, /sbin/swapoff, /bin/cp, /bin/chown, /bin/mkdir, /sbin/udevadm, /bin/systemctl start docker, /bin/systemctl stop docker
SUDO
chmod 440 "/etc/sudoers.d/sovereign"

# ---- Step 6: Configure auto-login (optional) ----
echo -e "${CYAN}[6/6] Configuring auto-login...${NC}"

# Detect display manager
if command -v lightdm &>/dev/null; then
    mkdir -p /etc/lightdm/lightdm.conf.d
    cat > /etc/lightdm/lightdm.conf.d/50-sovereign.conf << LDM
[Seat:*]
autologin-user=$MAIN_USER
autologin-user-timeout=0
LDM
    echo "  LightDM auto-login configured"
elif command -v gdm3 &>/dev/null; then
    sed -i "s/^#  AutomaticLoginEnable.*/AutomaticLoginEnable = true/" /etc/gdm3/daemon.conf 2>/dev/null || true
    sed -i "s/^#  AutomaticLogin .*/AutomaticLogin = $MAIN_USER/" /etc/gdm3/daemon.conf 2>/dev/null || true
    echo "  GDM auto-login configured"
else
    echo -e "${YELLOW}  No display manager detected — auto-login not configured${NC}"
    echo "  You can set it up manually later"
fi

# ---- Done ----
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          SETUP COMPLETE                              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "What was installed:"
echo "  ✓ Docker + Docker Compose"
echo "  ✓ nftables firewall"
echo "  ✓ Sovereign boot scripts in $MAIN_HOME/.local/bin/"
echo "  ✓ Config files in $MAIN_HOME/.config/sovereign/"
echo "  ✓ XDG autostart for sovereign-boot.sh"
echo "  ✓ System hardening (no swap, no bluetooth, no IPv6)"
echo "  ✓ Auto-login configured"
echo ""
echo "Next steps:"
echo "  1. Reboot to verify auto-login and sovereign-boot.sh launches"
echo "  2. Run provision-usb2.sh to set up the program drive"
echo "  3. Run provision-usb3.sh to set up the Apricorn data drive"
echo "  4. Update ~/.config/sovereign/drive-uuids.conf with real UUIDs"
echo ""
