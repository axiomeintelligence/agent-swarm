# Infrastructure Ansible Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure server provisioning into `infrastructure/` with a minimal cloud-config (user + Tailscale + firewall only) and Ansible playbooks that handle Docker, Komodo, and Periphery installation.

**Architecture:** A cloud-config bootstraps just enough for Ansible to connect (creates `cloud_user`, installs Tailscale with SSH, applies iptables firewall). A single `ansible-playbook` command then installs Docker, deploys Komodo, pauses for a manual onboarding key, and installs Periphery. All secrets live in a gitignored `vars/komodo.yml`.

**Tech Stack:** cloud-init YAML, Ansible (agentless, SSH via Tailscale), Docker Compose, Komodo (moghtech), Ubuntu 24.04

---

## File Map

**Create:**
- `infrastructure/cloud-config/cloud-config.yml` — minimal bootstrap (user, Tailscale, iptables)
- `infrastructure/ansible/inventory/hosts.example` — placeholder inventory
- `infrastructure/ansible/inventory/.gitignore` — ignores `hosts`
- `infrastructure/ansible/vars/komodo.example.yml` — placeholder secrets
- `infrastructure/ansible/vars/.gitignore` — ignores `komodo.yml`
- `infrastructure/ansible/tasks/docker.yml` — install Docker CE + compose plugin
- `infrastructure/ansible/tasks/komodo.yml` — create dirs, write compose files, start stack
- `infrastructure/ansible/templates/komodo-compose.env.j2` — Jinja2 template for compose.env
- `infrastructure/ansible/tasks/periphery.yml` — run periphery setup script, enable service
- `infrastructure/ansible/site.yml` — three-play entry point with pause gate
- `infrastructure/SERVER_SETUP.md` — updated docs referencing new layout

**Delete:**
- `cloud_setup/SERVER_SETUP.md` — replaced by `infrastructure/SERVER_SETUP.md`

---

### Task 1: Create minimal cloud-config.yml

**Goal:** Strip the existing cloud-config down to only what is needed for Ansible to connect — user creation, Tailscale, and iptables.

**Files:**
- Create: `infrastructure/cloud-config/cloud-config.yml`

**Acceptance Criteria:**
- [ ] Contains only: user creation, packages, iptables write_file, auto-upgrades write_file, Tailscale install, firewall apply, tailscale up, reboot
- [ ] Does NOT contain Docker install, Komodo write_files, or Periphery steps
- [ ] Includes `python3` in packages (required by Ansible on the remote host)
- [ ] Passes `cloud-init schema` validation if tool is available

**Verify:** `cat infrastructure/cloud-config/cloud-config.yml` — confirm no Docker or Komodo references

**Steps:**

- [ ] **Step 1: Create directory and write the file**

```bash
mkdir -p infrastructure/cloud-config
```

Write `infrastructure/cloud-config/cloud-config.yml`:

