# Assistant Agent Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create a public Docker image that runs Hermes Agent (Nous Research) as a self-hostable AI assistant reachable via Telegram, Slack, AgentMail/SMTP email, and CLI.

**Architecture:** New `assistant/` directory alongside `devbot/` in the same repo, built from `ubuntu:22.04`. Hermes Agent is installed via its official install script and runs as the foreground process. All platform credentials are passed as environment variables — Hermes reads them natively. An entrypoint script validates the AI provider key, maps AgentMail credentials to Hermes email env vars, and launches `hermes gateway`.

**Tech Stack:** Hermes Agent (Nous Research), mem0ai (Python), cloudflared, Ubuntu 22.04, GitHub Actions, GHCR

---

## File Map

| File | Action | Purpose |
|---|---|---|
| `assistant/Dockerfile` | Create | Ubuntu 22.04 image with Hermes + mem0ai + cloudflared |
| `assistant/scripts/entrypoint.sh` | Create | Validates env, maps AgentMail creds, starts Hermes gateway |
| `assistant/docker-compose.yml` | Create | Container orchestration, env pass-through, volume mounts |
| `assistant/.env.example` | Create | Fully documented env template with setup links |
| `.github/workflows/publish-assistant.yml` | Create | Builds and pushes assistant image to GHCR on push to main |
| `.github/workflows/publish.yml` | Modify | Add `paths: devbot/**` filter so it only fires on devbot changes |
| `README.md` | Modify | Add assistant quickstart section |

---

### Task 1: Dockerfile

**Goal:** Build a lean Ubuntu 22.04 image with Hermes Agent, mem0ai, and cloudflared installed, running as a non-root `assistant` user.

**Files:**
- Create: `assistant/Dockerfile`

**Acceptance Criteria:**
- [ ] `docker build -t assistant-test assistant/` exits 0
- [ ] `docker run --rm assistant-test hermes --version` prints a version string
- [ ] Image runs as non-root user `assistant`
- [ ] cloudflared is on PATH inside the container

**Verify:** `docker build -t assistant-test assistant/ && docker run --rm assistant-test whoami` → `assistant`

**Steps:**

- [ ] **Step 1: Create the `assistant/scripts/` directory**

```bash
mkdir -p assistant/scripts
```

- [ ] **Step 2: Create `assistant/Dockerfile`**

