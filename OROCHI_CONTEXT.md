# Project Orochi — Context Brief
> Hand this file to a new Claude instance to bring it fully up to speed.

---

## What is Orochi?

A **rapid, repeatable, offline-capable cyber incident response (DFIR) platform** designed to be deployed by a non-technical analyst onto bare metal hardware in **under 6 hours**, with zero internet dependency after an initial prep phase.

The guiding design principle: **"a mong could deploy it."** If it requires engineering knowledge to operate, it's too complicated.

---

## Architecture Overview

### Physical Hardware
- **Orochi Node** — bare metal Ubuntu Server, runs everything directly. Currently: Intel NUC, accessible at `100.70.2.104` via Tailscale during dev. Production IP for management network: `10.16.255.254/24`
- **Management Laptop** — Ubuntu, single ethernet interface, used ONLY for build/deploy. Production IP: `10.16.255.253/24`. Never connects to internet during deployment.
- **Analyst Laptop(s)** — on-site analysts, connect via physical dumb switch to the Orochi node LAN interface
- **USB Install Drive** — read-only, reusable. Contains all Docker images, Ansible collections, packages. Pre-downloaded in office during prep phase.
- **USB Evidence Drive** — blank, per-engagement. Receives NDJSON export at end of investigation.

### Network Interfaces (Orochi Node)
| Interface | Role | Physical NIC |
|-----------|------|-------------|
| enp89s0 | Analyst LAN | 88:ae:dd:0f:d9:0e |
| enx98e743225b91 | Target network — Elastic Agent callbacks only | 98:e7:43:22:5b:91 |
| (TBD) | Capture network — passive only, no IP, promiscuous | USB NIC (TO BE PROCURED) |
| wlo1 | Bearer of Opportunity / WireGuard (BOO) | WiFi |

> **Note:** One USB ethernet adapter still needs to be procured for the capture network (nic2).

### Network Policy (iptables — replaces PfSense)
| Interface | Policy |
|-----------|--------|
| enp89s0 | Allow all — analyst access |
| enx98e743225b91 | Allow inbound Elastic Agent callback port only, DROP everything else |
| (TBD) | No IP assigned, promiscuous mode — passive capture only, no response |
| wlo1 | Allow WireGuard port only, DROP everything else |

---

## Services

### Dockerised (all on Orochi node)
| Service | Role |
|---------|------|
| Elasticsearch | Search and analytics backend |
| Kibana | Visualisation and dashboards |
| Elastic Fleet Server | Endpoint agent management |
| Logstash | Log ingestion and processing from target endpoints |
| TheHive4 | Case management |
| Velociraptor | Endpoint forensics and live response |
| Timesketch | Collaborative timeline analysis |
| CyberChef | Data transformation and analysis |
| Mattermost | Team communication |
| Arkime Viewer | PCAP review UI |
| Nginx | Analyst portal / service dashboard |

### Bare Metal (direct on Orochi node)
| Service | Role |
|---------|------|
| Arkime Capture | Full packet capture to disk |
| Zeek | Network metadata and connection logs |
| Suricata | Network IDS / signature-based detection |
| RITA | Beaconing and C2 detection from Zeek logs |

### Supporting Containers
| Service | Used by |
|---------|---------|
| PostgreSQL (Mattermost instance) | Mattermost |
| PostgreSQL (Timesketch instance) | Timesketch |
| Redis | Timesketch (Celery task queue) |

---

## Data Flow

```
Target Endpoints
    └── Elastic Agent → nic1 (iptables: callback port only) → Logstash → Elasticsearch

On-site Analyst
    └── Laptop → Physical switch → nic0 → All services

Remote Analyst
    └── Internet → wlo1 → WireGuard VPN → All services

Passive Capture
    └── TAPs → Physical switch → nic2 (promiscuous, no IP) → Arkime/Zeek/Suricata/RITA
```

---

## Deployment Pipeline

### Phase 1 — Office Prep (one-time, requires internet)
1. Run prep tool on management laptop
2. Downloads all Docker images as tarballs, Ansible collections, packages
3. Verifies checksums
4. Confirms "you are ready — disconnect from internet"
5. All artifacts stored on management laptop (which IS the install platform)

### Phase 2 — On-site Deployment (fully offline)
1. Analyst installs Ubuntu Server on bare metal (manual for now, PXE boot planned for v2)
2. Analyst plugs management laptop ethernet into Orochi node
3. Tool detects link, assigns `10.16.255.253/24` to ethernet interface automatically
4. Tool prompts for engagement inputs:
   - Case reference
   - Common password (used across all services)
   - Target network CIDR
   - WireGuard peer public key (for remote analyst access)
