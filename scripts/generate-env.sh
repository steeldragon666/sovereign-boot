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

mkdir -p "$DATA/env" "$DATA/jwt"

# Generate RSA key pair for JWT as files
openssl genrsa -out "$DATA/jwt/private.pem" 2048 2>/dev/null
openssl rsa -in "$DATA/jwt/private.pem" -pubout -out "$DATA/jwt/public.pem" 2>/dev/null
chmod 600 "$DATA/jwt/private.pem"

# Generate secrets
PG_PASS=$(openssl rand -hex 32)
FERNET=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)
BOT_API_KEY=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
HMAC_SECRET=$(openssl rand -base64 32 | tr -d '/+=' | head -c 32)
OPERATOR_PASS=$(openssl rand -hex 16)

cat > "$DATA/env/.env" << ENVEOF
POSTGRES_USER=sovereign
POSTGRES_PASSWORD=$PG_PASS
POSTGRES_DB=sovereign_commerce
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
REDIS_URL=unix:///var/run/redis/redis.sock
TELEGRAM_BOT_TOKEN=PASTE_YOUR_BOT_TOKEN_HERE
TELEGRAM_ADMIN_IDS=PASTE_YOUR_TELEGRAM_USER_ID_HERE
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

echo ""
echo "=== Generated .env ==="
echo "Operator login: admin / $OPERATOR_PASS"
echo "JWT keys saved to: $DATA/jwt/"
echo ""
echo "Replace TELEGRAM_BOT_TOKEN and TELEGRAM_ADMIN_IDS in:"
echo "  $DATA/env/.env"
echo ""
echo "DONE"
