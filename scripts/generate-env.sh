#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi

DATA="/mnt/sovereign/data"
if ! mountpoint -q "$DATA" 2>/dev/null; then
    for dev in /dev/sd?1 /dev/sd?; do
        [[ -b "$dev" ]] || continue
        FSTYPE=$(lsblk -no FSTYPE "$dev" 2>/dev/null | head -1)
        [[ "$FSTYPE" == "exfat" || "$FSTYPE" == "vfat" ]] || continue
        mkdir -p "$DATA"
        umount "$dev" 2>/dev/null || true
        mount "$dev" "$DATA" && break
    done
fi

if ! mountpoint -q "$DATA" 2>/dev/null; then
    echo "ERROR: Could not mount data drive"
    exit 1
fi

mkdir -p "$DATA/env"

# Generate RSA key pair for JWT
JWT_PRIVATE_KEY=$(openssl genrsa 2048 2>/dev/null)
JWT_PUBLIC_KEY=$(echo "$JWT_PRIVATE_KEY" | openssl rsa -pubout 2>/dev/null)

# Generate secrets
PG_PASS=$(openssl rand -hex 32)
FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)
BOT_API_KEY=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32)
HMAC_SECRET=$(python3 -c "import secrets; print(secrets.token_urlsafe(32))" 2>/dev/null || openssl rand -base64 32)
OPERATOR_PASS=$(openssl rand -hex 16)

cat > "$DATA/env/.env" << ENVEOF
# ============================================================
# Sovereign Commerce Platform — Generated $(date '+%Y-%m-%d %H:%M')
# ============================================================

# --- PostgreSQL ---
POSTGRES_USER=sovereign
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=sovereign_commerce
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
DATABASE_URL=postgresql+asyncpg://sovereign:${PG_PASS}@postgres:5432/sovereign_commerce

# --- Redis ---
REDIS_URL=unix:///var/run/redis/redis.sock

# --- Telegram Bot ---
TELEGRAM_BOT_TOKEN=PASTE_YOUR_BOT_TOKEN_HERE
TELEGRAM_ADMIN_IDS=PASTE_YOUR_TELEGRAM_USER_ID_HERE

# --- API Server ---
API_HOST=0.0.0.0
API_PORT=8000
API_BASE_URL=http://api:8000

# --- JWT Authentication ---
JWT_PRIVATE_KEY=$JWT_PRIVATE_KEY
JWT_PUBLIC_KEY=$JWT_PUBLIC_KEY
JWT_ALGORITHM=RS256
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=60
JWT_REFRESH_TOKEN_EXPIRE_HOURS=24

# --- Encryption ---
FERNET_KEY=$FERNET

# --- Bot-to-API Authentication ---
BOT_API_KEY=$BOT_API_KEY
BOT_HMAC_SECRET=$HMAC_SECRET

# --- Initial Operator Account ---
OPERATOR_USERNAME=admin
OPERATOR_PASSWORD=$OPERATOR_PASS

# --- Security ---
BOT_RATE_LIMIT_PER_MINUTE=30
BOT_SESSION_TIMEOUT_MINUTES=15
LOGIN_MAX_ATTEMPTS=5
LOGIN_LOCKOUT_MINUTES=30

# --- Backup ---
BACKUP_DIR=/backups
BACKUP_RETENTION_DAYS=30

# --- Logging ---
LOG_LEVEL=INFO

# --- App ---
ENVIRONMENT=production
DEBUG=false
ENVEOF

echo ""
echo "=== Generated .env ==="
echo "PostgreSQL password: $PG_PASS"
echo "Operator username: admin"
echo "Operator password: $OPERATOR_PASS"
echo ""
echo "=== IMPORTANT ==="
echo "Replace TELEGRAM_BOT_TOKEN with your real token from @BotFather"
echo "Replace TELEGRAM_ADMIN_IDS with your numeric Telegram user ID"
echo ""
echo "File saved to: $DATA/env/.env"
echo "DONE"
