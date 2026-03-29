#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — Build and Export Docker Images
# Run on a machine with Docker to update USB 2 image tarballs.
# USB 2 must be LUKS-open and mounted.
# ============================================================

CYAN='\033[0;36m'
GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

PROGRAM_MOUNT="${1:-/mnt/sovereign/program}"

if ! mountpoint -q "$PROGRAM_MOUNT" 2>/dev/null; then
    echo -e "${RED}Program drive not mounted at $PROGRAM_MOUNT${NC}"
    echo "Usage: $0 [mount_point]"
    exit 1
fi

TC_DIR="$PROGRAM_MOUNT/threadcount"
IMAGES_DIR="$PROGRAM_MOUNT/images"

if [[ ! -f "$TC_DIR/docker-compose.yml" ]]; then
    echo -e "${RED}ThreadCount not found at $TC_DIR${NC}"
    exit 1
fi

# Pull latest code
echo -e "${CYAN}Pulling latest ThreadCount...${NC}"
cd "$TC_DIR"
git pull origin main

# Build
echo -e "${CYAN}Building Docker images...${NC}"
docker compose build

# Export
echo -e "${CYAN}Exporting images...${NC}"
mkdir -p "$IMAGES_DIR"

docker save threadcount-api:latest       -o "$IMAGES_DIR/sovereign-api.tar" 2>/dev/null || true
docker save threadcount-bot:latest       -o "$IMAGES_DIR/sovereign-bot.tar" 2>/dev/null || true
docker save threadcount-dashboard:latest -o "$IMAGES_DIR/sovereign-dashboard.tar" 2>/dev/null || true
docker save caddy:2-alpine              -o "$IMAGES_DIR/caddy.tar"
docker save postgres:16-alpine          -o "$IMAGES_DIR/postgres.tar"
docker save redis:7-alpine              -o "$IMAGES_DIR/redis.tar"
docker save osminogin/tor-simple:latest -o "$IMAGES_DIR/tor-simple.tar"

# Regenerate manifest
cd "$PROGRAM_MOUNT"
find . -type f ! -name 'MANIFEST.sha256' -exec sha256sum {} \; > MANIFEST.sha256

echo ""
echo -e "${GREEN}Images updated and manifest regenerated.${NC}"
ls -lh "$IMAGES_DIR/"
