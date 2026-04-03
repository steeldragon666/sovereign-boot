#!/bin/bash

# ============================================================
# Sovereign Boot — Secure ThreadCount launcher
#
# Architecture:
#   Laptop (LUKS Ubuntu) — Docker, code, images, database volumes
#   Apricorn (FIPS 140-2) — secrets (.env, JWT keys) only
#
# Run: sudo bash sovereign-boot.sh
# ============================================================

DATA_MOUNT="/mnt/sovereign/data"
COMPOSE_PROJECT="sovereign"

if [[ $EUID -ne 0 ]]; then
    echo "Usage: sudo bash $0"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
TC_DIR="$REAL_HOME/threadcount"
OVERLAY="$REAL_HOME/.config/sovereign/compose/docker-compose.sovereign.yml"

fail() { echo "  ✗ $1"; exit 1; }
ok()   { echo "  ✓ $1"; }

cleanup() {
    echo ""
    echo "Shutting down..."
    cd "$TC_DIR" 2>/dev/null
    docker compose $COMPOSE_FILES --project-name "$COMPOSE_PROJECT" down --timeout 15 2>/dev/null || true
    rm -f "$TC_DIR/.env"
    sync
    umount "$DATA_MOUNT" 2>/dev/null || umount -l "$DATA_MOUNT" 2>/dev/null || true
    echo ""
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║       SAFELY SHUT DOWN — REMOVE APRICORN             ║"
    echo "╚═══════════════════════════════════════════════════════╝"
}
trap cleanup EXIT

COMPOSE_FILES=""

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║            SOVEREIGN BOOT SYSTEM                     ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# ---- CLEANUP PREVIOUS SESSION ----
docker compose --project-name "$COMPOSE_PROJECT" down --timeout 10 2>/dev/null || true
umount -l "$DATA_MOUNT" 2>/dev/null || true
rm -f "$TC_DIR/.env" 2>/dev/null || true

# ============================================================
# 1 — MOUNT APRICORN
# ============================================================
echo "[1] Waiting for Apricorn..."
echo "    Unlock with hardware PIN → plug in → press Enter"
read -r

DATA_DEVICE=""
for dev in /dev/sd?1 /dev/sd?; do
    [[ -b "$dev" ]] || continue
    FSTYPE=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1)
    [[ -z "$FSTYPE" || "$FSTYPE" == "crypto_LUKS" || "$FSTYPE" == "LVM2_member" ]] && continue
    SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
    SIZE_GB=$((SIZE / 1073741824))
    [[ $SIZE_GB -lt 5 ]] && continue
    PARENT=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    [[ "$PARENT" == nvme* ]] && continue
    DATA_DEVICE="$dev"
    break
done
[[ -z "$DATA_DEVICE" ]] && fail "No USB data drive found"

# Unmount any automount, remount at known path
umount "$DATA_DEVICE" 2>/dev/null || true
AUTOMOUNT=$(lsblk -no MOUNTPOINT "$DATA_DEVICE" 2>/dev/null | head -1)
[[ -n "$AUTOMOUNT" ]] && umount "$AUTOMOUNT" 2>/dev/null || true

mkdir -p "$DATA_MOUNT"
# exFAT: set ownership via mount options (no chown/chmod support)
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")
mount -o "rw,uid=$REAL_UID,gid=$REAL_GID" "$DATA_DEVICE" "$DATA_MOUNT" || fail "Could not mount $DATA_DEVICE"

mkdir -p "$DATA_MOUNT/env" "$DATA_MOUNT/jwt" 2>/dev/null || true
ok "Apricorn mounted"

# ============================================================
# 2 — VALIDATE SECRETS
# ============================================================
echo ""
echo "[2] Validating secrets..."
[[ -f "$DATA_MOUNT/env/.env" ]] || fail ".env missing — run: sudo bash ~/sovereign-boot/scripts/generate-env.sh"

# Quick validation
grep -q "POSTGRES_PASSWORD=" "$DATA_MOUNT/env/.env" || fail ".env missing POSTGRES_PASSWORD"
if grep -q "PASTE_YOUR_BOT_TOKEN_HERE" "$DATA_MOUNT/env/.env"; then
    echo "    ⚠ Telegram bot token not set — bot will fail to connect"
fi
ok "Secrets valid"

# ============================================================
# 3 — PREPARE THREADCOUNT
# ============================================================
echo ""
echo "[3] Preparing ThreadCount..."

if [[ ! -f "$TC_DIR/docker-compose.yml" ]]; then
    echo "    Cloning repository..."
    su - "$REAL_USER" -c "git clone https://github.com/steeldragon666/threadcount.git $TC_DIR"
fi
[[ -f "$TC_DIR/docker-compose.yml" ]] || fail "docker-compose.yml not found"

cp "$DATA_MOUNT/env/.env" "$TC_DIR/.env"
ok "ThreadCount ready"

# ============================================================
# 4 — DOCKER
# ============================================================
echo ""
echo "[4] Preparing Docker..."

systemctl is-active --quiet docker || { systemctl start docker; sleep 3; }

# Build app images if first run
if [[ -z "$(docker images -q threadcount-api 2>/dev/null)" ]]; then
    echo "    Building images (first run)..."
    cd "$TC_DIR" && docker compose build
fi

# Pull infra images if missing
for img in postgres:16-alpine redis:7-alpine caddy:2-alpine; do
    if [[ -z "$(docker images -q "$img" 2>/dev/null)" ]]; then
        echo "    Pulling $img..."
        docker pull "$img" 2>/dev/null || true
    fi
done

# Pull Tor only if overlay exists
if [[ -f "$OVERLAY" ]]; then
    if [[ -z "$(docker images -q osminogin/tor-simple 2>/dev/null)" ]]; then
        echo "    Pulling Tor proxy image..."
        docker pull osminogin/tor-simple:latest 2>/dev/null || echo "    ⚠ Tor pull failed — overlay will start without Tor"
    fi
fi

ok "Docker ready"

# ============================================================
# 5 — LAUNCH
# ============================================================
echo ""
echo "[5] Launching..."

cd "$TC_DIR"
COMPOSE_FILES="-f $TC_DIR/docker-compose.yml"
if [[ -f "$OVERLAY" ]]; then
    COMPOSE_FILES="$COMPOSE_FILES -f $OVERLAY"
    echo "    Sovereign overlay active (Tor proxy)"
fi

docker compose $COMPOSE_FILES --project-name "$COMPOSE_PROJECT" up -d

# Wait for health
echo "    Waiting for services..."
for i in $(seq 1 30); do
    RUNNING=$(docker compose --project-name "$COMPOSE_PROJECT" ps --status running -q 2>/dev/null | wc -l)
    [[ $RUNNING -ge 4 ]] && break
    sleep 2
done

echo ""
docker compose --project-name "$COMPOSE_PROJECT" ps
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║          SOVEREIGN SESSION ACTIVE                    ║"
echo "║                                                       ║"
echo "║  Dashboard:  http://localhost                         ║"
echo "║  API:        http://localhost/api/v1/health           ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

su - "$REAL_USER" -c "firefox http://localhost &" 2>/dev/null || true

echo "Press Enter to shut down and safely eject Apricorn..."
read -r
# cleanup runs via EXIT trap
