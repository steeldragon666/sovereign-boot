# Sovereign Security Boot System — Design Document

**Date:** 2026-03-29
**Status:** Approved
**Application:** ThreadCount (steeldragon666/threadcount) — Sovereign Commerce Platform

---

## 1. Summary

A three-USB boot system that turns a standard laptop into a secure, portable operating station for the ThreadCount commerce platform. The laptop appears as a normal Windows machine when powered on without the boot drive. When USB 1 is selected from the BIOS boot menu, it launches a hardened Debian environment that mounts two additional USB drives — one carrying the application (Docker images), one carrying all persistent data and secrets (hardware-encrypted Apricorn). All outbound internet traffic routes through Tor.

---

## 2. Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        HOST LAPTOP                              │
│  Internal SSD: Windows 11 (decoy, default boot)                 │
│  BIOS: Password-protected, USB boot via F12 only                │
│                                                                 │
│  ┌──────────────────┐  ┌─────────────────┐  ┌────────────────┐ │
│  │    USB 1 BOOT    │  │  USB 2 PROGRAM  │  │  USB 3 DATA    │ │
│  │  Debian 12       │  │  LUKS2          │  │  Apricorn      │ │
│  │  Minimal + LUKS  │  │  (argon2id)     │  │  Aegis 128GB   │ │
│  │                  │  │                 │  │  Hardware PIN   │ │
│  │  • Linux kernel  │  │  • threadcount/ │  │  • pgdata/     │ │
│  │  • Docker engine │  │    repo clone   │  │  • redis-data/ │ │
│  │  • Docker Compose│  │  • Docker images│  │  • .env        │ │
│  │  • Minimal Xfce  │  │    (exported    │  │  • SSL certs   │ │
│  │  • Firefox ESR   │  │     tarballs)   │  │  • JWT keys    │ │
│  │  • nftables fw   │  │  • docker-      │  │  • Fernet key  │ │
│  │  • Tor routing   │  │    compose.     │  │  • Tor state   │ │
│  │  • sovereign     │  │    sovereign.yml│  │  • logs/       │ │
│  │    boot scripts  │  │  • MANIFEST.sha │  │  • backups/    │ │
│  │  • udev rules    │  │                 │  │                │ │
│  └──────────────────┘  └─────────────────┘  └────────────────┘ │
└─────────────────────────────────────────────────────────────────┘
```

### Drive Roles

| Drive | Role | Encryption | Mount Mode | Contents |
|-------|------|-----------|------------|----------|
| USB 1 | Boot OS | LUKS2 full-disk (argon2id) | Read-write (OS) | Debian 12 minimal, Docker, Xfce, Firefox, boot scripts, firewall rules, udev rules |
| USB 2 | Application | LUKS2 (argon2id, separate passphrase) | Read-only | ThreadCount repo clone, pre-built Docker image tarballs, compose override, integrity manifest |
| USB 3 | Data & Secrets | Apricorn Aegis hardware AES-256 (FIPS 140-2 L3) | Read-write | PostgreSQL data, Redis data, .env (all secrets), SSL certs, JWT keys, Tor state, logs, backups |

### Why Debian 12 (not Tails)

ThreadCount is a 6-service Docker Compose application (FastAPI, PostgreSQL, Redis, Telegram Bot, React Dashboard, Caddy). Tails does not ship Docker and its amnesic design conflicts with running a persistent Docker daemon. Debian 12 minimal provides:
- Native Docker support
- Desktop environment for localhost dashboard access
- Reproducible provisioning via debootstrap
- Standard full-disk LUKS encryption

---

## 3. Network Architecture — All Traffic Through Tor

```
┌─────────────────── HOST (Debian USB 1) ───────────────────────┐
│                                                                │
│  nftables firewall:                                            │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ ALLOW: loopback (127.0.0.0/8)                            │  │
│  │ ALLOW: outbound to Tor SOCKS (Docker network)            │  │
│  │ ALLOW: Tor process → outbound 443, 9001, 9030 (OR ports) │  │
│  │ ALLOW: Tor process → outbound 53 (DNS for bootstrapping) │  │
│  │ DROP:  everything else inbound and outbound               │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
│  Docker network (sovereign-net):                               │
│                                                                │
│  bot ──┐                                                       │
│  api ──┤──→ tor-proxy (SOCKS5 :9050) ──→ Tor network          │
│        │                                                       │
│  caddy ──→ localhost:80/443 (operator browser)                 │
│  dashboard ──→ (served via caddy, localhost only)              │
│  postgres, redis ──→ internal Docker network only              │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

