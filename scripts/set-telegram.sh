#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi

# Find .env on Apricorn
ENV=""
for path in /mnt/sovereign/data/env/.env /media/*/SOVEREIGN/env/.env; do
    [[ -f "$path" ]] && ENV="$path" && break
done
[[ -z "$ENV" ]] && { echo "ERROR: .env not found. Mount Apricorn first."; exit 1; }

sed -i 's/PASTE_YOUR_BOT_TOKEN_HERE/AAGL_FKdviqw3egkvJbdoPuNCr_Eo_gwx74/' "$ENV"
sed -i 's/PASTE_YOUR_TELEGRAM_USER_ID_HERE/5410979519/' "$ENV"
echo "Telegram config updated:"
grep TELEGRAM "$ENV"
echo "DONE"
