#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with sudo"; exit 1; fi
ENV="/mnt/sovereign/data/env/.env"
if [[ ! -f "$ENV" ]]; then echo "ERROR: $ENV not found. Run generate-env.sh first."; exit 1; fi
sed -i 's/PASTE_YOUR_BOT_TOKEN_HERE/AAGL_FKdviqw3egkvJbdoPuNCr_Eo_gwx74/' "$ENV"
sed -i 's/PASTE_YOUR_TELEGRAM_USER_ID_HERE/5410979519/' "$ENV"
echo "Telegram config updated:"
grep TELEGRAM "$ENV"
echo "DONE"
