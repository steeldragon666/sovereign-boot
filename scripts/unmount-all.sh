#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Emergency Unmount
# Call manually if sovereign-boot.sh crashes or you need
# to quickly tear down and remove drives.
# ============================================================

CONFIG_DIR="$HOME/.config/sovereign"

# Source mount paths
if [[ -f "$CONFIG_DIR/mount-points.conf" ]]; then
    eval "$(grep -v '^\[' "$CONFIG_DIR/mount-points.conf" | grep -v '^#' | grep -v '^$' | sed 's/ *= */=/')"
else
    # Fallback defaults if config not found
    PROGRAM_MOUNT=/mnt/sovereign/program
    DATA_MOUNT=/mnt/sovereign/data
fi

echo "╔═══════════════════════════════════════════╗"
echo "║     EMERGENCY UNMOUNT INITIATED           ║"
echo "╚═══════════════════════════════════════════╝"

# Stop Docker containers if running
if docker compose ls 2>/dev/null | grep -q "sovereign"; then
    echo "Stopping Docker containers..."
    docker compose down --timeout 10 2>/dev/null || true
fi

# Sync all pending writes
echo "Syncing filesystem..."
sync

# Unmount in reverse order (data last, it has the logs)
for mp in "$DATA_MOUNT" "$PROGRAM_MOUNT"; do
    if mountpoint -q "$mp" 2>/dev/null; then
        sudo umount -l "$mp" && echo "Unmounted $mp" || echo "WARN: Failed to unmount $mp"
    else
        echo "Not mounted: $mp"
    fi
done

# Close LUKS if open
if [[ -e /dev/mapper/sovereign_program ]]; then
    sudo cryptsetup luksClose sovereign_program && echo "LUKS closed: sovereign_program" || echo "WARN: Failed to close LUKS"
else
    echo "LUKS not open: sovereign_program"
fi

echo ""
echo "Done. Safe to remove USB drives."