5. Ansible configures everything — services, networking, iptables, WireGuard
6. Post-build validation checks all services are healthy (green/red Nginx dashboard)

### Phase 3 — End of Engagement
1. **Export playbook** runs — produces verified NDJSON archive to USB Evidence Drive
2. Checksums validated, export confirmed
3. **Analyst manually confirms** export is good
4. **Destroy playbook** runs — only after explicit confirmation
5. All data wiped, node reset to clean state

> These are intentionally separate steps. Destroy will NOT run without confirmed export. Evidence drive is physically separate from install drive.

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Bare metal Ubuntu, no hypervisor | NUC doesn't have the resources to run a hypervisor + 4 VMs efficiently. Direct deployment is faster and simpler. |
| Docker for all services except capture tools | Repeatability, easy teardown, image pre-caching for offline use |
| Capture tools bare metal | Zeek/Suricata/Arkime/RITA need raw packet access — containers add unnecessary complexity |
| iptables instead of PfSense VM | Removes an entire VM from the stack, same policy enforcement, less resource overhead |
| WireGuard directly on host | Simpler than running it inside a VM, lighter, better on variable internet connections |
| Ansible only, no Terraform | No VMs to provision — Ansible runs straight onto the bare metal node |
| Fixed management network 10.16.255.0/24 | Removes "why can't my laptop see the node" troubleshooting |
| Management laptop = install platform | No separate USB install drive needed, laptop IS the artifact store |
| Export before destroy enforced | Chain of custody, evidence integrity |
| NDJSON export format | Ingestible by both Elasticsearch and Splunk natively |
| Offline from phase 2 onwards | Operational security, works in any environment |
| Elastic Agent (not Velociraptor) as endpoint agent | Fleet-managed, feeds Logstash directly |
| Separate Postgres instances for Mattermost and Timesketch | Avoids schema conflicts, simpler to manage independently |
| USB Evidence Drive separate from Install Drive | Chain of custody — evidence drive is blank per engagement |

---

## Current State

- Management box is up at `192.168.0.24` (Ubuntu 25.10, user: orochiman)
- Orochi node (NUC) is at `100.70.2.104` (Tailscale) / `192.168.0.200` (LAN) — intermittently unstable, suspected hardware limitations under load
- Proxmox and Terraform work has been abandoned in favour of bare metal Ubuntu + Ansible approach
- Existing Ansible roles exist in `orochi/` for most Docker services — written against an older model, need review for the new single-node bare metal architecture
- **Immediate next step: write Ansible roles for iptables and WireGuard, then wire up Docker Compose for the full service stack**

---

## Immediate Next Steps

1. Write iptables Ansible role (replaces PfSense network policy)
2. Write WireGuard Ansible role (replaces PfSense VPN)
3. Write/update Docker Compose for full service stack (including Timesketch)
4. Write Timesketch Ansible role
5. Refactor existing Ansible roles for single-node bare metal deployment
6. Wire up `prep_for_battle.yml` to target bare metal Ubuntu node instead of Proxmox
7. Build Nginx portal/dashboard
8. Write export playbook
9. Write destroy playbook
10. Build management laptop wizard/front-end

---

## Repo Structure

```
E:\Projects\Proj_OROCHI\
├── orochi\
│   ├── push_to_mgmt.ps1        # Sync project to management box
│   ├── fuse.yml                # Main Ansible deployer (to be refactored)
│   ├── ansible.cfg
│   ├── group_vars\all.yml      # Main config, version pinning, ports
│   ├── inventory\hosts.yml     # Target host config
│   ├── vars\secrets.yml        # Ansible vault encrypted secrets
│   ├── playbooks\
│   │   ├── prep_for_battle.yml     # Bootstraps management box + Proxmox (to be refactored for bare metal)
│   │   ├── setup_mgmt_box.yml      # Sets up management laptop
│   │   ├── deploy_elastic_stack.yml
│   │   ├── deploy_arkime.yml
│   │   ├── deploy_thehive.yml
│   │   ├── deploy_velociraptor.yml
│   │   └── teardown.yml
│   └── roles\                  # Ansible roles — mostly usable, need review
└── OROCHI_CONTEXT.md
```

> The Terraform directory (`terraform/`) can be removed — it is no longer part of the architecture.

---

## Constraints

- Build time: **≤ 6 hours** from bare metal Ubuntu to operational stack
- Internet: **zero dependency** after prep phase
- Operator skill: **assume non-technical** — no engineering knowledge required
- Export and destroy: **always separate steps**, export must be verified first
- Network policy: **default deny** on nic1 and wlo1, only explicitly permitted traffic passes