```yaml
#cloud-config
users:
  - name: cloud_user
    groups: users, admin, docker
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

packages:
  - iptables-persistent
  - curl
  - ca-certificates
  - gnupg
  - python3
  - unattended-upgrades
package_update: true
package_upgrade: true

write_files:
  # Uncomment to enable this server as a Tailscale exit node.
  # Also requires approval in the Tailscale admin console after boot:
  # https://login.tailscale.com/admin/machines
  # - path: /etc/sysctl.d/99-tailscale.conf
  #   content: |
  #     net.ipv4.ip_forward=1
  #     net.ipv6.conf.all.forwarding=1

  - path: /etc/iptables/rules.v4
    content: |
      *filter
      :INPUT DROP [0:0]
      :FORWARD DROP [0:0]
      :OUTPUT ACCEPT [0:0]
      # Allow established/related connections
      -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
      # Allow loopback
      -A INPUT -i lo -j ACCEPT
      # Tailscale direct peer connections (falls back to DERP relay if blocked)
      -A INPUT -p udp --dport 41641 -j ACCEPT
      # SSH — Tailscale network only
      -A INPUT -i tailscale0 -p tcp --dport 22 -j ACCEPT
      # Komodo web UI — Tailscale network only (accessed during Ansible playbook)
      -A INPUT -i tailscale0 -p tcp --dport 9120 -j ACCEPT
      COMMIT

  - path: /etc/apt/apt.conf.d/20auto-upgrades
    content: |
      APT::Periodic::Update-Package-Lists "1";
      APT::Periodic::Unattended-Upgrade "1";
      APT::Periodic::AutocleanInterval "7";

runcmd:
  # Disable openssh — emergency access via provider VNC console only
  - systemctl disable --now ssh || true
  - systemctl mask ssh

  # Install Tailscale
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).noarmor.gpg | tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null
  - curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/$(lsb_release -cs).tailscale-keyring.list | tee /etc/apt/sources.list.d/tailscale.list
  - apt-get update -y
  - apt-get install -y tailscale
  - systemctl enable --now tailscaled

  # Apply firewall rules and persist across reboots
  - iptables-restore < /etc/iptables/rules.v4
  - netfilter-persistent save

  # Authenticate Tailscale with SSH enabled
  # To also advertise as an exit node, uncomment the two lines below and comment out the one above:
  # - sysctl -p /etc/sysctl.d/99-tailscale.conf
  # - tailscale up --ssh --advertise-exit-node --authkey=<tailscale-auth-key>
  - tailscale up --ssh --authkey=<tailscale-auth-key>
  - reboot
```

- [ ] **Step 2: Verify no Docker/Komodo references**

```bash
grep -E "docker|komodo|mongo|periphery" infrastructure/cloud-config/cloud-config.yml
```

Expected: no output (no matches).

- [ ] **Step 3: Commit**

```bash
git add infrastructure/cloud-config/cloud-config.yml
git commit -m "feat(infra): add minimal cloud-config for Ansible bootstrap"
```

---

### Task 2: Create Ansible inventory and vars scaffold

**Goal:** Produce the gitignored inventory and vars files that operators copy and fill before running the playbook.

**Files:**
- Create: `infrastructure/ansible/inventory/hosts.example`
- Create: `infrastructure/ansible/inventory/.gitignore`
- Create: `infrastructure/ansible/vars/komodo.example.yml`
- Create: `infrastructure/ansible/vars/.gitignore`

**Acceptance Criteria:**
- [ ] `hosts.example` contains a `[servers]` group with `ansible_user=cloud_user`
- [ ] `inventory/.gitignore` ignores `hosts` (but not `hosts.example`)
- [ ] `komodo.example.yml` contains all four secret placeholders with generation instructions
- [ ] `vars/.gitignore` ignores `komodo.yml` (but not `komodo.example.yml`)

**Verify:** `git status infrastructure/ansible/` — `.example` files appear tracked, no `hosts` or `komodo.yml`

**Steps:**

- [ ] **Step 1: Create inventory files**

```bash
mkdir -p infrastructure/ansible/inventory
```

Write `infrastructure/ansible/inventory/hosts.example`:

```ini
# Copy this file to inventory/hosts (git-ignored) and fill in the real hostname.
# The hostname must be the server's Tailscale MagicDNS name or IP address.
#
#   cp inventory/hosts.example inventory/hosts
#   # Edit inventory/hosts — replace <server-tailscale-hostname>
#
# Example after filling in:
#   [servers]
#   hz-agents-0 ansible_user=cloud_user

[servers]
<server-tailscale-hostname> ansible_user=cloud_user
```

Write `infrastructure/ansible/inventory/.gitignore`:

```
hosts
```

- [ ] **Step 2: Create vars files**

```bash
mkdir -p infrastructure/ansible/vars
```

Write `infrastructure/ansible/vars/komodo.example.yml`:

```yaml
# Copy to vars/komodo.yml (git-ignored) and fill in real values before running.
# Generate each secret with: openssl rand -hex 32
#
#   cp vars/komodo.example.yml vars/komodo.yml
#   # Edit vars/komodo.yml — replace all placeholder values

komodo_database_password: "<mongo-password>"
komodo_jwt_secret: "<jwt-secret>"
komodo_webhook_secret: "<webhook-secret>"
komodo_admin_password: "<admin-password>"
```

