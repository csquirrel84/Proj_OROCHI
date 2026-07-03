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
echo "║                  NODE RESET SCRIPT v2.0                       ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${RED}This will permanently remove all OROCHI deployment artefacts:${NC}"
echo "  • All OROCHI Docker containers and their data"
echo "  • OROCHI Docker network and dangling volumes"
echo "  • /opt/orochi  (service data, certs, elasticsearch, kibana, thehive,"
echo "                  velociraptor, arkime, mattermost, timesketch, portal…)"
echo "  • /opt/rita, /etc/rita, /var/log/rita, /usr/local/bin/rita wrapper"
echo "  • Zeek runtime dirs, config, packages, and cron watchdog (purged)"
echo "  • Suricata config, data dirs, and packages (purged)"
echo "  • OROCHI-written systemd units and profile.d entries"
echo "  • Promiscuous mode on capture interfaces (turned off)"
echo "  • apt proxy config, Docker insecure-registry config"
echo "  • OROCHI firewall rules and persistence packages"
echo ""
echo -e "${YELLOW}Skipped for speed (commented out — re-enable for full clean):${NC}"
echo "  • All Docker image removal"
echo ""
read -rp "Type YES to confirm: " CONFIRM
[ "$CONFIRM" = "YES" ] || { echo "Cancelled."; exit 0; }
echo ""

# ── 1. Bare metal services ────────────────────────────────────────────────────
echo -e "${YELLOW}[1/9] Stopping bare metal services...${NC}"

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
echo -e "${YELLOW}[2/9] Removing Docker containers...${NC}"

CONTAINERS=(
    tool-portal
    timesketch
    timesketch-worker
    redis-timesketch
    postgres-timesketch
    mattermost
    postgres-mattermost
    cyberchef
    velociraptor
    arkimecapture
    arkimeviewer
    arkimecapture-remote
    thehive
    cassandra
    elasticsearch-hive
    fleet-server
    kibana
    elasticsearch
    rita-syslog-ng
    rita-clickhouse
)

for c in "${CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${c}$"; then
        info "Removing container: $c"
        docker stop "$c" 2>/dev/null || true
        docker rm -f "$c" 2>/dev/null || true
    fi
done
ok "Containers removed"

# ── 3. Docker network ─────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[3/9] Removing Docker network...${NC}"

if docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^orochi-network$"; then
    info "Removing orochi-network"
    docker network rm orochi-network 2>/dev/null || true
fi
ok "Network removed"

# ── 4. Docker volumes ─────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[4/9] Removing Docker volumes...${NC}"

DANGLING=$(docker volume ls -qf dangling=true 2>/dev/null)
if [ -n "$DANGLING" ]; then
    info "Removing dangling Docker volumes"
    docker volume rm $DANGLING 2>/dev/null || true
fi
ok "Volumes removed"

# ── 5. Data directories ───────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[5/9] Removing data directories...${NC}"

# Main OROCHI data tree (all service data lives under /opt/orochi)
for path in \
    /opt/orochi \
    /opt/rita \
    /etc/rita \
    /var/log/rita \
    /usr/local/bin/rita \
    /tmp/docker-debs \
    /tmp/docker-debs.tar.gz \
    /tmp/zeek-debs \
    /tmp/zeek-debs.tar.gz \
    /tmp/suricata-debs \
    /tmp/suricata-debs.tar.gz \
    /tmp/suricata-rules.tar.gz \
    /tmp/rita-installer.tar.gz \
    /tmp/rita-*-installer \
    /tmp/rita_patch_images.py \
    /tmp/zeek-release.key
do
    if [ -e "$path" ]; then
        info "Removing $path"
        rm -rf "$path" || warn "Failed to remove $path (check for active mounts)"
    fi
done

# Zeek — /opt/zeek is the package install root; do NOT remove it (breaks dpkg).
# Remove only the dirs written by OROCHI so zeekctl can redeploy fresh.
for path in \
    /opt/zeek/etc \
    /opt/zeek/logs \
    /opt/zeek/spool \
    /opt/zeek/share/zeek/site
do
    if [ -e "$path" ]; then
        info "Removing $path"
        rm -rf "$path" || warn "Failed to remove $path"
    fi
done

# Suricata config and data dirs
for path in \
    /etc/suricata \
    /etc/default/suricata \
    /var/log/suricata \
    /var/lib/suricata
do
    if [ -e "$path" ]; then
        info "Removing $path"
        rm -rf "$path" || warn "Failed to remove $path"
    fi
done

ok "Data directories removed"

# ── 6. Bare metal packages ─────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[6/9] Purging bare metal packages...${NC}"

