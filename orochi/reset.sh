#!/bin/bash
# =============================================================================
# OROCHI RESET — returns the orochi node to a clean pre-deployment state
# Run as root or with sudo: sudo bash reset.sh
# =============================================================================

set -uo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $*"; }
info() { echo -e "  ${CYAN}→${NC} $*"; }
warn() { echo -e "  ${YELLOW}!${NC} $*"; }

# ── Must run as root ──────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root: sudo bash reset.sh${NC}"
    exit 1
fi

echo -e "${YELLOW}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                                                               ║"
echo "║     ██████  ██████   ██████   ██████ ██   ██ ██               ║"
echo "║    ██    ██ ██   ██ ██    ██ ██      ██   ██ ██               ║"
echo "║    ██    ██ ██████  ██    ██ ██      ███████ ██               ║"
echo "║    ██    ██ ██   ██ ██    ██ ██      ██   ██ ██               ║"
echo "║     ██████  ██   ██  ██████   ██████ ██   ██ ██               ║"
echo "║                                                               ║"
echo "║                  NODE RESET SCRIPT v1.0                       ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${RED}This will permanently remove:${NC}"
echo "  • All Orochi Docker containers and data"
echo "  • Suricata and Zeek packages, configs, and rules"
echo "  • Docker insecure-registry config"
echo "  • apt proxy config"
echo ""
echo -e "${YELLOW}Docker itself and OS packages remain intact.${NC}"
echo ""
read -rp "Type YES to confirm: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Cancelled."; exit 0; }
echo ""

# ── 1. Bare metal services ────────────────────────────────────────────────────
echo -e "${YELLOW}[1/7] Stopping bare metal services...${NC}"

# RITA runs as a docker-compose stack — tear it down first
if [ -f /opt/rita/docker-compose.yml ]; then
    info "Stopping RITA docker-compose stack"
    docker compose -f /opt/rita/docker-compose.yml down -v 2>/dev/null || true
fi

for svc in suricata zeek; do
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        info "Stopping $svc"
        systemctl stop "$svc" 2>/dev/null || true
    fi
    if systemctl is-enabled --quiet "$svc" 2>/dev/null; then
        systemctl disable "$svc" 2>/dev/null || true
    fi
done
ok "Bare metal services stopped"

# ── 2. Docker containers ──────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[2/7] Removing Docker containers...${NC}"

CONTAINERS=(
    elasticsearch
    kibana
    fleet-server
    elasticsearch-hive
    thehive
    cassandra
    velociraptor
    arkime
    cyberchef
    mattermost
    postgres-mattermost
    timesketch
    timesketch-worker
    redis-timesketch
    postgres-timesketch
    nginx-portal
)

for c in "${CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$"; then
        info "Removing container: $c"
        docker rm -f "$c" 2>/dev/null || true
    fi
done
ok "Containers removed"

# ── 3. Docker network ─────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[3/7] Removing Docker network...${NC}"

if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^orochi-network$"; then
    info "Removing orochi-network"
    docker network rm orochi-network 2>/dev/null || true
fi
ok "Network removed"

# ── 4. Data directories ───────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[4/7] Removing data directories...${NC}"

for path in \
    /opt/orochi \
    /opt/rita \
    /var/log/suricata \
    /var/lib/suricata \
    /etc/suricata \
    /opt/zeek/logs \
    /tmp/docker-debs \
    /tmp/docker-debs.tar.gz \
    /tmp/suricata-debs \
    /tmp/suricata-debs.tar.gz \
    /tmp/zeek-debs \
    /tmp/zeek-debs.tar.gz \
    /tmp/suricata-rules.tar.gz \
    /tmp/arkime-deps \
    /tmp/arkime-deps.tar.gz \
    /tmp/rita-installer.tar.gz \
    /tmp/rita_patch_images.py
do
    if [ -e "$path" ]; then
        info "Removing $path"
        rm -rf "$path"
    fi
done
ok "Data directories removed"

# ── 5. Bare metal packages ────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[5/7] Removing bare metal packages...${NC}"

if dpkg -l suricata &>/dev/null; then
    info "Purging suricata"
    apt-get purge -y suricata 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
fi

if dpkg -l zeek &>/dev/null; then
    info "Purging zeek"
    apt-get purge -y zeek 2>/dev/null || true
    apt-get autoremove -y 2>/dev/null || true
fi
ok "Packages removed"

# ── 6. Suricata systemd override ──────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[6/7] Removing systemd overrides...${NC}"

for override in \
    /etc/systemd/system/suricata.service.d \
    /etc/systemd/system/zeek.service.d
do
    if [ -d "$override" ]; then
        info "Removing $override"
        rm -rf "$override"
    fi
done
systemctl daemon-reload 2>/dev/null || true
ok "Systemd overrides removed"

# ── 7. Node configuration ─────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[7/7] Removing node configuration...${NC}"

# apt proxy
if [ -f /etc/apt/apt.conf.d/01orochi-proxy ]; then
    info "Removing apt proxy config"
    rm -f /etc/apt/apt.conf.d/01orochi-proxy
fi

# Docker insecure registry
if [ -f /etc/docker/daemon.json ]; then
    info "Removing Docker insecure-registry config"
    rm -f /etc/docker/daemon.json
    systemctl restart docker 2>/dev/null || true
fi

# Dangling Docker volumes
DANGLING=$(docker volume ls -qf dangling=true 2>/dev/null)
if [ -n "$DANGLING" ]; then
    info "Removing dangling Docker volumes"
    docker volume rm $DANGLING 2>/dev/null || true
fi

ok "Node configuration cleaned"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                     RESET COMPLETE                            ║"
echo "║                                                               ║"
echo "║  Node is clean. Run fuse.yml to redeploy.                     ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