```dockerfile
FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=UTC

# System deps — curl/git for Hermes install, libsodium/dbus for Signal protocol
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    libsodium-dev \
    dbus-x11 \
    && rm -rf /var/lib/apt/lists/*

# Cloudflare Tunnel CLI via official Cloudflare apt repo
RUN curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null \
    && echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared jammy main' \
      | tee /etc/apt/sources.list.d/cloudflared.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends cloudflared \
    && rm -rf /var/lib/apt/lists/*

# Create non-root assistant user
RUN useradd -m -s /bin/bash assistant

# Entrypoint installed as root before user switch
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Switch to non-root user for Hermes installation
USER assistant
WORKDIR /home/assistant
ENV PATH="/home/assistant/.local/bin:${PATH}"

# Install Hermes Agent — non-interactive, skip setup wizard and browser engine
# Installs to ~/.hermes/hermes-agent with binary at ~/.local/bin/hermes
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
    | bash -s -- --skip-setup --skip-browser

# Install mem0ai into the Hermes Python virtual environment
RUN /home/assistant/.hermes/hermes-agent/.venv/bin/pip install --quiet mem0ai

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

- [ ] **Step 3: Create a stub entrypoint so the build doesn't fail (real entrypoint in Task 2)**

```bash
cat > assistant/scripts/entrypoint.sh << 'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
chmod +x assistant/scripts/entrypoint.sh
```

- [ ] **Step 4: Build the image and verify**

```bash
docker build -t assistant-test assistant/
```
Expected: build completes with exit code 0. The Hermes install step will take several minutes on first run.

- [ ] **Step 5: Verify Hermes is installed and user is non-root**

```bash
docker run --rm assistant-test whoami
```
Expected: `assistant`

```bash
docker run --rm assistant-test hermes --version
```
Expected: prints Hermes version string (e.g., `hermes 0.x.x`)

```bash
docker run --rm assistant-test which cloudflared
```
Expected: `/usr/bin/cloudflared`

- [ ] **Step 6: Commit**

```bash
git add assistant/Dockerfile assistant/scripts/entrypoint.sh
git commit -m "feat(assistant): add Dockerfile with Hermes, mem0ai, cloudflared"
```

---

### Task 2: Entrypoint Script

**Goal:** A bash entrypoint that validates the AI provider key, maps AgentMail credentials to Hermes email env vars, logs active platforms, optionally starts the Cloudflare tunnel, then launches `hermes gateway` as the foreground process.

**Files:**
- Modify: `assistant/scripts/entrypoint.sh`

**Acceptance Criteria:**
- [ ] Container exits 1 with a clear error if AI_PROVIDER is set but the corresponding key is missing
- [ ] AgentMail credentials are correctly mapped to Hermes EMAIL_* env vars
- [ ] Active platforms are logged on startup
- [ ] Hermes gateway starts as the foreground process (PID 1 via `exec`)
- [ ] Container starts cleanly in CLI-only mode when no platform tokens are set

**Verify:**
```bash
docker run --rm -e AI_PROVIDER=anthropic -e ANTHROPIC_API_KEY=test assistant-test /usr/local/bin/entrypoint.sh 2>&1 | head -5
```
Expected: logs show provider validated and "No messaging platforms configured — CLI only" before Hermes starts.

**Steps:**

- [ ] **Step 1: Write the full entrypoint script**

Replace `assistant/scripts/entrypoint.sh` with:

```bash
#!/usr/bin/env bash
set -euo pipefail

# ── 1. Validate AI provider key ───────────────────────────────────────────────
AI_PROVIDER="${AI_PROVIDER:-anthropic}"
case "$AI_PROVIDER" in
  anthropic)
    if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
      echo "[assistant] ERROR: AI_PROVIDER=anthropic but ANTHROPIC_API_KEY is not set."
      exit 1
    fi
    ;;
  openai)
    if [ -z "${OPENAI_API_KEY:-}" ]; then
      echo "[assistant] ERROR: AI_PROVIDER=openai but OPENAI_API_KEY is not set."
      exit 1
    fi
    ;;
  openrouter)
    if [ -z "${OPENROUTER_API_KEY:-}" ]; then
      echo "[assistant] ERROR: AI_PROVIDER=openrouter but OPENROUTER_API_KEY is not set."
      exit 1
    fi
    ;;
  *)
    echo "[assistant] ERROR: Unknown AI_PROVIDER '${AI_PROVIDER}'. Valid values: anthropic, openai, openrouter."
    exit 1
    ;;
esac
echo "[assistant] AI provider: ${AI_PROVIDER}"

# ── 2. Configure mem0 ─────────────────────────────────────────────────────────
if [ -n "${MEM0_API_KEY:-}" ]; then
  echo "[assistant] mem0: cloud storage"
else
  echo "[assistant] mem0: local storage at /home/assistant/.mem0"
  mkdir -p /home/assistant/.mem0
fi

# ── 3. Map AgentMail credentials to Hermes email env vars ─────────────────────
# AgentMail IMAP: imap.agentmail.to:993 (SSL) — username: inbox email, password: API key
# AgentMail SMTP: smtp.agentmail.to:465 (SSL) — username: agentmail, password: API key
if [ -n "${AGENTMAIL_API_KEY:-}" ] && [ -n "${AGENTMAIL_INBOX_EMAIL:-}" ]; then
  echo "[assistant] Email: AgentMail (${AGENTMAIL_INBOX_EMAIL})"
  export EMAIL_ADDRESS="${AGENTMAIL_INBOX_EMAIL}"
  export EMAIL_PASSWORD="${AGENTMAIL_API_KEY}"
  export EMAIL_IMAP_HOST="imap.agentmail.to"
  export EMAIL_IMAP_PORT="993"
  export EMAIL_SMTP_HOST="smtp.agentmail.to"
  export EMAIL_SMTP_PORT="465"
