#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
TC="$REAL_HOME/threadcount"
DATA="/mnt/sovereign/data"

echo ""
echo "=== DIAGNOSING AND FIXING ==="
echo ""

# 1. Stop everything
echo "[1] Cleaning up..."
docker compose --project-name sovereign down --timeout 5 2>/dev/null || true
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker volume prune -f 2>/dev/null || true

# 2. Update threadcount
echo "[2] Updating ThreadCount..."
if [[ -d "$TC" ]]; then
    cd "$TC" && su - "$REAL_USER" -c "cd $TC && git pull"
else
    su - "$REAL_USER" -c "git clone https://github.com/steeldragon666/threadcount.git $TC"
fi

# 3. Mount Apricorn
echo "[3] Mounting Apricorn..."
umount -l "$DATA" 2>/dev/null || true
for dev in /dev/sd?1 /dev/sd?; do
    [[ -b "$dev" ]] || continue
    FSTYPE=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1)
    [[ "$FSTYPE" == "exfat" || "$FSTYPE" == "vfat" ]] || continue
    SIZE=$(lsblk -bno SIZE "$dev" 2>/dev/null | head -1)
    SIZE_GB=$((SIZE / 1073741824))
    [[ $SIZE_GB -lt 5 ]] && continue
    PARENT=$(lsblk -no PKNAME "$dev" 2>/dev/null | head -1)
    [[ "$PARENT" == nvme* ]] && continue
    umount "$dev" 2>/dev/null || true
    AUTOMOUNT=$(lsblk -no MOUNTPOINT "$dev" 2>/dev/null | head -1)
    [[ -n "$AUTOMOUNT" ]] && umount "$AUTOMOUNT" 2>/dev/null || true
    mkdir -p "$DATA"
    mount -o "rw,uid=$(id -u $REAL_USER),gid=$(id -g $REAL_USER)" "$dev" "$DATA" && echo "  Mounted $dev" && break
done

# 4. Check/create .env
echo "[4] Checking .env..."
if mountpoint -q "$DATA" 2>/dev/null && [[ -f "$DATA/env/.env" ]]; then
    cp "$DATA/env/.env" "$TC/.env"
    echo "  Copied from Apricorn"
elif [[ -f "$TC/.env" ]]; then
    echo "  Using existing .env"
else
    echo "  Generating new .env..."
    PG_PASS=$(openssl rand -hex 32)
    FERNET=$(openssl rand -base64 32)
    BOT_API_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 43)
    HMAC_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 43)
    OPERATOR_PASS=$(openssl rand -hex 16)
    cat > "$TC/.env" << ENVEOF
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
    echo "  Generated (login: admin / $OPERATOR_PASS)"
fi

# Verify .env has what we need
echo "  Checking .env contents..."
for var in POSTGRES_PASSWORD POSTGRES_USER POSTGRES_DB REDIS_URL; do
    if ! grep -q "^${var}=" "$TC/.env"; then
        echo "  ERROR: Missing $var in .env"
        exit 1
    fi
done
echo "  ✓ .env valid"

# 5. Docker
echo "[5] Starting Docker..."
systemctl is-active --quiet docker || { systemctl start docker; sleep 3; }

# 6. Build
echo "[6] Building images..."
cd "$TC"
docker compose build 2>&1 | tail -5

# 7. Launch — foreground first to see errors
echo "[7] Launching (showing output for 30 seconds)..."
echo ""
cd "$TC"
docker compose --project-name sovereign up -d 2>&1

echo ""
echo "  Waiting 30 seconds for services to start..."
sleep 30

echo ""
echo "=== CONTAINER STATUS ==="
docker compose --project-name sovereign ps 2>/dev/null || docker ps -a
echo ""

echo "=== POSTGRES LOGS ==="
docker logs sovereign-postgres 2>&1 | tail -10
echo ""

echo "=== REDIS LOGS ==="
docker logs sovereign-redis 2>&1 | tail -5
echo ""

echo "=== API LOGS ==="
docker logs sovereign-api 2>&1 | tail -10
echo ""

# Check if dashboard is reachable
if curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null | grep -q "200\|301\|302"; then
    echo "=== DASHBOARD IS UP ==="
    echo "Open: http://localhost"
else
    echo "=== DASHBOARD NOT REACHABLE YET ==="
    echo "Check: sudo docker logs sovereign-caddy"
fi
echo ""
