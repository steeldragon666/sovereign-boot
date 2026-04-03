#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║         SOVEREIGN FULL REBUILD                        ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# Stop everything
echo "[1] Stopping existing containers..."
docker compose --project-name sovereign down --timeout 10 2>/dev/null || true

# Update repos
echo "[2] Updating repositories..."
su - "$REAL_USER" -c "cd $REAL_HOME/sovereign-boot && git pull"
su - "$REAL_USER" -c "cd $REAL_HOME/threadcount && git pull"

# Install sovereign-boot files
echo "[3] Installing config files..."
mkdir -p "$REAL_HOME/.config/sovereign/compose" "$REAL_HOME/.local/bin"
cp "$REAL_HOME/sovereign-boot/config/"* "$REAL_HOME/.config/sovereign/"
cp "$REAL_HOME/sovereign-boot/scripts/"* "$REAL_HOME/.local/bin/"
cp "$REAL_HOME/sovereign-boot/compose/"* "$REAL_HOME/.config/sovereign/compose/"
find "$REAL_HOME/.config/sovereign" "$REAL_HOME/.local/bin" -type f -exec sed -i 's/\r$//' {} +
find "$REAL_HOME/.local/bin" -name '*.sh' -exec chmod 755 {} +
find "$REAL_HOME/.config/sovereign" -type f -exec chmod 644 {} +
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/sovereign" "$REAL_HOME/.local/bin"

# Rebuild all Docker images
echo "[4] Rebuilding Docker images..."
systemctl is-active --quiet docker || { systemctl start docker; sleep 3; }
cd "$REAL_HOME/threadcount" && docker compose build

# Pull infra images
echo "[5] Pulling infrastructure images..."
docker pull postgres:16-alpine
docker pull redis:7-alpine
docker pull caddy:2-alpine
docker pull osminogin/tor-simple:latest 2>/dev/null || echo "  ⚠ Tor image pull failed (optional)"

# Generate secrets on Apricorn
echo "[6] Setting up Apricorn secrets..."
DATA="/mnt/sovereign/data"
umount -l "$DATA" 2>/dev/null || true
for dev in /dev/sd?1 /dev/sd?; do
    [[ -b "$dev" ]] || continue
    FSTYPE=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1)
    [[ "$FSTYPE" == "exfat" || "$FSTYPE" == "vfat" ]] || continue
    [[ "$FSTYPE" == "crypto_LUKS" || "$FSTYPE" == "LVM2_member" ]] && continue
    SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
    SIZE_GB=$((SIZE / 1073741824))
    [[ $SIZE_GB -lt 5 ]] && continue
    PARENT=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    [[ "$PARENT" == nvme* ]] && continue
    umount "$dev" 2>/dev/null || true
    AUTOMOUNT=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | head -1)
    [[ -n "$AUTOMOUNT" ]] && umount "$AUTOMOUNT" 2>/dev/null || true
    mkdir -p "$DATA"
    REAL_UID=$(id -u "$REAL_USER")
    REAL_GID=$(id -g "$REAL_USER")
    mount -o "rw,uid=$REAL_UID,gid=$REAL_GID" "$dev" "$DATA" && break
done

if mountpoint -q "$DATA" 2>/dev/null; then
    mkdir -p "$DATA/env" "$DATA/jwt"

    # Only generate if .env doesn't exist yet
    if [[ ! -f "$DATA/env/.env" ]] || ! grep -q "POSTGRES_PASSWORD=" "$DATA/env/.env"; then
        echo "  Generating new secrets..."
        PG_PASS=$(openssl rand -hex 32)
        FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)
        BOT_API_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 43)
        HMAC_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 43)
        OPERATOR_PASS=$(openssl rand -hex 16)

        cat > "$DATA/env/.env" << ENVEOF
POSTGRES_USER=sovereign
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=sovereign_commerce
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
REDIS_URL=unix:///var/run/redis/redis.sock
TELEGRAM_BOT_TOKEN=AAGL_FKdviqw3egkvJbdoPuNCr_Eo_gwx74
TELEGRAM_ADMIN_IDS=5410979519
API_HOST=0.0.0.0
API_PORT=8000
API_BASE_URL=http://api:8000
JWT_ALGORITHM=RS256
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=60
JWT_REFRESH_TOKEN_EXPIRE_HOURS=24
FERNET_KEY=$FERNET
BOT_API_KEY=$BOT_API_KEY
BOT_HMAC_SECRET=$HMAC_SECRET
OPERATOR_USERNAME=admin
OPERATOR_PASSWORD=$OPERATOR_PASS
BOT_RATE_LIMIT_PER_MINUTE=30
BOT_SESSION_TIMEOUT_MINUTES=15
LOGIN_MAX_ATTEMPTS=5
LOGIN_LOCKOUT_MINUTES=30
BACKUP_DIR=/backups
BACKUP_RETENTION_DAYS=30
LOG_LEVEL=INFO
ENVIRONMENT=production
DEBUG=false
SOVEREIGN_MODE=true
ENVEOF
        echo "  ✓ Secrets generated (operator: admin / $OPERATOR_PASS)"
    else
        # Ensure SOVEREIGN_MODE is set
        grep -q "SOVEREIGN_MODE" "$DATA/env/.env" || echo "SOVEREIGN_MODE=true" >> "$DATA/env/.env"
        # Ensure Telegram is set
        sed -i 's/PASTE_YOUR_BOT_TOKEN_HERE/AAGL_FKdviqw3egkvJbdoPuNCr_Eo_gwx74/' "$DATA/env/.env"
        sed -i 's/PASTE_YOUR_TELEGRAM_USER_ID_HERE/5410979519/' "$DATA/env/.env"
        echo "  ✓ Existing secrets preserved, sovereign mode ensured"
    fi

    # JWT keys
    if [[ ! -f "$DATA/jwt/private.pem" ]]; then
        openssl genrsa -out "$DATA/jwt/private.pem" 2048 2>/dev/null
        openssl rsa -in "$DATA/jwt/private.pem" -pubout -out "$DATA/jwt/public.pem" 2>/dev/null
        echo "  ✓ JWT keys generated"
    fi
else
    echo "  ⚠ Apricorn not found — skipping secret generation"
    echo "    Plug in Apricorn and run: sudo bash ~/sovereign-boot/scripts/generate-env.sh"
fi

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║         REBUILD COMPLETE                              ║"
echo "║                                                       ║"
echo "║  To launch: sudo bash ~/sovereign-boot/scripts/sovereign-boot.sh"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""