elif [ -n "${EMAIL_SMTP_HOST:-}" ] && [ -n "${EMAIL_ADDRESS:-}" ]; then
  echo "[assistant] Email: SMTP/IMAP (${EMAIL_SMTP_HOST})"
else
  echo "[assistant] Email: disabled"
fi

# ── 4. Log active platforms ───────────────────────────────────────────────────
PLATFORMS=()
[ -n "${TELEGRAM_BOT_TOKEN:-}" ] && PLATFORMS+=("Telegram")
[ -n "${SLACK_BOT_TOKEN:-}" ]    && PLATFORMS+=("Slack")
[ -n "${EMAIL_ADDRESS:-}" ]      && PLATFORMS+=("Email")

if [ ${#PLATFORMS[@]} -eq 0 ]; then
  echo "[assistant] No messaging platforms configured — CLI only"
  echo "[assistant] Attach a shell: docker exec -it \${HOSTNAME} hermes"
else
  echo "[assistant] Active platforms: ${PLATFORMS[*]}"
fi

# ── 5. Start Cloudflare Tunnel (if token provided) ────────────────────────────
if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
  echo "[assistant] Starting Cloudflare Tunnel ..."
  cloudflared tunnel run --token "${CLOUDFLARE_TUNNEL_TOKEN}" &
fi

# ── 6. Launch Hermes gateway (foreground) ─────────────────────────────────────
echo "[assistant] Starting Hermes gateway ..."
exec hermes gateway
```

- [ ] **Step 2: Rebuild the image with the new entrypoint**

```bash
docker build -t assistant-test assistant/
```
Expected: build succeeds.

- [ ] **Step 3: Verify exit-1 on missing key**

```bash
docker run --rm -e AI_PROVIDER=anthropic assistant-test 2>&1 | head -3
```
Expected output:
```
[assistant] ERROR: AI_PROVIDER=anthropic but ANTHROPIC_API_KEY is not set.
```

- [ ] **Step 4: Verify AgentMail credential mapping**

```bash
docker run --rm \
  -e AI_PROVIDER=anthropic \
  -e ANTHROPIC_API_KEY=sk-test \
  -e AGENTMAIL_API_KEY=agentmail-test-key \
  -e AGENTMAIL_INBOX_EMAIL=mybot@agentmail.to \
  assistant-test \
  bash -c 'source /usr/local/bin/entrypoint.sh 2>&1 || true' 2>&1 | grep -E "Email:|IMAP|SMTP"
```
Expected: `[assistant] Email: AgentMail (mybot@agentmail.to)`

- [ ] **Step 5: Verify CLI-only mode**

```bash
docker run --rm \
  -e AI_PROVIDER=anthropic \
  -e ANTHROPIC_API_KEY=sk-test \
  assistant-test \
  bash -c '/usr/local/bin/entrypoint.sh 2>&1 || true' | head -6
```
Expected lines include: `[assistant] No messaging platforms configured — CLI only`

- [ ] **Step 6: Commit**

```bash
git add assistant/scripts/entrypoint.sh
git commit -m "feat(assistant): add entrypoint with platform detection and AgentMail mapping"
```

---

### Task 3: docker-compose.yml

**Goal:** Compose file that wires all env vars through to the container, mounts Hermes config and mem0 data directories, and uses standardized `CONTAINER_NAME` / `HOST_PORT` naming.

**Files:**
- Create: `assistant/docker-compose.yml`

**Acceptance Criteria:**
- [ ] `docker compose config` in `assistant/` parses without errors
- [ ] Container name defaults to `assistant`, port defaults to `3002`
- [ ] Hermes config dir (`~/.hermes`) is persisted to host via volume mount
- [ ] mem0 local data dir (`~/.mem0`) is persisted to host via volume mount

**Verify:** `cd assistant && docker compose config | grep container_name` → `container_name: assistant`

**Steps:**

- [ ] **Step 1: Create `assistant/docker-compose.yml`**

```yaml
name: ${CONTAINER_NAME:-assistant}

services:
  assistant:
    # Pull the pre-built image from GHCR (default).
    # To build locally instead: docker compose up --build
    image: ghcr.io/axiomeintelligence/assistant:latest
    build: .
    container_name: ${CONTAINER_NAME:-assistant}
    hostname: ${CONTAINER_NAME:-assistant}
    restart: unless-stopped
    ports:
      - "${HOST_PORT:-3002}:8443"
    volumes:
      - ${ASSISTANT_HERMES_DIR:-./data/hermes}:/home/assistant/.hermes
      - ${ASSISTANT_MEM0_DIR:-./data/mem0}:/home/assistant/.mem0
    environment:
      - TZ=${TZ:-UTC}
      # ── AI model ────────────────────────────────────────────────────────────
      - AI_PROVIDER=${AI_PROVIDER:-anthropic}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
      # ── Memory ──────────────────────────────────────────────────────────────
      - MEM0_API_KEY=${MEM0_API_KEY:-}
      # ── Telegram ────────────────────────────────────────────────────────────
      - TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
      - TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}
      # ── Slack ───────────────────────────────────────────────────────────────
      - SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN:-}
      - SLACK_APP_TOKEN=${SLACK_APP_TOKEN:-}
      - SLACK_ALLOWED_USERS=${SLACK_ALLOWED_USERS:-}
      # ── AgentMail ───────────────────────────────────────────────────────────
      - AGENTMAIL_API_KEY=${AGENTMAIL_API_KEY:-}
      - AGENTMAIL_INBOX_EMAIL=${AGENTMAIL_INBOX_EMAIL:-}
      # ── Standard email (SMTP/IMAP fallback) ─────────────────────────────────
      - EMAIL_ADDRESS=${EMAIL_ADDRESS:-}
      - EMAIL_PASSWORD=${EMAIL_PASSWORD:-}
      - EMAIL_IMAP_HOST=${EMAIL_IMAP_HOST:-}
      - EMAIL_IMAP_PORT=${EMAIL_IMAP_PORT:-993}
      - EMAIL_SMTP_HOST=${EMAIL_SMTP_HOST:-}
      - EMAIL_SMTP_PORT=${EMAIL_SMTP_PORT:-587}
      - EMAIL_ALLOWED_USERS=${EMAIL_ALLOWED_USERS:-}
      - EMAIL_POLL_INTERVAL=${EMAIL_POLL_INTERVAL:-15}
      # ── Tunnel ──────────────────────────────────────────────────────────────
      - CLOUDFLARE_TUNNEL_TOKEN=${CLOUDFLARE_TUNNEL_TOKEN:-}
