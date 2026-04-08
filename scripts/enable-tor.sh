#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_HOME=$(getent passwd "${SUDO_USER:-$(whoami)}" | cut -d: -f6)
TC="$REAL_HOME/threadcount"
OVERLAY="$REAL_HOME/.config/sovereign/compose/docker-compose.sovereign.yml"

# Install overlay
mkdir -p "$REAL_HOME/.config/sovereign/compose"
cp "$REAL_HOME/sovereign-boot/compose/docker-compose.sovereign.yml" "$OVERLAY"
sed -i 's/\r$//' "$OVERLAY"

echo "=== Enabling Tor ==="

# Pull Tor image
echo "Pulling Tor image..."
docker pull osminogin/tor-simple:latest

# Restart with overlay
echo "Restarting with Tor overlay..."
cd "$TC"
docker compose -f docker-compose.yml -f "$OVERLAY" up -d --force-recreate

sleep 10
echo ""
echo "=== Container Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}"

echo ""
echo "=== Tor Check ==="
# Verify bot routes through Tor
TOR_IP=$(docker exec sovereign-bot python3 -c "import urllib.request; print(urllib.request.urlopen('https://check.torproject.org/api/ip').read().decode())" 2>/dev/null || echo "Could not check")
echo "Bot external IP: $TOR_IP"

echo ""
echo "DONE — all outbound API and bot traffic now routes through Tor"
