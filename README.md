# Tiamat Security Stack - Ansible Deployment

This Ansible playbook automates the deployment of the Tiamat security stack, which includes ELK Stack, Fleet Server, Arkime, TheHive, Velociraptor, Mattermost, Suricata, CyberChef, Zeek, and RITA.

## Prerequisites

### Control Node (where you run Ansible)
- Ansible 2.10 or later
- Python 3.8+
- SSH access to target hosts

### Target Hosts
- Ubuntu 20.04/22.04 or Debian 11/12
- Minimum 8GB RAM (16GB+ recommended)
- 50GB+ free disk space
- Sudo privileges

## Project Structure

```
tiamat-ansible/
├── ansible.cfg
├── tiamat.yml                 # Main playbook
├── inventory/
│   └── hosts.ini              # Inventory file
├── group_vars/
│   └── tiamat_servers.yml     # Group variables
├── tasks/
│   ├── 00_init_vars.yml
│   ├── 01_prerequisites.yml
│   ├── 02_configure_env.yml
│   ├── 03_elk.yml
│   ├── 04_fleet.yml
│   ├── 05_arkime.yml
│   ├── 06_hive.yml
│   ├── 07_velociraptor.yml
│   ├── 08_mattermost.yml
│   ├── 09_suricata.yml
│   ├── 10_cyberchef.yml
│   ├── 11_zeek.yml
│   ├── 12_rita.yml
│   ├── 13_website.yml
│   └── 14_display_info.yml
├── templates/
│   ├── env.j2
│   ├── arkime_config.ini.j2
│   └── index.html.j2
└── files/
    └── docker-compose.yml      # Optional: your compose file
```

## Installation

### 1. Install Ansible

```bash
# Ubuntu/Debian
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install -y ansible

# Or via pip
pip3 install ansible

# Install required collections
ansible-galaxy collection install community.docker
```

### 2. Configure Inventory

Edit `inventory/hosts.ini`:

```ini
# For local deployment
[tiamat_servers]
localhost ansible_connection=local

# For remote deployment
[tiamat_servers]
tiamat-01 ansible_host=192.168.1.100 ansible_user=ubuntu ansible_ssh_private_key_file=~/.ssh/id_ed25519
```

### 3. Customize Variables

Edit `group_vars/tiamat_servers.yml` to customize:
- Components to deploy
- Network settings
- Zeek network range
- Project directories

### 4. Test Connection

```bash
ansible all -m ping
```

## Usage

### Deploy All Components

```bash
ansible-playbook tiamat.yml
```

You'll be prompted for:
- Elasticsearch/services password
- Velociraptor username
- Network interface (or auto-detect)

### Deploy Specific Components

```bash
# Deploy only ELK stack
ansible-playbook tiamat.yml --tags elk

# Deploy ELK and Fleet
ansible-playbook tiamat.yml --tags elk,fleet

# Deploy everything except Zeek and RITA
ansible-playbook tiamat.yml --skip-tags zeek,rita
```

### Available Tags

- `elk` - Elasticsearch, Logstash, Kibana
- `fleet` - Fleet Server
- `arkime` - Arkime packet capture
- `hive` - TheHive incident response
- `velociraptor` - Velociraptor endpoint monitoring
- `mattermost` - Mattermost communications
- `suricata` - Suricata IDS
- `cyberchef` - CyberChef data analysis
- `zeek` - Zeek network monitor
- `rita` - RITA beacon detection
- `website` - Dashboard website

### Selective Deployment via Variables

Edit `group_vars/tiamat_servers.yml`:

```yaml
deploy_components:
  - elk
  - fleet
  - arkime
  # Comment out components you don't want
```

Then run:
```bash
ansible-playbook tiamat.yml
```

## Advanced Usage

### Check Mode (Dry Run)

```bash
ansible-playbook tiamat.yml --check
```

### Verbose Output

```bash
ansible-playbook tiamat.yml -v    # Verbose
ansible-playbook tiamat.yml -vvv  # Very verbose
```

### Remote Deployment with SSH Key

```bash
# Generate SSH key on control node
ssh-keygen -t ed25519 -C "ansible@tiamat"

# Copy to target host
ssh-copy-id -i ~/.ssh/id_ed25519.pub ubuntu@192.168.1.100

# Update inventory with key path
# Then run playbook
ansible-playbook tiamat.yml
```

### Limit to Specific Hosts

```bash
ansible-playbook tiamat.yml --limit tiamat-01
```

### Pass Variables via Command Line

```bash
ansible-playbook tiamat.yml \
  -e "stack_version=8.18.0" \
  -e "monitor_interface=eth0"
```

## Post-Deployment

After successful deployment:

1. **Access the Dashboard**: `http://<host_ip>/`
2. **Check deployment summary**: `/opt/tiamat/DEPLOYMENT_SUMMARY.txt`
3. **Review logs**: `/opt/tiamat/`

### Default Credentials

- **Elasticsearch/Kibana**: `elastic` / (your configured password)
- **Arkime**: `admin` / (your configured password)
- **Velociraptor**: (your configured username) / (your configured password)

## Troubleshooting

### View Service Status

```bash
ansible tiamat_servers -m shell -a "cd /opt/tiamat && docker compose ps"
```

### Check Logs

```bash
ansible tiamat_servers -m shell -a "cd /opt/tiamat && docker compose logs -f elasticsearch"
```

### Restart Services

```bash
ansible tiamat_servers -m shell -a "cd /opt/tiamat && docker compose restart"
```

### Clean Deployment

```bash
ansible tiamat_servers -m shell -a "cd /opt/tiamat && docker compose down -v"
```

## Maintenance

### Update Components

```bash
# Pull latest images
ansible tiamat_servers -m shell -a "cd /opt/tiamat && docker compose pull"

# Restart with new images
ansible tiamat_servers -m shell -a "cd /opt/tiamat && docker compose up -d"
```

### Backup Configuration

```bash
ansible tiamat_servers -m fetch -a "src=/opt/tiamat/.env dest=./backups/"
```

## Differences from Bash Script

1. **Idempotent**: Can run multiple times safely
2. **Parallel Execution**: Can deploy to multiple hosts simultaneously
3. **Better Error Handling**: Automatic rollback on failures
4. **State Management**: Tracks what's installed and configured
5. **Modular**: Easy to add/remove components
6. **No Interactive Prompts**: Uses secure variable prompts instead

## Requirements File

Create `requirements.yml` for dependencies:

```yaml
---
collections:
  - name: community.docker
    version: ">=3.0.0"
```

Install with:
```bash
ansible-galaxy collection install -r requirements.yml
```

## Security Notes

- Passwords are prompted securely (not stored in files)
- `.env` file permissions set to 0600
- Use Ansible Vault for sensitive data in production:

```bash
# Create encrypted variable file
ansible-vault create group_vars/tiamat_servers/vault.yml

# Add encrypted passwords
ansible-vault edit group_vars/tiamat_servers/vault.yml

# Run with vault password
ansible-playbook tiamat.yml --ask-vault-pass
```

## Contributing

To extend this playbook:
1. Add new task file in `tasks/`
2. Create corresponding template in `templates/`
3. Import task in main playbook with appropriate tags
4. Update `group_vars` with new variables

