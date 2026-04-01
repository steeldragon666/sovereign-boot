#!/bin/bash

# ============================================================
# Sovereign Security Boot
# ============================================================
# Run with: sudo bash ~/.local/bin/sovereign-boot.sh
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "Run with: sudo bash $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
CONFIG_DIR="$REAL_HOME/.config/sovereign"
PROGRAM_MOUNT="/mnt/sovereign/program"
DATA_MOUNT="/mnt/sovereign/data"

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║          SOVEREIGN SECURITY BOOT SYSTEM              ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# ---- CLEANUP FROM PREVIOUS RUNS ----
umount -l "$PROGRAM_MOUNT" 2>/dev/null || true
umount -l "$DATA_MOUNT" 2>/dev/null || true
if [[ -e /dev/mapper/sovereign_program ]]; then
    cryptsetup luksClose sovereign_program 2>/dev/null || true
fi
swapoff -a 2>/dev/null || true

# ---- STEP 1: FIND AND MOUNT PROGRAM DRIVE ----
echo "[STEP 1] Looking for LUKS-encrypted program drive..."
echo ""

# Find all LUKS devices
LUKS_DEVICE=""
for dev in /dev/sd?; do
    if [[ -b "$dev" ]] && cryptsetup isLuks "$dev" 2>/dev/null; then
        SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
        SIZE_GB=$((SIZE / 1073741824))
        echo "  Found LUKS device: $dev (${SIZE_GB}GB)"
        LUKS_DEVICE="$dev"
    fi
done

for dev in /dev/sd??; do
    if [[ -b "$dev" ]] && cryptsetup isLuks "$dev" 2>/dev/null; then
        SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
        SIZE_GB=$((SIZE / 1073741824))
        echo "  Found LUKS device: $dev (${SIZE_GB}GB)"
        LUKS_DEVICE="$dev"
    fi
done

if [[ -z "$LUKS_DEVICE" ]]; then
    echo ""
    echo "  No LUKS drive found. Insert the PROGRAM drive and press Enter..."
    read -r
    for dev in /dev/sd? /dev/sd??; do
        if [[ -b "$dev" ]] && cryptsetup isLuks "$dev" 2>/dev/null; then
            LUKS_DEVICE="$dev"
            echo "  Found: $LUKS_DEVICE"
            break
        fi
    done
fi

if [[ -z "$LUKS_DEVICE" ]]; then
    echo "  ERROR: No LUKS drive found. Available devices:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE
    echo ""
    echo "  Plug in the program drive and try again."
    exit 1
fi

echo ""
echo "  Decrypting $LUKS_DEVICE ..."
if ! cryptsetup luksOpen "$LUKS_DEVICE" sovereign_program; then
    echo "  ERROR: Wrong passphrase or drive error."
    exit 1
fi

mkdir -p "$PROGRAM_MOUNT"
if ! mount -o ro /dev/mapper/sovereign_program "$PROGRAM_MOUNT"; then
    echo "  ERROR: Failed to mount program drive."
    cryptsetup luksClose sovereign_program
    exit 1
fi

echo "  ✓ Program drive mounted at $PROGRAM_MOUNT"
echo ""

# ---- STEP 2: LOAD DOCKER IMAGES ----
echo "[STEP 2] Loading Docker images..."

# Make sure Docker is running
if ! systemctl is-active --quiet docker; then
    systemctl start docker
    sleep 3
fi

if [[ -d "$PROGRAM_MOUNT/images" ]]; then
    COUNT=0
    for tar in "$PROGRAM_MOUNT/images/"*.tar; do
        if [[ -f "$tar" ]]; then
            echo "  Loading $(basename "$tar")..."
            docker load -i "$tar" 2>/dev/null
            COUNT=$((COUNT + 1))
        fi
    done
    echo "  ✓ Loaded $COUNT images"
else
    echo "  WARNING: No images/ directory found"
fi
echo ""

# ---- STEP 3: MOUNT DATA DRIVE (APRICORN) ----
echo "[STEP 3] Waiting for data drive (Apricorn)..."
echo ""
echo "  Unlock the Apricorn with its hardware PIN,"
echo "  plug it in, then press Enter..."
read -r

# Find a newly appeared USB drive that isn't the LUKS one
DATA_DEVICE=""
for dev in /dev/sd? /dev/sd??; do
    [[ -b "$dev" ]] || continue
    [[ "$dev" == "$LUKS_DEVICE" ]] && continue
    cryptsetup isLuks "$dev" 2>/dev/null && continue
    # Check if it has a filesystem
    FSTYPE=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1)
    if [[ -n "$FSTYPE" && "$FSTYPE" != "crypto_LUKS" ]]; then
        SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
        SIZE_GB=$((SIZE / 1073741824))
        echo "  Found: $dev (${SIZE_GB}GB, $FSTYPE)"
        DATA_DEVICE="$dev"
        break
    fi
