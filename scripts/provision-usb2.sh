#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — USB 2 (Program Drive) Provisioning
# Formats, encrypts, clones ThreadCount, and exports Docker images.
# Prerequisite: Docker installed on the provisioning machine.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     USB 2 (Program Drive) Provisioning               ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Identify device
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL
echo ""
read -rp "Enter the USB 2 device (e.g., /dev/sdb): " DEVICE

if [[ ! -b "$DEVICE" ]]; then
    echo -e "${RED}Device $DEVICE does not exist. Aborting.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}WARNING: This will ERASE ALL DATA on $DEVICE${NC}"
echo -e "${YELLOW}Device: $(lsblk -ndo MODEL,SIZE "$DEVICE" 2>/dev/null)${NC}"
read -rp "Type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# Wipe with random data
echo -e "${CYAN}Wiping drive with random data (this may take a while)...${NC}"
sudo dd if=/dev/urandom of="$DEVICE" bs=4M status=progress 2>/dev/null || true

# LUKS format
echo ""
echo -e "${CYAN}Creating LUKS2 encrypted container...${NC}"
echo -e "${YELLOW}You will be prompted to set a passphrase for this drive.${NC}"
sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --label SOVEREIGN_PROGRAM \
    "$DEVICE"

# Open and format
echo -e "${CYAN}Opening LUKS container...${NC}"
sudo cryptsetup luksOpen "$DEVICE" sovereign_program

echo -e "${CYAN}Formatting as ext4...${NC}"
sudo mkfs.ext4 -L SOVEREIGN_PROGRAM /dev/mapper/sovereign_program

# Mount
MOUNT_TMP="/tmp/sovereign-usb2-provision"
sudo mkdir -p "$MOUNT_TMP"
sudo mount /dev/mapper/sovereign_program "$MOUNT_TMP"
sudo chown "$(whoami):$(whoami)" "$MOUNT_TMP"

# Clone ThreadCount
echo -e "${CYAN}Cloning ThreadCount repository...${NC}"
git clone https://github.com/steeldragon666/threadcount "$MOUNT_TMP/threadcount"

# Build Docker images
echo -e "${CYAN}Building Docker images (this will take several minutes)...${NC}"
cd "$MOUNT_TMP/threadcount"
docker compose build

# Export images
echo -e "${CYAN}Exporting Docker images as tarballs...${NC}"
mkdir -p "$MOUNT_TMP/images"

docker save sovereign-api:latest       -o "$MOUNT_TMP/images/sovereign-api.tar" 2>/dev/null || \
docker save threadcount-api:latest     -o "$MOUNT_TMP/images/sovereign-api.tar"

docker save sovereign-bot:latest       -o "$MOUNT_TMP/images/sovereign-bot.tar" 2>/dev/null || \
docker save threadcount-bot:latest     -o "$MOUNT_TMP/images/sovereign-bot.tar"

docker save sovereign-dashboard:latest -o "$MOUNT_TMP/images/sovereign-dashboard.tar" 2>/dev/null || \
docker save threadcount-dashboard:latest -o "$MOUNT_TMP/images/sovereign-dashboard.tar"

docker save caddy:2-alpine             -o "$MOUNT_TMP/images/caddy.tar"
docker save postgres:16-alpine         -o "$MOUNT_TMP/images/postgres.tar"
docker save redis:7-alpine             -o "$MOUNT_TMP/images/redis.tar"
docker save osminogin/tor-simple:latest -o "$MOUNT_TMP/images/tor-simple.tar"

cd "$MOUNT_TMP"

# Generate integrity manifest
echo -e "${CYAN}Generating integrity manifest...${NC}"
find . -type f ! -name 'MANIFEST.sha256' -exec sha256sum {} \; > MANIFEST.sha256

# Print summary
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          USB 2 PROVISIONING COMPLETE                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Contents:"
ls -lh "$MOUNT_TMP/images/"
echo ""
echo "Drive UUID (add to drive-uuids.conf):"
PROGRAM_UUID=$(blkid -s UUID -o value /dev/mapper/sovereign_program)
echo "  $PROGRAM_UUID"
echo ""

# Unmount and close
sync
cd /
sudo umount "$MOUNT_TMP"
sudo cryptsetup luksClose sovereign_program
rmdir "$MOUNT_TMP"

echo -e "${GREEN}Done. LUKS closed. Drive safe to remove.${NC}"