- Bot and API containers use `HTTPS_PROXY=socks5h://tor-proxy:9050` (socks5h = DNS through Tor, no leak)
- Tor state persisted to USB 3 (`/mnt/sovereign/data/tor/`) to maintain guard node selection across sessions
- Dashboard accessible only at localhost — never exposed to network

---

## 4. Boot Sequence

```
1. Power on → F12 → Select USB 1
2. GRUB → LUKS passphrase → Debian boots
3. Auto-login (lightdm → sovereign user → Xfce)
4. XDG autostart → sovereign-boot.sh launches in terminal

5. Deploy udev USB whitelist rules
6. Deploy nftables firewall (Tor-only outbound)
7. Block internal drives (chmod 000)
8. Verify no swap enabled

9. Prompt: "Insert PROGRAM drive and press Enter"
   → Find USB 2 by UUID
   → cryptsetup luksOpen → mount read-only
   → Verify MANIFEST.sha256 integrity
   → docker load all image tarballs

10. Prompt: "Unlock Apricorn with PIN, insert, press Enter"
    → Find USB 3 by UUID
    → Mount read-write (hardware already decrypted via PIN)
    → Verify directory structure

11. Run sovereign-health-check.sh
    → Both drives mounted correctly
    → .env exists, pgdata exists, Docker images loaded
    → No internal drives mounted, no swap

12. docker compose -f (USB2)/docker-compose.yml \
                    -f (sovereign)/docker-compose.sovereign.yml \
                    up -d

13. Wait for all containers healthy (Postgres, Redis, API, Bot, Tor)
14. Open Firefox to http://localhost/dashboard
15. Operator works

16. Press Enter (or Ctrl+C) to shut down
    → docker compose down
    → sync, copy boot log to USB 3
    → Unmount USB 3
    → Unmount + luksClose USB 2
    → "Safe to remove drives"
```

---

## 5. Docker Compose Override

`docker-compose.sovereign.yml` overlays ThreadCount's stock `docker-compose.yml` to:

1. **Redirect all volumes to USB 3** (`/mnt/sovereign/data/`)
2. **Add Tor proxy container** with SOCKS5 on port 9050
3. **Inject `HTTPS_PROXY`** env vars into bot and api containers
4. **Point `env_file`** to USB 3's `.env` for all services needing secrets
5. **Persist Tor state** to USB 3 for guard node continuity

Services unmodified: dashboard (static, no secrets, no outbound).
Postgres and Redis: internal network only, no internet access.

---

## 6. USB 3 (Apricorn) Directory Layout

```
/mnt/sovereign/data/
├── env/
│   └── .env                          # ALL secrets (Telegram token, DB pass, JWT keys, Fernet key)
├── postgres/
│   ├── data/                         # PostgreSQL data directory
│   └── ssl/
│       ├── ca.crt
│       ├── server.crt
│       └── server.key
├── redis/
│   └── data/                         # Redis AOF/RDB persistence
├── caddy/
│   ├── data/                         # Caddy TLS state
│   └── config/
├── tor/                              # Tor guard node state
├── logs/
│   ├── session-YYYYMMDD-HHMMSS.log
│   └── boot-YYYYMMDD-HHMMSS.log
└── backups/
    └── sovereign_commerce-YYYYMMDD.sql.gpg
```

---

## 7. Security Hardening

