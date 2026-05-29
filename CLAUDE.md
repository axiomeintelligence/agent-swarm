# agent-swarm — CLAUDE.md

This file is the primary context document for AI assistants working in this repository.

## What this repo is

A collection of Dockerized AI agents and supporting infrastructure, designed as a template. Other repositories consume pre-built images from GHCR and extend the composition. The repo is hosted at `github.com/axiomeintelligence/agent-swarm` (private).

## Repo layout

```
agent-swarm/
├── devbot/              # Claude Code agent with web UI (port 3001)
├── assistant/           # Hermes AI gateway — three-container stack
│   ├── hermes/          # Thin wrapper on nousresearch/hermes-agent
│   ├── gbrain/          # G-Brain knowledge graph MCP (port 3131)
│   └── gdrive-mcp/      # Google Drive MCP via supergateway (port 3000)
├── infrastructure/
│   ├── cloud-config/    # cloud-init YAML for server first boot
│   └── ansible/         # Playbook: Docker + Komodo + Periphery
└── docs/superpowers/    # Design specs and implementation plans
```

## Git identity

- Remote alias: `github-axiome` (SSH key for `axiomeintelligence` org)
- GPG signing key: `12F838BB0FBEC036`
- Always sign commits: `git config commit.gpgsign true` is set on this repo

## Running the agents locally

### devbot

```bash
cd devbot
cp .env.example .env   # fill in GITHUB_PAT, GITHUB_REPO_URL
docker compose up -d
# Web UI at http://localhost:3001
```

### assistant (three containers)

```bash
cd assistant
cp .env.example .env   # fill in ANTHROPIC_API_KEY + platform tokens
docker compose up -d
# Hermes gateway at http://localhost:8642
```

Hermes depends on `gbrain` being healthy before it starts. `gdrive-mcp` is optional (requires `GOOGLE_SERVICE_ACCOUNT_JSON`); Hermes starts even if it is not healthy.

See `assistant/README.md` for full details.

---

## Infrastructure — Ansible playbook

### Purpose

The Ansible playbook in `infrastructure/ansible/` provisions a fresh Ubuntu 24.04 server with:

1. **Docker CE** (with compose plugin)
2. **Komodo Core + MongoDB** (container orchestration UI, port 9120)
3. **Komodo Periphery** (agent that connects the server to Komodo Core)

The server is accessed exclusively over Tailscale (no public SSH). All other configuration (Tailscale join, iptables hardening, unattended upgrades) is handled by `cloud-config/cloud-config.yml` on first boot.

### Prerequisites

- Ansible installed locally: `pip install ansible`
- Tailscale installed and connected locally
- Target server provisioned with `cloud-config/cloud-config.yml` (Tailscale joined, cloud-init complete)

### Step-by-step

#### 1. Prepare the server

In the cloud provider console, paste `infrastructure/cloud-config/cloud-config.yml` into the "User data" / "Cloud init" field when creating the instance. **Before pasting**, replace the one placeholder:

| Placeholder | Replace with |
|---|---|
| `<tailscale-auth-key>` | Auth key from https://login.tailscale.com/admin/settings/keys |

Apply the Tailscale-only cloud firewall (UDP 41641 inbound only). Wait ~2 minutes after instance creation for cloud-init to finish, then verify:

```bash
tailscale status   # server should appear with a MagicDNS hostname, e.g. hz-agents-0
```

#### 2. Create the inventory file

```bash
cd infrastructure/ansible
cp inventory/hosts.example inventory/hosts
```

Edit `inventory/hosts` — replace `<server-tailscale-hostname>` with the MagicDNS name from `tailscale status`:

```ini
[servers]
hz-agents-0 ansible_user=cloud_user
```

`inventory/hosts` is gitignored — never commit it.

#### 3. Create the vars file

```bash
cp vars/komodo.example.yml vars/komodo.yml
```

Edit `vars/komodo.yml` — generate each secret with `openssl rand -hex 32`:

```yaml
komodo_database_password: "<output of openssl rand -hex 32>"
komodo_jwt_secret:         "<output of openssl rand -hex 32>"
komodo_webhook_secret:     "<output of openssl rand -hex 32>"
komodo_admin_password:     "<output of openssl rand -hex 32>"
```

`vars/komodo.yml` is gitignored — never commit it.

#### 4. Run the playbook

```bash
ansible-playbook -i inventory/hosts site.yml
```

The playbook runs three plays in sequence:

**Play 1 — Install Docker + deploy Komodo** (automated):
- Installs Docker CE and compose plugin
- Deploys Komodo Core (port 9120) and MongoDB via docker compose under `/opt/komodo/`

**Play 2 — Collect onboarding key** (interactive pause):
- The playbook pauses and prints `http://<hostname>:9120`
- Open that URL in a browser (accessible over Tailscale)
- Register as the first user — first user gets admin rights automatically
- Go to **Settings → Onboarding Keys** → create a key (starts with `O-...`)
- Copy the key and paste it into the terminal prompt