done

# Also check partitions
if [[ -z "$DATA_DEVICE" ]]; then
    for dev in /dev/sd?1; do
        [[ -b "$dev" ]] || continue
        PARENT="/dev/$(lsblk -no PKNAME "$dev" 2>/dev/null)"
        [[ "$PARENT" == "$LUKS_DEVICE" ]] && continue
        FSTYPE=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1)
        if [[ -n "$FSTYPE" ]]; then
            SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
            SIZE_GB=$((SIZE / 1073741824))
            echo "  Found: $dev (${SIZE_GB}GB, $FSTYPE)"
            DATA_DEVICE="$dev"
            break
        fi
    done
fi

if [[ -z "$DATA_DEVICE" ]]; then
    echo "  ERROR: No data drive found. Available devices:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE
    echo ""
    echo "  Plug in the Apricorn and try again."
    exit 1
fi

# Unmount if automounted
umount "$DATA_DEVICE" 2>/dev/null || true
AUTOMOUNT=$(lsblk -no MOUNTPOINT "$DATA_DEVICE" 2>/dev/null | head -1)
[[ -n "$AUTOMOUNT" ]] && umount "$AUTOMOUNT" 2>/dev/null || true

mkdir -p "$DATA_MOUNT"
if ! mount -o rw "$DATA_DEVICE" "$DATA_MOUNT"; then
    echo "  ERROR: Failed to mount data drive."
    exit 1
fi

# Ensure directories exist
for dir in env postgres/data postgres/ssl redis/data caddy/data caddy/config tor logs backups; do
    mkdir -p "$DATA_MOUNT/$dir"
done
chown -R "$REAL_USER:$REAL_USER" "$DATA_MOUNT"

echo "  ✓ Data drive mounted at $DATA_MOUNT"
echo ""

# ---- STEP 4: LAUNCH THREADCOUNT ----
echo "[STEP 4] Launching ThreadCount..."
echo ""

TC_COMPOSE="$PROGRAM_MOUNT/threadcount/docker-compose.yml"
SV_COMPOSE="$CONFIG_DIR/compose/docker-compose.sovereign.yml"

if [[ ! -f "$TC_COMPOSE" ]]; then
    echo "  ERROR: docker-compose.yml not found at $TC_COMPOSE"
    ls "$PROGRAM_MOUNT/" 2>/dev/null
    exit 1
fi

if [[ ! -f "$SV_COMPOSE" ]]; then
    echo "  WARNING: Sovereign override not found, using base compose only"
    SV_COMPOSE=""
fi

COMPOSE_CMD="docker compose -f $TC_COMPOSE"
[[ -n "$SV_COMPOSE" ]] && COMPOSE_CMD="$COMPOSE_CMD -f $SV_COMPOSE"
COMPOSE_CMD="$COMPOSE_CMD --project-name sovereign --project-directory $PROGRAM_MOUNT/threadcount"

# Export env file path for docker compose
if [[ -f "$DATA_MOUNT/env/.env" ]]; then
    export ENV_FILE="$DATA_MOUNT/env/.env"
    echo "  Using .env from data drive"
fi

$COMPOSE_CMD up -d

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║          SOVEREIGN SESSION ACTIVE                    ║"
echo "║          Dashboard: http://localhost/dashboard        ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# Open browser
if command -v firefox &>/dev/null; then
    su - "$REAL_USER" -c "firefox http://localhost/dashboard &" 2>/dev/null || true
fi

echo "Press Enter to shut down and safely unmount all drives..."
read -r

# ---- SHUTDOWN ----
echo ""
echo "Shutting down..."
$COMPOSE_CMD down --timeout 15 2>/dev/null || true
sync

umount "$DATA_MOUNT" 2>/dev/null || umount -l "$DATA_MOUNT" 2>/dev/null || true
umount "$PROGRAM_MOUNT" 2>/dev/null || umount -l "$PROGRAM_MOUNT" 2>/dev/null || true
cryptsetup luksClose sovereign_program 2>/dev/null || true

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       ALL DRIVES SAFELY UNMOUNTED                    ║"
echo "║       You may remove USB drives.                     ║"
echo "╚═══════════════════════════════════════════════════════╝"