ZEEK_PKGS="zeek zeek-core zeek-core-dev zeekctl zeek-client zeek-btest zeek-btest-data zeek-zkg zeek-spicy-dev"
ZEEK_INSTALLED=$(dpkg -l $ZEEK_PKGS 2>/dev/null | awk '/^[hi]i/{print $2}')
if [ -n "$ZEEK_INSTALLED" ]; then
    info "Purging zeek packages: $ZEEK_INSTALLED"
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all $ZEEK_INSTALLED 2>/dev/null || true
fi

# suricata-debs.tar.gz also installs jq and libevent — purge the lot
SURI_PKGS="suricata jq libevent-2.1-7t64 libevent-core-2.1-7t64 libevent-pthreads-2.1-7t64"
SURI_INSTALLED=$(dpkg -l $SURI_PKGS 2>/dev/null | awk '/^[hi]i/{print $2}')
if [ -n "$SURI_INSTALLED" ]; then
    info "Purging suricata packages: $SURI_INSTALLED"
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all $SURI_INSTALLED 2>/dev/null || true
fi

ok "Bare metal packages purged"

# ── 7. Docker images ──────────────────────────────────────────────────────────
# COMMENTED OUT for faster testing cycles.
# Re-enable when you need images re-pulled from the management box registry.
echo ""
echo -e "${YELLOW}[7/9] Docker images (SKIPPED)...${NC}"

# info "Removing all Docker images"
# docker rmi $(docker images -q) 2>/dev/null || true

ok "Image removal skipped"

# ── 8. Systemd units ──────────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[8/9] Removing OROCHI systemd units...${NC}"

for unit in \
    /etc/systemd/system/zeek.service \
    /etc/systemd/system/suricata.service.d \
    /etc/systemd/system/zeek.service.d
do
    if [ -e "$unit" ]; then
        info "Removing $unit"
        rm -rf "$unit"
    fi
done

for unit in /etc/systemd/system/promisc-*.service; do
    if [ -e "$unit" ]; then
        # Turn promiscuous mode off on the live interface before removing
        # the unit — otherwise the flag persists until reboot.
        IFACE=$(basename "$unit" .service)
        IFACE=${IFACE#promisc-}
        if ip link show "$IFACE" &>/dev/null; then
            info "Disabling promiscuous mode on $IFACE"
            ip link set "$IFACE" promisc off 2>/dev/null || true
        fi
        info "Removing $unit"
        systemctl disable "$(basename "$unit")" 2>/dev/null || true
        rm -f "$unit"
    fi
done

if [ -f /etc/profile.d/zeek.sh ]; then
    info "Removing /etc/profile.d/zeek.sh"
    rm -f /etc/profile.d/zeek.sh
fi

# zeekctl cron watchdog installed by the zeek role
if crontab -l 2>/dev/null | grep -q 'zeekctl cron'; then
    info "Removing zeekctl cron watchdog"
    crontab -l 2>/dev/null | grep -v 'zeekctl cron' | crontab - || true
fi

systemctl daemon-reload 2>/dev/null || true
ok "Systemd units removed"

# ── 9. Node configuration ─────────────────────────────────────────────────────
echo ""
echo -e "${YELLOW}[9/9] Removing node configuration...${NC}"

# apt proxy written by bootstrap_node role
if [ -f /etc/apt/apt.conf.d/01orochi-proxy ]; then
    info "Removing apt proxy config"
    rm -f /etc/apt/apt.conf.d/01orochi-proxy
fi

# Zeek GPG keyring added by zeek role
if [ -f /etc/apt/keyrings/zeek-archive-keyring.gpg ]; then
    info "Removing Zeek GPG keyring"
    rm -f /etc/apt/keyrings/zeek-archive-keyring.gpg
fi

# Docker insecure-registry config written by common role
if [ -f /etc/docker/daemon.json ]; then
    info "Removing Docker insecure-registry config"
    rm -f /etc/docker/daemon.json
    systemctl restart docker 2>/dev/null || true
fi

# Firewall rules written by the firewall role
info "Flushing OROCHI firewall rules"
iptables -F INPUT 2>/dev/null || true
iptables -F DOCKER-USER 2>/dev/null || true
iptables -A DOCKER-USER -j RETURN 2>/dev/null || true
rm -f /etc/iptables/rules.v4 /etc/iptables/rules.v6

# Firewall persistence packages installed by the firewall role
# (iptables itself is a base-system package — left alone)
FW_PKGS=$(dpkg -l iptables-persistent netfilter-persistent 2>/dev/null | awk '/^[hi]i/{print $2}')
if [ -n "$FW_PKGS" ]; then
    info "Purging firewall persistence packages: $FW_PKGS"
    DEBIAN_FRONTEND=noninteractive dpkg --purge --force-all $FW_PKGS 2>/dev/null || true
fi

# Any leftover RITA compose networks (compose down handles these when the
# compose file still exists; this catches partially-removed installs)
for net in $(docker network ls --format '{{.Name}}' 2>/dev/null | grep '^rita' || true); do
    info "Removing Docker network: $net"
    docker network rm "$net" 2>/dev/null || true
done

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
