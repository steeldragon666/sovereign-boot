#!/bin/bash
set -uo pipefail

# ============================================================
# Sovereign Security Boot — Main Orchestration Script
# Run with: sudo bash ~/.local/bin/sovereign-boot.sh
# ============================================================

# Must be root
if [[ $EUID -ne 0 ]]; then
    echo "Run with sudo: sudo bash $0"
    exit 1
fi

# Resolve the real user (the one who called sudo)
REAL_USER="${SUDO_USER:-$(logname 2>/dev/null || whoami)}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$REAL_HOME/.config/sovereign"
LOG_FILE="/tmp/sovereign-boot.log"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# Config variables — set defaults so set -u never crashes
PROGRAM_MOUNT=""
DATA_MOUNT=""
ENV_DIR=""
LOG_DIR=""
PROGRAM_DRIVE_UUID=""
PROGRAM_DRIVE_LUKS_LABEL=""
DATA_DRIVE_UUID=""
DATA_DRIVE_DEVICE_LABEL=""

log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [$1] $2" | tee -a "$LOG_FILE"
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

source_config() {
    for conf in drive-uuids.conf mount-points.conf; do
        local path="$CONFIG_DIR/$conf"
        if [[ ! -f "$path" ]]; then
            log "FATAL" "Config not found: $path"
            exit 1
        fi
        eval "$(sed 's/\r//' "$path" | grep -v '^\[' | grep -v '^#' | grep -v '^$' | sed 's/ *= */=/')"
    done
    log "INFO" "Config loaded — user=$REAL_USER home=$REAL_HOME"
    log "INFO" "PROGRAM_MOUNT=$PROGRAM_MOUNT DATA_MOUNT=$DATA_MOUNT"
    log "INFO" "PROGRAM_UUID=$PROGRAM_DRIVE_UUID DATA_UUID=$DATA_DRIVE_UUID"
}

cleanup_stale() {
    log "INFO" "Cleaning stale state from previous runs..."

    # Unmount program drive if still mounted
    if [[ -n "$PROGRAM_MOUNT" ]] && mountpoint -q "$PROGRAM_MOUNT" 2>/dev/null; then
        fuser -km "$PROGRAM_MOUNT" 2>/dev/null || true
        umount -l "$PROGRAM_MOUNT" 2>/dev/null || true
        log "INFO" "Unmounted stale $PROGRAM_MOUNT"
    fi

    # Close LUKS if still open
    if [[ -e /dev/mapper/sovereign_program ]]; then
        cryptsetup luksClose sovereign_program 2>/dev/null || true
        log "INFO" "Closed stale LUKS"
    fi

    # Unmount data drive if still mounted
    if [[ -n "$DATA_MOUNT" ]] && mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        fuser -km "$DATA_MOUNT" 2>/dev/null || true
        umount -l "$DATA_MOUNT" 2>/dev/null || true
        log "INFO" "Unmounted stale $DATA_MOUNT"
    fi
}

verify_environment() {
    log "INFO" "Verifying environment..."

    local avail_mb
    avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
    if [[ "$avail_mb" -lt 4096 ]]; then
        log "WARN" "Low RAM: ${avail_mb}MB (need ~3GB)"
    fi

    if ! systemctl is-active --quiet docker; then
        log "INFO" "Starting Docker..."
        systemctl start docker
        sleep 2
    fi

    log "INFO" "Environment OK — RAM: ${avail_mb}MB, Docker running"
}

deploy_security() {
    log "INFO" "Deploying security controls..."

    # Firewall
    local fw="$CONFIG_DIR/sovereign-firewall.nft"
    if [[ -f "$fw" ]]; then
        nft -f "$fw" 2>/dev/null && log "INFO" "Firewall deployed" || log "WARN" "Firewall failed (nftables may not be installed)"
    fi

    # Udev
    local udev="$CONFIG_DIR/99-sovereign-usb.rules"
    if [[ -f "$udev" ]]; then
        cp "$udev" /etc/udev/rules.d/ 2>/dev/null || true
        udevadm control --reload-rules 2>/dev/null || true
        udevadm trigger 2>/dev/null || true
    fi

    # Block internal NVMe only (not /dev/sd* which are USB drives)
    for dev in /dev/nvme0n1 /dev/nvme1n1; do
        [[ -b "$dev" ]] && chmod 000 "$dev" 2>/dev/null || true
    done

    swapoff -a 2>/dev/null || true
    log "INFO" "Security controls deployed"
}

