# Project Orochi — Context Brief
> Hand this file to a new Claude instance to bring it fully up to speed.
> Last verified against the codebase: June 2026 (post `multi_arkimecapture` merge).
> **Where this doc and the code disagree, the code wins.**

---

## What is Orochi?

A **rapid, repeatable, offline-capable cyber incident response (DFIR) platform** deployed by a non-technical analyst onto bare metal hardware in **under 6 hours**, with zero internet dependency after an initial prep phase.

The guiding design principle: if it requires engineering knowledge to operate, it's too complicated.

---

## The Two-Box Model (implemented)

**Management box** — Ubuntu laptop, the Ansible control node. Before going on-site it downloads and caches every artefact. On-site it runs three services the orochi node uses as its sole software source:

| Service | Port | Serves |
|---------|------|--------|
| Docker registry (`orochi-registry`) | 5000 | All Docker images |
| Nginx artifact server (`orochi-artifacts`) | 8888 | Velociraptor binary, RITA tarball, Zeek/Suricata/Docker `.deb` tarballs, Suricata rules, GPG keys, version files |
| apt-cacher-ng | 3142 | Transparent apt proxy for the node |

**Orochi node** — bare metal Ubuntu Server (currently an Intel NUC). Pulls everything from the management box, runs the full stack. Zero internet during or after deployment.

Dev addressing: management box `100.99.102.28` (Tailscale, user `orochiman`), node `100.70.2.104` (Tailscale) / `192.168.0.200` (LAN, user `orochi`). Production: direct ethernet link, management box `10.16.255.253/24` (default in `group_vars/all.yml`).

---

## Services (as deployed by the current roles)

### Docker containers on `orochi-network` bridge
| Container(s) | Role |
|--------------|------|
| `elasticsearch` | ES 9.x — main SIEM backend (TLS, single node, basic licence) |
| `kibana` | Visualisation |
| `fleet-server` | Elastic Agent management (elastic-agent image) |
| `elasticsearch-hive` | ES 7.17.x — dedicated backend for TheHive and Timesketch |
| `cassandra` | TheHive primary database |
| `thehive` | TheHive 4 case management |
| `velociraptor` | Endpoint forensics (custom image built on-node from debian-slim + binary) |
| `cyberchef` | Data transformation |
| `mattermost` + `postgres-mattermost` | Team comms |
| `timesketch` + `timesketch-worker` + `postgres-timesketch` + `redis-timesketch` | Timeline analysis |
| `tool-portal` | Nginx analyst dashboard (port 80) |

### Docker containers with host networking
| Container | Role |
|-----------|------|
| `arkimecapture` | Full packet capture (promiscuous, `NET_ADMIN`/`NET_RAW`) |
| `arkimeviewer` | PCAP review UI (port 8005) |
| `arkimecapture-remote` | Optional — capture on additional boxes around the target network, shipping sessions to the node's ES while keeping PCAP local |

### Bare metal (systemd)
| Service | Role |
|---------|------|
| Zeek | Network metadata (installed from cached `.deb`s) |
| Suricata | Network IDS (cached `.deb`s + cached ET Open ruleset, ~15 min first start for rule compilation) |

### Docker Compose stack at `/opt/rita/`
| Container | Role |
|-----------|------|
| `rita` | RITA v5 analysis engine (one-shot, run via `/usr/local/bin/rita` wrapper) |
| `rita-clickhouse` | Results database (v5 replaced MongoDB) |
| `rita-syslog-ng` | Log ingestion |

> There is **no Logstash**. Elastic Agents enrol with Fleet and ship directly to Elasticsearch.

---

## Data Flow (current)

```
Target Endpoints
    └── Elastic Agent → Fleet Server (8220) → Elasticsearch

On-site Analyst
    └── Laptop → switch → analyst NIC → all services (portal on :80)

Remote capture box(es)
    └── arkimecapture-remote → sessions to node ES (9200), PCAP stays local

Passive Capture (on-node)
    └── capture NIC (promiscuous) → Arkime / Zeek / Suricata → RITA (from Zeek logs)
```

---

## Deployment Pipeline (implemented)

### Phase 0 — Management box setup (once, internet required)
`playbooks/setup_mgmt_box.yml` — installs Docker, apt-cacher-ng, local registry, artifact server, Ansible collections, generates the `orochi_id_ed25519` SSH key, grants passwordless sudo.