Write `infrastructure/ansible/vars/.gitignore`:

```
komodo.yml
```

- [ ] **Step 3: Verify gitignore works**

```bash
touch infrastructure/ansible/inventory/hosts infrastructure/ansible/vars/komodo.yml
git status infrastructure/ansible/
```

Expected: `hosts` and `komodo.yml` do NOT appear as untracked. Remove the test files:

```bash
rm infrastructure/ansible/inventory/hosts infrastructure/ansible/vars/komodo.yml
```

- [ ] **Step 4: Commit**

```bash
git add infrastructure/ansible/inventory/ infrastructure/ansible/vars/
git commit -m "feat(infra): add Ansible inventory and vars scaffold"
```

---

### Task 3: Create tasks/docker.yml

**Goal:** Ansible task file that installs Docker CE and the compose plugin idempotently via the official Docker apt repository.

**Files:**
- Create: `infrastructure/ansible/tasks/docker.yml`

**Acceptance Criteria:**
- [ ] Adds Docker GPG key to `/usr/share/keyrings/docker-archive-keyring.gpg`
- [ ] Adds Docker apt repo using `dpkg --print-architecture` and `lsb_release -cs` for portability
- [ ] Installs `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`
- [ ] Enables and starts Docker systemd service
- [ ] Passes `ansible-playbook --syntax-check`

**Verify:**
```bash
cd infrastructure/ansible
ansible-playbook --syntax-check -i inventory/hosts.example site.yml
```
Expected: `playbook: site.yml` with no errors (run after Task 7 creates site.yml; for now verify YAML is valid with `python3 -c "import yaml; yaml.safe_load(open('tasks/docker.yml'))"`)

**Steps:**

- [ ] **Step 1: Write the task file**

```bash
mkdir -p infrastructure/ansible/tasks
```

Write `infrastructure/ansible/tasks/docker.yml`:

```yaml
- name: Download Docker GPG key
  ansible.builtin.get_url:
    url: https://download.docker.com/linux/ubuntu/gpg
    dest: /tmp/docker.gpg
    mode: '0644'

- name: Dearmor Docker GPG key
  ansible.builtin.command:
    cmd: gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg /tmp/docker.gpg
    creates: /usr/share/keyrings/docker-archive-keyring.gpg

- name: Get system architecture
  ansible.builtin.command: dpkg --print-architecture
  register: dpkg_arch
  changed_when: false

- name: Get Ubuntu codename
  ansible.builtin.command: lsb_release -cs
  register: ubuntu_codename
  changed_when: false

- name: Add Docker apt repository
  ansible.builtin.apt_repository:
    repo: "deb [arch={{ dpkg_arch.stdout }} signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu {{ ubuntu_codename.stdout }} stable"
    state: present
    filename: docker

- name: Install Docker CE and compose plugin
  ansible.builtin.apt:
    name:
      - docker-ce
      - docker-ce-cli
      - containerd.io
      - docker-compose-plugin
    update_cache: true
    state: present

- name: Enable and start Docker
  ansible.builtin.systemd:
    name: docker
    enabled: true
    state: started
```

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('infrastructure/ansible/tasks/docker.yml')); print('OK')"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add infrastructure/ansible/tasks/docker.yml
git commit -m "feat(infra): add Ansible docker install tasks"
```

---

### Task 4: Create tasks/komodo.yml and komodo-compose.env.j2

**Goal:** Ansible task file that creates the Komodo directory, writes the compose files from templates, and starts the stack. The compose.env is rendered from a Jinja2 template so secrets are never hardcoded.

**Files:**
- Create: `infrastructure/ansible/tasks/komodo.yml`
- Create: `infrastructure/ansible/templates/komodo-compose.env.j2`

**Acceptance Criteria:**
- [ ] Creates `/opt/komodo/` and `/etc/komodo/backups/` directories
- [ ] Writes `/opt/komodo/docker-compose.yml` (static — no secrets)
- [ ] Renders `/opt/komodo/compose.env` from `komodo-compose.env.j2` with mode `0600`
- [ ] `KOMODO_HOST` uses `{{ inventory_hostname }}` so it is set correctly without a post-provisioning edit
- [ ] Runs `docker compose up -d`
- [ ] Passes YAML syntax check

**Verify:**
```bash
python3 -c "import yaml; yaml.safe_load(open('infrastructure/ansible/tasks/komodo.yml')); print('OK')"
```
Expected: `OK`

**Steps:**

- [ ] **Step 1: Write the Jinja2 template**

```bash
mkdir -p infrastructure/ansible/templates
```

Write `infrastructure/ansible/templates/komodo-compose.env.j2`:

```jinja2
# Periphery is locked to v2.2.0; pin in the future if needed.
COMPOSE_KOMODO_IMAGE_TAG=2