mount_program_drive() {
    log "INFO" "Waiting for program drive (USB 2)..."
    mkdir -p "$PROGRAM_MOUNT"

    echo -e "${YELLOW}Insert the PROGRAM drive (USB 2) and press Enter...${NC}"
    read -r

    # Unmount if Ubuntu automounted it
    local automount
    automount=$(lsblk -no MOUNTPOINT $(blkid -U "$PROGRAM_DRIVE_UUID" 2>/dev/null) 2>/dev/null | head -1)
    if [[ -n "$automount" ]]; then
        umount "$automount" 2>/dev/null || true
    fi

    local device=""
    device=$(blkid -U "$PROGRAM_DRIVE_UUID" 2>/dev/null || true)
    if [[ -z "$device" ]]; then
        device=$(blkid -L "$PROGRAM_DRIVE_LUKS_LABEL" 2>/dev/null || true)
    fi

    if [[ -z "$device" ]]; then
        log "ERROR" "Program drive not found (UUID=$PROGRAM_DRIVE_UUID)"
        echo -e "${RED}Program drive not detected. Available devices:${NC}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID
        return 1
    fi

    log "INFO" "Found program drive at $device"
    echo -e "${CYAN}Decrypting program drive...${NC}"

    if ! cryptsetup luksOpen "$device" sovereign_program; then
        log "ERROR" "Failed to decrypt program drive"
        return 1
    fi

    if ! mount -o ro,noexec,nosuid,nodev /dev/mapper/sovereign_program "$PROGRAM_MOUNT"; then
        log "ERROR" "Failed to mount program drive"
        cryptsetup luksClose sovereign_program
        return 1
    fi

    log "INFO" "Program drive mounted at $PROGRAM_MOUNT"
    echo -e "${GREEN}✓ Program drive mounted (read-only)${NC}"
}

verify_program_integrity() {
    log "INFO" "Verifying program integrity..."

    if [[ ! -f "$PROGRAM_MOUNT/MANIFEST.sha256" ]]; then
        log "WARN" "No MANIFEST.sha256 — skipping"
        return 0
    fi

    cd "$PROGRAM_MOUNT"
    if sha256sum -c MANIFEST.sha256 --quiet 2>/dev/null; then
        log "INFO" "Integrity verified"
        echo -e "${GREEN}✓ Integrity check passed${NC}"
    else
        log "ERROR" "INTEGRITY CHECK FAILED"
        echo -e "${RED}✗ INTEGRITY CHECK FAILED${NC}"
        cd - >/dev/null
        return 1
    fi
    cd - >/dev/null
}

load_docker_images() {
    log "INFO" "Loading Docker images..."

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
            ((count++)) || true
        fi
    done

    log "INFO" "Loaded $count Docker images"
    echo -e "${GREEN}✓ $count Docker images loaded${NC}"
}

