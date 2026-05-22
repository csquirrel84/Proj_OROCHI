# Orochi Deployment — Analyst Walkthrough

A plain-English, step-by-step guide. No engineering knowledge required.

---

## Pre-Deployment — Office (internet required)

Do this once before going on-site. You need internet for this phase only.

---

### Step 0.1 — Install Ubuntu on the management box

Install Ubuntu Server 25.10 on the management laptop.

During install:
- Create user: **`orochiman`** with sudo access
- Enable OpenSSH server when prompted
- No additional packages needed

---

### Step 0.2 — Get the repo onto the management box

**Option A — Push from the dev machine (Windows):**
```powershell
.\orochi\push_to_mgmt.ps1 -IP <mgmt-box-ip> -User orochiman
```

### Step 0.3 — Set up the management box

SSH into the management box. Install Ansible, then run the setup playbook:

```bash
sudo apt update && sudo apt install -y ansible
cd ~/orochi/orochi
ansible-playbook playbooks/setup_mgmt_box.yml
```

---

### Step 0.4 — Download all deployment artefacts

```bash
cd ~/orochi/orochi
ansible-playbook playbooks/prep_artefacts.yml
```

This takes 15–60 minutes depending on internet speed. It downloads every Docker image, binary, and package the orochi node will need — nothing is fetched from the internet during deployment.

When it finishes you see:

```
All artefacts downloaded and cached.
Local registry:    localhost:5000
Artifact server:   http://localhost:8888
Apt proxy:         localhost:3142

Management box is ready for offline deployment.
You can now disconnect from the internet.
```

**Disconnect from the internet. Everything from here is offline.**

---

## On-Site Deployment

---

### Step 1 — Install Ubuntu on the orochi node

Boot the NUC from a USB drive, install Ubuntu Server 25.10.

> **IMPORTANT:** During install you MUST create the user exactly as shown below.
> If the username is wrong, Ansible will not be able to connect and deployment will fail.

During install:
- Create user: **`orochi`** (exactly this name, lowercase) with sudo access
- Enable OpenSSH server when prompted
- No additional packages needed

---

### Step 2 — Physical cabling

1. Management box ethernet → orochi node analyst NIC
2. Target network ethernet → orochi node target NIC

---

### Step 3 — Generate and copy the SSH key to the orochi node

From the management box, generate a key if you don't already have one:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/orochi_id_ed25519 -C "orochi-mgmt"
```

Then copy it to the orochi node:

```bash
ssh-copy-id -i ~/.ssh/orochi_id_ed25519.pub orochi@<node-ip>
```

To find the node's IP first:
```bash
arp-scan --interface=<your-eth-interface> --localnet
```

Enter the `orochi` user's password when prompted. After this, Ansible connects without a password.

---

### Step 4 — Run the deployer

```bash
cd ~/orochi/orochi
ansible-playbook fuse.yml
```

Here is exactly what you will see and do:

**a) Password prompt**

```
Engagement password (used across all services): ****
Engagement password (used across all services) (confirm): ****
```

Choose a strong password and write it down. It is used for every service. It cannot be recovered after the session ends.

**b) Orochi node IP (first run only)**

```
Enter the orochi node IP address: 
```

Type the IP of the orochi node (the one you used with `ssh-copy-id`). It is saved and you will not be asked again.

**c) Management box IP (first run only)**

```
Select the IP address the orochi node should use to reach this management box:
  1. eth0  10.16.255.253
  2. wlo1  192.168.1.45

Enter number or IP address [10.16.255.253]:
```

Type the number of the interface connected to the orochi node. It is saved and you will not be asked again.

**d) The menu appears**

```
┌─────────────────────────────────────────┐
│           DEPLOYMENT OPTIONS            │
├─────────────────────────────────────────┤
│  1. Deploy Complete Stack               │
│  2. Deploy Elastic Stack                │
│  ...                                    │
└─────────────────────────────────────────┘

Enter your choice [1-14, 0 to exit]:
```

Type **`1`** to deploy everything.

**e) Environment questions**

You will be asked a few questions about the deployment. Press Enter to accept the default for anything you are unsure about:

- Elastic Stack version — press Enter
- Cluster name — press Enter
- License type — press Enter
- Memory limit — press Enter
- **Capture interface** — select the NIC facing the monitored network
- **HOME_NET CIDR** — the target network subnet, e.g. `10.0.0.0/8`
- **IP for analyst access** — select the NIC analysts connect to
- Velociraptor server URL — press Enter
- **Arkime Docker tag** — select from the list of available tags (choose `v6-latest`)

**f) Deployment runs**

No further input required. Ansible deploys all services in sequence. This takes 15–45 minutes. Watch the output — if anything goes red, note the task name and error.

**g) Done**

```
╔═══════════════════════════════════════════════════════════════╗
║                    DEPLOYMENT COMPLETE                        ║
╠═══════════════════════════════════════════════════════════════╣
║  • Elasticsearch: https://<IP>:9200                           ║
║  • Kibana:        https://<IP>:5601                           ║
║  • Fleet Server:  https://<IP>:8220                           ║
║  • TheHive:       http://<IP>:9000                            ║
║  • Velociraptor:  https://<IP>:8889                           ║
╚═══════════════════════════════════════════════════════════════╝
```

Open a browser and go to `http://<node-ip>` to see the tool portal with links to every service.

---

## If Something Fails

Every run writes a full log to:

```
~/orochi/orochi/install.log
```

To see only the failures:

```bash
grep -A 20 'FAILED\|fatal:' ~/orochi/orochi/install.log
```

To start a fresh log before a new run (recommended before re-trying after a failure):

```bash
> ~/orochi/orochi/install.log
```

Feed the log (or the grep output) to Claude for diagnosis.

---

## Re-running After a Break

If you need to re-run `fuse.yml` (e.g. to add a tool or fix a failed step):

```bash
cd ~/orochi/orochi
ansible-playbook fuse.yml
```

- The node IP and management box IP will not be prompted again — both were saved on first run
- You will need to enter the engagement password again
- When asked "Existing configuration found. Use it? (y/n)" — type `y`
- Select the option you want from the menu

All roles are idempotent — re-running a step that already completed is safe.
