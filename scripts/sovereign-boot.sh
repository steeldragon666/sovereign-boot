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
