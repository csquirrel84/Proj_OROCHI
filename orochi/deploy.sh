#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# OROCHI SECURITY STACK - DEPLOYMENT SCRIPT
# ==============================================
# This is the only script the analyst needs to run.
# It handles everything: dependencies, configuration,
# and full stack deployment.
# ==============================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# Project directory (where this script lives)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ==============================================
# Banner
# ==============================================
clear
echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════════════════════════════╗"
echo "  ║                                                               ║"
echo "  ║     ██████  ██████   ██████   ██████ ██   ██ ██               ║"
echo "  ║    ██    ██ ██   ██ ██    ██ ██      ██   ██ ██               ║"
echo "  ║    ██    ██ ██████  ██    ██ ██      ███████ ██               ║"
echo "  ║    ██    ██ ██   ██ ██    ██ ██      ██   ██ ██               ║"
echo "  ║     ██████  ██   ██  ██████   ██████ ██   ██ ██               ║"
echo "  ║                                                               ║"
echo "  ║              SECURITY STACK DEPLOYER v2.0                     ║"
echo "  ║                  Localhost Edition                             ║"
echo "  ║                                                               ║"
echo "  ╚═══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
echo ""

# ==============================================
# Pre-flight checks
# ==============================================
echo -e "${YELLOW}[1/7] Pre-flight checks...${NC}"

# Check Ubuntu version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        echo -e "${RED}ERROR: This script requires Ubuntu 24.04 or 25.04${NC}"
        echo "Detected: $PRETTY_NAME"
        exit 1
    fi
    UBUNTU_MAJOR="${VERSION_ID%%.*}"
    if [[ "$UBUNTU_MAJOR" -lt 24 ]]; then
        echo -e "${RED}ERROR: Ubuntu 24.04 or later required. Detected: $VERSION_ID${NC}"
        exit 1
    fi
    echo -e "  ${GREEN}✓${NC} Ubuntu $VERSION_ID detected"
else
    echo -e "${RED}ERROR: Cannot determine OS version${NC}"
    exit 1
fi

# Check running as non-root with sudo
if [[ "$EUID" -eq 0 ]]; then
    echo -e "${RED}ERROR: Do not run this script as root.${NC}"
    echo "Run as a normal user with sudo privileges."
    exit 1
fi

if ! sudo -v 2>/dev/null; then
    echo -e "${RED}ERROR: You need sudo privileges to deploy Orochi.${NC}"
    exit 1
fi
echo -e "  ${GREEN}✓${NC} Sudo access confirmed"

# Keep sudo session alive in the background (refreshes every 50 seconds)
# This prevents sudo timeout during long deployments
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!
trap "kill $SUDO_KEEPALIVE_PID 2>/dev/null; rm -f '$SCRIPT_DIR/.vault_pass' '$SCRIPT_DIR/.become_pass'" EXIT

# Check minimum RAM (16GB recommended)
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
TOTAL_RAM_GB=$((TOTAL_RAM_KB / 1024 / 1024))
if [[ "$TOTAL_RAM_GB" -lt 12 ]]; then
    echo -e "${YELLOW}  WARNING: Only ${TOTAL_RAM_GB}GB RAM detected. 16GB+ recommended for full stack.${NC}"
else
    echo -e "  ${GREEN}✓${NC} ${TOTAL_RAM_GB}GB RAM detected"
fi

echo ""

# ==============================================
# Install dependencies
# ==============================================
echo -e "${YELLOW}[2/7] Installing dependencies...${NC}"

# Update apt cache
sudo apt-get update -qq > /dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Package cache updated"

# Install Ansible and prerequisites
sudo apt-get install -y -qq \
    ansible \
    python3-docker \
    python3-requests \
    python3-urllib3 \
    python3-jmespath \
    sshpass \
    openssl \
    curl \
    jq \
    > /dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Ansible and dependencies installed"

# Install Ansible Docker collection
ansible-galaxy collection install community.docker --force > /dev/null 2>&1
echo -e "  ${GREEN}✓${NC} Ansible Docker collection installed"

echo ""

# ==============================================
# Ask the analyst for passwords
# ==============================================
echo -e "${YELLOW}[3/7] Security configuration...${NC}"
echo ""
echo -e "${BOLD}  All services (Elasticsearch, Kibana, TheHive, Velociraptor,"
echo -e "  Arkime, Mattermost) will share a single password.${NC}"
echo ""

