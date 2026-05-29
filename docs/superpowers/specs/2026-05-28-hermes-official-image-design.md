# Hermes Official Image Migration Design

**Date:** 2026-05-28
**Status:** Approved

## Overview

Migrate the `assistant/` stack from a from-scratch ubuntu-based build to a three-container composition that pulls the official `nousresearch/hermes-agent` image. Replace mem0 with G-Brain (knowledge graph MCP). Add Google Drive MCP as a sidecar. Drop AgentMail, cloudflared, and all custom entrypoint logic.

---

## Architecture

Three containers on a shared Docker network (`assistant-net`):

```
┌─────────────────────────────────────────────────────┐
│                  assistant-net                       │
│                                                      │
│  ┌──────────────────┐   MCP/HTTP  ┌──────────────┐  │
│  │     hermes       │────────────▶│    gbrain    │  │
│  │                  │             │  (port 3333) │  │
│  │  thin wrapper    │   MCP/HTTP  └──────────────┘  │
│  │  on official     │────────────▶┌──────────────┐  │
│  │  Hermes image    │             │  gdrive-mcp  │  │
│  │                  │             │  (port 3000) │  │
│  └──────────────────┘             └──────────────┘  │
│         │ :8642                                      │
└─────────┼───────────────────────────────────────────┘
          │ (host: HOST_PORT)
```

- **hermes** — Thin `FROM nousresearch/hermes-agent:latest` wrapper. Adds a single s6 `cont-init.d` script that writes MCP server registrations into `/opt/data/config.yaml` on first boot. Gmail wired via standard IMAP/SMTP env vars. Published to GHCR by CI.
- **gbrain** — G-Brain knowledge graph MCP server. `FROM oven/bun:1`, installs from `github:garrytan/gbrain` pinned via `GBRAIN_REF` build arg. Runs HTTP MCP mode on port 3333. Published to GHCR by CI.
- **gdrive-mcp** — Google Drive MCP server. `FROM node:22-slim`, Google Drive MCP package (candidate: `@modelcontextprotocol/server-gdrive` — confirm package name and HTTP mode support during implementation). Authenticates via service account JSON env var. HTTP MCP on port 3000. Published to GHCR by CI.

---

## File Structure

### What is removed

- `assistant/Dockerfile` (ubuntu from-scratch build)
- `assistant/scripts/entrypoint.sh` (AgentMail mapping, cloudflared, mem0 logic)

### New layout

```
assistant/
├── hermes/
│   ├── Dockerfile              ← FROM nousresearch/hermes-agent:latest
│   └── scripts/
│       └── init-mcp.sh         ← s6 cont-init.d script
├── gbrain/
│   └── Dockerfile              ← FROM oven/bun:1, GBRAIN_REF build arg
├── gdrive-mcp/
│   └── Dockerfile              ← FROM node:22-slim
├── docker-compose.yml          ← composes all three services
└── .env.example                ← updated env vars
```

---

## docker-compose.yml

All image references are overridable via env vars — consuming repos can pin to specific SHA tags without modifying the compose file:

```yaml
services:
  hermes:
    image: ${ASSISTANT_IMAGE:-ghcr.io/axiomeintelligence/assistant:latest}
    build:
      context: ./hermes
    container_name: ${CONTAINER_NAME:-assistant}
    restart: unless-stopped
    depends_on:
      gbrain:
        condition: service_healthy
      gdrive-mcp:
        condition: service_healthy
    ports:
      - "${HOST_PORT:-8642}:8642"
    volumes:
      - ./data/${CONTAINER_NAME:-assistant}/hermes:/opt/data
    networks:
      - assistant-net
    environment:
      # AI provider
      - AI_PROVIDER=${AI_PROVIDER:-anthropic}
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}
      - OPENROUTER_API_KEY=${OPENROUTER_API_KEY:-}
      # Messaging platforms
      - TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
      - TELEGRAM_ALLOWED_USERS=${TELEGRAM_ALLOWED_USERS:-}
      - SLACK_BOT_TOKEN=${SLACK_BOT_TOKEN:-}
      - SLACK_APP_TOKEN=${SLACK_APP_TOKEN:-}
      - SLACK_ALLOWED_USERS=${SLACK_ALLOWED_USERS:-}
      # Gmail (IMAP/SMTP)
      - EMAIL_ADDRESS=${EMAIL_ADDRESS:-}
      - EMAIL_PASSWORD=${EMAIL_PASSWORD:-}
      - EMAIL_IMAP_HOST=${EMAIL_IMAP_HOST:-}
      - EMAIL_IMAP_PORT=${EMAIL_IMAP_PORT:-993}
      - EMAIL_SMTP_HOST=${EMAIL_SMTP_HOST:-}
      - EMAIL_SMTP_PORT=${EMAIL_SMTP_PORT:-587}
      - EMAIL_ALLOWED_USERS=${EMAIL_ALLOWED_USERS:-}
      - EMAIL_POLL_INTERVAL=${EMAIL_POLL_INTERVAL:-15}
      - TZ=${TZ:-UTC}

  gbrain:
    image: ${GBRAIN_IMAGE:-ghcr.io/axiomeintelligence/gbrain:latest}
    build:
      context: ./gbrain
      args:
        GBRAIN_REF: ${GBRAIN_REF:-main}
    container_name: ${CONTAINER_NAME:-assistant}-gbrain
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3333/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    volumes:
      - ./data/${CONTAINER_NAME:-assistant}/gbrain:/data
    networks:
      - assistant-net
    environment:
      - OPENAI_API_KEY=${OPENAI_API_KEY:-}

  gdrive-mcp:
    image: ${GDRIVE_MCP_IMAGE:-ghcr.io/axiomeintelligence/gdrive-mcp:latest}
    build:
      context: ./gdrive-mcp
    container_name: ${CONTAINER_NAME:-assistant}-gdrive-mcp
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:3000/health"]
      interval: 10s
      timeout: 5s
      retries: 5
    networks:
      - assistant-net
    environment:
      - GOOGLE_SERVICE_ACCOUNT_JSON=${GOOGLE_SERVICE_ACCOUNT_JSON:-}

networks:
  assistant-net:
```

