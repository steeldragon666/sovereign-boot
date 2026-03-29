#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — USB 3 (Apricorn Data Drive) Provisioning
# Run this ONCE on the Apricorn after setting hardware PIN.
# Prerequisite: Apricorn unlocked with PIN and inserted.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     USB 3 (Apricorn) Data Drive Provisioning         ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Identify device
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL
echo ""
read -rp "Enter the Apricorn device (e.g., /dev/sdc): " DEVICE

if [[ ! -b "$DEVICE" ]]; then
    echo -e "${RED}Device $DEVICE does not exist. Aborting.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}WARNING: This will ERASE ALL DATA on $DEVICE${NC}"
echo -e "${YELLOW}Device: $(lsblk -ndo MODEL,SIZE "$DEVICE" 2>/dev/null)${NC}"
read -rp "Type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# Format
echo -e "${CYAN}Formatting as ext4...${NC}"
sudo mkfs.ext4 -L SOVEREIGN_DATA "$DEVICE"

# Mount temporarily
MOUNT_TMP="/tmp/sovereign-usb3-provision"
sudo mkdir -p "$MOUNT_TMP"
sudo mount "$DEVICE" "$MOUNT_TMP"

# Create directory scaffold
echo -e "${CYAN}Creating directory structure...${NC}"
for dir in env postgres/data postgres/ssl redis/data caddy/data caddy/config tor logs logs/postgres backups; do
    sudo mkdir -p "$MOUNT_TMP/$dir"
done

# Generate secrets
echo ""
echo -e "${CYAN}Generating secrets...${NC}"

# Check if threadcount .env.example is available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_EXAMPLE=""
if [[ -f "$SCRIPT_DIR/../.env.example" ]]; then
    ENV_EXAMPLE="$SCRIPT_DIR/../.env.example"
elif [[ -f "/tmp/threadcount/.env.example" ]]; then
    ENV_EXAMPLE="/tmp/threadcount/.env.example"
fi

# Generate cryptographic material
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)
BOT_API_KEY=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
BOT_HMAC_SECRET=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
OPERATOR_PASSWORD=$(openssl rand -base64 24 | tr -d '=/+' | head -c 24)

# Generate JWT RSA key pair
JWT_PRIVATE_KEY=$(openssl genrsa 2048 2>/dev/null)
JWT_PUBLIC_KEY=$(echo "$JWT_PRIVATE_KEY" | openssl rsa -pubout 2>/dev/null)

# Prompt for Telegram bot token
echo ""
read -rp "Enter your Telegram Bot Token (from @BotFather): " TELEGRAM_BOT_TOKEN
read -rp "Enter Telegram Admin IDs (comma-separated numeric IDs): " TELEGRAM_ADMIN_IDS

# Write .env
cat > "$MOUNT_TMP/env/.env" << ENVEOF
# ============================================================
# Sovereign Commerce Platform — Environment Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- PostgreSQL ---
POSTGRES_USER=sovereign
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=sovereign_commerce
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
DATABASE_URL=postgresql+asyncpg://sovereign:${POSTGRES_PASSWORD}@postgres:5432/sovereign_commerce

# --- Redis ---
REDIS_URL=unix:///var/run/redis/redis.sock

# --- Telegram Bot ---
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ADMIN_IDS=$TELEGRAM_ADMIN_IDS

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
FERNET_KEY=$FERNET_KEY

# --- Bot-to-API Authentication ---
BOT_API_KEY=$BOT_API_KEY
BOT_HMAC_SECRET=$BOT_HMAC_SECRET

# --- Initial Operator Account ---
OPERATOR_USERNAME=admin
OPERATOR_PASSWORD=$OPERATOR_PASSWORD

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
ENVEOF

sudo chmod 600 "$MOUNT_TMP/env/.env"

# Generate SSL certificates for PostgreSQL
echo -e "${CYAN}Generating PostgreSQL SSL certificates...${NC}"
openssl req -new -x509 -days 3650 -nodes \
    -out "$MOUNT_TMP/postgres/ssl/ca.crt" \
    -keyout "$MOUNT_TMP/postgres/ssl/ca.key" \
    -subj "/CN=SovereignCA" 2>/dev/null

openssl req -new -nodes \
    -out "$MOUNT_TMP/postgres/ssl/server.csr" \
    -keyout "$MOUNT_TMP/postgres/ssl/server.key" \
    -subj "/CN=postgres" 2>/dev/null

openssl x509 -req -days 3650 \
    -in "$MOUNT_TMP/postgres/ssl/server.csr" \
    -CA "$MOUNT_TMP/postgres/ssl/ca.crt" \
    -CAkey "$MOUNT_TMP/postgres/ssl/ca.key" \
    -CAcreateserial \
    -out "$MOUNT_TMP/postgres/ssl/server.crt" 2>/dev/null

rm -f "$MOUNT_TMP/postgres/ssl/server.csr" "$MOUNT_TMP/postgres/ssl/ca.key" "$MOUNT_TMP/postgres/ssl/ca.srl"
sudo chmod 600 "$MOUNT_TMP/postgres/ssl/server.key"

# Set ownership
sudo chown -R 1000:1000 "$MOUNT_TMP/"

# Print summary
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          USB 3 PROVISIONING COMPLETE                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Directory structure:"
find "$MOUNT_TMP" -maxdepth 3 -not -path '*/\.*' | head -30
echo ""
echo -e "${YELLOW}IMPORTANT: Record these credentials securely:${NC}"
echo "  Operator username: admin"
echo "  Operator password: $OPERATOR_PASSWORD"
echo "  Postgres password: $POSTGRES_PASSWORD"
echo ""
echo "Drive UUID (add to drive-uuids.conf):"
blkid "$DEVICE" | grep -oP 'UUID="\K[^"]+'
echo ""

# Record UUID
echo ""
echo -e "${CYAN}Recording drive UUID...${NC}"
DATA_UUID=$(blkid -s UUID -o value "$DEVICE")
echo "Data drive UUID: $DATA_UUID"

# Unmount
sync
sudo umount "$MOUNT_TMP"
rmdir "$MOUNT_TMP"

echo -e "${GREEN}Done. Drive unmounted safely.${NC}"
