#!/bin/bash

# ============================================================
# Rebuild USB 2 (Program Drive) — One Shot
# Run with: sudo bash rebuild-usb2.sh
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "Run with: sudo bash $0"
    exit 1
fi

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       REBUILD USB 2 — PROGRAM DRIVE                  ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
echo "This will WIPE a USB drive and set it up as the"
echo "encrypted program drive with ThreadCount."
echo ""

# Show available drives
echo "Available drives:"
echo ""
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL | grep -E "disk|NAME"
echo ""

# Let user pick
echo -n "Enter the device name (e.g. sda, sdb, sdc): "
read -r DEVNAME
DEVICE="/dev/$DEVNAME"

if [[ ! -b "$DEVICE" ]]; then
    echo "ERROR: $DEVICE is not a valid block device."
    exit 1
fi

SIZE=$(lsblk -bno SIZE "$DEVICE" 2>/dev/null | head -1)
SIZE_GB=$((SIZE / 1073741824))
MODEL=$(lsblk -no MODEL "$DEVICE" 2>/dev/null | head -1)

echo ""
echo "  Selected: $DEVICE ($SIZE_GB GB) $MODEL"
echo ""
echo "  *** ALL DATA ON $DEVICE WILL BE DESTROYED ***"
echo ""
echo -n "Type YES to continue: "
read -r CONFIRM
if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# ---- STEP 1: CLEAN UP ----
echo ""
echo "[1/8] Cleaning up..."
umount "${DEVICE}"* 2>/dev/null || true
if [[ -e /dev/mapper/sovereign_program ]]; then
    umount /mnt/sovereign/program 2>/dev/null || true
    cryptsetup luksClose sovereign_program 2>/dev/null || true
fi
wipefs -a "$DEVICE" 2>/dev/null || true
dd if=/dev/zero of="$DEVICE" bs=1M count=10 2>/dev/null
echo "  ✓ Drive wiped"

# ---- STEP 2: LUKS FORMAT ----
echo ""
echo "[2/8] Creating LUKS encryption..."
echo "  Enter a passphrase for the program drive."
echo "  YOU MUST REMEMBER THIS — it's needed every boot."
echo ""
if ! cryptsetup luksFormat --type luks2 "$DEVICE"; then
    echo "  ERROR: LUKS format failed."
    exit 1
fi
echo "  ✓ LUKS created"

# ---- STEP 3: OPEN AND FORMAT ----
echo ""
echo "[3/8] Opening and formatting..."
if ! cryptsetup luksOpen "$DEVICE" sovereign_program; then
    echo "  ERROR: Could not open LUKS."
    exit 1
fi
mkfs.ext4 -L SOVEREIGN-PROG /dev/mapper/sovereign_program
echo "  ✓ Filesystem created"

# ---- STEP 4: MOUNT ----
echo ""
echo "[4/8] Mounting..."
mkdir -p /mnt/sovereign/program
mount /dev/mapper/sovereign_program /mnt/sovereign/program
echo "  ✓ Mounted at /mnt/sovereign/program"

# ---- STEP 5: CLONE THREADCOUNT ----
echo ""
echo "[5/8] Cloning ThreadCount..."
git clone https://github.com/steeldragon666/threadcount.git /mnt/sovereign/program/threadcount
echo "POSTGRES_PASSWORD=buildonly" > /mnt/sovereign/program/threadcount/.env
echo "  ✓ ThreadCount cloned"

# ---- STEP 6: BUILD DOCKER IMAGES ----
echo ""
echo "[6/8] Building Docker images (this takes a few minutes)..."

if ! systemctl is-active --quiet docker; then
    systemctl start docker
    sleep 3
fi

cd /mnt/sovereign/program/threadcount
docker compose build

if [[ $? -ne 0 ]]; then
    echo "  ERROR: Docker build failed."
    exit 1
fi
echo "  ✓ Images built"

# ---- STEP 7: SAVE IMAGES ----
echo ""
echo "[7/8] Saving Docker images as tarballs..."
mkdir -p /mnt/sovereign/program/images

docker save threadcount-api:latest -o /mnt/sovereign/program/images/api.tar
echo "  ✓ api.tar"
docker save threadcount-bot:latest -o /mnt/sovereign/program/images/bot.tar
echo "  ✓ bot.tar"
docker save threadcount-dashboard:latest -o /mnt/sovereign/program/images/dashboard.tar
echo "  ✓ dashboard.tar"

docker pull postgres:16
docker save postgres:16 -o /mnt/sovereign/program/images/postgres.tar
echo "  ✓ postgres.tar"

docker pull redis:7-alpine
docker save redis:7-alpine -o /mnt/sovereign/program/images/redis.tar
echo "  ✓ redis.tar"

docker pull caddy:2-alpine
docker save caddy:2-alpine -o /mnt/sovereign/program/images/caddy.tar
echo "  ✓ caddy.tar"

# Generate manifest
cd /mnt/sovereign/program
sha256sum images/*.tar > MANIFEST.sha256
echo "  ✓ MANIFEST.sha256 generated"

# ---- STEP 8: CLEANUP AND CLOSE ----
echo ""
echo "[8/8] Cleaning up and closing..."
rm -f /mnt/sovereign/program/threadcount/.env
cd /
sync
umount /mnt/sovereign/program
cryptsetup luksClose sovereign_program

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       USB 2 PROGRAM DRIVE — READY                    ║"
echo "║       You may remove the drive.                      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