---

## Data Volumes

All state is scoped under `./data/${CONTAINER_NAME}/` so multiple instances on the same host are immediately distinguishable on the filesystem:

| Service | Host path | Container path | Contents |
|---------|-----------|----------------|----------|
| hermes | `./data/${CONTAINER_NAME}/hermes` | `/opt/data` | Config, sessions, memories, skills, logs |
| gbrain | `./data/${CONTAINER_NAME}/gbrain` | `/data` | PGLite knowledge graph database |
| gdrive-mcp | none | — | Stateless — service account auth via env var |

Example with two instances (`CONTAINER_NAME=assistant` and `CONTAINER_NAME=assistant-work`):

```
./data/
├── assistant/
│   ├── hermes/
│   └── gbrain/
└── assistant-work/
    ├── hermes/
    └── gbrain/
```

---

## Hermes MCP Wiring (`hermes/scripts/init-mcp.sh`)

Runs as an s6 `cont-init.d` oneshot before Hermes starts. Writes MCP server registrations into `/opt/data/config.yaml` only if the file does not already exist — a user's hand-edited config is never overwritten on restart:

```bash
#!/bin/sh
set -e

CONFIG=/opt/data/config.yaml
[ -f "$CONFIG" ] && exit 0

mkdir -p /opt/data
cat > "$CONFIG" << 'EOF'
mcpServers:
  - name: gbrain
    transport: http
    url: http://gbrain:3333
  - name: gdrive
    transport: http
    url: http://gdrive-mcp:3000
EOF

echo "[hermes-init] MCP config written"
```

The hostnames `gbrain` and `gdrive-mcp` resolve via the shared Docker network.

**Implementation note:** The exact `config.yaml` MCP registration key (`mcpServers`, `mcp_servers`, `tools`, etc.) must be confirmed against the live Hermes documentation before writing code. The schema above is illustrative.

---

## Environment Variables

### Removed from `.env.example`

| Variable | Reason |
|----------|--------|
| `AGENTMAIL_API_KEY` | AgentMail dropped |
| `AGENTMAIL_INBOX_EMAIL` | AgentMail dropped |
| `MEM0_API_KEY` | mem0 replaced by G-Brain |
| `CLOUDFLARE_TUNNEL_TOKEN` | cloudflared dropped from this stack |
| `ASSISTANT_HERMES_DIR` | Replaced by scoped `./data/${CONTAINER_NAME}/hermes` |
| `ASSISTANT_MEM0_DIR` | mem0 gone |
| `HERMES_REF` | Moved to `hermes/Dockerfile` build arg |

### Added to `.env.example`

| Variable | Purpose |
|----------|---------|
| `GOOGLE_SERVICE_ACCOUNT_JSON` | Service account credentials for Google Drive MCP |
| `GBRAIN_REF` | Commit SHA or branch to build G-Brain from (default: `main`) |
| `ASSISTANT_IMAGE` | Override published Hermes wrapper image tag |
| `GBRAIN_IMAGE` | Override published G-Brain image tag |
| `GDRIVE_MCP_IMAGE` | Override published Google Drive MCP image tag |

`OPENAI_API_KEY` is already present and doubles as the embedding provider for G-Brain.

---

## CI Workflows

Three separate workflows, each triggered by path changes to its component folder:

| Workflow | Trigger path | Published image |
|----------|-------------|-----------------|
| `publish-assistant.yml` | `assistant/hermes/**` | `ghcr.io/axiomeintelligence/assistant:latest` + `:sha-<commit>` |
| `publish-gbrain.yml` | `assistant/gbrain/**` | `ghcr.io/axiomeintelligence/gbrain:latest` + `:sha-<commit>` |
| `publish-gdrive-mcp.yml` | `assistant/gdrive-mcp/**` | `ghcr.io/axiomeintelligence/gdrive-mcp:latest` + `:sha-<commit>` |

Publishing both `:latest` and `:sha-<commit>` allows consuming repos to pin to a specific digest without modifying their compose file — set `GBRAIN_IMAGE=ghcr.io/axiomeintelligence/gbrain:sha-abc123` in their `.env`.

---

## Template Usage Pattern

This repo is a template. Consuming repos:

1. Reference published images via the overridable image env vars
2. Provide their own `.env` with credentials
3. Can pin any component to a specific SHA tag via `*_IMAGE` env vars
4. Can extend any component by building a derived image and setting the override var

No changes to this repo's compose file or Dockerfiles are required for downstream customization.

---

## What Is Not Changing

- Telegram, Slack, Gmail IMAP/SMTP platform support — same env vars, same behavior
- `CONTAINER_NAME` pattern for multi-instance deployments
- `HOST_PORT` for port mapping
- `TZ` for timezone
- Devbot stack (`devbot/`) — untouched
