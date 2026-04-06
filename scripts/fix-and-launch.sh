#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
TC="$REAL_HOME/threadcount"

echo ""
echo "=== CLEAN START ==="
echo ""

# 1. Kill everything
echo "[1] Stopping Docker..."
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm -f $(docker ps -aq) 2>/dev/null || true
docker volume rm $(docker volume ls -q) 2>/dev/null || true

# 2. Update code
echo "[2] Updating code..."
if [[ -d "$TC" ]]; then
    su - "$REAL_USER" -c "cd $TC && git pull"
else
    su - "$REAL_USER" -c "git clone https://github.com/steeldragon666/threadcount.git $TC"
fi

# 3. Setup .env
echo "[3] Setting up .env..."
if [[ ! -f "$TC/.env" ]] || ! grep -q "POSTGRES_PASSWORD" "$TC/.env"; then
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
ENVEOF
    echo "  Generated (operator: admin / $OPERATOR_PASS)"
else
    echo "  Using existing .env"
fi

# 4. Docker
echo "[4] Starting Docker..."
systemctl is-active --quiet docker || { systemctl start docker; sleep 3; }

# 5. Build and launch — BASE COMPOSE ONLY, no overlay
echo "[5] Building and launching..."
cd "$TC"
docker compose build 2>&1 | tail -10
docker compose up -d 2>&1

echo ""
echo "  Waiting 60 seconds for services..."
sleep 60

echo ""
echo "=== STATUS ==="
docker compose ps
echo ""
echo "=== POSTGRES ==="
docker logs sovereign-postgres 2>&1 | tail -5
echo ""
echo "=== API ==="
docker logs sovereign-api 2>&1 | tail -10
echo ""
echo "=== REDIS ==="
docker logs sovereign-redis 2>&1 | tail -3
echo ""

HTTP=$(curl -s -o /dev/null -w "%{http_code}" http://localhost 2>/dev/null || echo "000")
echo "Dashboard: HTTP $HTTP"
API=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/api/v1/health 2>/dev/null || echo "000")
echo "API health: HTTP $API"
echo ""
