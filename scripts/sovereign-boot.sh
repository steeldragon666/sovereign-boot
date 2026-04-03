#!/bin/bash
set -uo pipefail

# ============================================================
# Sovereign Boot — Secure ThreadCount launcher
#
# Architecture:
#   Laptop (LUKS Ubuntu) — Docker, code, images
#   Apricorn (FIPS 140-2) — secrets, databases, logs
#
# The sovereign compose overlay redirects all Docker named
# volumes to bind mounts on the Apricorn. Config files
# (init.sql, redis.conf, Caddyfile) stay in the repo.
# Tor proxy routes outbound API/bot traffic through SOCKS5.
#
# Run with: sudo bash sovereign-boot.sh
# ============================================================

# ---- Constants ----
DATA_MOUNT="/mnt/sovereign/data"
COMPOSE_PROJECT="sovereign"

# ---- Root check ----
if [[ $EUID -ne 0 ]]; then
    echo "Usage: sudo bash $0"
    exit 1
fi

# ---- Resolve real user ----
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
TC_DIR="$REAL_HOME/threadcount"
OVERLAY="$REAL_HOME/.config/sovereign/compose/docker-compose.sovereign.yml"

# ---- Helpers ----
fail() { echo "  ✗ $1"; exit 1; }
ok()   { echo "  ✓ $1"; }

# ---- Banner ----
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║            SOVEREIGN BOOT SYSTEM                     ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# ---- Cleanup previous session ----
docker compose --project-name "$COMPOSE_PROJECT" down --timeout 10 2>/dev/null || true
umount -l "$DATA_MOUNT" 2>/dev/null || true
rm -f "$TC_DIR/.env" 2>/dev/null || true

# ============================================================
# STEP 1 — Detect and mount Apricorn
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

[[ -z "$DATA_DEVICE" ]] && fail "No USB data drive found. Run: lsblk"

# Unmount automount, remount at known path
umount "$DATA_DEVICE" 2>/dev/null || true
AUTOMOUNT=$(lsblk -no MOUNTPOINT "$DATA_DEVICE" 2>/dev/null | head -1)
[[ -n "$AUTOMOUNT" ]] && umount "$AUTOMOUNT" 2>/dev/null || true
mkdir -p "$DATA_MOUNT"
REAL_UID=$(id -u "$REAL_USER")
REAL_GID=$(id -g "$REAL_USER")
mount -o "rw,nosuid,nodev,uid=$REAL_UID,gid=$REAL_GID,dmask=0000,fmask=0000" "$DATA_DEVICE" "$DATA_MOUNT" || fail "Could not mount $DATA_DEVICE"

# Ensure Apricorn directory structure
for dir in env jwt postgres/data postgres/ssl redis/data caddy/data caddy/config tor logs/postgres backups; do
    mkdir -p "$DATA_MOUNT/$dir"
done
ok "Apricorn mounted at $DATA_MOUNT ($(lsblk -bno SIZE "$DATA_DEVICE" | awk '{printf "%.0fGB", $1/1073741824}'))"

# ============================================================
# STEP 2 — Validate secrets
# ============================================================
echo ""
echo "[2] Validating secrets..."
[[ -f "$DATA_MOUNT/env/.env" ]] || fail ".env not found — run: sudo bash scripts/generate-env.sh"
source "$DATA_MOUNT/env/.env" 2>/dev/null
[[ -n "${POSTGRES_PASSWORD:-}" ]] || fail ".env missing POSTGRES_PASSWORD"
[[ "${TELEGRAM_BOT_TOKEN:-}" != "PASTE_YOUR_BOT_TOKEN_HERE" ]] || echo "    ⚠ Telegram bot token not configured — bot will fail"
ok "Secrets validated"

# ============================================================
# STEP 3 — Prepare ThreadCount
# ============================================================
echo ""
echo "[3] Preparing ThreadCount..."

if [[ ! -f "$TC_DIR/docker-compose.yml" ]]; then
    echo "    Cloning repository..."
    su - "$REAL_USER" -c "git clone https://github.com/steeldragon666/threadcount.git $TC_DIR"
fi
[[ -f "$TC_DIR/docker-compose.yml" ]] || fail "docker-compose.yml not found in $TC_DIR"

# Copy .env into project directory (docker compose reads from project root)
cp "$DATA_MOUNT/env/.env" "$TC_DIR/.env"
chmod 600 "$TC_DIR/.env"
ok "ThreadCount ready"

# ============================================================
# STEP 4 — Docker
# ============================================================
echo ""
echo "[4] Starting Docker..."

systemctl is-active --quiet docker || systemctl start docker
sleep 2

# Build app images if missing
if [[ -z "$(docker images -q threadcount-api 2>/dev/null)" ]]; then
    echo "    Building images (first run, takes a few minutes)..."
    cd "$TC_DIR" && docker compose build
fi

# Pull infrastructure images if missing
for img in postgres:16-alpine redis:7-alpine caddy:2-alpine osminogin/tor-simple:latest; do
    if [[ -z "$(docker images -q "$img" 2>/dev/null)" ]]; then
        echo "    Pulling $img..."
        docker pull "$img"
    fi
done
ok "Docker images ready"

# ============================================================
# STEP 5 — Launch
# ============================================================
echo ""
echo "[5] Launching ThreadCount..."

cd "$TC_DIR"

# Build compose command — use overlay if available
COMPOSE_FILES="-f $TC_DIR/docker-compose.yml"
if [[ -f "$OVERLAY" ]]; then
    COMPOSE_FILES="$COMPOSE_FILES -f $OVERLAY"
    echo "    Using sovereign overlay (Tor + Apricorn volumes)"
else
    echo "    Using base compose only"
fi

docker compose $COMPOSE_FILES --project-name "$COMPOSE_PROJECT" up -d

# Wait for services
echo "    Waiting for services to start..."
RETRIES=30
while [[ $RETRIES -gt 0 ]]; do
    RUNNING=$(docker compose --project-name "$COMPOSE_PROJECT" ps --status running --format json 2>/dev/null | wc -l || echo 0)
    [[ $RUNNING -ge 4 ]] && break
    sleep 2
    ((RETRIES--)) || true
done

echo ""
docker compose --project-name "$COMPOSE_PROJECT" ps
echo ""

# Quick health summary
HEALTHY=$(docker compose --project-name "$COMPOSE_PROJECT" ps --format json 2>/dev/null | grep -c healthy || echo 0)
TOTAL=$(docker compose --project-name "$COMPOSE_PROJECT" ps --format json 2>/dev/null | wc -l || echo 0)
echo "    Services: $TOTAL running, $HEALTHY healthy"

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║          SOVEREIGN SESSION ACTIVE                    ║"
echo "║                                                       ║"
echo "║  Dashboard:  http://localhost                         ║"
echo "║  API:        http://localhost/api/v1/health           ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# Open browser as real user
su - "$REAL_USER" -c "firefox http://localhost &" 2>/dev/null || true

echo "Press Enter to shut down and safely eject Apricorn..."
read -r

# ============================================================
# SHUTDOWN
# ============================================================
echo ""
echo "Shutting down..."

cd "$TC_DIR"
docker compose $COMPOSE_FILES --project-name "$COMPOSE_PROJECT" down --timeout 15

# Remove .env from disk (secrets stay on Apricorn only)
rm -f "$TC_DIR/.env"

# Sync and unmount
sync
umount "$DATA_MOUNT" 2>/dev/null || umount -l "$DATA_MOUNT" 2>/dev/null || true

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║       SAFELY SHUT DOWN — REMOVE APRICORN             ║"
echo "╚═══════════════════════════════════════════════════════╝"