KOMODO_DATABASE_USERNAME=komodo
KOMODO_DATABASE_PASSWORD={{ komodo_database_password }}

TZ=Etc/UTC

KOMODO_HOST=http://{{ inventory_hostname }}:9120
KOMODO_TITLE=Komodo

KOMODO_LOCAL_AUTH=true
KOMODO_INIT_ADMIN_USERNAME=admin
KOMODO_INIT_ADMIN_PASSWORD={{ komodo_admin_password }}

KOMODO_JWT_SECRET={{ komodo_jwt_secret }}
KOMODO_WEBHOOK_SECRET={{ komodo_webhook_secret }}

KOMODO_DISABLE_USER_REGISTRATION=true
KOMODO_ENABLE_NEW_USERS=false
```

- [ ] **Step 2: Write the task file**

Write `infrastructure/ansible/tasks/komodo.yml`:

```yaml
- name: Create Komodo directory
  ansible.builtin.file:
    path: /opt/komodo
    state: directory
    mode: '0755'

- name: Create Komodo backups directory
  ansible.builtin.file:
    path: /etc/komodo/backups
    state: directory
    mode: '0755'

- name: Write Komodo docker-compose.yml
  ansible.builtin.copy:
    dest: /opt/komodo/docker-compose.yml
    mode: '0644'
    content: |
      services:
        mongo:
          image: mongo
          labels:
            komodo.skip:
          command: --quiet --wiredTigerCacheSizeGB 0.25
          restart: unless-stopped
          env_file: ./compose.env
          volumes:
            - mongo-data:/data/db
            - mongo-config:/data/configdb
          environment:
            MONGO_INITDB_ROOT_USERNAME: ${KOMODO_DATABASE_USERNAME}
            MONGO_INITDB_ROOT_PASSWORD: ${KOMODO_DATABASE_PASSWORD}

        core:
          image: ghcr.io/moghtech/komodo-core:${COMPOSE_KOMODO_IMAGE_TAG:-2}
          init: true
          restart: unless-stopped
          depends_on:
            - mongo
          ports:
            - 9120:9120
          env_file: ./compose.env
          environment:
            KOMODO_DATABASE_ADDRESS: mongo:27017
          volumes:
            - keys:/config/keys
            - /etc/komodo/backups:/backups

      volumes:
        mongo-data:
        mongo-config:
        keys:

- name: Write Komodo compose.env from template
  ansible.builtin.template:
    src: komodo-compose.env.j2
    dest: /opt/komodo/compose.env
    mode: '0600'

- name: Start Komodo stack via docker compose
  ansible.builtin.command:
    cmd: docker compose -f /opt/komodo/docker-compose.yml --env-file /opt/komodo/compose.env up -d
    chdir: /opt/komodo
  changed_when: true
```

- [ ] **Step 3: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('infrastructure/ansible/tasks/komodo.yml')); print('OK')"
```

Expected: `OK`

- [ ] **Step 4: Commit**

```bash
git add infrastructure/ansible/tasks/komodo.yml infrastructure/ansible/templates/
git commit -m "feat(infra): add Ansible Komodo deploy tasks and template"
```

---

### Task 5: Create tasks/periphery.yml

**Goal:** Ansible task file that runs the Komodo Periphery setup script and enables the systemd service. The onboarding key is passed in as a variable from the `pause` in site.yml.