```

- [ ] **Step 2: Verify the compose file parses correctly**

```bash
cd assistant && docker compose config
```
Expected: full resolved config printed without errors.

- [ ] **Step 3: Verify container name and port defaults**

```bash
cd assistant && docker compose config | grep -E "container_name|published"
```
Expected:
```
container_name: assistant
published: "3002"
```

- [ ] **Step 4: Commit**

```bash
git add assistant/docker-compose.yml
git commit -m "feat(assistant): add docker-compose.yml"
```

---

### Task 4: .env.example

**Goal:** Fully documented environment template with setup links for every credential, using the standardized variable names decided in design.

**Files:**
- Create: `assistant/.env.example`

**Acceptance Criteria:**
- [ ] File contains every env var referenced in docker-compose.yml
- [ ] Every platform section has a setup link
- [ ] AgentMail and SMTP/IMAP sections are clearly separated with comments explaining which to use
- [ ] `CONTAINER_NAME` and `HOST_PORT` are present (not `ASSISTANT_NAME` / `ASSISTANT_HOST_PORT`)

**Verify:** `diff <(grep -oP '(?<=- )\w+(?==)' assistant/docker-compose.yml | sort -u) <(grep -oP '^\w+(?==)' assistant/.env.example | sort -u)` — no significant mismatches (some vars like `ASSISTANT_HERMES_DIR` are optional overrides).

**Steps:**

- [ ] **Step 1: Create `assistant/.env.example`**

```bash
cat > assistant/.env.example << 'ENVEOF'
# ── Identity ──────────────────────────────────────────────────────────────────
# Container name. Change for multiple instances on the same machine.
# Each instance also needs a unique HOST_PORT.
CONTAINER_NAME=assistant

