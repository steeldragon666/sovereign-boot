#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi

if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: sudo bash $0 <BOT_TOKEN> <ADMIN_ID>"
    echo "  BOT_TOKEN: from @BotFather (format: 123456:ABC...)"
    echo "  ADMIN_ID:  your numeric Telegram user ID"
    exit 1
fi

TOKEN="$1"
ADMIN_ID="$2"

# Find .env
ENV=""
for path in ~/threadcount/.env /mnt/sovereign/data/env/.env /media/*/SOVEREIGN/env/.env; do
    [[ -f "$path" ]] && ENV="$path" && break
done
[[ -z "$ENV" ]] && { echo "ERROR: .env not found"; exit 1; }

sed -i "s|TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$TOKEN|" "$ENV"
sed -i "s|TELEGRAM_ADMIN_IDS=.*|TELEGRAM_ADMIN_IDS=$ADMIN_ID|" "$ENV"
echo "Updated $ENV:"
grep TELEGRAM "$ENV"
echo "DONE"
