# Infrastructure — Ansible Migration Design

**Date:** 2026-05-28
**Status:** Approved

## Overview

Restructure the server provisioning workflow into an `infrastructure/` folder. A minimal cloud-config handles the bootstrap (user, Tailscale, firewall) so that Ansible can connect immediately after reboot. Ansible owns everything else: Docker, Komodo, and Periphery. The one manual step in the flow — creating a Komodo onboarding key — is handled with an Ansible `pause`, keeping the entire provisioning run as a single command.

---

## Folder Structure

```
infrastructure/
├── cloud-config/
│   └── cloud-config.yml          ← user + Tailscale + firewall only
├── ansible/
│   ├── inventory/
│   │   ├── hosts.example         ← committed placeholder; copy → hosts to use
│   │   └── .gitignore            ← ignores hosts
│   ├── tasks/
│   │   ├── docker.yml            ← install Docker CE + compose plugin
│   │   ├── komodo.yml            ← write compose.env, docker compose up
│   │   └── periphery.yml         ← run periphery setup script
│   ├── vars/
│   │   ├── komodo.example.yml    ← placeholder secrets; copy → komodo.yml to use
│   │   └── .gitignore            ← ignores komodo.yml
│   └── site.yml                  ← single entry point
└── SERVER_SETUP.md               ← moved from cloud_setup/, updated for new layout
```

`cloud_setup/SERVER_SETUP.md` is moved into `infrastructure/SERVER_SETUP.md` and updated to reference the new file paths.

---

## Responsibility Split

### cloud-config.yml

Handles only what is required for Ansible to connect after first boot:

- Create `cloud_user` (groups: users, admin, docker; passwordless sudo)
- Install: `iptables-persistent`, `curl`, `ca-certificates`, `unattended-upgrades`
- Write `/etc/iptables/rules.v4`:
  - DROP all INPUT by default
  - ACCEPT established/related
  - ACCEPT loopback
  - ACCEPT UDP 41641 (Tailscale direct peers)
  - ACCEPT TCP 22 on `tailscale0` (Tailscale SSH)
  - ACCEPT TCP 9120 on `tailscale0` (Komodo UI — for Ansible pause step)
- Install Tailscale via official apt repo
- `tailscale up --ssh --authkey=<tailscale-auth-key>`
- Apply firewall: `iptables-restore`, `netfilter-persistent save`
- Reboot

Docker, Komodo, and Periphery are **not** in cloud-config.

### Ansible — site.yml

Single playbook, single command: `ansible-playbook -i inventory/hosts site.yml`

**Play 1 — Server setup** (`hosts: servers`, `become: true`):
1. `import_tasks: tasks/docker.yml` — install Docker CE + compose plugin via official Docker apt repo
2. `import_tasks: tasks/komodo.yml` — write `/opt/komodo/compose.env` from `vars/komodo.yml`, run `docker compose up -d`

**Play 2 — Manual gate** (`hosts: localhost`):
3. `ansible.builtin.pause` — displays:
   > Komodo is running at `http://{{ groups['servers'][0] }}:9120`
   > Log in → Settings → Onboarding Keys → create a new key.
   > Paste the key here and press Enter:

   Registers the key as `onboarding_key`. The hostname is read from the `[servers]` inventory group, so no extra variable is needed.

**Play 3 — Periphery** (`hosts: servers`, `become: true`):
4. `import_tasks: tasks/periphery.yml` — runs the Komodo periphery setup script with `--core-address`, `--connect-as` (derived from inventory hostname), and `--onboarding-key` from the pause step; enables `periphery` systemd service

---

## Inventory

### inventory/hosts.example

```ini
# Copy this file to inventory/hosts (git-ignored) and fill in the real hostname.
# The hostname must be reachable over Tailscale (MagicDNS or IP).
#
#   cp inventory/hosts.example inventory/hosts
#   # Edit inventory/hosts and replace <server-tailscale-hostname>

[servers]
<server-tailscale-hostname> ansible_user=cloud_user
```

### inventory/.gitignore

```
hosts
```

`hosts` is gitignored so real hostnames are never committed. The `.example` file is the committed reference.

---

## Variables

### vars/komodo.example.yml

```yaml
# Copy to vars/komodo.yml (git-ignored) and fill in real values.
# Generate secrets with: openssl rand -hex 32
#
#   cp vars/komodo.example.yml vars/komodo.yml

komodo_database_password: "<mongo-password>"
komodo_jwt_secret: "<jwt-secret>"
komodo_webhook_secret: "<webhook-secret>"
komodo_admin_password: "<admin-password>"
```

### vars/.gitignore

```
komodo.yml
```

`site.yml` includes `vars/komodo.yml` via `vars_files`. If the file is missing, Ansible fails with a clear error pointing to the copy step.

---

## Running the Playbook

```bash
# 1. Copy and fill inventory
cp ansible/inventory/hosts.example ansible/inventory/hosts
# Edit ansible/inventory/hosts — replace <server-tailscale-hostname>

# 2. Copy and fill vars
cp ansible/vars/komodo.example.yml ansible/vars/komodo.yml
# Edit ansible/vars/komodo.yml — fill in secrets

# 3. Run
cd ansible
ansible-playbook -i inventory/hosts site.yml
```

Ansible connects over Tailscale SSH as `cloud_user`. No password or SSH key required — Tailscale handles auth.

---

## Manual Steps (Preserved in Playbook Flow)

The only manual step is creating the Komodo onboarding key. Ansible pauses and prompts for it inline — no need to open a second terminal or re-run the playbook.

All other previously manual post-provisioning steps (verifying Tailscale status, SSHing in, starting Komodo) are handled automatically by cloud-config and the playbook.

---

## What is Removed

- `cloud_setup/SERVER_SETUP.md` — replaced by `infrastructure/SERVER_SETUP.md`
- All Docker, Komodo, and Periphery `runcmd` entries from cloud-config
- All `write_files` entries for Komodo compose files from cloud-config (these move to Ansible)