**Files:**
- Create: `infrastructure/ansible/tasks/periphery.yml`

**Acceptance Criteria:**
- [ ] Runs the official Periphery setup script pinned to `v2.2.0`
- [ ] Passes `--core-address` as `http://{{ inventory_hostname }}:9120`
- [ ] Passes `--connect-as` as `{{ inventory_hostname }}` (identifies the server in Komodo)
- [ ] Passes `--onboarding-key` as `{{ onboarding_key }}` (provided by the calling play)
- [ ] Uses `creates: /usr/local/bin/periphery` so the script is idempotent
- [ ] Enables and starts the `periphery` systemd service

**Verify:**
```bash
python3 -c "import yaml; yaml.safe_load(open('infrastructure/ansible/tasks/periphery.yml')); print('OK')"
```
Expected: `OK`

**Steps:**

- [ ] **Step 1: Write the task file**

Write `infrastructure/ansible/tasks/periphery.yml`:

```yaml
- name: Run Komodo Periphery setup script
  ansible.builtin.shell: |
    curl -sSL https://raw.githubusercontent.com/moghtech/komodo/main/scripts/setup-periphery.py \
      | python3 - \
      --version="v2.2.0" \
      --core-address="http://{{ inventory_hostname }}:9120" \
      --connect-as="{{ inventory_hostname }}" \
      --onboarding-key="{{ onboarding_key }}"
  args:
    creates: /usr/local/bin/periphery

- name: Enable and start Periphery systemd service
  ansible.builtin.systemd:
    name: periphery
    enabled: true
    state: started
    daemon_reload: true
```

- [ ] **Step 2: Validate YAML syntax**

```bash
python3 -c "import yaml; yaml.safe_load(open('infrastructure/ansible/tasks/periphery.yml')); print('OK')"
```

Expected: `OK`

- [ ] **Step 3: Commit**

```bash
git add infrastructure/ansible/tasks/periphery.yml
git commit -m "feat(infra): add Ansible Periphery install tasks"
```

---

### Task 6: Create site.yml

**Goal:** The single playbook entry point — three plays: server setup (Docker + Komodo), manual pause for onboarding key, Periphery installation.

**Files:**
- Create: `infrastructure/ansible/site.yml`

**Acceptance Criteria:**
- [ ] Play 1 targets `hosts: servers`, loads `vars_files: [vars/komodo.yml]`, imports docker and komodo tasks
- [ ] Play 2 targets `hosts: localhost`, `gather_facts: false`, pauses and registers `komodo_onboarding_key`
- [ ] Play 3 targets `hosts: servers`, imports periphery tasks with `onboarding_key` set from Play 2's registered value
- [ ] Passes `ansible-playbook --syntax-check` using `hosts.example` as inventory and a dummy vars file

**Verify:**
```bash
cd infrastructure/ansible
cp vars/komodo.example.yml vars/komodo.yml
ansible-playbook --syntax-check -i inventory/hosts.example site.yml
rm vars/komodo.yml
```
Expected: `playbook: site.yml` — no errors.

**Steps:**

- [ ] **Step 1: Write site.yml**

Write `infrastructure/ansible/site.yml`:

```yaml
---
# Play 1: Install Docker and deploy Komodo on the server
- name: Install Docker and deploy Komodo
  hosts: servers
  become: true
  vars_files:
    - vars/komodo.yml
  tasks:
    - ansible.builtin.import_tasks: tasks/docker.yml
    - ansible.builtin.import_tasks: tasks/komodo.yml

# Play 2: Pause on localhost to collect the Komodo onboarding key
- name: Collect Komodo onboarding key
  hosts: localhost
  gather_facts: false
  tasks:
    - name: Prompt for Komodo onboarding key
      ansible.builtin.pause:
        prompt: |

          Komodo is running at http://{{ groups['servers'][0] }}:9120

          Steps:
            1. Open the URL above in your browser
            2. Register as the first user (they receive admin rights automatically)
            3. Go to Settings → Onboarding Keys
            4. Create a new key — it will start with O-...
            5. Copy it immediately (shown only once)

          Paste the onboarding key here and press Enter
      register: komodo_onboarding_key

# Play 3: Install Periphery on the server using the onboarding key from Play 2
- name: Install Periphery
  hosts: servers
  become: true
  tasks:
    - ansible.builtin.import_tasks: tasks/periphery.yml
      vars:
        onboarding_key: "{{ hostvars['localhost']['komodo_onboarding_key']['user_input'] }}"
```

