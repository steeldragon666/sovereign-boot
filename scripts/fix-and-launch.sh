#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
TC="$REAL_HOME/threadcount"
DATA="/mnt/sovereign/data"
OVERLAY="$REAL_HOME/.config/sovereign/compose/docker-compose.sovereign.yml"

echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║         SOVEREIGN FULL RESET AND LAUNCH               ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# ============================================================
# 1. DESTROY ALL DOCKER STATE
# ============================================================
echo "[1] Destroying all Docker state..."
docker compose --project-name sovereign down -v --remove-orphans --timeout 5 2>/dev/null || true
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker volume rm $(docker volume ls -q) 2>/dev/null || true
docker network prune -f 2>/dev/null || true
docker system prune -a --volumes -f 2>/dev/null || true
echo "  ✓ All Docker containers, images, volumes, cache destroyed"

# ============================================================
# 2. UPDATE SOURCE CODE
# ============================================================
echo ""
echo "[2] Updating source code..."
su - "$REAL_USER" -c "cd $REAL_HOME/sovereign-boot && git pull" 2>/dev/null
if [[ -d "$TC" ]]; then
    su - "$REAL_USER" -c "cd $TC && git pull"
else
    su - "$REAL_USER" -c "git clone https://github.com/steeldragon666/threadcount.git $TC"
fi
echo "  ✓ Code updated"

# ============================================================
# 3. INSTALL SOVEREIGN OVERLAY
# ============================================================
echo ""
echo "[3] Installing sovereign overlay..."
mkdir -p "$REAL_HOME/.config/sovereign/compose"
cp "$REAL_HOME/sovereign-boot/compose/"* "$REAL_HOME/.config/sovereign/compose/" 2>/dev/null || true
sed -i 's/\r$//' "$REAL_HOME/.config/sovereign/compose/"* 2>/dev/null || true
chown -R "$REAL_USER:$REAL_USER" "$REAL_HOME/.config/sovereign"
if [[ -f "$OVERLAY" ]]; then
    echo "  ✓ Overlay installed"
else
    echo "  ⚠ No overlay found — will use base compose only"
fi

# ============================================================
# 4. MOUNT APRICORN AND SETUP .ENV
# ============================================================
echo ""
echo "[4] Setting up secrets..."
umount -l "$DATA" 2>/dev/null || true
MOUNTED=false
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
    mount -o "rw,uid=$(id -u $REAL_USER),gid=$(id -g $REAL_USER)" "$dev" "$DATA" && MOUNTED=true && break
done

if $MOUNTED && [[ -f "$DATA/env/.env" ]]; then
    cp "$DATA/env/.env" "$TC/.env"
    # Ensure SOVEREIGN_MODE is set
    grep -q "SOVEREIGN_MODE" "$TC/.env" || echo "SOVEREIGN_MODE=true" >> "$TC/.env"
    echo "  ✓ Secrets loaded from Apricorn"
elif [[ -f "$TC/.env" ]] && grep -q "POSTGRES_PASSWORD" "$TC/.env"; then
    grep -q "SOVEREIGN_MODE" "$TC/.env" || echo "SOVEREIGN_MODE=true" >> "$TC/.env"
    echo "  ✓ Using existing .env"
else
    echo "  Generating new secrets..."
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
    # Save to Apricorn too if mounted
    if $MOUNTED; then
        mkdir -p "$DATA/env"
        cp "$TC/.env" "$DATA/env/.env"
    fi
    echo "  ✓ Secrets generated (login: admin / $OPERATOR_PASS)"
fi

# ============================================================
# 5. START DOCKER
# ============================================================
echo ""
echo "[5] Starting Docker..."
systemctl is-active --quiet docker || { systemctl start docker; sleep 3; }

# ============================================================
# 6. BUILD ALL IMAGES FROM SCRATCH
# ============================================================
echo ""
echo "[6] Building ALL images from scratch (no cache)..."
cd "$TC"

COMPOSE_FILES="-f $TC/docker-compose.yml"
if [[ -f "$OVERLAY" ]]; then
    COMPOSE_FILES="$COMPOSE_FILES -f $OVERLAY"
fi

docker compose $COMPOSE_FILES build --no-cache 2>&1 | tail -20

# Pull infra images fresh
echo "  Pulling infrastructure images..."
docker pull postgres:16-alpine 2>/dev/null || true
docker pull redis:7-alpine 2>/dev/null || true
docker pull caddy:2-alpine 2>/dev/null || true
docker pull osminogin/tor-simple:latest 2>/dev/null || true

# ============================================================
# 7. LAUNCH
# ============================================================
echo ""
echo "[7] Launching..."
cd "$TC"
docker compose $COMPOSE_FILES --project-name sovereign up -d 2>&1

echo ""
echo "  Waiting 40 seconds for all services to initialize..."
sleep 40

# ============================================================
# 8. STATUS REPORT
# ============================================================
echo ""
echo "╔═══════════════════════════════════════════════════════╗"
echo "║                   STATUS REPORT                       ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

echo "=== CONTAINERS ==="
docker compose --project-name sovereign ps 2>/dev/null || docker ps -a
echo ""

echo "=== POSTGRES ==="
docker logs sovereign-postgres 2>&1 | tail -5
echo ""

echo "=== API ==="
docker logs sovereign-api 2>&1 | tail -5
echo ""

echo "=== REDIS ==="
docker logs sovereign-redis 2>&1 | tail -3
echo ""

# Test connectivity
echo "=== CONNECTIVITY ==="
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null || echo "000")
echo "  Dashboard (http://localhost): HTTP $HTTP_CODE"

API_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/v1/health 2>/dev/null || echo "000")
echo "  API health (http://localhost/api/v1/health): HTTP $API_CODE"

echo ""
if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "301" || "$HTTP_CODE" == "302" ]]; then
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║          SOVEREIGN SESSION ACTIVE                    ║"
    echo "║          Open: http://localhost                       ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    su - "$REAL_USER" -c "firefox http://localhost &" 2>/dev/null || true
else
    echo "Dashboard not responding yet. Check logs above for errors."
fi
echo ""
