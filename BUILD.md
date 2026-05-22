# OROCHI Security Stack — Build and Operations Guide

## Table of Contents

1. [How It Works](#how-it-works)
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
12. [Teardown and Reset](#teardown-and-reset)
13. [Adapting for Different Hardware](#adapting-for-different-hardware)
14. [Updating Tool Versions](#updating-tool-versions)
15. [Troubleshooting](#troubleshooting)

---

## How It Works

OROCHI is a self-contained DFIR and network monitoring platform designed for rapid deployment in air-gapped or internet-restricted environments. The full security stack — Elastic SIEM, IDS/IPS, full packet capture, incident response, endpoint visibility, and timeline analysis — can be operational in under six hours from unpacking hardware.

### The Core Problem It Solves

Deploying security tools on a network you're monitoring is inherently constrained: you cannot download packages from the internet (the network is compromised or isolated), you may not have DNS, and pulling images from Docker Hub is out of the question. OROCHI solves this by pre-staging everything on a management laptop before arriving on-site.

### The Two-Box Model

OROCHI uses exactly two machines:

**Management box** (your laptop) — the Ansible control node. Before going on-site, it downloads every Docker image, every `.deb` package, every binary, and every Suricata rule file. On-site, it runs three server processes that the orochi node uses as its sole source for all software:

- **Docker registry** (port 5000) — serves all Docker images locally. Every image the orochi node pulls comes from here, not the internet.
- **Nginx artifact server** (port 8888) — serves binary files: Velociraptor executable, RITA tarball, Suricata and Zeek `.deb` tarballs, Zeek GPG key, Suricata rules archive.
- **apt-cacher-ng** (port 3142) — transparent apt proxy. When the orochi node runs `apt-get install`, it routes through the management box cache instead of hitting the internet.

**Orochi node** (the deployment target) — a bare-metal Ubuntu Server that pulls everything from the management box and runs the full security stack. It requires zero internet access during or after deployment.

### How Ansible Drives Everything

`fuse.yml` is the single entry point for all deployments. It:

1. Runs `bootstrap_node` as a pre-task (always, before any menu choice) — this resolves the management box IP (prompting on first run, reading `.env` on re-runs), configures the orochi node to use the management box for apt, and verifies the management box is reachable.
2. Prompts for a single engagement password that flows into every service's authentication.
3. Presents an interactive menu and runs the selected role chain.

Every role is idempotent — re-running the same option is safe and will skip already-complete steps while re-applying any changed configuration.

### Interface Selection

The capture interface (used by Suricata, Zeek, and Arkime) is selected interactively by the `environment` role at the start of each deployment. It lists all non-loopback, non-Docker interfaces on the orochi node and prompts you to pick the one facing the monitored network. The selection is saved to `.env` on the management box and reused on subsequent runs.

### The Single Password Pattern

One password is entered at `fuse.yml` startup and flows into every service:

- Elasticsearch superuser (`elastic` / *password*)
- Kibana system user
- Fleet Server enrolment token
- Velociraptor admin
- Arkime admin + HMAC secret
- Timesketch admin
- Mattermost (set during first-use wizard)

This means you only have one credential to manage per engagement. **TheHive is the exception** — it uses its own hardcoded default (`admin@thehive.local` / `secret`) which you must change manually after first login.

---

## Architecture

```
┌─────────────────────────────────┐       ┌─────────────────────────────────┐
│       MANAGEMENT BOX            │       │          OROCHI NODE             │
│   (analyst laptop / NUC)        │       │   (bare metal Ubuntu Server)    │
│                                 │       │                                  │
│  ┌─────────────────────────┐   │ethernet│  Docker containers:              │
│  │ Local Docker Registry   │◄──┤ link  ├─► Elasticsearch 9.x (9200)      │
│  │ :5000                   │   │       │  Kibana (5601)                   │
│  └─────────────────────────┘   │       │  Fleet Server (8220)             │
│  ┌─────────────────────────┐   │       │  Elasticsearch 7.x (TheHive)     │
│  │ Nginx Artifact Server   │◄──┤       ├─► Cassandra (TheHive backend)    │
│  │ :8888                   │   │       │  TheHive 4 (9000)                │
│  └─────────────────────────┘   │       │  Velociraptor (8889/8000/8001)   │
│  ┌─────────────────────────┐   │       │  CyberChef (8080)                │
│  │ apt-cacher-ng           │◄──┤       ├─► Mattermost (8065)              │
│  │ :3142                   │   │       │  PostgreSQL (Mattermost)         │
│  └─────────────────────────┘   │       │  Timesketch (5000)               │
│                                 │       │  Redis (Timesketch)              │
│  Ansible control node           │       │  PostgreSQL (Timesketch)         │
│  Runs all playbooks against     │       │  Arkime capture + viewer (8005)  │
│  the orochi node via SSH        │       │  nginx-portal (80)               │
└─────────────────────────────────┘       │                                  │
                                          │  Bare metal (systemd):           │
                                          │  Suricata IDS                    │
                                          │  Zeek NSM                        │
                                          │                                  │
                                          │  Docker compose (/opt/rita):     │
                                          │  RITA + ClickHouse + syslog-ng   │
                                          └─────────────────────────────────┘
```

### Docker Network

All containers share a single bridge network named `orochi-network`. This allows containers to reach each other by container name (e.g. Kibana reaches Elasticsearch as `elasticsearch:9200`). The network is created by the `common` role before any containers are started.

> **Arkime exception:** Arkime's capture and viewer containers run with `--network host` rather than on `orochi-network`. Host networking is required so the capture container can see all physical interfaces on the node in promiscuous mode. Arkime reaches Elasticsearch at `localhost:9200`.

### Data Persistence

All persistent data lives under `/opt/orochi/` on the orochi node:

```
/opt/orochi/
├── certs/              ← TLS certificates (CA, node cert, node key)
├── elasticsearch/      ← ES 9.x data and config
├── kibana/             ← Kibana config and session store
├── fleet/              ← Fleet Server data
├── thehive/            ← TheHive data
├── thehive-es/         ← ES 7.x data for TheHive
├── cassandra/          ← Cassandra data for TheHive
├── velociraptor/       ← Velociraptor configs, client keys
├── arkime/             ← Arkime PCAP and config
├── mattermost/         ← Mattermost data
├── postgres/           ← PostgreSQL data (Mattermost)
├── postgres-timesketch/← PostgreSQL data (Timesketch)
├── timesketch/         ← Timesketch config
├── rita/               ← RITA install and databases
├── portal/             ← nginx portal HTML
└── logs/               ← Shared log directory
```

Running option 14 (Teardown) stops and removes containers but does **not** delete these directories. Data survives a teardown and redeploy.

---

## Hardware Requirements

### Management Box (Analyst Laptop)

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu 24.04 LTS | Ubuntu 25.10 |
| CPU | 4 cores | 8 cores |
| RAM | 8 GB | 16 GB |
| Storage | 100 GB free | 200 GB free |
| NICs | 1 (WiFi OK) | 2 (WiFi + ethernet) |

The management box needs sufficient disk to cache all Docker image layers (approximately 40–60 GB) plus the binary artefacts (~2 GB). Docker image layers are deduplicated — the cache is smaller than the sum of individual image sizes.

### Orochi Node (Deployment Target)

| Component | Minimum | Recommended |
|-----------|---------|-------------|
| OS | Ubuntu Server 25.10 | Ubuntu Server 25.10 |
| CPU | 8 cores | 16 cores |
| RAM | 32 GB | 64 GB |
| Storage | 500 GB SSD | 2 TB NVMe |
| NICs | 2 | 3 (management + target network + dedicated capture) |

**RAM breakdown at full deployment (approximate):**
- Elasticsearch 9.x: 4 GB container limit (2 GB heap)
- Elasticsearch 7.x (TheHive): 1 GB container limit
- Kibana: 2 GB
- Cassandra: 2 GB
- TheHive: 2 GB
- Velociraptor: ~512 MB
- Timesketch: 2 GB
- Mattermost + PostgreSQL: ~1.5 GB
- Suricata (bare metal): ~1–2 GB (scales with rule count)
- Zeek (bare metal): ~512 MB
- Arkime capture + viewer (Docker): ~1 GB
- **Total:** approximately 20–22 GB active use. 32 GB is the practical minimum; 64 GB is comfortable.

**NIC roles:**

| NIC | Purpose |
|-----|---------|
| Analyst NIC | Management traffic — SSH from management box, Docker pulls, apt |
| Target NIC | Connected to the target network. Currently also used as the packet capture interface. |
| Future USB NIC | Dedicated packet capture (promiscuous mode). |

---

## Network Layout

### Production (On-Site)

```
Management Box ──ethernet──► Orochi Node
 10.16.255.253                10.16.255.x (DHCP or static)
```

The management box uses a dedicated ethernet port at `10.16.255.253` connected directly to the orochi node's analyst NIC.

### Management Box IP Resolution

Because the management box IP can vary (DHCP, Tailscale, different ethernet adapters), `bootstrap_node` resolves it dynamically at the start of every `fuse.yml` run:

1. If `MGMT_BOX_IP` exists in `{{ playbook_dir }}/.env`, it is used automatically — no prompt.
2. Otherwise, `bootstrap_node` lists all non-loopback interfaces on the **management box** (the control node) and asks you to select the one the orochi node can reach. The chosen IP is saved to `.env` and reused on the next run.

To override for a specific run (dev or testing):
```bash
ansible-playbook fuse.yml -e mgmt_box_ip=100.99.102.28
```

The `-e` override takes precedence over `.env` for that run only. `.env` is not modified.

For `prep_artefacts.yml`, which runs on localhost, override the same way:
```bash
ansible-playbook playbooks/prep_artefacts.yml -e mgmt_box_ip=100.99.102.28
```

### Ports the Orochi Node Needs to Reach on the Management Box

| Port | Service | Used for |
|------|---------|----------|
| 3142 | apt-cacher-ng | All `apt-get install` calls on the orochi node |
| 5000 | Docker registry | All Docker image pulls |
| 8888 | nginx artifact server | Binary files (.deb tarballs, Velociraptor, RITA, rules) |

If any of these three are unreachable, deployment will fail. `bootstrap_node` checks port 8888 at the start of every fuse.yml run.

---

## Phase 0 — Management Box Setup

> **Run once** when first setting up the management box. Requires internet. Takes approximately 10 minutes.

### 0.1 Install Ubuntu on the Management Box

Install Ubuntu 25.10 (or 24.04 LTS) on the management laptop. During install:
- Create user `orochiman` with sudo access
- Enable OpenSSH server (optional — you'll be running everything locally)
- Do not install any additional packages beyond the base system

### 0.2 Copy the Orochi Project to the Management Box

**From the Windows development machine:**
```powershell
# Run from E:\Projects\Proj_OROCHI on the Windows machine
.\orochi\push_to_mgmt.ps1 -IP 100.99.102.28 -User orochiman
```

This copies the entire project to `~/orochi/` on the management box via SCP.

**Or directly on the management box:**
```bash
git clone <repo-url> ~/orochi
```

### 0.3 Bootstrap Ansible

The management box needs Ansible before it can run any playbooks. Install it:

```bash
sudo apt update && sudo apt install -y ansible python3-pip
```

Then install the required Ansible collections. These must be installed **before** running `setup_mgmt_box.yml` because the playbook itself uses `community.docker` to start the registry:

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

This playbook installs and configures everything the management box needs to serve artefacts to the orochi node:

| Component | What it does |
|-----------|-------------|
| Docker CE | Required to run the registry and nginx containers |
| apt-cacher-ng | Transparent apt proxy on port 3142. The orochi node routes all apt traffic through this. |
| Docker registry container | Runs `registry:2` on port 5000. Stores Docker image layers under `/opt/orochi/registry/`. |
| nginx artifact container | Runs `nginx:alpine` on port 8888. Serves files from `/opt/orochi/artifacts/` as a plain directory listing. |
| Ansible collections | Installs community.docker, community.crypto, ansible.posix, community.general |
| SSH keypair | Generates `~/.ssh/orochi_id_ed25519` — the key used to SSH to the orochi node |

> **Note:** The playbook also installs Terraform and creates a Terraform plugin cache directory. This is vestigial (Terraform was used in an earlier architecture for VM provisioning). It is harmless — ignore it.

Both the registry and nginx containers are started with `restart_policy: unless-stopped`, so they survive management box reboots.

### 0.5 Install the Orochi Node OS

Install **Ubuntu Server 25.10** on the orochi node. During install:
- Create user `orochi` with sudo access (passwordless sudo is acceptable: `orochi ALL=(ALL) NOPASSWD:ALL`)
- Enable OpenSSH server
- Do **not** install any additional packages — Docker, Suricata, Zeek etc. are all installed by Ansible

### 0.6 Distribute the SSH Key

From the management box, copy the generated public key to the orochi node:

```bash
ssh-copy-id -i ~/.ssh/orochi_id_ed25519 orochi@192.168.0.200
```

Verify the key-based connection works before proceeding:

```bash
ssh -i ~/.ssh/orochi_id_ed25519 orochi@192.168.0.200 "echo OK"
```

You should see `OK` with no password prompt.

### 0.7 Update the Ansible Inventory

Check `orochi/inventory/hosts.yml`:

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

Change `ansible_host` if your orochi node has a different IP.

### 0.8 Verify the Connection

```bash
cd ~/orochi/orochi
ansible orochi_node -m ping
```

Expected: `orochi | SUCCESS => {"ping": "pong"}`

If this fails, see [Can't SSH to Orochi Node](#cant-ssh-to-orochi-node) in Troubleshooting.

---

## Phase 1 — Artefact Pre-Caching

> **Run before every engagement** (or when updating tool versions). Requires internet. Takes 15–60 minutes depending on connection speed.

This step downloads everything the orochi node will need during deployment and stores it all on the management box. Once complete, the management box is fully offline-capable.

```bash
cd ~/orochi/orochi

# Development (home lab):
ansible-playbook playbooks/prep_artefacts.yml -e mgmt_box_ip=100.99.102.28

# Production (management box at 10.16.255.253):
ansible-playbook playbooks/prep_artefacts.yml
```

### What prep_artefacts.yml Does

The playbook runs entirely on `localhost` (the management box). It:

1. **Starts the local Docker registry** at `localhost:5000` (or confirms it's running).
2. **Pulls Docker images** from their upstream sources (docker.elastic.co, Docker Hub, GitHub Container Registry, Google Artifact Registry) and pushes them all into the local registry under the paths `group_vars/all.yml` references. The orochi node never contacts any upstream registry — it only talks to the management box registry.
3. **Downloads binary artefacts** (RITA tarball, Zeek signing key) via direct URL.
4. **Resolves the latest Velociraptor release** from the GitHub API and downloads the `linux-amd64` binary.
5. **Downloads Docker CE `.deb` packages** using `apt-get --download-only --reinstall` (the `--reinstall` flag is required — without it, apt skips packages that are already installed at the current version, and nothing gets downloaded).
6. **Downloads Zeek `.deb` packages** the same way, after adding the Zeek OpenSUSE apt repository.
7. **Downloads Suricata `.deb` packages** from standard Ubuntu repos.
8. **Downloads Suricata rules** by spinning up a temporary Ubuntu container, running `suricata-update` inside it, and tarring the resulting rule files to `/opt/orochi/artifacts/suricata-rules.tar.gz`. The orochi node extracts this tarball during deployment — it never runs suricata-update itself.
9. **Warms apt-cacher-ng** by temporarily pointing the management box's own apt at the local proxy and downloading standard packages (iptables, wireguard, Python libraries, etc.).
10. **Starts the nginx artifact server** at `localhost:8888` serving `/opt/orochi/artifacts/`.
11. **Verifies** that all expected registry images and artifact files are present. Fails loudly if anything is missing.

### What Gets Cached On-Disk

```
/opt/orochi/
├── artifacts/                      ← served by nginx on port 8888
│   ├── docker-debs/                ← Docker CE .deb files (directory)
│   ├── docker-debs.tar.gz          ← tarball of above
│   ├── zeek-debs/                  ← Zeek .deb files (directory)
│   ├── zeek-debs.tar.gz            ← tarball of above
│   ├── suricata-debs/              ← Suricata .deb files (directory)
│   ├── suricata-debs.tar.gz        ← tarball of above
│   ├── suricata-rules.tar.gz       ← ET Open rules from suricata-update
│   ├── velociraptor-linux-amd64
│   ├── rita-v5.1.1.tar.gz          ← RITA installer (docker-compose stack + config)
│   └── zeek-release.key
└── registry/                       ← Docker layer blobs
    ├── docker/registry/v2/...      ← all tool images
    ├── ...arkime/...               ← Arkime capture + viewer image (arkime/arkime:v6-latest)
    └── ...rita/...                 ← RITA + ClickHouse + syslog-ng images
```

> **RITA images** are stored in the registry under the `rita/` namespace (e.g. `<mgmt-ip>:5000/rita/rita:v5.1.1`, `<mgmt-ip>:5000/rita/clickhouse-server:24.x`). They are discovered automatically from the RITA installer's `docker-compose.yml` during `prep_artefacts.yml`.

> **Arkime image** is pulled from `ghcr.io/arkime/arkime/arkime:v6-latest` (GitHub Container Registry) and stored locally as `<mgmt-ip>:5000/arkime/arkime:v6-latest`. A single image is used for both the capture and viewer containers — the behaviour is selected by passing `capture` or `viewer` as the container command.

### Verifying the Cache

A successful run ends with:
```
- All artefacts downloaded and cached.
- Local registry:    localhost:5000
- Artifact server:   http://localhost:8888
- Apt proxy:         localhost:3142
- Management box is ready for offline deployment.
- You can now disconnect from the internet.
```

To manually verify the registry contents after caching:
```bash
curl http://localhost:5000/v2/_catalog
```

To verify a specific artifact file is present and readable:
```bash
curl -o /dev/null -w "%{http_code} %{size_download}\n" http://localhost:8888/velociraptor-linux-amd64
# Expect: 200 <size-in-bytes>
```

### Re-Running Is Safe

`prep_artefacts.yml` is largely idempotent. Docker images that are already in the local registry are pulled again from upstream (they are re-tagged and re-pushed, but Docker layer deduplication means this is fast for unchanged images). If a download fails partway, re-run the playbook — it will skip completed steps and retry failed ones.

### Updating Artefact Versions

Edit `group_vars/all.yml` to change any version pin:

```yaml
stack_version: "9.3.4"          # Elasticsearch + Kibana + Fleet Agent
elasticsearch_hive_version: "7.17.9"   # ES for TheHive (must stay 7.x)
thehive_version: "4.1.19"
cassandra_version: "4.0"
arkime_version: "v6-latest"
rita_version: "v5.1.1"
postgres_version: "15-alpine"
redis_version: "7-alpine"
```

Then re-run `prep_artefacts.yml`. Only images/files with changed tags will require new downloads.

> **Important:** When you change `stack_version`, the orochi node will also prompt you to enter the new version at deployment time via the `environment` role's interactive prompt. Enter the version that matches what you actually downloaded in prep_artefacts — if they don't match, image pulls will fail with 404.

---

## Phase 2 — On-Site Deployment

### 2.1 Physical Setup

1. Unpack and power on the orochi node
2. Connect the management box ethernet port to the orochi node's analyst NIC (direct cable or via switch)
3. Connect the target-network ethernet to the orochi node's target NIC
4. Confirm you can SSH to the orochi node from the management box

### 2.2 Verify Management Box Services Are Running

The registry and nginx containers start automatically after reboots (`restart_policy: unless-stopped`), but verify before starting a deployment:

```bash
# Registry — should return JSON with a list of repositories
curl http://localhost:5000/v2/_catalog

# Artifact server — should return an nginx HTML directory listing
curl -o /dev/null -w "%{http_code}\n" http://localhost:8888/

# apt-cacher-ng — should be listening on 3142
ss -tlnp | grep 3142
```

If any service is down:
```bash
docker start orochi-registry       # restart registry
docker start orochi-artifacts      # restart nginx
sudo systemctl start apt-cacher-ng
```

### 2.3 Sync the Project (If Updated Since Last Cache Run)

If you've made changes on the Windows development machine:
```powershell
.\orochi\push_to_mgmt.ps1 -IP <mgmt-box-ip> -User orochiman
```

Or pull from git on the management box:
```bash
cd ~/orochi && git pull
```

### 2.4 Verify the Orochi Node Is Reachable

```bash
cd ~/orochi/orochi
ansible orochi_node -m ping
```

Expected: `orochi | SUCCESS => {"ping": "pong"}`

### 2.5 Launch the Deployer

```bash
cd ~/orochi/orochi

# Production (management box is at 10.16.255.253 — default):
ansible-playbook fuse.yml

# Development (override management box IP):
ansible-playbook fuse.yml -e mgmt_box_ip=100.99.102.28
```

You will be prompted to enter and confirm the **engagement password**. This password is used for every service's authentication. Choose something strong and record it securely — it cannot be retrieved after the session ends.

### 2.6 What Happens Before the Menu Appears

Before displaying the menu, `fuse.yml` always runs the `bootstrap_node` role as a pre-task. This:

1. **Resolves the management box IP** — reads `MGMT_BOX_IP` from `{{ playbook_dir }}/.env` if present. If not, it lists all non-loopback interfaces on the management box (the control node) and prompts you to select the correct one. The selected IP is saved to `.env` for future runs.
2. **Verifies the management box is reachable** — fails immediately if port 8888 is unreachable at the resolved IP.
3. **Configures apt on the orochi node** to proxy through the management box (`/etc/apt/apt.conf.d/01orochi-proxy`). All subsequent `apt-get` calls on the node go through port 3142 on the management box.

### 2.7 The Interactive Menu

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

Each option runs `common` (Docker install + network + base directories) before doing its specific work, so individual options are safe to run standalone.

---

## Deployment Menu Reference

### Option 1 — Deploy Complete Stack

Deploys everything in order. Use this for a full engagement build from a clean node.

**Role execution order:**
`common` → `environment` → `certificates` → `elasticsearch` → `kibana` → `fleet` → `thehive` → `velociraptor` → `suricata` → `zeek` → `arkime` → `cyberchef` → `mattermost` → `rita` → `timesketch` → `nginx_proxy`

**Estimated time:** 45–90 minutes

**Caveats:**
- Suricata startup takes up to 15 minutes for rule compilation on first run (see option 6 below for detail)
- RITA is fully offline — all images pre-cached by `prep_artefacts.yml`

---

### Option 2 — Deploy Elastic Stack

Deploys Elasticsearch 9.x, Kibana, and Fleet Server. This is the foundation — Arkime requires it, and it's the destination for Kibana dashboards and Fleet-managed agents.

**What it deploys:**
- `elasticsearch` container — single-node cluster in `basic` licence mode, TLS enabled, heap 2 GB
- `kibana` container — connects to ES with the `kibana_system` user; takes 2–5 minutes after start to become ready
- `fleet-server` container (elastic-agent image) — Fleet Server that manages Elastic Agents; requires Kibana to be healthy first

**Certificate handling:** The `certificates` role generates a self-signed CA and node certificate under `/opt/orochi/certs/`. Kibana and Fleet use these. Velociraptor generates its own separate PKI.

**Estimated time:** 15–25 minutes

> Elastic Stack must be deployed before Arkime. All other tools are independent of it.

---

### Option 3 — Deploy TheHive 4

Deploys the TheHive 4 incident response platform with its own dedicated backend stack.

**What it deploys:**
- `cassandra` container (Cassandra 4.0) — TheHive's primary database. Slow to initialise on first run; the role waits 45 seconds for it to become ready.
- `elasticsearch-hive` container (ES 7.17.9) — TheHive requires ES 7.x specifically (not 9.x). Runs separately from the main Elastic Stack on a different port (no direct external port exposed).
- `thehive` container (TheHive 4.1.19) — connects to both Cassandra and ES-hive.

**First-login credentials:** `admin@thehive.local` / `secret`

> **CRITICAL: Change the default TheHive password immediately after first login.** Go to Admin → Users → admin → Edit. This password is not managed by the engagement password and is the same on every deployment.

**Estimated time:** 10–15 minutes (Cassandra start is the bottleneck)

---

### Option 4 — Deploy Velociraptor

Deploys Velociraptor for DFIR and live endpoint interrogation.

**What it deploys:** Velociraptor runs inside a Docker container built on-node from the pre-cached `debian:bookworm-slim` image and the `velociraptor-linux-amd64` binary downloaded from the artifact server. The role:
1. Downloads the binary from the artifact server
2. Generates a server configuration (self-signed TLS, local datastore)
3. Builds a custom Docker image
4. Starts the container with GUI (8889), frontend (8000), and API (8001) ports exposed
5. Creates the admin user

**Endpoint collection:** After deployment, retrieve the client config from `/opt/orochi/velociraptor/client.config.yaml` and use it to generate the agent installer for target endpoints.

**Credentials:** `admin` / *engagement password*

**Estimated time:** 5–10 minutes

---

### Option 5 — Deploy Zeek

Installs Zeek Network Security Monitor from the pre-cached `.deb` tarball.

**What it deploys:** Zeek runs as a bare-metal systemd service (not a container). The role:
1. Downloads `zeek-debs.tar.gz` from the artifact server
2. Extracts and installs all `.deb` files with `apt-get`
3. Configures Zeek to monitor `{{ capture_interface }}` (discovered at runtime from `target_nic_mac`)
4. Configures `zeekctl` and deploys Zeek via `zeekctl deploy`

**Log location:** `/opt/zeek/logs/current/` (conn.log, dns.log, http.log, ssl.log, etc.)

**Estimated time:** 5 minutes

---

### Option 6 — Deploy Suricata

Installs Suricata IDS from the pre-cached `.deb` tarball.

**What it deploys:** Suricata runs as a bare-metal systemd service. The role:
1. Downloads `suricata-debs.tar.gz` from the artifact server and installs
2. Writes `/etc/suricata/suricata.yaml` — configures `HOME_NET`, all required port-groups (HTTP_PORTS, SSH_PORTS, ORACLE_PORTS, DNP3_PORTS, MODBUS_PORTS, FTP_PORTS, SHELLCODE_PORTS, FILE_DATA_PORTS), EVE JSON output, af-packet capture on `{{ capture_interface }}`
3. Downloads `suricata-rules.tar.gz` (Emerging Threats Open ruleset, ~55,000 signatures) from the artifact server and extracts to `/var/lib/suricata/rules/`
4. Creates a systemd service override with `TimeoutStartSec=900` and `Restart=on-failure`
5. Enables and starts the service

**Important — Suricata startup time:** On first start, Suricata must compile 55,000+ ET Open signatures into its detection engine. This takes **8–15 minutes** depending on hardware. The systemd timeout is set to 900 seconds (15 minutes) to accommodate this. The service will show `activating` in `systemctl status` for the full duration. This is normal — do not interrupt it. You can monitor progress:

```bash
# On the orochi node — watch for "Engine started." in the journal
journalctl -fu suricata
```

Once you see `Engine started.`, Suricata is live. Subsequent restarts are fast (~30 seconds) because the detection engine is reloaded from the compiled state.

**Logs:**
- `/var/log/suricata/eve.json` — full JSON event log (alerts, DNS, HTTP, TLS, flows)
- `/var/log/suricata/fast.log` — human-readable alert log
- `/var/log/suricata/stats.log` — performance statistics

**Estimated time:** 5 minutes to deploy, 8–15 minutes for first service startup

---

### Option 7 — Deploy Arkime

Deploys Arkime full packet capture as Docker containers (official `arkime/arkime` image).

**What it deploys:** Two containers from the same image, both with `--network host` and `NET_ADMIN`/`NET_RAW` capabilities so they can see host interfaces in promiscuous mode:
- `arkimecapture` — captures packets on `{{ capture_interface }}` and indexes session metadata into Elasticsearch
- `arkimeviewer` — web UI for searching sessions and retrieving PCAP (port 8005)

The role:
1. Creates the PCAP directory (`/opt/orochi/arkime/raw/`) owned by `nobody:daemon`
2. Waits for Elasticsearch to be healthy
3. Initialises Arkime's Elasticsearch index templates via a one-shot `docker run --rm` call to `db.pl init`
4. Configures index lifecycle management (1-day rotation, 30-day retention)
5. Creates the admin user via `arkime_add_user.sh`
6. Applies a priority-600 Elasticsearch index template to ensure `firstPacket`/`lastPacket` are mapped as `date` (not `long`) on ES 9.x
7. Starts the `arkimecapture` and `arkimeviewer` containers
8. Waits for the viewer to respond on port 8005; prints container logs if it fails

**Elasticsearch dependency:** Arkime indexes session metadata into the main Elasticsearch 9.x instance. Elastic Stack (option 2) must be running before deploying Arkime. Option 7 in `fuse.yml` automatically includes Elastic Stack in its role chain.

**PCAP storage:** `/opt/orochi/arkime/raw/`

**Credentials:** `admin` / *engagement password*

**Logs:**
```bash
docker logs -f arkimecapture    # packet capture activity
docker logs -f arkimeviewer     # web UI / query logs
```

**Estimated time:** 10 minutes

---

### Option 8 — Deploy CyberChef

Deploys CyberChef as a Docker container. No authentication. Fully offline — no CDN calls, all resources are bundled in the image.

**Estimated time:** 2 minutes

---

### Option 9 — Deploy Mattermost

Deploys Mattermost team chat with a dedicated PostgreSQL backend.

**What it deploys:**
- `postgres-mattermost` container — PostgreSQL 15 database for Mattermost
- `mattermost` container — Mattermost Team Edition

**First-use setup:** Navigate to `http://<node-ip>:8065`. Mattermost runs a first-use wizard on the first visit — create the admin account here. Use the engagement password for consistency.

**Estimated time:** 5 minutes

---

### Option 10 — Deploy RITA

Installs RITA (Real Intelligence Threat Analytics) for beaconing and C2 detection from Zeek logs.

**RITA v5 is fully offline.** It runs as a `docker compose` stack — no bare-metal MongoDB install, no internet required. All images (RITA, ClickHouse, syslog-ng) are pre-cached in the local registry by `prep_artefacts.yml` and served from the management box.

**What it deploys** (stack at `/opt/rita/`):
- `rita` container — the RITA analysis engine
- `rita-clickhouse` container — ClickHouse columnar database (RITA v5 replaced MongoDB with ClickHouse)
- `rita-syslog-ng` container — log ingestion

The role extracts the RITA installer tarball from the artifact server, rewrites all `image:` references in `docker-compose.yml` to point at the local registry, and runs `docker compose up -d`.

**Usage (on the orochi node):**
```bash
cd /opt/rita

# Import Zeek logs
docker compose exec rita rita import --database=<engagement-name> /zeek/logs/current

# View results
docker compose exec rita rita view <engagement-name>

# Generate HTML report
docker compose exec rita rita html-report <engagement-name>
```

> **Zeek logs volume:** RITA's compose file mounts Zeek log directories from the host. Verify the volume paths in `/opt/rita/docker-compose.yml` match your Zeek log location (`/opt/zeek/logs/current/`).

**Estimated time:** 5–10 minutes

---

### Option 11 — Deploy Timesketch

Deploys Timesketch timeline analysis platform.

**What it deploys:**
- `redis-timesketch` container — Redis 7 for Timesketch task queue
- `postgres-timesketch` container — PostgreSQL 15 for Timesketch metadata
- `timesketch` container — Timesketch web frontend (gunicorn on port 5000, started with `command: timesketch-web`)
- `timesketch-worker` container — Celery background worker for async jobs (same image, `command: timesketch-worker`)

The entrypoint script (`/docker-entrypoint.sh`) requires an explicit command argument — without it the container exits immediately with no logs. The role passes `timesketch-web` and `timesketch-worker` respectively.

The Timesketch role also starts `elasticsearch-hive` (ES 7.x) if it's not already running, since Timesketch uses the same ES 7 instance as TheHive for timeline index storage.

After the containers are up, the role:
1. Polls until the `timesketch` container reaches `running` state (not `restarting`)
2. Initialises the database with `tsctl db init`
3. Skips `tsctl db upgrade` non-fatally — it fails on fresh installs due to a SQLAlchemy 2.x / Alembic incompatibility in the image's `env.py`, but the schema is already correct from `db init`
4. Creates the admin user: `tsctl create-user <username> --password <password>`
5. Grants admin role: `tsctl make-admin <username>`

**Credentials:** `admin` / *engagement password*

**Estimated time:** 10–15 minutes

---

### Option 12 — Deploy Tool Portal

Deploys the Orochi landing page — an nginx-served HTML dashboard with links to all running services.

**Access:** `http://<orochi-node-ip>/`

**Offline note:** The portal HTML loads tool logos from external CDN/GitHub URLs. In an air-gapped environment the logos will be broken images, but all navigation links function correctly.

**Estimated time:** 2 minutes

---

### Option 13 — Show Status

Runs `docker ps` on the orochi node and prints a formatted table of all running containers with their state and port mappings. Also check bare-metal services on the node:

```bash
# Bare metal services (Suricata and Zeek only — Arkime runs as Docker containers)
ssh orochi@<node-ip> systemctl status suricata zeek
```

---

### Option 14 — Teardown All

Stops and removes all Orochi Docker containers (including `arkimecapture` and `arkimeviewer`) and bare-metal services (Suricata and Zeek). Removes the `orochi-network` Docker bridge.

**Does NOT delete** data under `/opt/orochi/` — redeploy after a teardown picks up existing data.

You will be prompted to type `YES` to confirm.

---

## Recommended Deployment Order

For a full engagement build using individual options rather than option 1:

```
2  → Elastic Stack         (foundation — Arkime and Kibana agents depend on this)
3  → TheHive               (independent; its own ES7 + Cassandra backend)
4  → Velociraptor          (endpoint collection — get agents deployed early)
5  → Zeek                  (start network logging immediately)
6  → Suricata              (start alerting immediately — expect 15 min startup)
7  → Arkime                (PCAP — needs Elastic Stack running)
8  → CyberChef             (standalone, any time)
9  → Mattermost            (comms, any time)
11 → Timesketch            (timeline analysis — can wait)
10 → RITA                  (requires internet — do before going offline or skip)
12 → Portal                (last — links everything together)
```

**For fastest time to visibility**, prioritise the network sensors first:
```
6 (Suricata) → 5 (Zeek) → 2 (Elastic Stack) → 7 (Arkime)
```
Start Suricata first because its 15-minute startup runs in the background while you deploy the others.

---

## Service Access Reference

Replace `<node-ip>` with the orochi node's IP address.

| Service | URL | Protocol | Username | Password |
|---------|-----|----------|----------|----------|
| **Kibana** | `https://<node-ip>:5601` | HTTPS | `elastic` | engagement password |
| **Fleet Server** | `https://<node-ip>:8220` | HTTPS | API use only | — |
| **TheHive** | `http://<node-ip>:9000` | HTTP | `admin@thehive.local` | `secret` ⚠️ |
| **Velociraptor** | `https://<node-ip>:8889` | HTTPS | `admin` | engagement password |
| **Arkime** | `http://<node-ip>:8005` | HTTP | `admin` | engagement password |
| **CyberChef** | `http://<node-ip>:8080` | HTTP | — | — |
| **Mattermost** | `http://<node-ip>:8065` | HTTP | Setup wizard on first visit | — |
| **Timesketch** | `http://<node-ip>:5000` | HTTP | `admin` | engagement password |
| **Tool Portal** | `http://<node-ip>:80` | HTTP | — | — |

> ⚠️ **TheHive default password is `secret`**. Change it immediately after first login: Admin → Users → admin → Edit.

### Log Locations (on the Orochi Node)

| Service | Log Path | Notes |
|---------|----------|-------|
| Suricata alerts | `/var/log/suricata/eve.json` | JSON; includes alerts, DNS, HTTP, TLS, flows |
| Suricata fast log | `/var/log/suricata/fast.log` | Human-readable alert summary |
| Suricata stats | `/var/log/suricata/stats.log` | Performance counters |
| Zeek logs | `/opt/zeek/logs/current/` | conn.log, dns.log, http.log, ssl.log, etc. |
| Arkime PCAP | `/opt/orochi/arkime/raw/` | Raw capture files |
| Arkime capture logs | `docker logs arkimecapture` | Packet capture activity |
| Arkime viewer logs | `docker logs arkimeviewer` | Web UI / query activity |
| Docker logs | `docker logs <container-name>` | All containerised services |

---

## Verification Checklist

Run these checks after a full deployment to confirm everything is healthy.

### Quick Check (from the Management Box)

```bash
# Elasticsearch cluster health — should show "green" or "yellow"
curl -k -u elastic:<password> https://<node-ip>:9200/_cluster/health?pretty

# Kibana API status — look for "overall.state": "green"
curl -k https://<node-ip>:5601/api/status | python3 -m json.tool | grep -A3 '"overall"'

# Fleet Server — should return 200
curl -k -o /dev/null -w "%{http_code}\n" https://<node-ip>:8220/api/status

# TheHive — should return 200 with status JSON
curl -o /dev/null -w "%{http_code}\n" http://<node-ip>:9000/api/status

# Velociraptor — should return 200 (ignore TLS warning)
curl -k -o /dev/null -w "%{http_code}\n" https://<node-ip>:8889/

# Arkime viewer — should return 200
curl -o /dev/null -w "%{http_code}\n" http://<node-ip>:8005/

# Timesketch — should return 200
curl -o /dev/null -w "%{http_code}\n" http://<node-ip>:5000/
```

### Bare Metal Services (on the Orochi Node)

```bash
# Bare metal services — should show "active (running)"
systemctl status suricata zeek

# Suricata is producing alerts
tail -f /var/log/suricata/fast.log

# Zeek is logging connections
ls -la /opt/zeek/logs/current/
```

### Arkime (Docker Containers)

```bash
# Both containers should show "Up"
docker ps --filter name=arkime

# Arkime is capturing — directory should contain .pcap files
ls /opt/orochi/arkime/raw/

# Live capture log
docker logs -f arkimecapture
```

### Container Status (Option 13)

The fastest full check: run `fuse.yml` and choose option `13`. It prints a live `docker ps` table.

---

## Teardown and Reset

### Graceful Teardown (Option 14)

```bash
ansible-playbook fuse.yml
# Choose 14, type YES when prompted
```

Stops all containers and bare metal services. Data under `/opt/orochi/` is preserved.

### Full Node Reset

To return the orochi node to a completely clean pre-deployment state, use `reset.sh`. Copy it to the orochi node and run it as root:

```bash
# From the management box
scp orochi/reset.sh orochi@<node-ip>:~/reset.sh
ssh orochi@<node-ip>

# On the orochi node
sudo bash reset.sh
```

The reset script removes:
- All Orochi Docker containers (stops and removes)
- The `orochi-network` Docker bridge
- All data directories (`/opt/orochi/`, `/var/log/suricata/`, `/var/lib/suricata/`, `/etc/suricata/`, `/opt/zeek/logs/`)
- Suricata and Zeek packages (purged via `apt-get purge`)
- Systemd service overrides for Suricata and Zeek
- The apt proxy config (`/etc/apt/apt.conf.d/01orochi-proxy`)
- The Docker insecure-registry config (`/etc/docker/daemon.json`)
- Temporary package download directories in `/tmp/`

**Docker itself is preserved.** After reset, the node is ready for a fresh `fuse.yml` deployment.

### Teardown Individual Containers

```bash
# Stop and remove one container without touching others
docker stop <container-name> && docker rm <container-name>

# Remove its data directory too:
sudo rm -rf /opt/orochi/<service-name>/
```

---

## Adapting for Different Hardware

OROCHI is hardware-agnostic for the orochi node. No MAC addresses or interface names are hardcoded — interface selection happens interactively at deploy time.

### If the Orochi Node Is Different Hardware

1. Boot the new hardware with Ubuntu Server 25.10 installed
2. Update `inventory/hosts.yml` with the new node's IP
3. Run `fuse.yml` — the `environment` role lists available interfaces and prompts you to select the capture interface at runtime

No other changes are required.

### If the Management Box Has a Different IP (Production vs Development)

`bootstrap_node` resolves the management box IP dynamically — you don't need to hardcode it. On first run it prompts you to select the interface, saves the result to `.env`, and reuses it on subsequent runs.

To force a specific IP for a single run without changing `.env`:
```bash
ansible-playbook fuse.yml -e mgmt_box_ip=100.99.102.28
ansible-playbook playbooks/prep_artefacts.yml -e mgmt_box_ip=100.99.102.28
```

To re-run the IP selection prompt (e.g. the management box IP has changed), delete `MGMT_BOX_IP` from `{{ playbook_dir }}/.env` or remove the file entirely — `bootstrap_node` will prompt again on the next run.

---

## Updating Tool Versions

All version pins are in `group_vars/all.yml`. To update any tool:

1. Edit the relevant version variable in `group_vars/all.yml`
2. Run `prep_artefacts.yml` with internet access — it downloads the new version and pushes it to the local registry
3. Run `fuse.yml` on-site — the role detects the container is out of date and recreates it with the new image

**Version constraints to be aware of:**
- `elasticsearch_hive_version` must stay on `7.x` — TheHive 4 is not compatible with Elasticsearch 8+
- `cassandra_version: "4.0"` — TheHive 4 is tested against Cassandra 4
- `stack_version` for Elasticsearch, Kibana, and Fleet Agent must all be the **same version** — the Elastic stack enforces version parity

---

## Troubleshooting

### Management Box Artifact Server Not Reachable

```
FAILED! => Management box artifact server not reachable at 10.16.255.253:8888
```

**Diagnosis:**
```bash
# From the orochi node — can it reach port 8888?
curl -o /dev/null -w "%{http_code}\n" http://10.16.255.253:8888/

# Is nginx running on the management box?
docker ps | grep orochi-artifacts

# Can you ping the management box from the orochi node?
ping 10.16.255.253
```

**Fixes:**
- Check the ethernet cable between the two machines
- Start the nginx container: `docker start orochi-artifacts`
- Verify the management box IP — if using dev, add `-e mgmt_box_ip=100.99.102.28`

---

### Docker Registry HTTP vs HTTPS Error

```
Error: Get "https://10.16.255.253:5000/v2/": http: server gave HTTP response to HTTPS client
```

The Docker daemon on the orochi node doesn't have the management box registry in its `insecure-registries` list. This should be fixed by the `common` role, but if it persists:

```bash
# Check /etc/docker/daemon.json on the orochi node
cat /etc/docker/daemon.json
# Expected: {"insecure-registries": ["10.16.255.253:5000"]}

# Check if the running daemon has it loaded
docker info | grep -A5 "Insecure Registries"

# If daemon.json is correct but docker info doesn't show it — restart Docker
sudo systemctl restart docker
```

If `daemon.json` is missing entirely, re-run the relevant fuse.yml option — the `common` role writes this file and restarts Docker if it's not already loaded.

---

### Elasticsearch Won't Start

```
docker logs elasticsearch
# ERROR: max virtual memory areas vm.max_map_count [65530] is too low
```

The `common` role sets this automatically, but verify it's applied:

```bash
# On the orochi node
sudo sysctl vm.max_map_count
# Should return 262144

# If not, set it:
sudo sysctl -w vm.max_map_count=262144
```

---

### Suricata Fails to Start

**Interface not found:**
```
Interface enx98e743225b91 does not exist
```

The capture interface MAC in `group_vars/all.yml` doesn't match the hardware. Find the correct interface:
```bash
# On the orochi node
ip link
# Find the NIC connected to the target network and note its MAC
```

Update `target_nic_mac` in `group_vars/all.yml` and re-run option 6.

**Configuration test fails:**
```bash
# On the orochi node — test the config without starting
sudo suricata -T -c /etc/suricata/suricata.yaml
```

Any `Variable "X" is not defined` error means a port-group variable is missing from `suricata.yaml`. This is normally handled by the role — re-run option 6 to re-apply the config.

**Service stuck at `activating`:**

This is **normal** on first start. Suricata is compiling 55,000+ detection signatures. Monitor it:

```bash
journalctl -fu suricata
# Wait for: "Engine started."
```

If it fails after 900 seconds, check the journal for errors:
```bash
journalctl -u suricata --since "10 minutes ago"
```

---

### Zeek Not Logging

```bash
/opt/zeek/bin/zeekctl status
# zeek  crashed  orochi  ...
```

**Fix:**
```bash
/opt/zeek/bin/zeekctl check      # check configuration
/opt/zeek/bin/zeekctl deploy     # redeploy (stop + start)
```

Common cause: the capture interface was not in promiscuous mode when Zeek started. `zeekctl deploy` sets promiscuous mode itself.

---

### TheHive Not Starting (Cassandra Not Ready)

TheHive requires Cassandra to be fully initialised before it can connect. The deployment pauses 45 seconds, but on slow hardware Cassandra may need longer.

```bash
# Check Cassandra is ready — look for "Created default superuser role 'cassandra'"
docker logs cassandra | tail -30

# Once Cassandra is ready, restart TheHive
docker restart thehive
docker logs -f thehive
```

---

### Velociraptor Admin User Already Exists

```
user add: Error: user already exists
```

This is expected on re-runs and is harmless. The `failed_when` condition in the role handles it. Not a failure.

---

### Timesketch Container Keeps Restarting

```
Container f886db... is restarting, wait until the container is running
```

The most common cause is not passing the required CMD argument. The OSDFIR Timesketch image's entrypoint (`/docker-entrypoint.sh`) exits immediately with code 0 if called without an argument — producing no logs and triggering the restart loop.

The role passes `command: timesketch-web` to the web container and `command: timesketch-worker` to the worker. If the container is still restarting, check the gunicorn log:

```bash
docker logs timesketch
# Or check the mounted log file:
cat /opt/orochi/timesketch/logs/wsgi_error.log
```

### Timesketch Database Init Fails

```
TASK [Initialise Timesketch database] FAILED
# could not connect to server: Connection refused
```

PostgreSQL or Elasticsearch-hive isn't ready yet.

```bash
# Check PostgreSQL is ready
docker logs postgres-timesketch | tail -10
# Wait for: "database system is ready to accept connections"

# Manually initialise if needed
docker exec timesketch tsctl db init
# db upgrade will fail with SQLAlchemy 2.x — that is expected and non-fatal

# Create user (positional arg, no --admin flag):
docker exec timesketch tsctl create-user admin --password <password>
docker exec timesketch tsctl make-admin admin
```

### tsctl db upgrade Fails (AttributeError: get_engine)

```
AttributeError: type object 'BaseModel' has no attribute 'get_engine'
```

Known incompatibility between the Alembic migration `env.py` baked into the OSDFIR image and SQLAlchemy 2.x. This is **non-fatal on fresh installs** — `tsctl db init` already created the schema from the current models. The role logs a warning and continues. No action required.

---

### RITA Stack Fails to Start

```bash
# Check RITA container status
cd /opt/rita && docker compose ps

# Check logs
docker compose logs rita
docker compose logs rita-clickhouse
```

If images are missing from the local registry (pull errors), re-run `prep_artefacts.yml` on the management box to re-cache the RITA images, then re-run option 10.

---

### Can't SSH to Orochi Node

```
ansible orochi_node -m ping
# UNREACHABLE! => SSH Error
```

1. Verify the IP in `inventory/hosts.yml` is correct
2. Verify the SSH key exists: `ls ~/.ssh/orochi_id_ed25519`
3. Re-copy the key: `ssh-copy-id -i ~/.ssh/orochi_id_ed25519 orochi@<node-ip>`
4. Verify sshd is running on the orochi node — connect a keyboard/monitor directly and run: `sudo systemctl start ssh`

---

### Re-Running fuse.yml Is Always Safe

All roles are idempotent. Running the same option again on an already-deployed service:
- Skips steps that are already complete (containers running, files already present)
- Re-applies any configuration that has changed since the last run
- Does not delete or recreate containers unless their configuration changed

This means you can safely re-run individual options to fix a partially-failed deployment, or to push a configuration change without tearing down the whole stack.
