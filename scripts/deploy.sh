#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)
TC="$REAL_HOME/threadcount"
SB="$REAL_HOME/sovereign-boot"

echo ""
echo "=== SOVEREIGN DEPLOY ==="
echo ""

# 1. Stop and clean
echo "[1] Stopping containers..."
cd "$TC" 2>/dev/null && docker compose down --remove-orphans 2>/dev/null || true
docker stop $(docker ps -aq) 2>/dev/null || true
docker rm -f $(docker ps -aq) 2>/dev/null || true

# 2. Update repos
echo "[2] Updating code..."
su - "$REAL_USER" -c "cd $SB && git pull" 2>/dev/null
su - "$REAL_USER" -c "cd $TC && git pull" 2>/dev/null

# 3. Copy overlay and tor build context into threadcount dir
echo "[3] Installing overlay..."
cp "$SB/compose/docker-compose.sovereign.yml" "$TC/docker-compose.sovereign.yml"
cp -r "$SB/compose/tor" "$TC/tor"
sed -i 's/\r$//' "$TC/docker-compose.sovereign.yml" "$TC/tor/Dockerfile"
chown -R "$REAL_USER:$REAL_USER" "$TC/docker-compose.sovereign.yml" "$TC/tor"

# 4. Ensure .env exists and has SOVEREIGN_MODE
echo "[4] Checking .env..."
if [[ ! -f "$TC/.env" ]] || ! grep -q "POSTGRES_PASSWORD" "$TC/.env"; then
    echo "  ERROR: No .env found. Run fresh-start.sh first."
    exit 1
fi
grep -q "SOVEREIGN_MODE" "$TC/.env" || echo "SOVEREIGN_MODE=true" >> "$TC/.env"
echo "  .env OK"

# 5. Start Docker
systemctl is-active --quiet docker || { systemctl start docker; sleep 3; }

# 6. Prune build cache and rebuild
echo "[5] Building all images..."
docker builder prune -af 2>/dev/null || true
cd "$TC"
docker compose -f docker-compose.yml -f docker-compose.sovereign.yml build --no-cache 2>&1 | tail -5

# 7. Launch
echo "[6] Launching..."
cd "$TC"
docker compose -f docker-compose.yml -f docker-compose.sovereign.yml up -d 2>&1

echo ""
echo "  Waiting 60 seconds..."
sleep 60

echo ""
echo "=== STATUS ==="
docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""

echo "=== API ==="
curl -s http://localhost/api/v1/health 2>/dev/null || echo "API not reachable"
echo ""

echo "=== BOT ==="
docker logs sovereign-bot 2>&1 | tail -5
echo ""

echo "=== TOR ==="
docker logs sovereign-tor 2>&1 | tail -3
echo ""

echo "=== DASHBOARD ==="
HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://localhost 2>/dev/null)
echo "HTTP $HTTP"
echo ""
