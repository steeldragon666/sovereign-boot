# Sovereign Boot System Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build all scripts, configs, and compose files for a three-USB sovereign boot system that runs ThreadCount through Tor on a hardened Debian USB drive.

**Architecture:** Separate repo (`sovereign-boot/`) wraps ThreadCount. Config files define drive identities and mount paths. A Docker Compose override redirects all volumes to the Apricorn data drive and adds a Tor proxy. Boot scripts orchestrate the entire sequence from LUKS unlock through Docker launch. Provisioning scripts automate one-time USB setup.

**Tech Stack:** Bash (scripts), Docker Compose (orchestration), nftables (firewall), udev (USB whitelist), LUKS2/cryptsetup (encryption), debootstrap (OS install), Tor (network privacy)

**Design doc:** `docs/plans/2026-03-29-sovereign-boot-design.md`

---

## Task 1: Configuration Files

These are the foundation — every other script sources them.

**Files:**
- Create: `config/drive-uuids.conf`
- Create: `config/mount-points.conf`

**Step 1: Create drive-uuids.conf**

```ini
# Sovereign Security — Drive Identity Configuration
# Fill in UUIDs during drive provisioning (blkid /dev/sdX)
# Fill in serial numbers from: udevadm info --query=all --name=/dev/sdX | grep ID_SERIAL_SHORT

[program_drive]
UUID=PLACEHOLDER-FILL-DURING-PROVISIONING
LUKS_LABEL=SOVEREIGN_PROGRAM
EXPECTED_FS=ext4

[data_drive]
UUID=PLACEHOLDER-FILL-DURING-PROVISIONING
DEVICE_LABEL=SOVEREIGN_DATA
EXPECTED_FS=ext4

[serial_numbers]
PROGRAM_DRIVE_SERIAL=PLACEHOLDER
DATA_DRIVE_SERIAL=PLACEHOLDER
```

**Step 2: Create mount-points.conf**

```ini
[paths]
PROGRAM_MOUNT=/mnt/sovereign/program
DATA_MOUNT=/mnt/sovereign/data
ENV_DIR=/mnt/sovereign/data/env
LOG_DIR=/mnt/sovereign/data/logs
DB_DIR=/mnt/sovereign/data/postgres/data
REDIS_DIR=/mnt/sovereign/data/redis/data
CADDY_DATA_DIR=/mnt/sovereign/data/caddy/data
CADDY_CONFIG_DIR=/mnt/sovereign/data/caddy/config
TOR_DIR=/mnt/sovereign/data/tor
BACKUP_DIR=/mnt/sovereign/data/backups
SSL_DIR=/mnt/sovereign/data/postgres/ssl
```

**Step 3: Verify files parse cleanly**

Run:
```bash
# Confirm no syntax errors — should print variable assignments with no errors
grep -v '^\[' config/drive-uuids.conf | grep -v '^#' | grep -v '^$' | grep '='
grep -v '^\[' config/mount-points.conf | grep -v '^#' | grep -v '^$' | grep '='
```

Expected: Clean list of KEY=VALUE lines, no errors.

**Step 4: Commit**

```bash
git add config/drive-uuids.conf config/mount-points.conf
git commit -m "feat: add drive UUID and mount point configuration files"
```

---

## Task 2: Docker Compose Sovereign Override

This is the critical glue between ThreadCount and the 3-USB architecture.

**Files:**
- Create: `compose/docker-compose.sovereign.yml`

**Step 1: Create the override file**

This file is used with `-f` flag alongside ThreadCount's stock `docker-compose.yml`. It:
- Redirects all named volumes to bind-mounts on USB 3
- Adds the Tor SOCKS proxy container
- Injects HTTPS_PROXY into bot and api
- Points env_file to USB 3
- Adds redis-socket tmpfs for performance

Reference ThreadCount's stock compose at: https://github.com/steeldragon666/threadcount/blob/main/docker-compose.yml

Key points from the stock file:
- Named volumes: `pgdata`, `redis-socket`, `redis-data`, `backups`, `caddy-data`, `caddy-config`, `postgres-logs`
- Services: `postgres`, `redis`, `api`, `bot`, `dashboard`, `caddy`
- Network: `sovereign-net` (bridge)
- Redis uses Unix socket at `/var/run/redis/redis.sock`
- API and bot use `env_file: .env`
- Caddy binds `127.0.0.1:80` and `127.0.0.1:443`

```yaml
# docker-compose.sovereign.yml
# Sovereign Boot overlay — redirects all state to Apricorn USB 3
# Usage: docker compose -f /path/to/threadcount/docker-compose.yml -f /path/to/docker-compose.sovereign.yml up -d

services:
  # ── Tor SOCKS Proxy (new service) ──────────────────────────
  tor-proxy:
    image: osminogin/tor-simple:latest
    container_name: sovereign-tor
    restart: unless-stopped
    networks:
      - sovereign-net
    volumes:
      - /mnt/sovereign/data/tor:/var/lib/tor
    deploy:
      resources:
        limits:
          memory: 128M
          cpus: "0.25"

  # ── PostgreSQL — redirect data to USB 3 ────────────────────
  postgres:
    volumes:
      - /mnt/sovereign/data/postgres/data:/var/lib/postgresql/data
      - /mnt/sovereign/data/postgres/ssl/ca.crt:/etc/ssl/certs/ca.crt:ro
      - /mnt/sovereign/data/logs/postgres:/var/log/postgresql
    env_file:
      - /mnt/sovereign/data/env/.env

  # ── Redis — data on USB 3, socket on tmpfs ─────────────────
  redis:
    volumes:
      - /mnt/sovereign/data/redis/data:/data
      - type: tmpfs
        target: /var/run/redis
        tmpfs:
          size: 10M

  # ── FastAPI Backend — route through Tor ────────────────────
  api:
    env_file:
      - /mnt/sovereign/data/env/.env
    environment:
      HTTP_PROXY: socks5h://tor-proxy:9050
      HTTPS_PROXY: socks5h://tor-proxy:9050
      NO_PROXY: postgres,redis,localhost,127.0.0.1
    volumes:
      - /mnt/sovereign/data/backups:/backups
      - /mnt/sovereign/data/postgres/ssl/ca.crt:/etc/ssl/certs/ca.crt:ro
    depends_on:
      tor-proxy:
        condition: service_started

  # ── Telegram Bot — route through Tor ───────────────────────
  bot:
    env_file:
      - /mnt/sovereign/data/env/.env
    environment:
      HTTP_PROXY: socks5h://tor-proxy:9050
      HTTPS_PROXY: socks5h://tor-proxy:9050
      NO_PROXY: api,postgres,redis,localhost,127.0.0.1
    depends_on:
      tor-proxy:
        condition: service_started

  # ── Caddy — redirect state to USB 3 ───────────────────────
  caddy:
    volumes:
      - /mnt/sovereign/data/caddy/data:/data
      - /mnt/sovereign/data/caddy/config:/config

  # ── Dashboard — no changes needed ─────────────────────────
  dashboard: {}

# Override named volumes — we don't use them, but must declare
# them to prevent docker compose from creating default ones
volumes:
  pgdata:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/sovereign/data/postgres/data
  redis-socket:
    driver: local
    driver_opts:
      type: tmpfs
      device: tmpfs
      o: size=10m
  redis-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/sovereign/data/redis/data
  backups:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/sovereign/data/backups
  caddy-data:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/sovereign/data/caddy/data
  caddy-config:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/sovereign/data/caddy/config
  postgres-logs:
    driver: local
    driver_opts:
      type: none
      o: bind
      device: /mnt/sovereign/data/logs/postgres
```

