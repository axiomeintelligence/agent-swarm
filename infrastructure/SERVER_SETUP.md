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
