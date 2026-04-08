#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_HOME=$(getent passwd "${SUDO_USER:-$(whoami)}" | cut -d: -f6)
TC="$REAL_HOME/threadcount"
SB="$REAL_HOME/sovereign-boot"
OVERLAY="$REAL_HOME/.config/sovereign/compose/docker-compose.sovereign.yml"

echo "=== Enabling Tor ==="

# Install overlay and Tor Dockerfile
mkdir -p "$REAL_HOME/.config/sovereign/compose/tor"
cp "$SB/compose/docker-compose.sovereign.yml" "$OVERLAY"
cp "$SB/compose/tor/Dockerfile" "$REAL_HOME/.config/sovereign/compose/tor/Dockerfile"
sed -i 's/\r$//' "$OVERLAY" "$REAL_HOME/.config/sovereign/compose/tor/Dockerfile"

# Set build context for Tor
export SOVEREIGN_BOOT_DIR="$REAL_HOME/.config/sovereign/compose/tor"

# Build and restart
echo "Building Tor proxy..."
cd "$TC"
docker compose -f docker-compose.yml -f "$OVERLAY" build tor-proxy 2>&1 | tail -5

echo "Starting all services with Tor..."
docker compose -f docker-compose.yml -f "$OVERLAY" up -d --force-recreate

echo "Waiting 60 seconds for Tor to establish circuits..."
sleep 60

echo ""
echo "=== Status ==="
docker ps --format "table {{.Names}}\t{{.Status}}"

echo ""
echo "=== Tor Verification ==="
TOR_CHECK=$(docker exec sovereign-tor curl -sf --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null || echo "FAILED")
echo "Tor exit IP: $TOR_CHECK"

echo ""
BOT_CHECK=$(docker exec sovereign-bot python3 -c "
import os, urllib.request
proxy = urllib.request.ProxyHandler({'https': os.environ.get('HTTPS_PROXY','')})
opener = urllib.request.build_opener(proxy)
print(opener.open('https://check.torproject.org/api/ip').read().decode())
" 2>/dev/null || echo "Bot cannot reach Tor")
echo "Bot via Tor: $BOT_CHECK"
echo ""
