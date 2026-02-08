#!/bin/bash

# ==============================================
# OROCHI SECURITY STACK - RESET SCRIPT
# ==============================================
# This script removes ONLY Orochi components
# It will NOT affect other Docker projects
# ==============================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Orochi configuration
OROCHI_BASE_PATH="/opt/orochi"
OROCHI_NETWORK="orochi-network"

# List of Orochi containers
OROCHI_CONTAINERS=(
    "elasticsearch"
    "kibana"
    "fleet-server"
    "elasticsearch-hive"
    "thehive"
    "cassandra"
    "velociraptor"
    "suricata"
    "arkime"
    "cyberchef"
    "mattermost"
    "postgres-mattermost"
    "nginx-proxy"
)

echo -e "${YELLOW}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                                                               ║"
echo "║     ██████  ██████   ██████   ██████ ██   ██ ██               ║"
echo "║    ██    ██ ██   ██ ██    ██ ██      ██   ██ ██               ║"
echo "║    ██    ██ ██████  ██    ██ ██      ███████ ██               ║"
echo "║    ██    ██ ██   ██ ██    ██ ██      ██   ██ ██               ║"
echo "║     ██████  ██   ██  ██████   ██████ ██   ██ ██               ║"
echo "║                                                               ║"
echo "║                  RESET SCRIPT v1.0                            ║"
echo "║                                                               ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo -e "${RED}WARNING: This will remove ALL Orochi components:${NC}"
echo "  - Docker containers: ${OROCHI_CONTAINERS[@]}"
echo "  - Docker network: ${OROCHI_NETWORK}"
echo "  - All data in: ${OROCHI_BASE_PATH}"
echo ""
echo -e "${YELLOW}This will NOT affect other Docker projects on this system.${NC}"
echo ""
read -p "Are you sure you want to continue? Type 'YES' to confirm: " CONFIRM

if [ "$CONFIRM" != "YES" ]; then
    echo -e "${GREEN}Reset cancelled.${NC}"
    exit 0
fi

echo ""
echo -e "${GREEN}Starting Orochi reset...${NC}"
echo ""

# ==============================================
# Stop and remove Orochi containers
# ==============================================
echo -e "${YELLOW}[1/4] Stopping and removing Orochi containers...${NC}"
for container in "${OROCHI_CONTAINERS[@]}"; do
    if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
        echo "  - Removing container: ${container}"
        docker stop "${container}" 2>/dev/null || true
        docker rm -f "${container}" 2>/dev/null || true
    else
        echo "  - Container not found (skipping): ${container}"
    fi
done
echo -e "${GREEN}✓ Containers removed${NC}"
echo ""

# ==============================================
# Remove Orochi Docker network
# ==============================================
echo -e "${YELLOW}[2/4] Removing Orochi Docker network...${NC}"
if docker network ls --format '{{.Name}}' | grep -q "^${OROCHI_NETWORK}$"; then
    echo "  - Removing network: ${OROCHI_NETWORK}"
    docker network rm "${OROCHI_NETWORK}" 2>/dev/null || true
    echo -e "${GREEN}✓ Network removed${NC}"
else
    echo "  - Network not found (skipping): ${OROCHI_NETWORK}"
    echo -e "${GREEN}✓ Network already removed${NC}"
fi
echo ""

# ==============================================
# Remove Orochi volumes (optional - only unnamed ones)
# ==============================================
echo -e "${YELLOW}[3/4] Cleaning up dangling Docker volumes...${NC}"
DANGLING_VOLUMES=$(docker volume ls -qf dangling=true)
if [ -n "$DANGLING_VOLUMES" ]; then
    echo "  - Removing dangling volumes"
    docker volume rm $DANGLING_VOLUMES 2>/dev/null || true
    echo -e "${GREEN}✓ Dangling volumes removed${NC}"
else
    echo "  - No dangling volumes found"
    echo -e "${GREEN}✓ No cleanup needed${NC}"
fi
echo ""

# ==============================================
# Remove Orochi data directories
# ==============================================
echo -e "${YELLOW}[4/4] Removing Orochi data directories...${NC}"
if [ -d "$OROCHI_BASE_PATH" ]; then
    echo "  - Removing: ${OROCHI_BASE_PATH}"
    echo "    This includes all subdirectories:"
    echo "      • certs, elasticsearch, kibana, fleet"
    echo "      • thehive, thehive-es, cassandra"
    echo "      • velociraptor, suricata, arkime"
    echo "      • mattermost, postgres, nginx, logs"

    # Check if we need sudo
    if [ -w "$OROCHI_BASE_PATH" ]; then
        rm -rf "$OROCHI_BASE_PATH"
    else
        echo "  - Requires sudo privileges..."
        sudo rm -rf "$OROCHI_BASE_PATH"
    fi
    echo -e "${GREEN}✓ Data directories removed${NC}"
else
    echo "  - Directory not found (skipping): ${OROCHI_BASE_PATH}"
    echo -e "${GREEN}✓ Directory already removed${NC}"
fi
echo ""

# ==============================================
# Summary
# ==============================================
echo -e "${GREEN}"
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║                     RESET COMPLETE                            ║"
echo "╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""
echo "Orochi has been completely removed from this system."
echo "Other Docker projects and images remain untouched."
echo ""
echo "To redeploy Orochi, run:"
echo "  ansible-playbook fuse.yml"
echo ""