- [ ] **Step 2: Run syntax check**

```bash
cd infrastructure/ansible
cp vars/komodo.example.yml vars/komodo.yml
ansible-playbook --syntax-check -i inventory/hosts.example site.yml
rm vars/komodo.yml
```

Expected output ends with:
```
playbook: site.yml
```
No errors.

- [ ] **Step 3: Commit**

```bash
git add infrastructure/ansible/site.yml
git commit -m "feat(infra): add Ansible site.yml with three-play provisioning flow"
```

---

### Task 7: Move and update SERVER_SETUP.md

**Goal:** Move `cloud_setup/SERVER_SETUP.md` to `infrastructure/SERVER_SETUP.md` and rewrite it to reflect the new Ansible-based workflow, updated file paths, and removed manual steps.

**Files:**
- Create: `infrastructure/SERVER_SETUP.md` (rewritten content)
- Delete: `cloud_setup/SERVER_SETUP.md`

**Acceptance Criteria:**
- [ ] Security section preserved verbatim
- [ ] Cloud-config section updated: references `infrastructure/cloud-config/cloud-config.yml`, placeholder table contains only `<tailscale-auth-key>`
- [ ] New "Run Ansible" section explains the three-step process (copy hosts, copy vars, run playbook)
- [ ] Periphery manual step removed — replaced by a note that Ansible handles it via the inline pause
- [ ] Post-provisioning section simplified: just `tailscale status` to verify the node is online
- [ ] `cloud_setup/SERVER_SETUP.md` is deleted

**Verify:**
```bash
ls cloud_setup/
git status infrastructure/SERVER_SETUP.md
```
Expected: `cloud_setup/` is empty or removed; `infrastructure/SERVER_SETUP.md` is tracked.

**Steps:**

- [ ] **Step 1: Write infrastructure/SERVER_SETUP.md**

Write `infrastructure/SERVER_SETUP.md` with the full content below:

