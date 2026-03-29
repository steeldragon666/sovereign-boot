#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Health Check — Pre-Launch Integrity Verification
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/sovereign"

# Source mount paths
eval "$(grep -v '^\[' "$CONFIG_DIR/mount-points.conf" | grep -v '^#' | grep -v '^$' | sed 's/ *= */=/')"

ERRORS=0
WARNINGS=0

pass() { echo -e "  \033[0;32m✓\033[0m $1"; }
fail() { echo -e "  \033[0;31m✗\033[0m $1"; ((ERRORS++)); }
warn() { echo -e "  \033[1;33m⚠\033[0m $1"; ((WARNINGS++)); }

echo ""
echo "═══════════════════════════════════════════"
echo "  Sovereign Health Check"
echo "═══════════════════════════════════════════"
echo ""

# ---- Drive Mounts ----
echo "Drive Mounts:"
mountpoint -q "$PROGRAM_MOUNT" 2>/dev/null && pass "Program drive mounted at $PROGRAM_MOUNT" || fail "Program drive NOT mounted"
mount | grep "$PROGRAM_MOUNT" | grep -q 'ro,' 2>/dev/null && pass "Program drive is read-only" || fail "Program drive is NOT read-only"
mountpoint -q "$DATA_MOUNT" 2>/dev/null && pass "Data drive mounted at $DATA_MOUNT" || fail "Data drive NOT mounted"
mount | grep "$DATA_MOUNT" | grep -q 'rw,' 2>/dev/null && pass "Data drive is read-write" || fail "Data drive is NOT read-write"

# ---- Data Drive Structure ----
echo ""
echo "Data Drive Structure:"
[[ -f "$ENV_DIR/.env" ]] && pass ".env file exists" || fail ".env file MISSING at $ENV_DIR/.env"
[[ -d "$DB_DIR" ]] && pass "PostgreSQL data directory exists" || fail "PostgreSQL data directory MISSING"
[[ -d "$REDIS_DIR" ]] && pass "Redis data directory exists" || fail "Redis data directory MISSING"
[[ -d "$LOG_DIR" ]] && pass "Log directory exists" || fail "Log directory MISSING"
[[ -d "$BACKUP_DIR" ]] && pass "Backup directory exists" || fail "Backup directory MISSING"
[[ -d "$TOR_DIR" ]] && pass "Tor state directory exists" || warn "Tor state directory missing (will be created on first run)"
[[ -d "$SSL_DIR" ]] && pass "SSL certificate directory exists" || warn "SSL certificate directory missing"

# ---- Docker ----
echo ""
echo "Docker:"
systemctl is-active docker &>/dev/null && pass "Docker daemon is running" || fail "Docker daemon is NOT running"
docker info &>/dev/null && pass "Docker CLI is functional" || fail "Docker CLI cannot connect to daemon"

# Count loaded images
local_images=$(docker images --format '{{.Repository}}' 2>/dev/null | grep -cE '(sovereign|postgres|redis|caddy|tor)' || true)
if [[ "$local_images" -ge 6 ]]; then
    pass "All Docker images loaded ($local_images found)"
elif [[ "$local_images" -ge 1 ]]; then
    warn "Only $local_images/7 Docker images loaded"
else
    fail "No sovereign Docker images loaded"
fi

# ---- Program Drive Integrity ----
echo ""
echo "Program Drive Integrity:"
if [[ -f "$PROGRAM_MOUNT/MANIFEST.sha256" ]]; then
    cd "$PROGRAM_MOUNT"
    if sha256sum -c MANIFEST.sha256 --quiet 2>/dev/null; then
        pass "MANIFEST.sha256 — all checksums match"
    else
        fail "MANIFEST.sha256 — checksum mismatch detected!"
    fi
    cd - >/dev/null
else
    warn "No MANIFEST.sha256 found on program drive (integrity check skipped)"
fi

# ---- Security ----
echo ""
echo "Security:"
[[ $(swapon --show 2>/dev/null | wc -l) -eq 0 ]] && pass "No swap enabled" || fail "Swap is enabled — security risk"

# Check internal drives are blocked
internal_mounted=false
for dev in /dev/sda /dev/nvme0n1 /dev/nvme1n1; do
    if mount | grep -q "^${dev}"; then
        if ! mount | grep -q "sovereign"; then
            internal_mounted=true
        fi
    fi
done
$internal_mounted && fail "Internal drive is mounted" || pass "No internal drives mounted"

# Check firewall is loaded
if nft list ruleset 2>/dev/null | grep -q "sovereign"; then
    pass "Sovereign firewall rules loaded"
else
    warn "Sovereign firewall rules not detected"
fi

# ---- Summary ----
echo ""
echo "═══════════════════════════════════════════"
if [[ "$ERRORS" -gt 0 ]]; then
    echo -e "  \033[0;31mFAILED: $ERRORS error(s), $WARNINGS warning(s)\033[0m"
    echo "═══════════════════════════════════════════"
    exit 1
elif [[ "$WARNINGS" -gt 0 ]]; then
    echo -e "  \033[1;33mPASSED with $WARNINGS warning(s)\033[0m"
    echo "═══════════════════════════════════════════"
    exit 0
else
    echo -e "  \033[0;32mALL CHECKS PASSED\033[0m"
    echo "═══════════════════════════════════════════"
    exit 0
fi