mount_data_drive() {
    log "INFO" "Waiting for data drive (USB 3 — Apricorn)..."
    mkdir -p "$DATA_MOUNT"

    echo ""
    echo -e "${YELLOW}Unlock the Apricorn with its hardware PIN,${NC}"
    echo -e "${YELLOW}then insert it and press Enter...${NC}"
    read -r

    local device=""
    device=$(blkid -U "$DATA_DRIVE_UUID" 2>/dev/null || true)
    if [[ -z "$device" ]]; then
        device=$(blkid -L "$DATA_DRIVE_DEVICE_LABEL" 2>/dev/null || true)
    fi

    if [[ -z "$device" ]]; then
        log "ERROR" "Data drive not found (UUID=$DATA_DRIVE_UUID)"
        echo -e "${RED}Data drive not detected. Available devices:${NC}"
        lsblk -o NAME,SIZE,TYPE,FSTYPE,LABEL,UUID
        return 1
    fi

    log "INFO" "Found data drive at $device"

    # Unmount if Ubuntu automounted it
    umount "$device" 2>/dev/null || true

    if ! mount -o rw,nosuid,nodev "$device" "$DATA_MOUNT"; then
        log "ERROR" "Failed to mount data drive"
        return 1
    fi

    for dir in env postgres/data postgres/ssl redis/data caddy/data caddy/config tor logs backups; do
        mkdir -p "$DATA_MOUNT/$dir"
    done
    chown -R "$REAL_USER:$REAL_USER" "$DATA_MOUNT"

    log "INFO" "Data drive mounted at $DATA_MOUNT"
    echo -e "${GREEN}✓ Data drive mounted (read-write)${NC}"
}

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

    docker compose \
        -f "$tc_compose" \
        -f "$sv_compose" \
        --project-name sovereign \
        --project-directory "$PROGRAM_MOUNT/threadcount" \
        up -d

    echo -e "${CYAN}Waiting for services...${NC}"
    local retries=30
    while [[ $retries -gt 0 ]]; do
        local healthy
        healthy=$(docker compose --project-name sovereign ps --format json 2>/dev/null | grep -c '"healthy"' || true)
        if [[ "$healthy" -ge 3 ]]; then break; fi
        echo -n "."
        sleep 2
        ((retries--)) || true
    done
    echo ""

    docker compose --project-name sovereign ps
    log "INFO" "ThreadCount is running"

    # Open Firefox as the real user, not root
    if command -v firefox &>/dev/null; then
        su - "$REAL_USER" -c "firefox http://localhost/dashboard &" 2>/dev/null || true
    fi
    log "INFO" "Dashboard at http://localhost/dashboard"
}

clean_shutdown() {
    echo ""
    echo -e "${YELLOW}Shutting down sovereign session...${NC}"

    docker compose --project-name sovereign down --timeout 15 2>/dev/null || true
    sync

    if [[ -n "$DATA_MOUNT" ]] && mountpoint -q "$DATA_MOUNT" 2>/dev/null; then
        [[ -n "$LOG_DIR" && -d "$LOG_DIR" ]] && cp "$LOG_FILE" "$LOG_DIR/boot-$(date '+%Y%m%d-%H%M%S').log" 2>/dev/null || true
        sync
        umount "$DATA_MOUNT" 2>/dev/null || umount -l "$DATA_MOUNT" 2>/dev/null || true
    fi

    if [[ -n "$PROGRAM_MOUNT" ]] && mountpoint -q "$PROGRAM_MOUNT" 2>/dev/null; then
        umount "$PROGRAM_MOUNT" 2>/dev/null || umount -l "$PROGRAM_MOUNT" 2>/dev/null || true
    fi

    [[ -e /dev/mapper/sovereign_program ]] && cryptsetup luksClose sovereign_program 2>/dev/null || true

    shred -u "$LOG_FILE" 2>/dev/null || rm -f "$LOG_FILE"

    echo ""
    echo -e "${GREEN}╔═══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       ALL DRIVES SAFELY UNMOUNTED                    ║${NC}"
    echo -e "${GREEN}║       You may remove USB drives.                     ║${NC}"
    echo -e "${GREEN}╚═══════════════════════════════════════════════════════╝${NC}"
}

trap clean_shutdown EXIT SIGINT SIGTERM

# ============================================================
# MAIN
# ============================================================

banner
source_config
cleanup_stale
verify_environment
deploy_security

if ! mount_program_drive; then
    echo -e "${RED}Failed to mount program drive. Aborting.${NC}"
    exit 1
fi

verify_program_integrity || { echo -e "${RED}Integrity check failed. Aborting.${NC}"; exit 1; }

load_docker_images

if ! mount_data_drive; then
    echo -e "${RED}Failed to mount data drive. Aborting.${NC}"
    exit 1
fi

launch_threadcount

echo ""
echo -e "${CYAN}Sovereign session is active.${NC}"
echo -e "${CYAN}Press Enter to shut down, or Ctrl+C for emergency stop.${NC}"
read -r