**Play 3 — Install Periphery** (automated):
- Runs the official Komodo Periphery setup script on the server
- Periphery connects to Komodo Core using the onboarding key
- The server appears under **Servers** in the Komodo UI

### What the playbook does NOT do

- Does not configure Tailscale (cloud-config handles that)
- Does not deploy agent containers (use Komodo UI for that after setup)
- Does not configure Cloudflare Tunnels (manual step in Komodo or CF dashboard)

### Re-running the playbook

The playbook is idempotent for Docker and Komodo tasks. Periphery installation is skipped if `/usr/local/bin/periphery` already exists. Re-running is safe.

### File map

```
infrastructure/ansible/
├── site.yml                      # Entrypoint — three plays
├── inventory/
│   ├── hosts.example             # Template — copy to hosts and fill hostname
│   └── .gitignore                # Ignores hosts (real inventory)
├── tasks/
│   ├── docker.yml                # Play 1: install Docker CE
│   ├── komodo.yml                # Play 1: deploy Komodo + MongoDB
│   └── periphery.yml             # Play 3: install Periphery agent
├── templates/
│   └── komodo-compose.env.j2     # Jinja2 template for Komodo's compose.env
└── vars/
    ├── komodo.example.yml        # Template — copy to komodo.yml and fill secrets
    └── .gitignore                # Ignores komodo.yml (real secrets)
```

---

## Key constraints for AI assistants

- **Never commit** `infrastructure/ansible/inventory/hosts` or `infrastructure/ansible/vars/komodo.yml` — both are gitignored for a reason (hostnames and secrets).
- **Never commit** any `.env` files (only `.env.example` files are tracked).
- **Always sign commits** with GPG key `12F838BB0FBEC036`.
- **Use the `github-axiome` SSH remote** when pushing: `git@github-axiome:axiomeintelligence/agent-swarm.git`
- The pre-commit hook blocks commits when native Claude Code tasks are incomplete — mark all tasks done before committing.
- `infrastructure/ansible/tasks/periphery.yml` pins Periphery at `v2.2.0` — update intentionally, not as a side effect.

---

## CI/CD — published images

Three GitHub Actions workflows publish images to GHCR on push to `main`:

| Workflow | Trigger path | Image |
|---------|-------------|-------|
| `publish-assistant.yml` | `assistant/hermes/**` | `ghcr.io/axiomeintelligence/assistant` |
| `publish-gbrain.yml` | `assistant/gbrain/**` | `ghcr.io/axiomeintelligence/gbrain` |
| `publish-gdrive-mcp.yml` | `assistant/gdrive-mcp/**` | `ghcr.io/axiomeintelligence/gdrive-mcp` |
| `publish.yml` | `devbot/**` | `ghcr.io/axiomeintelligence/devbot` |

Images are tagged `latest` and `sha-<commit-sha>`. Consuming repos override via `ASSISTANT_IMAGE`, `GBRAIN_IMAGE`, `GDRIVE_MCP_IMAGE`, or `DEVBOT_IMAGE` env vars.

---

## GitOps Deploy Flow

Agent stacks are deployed from a downstream instance repo (e.g. `axiome_intelligence`) via Komodo Resource Sync.

**Flow on push to instance repo:**
1. Instance repo contains `agent-stacks/komodo.toml` (Komodo manifest) and `agent-stacks/<name>/.enc.env` (SOPS-encrypted secrets).
2. GitHub Actions workflow triggers on changes to `agent-stacks/**`.
3. Workflow joins the Tailnet using an ephemeral `tag:ci` auth key (preauthorized — bypasses device approval).
4. Workflow calls `POST /api/execute/RunProcedure` on the Komodo API at `http://<server-tailscale-hostname>:9120`.
5. Komodo pulls the instance repo → `on_pull` script decrypts secrets → Komodo redeploys the Stack from this repo.

**Required GitHub secrets in the instance repo:**

| Secret | Description |
|--------|-------------|
| `TAILSCALE_AUTH_KEY` | Ephemeral + preauthorized + `tag:ci`. Generate at Tailscale admin → Settings → Keys |
| `KOMODO_API_KEY` | From Komodo UI → Settings → API Keys |
| `KOMODO_URL` | `http://<server-tailscale-hostname>:9120` |

---

## Tailscale ACL Policy

`infrastructure/tailscale/acl-policy.example.hujson` is a ready-made policy template. Copy the relevant sections into the Tailscale admin console at `https://login.tailscale.com/admin/acls`.

**Tags defined:**
- `tag:agent-server` — apply to each provisioned server via the auth key at creation time (see SERVER_SETUP.md Step 1.3)
- `tag:ci` — apply to the GitHub Actions ephemeral auth key in the instance repo

GitHub Actions runners tagged `tag:ci` can reach `tag:agent-server:9120` (Komodo API) only. No SSH or other port access.
