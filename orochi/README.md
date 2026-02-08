# Orochi Security Stack

An Ansible-based deployment framework for security tools, inspired by [Project Tiamat](https://github.com/csquirrel84/PROJ_TIAMAT).

## Features

- **Modular Design**: Deploy only what you need
- **Interactive Menu**: Easy-to-use deployment interface
- **Production Ready**: Secure defaults, proper certificate handling
- **Fully Automated**: No manual configuration required

## Available Services

| Service | Description | Port |
|---------|-------------|------|
| Elasticsearch | Search & Analytics | 9200 |
| Kibana | Visualization | 5601 |
| Fleet Server | Endpoint Management | 8220 |
| TheHive 4 | Incident Response | 9000 |
| Velociraptor | DFIR Platform | 8889 |
| Suricata | Network IDS | - |
| Arkime | Packet Capture | 8005 |
| CyberChef | Data Analysis | 8080 |
| Mattermost | Team Chat | 8065 |
| RITA | Network Traffic Analytics | 8888 |
| Tool Portal | Service Dashboard | 80 |

## Quick Start

```bash
# Clone the repository
git clone https://github.com/yourusername/orochi.git
cd orochi

# Create vault for secrets (optional but recommended)
ansible-vault create vars/vault.yml

# Run interactive deployer
./site.yml

# Or deploy specific stack
ansible-playbook playbooks/deploy_elastic_stack.yml
ansible-playbook playbooks/deploy_thehive.yml
ansible-playbook playbooks/deploy_velociraptor.yml