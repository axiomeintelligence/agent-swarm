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

All other configuration (Docker, Komodo, Periphery) is handled by Ansible after first boot.

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
# Find and delete the conflicting line — the error output will tell you the exact line number
nano ~/.ssh/known_hosts
# Delete the line for <tailscale-hostname>, save, and re-run ssh
```

Or use `ssh-keygen` to remove it directly:

```bash
ssh-keygen -R <tailscale-hostname>
```

Once you have successfully connected and see the shell prompt, type `exit`. Ansible can now connect without further prompts.

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

---

### 7. SOPS Secret Management

Stack-level secrets are committed to the instance repo as SOPS-encrypted `.enc.env` files and decrypted on the server by Komodo's Repo `on_pull` hook.

**Prerequisites — install locally:**

```bash
brew install age sops   # macOS
```

**Setup for a new server:**

```bash
# 1. Generate an age keypair (run on your local machine — not on the server)
age-keygen
# Output:
#   # created: 2026-05-29T00:00:00Z
#   # public key: age1xxxx...
#   AGE-SECRET-KEY-1yyyy...

# 2. Add the PRIVATE key to ansible/vars/komodo.yml under age_private_key
#    (git-ignored — never commit this file)

# 3. Add the PUBLIC key to the instance repo's .sops.yaml:
#    - path_regex: ^agent-stacks/<stack-name>/.*\.enc\.env$
#      age: age1xxxx...

# 4. Re-run the Ansible playbook (or just the sops task):
ansible-playbook -i inventory/hosts site.yml --tags sops
# This installs sops and writes the age private key to /root/.config/sops/age/keys.txt
```

The age private key is written to `/root/.config/sops/age/keys.txt` by the `sops.yml` Ansible task. Komodo's `on_pull` script calls `sops --decrypt`, which reads the key from that path automatically.

**Editing encrypted secrets:**

```bash
# From the instance repo (e.g. axiome_intelligence):
sops agent-stacks/<stack-name>/.enc.env
# Opens in $EDITOR — save to re-encrypt automatically
```

---

### 8. Komodo Stack Setup (Instance Repo)

This step configures Komodo to watch your instance repo and deploy stacks from it. Complete this after the server is running (Steps 1–6) and SOPS is configured (Step 7).

#### 8.1 Create the instance repo

Fork or derive an instance repo (e.g. `your-org/your-instance`) — this holds your Komodo resource manifest and encrypted stack secrets. The `agent-stacks/` directory structure is:

```
agent-stacks/
├── komodo.toml          # Komodo Resource Sync manifest
├── <stack-name>/
│   └── .enc.env         # SOPS-encrypted env file for the stack
└── ...
```

#### 8.2 Configure komodo.toml

Copy and adapt `agent-stacks/komodo.toml` from this template. Key values to update:

| Field | Description |
|---|---|
| `Repo.config.server` | MagicDNS hostname of your Komodo server (e.g. `hz-agents-0`) |
| `Repo.config.repo` | `your-org/your-instance` |
| `Stack.config.server` | Same MagicDNS hostname |
| `Stack.config.repo` | The stack's docker compose repo (e.g. `your-org/axiome-agent-swarm`) |
| `on_clone.command` / `on_pull.command` | Adjust paths to match actual Komodo repo/stack directories on the server |

> **Verify on-server paths before first deploy.** Komodo clones repos and stores stack files under paths configured in its settings. Check the actual directories (`ls /root/repos/` and `ls /root/stacks/` are common defaults) and update the `on_pull` decrypt command accordingly.

#### 8.3 Create and encrypt the stack env file

```bash
# 1. Copy the template and fill in values
cp /tmp/your-stack.env agent-stacks/<stack-name>/.enc.env

# 2. Encrypt in-place (requires .sops.yaml with your age public key)
sops --encrypt --in-place agent-stacks/<stack-name>/.enc.env

# 3. Commit
git add agent-stacks/<stack-name>/.enc.env
git commit -m "feat: add encrypted <stack-name> env"
git push
```

The decrypted `.env` is never committed — only the SOPS-encrypted `.enc.env`.

#### 8.4 Register the Resource Sync in Komodo

1. Open Komodo UI → **Resource Sync** → **Add Sync**
2. Set **Repo** to your instance repo and **Branch** to `main`
3. Set **Resource path** to `agent-stacks/komodo.toml`
4. Save — Komodo will import the Repo, Stack, and Procedure resources defined in the manifest

#### 8.5 Verify the first deploy

1. In Komodo UI → **Procedures** → open `deploy-<stack-name>` → **Run**
2. Check the run log — the `on_pull` decrypt step runs first, then the stack deploys
3. Confirm the stack appears under **Stacks** with status Running

---

### 9. GitHub Actions — Automatic Deploys

After every push to `agent-stacks/**` in the instance repo, a GitHub Actions workflow automatically triggers the Komodo deploy procedure over the Tailnet.

#### 9.1 Create a Tailscale auth key for CI

1. Go to https://login.tailscale.com/admin/settings/keys
2. Click **Generate auth key**
3. Enable **Ephemeral** (runner node is removed after the job) and **Pre-authorized**
4. Expand **Tags** and add `tag:ci`
5. Copy the key

> The `tag:ci` tag restricts this key per the ACL policy in `infrastructure/tailscale/acl-policy.example.hujson` — it can only reach Komodo on port 9120, not SSH or other services.

#### 9.2 Get your Komodo API key

1. Open Komodo UI → click your **username/avatar** in the sidebar (bottom-left)
2. Go to your **Profile** page → **API Keys** → **Create**
3. Komodo displays two fields: **Key ID** and **Secret** — combine them as `<key-id>/<secret>` (forward slash separator) when setting the GitHub secret. Neither field alone is sufficient.

#### 9.3 Add GitHub secrets

In your instance repo → **Settings** → **Secrets and variables** → **Actions**:

| Secret | Value |
|---|---|
| `TAILSCALE_AUTH_KEY` | Auth key from Step 9.1 |
| `KOMODO_URL` | `http://<server-tailscale-hostname>:9120` |
| `KOMODO_API_KEY` | API key from Step 9.2 |

Or via CLI:

```bash
gh secret set TAILSCALE_AUTH_KEY --repo your-org/your-instance
gh secret set KOMODO_URL         --repo your-org/your-instance
gh secret set KOMODO_API_KEY     --repo your-org/your-instance
```

#### 9.4 Verify the workflow

Push any change to `agent-stacks/` and check **Actions** in your repo. The workflow:
1. Joins the Tailnet as an ephemeral `tag:ci` node
2. POSTs to Komodo's `RunProcedure` endpoint
3. Komodo pulls the repo (decrypting secrets via `on_pull`) and redeploys the stack

> The workflow file is at `.github/workflows/komodo-deploy.yml` in the instance repo. Adapt the procedure name (`deploy-axiome`) to match what you defined in `komodo.toml`.