**Step 2: Validate YAML syntax**

Run:
```bash
python3 -c "import yaml; yaml.safe_load(open('compose/docker-compose.sovereign.yml'))" 2>&1 || echo "YAML INVALID"
```

If python3/yaml not available:
```bash
docker compose -f compose/docker-compose.sovereign.yml config 2>&1 | head -5
```

Expected: No syntax errors (compose config may warn about missing base file — that's OK, we only validate syntax here).

**Step 3: Commit**

```bash
git add compose/docker-compose.sovereign.yml
git commit -m "feat: add Docker Compose sovereign override with Tor proxy and USB 3 volumes"
```

---

## Task 3: nftables Firewall Rules

**Files:**
- Create: `config/sovereign-firewall.nft`

**Step 1: Write the firewall ruleset**

This enforces Tor-only outbound at the host level. Even if a Docker container is compromised, it cannot bypass Tor.

```nft
#!/usr/sbin/nft -f
# Sovereign Security — nftables firewall
# All outbound traffic must go through Tor. No exceptions.

flush ruleset

table inet sovereign {

    chain input {
        type filter hook input priority 0; policy drop;

        # Allow loopback (localhost dashboard, Docker inter-container)
        iif "lo" accept

        # Allow established/related connections
        ct state established,related accept

        # Allow Docker bridge traffic (containers talking to each other)
        iifname "docker0" accept
        iifname "br-*" accept

        # Drop everything else inbound
        log prefix "SOVEREIGN_INPUT_DROP: " drop
    }

    chain output {
        type filter hook output priority 0; policy drop;

        # Allow loopback
        oif "lo" accept

        # Allow established/related
        ct state established,related accept

        # Allow Docker bridge traffic
        oifname "docker0" accept
        oifname "br-*" accept

        # Allow Tor process outbound to OR ports and directory authorities
        # Tor uses: 443 (OR port), 9001 (OR port), 9030 (dir port)
        meta skuid "debian-tor" tcp dport { 80, 443, 9001, 9030, 9090, 9091 } accept

        # Allow Tor DNS for bootstrapping (resolves directory authorities)
        meta skuid "debian-tor" udp dport 53 accept

        # Drop everything else outbound
        log prefix "SOVEREIGN_OUTPUT_DROP: " drop
    }

    chain forward {
        type filter hook forward priority 0; policy drop;

        # Allow Docker container-to-container (same bridge network)
        iifname "br-*" oifname "br-*" accept

        # Allow containers to reach Tor proxy (which then goes outbound)
        # The Tor container's outbound is handled by the output chain above
        iifname "br-*" oif "lo" accept

        # Allow established/related forwarded traffic
        ct state established,related accept

        # Drop direct internet access from containers (must go through Tor SOCKS)
        log prefix "SOVEREIGN_FORWARD_DROP: " drop
    }
}
```

**Step 2: Validate syntax (on a Linux machine or container)**

Run:
```bash
# Syntax check only — does not apply rules
nft -c -f config/sovereign-firewall.nft 2>&1 || echo "NFT SYNTAX ERROR"
```

If not on Linux, defer validation to USB 1 provisioning.

**Step 3: Commit**

```bash
git add config/sovereign-firewall.nft
git commit -m "feat: add nftables firewall enforcing Tor-only outbound traffic"
```

---

## Task 4: udev USB Whitelist Rules

**Files:**
- Create: `config/99-sovereign-usb.rules`

**Step 1: Write the udev rules**

Serial numbers are placeholders — filled during provisioning when physical drives are available.

```udev
# Sovereign Security — USB Device Whitelist
# Only known USB drives are permitted. All others are blocked and logged.
# Install to: /etc/udev/rules.d/99-sovereign-usb.rules
# Discover serials: udevadm info --query=all --name=/dev/sdX | grep ID_SERIAL_SHORT

# --- Block all unknown USB mass storage by default ---
ACTION=="add", SUBSYSTEMS=="usb", DRIVERS=="usb-storage", \
    ENV{ID_SERIAL_SHORT}!="PROGRAM_DRIVE_SERIAL", \
    ENV{ID_SERIAL_SHORT}!="DATA_DRIVE_SERIAL", \
    ATTR{authorized}="0", \
    RUN+="/bin/sh -c 'echo \"[$(date +%%Y-%%m-%%dT%%H:%%M:%%S)] UNAUTHORIZED USB: vendor=%s{idVendor} product=%s{idProduct} serial=%E{ID_SERIAL_SHORT}\" >> /tmp/sovereign-usb-audit.log'"

# --- Whitelist USB 2 (Program drive) ---
ACTION=="add", SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="PROGRAM_DRIVE_SERIAL", \
    ATTR{authorized}="1"

# --- Whitelist USB 3 (Apricorn data drive) ---
ACTION=="add", SUBSYSTEM=="block", ENV{ID_SERIAL_SHORT}=="DATA_DRIVE_SERIAL", \
    ATTR{authorized}="1"
```

**Step 2: Commit**

```bash
git add config/99-sovereign-usb.rules
git commit -m "feat: add udev rules for USB device whitelisting"
```

---

## Task 5: XDG Autostart Desktop Entry

**Files:**
- Create: `desktop/sovereign-boot.desktop`

**Step 1: Create the desktop entry**

This makes `sovereign-boot.sh` launch automatically in a terminal when the Xfce session starts.

```ini
[Desktop Entry]
Type=Application
Name=Sovereign Security Boot
Exec=xfce4-terminal --title="Sovereign Boot" --maximize -e /home/sovereign/.local/bin/sovereign-boot.sh
Terminal=false
X-GNOME-Autostart-enabled=true
X-XFCE-Autostart-Override=true
Comment=Mounts encrypted drives and launches ThreadCount through Tor
Icon=security-high
StartupNotify=true
```

Note: `Terminal=false` because we explicitly launch `xfce4-terminal` — this gives us control over the terminal window (title, maximize). If `Terminal=true`, Xfce chooses the terminal emulator which may not maximize.

**Step 2: Commit**

```bash
git add desktop/sovereign-boot.desktop
git commit -m "feat: add XDG autostart entry for sovereign boot"
```

---

## Task 6: Health Check Script

**Files:**
- Create: `scripts/sovereign-health-check.sh`

**Step 1: Write the health check**

This runs after both drives are mounted, before Docker starts. It verifies every precondition.

```bash
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
```

**Step 2: Make executable**

```bash
chmod +x scripts/sovereign-health-check.sh
```

**Step 3: Commit**

```bash
git add scripts/sovereign-health-check.sh
git commit -m "feat: add pre-launch health check script"
```

---

## Task 7: Emergency Unmount Script

**Files:**
- Create: `scripts/unmount-all.sh`

**Step 1: Write the emergency unmount**

```bash
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
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/unmount-all.sh
git add scripts/unmount-all.sh
git commit -m "feat: add emergency unmount script"
```

---

## Task 8: Main Orchestrator — sovereign-boot.sh

This is the largest script. It ties everything together.

**Files:**
- Create: `scripts/sovereign-boot.sh`

**Step 1: Write the main boot script**

```bash
#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security Boot — Main Orchestration Script
# Runs at session start via XDG autostart on Debian USB 1
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$HOME/.config/sovereign"
LOG_FILE="/tmp/sovereign-boot.log"

# ---- Colors ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

# ---- Logging ----
log() {
    local level="$1"; shift
    local msg="$1"; shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${msg}" | tee -a "$LOG_FILE"
}

banner() {
    clear
    echo -e "${CYAN}"
    echo "╔═══════════════════════════════════════════════════════╗"
    echo "║          SOVEREIGN SECURITY BOOT SYSTEM              ║"
    echo "║            Initializing Secure Session                ║"
    echo "╚═══════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
}

# ---- Source Configuration ----
source_config() {
    for conf in drive-uuids.conf mount-points.conf; do
        local path="$CONFIG_DIR/$conf"
        if [[ ! -f "$path" ]]; then
            log "FATAL" "Config not found: $path"
            exit 1
        fi
        eval "$(grep -v '^\[' "$path" | grep -v '^#' | grep -v '^$' | sed 's/ *= */=/')"
    done
    log "INFO" "Configuration loaded"
}

# ---- Verify Environment ----
verify_environment() {
    log "INFO" "Verifying environment..."

    # Confirm we're on the sovereign Debian system (not internal SSD)
    if [[ ! -f /etc/sovereign-boot-marker ]]; then
        log "FATAL" "Not running on sovereign boot drive. Aborting."
        echo -e "${RED}This script must run on the sovereign Debian USB boot drive.${NC}"
        exit 1
    fi

    # Check available RAM
    local avail_mb
    avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    if [[ "$avail_mb" -lt 4096 ]]; then
        log "WARN" "Low available RAM: ${avail_mb}MB (need ~3GB for Docker services)"
    fi

    # Ensure Docker is running
    if ! systemctl is-active --quiet docker; then
        log "INFO" "Starting Docker daemon..."
        sudo systemctl start docker
        sleep 2
    fi

    log "INFO" "Environment OK — RAM: ${avail_mb}MB available, Docker running"
}

# ---- Deploy Security Controls ----
deploy_security() {
    log "INFO" "Deploying security controls..."

    # Deploy nftables firewall
    local fw_rules="$CONFIG_DIR/sovereign-firewall.nft"
    if [[ -f "$fw_rules" ]]; then
        sudo nft -f "$fw_rules"
        log "INFO" "Firewall deployed (Tor-only outbound)"
    else
        log "WARN" "Firewall rules not found at $fw_rules"
    fi

    # Deploy udev USB whitelist
    local udev_rules="$CONFIG_DIR/99-sovereign-usb.rules"
    if [[ -f "$udev_rules" ]]; then
        sudo cp "$udev_rules" /etc/udev/rules.d/99-sovereign-usb.rules
        sudo udevadm control --reload-rules
        sudo udevadm trigger
        log "INFO" "USB whitelist rules deployed"
    fi

    # Block internal drives
    for dev in /dev/sda /dev/nvme0n1 /dev/nvme1n1; do
        if [[ -b "$dev" ]]; then
            sudo chmod 000 "$dev"
            log "INFO" "Blocked internal drive: $dev"
        fi
    done

    # Kill swap
    sudo swapoff -a 2>/dev/null || true
    log "INFO" "Swap disabled"

    # Screen lock on idle (5 minutes)
    xfce4-screensaver-command --lock-on-sleep 2>/dev/null || true
    xfconf-query -c xfce4-screensaver -p /lock/enabled -s true 2>/dev/null || true
    xfconf-query -c xfce4-screensaver -p /lock/saver-activation/delay -s 0 2>/dev/null || true
    xfconf-query -c xfce4-session -p /general/LockCommand -s "xfce4-screensaver-command --lock" 2>/dev/null || true
}

# ---- Mount Program Drive (USB 2) ----
mount_program_drive() {
    log "INFO" "Waiting for program drive (USB 2)..."
    sudo mkdir -p "$PROGRAM_MOUNT"

    echo -e "${YELLOW}Insert the PROGRAM drive (USB 2) and press Enter...${NC}"
    read -r

    # Find by UUID
    local device
    device=$(blkid -U "$UUID" 2>/dev/null || true)
    if [[ -z "$device" ]]; then
        device=$(blkid -L "$LUKS_LABEL" 2>/dev/null || true)
    fi

    if [[ -z "$device" ]]; then
        log "ERROR" "Program drive not found (UUID=$UUID, Label=$LUKS_LABEL)"
        echo -e "${RED}Program drive not detected. Available devices:${NC}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID
        return 1
    fi

    log "INFO" "Found program drive at $device"

    # Open LUKS
    echo -e "${CYAN}Decrypting program drive...${NC}"
    if ! sudo cryptsetup luksOpen "$device" sovereign_program; then
        log "ERROR" "Failed to decrypt program drive"
        return 1
    fi

    # Mount read-only
    if ! sudo mount -o ro,noexec,nosuid,nodev /dev/mapper/sovereign_program "$PROGRAM_MOUNT"; then
        log "ERROR" "Failed to mount program drive"
        sudo cryptsetup luksClose sovereign_program
        return 1
    fi

    sudo chown "$(whoami):$(whoami)" "$PROGRAM_MOUNT"
    log "INFO" "Program drive mounted read-only at $PROGRAM_MOUNT"
    echo -e "${GREEN}✓ Program drive mounted (read-only)${NC}"
}

# ---- Verify Program Integrity ----
verify_program_integrity() {
    log "INFO" "Verifying program drive integrity..."

    if [[ ! -f "$PROGRAM_MOUNT/MANIFEST.sha256" ]]; then
        log "WARN" "No MANIFEST.sha256 — skipping integrity check"
        return 0
    fi

    cd "$PROGRAM_MOUNT"
    if sha256sum -c MANIFEST.sha256 --quiet 2>/dev/null; then
        log "INFO" "Program drive integrity verified — all checksums match"
        echo -e "${GREEN}✓ Integrity check passed${NC}"
    else
        log "ERROR" "INTEGRITY CHECK FAILED — program drive may be tampered"
        echo -e "${RED}✗ INTEGRITY CHECK FAILED${NC}"
        cd - >/dev/null
        return 1
    fi
    cd - >/dev/null
}

# ---- Load Docker Images ----
load_docker_images() {
    log "INFO" "Loading Docker images from program drive..."

    local images_dir="$PROGRAM_MOUNT/images"
    if [[ ! -d "$images_dir" ]]; then
        log "ERROR" "No images/ directory on program drive"
        return 1
    fi

    local count=0
    for tarball in "$images_dir"/*.tar; do
        if [[ -f "$tarball" ]]; then
            echo -e "${CYAN}Loading $(basename "$tarball")...${NC}"
            docker load -i "$tarball" 2>/dev/null
            ((count++))
        fi
    done

    log "INFO" "Loaded $count Docker images"
    echo -e "${GREEN}✓ $count Docker images loaded${NC}"
}

# ---- Mount Data Drive (USB 3 — Apricorn) ----
mount_data_drive() {
    log "INFO" "Waiting for data drive (USB 3 — Apricorn)..."
    sudo mkdir -p "$DATA_MOUNT"

    echo ""
    echo -e "${YELLOW}Unlock the Apricorn drive with its hardware PIN,${NC}"
    echo -e "${YELLOW}then insert it and press Enter...${NC}"
    read -r

    # Apricorn appears as standard block device after hardware PIN
    local device
    device=$(blkid -U "$UUID" 2>/dev/null || true)
    if [[ -z "$device" ]]; then
        device=$(blkid -L "$DEVICE_LABEL" 2>/dev/null || true)
    fi

    if [[ -z "$device" ]]; then
        log "ERROR" "Data drive not found (UUID or Label=$DEVICE_LABEL)"
        echo -e "${RED}Data drive not detected. Available devices:${NC}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID
        return 1
    fi

    log "INFO" "Found data drive at $device"

    if ! sudo mount -o rw,nosuid,nodev "$device" "$DATA_MOUNT"; then
        log "ERROR" "Failed to mount data drive"
        return 1
    fi

    # Ensure directory structure
    for dir in env postgres/data postgres/ssl redis/data caddy/data caddy/config tor logs logs/postgres backups; do
        sudo mkdir -p "$DATA_MOUNT/$dir"
    done
    sudo chown -R "$(whoami):$(whoami)" "$DATA_MOUNT"

    log "INFO" "Data drive mounted read-write at $DATA_MOUNT"
    echo -e "${GREEN}✓ Data drive mounted (read-write)${NC}"
}

# ---- Launch ThreadCount ----
launch_threadcount() {
    log "INFO" "Launching ThreadCount..."

    local tc_compose="$PROGRAM_MOUNT/threadcount/docker-compose.yml"
    local sv_compose="$CONFIG_DIR/compose/docker-compose.sovereign.yml"

    if [[ ! -f "$tc_compose" ]]; then
        log "ERROR" "ThreadCount docker-compose.yml not found at $tc_compose"
        return 1
    fi
    if [[ ! -f "$sv_compose" ]]; then
        log "ERROR" "Sovereign compose override not found at $sv_compose"
        return 1
    fi

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ALL DRIVES MOUNTED                      ║${NC}"
    echo -e "${GREEN}║          Launching ThreadCount via Tor...            ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"

    # Start all services
    docker compose \
        -f "$tc_compose" \
        -f "$sv_compose" \
        --project-name sovereign \
        --project-directory "$PROGRAM_MOUNT/threadcount" \
        up -d

    # Wait for health checks
    echo -e "${CYAN}Waiting for services to become healthy...${NC}"
    local retries=30
    while [[ $retries -gt 0 ]]; do
        local healthy
        healthy=$(docker compose --project-name sovereign ps --format json 2>/dev/null | grep -c '"healthy"' || true)
        local total
        total=$(docker compose --project-name sovereign ps --format json 2>/dev/null | wc -l || true)

        if [[ "$healthy" -ge 3 ]]; then
            break
        fi
        echo -n "."
        sleep 2
        ((retries--))
    done
    echo ""

    # Show container status
    docker compose --project-name sovereign ps

    log "INFO" "ThreadCount is running"

    # Open dashboard in Firefox
    if command -v firefox-esr &>/dev/null; then
        firefox-esr http://localhost/dashboard &>/dev/null &
        log "INFO" "Opened Firefox to localhost/dashboard"
    fi
}

# ---- Clean Shutdown ----
clean_shutdown() {
    echo ""
    log "INFO" "Initiating clean shutdown..."
    echo -e "${YELLOW}Shutting down sovereign session...${NC}"

    # Stop Docker containers
    docker compose --project-name sovereign down --timeout 15 2>/dev/null || true

    # Sync writes
    sync

    # Copy boot log to data drive
    if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        cp "$LOG_FILE" "$LOG_DIR/boot-$(date '+%Y%m%d-%H%M%S').log" 2>/dev/null || true
        sync
    fi

    # Unmount data drive
    if mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        sudo umount "$DATA_MOUNT"
        log "INFO" "Data drive unmounted"
    fi

    # Unmount and close program drive
    if mountpoint -q "$PROGRAM_MOUNT" 2>/dev/null; then
        sudo umount "$PROGRAM_MOUNT"
        log "INFO" "Program drive unmounted"
    fi
    if [[ -e /dev/mapper/sovereign_program ]]; then
        sudo cryptsetup luksClose sovereign_program
        log "INFO" "LUKS closed"
    fi

    # Shred temporary boot log
    shred -u "$LOG_FILE" 2>/dev/null || rm -f "$LOG_FILE"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       ALL DRIVES SAFELY UNMOUNTED                    ║${NC}"
    echo -e "${GREEN}║       You may remove USB drives.                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
}

# ---- Trap for clean shutdown ----
trap clean_shutdown EXIT SIGINT SIGTERM

# ============================================================
# MAIN EXECUTION
# ============================================================

banner
source_config
verify_environment
deploy_security

if ! mount_program_drive; then
    echo -e "${RED}Failed to mount program drive. Aborting.${NC}"
    exit 1
fi

verify_program_integrity || {
    echo -e "${RED}Program integrity check failed. Aborting.${NC}"
    exit 1
}

load_docker_images

if ! mount_data_drive; then
    echo -e "${RED}Failed to mount data drive. Aborting.${NC}"
    exit 1
fi

# Run health check
"$SCRIPT_DIR/sovereign-health-check.sh" || log "WARN" "Health check had warnings"

launch_threadcount

# ---- Wait for operator ----
echo ""
echo -e "${CYAN}Sovereign session is active.${NC}"
echo -e "${CYAN}Press Enter to shut down, or Ctrl+C for emergency stop.${NC}"
read -r

# clean_shutdown runs via EXIT trap
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/sovereign-boot.sh
git add scripts/sovereign-boot.sh
git commit -m "feat: add main sovereign boot orchestration script"
```

---

## Task 9: USB 3 Provisioning Script (Apricorn Data Drive)

**Files:**
- Create: `scripts/provision-usb3.sh`

**Step 1: Write the provisioning script**

This is run once to set up the Apricorn drive with the correct directory structure and initial secrets.

```bash
#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — USB 3 (Apricorn Data Drive) Provisioning
# Run this ONCE on the Apricorn after setting hardware PIN.
# Prerequisite: Apricorn unlocked with PIN and inserted.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     USB 3 (Apricorn) Data Drive Provisioning         ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Identify device
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL
echo ""
read -rp "Enter the Apricorn device (e.g., /dev/sdc): " DEVICE

if [[ ! -b "$DEVICE" ]]; then
    echo -e "${RED}Device $DEVICE does not exist. Aborting.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}WARNING: This will ERASE ALL DATA on $DEVICE${NC}"
echo -e "${YELLOW}Device: $(lsblk -ndo MODEL,SIZE "$DEVICE" 2>/dev/null)${NC}"
read -rp "Type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# Format
echo -e "${CYAN}Formatting as ext4...${NC}"
sudo mkfs.ext4 -L SOVEREIGN_DATA "$DEVICE"

# Mount temporarily
MOUNT_TMP="/tmp/sovereign-usb3-provision"
sudo mkdir -p "$MOUNT_TMP"
sudo mount "$DEVICE" "$MOUNT_TMP"

# Create directory scaffold
echo -e "${CYAN}Creating directory structure...${NC}"
for dir in env postgres/data postgres/ssl redis/data caddy/data caddy/config tor logs logs/postgres backups; do
    sudo mkdir -p "$MOUNT_TMP/$dir"
done

# Generate secrets
echo ""
echo -e "${CYAN}Generating secrets...${NC}"

# Check if threadcount .env.example is available
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_EXAMPLE=""
if [[ -f "$SCRIPT_DIR/../.env.example" ]]; then
    ENV_EXAMPLE="$SCRIPT_DIR/../.env.example"
elif [[ -f "/tmp/threadcount/.env.example" ]]; then
    ENV_EXAMPLE="/tmp/threadcount/.env.example"
fi

# Generate cryptographic material
POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
FERNET_KEY=$(python3 -c "from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())" 2>/dev/null || openssl rand -base64 32)
BOT_API_KEY=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
BOT_HMAC_SECRET=$(openssl rand -base64 32 | tr -d '=/+' | head -c 32)
OPERATOR_PASSWORD=$(openssl rand -base64 24 | tr -d '=/+' | head -c 24)

# Generate JWT RSA key pair
JWT_PRIVATE_KEY=$(openssl genrsa 2048 2>/dev/null)
JWT_PUBLIC_KEY=$(echo "$JWT_PRIVATE_KEY" | openssl rsa -pubout 2>/dev/null)

# Prompt for Telegram bot token
echo ""
read -rp "Enter your Telegram Bot Token (from @BotFather): " TELEGRAM_BOT_TOKEN
read -rp "Enter Telegram Admin IDs (comma-separated numeric IDs): " TELEGRAM_ADMIN_IDS

# Write .env
cat > "$MOUNT_TMP/env/.env" << ENVEOF
# ============================================================
# Sovereign Commerce Platform — Environment Configuration
# Generated: $(date '+%Y-%m-%d %H:%M:%S')
# ============================================================

# --- PostgreSQL ---
POSTGRES_USER=sovereign
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=sovereign_commerce
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
DATABASE_URL=postgresql+asyncpg://sovereign:${POSTGRES_PASSWORD}@postgres:5432/sovereign_commerce

# --- Redis ---
REDIS_URL=unix:///var/run/redis/redis.sock

# --- Telegram Bot ---
TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN
TELEGRAM_ADMIN_IDS=$TELEGRAM_ADMIN_IDS

# --- API Server ---
API_HOST=0.0.0.0
API_PORT=8000
API_BASE_URL=http://api:8000

# --- JWT Authentication ---
JWT_PRIVATE_KEY=$JWT_PRIVATE_KEY
JWT_PUBLIC_KEY=$JWT_PUBLIC_KEY
JWT_ALGORITHM=RS256
JWT_ACCESS_TOKEN_EXPIRE_MINUTES=60
JWT_REFRESH_TOKEN_EXPIRE_HOURS=24

# --- Encryption ---
FERNET_KEY=$FERNET_KEY

# --- Bot-to-API Authentication ---
BOT_API_KEY=$BOT_API_KEY
BOT_HMAC_SECRET=$BOT_HMAC_SECRET

# --- Initial Operator Account ---
OPERATOR_USERNAME=admin
OPERATOR_PASSWORD=$OPERATOR_PASSWORD

# --- Security ---
BOT_RATE_LIMIT_PER_MINUTE=30
BOT_SESSION_TIMEOUT_MINUTES=15
LOGIN_MAX_ATTEMPTS=5
LOGIN_LOCKOUT_MINUTES=30

# --- Backup ---
BACKUP_DIR=/backups
BACKUP_RETENTION_DAYS=30

# --- Logging ---
LOG_LEVEL=INFO
ENVEOF

sudo chmod 600 "$MOUNT_TMP/env/.env"

# Generate SSL certificates for PostgreSQL
echo -e "${CYAN}Generating PostgreSQL SSL certificates...${NC}"
openssl req -new -x509 -days 3650 -nodes \
    -out "$MOUNT_TMP/postgres/ssl/ca.crt" \
    -keyout "$MOUNT_TMP/postgres/ssl/ca.key" \
    -subj "/CN=SovereignCA" 2>/dev/null

openssl req -new -nodes \
    -out "$MOUNT_TMP/postgres/ssl/server.csr" \
    -keyout "$MOUNT_TMP/postgres/ssl/server.key" \
    -subj "/CN=postgres" 2>/dev/null

openssl x509 -req -days 3650 \
    -in "$MOUNT_TMP/postgres/ssl/server.csr" \
    -CA "$MOUNT_TMP/postgres/ssl/ca.crt" \
    -CAkey "$MOUNT_TMP/postgres/ssl/ca.key" \
    -CAcreateserial \
    -out "$MOUNT_TMP/postgres/ssl/server.crt" 2>/dev/null

rm -f "$MOUNT_TMP/postgres/ssl/server.csr" "$MOUNT_TMP/postgres/ssl/ca.key" "$MOUNT_TMP/postgres/ssl/ca.srl"
sudo chmod 600 "$MOUNT_TMP/postgres/ssl/server.key"

# Set ownership
sudo chown -R 1000:1000 "$MOUNT_TMP/"

# Print summary
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          USB 3 PROVISIONING COMPLETE                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Directory structure:"
find "$MOUNT_TMP" -maxdepth 3 -not -path '*/\.*' | head -30
echo ""
echo -e "${YELLOW}IMPORTANT: Record these credentials securely:${NC}"
echo "  Operator username: admin"
echo "  Operator password: $OPERATOR_PASSWORD"
echo "  Postgres password: $POSTGRES_PASSWORD"
echo ""
echo "Drive UUID (add to drive-uuids.conf):"
blkid "$DEVICE" | grep -oP 'UUID="\K[^"]+'
echo ""

# Record UUID
echo ""
echo -e "${CYAN}Recording drive UUID...${NC}"
DATA_UUID=$(blkid -s UUID -o value "$DEVICE")
echo "Data drive UUID: $DATA_UUID"

# Unmount
sync
sudo umount "$MOUNT_TMP"
rmdir "$MOUNT_TMP"

echo -e "${GREEN}Done. Drive unmounted safely.${NC}"
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/provision-usb3.sh
git add scripts/provision-usb3.sh
git commit -m "feat: add Apricorn data drive provisioning script with secret generation"
```

---

## Task 10: USB 2 Provisioning Script (Program Drive)

**Files:**
- Create: `scripts/provision-usb2.sh`

**Step 1: Write the provisioning script**

```bash
#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — USB 2 (Program Drive) Provisioning
# Formats, encrypts, clones ThreadCount, and exports Docker images.
# Prerequisite: Docker installed on the provisioning machine.
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     USB 2 (Program Drive) Provisioning               ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Identify device
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL
echo ""
read -rp "Enter the USB 2 device (e.g., /dev/sdb): " DEVICE

if [[ ! -b "$DEVICE" ]]; then
    echo -e "${RED}Device $DEVICE does not exist. Aborting.${NC}"
    exit 1
fi

echo ""
echo -e "${YELLOW}WARNING: This will ERASE ALL DATA on $DEVICE${NC}"
echo -e "${YELLOW}Device: $(lsblk -ndo MODEL,SIZE "$DEVICE" 2>/dev/null)${NC}"
read -rp "Type YES to continue: " confirm
if [[ "$confirm" != "YES" ]]; then
    echo "Aborted."
    exit 0
fi

# Wipe with random data
echo -e "${CYAN}Wiping drive with random data (this may take a while)...${NC}"
sudo dd if=/dev/urandom of="$DEVICE" bs=4M status=progress 2>/dev/null || true

# LUKS format
echo ""
echo -e "${CYAN}Creating LUKS2 encrypted container...${NC}"
echo -e "${YELLOW}You will be prompted to set a passphrase for this drive.${NC}"
sudo cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    --label SOVEREIGN_PROGRAM \
    "$DEVICE"

# Open and format
echo -e "${CYAN}Opening LUKS container...${NC}"
sudo cryptsetup luksOpen "$DEVICE" sovereign_program

echo -e "${CYAN}Formatting as ext4...${NC}"
sudo mkfs.ext4 -L SOVEREIGN_PROGRAM /dev/mapper/sovereign_program

# Mount
MOUNT_TMP="/tmp/sovereign-usb2-provision"
sudo mkdir -p "$MOUNT_TMP"
sudo mount /dev/mapper/sovereign_program "$MOUNT_TMP"
sudo chown "$(whoami):$(whoami)" "$MOUNT_TMP"

# Clone ThreadCount
echo -e "${CYAN}Cloning ThreadCount repository...${NC}"
git clone https://github.com/steeldragon666/threadcount "$MOUNT_TMP/threadcount"

# Build Docker images
echo -e "${CYAN}Building Docker images (this will take several minutes)...${NC}"
cd "$MOUNT_TMP/threadcount"
docker compose build

# Export images
echo -e "${CYAN}Exporting Docker images as tarballs...${NC}"
mkdir -p "$MOUNT_TMP/images"

docker save sovereign-api:latest       -o "$MOUNT_TMP/images/sovereign-api.tar" 2>/dev/null || \
docker save threadcount-api:latest     -o "$MOUNT_TMP/images/sovereign-api.tar"

docker save sovereign-bot:latest       -o "$MOUNT_TMP/images/sovereign-bot.tar" 2>/dev/null || \
docker save threadcount-bot:latest     -o "$MOUNT_TMP/images/sovereign-bot.tar"

docker save sovereign-dashboard:latest -o "$MOUNT_TMP/images/sovereign-dashboard.tar" 2>/dev/null || \
docker save threadcount-dashboard:latest -o "$MOUNT_TMP/images/sovereign-dashboard.tar"

docker save caddy:2-alpine             -o "$MOUNT_TMP/images/caddy.tar"
docker save postgres:16-alpine         -o "$MOUNT_TMP/images/postgres.tar"
docker save redis:7-alpine             -o "$MOUNT_TMP/images/redis.tar"
docker save osminogin/tor-simple:latest -o "$MOUNT_TMP/images/tor-simple.tar"

cd "$MOUNT_TMP"

# Generate integrity manifest
echo -e "${CYAN}Generating integrity manifest...${NC}"
find . -type f ! -name 'MANIFEST.sha256' -exec sha256sum {} \; > MANIFEST.sha256

# Print summary
echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          USB 2 PROVISIONING COMPLETE                 ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Contents:"
ls -lh "$MOUNT_TMP/images/"
echo ""
echo "Drive UUID (add to drive-uuids.conf):"
PROGRAM_UUID=$(blkid -s UUID -o value /dev/mapper/sovereign_program)
echo "  $PROGRAM_UUID"
echo ""

# Unmount and close
sync
cd /
sudo umount "$MOUNT_TMP"
sudo cryptsetup luksClose sovereign_program
rmdir "$MOUNT_TMP"

echo -e "${GREEN}Done. LUKS closed. Drive safe to remove.${NC}"
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/provision-usb2.sh
git add scripts/provision-usb2.sh
git commit -m "feat: add program drive provisioning with LUKS, image export, and manifest"
```

---

## Task 11: Docker Image Build Helper Script

**Files:**
- Create: `scripts/build-images.sh`

**Step 1: Write the build script**

For use when updating ThreadCount — rebuilds images and re-exports to a mounted USB 2.

```bash
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
```

**Step 2: Make executable and commit**

```bash
chmod +x scripts/build-images.sh
git add scripts/build-images.sh
git commit -m "feat: add Docker image build and export helper for USB 2 updates"
```

---

## Task 12: USB 1 Installation Script (Debian Boot Drive)

This is the most complex script — it uses debootstrap to install a minimal Debian system onto a USB drive. **This script must be run from an existing Linux machine** (live USB, VM, or another Debian install).

**Files:**
- Create: `install/install-to-usb1.sh`

**Step 1: Write the installation script**

```bash
#!/bin/bash
set -euo pipefail

# ============================================================
# Sovereign Security — USB 1 (Boot Drive) Installation
# Creates a bootable, LUKS-encrypted Debian 12 USB with all
# sovereign boot infrastructure pre-installed.
#
# MUST be run as root from an existing Debian/Ubuntu system.
# Requires: debootstrap, cryptsetup, parted, grub, arch-chroot
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}This script must be run as root.${NC}"
    exit 1
fi

echo -e "${CYAN}"
echo "╔═══════════════════════════════════════════════════════╗"
echo "║     USB 1 (Boot Drive) — Debian 12 Installation      ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Check dependencies
for cmd in debootstrap cryptsetup parted mkfs.ext4 grub-install; do
    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${RED}Missing dependency: $cmd${NC}"
        echo "Install with: apt install debootstrap cryptsetup parted grub-pc grub-efi-amd64-bin"
        exit 1
    fi
done

# Identify device
echo "Available block devices:"
lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,MODEL
echo ""
read -rp "Enter the USB 1 device (e.g., /dev/sdb): " DEVICE

if [[ ! -b "$DEVICE" ]]; then
    echo -e "${RED}Device $DEVICE does not exist.${NC}"
    exit 1
fi

echo ""
echo -e "${RED}WARNING: This will COMPLETELY ERASE $DEVICE${NC}"
echo -e "${RED}Device: $(lsblk -ndo MODEL,SIZE "$DEVICE" 2>/dev/null)${NC}"
read -rp "Type DESTROY to continue: " confirm
if [[ "$confirm" != "DESTROY" ]]; then
    echo "Aborted."
    exit 0
fi

# ---- Partition ----
echo -e "${CYAN}Partitioning $DEVICE...${NC}"

# GPT partition table for UEFI
parted -s "$DEVICE" mklabel gpt

# EFI System Partition (512MB)
parted -s "$DEVICE" mkpart primary fat32 1MiB 513MiB
parted -s "$DEVICE" set 1 esp on

# Boot partition (512MB, unencrypted, for GRUB + kernel)
parted -s "$DEVICE" mkpart primary ext4 513MiB 1025MiB

# Root partition (remainder, will be LUKS encrypted)
parted -s "$DEVICE" mkpart primary ext4 1025MiB 100%

# Determine partition names (handle both sdX1 and sdXp1 formats)
if [[ -b "${DEVICE}1" ]]; then
    EFI_PART="${DEVICE}1"
    BOOT_PART="${DEVICE}2"
    ROOT_PART="${DEVICE}3"
elif [[ -b "${DEVICE}p1" ]]; then
    EFI_PART="${DEVICE}p1"
    BOOT_PART="${DEVICE}p2"
    ROOT_PART="${DEVICE}p3"
else
    sleep 2
    partprobe "$DEVICE"
    EFI_PART="${DEVICE}1"
    BOOT_PART="${DEVICE}2"
    ROOT_PART="${DEVICE}3"
fi

# ---- LUKS Encrypt Root ----
echo ""
echo -e "${CYAN}Encrypting root partition with LUKS2...${NC}"
echo -e "${YELLOW}You will be prompted to set the boot passphrase.${NC}"
cryptsetup luksFormat \
    --type luks2 \
    --cipher aes-xts-plain64 \
    --key-size 512 \
    --hash sha512 \
    --pbkdf argon2id \
    "$ROOT_PART"

cryptsetup luksOpen "$ROOT_PART" sovereign_root

# ---- Format Partitions ----
echo -e "${CYAN}Formatting partitions...${NC}"
mkfs.fat -F32 "$EFI_PART"
mkfs.ext4 -L SOVEREIGN_BOOT "$BOOT_PART"
mkfs.ext4 -L SOVEREIGN_ROOT /dev/mapper/sovereign_root

# ---- Mount ----
CHROOT="/tmp/sovereign-usb1"
mkdir -p "$CHROOT"
mount /dev/mapper/sovereign_root "$CHROOT"
mkdir -p "$CHROOT/boot"
mount "$BOOT_PART" "$CHROOT/boot"
mkdir -p "$CHROOT/boot/efi"
mount "$EFI_PART" "$CHROOT/boot/efi"

# ---- Debootstrap ----
echo -e "${CYAN}Installing Debian 12 base system (this will take several minutes)...${NC}"
debootstrap --arch=amd64 bookworm "$CHROOT" http://deb.debian.org/debian

# ---- Configure ----
echo -e "${CYAN}Configuring system...${NC}"

# fstab
ROOT_UUID=$(blkid -s UUID -o value /dev/mapper/sovereign_root)
BOOT_UUID=$(blkid -s UUID -o value "$BOOT_PART")
EFI_UUID=$(blkid -s UUID -o value "$EFI_PART")
LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

cat > "$CHROOT/etc/fstab" << FSTAB
# Sovereign Boot — /etc/fstab
UUID=$ROOT_UUID  /          ext4  errors=remount-ro  0 1
UUID=$BOOT_UUID  /boot      ext4  defaults           0 2
UUID=$EFI_UUID   /boot/efi  vfat  umask=0077         0 1
tmpfs            /tmp       tmpfs defaults,noexec,nosuid,size=2G  0 0
FSTAB

# crypttab
cat > "$CHROOT/etc/crypttab" << CRYPTTAB
sovereign_root UUID=$LUKS_UUID none luks
CRYPTTAB

# hostname
echo "sovereign" > "$CHROOT/etc/hostname"

# Marker file (sovereign-boot.sh checks for this)
echo "sovereign-boot-v1" > "$CHROOT/etc/sovereign-boot-marker"

# Network (basic DHCP via NetworkManager)
cat > "$CHROOT/etc/network/interfaces" << NET
auto lo
iface lo inet loopback
NET

# Sources list
cat > "$CHROOT/etc/apt/sources.list" << SOURCES
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
SOURCES

# ---- Chroot and install packages ----
mount --bind /dev "$CHROOT/dev"
mount --bind /dev/pts "$CHROOT/dev/pts"
mount -t proc proc "$CHROOT/proc"
mount -t sysfs sys "$CHROOT/sys"

chroot "$CHROOT" /bin/bash << 'CHROOTSCRIPT'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

# Update and install packages
apt-get update
apt-get install -y \
    linux-image-amd64 \
    grub-efi-amd64 \
    cryptsetup \
    cryptsetup-initramfs \
    lvm2 \
    docker.io \
    docker-compose-plugin \
    nftables \
    xfce4 \
    xfce4-terminal \
    xfce4-screensaver \
    lightdm \
    firefox-esr \
    network-manager \
    sudo \
    udev \
    coreutils \
    shred \
    openssh-client \
    gnupg \
    curl \
    git \
    python3 \
    --no-install-recommends

# Remove unnecessary services
apt-get remove -y --purge \
    avahi-daemon \
    cups \
    bluetooth \
    bluez \
    2>/dev/null || true
apt-get autoremove -y

# Create sovereign user
useradd -m -s /bin/bash -G sudo,docker sovereign
echo "sovereign:sovereign" | chpasswd

# Configure sudo without password for specific commands
cat > /etc/sudoers.d/sovereign << 'SUDO'
sovereign ALL=(ALL) NOPASSWD: /sbin/cryptsetup, /bin/mount, /bin/umount, /sbin/nft, /bin/chmod, /sbin/swapoff, /bin/cp, /bin/chown, /bin/mkdir, /sbin/udevadm, /bin/systemctl start docker, /bin/systemctl stop docker
SUDO

# LightDM auto-login
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/50-sovereign.conf << 'LDM'
[Seat:*]
autologin-user=sovereign
autologin-user-timeout=0
user-session=xfce
LDM

# Disable IPv6 (Tor uses IPv4)
cat >> /etc/sysctl.d/99-sovereign.conf << 'SYSCTL'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL

# Disable Bluetooth
systemctl disable bluetooth.service 2>/dev/null || true
systemctl mask bluetooth.service 2>/dev/null || true

# Enable Docker and NetworkManager
systemctl enable docker
systemctl enable NetworkManager

# Enable nftables
systemctl enable nftables

# Update initramfs (includes cryptsetup for LUKS boot)
update-initramfs -u -k all

# Install GRUB
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=sovereign --removable
update-grub

CHROOTSCRIPT

# ---- Install sovereign-boot files ----
echo -e "${CYAN}Installing sovereign boot scripts...${NC}"

SOVEREIGN_HOME="$CHROOT/home/sovereign"

# Scripts
mkdir -p "$SOVEREIGN_HOME/.local/bin"
cp "$PROJECT_DIR/scripts/sovereign-boot.sh"        "$SOVEREIGN_HOME/.local/bin/"
cp "$PROJECT_DIR/scripts/sovereign-health-check.sh" "$SOVEREIGN_HOME/.local/bin/"
cp "$PROJECT_DIR/scripts/unmount-all.sh"            "$SOVEREIGN_HOME/.local/bin/"
chmod +x "$SOVEREIGN_HOME/.local/bin/"*.sh

# Config
mkdir -p "$SOVEREIGN_HOME/.config/sovereign/compose"
cp "$PROJECT_DIR/config/drive-uuids.conf"        "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/mount-points.conf"        "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/sovereign-firewall.nft"   "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/config/99-sovereign-usb.rules"   "$SOVEREIGN_HOME/.config/sovereign/"
cp "$PROJECT_DIR/compose/docker-compose.sovereign.yml" "$SOVEREIGN_HOME/.config/sovereign/compose/"

# XDG autostart
mkdir -p "$SOVEREIGN_HOME/.config/autostart"
cp "$PROJECT_DIR/desktop/sovereign-boot.desktop"  "$SOVEREIGN_HOME/.config/autostart/"

# Set ownership
chroot "$CHROOT" chown -R sovereign:sovereign /home/sovereign

# ---- Cleanup ----
echo -e "${CYAN}Cleaning up...${NC}"
umount "$CHROOT/dev/pts"
umount "$CHROOT/dev"
umount "$CHROOT/proc"
umount "$CHROOT/sys"
umount "$CHROOT/boot/efi"
umount "$CHROOT/boot"
umount "$CHROOT"
cryptsetup luksClose sovereign_root
rmdir "$CHROOT"

echo ""
echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║          USB 1 INSTALLATION COMPLETE                 ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║  Boot from this USB via F12 boot menu.               ║${NC}"
echo -e "${GREEN}║  LUKS passphrase required at GRUB.                   ║${NC}"
echo -e "${GREEN}║  Auto-login → Xfce → sovereign-boot.sh              ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  1. Boot from USB 1 to test it works"
echo "  2. Run provision-usb2.sh to set up the program drive"
echo "  3. Run provision-usb3.sh to set up the Apricorn data drive"
echo "  4. Update config/drive-uuids.conf with discovered UUIDs"
echo "  5. Update config/99-sovereign-usb.rules with drive serial numbers"
```

**Step 2: Make executable and commit**

```bash
chmod +x install/install-to-usb1.sh
git add install/install-to-usb1.sh
git commit -m "feat: add USB 1 Debian installation script with debootstrap and LUKS"
```

---

## Task 13: Final Integration — Verify All Files Exist and Commit

**Step 1: Verify project structure matches design**

```bash
find sovereign-boot/ -type f | sort
```

Expected output:
```
sovereign-boot/compose/docker-compose.sovereign.yml
sovereign-boot/config/99-sovereign-usb.rules
sovereign-boot/config/drive-uuids.conf
sovereign-boot/config/mount-points.conf
sovereign-boot/config/sovereign-firewall.nft
sovereign-boot/desktop/sovereign-boot.desktop
sovereign-boot/docs/plans/2026-03-29-sovereign-boot-design.md
sovereign-boot/docs/plans/2026-03-29-sovereign-boot-implementation.md
sovereign-boot/install/install-to-usb1.sh
sovereign-boot/scripts/build-images.sh
sovereign-boot/scripts/provision-usb2.sh
sovereign-boot/scripts/provision-usb3.sh
sovereign-boot/scripts/sovereign-boot.sh
sovereign-boot/scripts/sovereign-health-check.sh
sovereign-boot/scripts/unmount-all.sh
```

**Step 2: All scripts are executable**

```bash
ls -la sovereign-boot/scripts/*.sh sovereign-boot/install/*.sh
```

Expected: All show `-rwxr-xr-x` permissions.

**Step 3: Final commit (implementation plan)**

```bash
git add docs/plans/2026-03-29-sovereign-boot-implementation.md
git commit -m "docs: add implementation plan for sovereign boot system"
```

---

## Execution Order Summary

| Task | What | Dependencies |
|------|------|-------------|
| 1 | Config files (drive-uuids, mount-points) | None |
| 2 | Docker Compose sovereign override | None |
| 3 | nftables firewall rules | None |
| 4 | udev USB whitelist rules | None |
| 5 | XDG autostart desktop entry | None |
| 6 | Health check script | Task 1 (sources config) |
| 7 | Emergency unmount script | Task 1 (sources config) |
| 8 | Main sovereign-boot.sh | Tasks 1-7 (sources everything) |
| 9 | USB 3 provisioning | None (standalone) |
| 10 | USB 2 provisioning | None (standalone) |
| 11 | Image build helper | None (standalone) |
| 12 | USB 1 Debian installer | Tasks 1-8 (copies them into USB) |
| 13 | Final verification | All tasks |

Tasks 1-5 and 9-11 are fully independent and can be parallelized.
