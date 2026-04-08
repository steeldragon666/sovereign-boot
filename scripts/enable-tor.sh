#!/bin/bash
if [[ $EUID -ne 0 ]]; then echo "Run with: sudo bash $0"; exit 1; fi

REAL_HOME=$(getent passwd "${SUDO_USER:-$(whoami)}" | cut -d: -f6)
TC="$REAL_HOME/threadcount"
SB="$REAL_HOME/sovereign-boot"
OVERLAY="$TC/docker-compose.sovereign.yml"

echo "=== Enabling Tor ==="

# Copy overlay into threadcount directory (so build contexts resolve correctly)
cp "$SB/compose/docker-compose.sovereign.yml" "$OVERLAY"
sed -i 's/\r$//' "$OVERLAY"

# Copy Tor Dockerfile into threadcount/tor-proxy/
mkdir -p "$TC/tor-proxy"
cp "$SB/compose/tor/Dockerfile" "$TC/tor-proxy/Dockerfile"
sed -i 's/\r$//' "$TC/tor-proxy/Dockerfile"

echo "  ✓ Overlay and Tor Dockerfile installed"

# Build Tor and restart everything
cd "$TC"
echo "  Building Tor proxy..."
docker compose -f docker-compose.yml -f docker-compose.sovereign.yml build tor-proxy 2>&1 | tail -5

echo "  Starting all services with Tor..."
docker compose -f docker-compose.yml -f docker-compose.sovereign.yml up -d 2>&1

echo "  Waiting 30 seconds for Tor circuits..."
sleep 30

echo ""
docker ps --format "table {{.Names}}\t{{.Status}}"
echo ""

# Test Tor
echo "=== Tor Test ==="
docker exec sovereign-tor curl -sf --socks5-hostname 127.0.0.1:9050 https://check.torproject.org/api/ip 2>/dev/null && echo "" || echo "Tor not ready yet — may need another 30 seconds"
echo ""
