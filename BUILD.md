# OROCHI Security Stack — Build Guide

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Hardware Requirements](#hardware-requirements)
4. [Network Layout](#network-layout)
5. [Phase 0 — Management Box Setup (Once, Requires Internet)](#phase-0--management-box-setup)
6. [Phase 1 — Artefact Pre-Caching (Per Engagement, Requires Internet)](#phase-1--artefact-pre-caching)
7. [Phase 2 — On-Site Deployment](#phase-2--on-site-deployment)
8. [Deployment Menu Reference](#deployment-menu-reference)
9. [Recommended Deployment Order](#recommended-deployment-order)
10. [Service Access Reference](#service-access-reference)
11. [Verification Checklist](#verification-checklist)
12. [Teardown](#teardown)
13. [Troubleshooting](#troubleshooting)

---

## Overview

Orochi is a self-contained DFIR and network monitoring platform designed for rapid deployment in air-gapped or internet-restricted environments. The entire stack — Elastic SIEM, IDS/IPS, full packet capture, incident response, endpoint visibility, and timeline analysis — can be operational in under six hours from unpacking hardware.

All dependencies are pre-cached on a management laptop before going on-site. The deployment target (the Orochi node) never requires internet access.

---

## Architecture

```
┌─────────────────────────────────┐       ┌─────────────────────────────────┐
│       MANAGEMENT BOX            │       │          OROCHI NODE             │
│   (analyst laptop / NUC)        │       │   (bare metal Ubuntu Server)    │
│                                 │       │                                  │
│  ┌─────────────────────────┐   │ethernet│  Docker containers:              │
│  │ Local Docker Registry   │◄──┤ link  ├─► Elasticsearch (9200)           │
│  │ localhost:5000          │   │       │  Kibana (5601)                   │
│  └─────────────────────────┘   │       │  Fleet Server (8220)             │
│  ┌─────────────────────────┐   │       │  TheHive (9000)                  │
│  │ Nginx Artifact Server   │◄──┤       ├─► Velociraptor (8889)            │
│  │ localhost:8888          │   │       │  CyberChef (8080)                │
│  └─────────────────────────┘   │       │  Mattermost (8065)               │
│  ┌─────────────────────────┐   │       │  Timesketch (5000)               │
│  │ apt-cacher-ng           │◄──┤       ├─► Portal (80)                    │
│  │ localhost:3142          │   │       │                                  │
│  └─────────────────────────┘   │       │  Bare metal (systemd):           │
│                                 │       │  Suricata (IDS)                  │
│  Ansible control node           │       │  Zeek (NSM)                      │
│  Runs all playbooks             │       │  Arkime (PCAP, 8005)             │
└─────────────────────────────────┘       └─────────────────────────────────┘
```

**Management box** runs locally on the analyst's machine and serves all artefacts (Docker images, .deb packages, binary files) to the Orochi node over a direct ethernet link. It is the Ansible control node.

**Orochi node** is a bare metal Ubuntu Server that pulls everything from the management box and runs the full security stack. It requires no internet access during or after deployment.

---

## Hardware Requirements

### Management Box (Analyst Laptop / NUC)
| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu 24.04 LTS | Ubuntu 25.10 |
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB |
| Storage | 100 GB free | 200 GB free |
| NICs | 1 (WiFi OK) | 2 (WiFi + ethernet) |

### Orochi Node (Deployment Target)
| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu Server 25.10 | Ubuntu Server 25.10 |
| CPU | 8 cores | 16 cores |
| RAM | 32 GB | 64 GB |
| Storage | 500 GB (SSD preferred) | 2 TB NVMe |
| NICs | 2 | 3 (management + target + dedicated capture) |

> **NIC note:** The Orochi node is currently configured to use the target-network NIC (MAC `98:e7:43:22:5b:91`) as the capture interface until a dedicated USB capture NIC is procured. A third NIC for dedicated packet capture is planned; once installed, update `target_nic_mac` in `group_vars/all.yml` to the new NIC's MAC and set `capture_nic_present: true`.

---

## Network Layout

### Production (On-Site)
```
Management Box ──ethernet──► Orochi Node
 10.16.255.253                10.16.255.x (DHCP or static)
```

The management box uses a direct ethernet link to the orochi node. The production `mgmt_box_ip` is `10.16.255.253` — this is the address the orochi node uses to reach the artifact server and Docker registry.

### Development (Home Lab)
```
Management Box ──switch──► Orochi Node
 192.168.0.24               192.168.0.200
```

Override the management box IP at playbook run time with `-e mgmt_box_ip=192.168.0.24` for all dev runs.

### Orochi Node NICs

Interface kernel names are **discovered automatically at deploy time** from their MAC addresses — you never need to know or hardcode names like `enp89s0` or `enx98e743225b91`. The only values you need to keep correct are the MACs in `group_vars/all.yml`.

| MAC | Role | `group_vars` key |
|-----|------|-----------------|
| `88:ae:dd:0f:d9:0e` | Analyst/management network | `analyst_nic_mac` |
| `98:e7:43:22:5b:91` | Target network + current capture | `target_nic_mac` |
| TBC (USB NIC) | Dedicated packet capture (future) | `target_nic_mac` (replace) |
| `wlo1` (WiFi) | WireGuard bearer | `nic_wg_bearer` |

**If deploying on different hardware**, the only change required is updating those two MAC values in `group_vars/all.yml`.

---

## Phase 0 — Management Box Setup

> **Run once** when first setting up the management box. Requires internet. Takes ~10 minutes.

### 0.1 Install Ubuntu on the Management Box

Install Ubuntu 25.10 (or 24.04 LTS) on the management laptop/NUC. Create a user called `orochiman` with sudo access.

### 0.2 Copy the Orochi Project to the Management Box

**From the Windows dev machine** (if applicable):
```powershell
# Run from e:\Projects\Proj_OROCHI on the Windows machine
.\orochi\push_to_mgmt.ps1 -IP 192.168.0.24 -User orochiman
```

This copies the entire project to `~/orochi/` on the management box via SCP.

**Or clone directly on the management box:**
```bash
git clone <repo-url> ~/orochi
```

### 0.3 Bootstrap Ansible

On the management box:
```bash
sudo apt update && sudo apt install -y ansible python3-pip
```

Install required Ansible collections before running any playbooks:
```bash
ansible-galaxy collection install \
  community.docker \
  community.crypto \
  ansible.posix \
  community.general
```

### 0.4 Run the Management Box Setup Playbook

```bash
cd ~/orochi/orochi
ansible-playbook playbooks/setup_mgmt_box.yml
```

This playbook:
- Installs Docker CE, Docker Compose plugin
- Installs and configures `apt-cacher-ng` (port 3142) — caches `.deb` packages for the orochi node
- Starts a local Docker registry container (port 5000) — serves all Docker images offline
- Starts an nginx artifact server (port 8888) — serves binary files (Velociraptor, Arkime, RITA, etc.)
- Generates the SSH keypair `~/.ssh/orochi_id_ed25519` used to connect to the orochi node

### 0.5 Install the Orochi Node OS

Install Ubuntu Server 25.10 on the orochi node. During install:
- Create user `orochi` with sudo (no password sudo is fine)
- Enable OpenSSH server
- Do **not** install any additional packages

### 0.6 Distribute the SSH Key

From the management box, copy the generated public key to the orochi node:
```bash
ssh-copy-id -i ~/.ssh/orochi_id_ed25519 orochi@192.168.0.200
```

Verify the connection works:
```bash
ssh -i ~/.ssh/orochi_id_ed25519 orochi@192.168.0.200 "echo OK"
```

### 0.7 Verify the Inventory

Check `orochi/inventory/hosts.yml` matches your environment:
```yaml
all:
  children:
    orochi_node:
      hosts:
        orochi:
          ansible_host: 192.168.0.200   # ← orochi node IP
          ansible_user: orochi
          ansible_ssh_private_key_file: ~/.ssh/orochi_id_ed25519
```

Update `ansible_host` if your orochi node has a different IP.

---

## Phase 1 — Artefact Pre-Caching

> **Run before every engagement** (or when updating the stack versions). Requires internet. Takes 15–60 minutes depending on connection speed.

This step downloads everything the orochi node will need during deployment and stores it on the management box. Once complete, the management box can operate entirely offline.

```bash
cd ~/orochi/orochi

# Development (home lab):
ansible-playbook playbooks/prep_artefacts.yml -e mgmt_box_ip=192.168.0.24

# Production (on-site management box):
ansible-playbook playbooks/prep_artefacts.yml
```

### What Gets Downloaded

| Category | Contents |
|----------|----------|
| Docker images | Elasticsearch 9.x, Elasticsearch 7.x, Kibana, Elastic Agent, Cassandra, TheHive4, Mattermost, PostgreSQL, CyberChef, Nginx, Timesketch, Redis |
| Binary packages | Arkime `.deb`, Velociraptor binary (latest), RITA tarball |
| APT packages | Docker CE `.deb` tarball, Zeek `.deb` tarball, Suricata `.deb` tarball |
| Rules | Suricata rules (via `suricata-update`) |
| Keys | Zeek GPG signing key |

### What Gets Cached On-Disk

```
/opt/orochi/
├── artifacts/          ← served by nginx on port 8888
│   ├── arkime_5.8.3.deb
│   ├── velociraptor-linux-amd64
│   ├── rita-v5.1.1.tar.gz
│   ├── docker-debs.tar.gz
│   ├── zeek-debs.tar.gz
│   ├── suricata-debs.tar.gz
│   ├── suricata-rules.tar.gz
│   └── zeek-release.key
└── registry/           ← served by Docker registry on port 5000
    └── (Docker layer blobs for all images)
```

### Verifying the Cache

The playbook ends with a verification block. A successful run looks like:
```
ok: [localhost] => (item=elasticsearch/elasticsearch)
ok: [localhost] => (item=kibana/kibana)
...
ok: [localhost] => (item=arkime_5.8.3.deb)
ok: [localhost] => (item=velociraptor-linux-amd64)
...
- Management box is ready for offline deployment.
- You can now disconnect from the internet.
```

If any item shows `failed`, re-run the playbook — it is idempotent and will skip already-completed steps.

### Updating Artefacts

To update a specific tool version, edit `group_vars/all.yml`:
```yaml
arkime_version: "5.8.3"      # ← change here
rita_version: "v5.1.1"
stack_version: "9.3.4"
```
Then re-run `prep_artefacts.yml`. It will only download changed artefacts (Docker images with the same tag are skipped if already present).

---

## Phase 2 — On-Site Deployment

### 2.1 Physical Setup

1. Unpack and power on the orochi node
2. Connect the management box to the orochi node via ethernet (direct or via switch)
3. Connect the target-network ethernet to the orochi node's second NIC

### 2.2 Sync the Project (If Updated Since Last Run)

If you've made any changes on the Windows dev machine since the last sync:
```powershell
.\orochi\push_to_mgmt.ps1 -IP <mgmt-box-ip> -User orochiman
```

Or from the management box itself if pulling from git:
```bash
cd ~/orochi && git pull
```

### 2.3 Verify Management Box Services Are Running

On the management box:
```bash
# Registry should return {"repositories": [...]}
curl http://localhost:5000/v2/_catalog

# Artifact server should return an nginx directory listing
curl http://localhost:8888/

# apt-cacher-ng should be listening
ss -tlnp | grep 3142
```

If any service is down, restart it:
```bash
docker start orochi-registry
docker start orochi-artifacts
sudo systemctl start apt-cacher-ng
```

### 2.4 Verify the Orochi Node Is Reachable

```bash
cd ~/orochi/orochi
ansible orochi_node -m ping
```

Expected output: `orochi | SUCCESS => {"ping": "pong"}`

If this fails, check the SSH key and IP address in the inventory.

### 2.5 Override mgmt_box_ip for Dev/Lab

If deploying in the dev/home-lab environment (management box at `192.168.0.24` rather than the production `10.16.255.253`):
```bash
# Add -e mgmt_box_ip=192.168.0.24 to every fuse.yml command
ansible-playbook fuse.yml -e mgmt_box_ip=192.168.0.24
```

> **This flag is not needed on-site.** The production default (`10.16.255.253`) is correct when using the direct ethernet link.

### 2.6 Launch the Deployer

```bash
cd ~/orochi/orochi
ansible-playbook fuse.yml
```

You will be prompted for:
1. **Engagement password** — used for all service authentication (Elasticsearch, Kibana, Velociraptor, Arkime, Timesketch, Mattermost). Choose something strong and record it securely.

The interactive menu will then appear:
```
┌─────────────────────────────────────────┐
│           DEPLOYMENT OPTIONS            │
├─────────────────────────────────────────┤
│  1. Deploy Complete Stack               │
│  2. Deploy Elastic Stack                │
│  3. Deploy TheHive 4                    │
│  4. Deploy Velociraptor                 │
│  5. Deploy Zeek                         │
│  6. Deploy Suricata                     │
│  7. Deploy Arkime                       │
│  8. Deploy CyberChef                    │
│  9. Deploy Mattermost                   │
│ 10. Deploy RITA                         │
│ 11. Deploy Timesketch                   │
│ 12. Deploy Tool Portal                  │
│ 13. Show Status                         │
│ 14. Teardown All                        │
│  0. Exit                                │
└─────────────────────────────────────────┘
```

---

## Deployment Menu Reference

Each option below describes what it deploys, what it depends on, and how long it typically takes.

### Option 1 — Deploy Complete Stack

Deploys everything in the correct order. Use this for a full engagement build.

**Deploys:** Elasticsearch, Kibana, Fleet Server, TheHive 4 (+ Cassandra + ES7), Velociraptor, Suricata, Zeek, Arkime, CyberChef, Mattermost, RITA, Timesketch, Portal

**Dependencies:** All artefacts cached (Phase 1 complete)

**Estimated time:** 45–90 minutes

---

### Option 2 — Deploy Elastic Stack

Deploys Elasticsearch, Kibana, and Fleet Server only. This is the foundation for SIEM and endpoint telemetry.

**Estimated time:** 15–25 minutes

> Elastic Stack must be deployed before Arkime, as Arkime uses Elasticsearch for session metadata storage.

---

### Option 3 — Deploy TheHive 4

Deploys TheHive 4 incident response platform with its own Elasticsearch 7.x backend and Cassandra database.

**Estimated time:** 10–15 minutes (Cassandra startup is slow — expect a 45-second wait)

**Default credentials after install:** `admin@thehive.local` / `secret`
**Change the default password immediately** after first login.

---

### Option 4 — Deploy Velociraptor

Deploys Velociraptor for DFIR and endpoint visibility. Builds a local container image from the pre-cached binary and a minimal Debian base image.

**Estimated time:** 5–10 minutes

**Credentials:** `admin` / *engagement password*

After deployment, collect endpoints by deploying the Velociraptor agent using the client config at `/opt/orochi/velociraptor/client.config.yaml`.

---

### Option 5 — Deploy Zeek

Installs Zeek Network Security Monitor from pre-cached packages. Zeek runs as a systemd service and logs to `/var/log/zeek/current/`.

**Estimated time:** 5 minutes

Zeek monitors the interface defined by `capture_interface` in `group_vars/all.yml` (currently the target NIC: `enx98e743225b91`).

---

### Option 6 — Deploy Suricata

Installs Suricata IDS from pre-cached packages and pre-downloaded rules. Runs as a systemd service.

**Logs:** `/var/log/suricata/eve.json` (JSON), `/var/log/suricata/fast.log`

**Estimated time:** 5 minutes

---

### Option 7 — Deploy Arkime

Installs Arkime (full packet capture) on bare metal. Requires Elasticsearch to already be running (deploy option 2 first, or use option 1).

**Estimated time:** 10 minutes

> Arkime's GeoIP databases require internet for enrichment. Without them, capture still works but sessions won't have country/ASN data. The deployment sets `failed_when: false` for the GeoIP update so offline deployment succeeds.

**Credentials:** `admin` / *engagement password*

---

### Option 8 — Deploy CyberChef

Deploys CyberChef as a Docker container. No authentication required. Fully offline once deployed.

**Estimated time:** 2 minutes

---

### Option 9 — Deploy Mattermost

Deploys Mattermost team chat with a dedicated PostgreSQL backend.

**Estimated time:** 5 minutes

Complete the initial setup wizard in the browser on first access. Use the engagement password when creating the admin account.

---

### Option 10 — Deploy RITA

Installs RITA (Real Intelligence Threat Analytics) for beaconing and C2 detection analysis. Runs RITA's own Ansible-based installer which sets up MongoDB.

**Estimated time:** 10–20 minutes

> **Important:** RITA v5's installer downloads MongoDB from the official MongoDB apt repository. This **requires internet access** unless the apt-cacher-ng has been pre-warmed with MongoDB packages. Plan accordingly — either deploy RITA before going offline, or warm the cache manually.

---

### Option 11 — Deploy Timesketch

Deploys Timesketch timeline analysis platform. Uses the shared Elasticsearch 7.x instance (starts it automatically if not already running), with its own dedicated PostgreSQL and Redis containers.

**Estimated time:** 10–15 minutes

**Credentials:** `admin` / *engagement password*

---

### Option 12 — Deploy Tool Portal

Deploys the Orochi landing page — a single nginx-served HTML dashboard with links to all running services. Access it at `http://<orochi-node-ip>/`.

**Estimated time:** 2 minutes

> The portal loads service tool logos from external URLs. In an air-gapped environment the logo images will be broken, but all navigation links work correctly.

---

### Option 13 — Show Status

Runs `docker ps` on the orochi node and displays all running containers with their status and port mappings. Does not deploy anything.

---

### Option 14 — Teardown All

Stops and removes all Orochi containers and bare metal services (Suricata, Zeek, Arkime). Does **not** delete data directories under `/opt/orochi/`.

> You will be prompted to type `YES` to confirm. This is irreversible for running services.

---

## Recommended Deployment Order

For a full engagement build, deploy in this sequence if doing it manually (options 2–12) rather than option 1:

```
2 → Elastic Stack        (foundation — everything depends on this for logging)
3 → TheHive              (separate ES7 + Cassandra, no Elastic Stack dependency)
4 → Velociraptor         (endpoint collection)
5 → Zeek                 (start capturing immediately)
6 → Suricata             (start alerting immediately)
7 → Arkime               (needs Elastic Stack running first)
8 → CyberChef            (standalone, any time)
9 → Mattermost           (comms, any time)
11 → Timesketch          (timeline analysis, can wait)
10 → RITA                (requires internet — do before going offline or skip)
12 → Portal              (last — links to everything else)
```

**For the fastest time to visibility**, prioritise: `6 (Suricata) → 5 (Zeek) → 2 (Elastic Stack) → 7 (Arkime)`.

---

## Service Access Reference

Replace `<node-ip>` with the orochi node's IP address (e.g. `192.168.0.200` in dev).

| Service | URL | Protocol | Username | Password |
|---------|-----|----------|----------|----------|
| **Kibana** | `https://<node-ip>:5601` | HTTPS | `elastic` | engagement password |
| **Fleet Server** | `https://<node-ip>:8220` | HTTPS | API use only | — |
| **TheHive** | `http://<node-ip>:9000` | HTTP | `admin@thehive.local` | `secret` ⚠️ |
| **Velociraptor** | `https://<node-ip>:8889` | HTTPS | `admin` | engagement password |
| **Arkime** | `http://<node-ip>:8005` | HTTP | `admin` | engagement password |
| **CyberChef** | `http://<node-ip>:8080` | HTTP | — | — |
| **Mattermost** | `http://<node-ip>:8065` | HTTP | Setup wizard | — |
| **Timesketch** | `http://<node-ip>:5000` | HTTP | `admin` | engagement password |
| **Portal** | `http://<node-ip>:80` | HTTP | — | — |

> ⚠️ **TheHive default password is `secret`**. Change it immediately after first login via the admin panel.

### Log Locations (on the Orochi Node)

| Service | Log Path |
|---------|----------|
| Suricata alerts | `/var/log/suricata/eve.json` |
| Suricata fast log | `/var/log/suricata/fast.log` |
| Zeek logs | `/opt/zeek/logs/current/` |
| Arkime PCAP | `/opt/orochi/arkime/raw/` |
| Arkime logs | `/opt/arkime/logs/` |
| Docker service logs | `docker logs <container-name>` |

---

## Verification Checklist

Run these checks after a full deployment to confirm everything is healthy.

### From the Orochi Node

```bash
# Docker containers
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

# Systemd services
systemctl status suricata zeek arkimecapture arkimeviewer

# Suricata is producing alerts
tail -f /var/log/suricata/fast.log

# Zeek is logging connections
ls /opt/zeek/logs/current/

# Arkime is capturing
ls /opt/orochi/arkime/raw/
```

### From the Management Box

```bash
# Elasticsearch cluster health
curl -k -u elastic:<engagement-password> https://<node-ip>:9200/_cluster/health?pretty

# Kibana status
curl -k https://<node-ip>:5601/api/status | python3 -m json.tool | grep '"overall"' -A3

# Fleet Server health
curl -k https://<node-ip>:8220/api/status

# TheHive API
curl http://<node-ip>:9000/api/status

# Velociraptor GUI responds
curl -k -o /dev/null -w "%{http_code}" https://<node-ip>:8889/

# Arkime viewer responds
curl -o /dev/null -w "%{http_code}" http://<node-ip>:8005/
```

### Option 13 — Quick Status

The fastest check: run `fuse.yml` again and choose option `13`. It runs `docker ps` on the orochi node and prints a live status table.

---

## Teardown

### Full Teardown (Option 14)

```bash
ansible-playbook fuse.yml
# Choose 14, type YES when prompted
```

Stops all containers and bare metal services. Data under `/opt/orochi/` is **preserved**.

### Remove Data (Complete Wipe)

After running option 14:
```bash
# On the orochi node
sudo rm -rf /opt/orochi/
sudo rm -rf /var/log/suricata/
sudo rm -rf /opt/zeek/
sudo rm -rf /opt/arkime/
sudo apt remove --purge suricata zeek
```

### Teardown Individual Services

To remove a specific container without touching others:
```bash
# On the orochi node
docker stop <container-name> && docker rm <container-name>

# To also remove its data directory:
sudo rm -rf /opt/orochi/<service-name>/
```

---

## Troubleshooting

### Management Box Artifact Server Not Reachable from Orochi Node

```
fatal: [orochi]: FAILED! => Management box artifact server not reachable
```

**Check:**
```bash
# From orochi node — can it reach the management box?
curl http://10.16.255.253:8888/velociraptor-linux-amd64 -o /dev/null -w "%{http_code}"

# Is nginx container running on management box?
docker ps | grep orochi-artifacts

# Restart if needed:
docker start orochi-artifacts
```

**Root cause is usually:** direct ethernet link not up, or management box nginx container stopped after a reboot.

---

### Docker Registry Not Reachable (image pull errors)

```
Error response from daemon: Get "https://10.16.255.253:5000/v2/": ...
```

**Check:**
```bash
# Registry running?
docker ps | grep orochi-registry

# Can the orochi node reach it?
curl http://10.16.255.253:5000/v2/_catalog

# Is daemon.json configured on the orochi node?
cat /etc/docker/daemon.json
# Expected: {"insecure-registries": ["10.16.255.253:5000"]}
```

If `daemon.json` is missing, re-run bootstrap_node (it runs automatically as a pre-task in `fuse.yml`) then restart Docker on the orochi node:
```bash
sudo systemctl restart docker
```

---

### Elasticsearch Won't Start

```
docker logs elasticsearch
# ERROR: max virtual memory areas vm.max_map_count [65530] is too low
```

**Fix:**
```bash
# On the orochi node
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee -a /etc/sysctl.conf
```

The `common` role sets this automatically, but running Elasticsearch standalone before `common` will hit this.

---

### Suricata Fails to Start

```bash
systemctl status suricata
# ... Interface enx98e743225b91 does not exist
```

**Cause:** The capture interface name in `group_vars/all.yml` doesn't match the actual interface on this system.

**Fix:**
```bash
# On the orochi node — find the interface with the target NIC MAC
ip link | grep -B1 '98:e7:43:22:5b:91'

# Update group_vars/all.yml with the correct interface name
capture_interface: "<correct-name>"

# Re-run option 6 in fuse.yml
```

---

### Zeek Not Logging

```bash
/opt/zeek/bin/zeekctl status
# zeek crashed / not running
```

**Check and restart:**
```bash
/opt/zeek/bin/zeekctl check
/opt/zeek/bin/zeekctl deploy
```

Common cause is the capture interface not being up or in promiscuous mode when Zeek started.

---

### TheHive Not Starting (Cassandra connection refused)

TheHive 4 requires Cassandra to be fully initialised before it can connect. The deployment adds a 45-second pause but on slow hardware Cassandra may take longer.

**Fix:**
```bash
docker logs cassandra | tail -20
# Wait until you see "Created default superuser role 'cassandra'"

# Then restart TheHive:
docker restart thehive
```

---

### Velociraptor Admin User Already Exists

```
user add: Error: user already exists
```

This is expected and harmless on re-runs. The role's `failed_when` condition handles this — it is not a failure.

---

### RITA Fails Offline (MongoDB download fails)

```
TASK [Run RITA pre-checks playbook] FAILED
# E: Failed to fetch https://repo.mongodb.org/...
```

RITA's installer downloads MongoDB from the internet. Options:
1. Deploy RITA before going offline
2. Pre-warm apt-cacher-ng with MongoDB packages (add MongoDB repo to management box, run `apt-get install -y --download-only mongodb-org` to populate the cache, then the orochi node will pull it through the proxy)
3. Skip RITA for this engagement

---

### Timesketch Database Init Fails

```
TASK [Initialise Timesketch database] FAILED
# could not connect to server: Connection refused
```

PostgreSQL or Elasticsearch-hive isn't ready yet. The role pauses 15 seconds for PostgreSQL but on slow hardware it may need more.

**Fix:**
```bash
docker logs postgres-timesketch | tail -10
# Wait for: database system is ready to accept connections

docker exec timesketch tsctl db init
docker exec timesketch tsctl db upgrade
docker exec timesketch tsctl create-user --name admin --password <password> --admin
```

---

### Can't SSH to Orochi Node

```
ansible orochi_node -m ping
# UNREACHABLE! => SSH Error
```

1. Check the IP in `inventory/hosts.yml` matches the orochi node
2. Verify the SSH key exists: `ls ~/.ssh/orochi_id_ed25519`
3. Re-copy the public key: `ssh-copy-id -i ~/.ssh/orochi_id_ed25519 orochi@<node-ip>`
4. Check the orochi node has sshd running: boot into it directly and run `sudo systemctl start ssh`

---

### Re-Running fuse.yml Is Safe

All roles are idempotent. Running `fuse.yml` again for an already-deployed service will:
- Skip steps that are already complete
- Re-apply any configuration that has changed
- Not delete or recreate containers unless configuration changed

This means you can safely add tools one at a time by re-running and choosing the relevant option.
