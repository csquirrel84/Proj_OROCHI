# Orochi Security Stack

An Ansible-based, fully offline-capable DFIR deployment framework, inspired by [Project Tiamat](https://github.com/csquirrel84/PROJ_TIAMAT).

Pre-cache everything on a management box with internet, then deploy the full stack to a bare metal Ubuntu node with **zero internet access** — under 6 hours from clean hardware to operational.

## Features

- **Fully Offline**: local Docker registry, artifact server, and apt proxy on the management box — the node never touches the internet
- **Interactive Menu**: space-separated multi-select, `all`, `status`, `teardown`
- **Single Engagement Password**: one credential fans out to every service
- **Idempotent**: re-running any option is safe; choices persist in `.env`
- **Firewalled**: the capture/target NIC is locked to Elastic Agent callbacks only
- **Remote Capture**: drop additional Arkime capture nodes around the target network mid-engagement

## Available Services

| # | Service | Description | Port |
|---|---------|-------------|------|
| 1 | Elastic Stack | Elasticsearch 9.x, Kibana, Fleet Server | 9200 / 5601 / 8220 |
| 2 | TheHive 4 | Incident response (own ES7 + Cassandra backend) | 9000 |
| 3 | Velociraptor | DFIR / endpoint interrogation | 8889 |
| 4 | Zeek | Network metadata (bare metal) | — |
| 5 | Suricata | Network IDS (bare metal) | — |
| 6 | Arkime | Full packet capture + viewer | 8005 |
| 7 | CyberChef | Data analysis | 8080 |
| 8 | Mattermost | Team chat | 8065 |
| 9 | RITA | Beaconing / C2 detection (CLI, no web UI) | — |
| 10 | Timesketch | Timeline analysis | 5000 |
| 11 | Tool Portal | Service dashboard | 80 |
| 12 | Arkime Remote Capture | Capture node on any additional box | 8007 |

## Quick Start

```bash
# ── Phase 0: management box setup (once, internet required) ──
sudo apt update && sudo apt install -y ansible
cd ~/orochi/orochi
ansible-playbook playbooks/setup_mgmt_box.yml

# ── Phase 1: cache all artefacts (per engagement, internet required) ──
ansible-playbook playbooks/prep_artefacts.yml
# ...then disconnect from the internet

# ── Phase 2: deploy (fully offline) ──
ansible-playbook fuse.yml
# enter engagement password, pick from the menu ('all' for everything)

# ── Add a remote capture node mid-engagement ──
ansible-playbook playbooks/deploy_remote_capture.yml
```

Full instructions: [BUILD.md](../BUILD.md) (operations guide) and [build_guide_simple.md](../build_guide_simple.md) (plain-English analyst walkthrough). RITA usage: [RITA.md](../RITA.md).

## Reset

Return the node to a clean pre-deployment state (run on the node as root):

```bash
sudo bash reset.sh
```
