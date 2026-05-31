# Arcane Setup

[Arcane](https://getarcane.app) is a lightweight Docker orchestration UI — single container, no external database, edge-mode agent for remote hosts.

**Prerequisites:** Complete [SERVER_SETUP.md](SERVER_SETUP.md) steps 1–6 first (server online, inventory ready).

---

## 1. Prepare Vars

```bash
cd infrastructure/ansible
cp vars/arcane.example.yml vars/server.yml
# Edit vars/server.yml — generate each secret with: openssl rand -hex 32
```

Key fields:

| Field | Description |
|---|---|
| `arcane_encryption_key` | 32-byte hex key (`openssl rand -hex 32`) |
| `arcane_jwt_secret` | JWT signing secret (`openssl rand -hex 32`) |
| `arcane_puid` / `arcane_pgid` | UID/GID for the Arcane container (default: 1000) |
| `age_private_key` | Age private key for SOPS decryption (see [SOPS Setup](#3-sops-setup)) |

> `vars/server.yml` is gitignored — never committed.

---

## 2. Run the Playbook

```bash
ansible-playbook -i inventory/hosts site.yml
```

This installs Docker, configures SOPS, and deploys Arcane. The playbook reads `orchestrator: arcane` from `vars/server.yml` and skips all Komodo plays automatically.

**Targeted re-runs:**

| Command | What it runs |
|---|---|
| `--tags docker` | Reinstall Docker |
| `--tags sops` | Update SOPS / age key |
| `--tags arcane` | Redeploy Arcane only |

---

## 3. First Login

Open `http://<server-tailscale-hostname>:3552` in your browser (accessible over Tailscale).

- Default credentials: `admin` / `admin`
- **Change the password immediately** under your profile settings

Arcane manages the local Docker environment via the mounted Docker socket — no agent registration needed for the host server.

---

## 4. SOPS Setup

Stack-level secrets are committed to the instance repo as SOPS-encrypted `.enc.env` files and decrypted on the server at deploy time.

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

# 2. Add the PRIVATE key to vars/server.yml under age_private_key
#    (git-ignored — never commit this file)

# 3. Add the PUBLIC key to the instance repo's .sops.yaml:
#    - path_regex: ^agent-stacks/<stack-name>/.*\.enc\.env$
#      age: age1xxxx...

# 4. Re-run the sops task to write the key to the server:
ansible-playbook -i inventory/hosts site.yml --tags sops
```

**Editing encrypted secrets:**

```bash
# From the instance repo:
sops agent-stacks/<stack-name>/.enc.env
# Opens in $EDITOR — save to re-encrypt automatically
```

---

## 5. Adding Remote Hosts

To manage additional Docker hosts from Arcane, deploy the Arcane Agent in **Edge** mode on each remote server:

```yaml
# docker-compose.yml on the remote host
services:
  arcane-agent:
    image: ghcr.io/getarcaneapp/arcane-headless:latest
    restart: unless-stopped
    environment:
      EDGE_AGENT: "true"
      AGENT_TOKEN: "<token-from-arcane-ui>"
      MANAGER_API_URL: "http://<arcane-server-tailscale-hostname>:3552"
      EDGE_TRANSPORT: auto
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
```

Generate the `AGENT_TOKEN` in Arcane UI → **Environments** → **Add Environment** → copy the token from the generated snippet.
