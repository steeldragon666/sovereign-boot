#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0 <TOKEN> <ADMIN_ID>"; exit 1; fi
if [[ -z "$1" ]]; then echo "Usage: sudo bash $0 <BOT_TOKEN> <ADMIN_ID>"; exit 1; fi

TOKEN="$1"
ADMIN_ID="${2:-5410979519}"
REAL_HOME=$(getent passwd "${SUDO_USER:-$(whoami)}" | cut -d: -f6)
ENV="$REAL_HOME/threadcount/.env"

echo "Updating $ENV..."

# Use python to do the replacement — no sed quote issues
python3 << PYEOF
import re
with open("$ENV", "r") as f:
    content = f.read()
content = re.sub(r"TELEGRAM_BOT_TOKEN=.*", f"TELEGRAM_BOT_TOKEN=$TOKEN", content)
content = re.sub(r"TELEGRAM_ADMIN_IDS=.*", f"TELEGRAM_ADMIN_IDS=$ADMIN_ID", content)
with open("$ENV", "w") as f:
    f.write(content)
PYEOF

echo "Verifying .env:"
grep TELEGRAM "$ENV"

echo "Recreating bot container..."
cd "$REAL_HOME/threadcount" && docker compose up -d --force-recreate bot

sleep 5
echo ""
echo "Container token:"
docker exec sovereign-bot env | grep TELEGRAM_BOT_TOKEN

echo ""
echo "Bot logs:"
docker logs sovereign-bot 2>&1 | tail -5
echo ""
echo "DONE — send /start to your bot now"