while true; do
    read -sp "  Enter a password for all services: " SERVICE_PASSWORD
    echo ""
    if [[ ${#SERVICE_PASSWORD} -lt 8 ]]; then
        echo -e "  ${RED}Password must be at least 8 characters. Try again.${NC}"
        continue
    fi
    read -sp "  Confirm password: " SERVICE_PASSWORD_CONFIRM
    echo ""
    if [[ "$SERVICE_PASSWORD" != "$SERVICE_PASSWORD_CONFIRM" ]]; then
        echo -e "  ${RED}Passwords do not match. Try again.${NC}"
        continue
    fi
    break
done
echo -e "  ${GREEN}✓${NC} Service password set"
echo ""

echo -e "${BOLD}  The vault password protects your configuration on disk."
echo -e "  You will need this password if you re-run the deployer later.${NC}"
echo ""

while true; do
    read -sp "  Enter a vault password: " VAULT_PASSWORD
    echo ""
    if [[ ${#VAULT_PASSWORD} -lt 6 ]]; then
        echo -e "  ${RED}Vault password must be at least 6 characters. Try again.${NC}"
        continue
    fi
    read -sp "  Confirm vault password: " VAULT_PASSWORD_CONFIRM
    echo ""
    if [[ "$VAULT_PASSWORD" != "$VAULT_PASSWORD_CONFIRM" ]]; then
        echo -e "  ${RED}Passwords do not match. Try again.${NC}"
        continue
    fi
    break
done
echo -e "  ${GREEN}✓${NC} Vault password set"
echo ""

# ==============================================
# Network interface selection
# ==============================================
echo -e "${YELLOW}[4/7] Network interface configuration...${NC}"
echo ""

# Discover interfaces (exclude lo, docker, bridge, veth)
mapfile -t IFACE_NAMES < <(ip -o -4 addr show | awk '{print $2}' | grep -vE '^(lo|docker|br-|veth)' | sort -u)
mapfile -t IFACE_IPS < <(for iface in "${IFACE_NAMES[@]}"; do ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1; done)

# Also get interfaces WITHOUT an IP (PCAP interfaces often have no IP)
mapfile -t ALL_IFACES < <(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br-|veth)' | sort -u)

if [[ ${#ALL_IFACES[@]} -lt 1 ]]; then
    echo -e "${RED}ERROR: No network interfaces found!${NC}"
    exit 1
fi

echo -e "  ${BOLD}Available network interfaces:${NC}"
echo ""
for i in "${!ALL_IFACES[@]}"; do
    iface="${ALL_IFACES[$i]}"
    ip_addr=$(ip -o -4 addr show "$iface" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1 || true)
    state=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'state \K\S+' || true)
    mac=$(ip -o link show "$iface" 2>/dev/null | grep -oP 'link/ether \K\S+' || true)
    if [[ -n "$ip_addr" ]]; then
        echo -e "    ${CYAN}$((i+1)).${NC} ${BOLD}${iface}${NC}  -  ${ip_addr}  (${state:-unknown}) [${mac:-unknown}]"
    else
        echo -e "    ${CYAN}$((i+1)).${NC} ${BOLD}${iface}${NC}  -  no IP assigned  (${state:-unknown}) [${mac:-unknown}]"
    fi
done
echo ""

# --- PCAP Interface ---
echo -e "  ${BOLD}PCAP Capture Interface${NC}"
echo -e "  This is the SPAN/mirror port from your switch."
echo -e "  Suricata, Zeek, and Arkime will sniff packets on this interface."
echo ""
while true; do
    read -p "  Select PCAP interface number: " PCAP_CHOICE
    if [[ "$PCAP_CHOICE" =~ ^[0-9]+$ ]] && [[ "$PCAP_CHOICE" -ge 1 ]] && [[ "$PCAP_CHOICE" -le ${#ALL_IFACES[@]} ]]; then
        PCAP_INTERFACE="${ALL_IFACES[$((PCAP_CHOICE-1))]}"
        break
    fi
    echo -e "  ${RED}Invalid selection. Enter a number between 1 and ${#ALL_IFACES[@]}.${NC}"
done
echo -e "  ${GREEN}✓${NC} PCAP interface: ${BOLD}${PCAP_INTERFACE}${NC}"
echo ""

# --- Log Ingestion Interface ---
echo -e "  ${BOLD}Log Ingestion Interface${NC}"
echo -e "  Elastic Agents on endpoints will send logs to this IP."
echo -e "  Fleet Server enrollment uses this address."
echo ""
while true; do
    read -p "  Select log ingestion interface number: " INGEST_CHOICE
    if [[ "$INGEST_CHOICE" =~ ^[0-9]+$ ]] && [[ "$INGEST_CHOICE" -ge 1 ]] && [[ "$INGEST_CHOICE" -le ${#ALL_IFACES[@]} ]]; then
        INGEST_INTERFACE="${ALL_IFACES[$((INGEST_CHOICE-1))]}"
        INGESTION_IP=$(ip -o -4 addr show "$INGEST_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
        if [[ -z "$INGESTION_IP" ]]; then
            echo -e "  ${RED}That interface has no IP address. Log ingestion needs an IP. Pick another.${NC}"
            continue
        fi
        break
    fi
    echo -e "  ${RED}Invalid selection. Enter a number between 1 and ${#ALL_IFACES[@]}.${NC}"
done
echo -e "  ${GREEN}✓${NC} Log ingestion interface: ${BOLD}${INGEST_INTERFACE}${NC} (${INGESTION_IP})"
echo ""

# --- Analyst Access Interface ---
echo -e "  ${BOLD}Analyst Access Interface${NC}"
echo -e "  SOC analysts will browse to Kibana, TheHive, and the portal"
echo -e "  from this network. Connect a switch here for analyst laptops."
echo ""
while true; do
    read -p "  Select analyst access interface number: " ACCESS_CHOICE
    if [[ "$ACCESS_CHOICE" =~ ^[0-9]+$ ]] && [[ "$ACCESS_CHOICE" -ge 1 ]] && [[ "$ACCESS_CHOICE" -le ${#ALL_IFACES[@]} ]]; then
        ACCESS_INTERFACE="${ALL_IFACES[$((ACCESS_CHOICE-1))]}"
        ACCESS_IP=$(ip -o -4 addr show "$ACCESS_INTERFACE" 2>/dev/null | awk '{print $4}' | cut -d'/' -f1 | head -1)
        if [[ -z "$ACCESS_IP" ]]; then
            echo -e "  ${RED}That interface has no IP address. Analyst access needs an IP. Pick another.${NC}"
            continue
        fi
        break
    fi
    echo -e "  ${RED}Invalid selection. Enter a number between 1 and ${#ALL_IFACES[@]}.${NC}"
done
echo -e "  ${GREEN}✓${NC} Analyst access interface: ${BOLD}${ACCESS_INTERFACE}${NC} (${ACCESS_IP})"
echo ""

# Auto-derive HOME_NET from ingestion interface subnet
INGEST_CIDR=$(ip -o -4 addr show "$INGEST_INTERFACE" 2>/dev/null | awk '{print $4}' | head -1)
if [[ -n "$INGEST_CIDR" ]]; then
    # Extract network portion using ipcalc-like logic
    IFS='/' read -r INGEST_ADDR INGEST_MASK <<< "$INGEST_CIDR"
    HOME_NET="${INGEST_CIDR}"
else
    HOME_NET="192.168.0.0/16"
fi

# ==============================================
# Generate secrets and write configuration
# ==============================================
echo -e "${YELLOW}[5/7] Generating configuration...${NC}"

# Generate random secrets
ARKIME_PASSWORD_SECRET=$(openssl rand -base64 32)
KIBANA_ENCRYPTION_KEY=$(openssl rand -hex 32)

# Write vault password file (temporary)
echo "$VAULT_PASSWORD" > "$SCRIPT_DIR/.vault_pass"
chmod 600 "$SCRIPT_DIR/.vault_pass"

# Create encrypted secrets vault
cat > /tmp/orochi_secrets.yml <<SECRETS_EOF
---
common_password: "$SERVICE_PASSWORD"
vault_kibana_encryption_key: "$KIBANA_ENCRYPTION_KEY"
SECRETS_EOF

ansible-vault encrypt /tmp/orochi_secrets.yml \
    --vault-password-file "$SCRIPT_DIR/.vault_pass" \
    --output "$SCRIPT_DIR/vars/secrets.yml" \
    > /dev/null 2>&1

# Clean up plaintext
rm -f /tmp/orochi_secrets.yml
echo -e "  ${GREEN}✓${NC} Encrypted vault created (vars/secrets.yml)"

# Write .env configuration
cat > "$SCRIPT_DIR/.env" <<ENV_EOF
# ==============================================
# Orochi Security Stack Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
# Target: localhost
# ==============================================
STACK_VERSION=9.3.0
CLUSTER_NAME=orochi
LICENSE=trial
MEM_LIMIT=4g
VELOX_USER=admin
VELOX_ROLE=administrator
VELOX_SERVER_URL=https://${ACCESS_IP}:8889/
VELOX_FRONTEND_HOSTNAME=${ACCESS_IP}
ES_PORT=9200
KIBANA_PORT=5601
FLEET_PORT=8220
SURICATA_PORT=8000
PCAP_INTERFACE=${PCAP_INTERFACE}
SURICATA_INTERFACE=${PCAP_INTERFACE}
SURICATA_HOME_NET=${HOME_NET}
INGESTION_IP=${INGESTION_IP}
ACCESS_IP=${ACCESS_IP}
ARKIME_ELASTICSEARCH_IP=${INGESTION_IP}
ARKIME_PASSWORD_SECRET=${ARKIME_PASSWORD_SECRET}
KIBANA_ENCRYPTION_KEY=${KIBANA_ENCRYPTION_KEY}
FLEET_SERVER_HOST=${INGESTION_IP}
LOCAL_KBN_URL=https://${ACCESS_IP}:5601
SELECTED_IP=${ACCESS_IP}
DEFAULT_TIMEOUT=300
ENV_EOF

chmod 600 "$SCRIPT_DIR/.env"
echo -e "  ${GREEN}✓${NC} Configuration written (.env)"

echo ""

# ==============================================
# Component selection
# ==============================================
echo -e "${YELLOW}[6/8] Component selection...${NC}"
echo ""
echo -e "  ┌─────────────────────────────────────────────────┐"
echo -e "  │            ${BOLD}DEPLOYMENT SUMMARY${NC}                    │"
echo -e "  ├─────────────────────────────────────────────────┤"
echo -e "  │  PCAP Capture:      ${BOLD}${PCAP_INTERFACE}${NC}"
echo -e "  │  Log Ingestion:     ${BOLD}${INGEST_INTERFACE}${NC} (${INGESTION_IP})"
echo -e "  │  Analyst Access:    ${BOLD}${ACCESS_INTERFACE}${NC} (${ACCESS_IP})"
echo -e "  │  HOME_NET:          ${BOLD}${HOME_NET}${NC}"
echo -e "  │  Elastic Stack:     ${BOLD}9.3.0${NC}"
echo -e "  │  RAM Available:     ${BOLD}${TOTAL_RAM_GB}GB${NC}"
echo -e "  └─────────────────────────────────────────────────┘"
echo ""

# Component toggle array (0=off, 1=on) — all on by default
declare -A COMPONENTS
COMPONENTS[elk]=1        # Elastic Stack — always required
COMPONENTS[thehive]=1
COMPONENTS[velociraptor]=1
COMPONENTS[suricata]=1
COMPONENTS[zeek]=1
COMPONENTS[arkime]=1
COMPONENTS[cyberchef]=1
COMPONENTS[mattermost]=1
COMPONENTS[rita]=1
COMPONENTS[portal]=1

# Display order and metadata
COMP_ORDER=(elk thehive velociraptor suricata zeek arkime cyberchef mattermost rita portal)
declare -A COMP_NAMES
COMP_NAMES[elk]="Elastic Stack (Elasticsearch + Kibana + Fleet)"
COMP_NAMES[thehive]="TheHive 4 (Incident Response)"
COMP_NAMES[velociraptor]="Velociraptor (DFIR & Endpoint Visibility)"
COMP_NAMES[suricata]="Suricata (Network IDS)"
COMP_NAMES[zeek]="Zeek (Network Analysis)"
COMP_NAMES[arkime]="Arkime (Full Packet Capture)"
COMP_NAMES[cyberchef]="CyberChef (Data Analysis)"
COMP_NAMES[mattermost]="Mattermost (Team Communication)"
COMP_NAMES[rita]="RITA (Network Traffic Analysis)"
COMP_NAMES[portal]="Tool Portal (Dashboard)"

# fuse.yml menu_choice for each component
declare -A COMP_MENU
COMP_MENU[elk]=2
COMP_MENU[thehive]=3
COMP_MENU[velociraptor]=4
COMP_MENU[zeek]=5
COMP_MENU[suricata]=6
COMP_MENU[arkime]=7
COMP_MENU[cyberchef]=8
COMP_MENU[mattermost]=9
COMP_MENU[rita]=10
COMP_MENU[portal]=11

show_components() {
    echo -e "  ${BOLD}Select components to deploy:${NC}"
    echo ""
    for i in "${!COMP_ORDER[@]}"; do
        local key="${COMP_ORDER[$i]}"
        local num=$((i + 1))
        if [[ "${COMPONENTS[$key]}" -eq 1 ]]; then
            local mark="${GREEN}[x]${NC}"
        else
            local mark="[ ]"
        fi
        echo -e "    ${mark}  ${num}. ${COMP_NAMES[$key]}"
    done
    echo ""
    echo -e "  ${BOLD}Commands:${NC}  Toggle: enter number (1-10)  |  ${GREEN}A${NC} = all on  |  ${RED}N${NC} = minimum (ELK only)  |  ${BOLD}D${NC} = deploy"
}

while true; do
    show_components
    echo ""
    read -p "  > " COMP_INPUT
    COMP_INPUT="${COMP_INPUT^^}"  # uppercase

    if [[ "$COMP_INPUT" == "D" ]]; then
        break
    elif [[ "$COMP_INPUT" == "A" ]]; then
        for key in "${COMP_ORDER[@]}"; do COMPONENTS[$key]=1; done
        echo ""
    elif [[ "$COMP_INPUT" == "N" ]]; then
        for key in "${COMP_ORDER[@]}"; do COMPONENTS[$key]=0; done
        echo ""
    elif [[ "$COMP_INPUT" =~ ^[0-9]+$ ]] && [[ "$COMP_INPUT" -ge 1 ]] && [[ "$COMP_INPUT" -le 10 ]]; then
        local_key="${COMP_ORDER[$((COMP_INPUT - 1))]}"
        if [[ "${COMPONENTS[$local_key]}" -eq 1 ]]; then
            COMPONENTS[$local_key]=0
            # Deselecting Zeek auto-deselects RITA (RITA needs Zeek logs)
            if [[ "$local_key" == "zeek" && "${COMPONENTS[rita]}" -eq 1 ]]; then
                COMPONENTS[rita]=0
                echo -e "  ${YELLOW}RITA automatically deselected (requires Zeek logs)${NC}"
            fi
        else
            COMPONENTS[$local_key]=1
            # Selecting RITA auto-selects Zeek (RITA needs Zeek logs)
            if [[ "$local_key" == "rita" && "${COMPONENTS[zeek]}" -eq 0 ]]; then
                COMPONENTS[zeek]=1
                echo -e "  ${YELLOW}Zeek automatically selected (required by RITA)${NC}"
            fi
        fi
        echo ""
    else
        echo -e "  ${RED}Invalid input. Enter a number (1-10), A, N, or D.${NC}"
        echo ""
    fi
done

# Build deployment list (in correct order)
DEPLOY_LIST=()
DEPLOY_NAMES=()
DEPLOYED_KEYS=()
for key in "${COMP_ORDER[@]}"; do
    if [[ "${COMPONENTS[$key]}" -eq 1 ]]; then
        DEPLOY_LIST+=("${COMP_MENU[$key]}")
        DEPLOY_NAMES+=("${COMP_NAMES[$key]}")
        DEPLOYED_KEYS+=("$key")
    fi
done

# Save component selection to .env
DEPLOYED_CSV=$(IFS=,; echo "${DEPLOYED_KEYS[*]}")
echo "DEPLOYED_COMPONENTS=${DEPLOYED_CSV}" >> "$SCRIPT_DIR/.env"

echo ""

# ==============================================
# Confirmation
# ==============================================
echo -e "${YELLOW}[7/8] Confirm deployment...${NC}"
echo ""
echo -e "  ${BOLD}Components to deploy (${#DEPLOY_LIST[@]}):${NC}"
for name in "${DEPLOY_NAMES[@]}"; do
    echo -e "    ${GREEN}+${NC} $name"
done
echo ""

read -p "  Deploy now? (y/n) [y]: " CONFIRM
CONFIRM="${CONFIRM:-y}"
if [[ ! "$CONFIRM" =~ ^[yY] ]]; then
    echo -e "${YELLOW}Deployment cancelled. Your configuration has been saved.${NC}"
    echo "To deploy later, run: sudo ansible-playbook fuse.yml --ask-vault-pass"
    rm -f "$SCRIPT_DIR/.vault_pass"
    exit 0
fi

echo ""

# ==============================================
# Deploy
# ==============================================
echo -e "${YELLOW}[8/8] Deploying Orochi Security Stack...${NC}"
echo -e "  Deploying ${#DEPLOY_LIST[@]} components. This will take a while. Grab a coffee."
echo ""

DEPLOY_EXIT=0
for i in "${!DEPLOY_LIST[@]}"; do
    CHOICE="${DEPLOY_LIST[$i]}"
    NAME="${DEPLOY_NAMES[$i]}"
    echo -e "${CYAN}  [$((i+1))/${#DEPLOY_LIST[@]}] Deploying: ${NAME}${NC}"

    set +e
    sudo ansible-playbook "$SCRIPT_DIR/fuse.yml" \
        -e menu_choice="$CHOICE" \
        --vault-password-file "$SCRIPT_DIR/.vault_pass"
    EXIT_CODE=$?
    set -e

    if [[ $EXIT_CODE -ne 0 ]]; then
        echo -e "${RED}  FAILED: ${NAME} (exit code $EXIT_CODE)${NC}"
        DEPLOY_EXIT=$EXIT_CODE
        echo ""
        read -p "  Continue deploying remaining components? (y/n) [n]: " CONTINUE
        CONTINUE="${CONTINUE:-n}"
        if [[ ! "$CONTINUE" =~ ^[yY] ]]; then
            break
        fi
    fi
done

# Clean up (trap also handles this on exit)
rm -f "$SCRIPT_DIR/.vault_pass"

echo ""

if [[ $DEPLOY_EXIT -eq 0 ]]; then
    echo -e "${GREEN}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                                                               ║"
    echo "  ║               DEPLOYMENT COMPLETE                             ║"
    echo "  ║                                                               ║"
    echo "  ╠═══════════════════════════════════════════════════════════════╣"
    echo "  ║                                                               ║"
    # Show URLs only for deployed components
    echo "  ║  Kibana:         https://${ACCESS_IP}:5601                    "
    [[ "${COMPONENTS[thehive]}" -eq 1 ]] && \
    echo "  ║  TheHive:        http://${ACCESS_IP}:9000                     "
    [[ "${COMPONENTS[velociraptor]}" -eq 1 ]] && \
    echo "  ║  Velociraptor:   https://${ACCESS_IP}:8889                    "
    [[ "${COMPONENTS[arkime]}" -eq 1 ]] && \
    echo "  ║  Arkime:         http://${ACCESS_IP}:8005                     "
    [[ "${COMPONENTS[cyberchef]}" -eq 1 ]] && \
    echo "  ║  CyberChef:      http://${ACCESS_IP}:8080                     "
    [[ "${COMPONENTS[mattermost]}" -eq 1 ]] && \
    echo "  ║  Mattermost:     http://${ACCESS_IP}:8065                     "
    [[ "${COMPONENTS[portal]}" -eq 1 ]] && \
    echo "  ║  Tool Portal:    http://${ACCESS_IP}                          "
    echo "  ║                                                               ║"
    echo "  ║  Fleet Server:   https://${INGESTION_IP}:8220                 "
    echo "  ║  (for agent enrollment from endpoints)                        ║"
    echo "  ║                                                               ║"
    [[ "${COMPONENTS[suricata]}" -eq 1 || "${COMPONENTS[zeek]}" -eq 1 || "${COMPONENTS[arkime]}" -eq 1 ]] && \
    echo "  ║  PCAP capturing on: ${PCAP_INTERFACE}                         "
    echo "  ║                                                               ║"
    echo "  ║  Username: admin / elastic                                    ║"
    echo "  ║  Password: (the one you set during setup)                     ║"
    echo "  ║                                                               ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo ""
    echo -e "  ${BOLD}To re-run or deploy additional components later:${NC}"
    echo "    sudo ansible-playbook fuse.yml --ask-vault-pass"
    echo ""
    echo -e "  ${BOLD}Save your vault password! You need it for future deployments.${NC}"
else
    echo -e "${RED}"
    echo "  ╔═══════════════════════════════════════════════════════════════╗"
    echo "  ║                  DEPLOYMENT FAILED                            ║"
    echo "  ╚═══════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
    echo "  Check the output above for errors."
    echo "  Your configuration has been saved. To retry:"
    echo "    sudo ansible-playbook fuse.yml --ask-vault-pass"
    exit 1
fi
