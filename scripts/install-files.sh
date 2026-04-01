#!/bin/bash
set -euo pipefail

# Find source: git clone or transfer USB
SOURCE=""
if [[ -d "/tmp/sovereign-boot/scripts" ]]; then
    SOURCE="/tmp/sovereign-boot"
elif [[ -d "$(dirname "$0")/../config" ]]; then
    SOURCE="$(cd "$(dirname "$0")/.." && pwd)"
else
    TRANSFER=$(find /media -name "TRANSFER" -type d 2>/dev/null | head -1)
    if [[ -n "$TRANSFER" ]]; then
        SOURCE="$TRANSFER/sovereign-boot"
    fi
fi

if [[ -z "$SOURCE" || ! -d "$SOURCE/scripts" ]]; then
    echo "ERROR: Cannot find sovereign-boot source files."
    echo "Clone first: git clone https://github.com/steeldragon666/sovereign-boot.git /tmp/sovereign-boot"
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
HOME_DIR=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "Installing from $SOURCE to $HOME_DIR (user: $REAL_USER)"

mkdir -p "$HOME_DIR/.config/sovereign/compose"
mkdir -p "$HOME_DIR/.local/bin"

cp "$SOURCE/config/"* "$HOME_DIR/.config/sovereign/"
cp "$SOURCE/scripts/"* "$HOME_DIR/.local/bin/"
cp "$SOURCE/compose/"* "$HOME_DIR/.config/sovereign/compose/"

find "$HOME_DIR/.config/sovereign" "$HOME_DIR/.local/bin" -type f -exec sed -i 's/\r$//' {} +
find "$HOME_DIR/.local/bin" -name '*.sh' -exec chmod 755 {} +
find "$HOME_DIR/.config/sovereign" -type f -exec chmod 644 {} +
chown -R "$REAL_USER:$REAL_USER" "$HOME_DIR/.config/sovereign" "$HOME_DIR/.local/bin"

echo ""
grep -E "UUID|LABEL" "$HOME_DIR/.config/sovereign/drive-uuids.conf" || true
echo ""
echo "DONE. Run with: sudo bash ~/.local/bin/sovereign-boot.sh"
