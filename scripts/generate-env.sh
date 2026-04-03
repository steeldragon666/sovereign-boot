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

mkdir -p "$DATA/env"

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

echo ""
echo "Generated .env:"
cat "$DATA/env/.env"
echo ""
echo "DONE"
