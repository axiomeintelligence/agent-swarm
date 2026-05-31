# Server Setup

## Security

### Overview

Access to the server instance is locked down to the Tailscale VPN. A Cloud Firewall restricts all inbound traffic to only what Tailscale requires, preventing any direct public access to the server or its services. iptables running on the server instance additionally blocks inbound traffic, providing a layer of defense in depth in case of misconfiguration.

Note that all outbound ports are open, to facilitate cloudflared, tailscale, and updates.

Cloudflare Tunnels are used to access individual services, and must be protected with sufficient Cloudflare Access policies to control access. SSO and MFA is recommended.

NOTE: OpenSSH is disabled — Tailscale SSH is the only access path, available over the Tailscale network only. Appropriate Tailscale ACLs should be implemented to prevent privilege escalation.

Emergency access is available via the Cloud's VNC to fix any Tailscale misconfiguration.

### Administering the Server

All server administration is done over the Tailscale network. Install the Tailscale client on any device you want to administer the server from:

- **macOS:** https://tailscale.com/download/macos
- **Android/iOS:** Available in respective app stores (optional)

Services running on the server are accessed directly over the Tailscale network via MagicDNS hostname. No public ports are exposed for services.

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

> **Tag the server:** When generating the auth key, expand **Tags** and add `tag:agent-server`. This allows the Tailscale ACL policy (`infrastructure/tailscale/acl-policy.example.hujson`) to correctly scope access to this server. The tag is applied at join time — no manual step needed after provisioning.

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

All other configuration (Docker, orchestrator, agents) is handled by Ansible after first boot.

---

### 5. Post-Boot: Verify Node is Online

After provisioning, wait ~2 minutes for cloud-init to complete, then run from your local machine:

```bash
tailscale status
```

The server should appear with a MagicDNS hostname (e.g. `hz-agents-0`).

---

### 5.1 Accept the Tailscale SSH Host Key

Before Ansible can connect, you must manually SSH in once to accept the server's host key.

```bash
ssh cloud_user@<tailscale-hostname>
```

**If Tailscale prompts for additional SSH checks:**
Tailscale may open a browser window or print a URL asking you to approve the SSH connection in the admin console. Follow the prompt, approve the check at https://login.tailscale.com/admin/machines, then re-run the SSH command.

**If you see a host key conflict** (`WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED`):
A previous server used the same Tailscale hostname. Remove the stale entry:

```bash
ssh-keygen -R <tailscale-hostname>
```

Once you have successfully connected and see the shell prompt, type `exit`. Ansible can now connect without further prompts.

---

### 6. Ansible Prerequisites

Install Ansible locally if you haven't already:

```bash
pip install ansible
```

Copy and fill the inventory file:

```bash
cd infrastructure/ansible
cp inventory/hosts.example inventory/hosts
# Edit inventory/hosts — replace <server-tailscale-hostname> with the MagicDNS hostname from Step 5
# Example: hz-agents-0 ansible_user=cloud_user
```

> `inventory/hosts` is gitignored — never committed.

---

### 7. Next Steps — Choose Your Orchestrator

Follow the guide for your chosen orchestrator:

- **[Arcane Setup](ARCANE_SETUP.md)** — lightweight single-container orchestrator (recommended)
- **[Komodo Setup](KOMODO_SETUP.md)** — full-featured orchestrator with MongoDB and GitOps sync
