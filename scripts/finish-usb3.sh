#!/bin/bash
set -euo pipefail

# Finish provisioning USB 3 (Apricorn)
# Run on Ubuntu laptop with Apricorn mounted at /mnt/sovereign/data

DATA="/mnt/sovereign/data"

if [ ! -d "$DATA" ]; then
    echo "ERROR: $DATA not found. Mount the Apricorn first."
    exit 1
fi

echo "=== Creating directories ==="
mkdir -p "$DATA"/{env,postgres/data,postgres/ssl,redis/data,caddy/data,caddy/config,tor,logs,backups}

echo "=== Generating .env ==="
cat > "$DATA/env/.env" << EOF
POSTGRES_USER=threadcount
POSTGRES_PASSWORD=$(openssl rand -hex 32)
POSTGRES_DB=threadcount
REDIS_PASSWORD=$(openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 64)
FERNET_KEY=$(openssl rand -base64 32)
TELEGRAM_BOT_TOKEN=PASTE_YOUR_TOKEN_HERE
ENVIRONMENT=production
DEBUG=false
EOF

echo "=== Generating SSL certs for Postgres ==="
openssl req -x509 -newkey rsa:4096 -keyout "$DATA/postgres/ssl/server.key" \
    -out "$DATA/postgres/ssl/server.crt" -days 3650 -nodes \
    -subj "/CN=sovereign-postgres"
cp "$DATA/postgres/ssl/server.crt" "$DATA/postgres/ssl/ca.crt"
chmod 600 "$DATA/postgres/ssl/server.key"

echo "=== Done ==="
echo ""
cat "$DATA/env/.env"
echo ""
echo "USB 3 provisioned. Replace TELEGRAM_BOT_TOKEN with your real token later."