```markdown
# Server Setup

## Security

### Overview

Access to the server instance is locked down to the Tailscale VPN. A Cloud Firewall restricts all inbound traffic to only what Tailscale requires, preventing any direct public access to the server or its services. iptables running on the server instance additionally blocks inbound traffic, providing a layer of defense in depth in case of misconfiguration.

Note that all outbound ports are open, to facilitate cloudflared, tailscale, and updates. See (Further Security Enhancements)

Cloudflare Tunnels are used to access individual services, and must be protected with sufficient Cloudflare Access policies to control access. SSO and MFA is recommended.

NOTE: OpenSSH is disabled — Tailscale SSH is the only access path, available over the Tailscale network only. Appropriate Tailscale ACLs should be implemented to prevent privilege escalation.

Emergency access is available via the Cloud's VNC to fix any Tailscale misconfiguration.

#### Further Security Enhancements (Out of Scope)

To further secure this instance, a layer 7 traffic inspection firewall policy should be implemented to prevent data exfiltration in the event of a compromise on outbound ports. Due to the ability to tunnel outbound traffic over http/https and similar ports that need to be left open, this presents little additional protection, unless a layer 7 firewall is utilized.

### Administering the Server

All server administration is done over the Tailscale network. Install the Tailscale client on any device you want to administer the server from:

- **macOS:** https://tailscale.com/download/macos
- **Android/iOS:** Available in respective app stores (optional)

Services running on the server (e.g. Komodo) are accessed directly over the Tailscale network via MagicDNS hostname. No public ports are exposed for services. iptables restricts the necessary ports on the server instance to the `tailscale0` interface.

---

## Setup

### 1. Tailscale

#### 1.1 Account

1. Sign up at [tailscale.com](https://tailscale.com) (Free tier is sufficient)
2. Install the client on your local machine
3. Log in — your device should appear under **Devices** in the Tailscale admin console

#### 1.2 Tailnet Hardening

- https://login.tailscale.com/admin/settings/user-management → Enable User Approval
- https://login.tailscale.com/admin/settings/device-management → Enable Device Approval

#### 1.3 Tailscale Auth Key

The server authenticates to Tailscale automatically on first boot using an auth key.

1. Go to https://login.tailscale.com/admin/settings/keys
2. Generate an **Auth Key**
3. Copy the key — it goes into `cloud-config/cloud-config.yml` as `<tailscale-auth-key>`

**Key expiry:** Keys expire after 90 days by default. To re-authenticate after expiry:
```bash
tailscale logout && tailscale up --ssh --authkey=tskey-auth-XXXXXX
```

---

### 2. Cloud Firewall

Create a firewall policy with the following inbound rule before provisioning the server.

| Rule Name | Protocol | Port | Notes |
|---|---|---|---|
| Tailscale | UDP | 41641 | Direct peer connections. Falls back to DERP relay if blocked. |

> No public SSH rule — all access is via Tailscale SSH.

**Policy name:** `Tailscale Firewall`

---

### 3. Cloud Instance

#### Oracle Cloud (Free Tier)

https://www.oracle.com/ca-en/cloud/free

Apply the `Tailscale Firewall` policy when provisioning.

#### Hetzner (Alternative)

| Setting | Value |
|---|---|
| Type | Regular Performance (CPX21) |
| Location | US-West |
| Image | Ubuntu 24.04 |
| Networking | IPv4 + IPv6 |
| SSH Key | Optional — emergency fallback only |
| Firewall | Tailscale Firewall |
| Backups | Enabled |

---

### 4. Cloud Config

File: `infrastructure/cloud-config/cloud-config.yml`

Replace the one placeholder before pasting into the server instance cloud-config field:

| Placeholder | Value |
|---|---|
| `<tailscale-auth-key>` | Auth key from Tailscale admin console (Step 1.3) |

All other configuration (Docker, Komodo, Periphery) is handled by Ansible after first boot.

---

### 5. Post-Boot: Verify Node is Online

After provisioning, wait ~2 minutes for cloud-init to complete, then run from your local machine:

```bash
tailscale status
```

The server should appear with a MagicDNS hostname (e.g. `hz-agents-0`).

---

### 6. Run Ansible

Ansible handles Docker, Komodo, and Periphery installation. It connects over Tailscale SSH as `cloud_user` — no password or SSH key required.

**Step 1 — Copy and fill inventory:**

```bash
cd infrastructure/ansible
cp inventory/hosts.example inventory/hosts
# Edit inventory/hosts — replace <server-tailscale-hostname> with the MagicDNS hostname from Step 5
# Example: hz-agents-0 ansible_user=cloud_user
```

**Step 2 — Copy and fill vars:**

```bash
cp vars/komodo.example.yml vars/komodo.yml
# Edit vars/komodo.yml — generate and fill in each secret:
#   openssl rand -hex 32
```

**Step 3 — Run the playbook:**

```bash
ansible-playbook -i inventory/hosts site.yml
```

The playbook will:
1. Install Docker CE on the server
2. Deploy Komodo (Core + MongoDB) via docker compose
3. **Pause** and prompt you to create a Komodo onboarding key in the browser
4. Install and register Periphery with the key you provide

The server will appear under **Servers** in the Komodo UI within seconds of Periphery registering.

> `inventory/hosts` and `vars/komodo.yml` are gitignored — never committed.
```

- [ ] **Step 2: Delete the old file**

```bash
git rm cloud_setup/SERVER_SETUP.md
```

If `cloud_setup/` is now empty, remove it:

```bash
rmdir cloud_setup/ 2>/dev/null || true
```

- [ ] **Step 3: Commit**

```bash
git add infrastructure/SERVER_SETUP.md
git commit -m "docs(infra): move and rewrite SERVER_SETUP.md for Ansible workflow"
```