| Measure | Implementation |
|---------|---------------|
| All outbound through Tor | socks5h proxy, nftables blocks direct outbound |
| USB whitelist | udev rules by serial number, unknown devices blocked and logged |
| Internal drive lockout | chmod 000 on /dev/sda, /dev/nvme* at boot |
| No swap | Verified at boot, swapoff -a as safety |
| Screen lock | Xfce screensaver lock after 5 min idle |
| Secure delete on shutdown | shred boot log from /tmp |
| Docker socket protection | Only sovereign user group |
| Read-only program drive | USB 2 mounted ro,noexec,nosuid,nodev |
| Program integrity check | MANIFEST.sha256 verified before docker load |
| Tor guard persistence | Tor state on Apricorn, reuses guards across sessions |
| App-level encryption | ThreadCount's own Fernet + JWT + Argon2id (second layer inside hardware encryption) |
| Container isolation | Seccomp profiles, no-new-privileges, capability dropping, read-only rootfs (from ThreadCount's existing hardening) |

### Threat Model

| Threat | Mitigation |
|--------|-----------|
| Laptop seized while off | Internal SSD shows only Windows. No trace of sovereign system on host. |
| USB 1 seized | LUKS2 encrypted. Shows it's a Debian drive but contents unrecoverable without passphrase. |
| USB 2 seized | LUKS2 encrypted. Application code unrecoverable without passphrase. |
| USB 3 seized | Apricorn hardware encryption. 10 wrong PINs = self-destruct (crypto-erase). FIPS 140-2 L3. |
| Network surveillance | All traffic through Tor. ISP sees Tor usage but not destination. No DNS leaks (socks5h). |
| Rogue USB insertion | udev whitelist blocks unknown devices, audit log captures attempts. |
| Container breakout | nftables blocks direct internet. Seccomp + no-new-privileges on containers. |
| Cold boot (RAM) | No swap. Keep sessions short. Docker volumes on USB 3, not tmpfs. |

---

## 8. RAM Budget

| Component | RAM |
|-----------|-----|
| Debian 12 Minimal + Xfce | ~800MB |
| Docker engine | ~200MB |
| PostgreSQL container | 512MB |
| Redis container | 256MB |
| FastAPI API container | 512MB |
| Telegram Bot container | 256MB |
| React Dashboard container | 128MB |
| Caddy container | 128MB |
| Tor proxy container | 128MB |
| **Total** | **~2.9GB** |

**Minimum laptop RAM: 8GB. Recommended: 16GB.**

---

## 9. Hardware Requirements

| Component | Recommendation |
|-----------|---------------|
| USB 1 (Boot) | Samsung FIT Plus 128GB USB 3.1 |
| USB 2 (Program) | Samsung BAR Plus 64GB USB 3.1 |
| USB 3 (Data) | Apricorn Aegis Secure Key 3 128GB |
| Laptop | UEFI with F12 boot menu, 8GB+ RAM, 3x USB-A ports |

---

## 10. Provisioning Procedures

### USB 1 (install-to-usb1.sh)
1. LUKS2 full-disk encrypt USB drive
2. Partition: /boot (512MB unencrypted) + / (remainder inside LUKS)
3. debootstrap Debian 12 minimal
4. Install: docker.io, docker-compose-plugin, nftables, xfce4, firefox-esr, cryptsetup, lightdm
5. Configure auto-login, install sovereign-boot scripts, lock down system
6. Install GRUB to USB drive

### USB 2 (provision-usb2.sh)
1. Wipe with urandom, LUKS2 format, open, mkfs.ext4
2. Clone threadcount repo
3. Build Docker images, export as tarballs
4. Generate MANIFEST.sha256
5. Close LUKS

### USB 3 (provision-usb3.sh)
1. Set Apricorn hardware PIN
2. Format ext4
3. Create directory scaffold
4. Generate secrets (.env, JWT keys, Fernet key, SSL certs)
5. Copy to env/.env and postgres/ssl/

---

## 11. Operational Procedures

### Normal sovereign boot
F12 → USB 1 → LUKS passphrase → auto-login → sovereign-boot.sh → insert USB 2 (LUKS) → insert USB 3 (Apricorn PIN) → health check → docker compose up → Firefox opens dashboard

### Emergency shutdown
Ctrl+C (clean) | Pull USB 1 (immediate) | Power button 5s (hard off — all drives remain encrypted)

### Updating ThreadCount
On separate machine: git pull, docker compose build, docker save. Mount USB 2, replace tarballs, regenerate manifest.

### Backup
From sovereign session: pg_dump | gpg --symmetric → /mnt/sovereign/data/backups/

---

## 12. Project Structure

```
sovereign-boot/
├── scripts/
│   ├── sovereign-boot.sh
│   ├── sovereign-health-check.sh
│   ├── unmount-all.sh
│   ├── provision-usb2.sh
│   ├── provision-usb3.sh
│   └── build-images.sh
├── config/
│   ├── drive-uuids.conf
│   ├── mount-points.conf
│   ├── sovereign-firewall.nft
│   └── 99-sovereign-usb.rules
├── compose/
│   └── docker-compose.sovereign.yml
├── desktop/
│   └── sovereign-boot.desktop
├── install/
│   └── install-to-usb1.sh
└── docs/
    └── plans/
        └── 2026-03-29-sovereign-boot-design.md
```
