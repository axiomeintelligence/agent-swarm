# Komodo Setup

[Komodo](https://komo.do) is a full-featured Docker orchestration platform with MongoDB, GitOps Resource Sync, and a Periphery agent for managed servers.

**Prerequisites:** Complete [SERVER_SETUP.md](SERVER_SETUP.md) steps 1–6 first (server online, inventory ready).

---

## 1. Prepare Vars

```bash
cd infrastructure/ansible
cp vars/komodo.example.yml vars/komodo.yml
# Edit vars/komodo.yml — generate each secret with: openssl rand -hex 32
```

Key fields:

| Field | Description |
|---|---|
| `komodo_database_password` | MongoDB password (`openssl rand -hex 32`) |
| `komodo_jwt_secret` | JWT signing secret (`openssl rand -hex 32`) |
| `komodo_webhook_secret` | Webhook HMAC secret (`openssl rand -hex 32`) |
| `komodo_admin_password` | Initial admin password |
| `komodo_github_username` | GitHub username for private repo access |
| `komodo_github_pat` | GitHub PAT for private repo access |
| `age_private_key` | Age private key for SOPS decryption (see [SOPS Setup](#4-sops-setup)) |

> `vars/komodo.yml` is gitignored — never committed.

---

## 2. Run the Playbook

```bash
ansible-playbook -i inventory/hosts komodo.yml
```

This deploys Komodo (Core + MongoDB), pauses for the Periphery onboarding key, and installs Periphery.

The playbook will **pause** mid-run:

1. Open `http://<hostname>:9120` in your browser (accessible over Tailscale)
2. Register as the first user — first user receives admin rights automatically
3. Go to **Settings → Onboarding Keys** → create a new key (starts with `O-...`)
4. Copy it immediately (shown only once)
5. Paste it into the terminal prompt

The server will appear under **Servers** in the Komodo UI within seconds of Periphery registering.

**Targeted re-runs:**

| Command | What it runs |
|---|---|
| `--tags komodo` | Redeploy Komodo Core + MongoDB |
| `--tags periphery` | Rerun Periphery onboarding |
| `--tags resource-sync` | Rerun Resource Sync bootstrap |
| `--tags teardown` | Remove Komodo entirely (see [Teardown](#6-teardown)) |

**Re-running Periphery with a known onboarding key** (skips the pause):

```bash
ansible-playbook -i inventory/hosts komodo.yml --tags periphery --extra-vars "onboarding_key=O-your-key"
```

---

## 3. Komodo Stack Setup (Instance Repo)

This step configures Komodo to watch your instance repo and deploy stacks from it. Complete this after the server is running and SOPS is configured.

### 3.1 Create the instance repo

Fork or derive an instance repo (e.g. `your-org/your-instance`) — this holds your Komodo resource manifest and encrypted stack secrets:

```
agent-stacks/
├── komodo.toml          # Komodo Resource Sync manifest
├── <stack-name>/
│   └── .enc.env         # SOPS-encrypted env file for the stack
└── ...
```

### 3.2 Configure komodo.toml

Copy and adapt `agent-stacks/komodo.toml`. Key values to update:

| Field | Description |
|---|---|
| `Repo.config.server` | MagicDNS hostname of your Komodo server (e.g. `hz-agents-0`) |
| `Repo.config.repo` | `your-org/your-instance` |
| `Stack.config.server` | Same MagicDNS hostname |
| `Stack.config.repo` | The stack's docker compose repo |
| `on_pull.command` | Adjust paths to match actual Komodo repo/stack directories on the server |

### 3.3 Create and encrypt the stack env file

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

### 3.4 Register the Resource Sync

Fill in the Resource Sync vars in `vars/komodo.yml`, then run:

```bash
ansible-playbook -i inventory/hosts komodo.yml --tags resource-sync
```

This authenticates to Komodo, creates the sync if it doesn't exist, and runs the initial sync.

**Manual fallback (UI):**

1. Komodo UI → **Resource Sync** → **New Resource Sync**
2. Fill in: Name, Repo (`your-org/your-instance`), Branch (`main`), Resource path (`agent-stacks/komodo.toml`)
3. Click **Save**, then **Sync**

### 3.5 Verify the first deploy

1. Komodo UI → **Procedures** → open `deploy-<client-name>-swarm` → **Run**
2. Check the run log — the `on_pull` decrypt step runs first, then the stack deploys
3. Confirm the stack appears under **Stacks** with status Running

---

## 4. SOPS Setup

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

## 5. GitHub Actions — Automatic Deploys

After every push to `agent-stacks/**` in the instance repo, a GitHub Actions workflow automatically triggers the Komodo deploy procedure over the Tailnet.

### 5.1 Create a Tailscale auth key for CI

1. Go to https://login.tailscale.com/admin/settings/keys
2. Click **Generate auth key**
3. Enable **Ephemeral** and **Pre-authorized**
4. Expand **Tags** and add `tag:ci`
5. Copy the key

> The `tag:ci` tag restricts this key per the ACL policy in `infrastructure/tailscale/acl-policy.example.hujson` — it can only reach Komodo on port 9120.

### 5.2 Get your Komodo API key

1. Komodo UI → click your **username/avatar** (bottom-left) → **Profile** → **API Keys** → **Create**
2. Komodo displays **Key ID** and **Secret** — store these as separate GitHub secrets

### 5.3 Add GitHub secrets

In your instance repo → **Settings** → **Secrets and variables** → **Actions**:

| Secret | Value |
|---|---|
| `TAILSCALE_AUTH_KEY` | Auth key from Step 5.1 |
| `KOMODO_URL` | `http://<server-tailscale-hostname>:9120` |
| `KOMODO_API_KEY` | Key ID from Komodo Profile → API Keys |
| `KOMODO_API_SECRET` | Secret from Komodo Profile → API Keys |

```bash
gh secret set TAILSCALE_AUTH_KEY --repo your-org/your-instance
gh secret set KOMODO_URL         --repo your-org/your-instance
gh secret set KOMODO_API_KEY     --repo your-org/your-instance
gh secret set KOMODO_API_SECRET  --repo your-org/your-instance
```

### 5.4 Verify the workflow

Push any change to `agent-stacks/` and check **Actions** in your repo. The workflow:
1. Joins the Tailnet as an ephemeral `tag:ci` node
2. POSTs to Komodo's `RunProcedure` endpoint
3. Komodo pulls the repo (decrypting secrets via `on_pull`) and redeploys the stack

---

## 6. Teardown

To remove Komodo from the server (stops containers, removes Periphery binary and service, deletes `/opt/komodo` and `/etc/komodo`, removes the port 9120 firewall rule):

```bash
ansible-playbook -i inventory/hosts komodo.yml --tags teardown
```

After teardown you can deploy a different orchestrator — e.g. `ansible-playbook -i inventory/hosts arcane.yml`.