# ── AI Model ──────────────────────────────────────────────────────────────────
# Get your Anthropic API key: https://console.anthropic.com/settings/keys
# Default provider is Anthropic Claude. Set AI_PROVIDER and the matching key.
AI_PROVIDER=anthropic             # anthropic | openai | openrouter
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
OPENROUTER_API_KEY=

# ── Memory (mem0) ─────────────────────────────────────────────────────────────
# Leave blank to use local file storage inside the container (./data/mem0 on host).
# Set MEM0_API_KEY to use mem0 cloud for cross-instance persistent memory: https://mem0.ai
MEM0_API_KEY=

# ── Platforms (all optional — leave blank to disable) ─────────────────────────
# Zero platforms configured = CLI-only mode (valid — attach via docker exec).
# Telegram, Slack, and Email are pre-configured here as the recommended defaults.

# Telegram
# Setup guide: https://core.telegram.org/bots#how-do-i-create-a-bot
TELEGRAM_BOT_TOKEN=               # From @BotFather on Telegram
TELEGRAM_ALLOWED_USERS=           # Comma-separated Telegram user IDs (leave blank = allow all)

# Slack
# Setup guide: https://api.slack.com/apps — create an app, enable Socket Mode,
# add bot scopes (chat:write, channels:history, channels:read), install to workspace
SLACK_BOT_TOKEN=                  # xoxb-... (OAuth & Permissions → Bot Token)
SLACK_APP_TOKEN=                  # xapp-... (Basic Information → App-Level Tokens)
SLACK_ALLOWED_USERS=              # Comma-separated Slack user IDs (leave blank = allow all)

# Email — AgentMail (recommended: gives the assistant its own @agentmail.to inbox)
# Setup guide: https://agentmail.to/docs
# 1. Create an account at https://console.agentmail.to
# 2. Create an inbox — note the full email address (e.g. mybot@agentmail.to)
# 3. Generate an API key under Dashboard → API Keys
AGENTMAIL_API_KEY=
AGENTMAIL_INBOX_EMAIL=            # e.g. mybot@agentmail.to

# Email — Standard SMTP/IMAP (use your own email account instead of AgentMail)
# Leave blank if using AgentMail above. Only one email source is used at a time.
EMAIL_ADDRESS=
EMAIL_PASSWORD=
EMAIL_IMAP_HOST=                  # e.g. imap.gmail.com
EMAIL_IMAP_PORT=993
EMAIL_SMTP_HOST=                  # e.g. smtp.gmail.com
EMAIL_SMTP_PORT=587
EMAIL_ALLOWED_USERS=              # Comma-separated allowed sender addresses (leave blank = allow all)
EMAIL_POLL_INTERVAL=15            # How often to check for new emails (seconds)

# Signal — not natively supported by Hermes; requires Signal-CLI bridge (future enhancement)

# ── Networking ────────────────────────────────────────────────────────────────
# Host port (only needed for Telegram webhook mode — polling mode requires no open port).
# Change when running multiple instances. devbot defaults to 3001, assistant to 3002.
HOST_PORT=3002

# Cloudflare Tunnel — exposes the assistant via a named tunnel (optional).
# Create a tunnel at: Cloudflare Zero Trust → Tunnels → Create a tunnel
CLOUDFLARE_TUNNEL_TOKEN=

# ── Storage overrides (optional) ──────────────────────────────────────────────
# Override where the assistant stores Hermes config and mem0 data on the host.
# Defaults to ./data/hermes and ./data/mem0 relative to the assistant/ directory.
ASSISTANT_HERMES_DIR=
ASSISTANT_MEM0_DIR=

