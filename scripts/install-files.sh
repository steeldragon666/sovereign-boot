#!/bin/bash
set -euo pipefail

TRANSFER=$(find /media -name "TRANSFER" -type d 2>/dev/null | head -1)
if [ -z "$TRANSFER" ]; then
    echo "ERROR: Transfer USB not found."
    exit 1
fi

REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
HOME_DIR=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "Installing from $TRANSFER to $HOME_DIR (user: $REAL_USER)"

mkdir -p "$HOME_DIR/.config/sovereign/compose"
mkdir -p "$HOME_DIR/.local/bin"

cp "$TRANSFER/sovereign-boot/config/"* "$HOME_DIR/.config/sovereign/"
cp "$TRANSFER/sovereign-boot/scripts/"* "$HOME_DIR/.local/bin/"
cp "$TRANSFER/sovereign-boot/compose/"* "$HOME_DIR/.config/sovereign/compose/"

# Fix line endings, permissions, ownership
find "$HOME_DIR/.config/sovereign" "$HOME_DIR/.local/bin" -type f -exec sed -i 's/\r$//' {} +
find "$HOME_DIR/.local/bin" -name '*.sh' -exec chmod 755 {} +
find "$HOME_DIR/.config/sovereign" -type f -exec chmod 644 {} +
chown -R "$REAL_USER:$REAL_USER" "$HOME_DIR/.config/sovereign" "$HOME_DIR/.local/bin"

echo ""
echo "=== Installed ==="
ls -la "$HOME_DIR/.local/bin/"*.sh
echo ""
grep -E "UUID|LABEL" "$HOME_DIR/.config/sovereign/drive-uuids.conf" || true
echo ""
echo "DONE. Run with: sudo bash ~/.local/bin/sovereign-boot.sh"
