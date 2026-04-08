#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi

if [[ -z "$1" || -z "$2" ]]; then
    echo "Usage: sudo bash $0 <BOT_TOKEN> <ADMIN_ID>"
    exit 1
fi

TOKEN="$1"
ADMIN_ID="$2"

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

ENV="$REAL_HOME/threadcount/.env"
if [[ ! -f "$ENV" ]]; then
    echo "ERROR: $ENV not found"
    exit 1
fi

sed -i "s|TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$TOKEN|" "$ENV"
sed -i "s|TELEGRAM_ADMIN_IDS=.*|TELEGRAM_ADMIN_IDS=$ADMIN_ID|" "$ENV"
echo "Updated $ENV:"
grep TELEGRAM "$ENV"
echo "DONE"