# ── Runtime ───────────────────────────────────────────────────────────────────
TZ=UTC
ENVEOF
```

- [ ] **Step 2: Verify all docker-compose env vars are covered**

```bash
# Check that every ${VAR} in docker-compose.yml appears in .env.example
grep -oP '\$\{(\w+)' assistant/docker-compose.yml | grep -oP '\w+$' | sort -u
grep -oP '^\w+(?==)' assistant/.env.example | sort -u
```
Expected: all vars from docker-compose appear in .env.example (storage overrides like `ASSISTANT_HERMES_DIR` are optional extras — their absence from compose is intentional, they're passed to the container as default path overrides).

- [ ] **Step 3: Commit**

```bash
git add assistant/.env.example
git commit -m "feat(assistant): add .env.example with full documentation and setup links"
```

---

### Task 5: CI/CD Workflows

**Goal:** New `publish-assistant.yml` workflow that builds and pushes the assistant image to GHCR on push to main; existing `publish.yml` updated with a path filter so it only fires when `devbot/**` changes.

**Files:**
- Create: `.github/workflows/publish-assistant.yml`
- Modify: `.github/workflows/publish.yml`

**Acceptance Criteria:**
- [ ] `publish-assistant.yml` triggers only on changes under `assistant/**`
- [ ] `publish.yml` triggers only on changes under `devbot/**`
- [ ] Assistant image pushed as `ghcr.io/axiomeintelligence/assistant:latest` and `ghcr.io/axiomeintelligence/assistant:<sha>`
- [ ] Both workflow files pass `yamllint` or GitHub's syntax check

**Verify:** `cat .github/workflows/publish-assistant.yml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin); print('valid')"` → `valid`

**Steps:**

- [ ] **Step 1: Create `.github/workflows/publish-assistant.yml`**

```yaml
name: Publish assistant image

on:
  push:
    branches: [main]
    paths:
      - assistant/**

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v5
        with:
          context: assistant
          push: true
          tags: |
            ghcr.io/axiomeintelligence/assistant:latest
            ghcr.io/axiomeintelligence/assistant:${{ github.sha }}
```

- [ ] **Step 2: Add path filter to the existing devbot workflow**

Open `.github/workflows/publish.yml` and add `paths` under the push trigger:

```yaml
on:
  push:
    branches: [main]
    paths:
      - devbot/**
```

Full updated file:

```yaml
name: Publish devbot image

on:
  push:
    branches: [main]
    paths:
      - devbot/**

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4

      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - uses: docker/build-push-action@v5
        with:
          context: devbot
          push: true
          tags: |
            ghcr.io/axiomeintelligence/devbot:latest
            ghcr.io/axiomeintelligence/devbot:${{ github.sha }}
```

- [ ] **Step 3: Validate both workflow files**

```bash
python3 -c "
import yaml, sys
for f in ['.github/workflows/publish-assistant.yml', '.github/workflows/publish.yml']:
    yaml.safe_load(open(f))
    print(f'valid: {f}')
"
```
Expected:
```
valid: .github/workflows/publish-assistant.yml
valid: .github/workflows/publish.yml
```

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/publish-assistant.yml .github/workflows/publish.yml
git commit -m "ci: publish assistant image to GHCR, add devbot path filter"
```

---

### Task 6: README Update

**Goal:** Add an `assistant/` section to the main README so users who discover the repo can understand and run the assistant without needing to read the spec.

**Files:**
- Modify: `README.md`

**Acceptance Criteria:**
- [ ] README has a distinct `assistant/` section separate from the `devbot/` section
- [ ] Quickstart covers: clone → cp .env.example → fill in keys → docker compose up
- [ ] Environment variable table lists all key variables with descriptions
- [ ] Pull image line references `ghcr.io/axiomeintelligence/assistant:latest`
- [ ] Signal is noted as a future enhancement (not listed as available)

**Verify:** `grep -c "assistant" README.md` → greater than 5

**Steps:**

- [ ] **Step 1: Append assistant section to `README.md`**

Add after the existing devbot section:

```markdown
---

## `assistant/` — Hermes AI Gateway

A self-hostable AI assistant powered by [Hermes Agent](https://github.com/NousResearch/hermes-agent) (Nous Research), reachable via Telegram, Slack, and email. Persistent memory via [mem0](https://mem0.ai).

Pre-built image: `ghcr.io/axiomeintelligence/assistant:latest`

---

### What's inside

**`assistant/`** — A Hermes Agent container with:
- [Hermes Agent](https://github.com/NousResearch/hermes-agent) — AI assistant runtime (Telegram, Slack, email, CLI)
- [mem0](https://mem0.ai) — persistent memory (local file or cloud)
- Cloudflare CLI (`cloudflared`) for optional tunnel support
- Supports any LLM provider: Anthropic Claude (default), OpenAI, OpenRouter

---

### Quickstart

```bash
cd assistant
cp .env.example .env
# Edit .env — set ANTHROPIC_API_KEY and at least one platform token
docker compose up -d
```

Attach a CLI shell:
```bash
docker exec -it assistant hermes
```

Follow logs:
```bash
docker logs -f assistant
```

---

### Environment variables

See [`assistant/.env.example`](assistant/.env.example) for the full list with descriptions and setup links.

Key variables:

| Variable | Required | Description |
|---|---|---|
| `ANTHROPIC_API_KEY` | Yes (default) | API key for Anthropic Claude |
| `AI_PROVIDER` | No | Model provider: `anthropic` \| `openai` \| `openrouter` (default: `anthropic`) |
| `MEM0_API_KEY` | No | mem0 cloud key — leave blank for local storage |
| `TELEGRAM_BOT_TOKEN` | No | Enable Telegram — from @BotFather |
| `SLACK_BOT_TOKEN` | No | Enable Slack — from Slack app settings |
| `AGENTMAIL_API_KEY` | No | Enable email via AgentMail (recommended) |
| `AGENTMAIL_INBOX_EMAIL` | No | Inbox address from AgentMail console |
| `CONTAINER_NAME` | No | Container name (default: `assistant`) |
| `HOST_PORT` | No | Host port (default: `3002`) |
| `CLOUDFLARE_TUNNEL_TOKEN` | No | Expose assistant via Cloudflare Tunnel |

---

### Running alongside devbot

Both containers can run simultaneously. Use different `CONTAINER_NAME` and `HOST_PORT` values in each `.env`:

```bash
# devbot/.env
CONTAINER_NAME=devbot
HOST_PORT=3001

# assistant/.env
CONTAINER_NAME=assistant
HOST_PORT=3002
```

Start each from its own directory:
```bash
cd devbot && docker compose up -d
cd assistant && docker compose up -d
```

---

### Signal support

Signal is not currently supported natively by Hermes Agent. Signal-CLI bridge support is planned as a future enhancement.
```

- [ ] **Step 2: Verify README has the assistant section**

```bash
grep -c "assistant" README.md
```
Expected: greater than 5

```bash
grep "ghcr.io/axiomeintelligence/assistant" README.md
```
Expected: at least one match.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: add assistant agent section to README"
```

---

## Self-Review Notes

**Spec coverage check:**
- ✅ Ubuntu 22.04 base (not extending devbot) — Task 1 Dockerfile
- ✅ Hermes Agent as primary runtime — Task 1 + Task 2
- ✅ mem0 installed — Task 1 Dockerfile; configured in Task 2 entrypoint
- ✅ Telegram, Slack, AgentMail/email support — Task 2 + Task 3 + Task 4
- ✅ Signal noted as opt-in/future — Task 4 .env.example + Task 6 README
- ✅ AI provider configurable, defaults to Anthropic — Task 2, 3, 4
- ✅ CONTAINER_NAME / HOST_PORT standardization — Task 3, 4
- ✅ `ghcr.io/axiomeintelligence/assistant:latest` + sha tag — Task 5
- ✅ Path-filtered CI (assistant/** and devbot/**) — Task 5
- ✅ Public documentation — Task 6

**Signal clarification:** Hermes Agent does not natively support Signal. Signal is noted in `.env.example` and README as a future enhancement requiring a Signal-CLI bridge sidecar, which is out of scope for this implementation.