### Phase 1 — Artefact pre-caching (per engagement, internet required)
`playbooks/prep_artefacts.yml` — pulls and pushes all Docker images to the local registry (including all RITA compose images, resolved from the installer's own compose file), downloads Velociraptor (latest from GitHub API), Zeek/Suricata/Docker `.deb` tarballs, Suricata ET Open rules, writes version files, warms the apt cache, verifies everything, then declares the box offline-ready. Offers latest-Elastic-version detection with prompt, persists the choice to `group_vars/all.yml`.

### Phase 2 — On-site deployment (fully offline)
`fuse.yml` — single entry point. Resolves node IP (prompt on first run, `.env` thereafter), prompts once for the **engagement password** (fans out to every service), always runs `bootstrap_node` (resolves/persists mgmt box IP, configures apt proxy, Docker insecure-registry trust), then presents a 12-option menu:

```
1 Elastic Stack   2 TheHive 4      3 Velociraptor   4 Zeek
5 Suricata        6 Arkime         7 CyberChef      8 Mattermost
9 RITA            10 Timesketch    11 Tool Portal   12 Arkime Remote Capture
Space-separated multi-select, 'all', 'status', 'teardown'
```

Shared prerequisites (`common`, `environment`, `certificates`, `elasticsearch`) run once based on the combined selection. The `environment` role handles all runtime prompts (capture interface, HOME_NET, versions offered from the registry, analyst-facing IP) and persists answers to `.env` on the control node for idempotent re-runs.

Option 12 / `playbooks/deploy_remote_capture.yml` deploy `arkimecapture-remote` to additional boxes around the target network — the standalone playbook exists so capture nodes can be added mid-engagement without re-running fuse.

### Reset
`reset.sh` (run as root on the node) returns it to a clean pre-deployment state: containers, network, dangling volumes, `/opt/orochi`, `/opt/rita`, Zeek/Suricata config and packages, systemd units, apt proxy and registry config. Image removal is intentionally skipped for fast test cycles. `fuse.yml` also has a lighter `teardown` option that keeps `/opt/orochi` data.

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Bare metal Ubuntu, no hypervisor | NUC can't run a hypervisor + VMs efficiently; direct deployment is faster and simpler |
| Docker for services, bare metal for Zeek/Suricata | Repeatability and offline image caching vs raw packet access |
| Ansible only — Terraform abandoned | No VMs to provision |
| Single engagement password | One credential per engagement, fans out to every service (TheHive excepted — hardcoded default, change on first login) |
| `.env` on the control node | Persists node IP, mgmt IP, interface and version choices across re-runs |
| Local registry + artifact server + apt proxy | The node never needs internet |
| Remote capture: sessions to central ES, PCAP local | Bandwidth-light visibility from multiple capture points |
| Fixed management network 10.16.255.0/24 | Removes "why can't my laptop see the node" troubleshooting |
| Elastic Agent (not Velociraptor) as the telemetry agent | Fleet-managed, ships direct to ES |
| Separate Postgres instances for Mattermost and Timesketch | Avoids schema conflicts |

---

## Planned / Not Yet Implemented

These are design intent. **None of the following exists in the codebase yet:**

1. **WireGuard Ansible role** — remote analyst access over a bearer of opportunity (`group_vars` already carries wireguard_* variables; no role consumes them)
2. **Export playbook** — verified NDJSON archive to a blank per-engagement USB Evidence Drive, checksummed, before any destroy
3. **Destroy playbook** — evidence-safe wipe, gated on confirmed export (current `reset.sh`/`teardown` are dev tools, not evidence-handling tools)
4. **Management laptop wizard/front-end** — guided deployment UX
5. **PXE boot** for node OS install (manual Ubuntu install for now)
6. **Capture-network USB NIC** — hardware still to be procured

> **Implemented since the list above was written:** the `firewall` role (per-interface iptables policy — analyst NIC open, capture/target NIC restricted to Fleet 8220 / ES 9200, SSH lockout guard, DOCKER-USER enforcement for published container ports, persisted via netfilter-persistent).

Target physical interface plan (NUC): `enp89s0` analyst LAN, `enx98e743225b91` target network (Elastic callbacks), USB NIC (TBD) passive capture, `wlo1` WireGuard.

---

## Repo Structure (actual)

```
Proj_OROCHI/
├── OROCHI_CONTEXT.md           # This file
├── BUILD.md                    # Full build and operations guide
├── build_guide_simple.md       # Plain-English analyst walkthrough
├── RITA.md                     # RITA usage reference
└── orochi/
    ├── fuse.yml                # Interactive deployer — single entry point
    ├── ansible.cfg
    ├── push_to_mgmt.ps1        # scp project from Windows dev box to mgmt box
    ├── reset.sh                # Node reset script (run on the node as root)
    ├── group_vars/all.yml      # Versions, ports, images, resource limits, password fan-out
    ├── inventory/hosts.yml     # Intentionally empty — fuse populates via add_host
    ├── playbooks/
    │   ├── setup_mgmt_box.yml          # Phase 0
    │   ├── prep_artefacts.yml          # Phase 1
    │   └── deploy_remote_capture.yml   # Standalone remote capture (mid-engagement)
    └── roles/
        bootstrap_node, common, environment, firewall, certificates,
        elasticsearch, kibana, fleet, thehive, velociraptor,
        zeek, suricata, arkime, rita, cyberchef, mattermost,
        timesketch, nginx_proxy
```

---

## Constraints

- Build time: **≤ 6 hours** from bare metal Ubuntu to operational stack
- Internet: **zero dependency** after the prep phase
- Operator skill: **assume non-technical** — every runtime decision is a prompt with a sane default
- Export and destroy (when built): **always separate steps**, export verified first
- Users are fixed: `orochiman` on the management box, `orochi` on the node — Ansible connects with `~/.ssh/orochi_id_ed25519`
