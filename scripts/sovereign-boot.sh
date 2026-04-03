#!/bin/bash

# ============================================================
# Sovereign Boot — Launch ThreadCount with Apricorn Data Drive
# Run with: sudo bash sovereign-boot.sh
# ============================================================

if [[ $EUID -ne 0 ]]; then
    echo "Run with: sudo bash $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
DATA_MOUNT="/mnt/sovereign/data"
TC_DIR="$REAL_HOME/threadcount"

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║            SOVEREIGN BOOT SYSTEM                     ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# ---- CLEANUP STALE STATE ----
docker compose --project-name sovereign down --timeout 10 2>/dev/null || true
umount -l "$DATA_MOUNT" 2>/dev/null || true

# ---- STEP 1: FIND APRICORN ----
echo "[1] Unlock Apricorn with hardware PIN, plug it in, press Enter..."
read -r

# Find USB drive that isn't the boot drive
DATA_DEVICE=""
for dev in /dev/sd?1 /dev/sd?; do
    [[ -b "$dev" ]] || continue
    FSTYPE=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1)
    [[ -z "$FSTYPE" ]] && continue
    [[ "$FSTYPE" == "crypto_LUKS" ]] && continue
    [[ "$FSTYPE" == "LVM2_member" ]] && continue
    SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
    SIZE_GB=$((SIZE / 1073741824))
    # Skip tiny partitions and the NVMe
    [[ $SIZE_GB -lt 5 ]] && continue
    TRAN=$(lsblk -no TRAN "$dev" 2>/dev/null | head -1)
    [[ "$TRAN" != "usb" ]] && continue
    echo "  Found USB device: $dev (${SIZE_GB}GB, $FSTYPE)"
    DATA_DEVICE="$dev"
    break
done

if [[ -z "$DATA_DEVICE" ]]; then
    echo "  ERROR: No USB data drive found."
    lsblk -o NAME,SIZE,TYPE,FSTYPE,TRAN
    exit 1
fi

# ---- STEP 2: MOUNT APRICORN ----
echo ""
echo "[2] Mounting Apricorn..."
umount "$DATA_DEVICE" 2>/dev/null || true
mkdir -p "$DATA_MOUNT"
if ! mount -o rw,nosuid,nodev "$DATA_DEVICE" "$DATA_MOUNT"; then
    echo "  ERROR: Failed to mount $DATA_DEVICE"
    exit 1
fi

for dir in env postgres/data postgres/ssl redis/data caddy/data caddy/config tor logs backups; do
    mkdir -p "$DATA_MOUNT/$dir"
done
chown -R "$REAL_USER:$REAL_USER" "$DATA_MOUNT"
echo "  ✓ Apricorn mounted at $DATA_MOUNT"

# ---- STEP 3: CHECK .ENV ----
echo ""
echo "[3] Checking secrets..."
if [[ ! -f "$DATA_MOUNT/env/.env" ]]; then
    echo "  ERROR: No .env file on Apricorn at $DATA_MOUNT/env/.env"
    echo "  Run the provisioning script first."
    exit 1
fi
echo "  ✓ Secrets found"

# ---- STEP 4: CHECK THREADCOUNT ----
echo ""
echo "[4] Checking ThreadCount..."
if [[ ! -f "$TC_DIR/docker-compose.yml" ]]; then
    echo "  ThreadCount not found at $TC_DIR — cloning..."
    su - "$REAL_USER" -c "git clone https://github.com/steeldragon666/threadcount.git $TC_DIR"
fi

if [[ ! -f "$TC_DIR/docker-compose.yml" ]]; then
    echo "  ERROR: docker-compose.yml not found"
    exit 1
fi
echo "  ✓ ThreadCount ready at $TC_DIR"

# ---- STEP 5: ENSURE DOCKER IS RUNNING ----
if ! systemctl is-active --quiet docker; then
    systemctl start docker
    sleep 3
fi

# ---- STEP 6: LAUNCH ----
echo ""
echo "[5] Launching ThreadCount..."
echo ""

# Link .env from Apricorn
cp "$DATA_MOUNT/env/.env" "$TC_DIR/.env"

# Build if images don't exist
if [[ -z "$(docker images -q threadcount-api 2>/dev/null)" ]]; then
    echo "  Building images (first run, takes a few minutes)..."
    cd "$TC_DIR" && docker compose build
fi

# Use sovereign overlay if it exists
COMPOSE_CMD="docker compose -f $TC_DIR/docker-compose.yml"
SV_COMPOSE="$REAL_HOME/.config/sovereign/compose/docker-compose.sovereign.yml"
if [[ -f "$SV_COMPOSE" ]]; then
    COMPOSE_CMD="$COMPOSE_CMD -f $SV_COMPOSE"
fi

cd "$TC_DIR"
$COMPOSE_CMD --project-name sovereign up -d

echo ""
docker compose --project-name sovereign ps
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

echo "Press Enter to shut down..."
read -r

# ---- SHUTDOWN ----
echo ""
echo "Shutting down..."
cd "$TC_DIR"
$COMPOSE_CMD --project-name sovereign down --timeout 15 2>/dev/null || true
rm -f "$TC_DIR/.env"
sync
umount "$DATA_MOUNT" 2>/dev/null || umount -l "$DATA_MOUNT" 2>/dev/null || true

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       SAFELY SHUT DOWN — REMOVE APRICORN             ║"
echo "╚═══════════════════════════════════════════════════════╝"
