#!/bin/bash
# McRubes Media Server — Setup Script
# Run once on fresh Debian install as root
# Usage: bash /Docker/Compose/setup.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

echo ""
echo "================================================"
echo "   McRubes Media Server — Setup"
echo "================================================"
echo ""

# ---------------------------------------------------------------------------
# 1. System update
# ---------------------------------------------------------------------------
info "Updating system packages..."
apt-get update -qq && apt-get upgrade -y -qq

# ---------------------------------------------------------------------------
# 2. Install Docker
# ---------------------------------------------------------------------------
if command -v docker &>/dev/null; then
    info "Docker already installed: $(docker --version)"
else
    info "Installing Docker..."
    apt-get install -y -qq curl ca-certificates
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
    info "Docker installed: $(docker --version)"
fi

# ---------------------------------------------------------------------------
# 3. Install Tailscale
# ---------------------------------------------------------------------------
if command -v tailscale &>/dev/null; then
    info "Tailscale already installed: $(tailscale version | head -1)"
else
    info "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    systemctl enable tailscaled
    systemctl start tailscaled
fi

echo ""
warn "Tailscale auth required. A URL will appear — open it to authenticate."
warn "After auth, press Enter to continue."
tailscale up --ssh
echo ""
read -p "Press Enter once Tailscale is authenticated..."

# ---------------------------------------------------------------------------
# 4. Create directory structure
# ---------------------------------------------------------------------------
info "Creating directory structure..."

mkdir -p \
  /Docker/Compose/services \
  /Docker/Server/plex/config \
  /Docker/Server/tautulli/config \
  /Docker/Server/sonarr/config \
  /Docker/Server/radarr/config \
  /Docker/Server/prowlarr/config \
  /Docker/Server/bazarr/config \
  /Docker/Server/overseerr/config \
  /Docker/Server/qbittorrent/config \
  /Docker/Server/sabnzbd/config \
  /Docker/Server/calibre-web-automated/config \
  /Docker/Server/shelfmark/config \
  /Docker/Server/portainer/data \
  /Docker/Server/wud \
  /Docker/Server/watchtower \
  /Docker/Server/glances \
  /Docker/Server/homepage/config \
  /Media/Movies \
  /Media/TV \
  /Media/Music \
  /Media/Books \
  /Media/InjestBooks \
  /Media/Transcode \
  /Media/Downloads/complete \
  /Media/Downloads/incomplete

info "Directories created."

# ---------------------------------------------------------------------------
# 5. Mount external media drive
# ---------------------------------------------------------------------------
echo ""
info "Detecting external drives for /Media..."

# Find non-NVMe, non-loop block devices with a filesystem
EXTERNAL=$(lsblk -rno NAME,TYPE,FSTYPE | grep -v "nvme\|loop\|sr" | grep "part\|disk" | grep -v "^$" | awk '{print $1, $3}' | grep -v " $")

if [ -z "$EXTERNAL" ]; then
    warn "No external drive detected. /Media will use the NVMe until a drive is connected."
    warn "When you connect the drive, run: bash /Docker/Compose/mount-media.sh"
else
    echo "Found external device(s):"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT | grep -v "nvme\|loop"
    echo ""

    # Auto-select first candidate
    DEVICE=$(lsblk -rno NAME,TYPE,FSTYPE | grep -v "nvme\|loop\|sr" | grep "part" | head -1 | awk '{print $1}')
    FSTYPE=$(lsblk -rno NAME,FSTYPE /dev/$DEVICE 2>/dev/null | head -1 | awk '{print $2}')
    UUID=$(blkid -s UUID -o value /dev/$DEVICE 2>/dev/null)

    if [ -n "$UUID" ]; then
        info "Using /dev/$DEVICE (UUID=$UUID, fstype=$FSTYPE) -> /Media"

        # Check if already in fstab
        if grep -q "$UUID" /etc/fstab; then
            warn "UUID $UUID already in /etc/fstab — skipping."
        else
            # Format if no filesystem detected
            if [ -z "$FSTYPE" ]; then
                warn "No filesystem on /dev/$DEVICE — formatting as ext4..."
                mkfs.ext4 -L Media /dev/$DEVICE
                UUID=$(blkid -s UUID -o value /dev/$DEVICE)
            fi
            echo "UUID=$UUID /Media ${FSTYPE:-ext4} defaults,nofail 0 2" >> /etc/fstab
            info "Added to /etc/fstab"
        fi

        mount -a && info "/Media mounted successfully." || warn "mount -a failed — check /etc/fstab"
    else
        warn "Could not determine UUID. Mount /Media manually and re-run."
    fi
fi

# ---------------------------------------------------------------------------
# 6. Plex claim token check
# ---------------------------------------------------------------------------
echo ""
CLAIM=$(grep PLEX_CLAIM /Docker/Compose/.env | cut -d= -f2)
if echo "$CLAIM" | grep -q "REPLACEME"; then
    warn "PLEX_CLAIM is not set in /Docker/Compose/.env"
    warn "Get a token at https://plex.tv/claim (expires in 4 minutes)"
    warn "Edit .env: PLEX_CLAIM=claim-xxxxxxxxxxxx"
    echo ""
    read -p "Paste your Plex claim token (or press Enter to skip): " TOKEN
    if [ -n "$TOKEN" ]; then
        sed -i "s|PLEX_CLAIM=.*|PLEX_CLAIM=$TOKEN|" /Docker/Compose/.env
        info "Plex claim token saved."
    else
        warn "Skipping — Plex will start without a claim token. Set it and restart the plex container."
    fi
fi

# ---------------------------------------------------------------------------
# 7. Bring up the stack
# ---------------------------------------------------------------------------
echo ""
info "Pulling Docker images (this may take a few minutes)..."
cd /Docker/Compose
docker compose pull

info "Starting all containers..."
docker compose up -d

# ---------------------------------------------------------------------------
# 8. Done — report status
# ---------------------------------------------------------------------------
echo ""
echo "================================================"
info "Setup complete! Waiting 10s for containers to initialize..."
sleep 10
docker compose ps
echo ""
SERVER_IP=$(hostname -I | awk '{print $1}')
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "not connected")
echo ""
echo "  Homepage:     http://${SERVER_IP}:3000"
echo "  Plex:         http://${SERVER_IP}:32400/web"
echo "  Portainer:    http://${SERVER_IP}:9000"
echo "  Sonarr:       http://${SERVER_IP}:8989"
echo "  Radarr:       http://${SERVER_IP}:7878"
echo "  qBittorrent:  http://${SERVER_IP}:8888"
echo "  SABnzbd:      http://${SERVER_IP}:7777"
echo "  Tailscale IP: ${TAILSCALE_IP}"
echo ""
echo "  Next steps:"
echo "  1. Set mcrubens/mcrubens on each service"
echo "  2. Configure Plex library paths -> /media/Movies, /media/TV, /media/Music"
echo "  3. Link Sonarr/Radarr -> Prowlarr -> qBittorrent & SABnzbd"
echo "  4. Grab API keys and update /Docker/Server/homepage/config/services.yaml"
echo "  5. Verify Tailscale remote access before leaving your network"
echo "================================================"
