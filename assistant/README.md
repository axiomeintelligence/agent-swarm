# assistant/

A self-hostable AI assistant composed of two Docker services: the Hermes AI gateway (official Nous Research image) with G-Brain knowledge graph embedded as a stdio subprocess, and Google Drive MCP.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ assistant-net (Docker bridge)                               │
│                                                             │
│  ┌──────────────────────────────┐    ┌───────────────┐      │
│  │           hermes             │    │  gdrive-mcp   │      │
│  │          :8642               │    │  :3000 SSE    │      │
│  │                              │    │               │      │
│  │  Hermes Agent (official)     │    │ GDrive MCP    │      │
│  │  + G-Brain MCP (stdio)       │    │ supergateway  │      │
│  │    PGLite graph              │    │               │      │
│  └──────────────────────────────┘    └───────────────┘      │
│        │                                  │                 │
│   /opt/data                          (stateless)            │
│   /opt/mono-repo (read-only)                                │
└─────────────────────────────────────────────────────────────┘
```

**hermes** — Thin wrapper on `nousresearch/hermes-agent:latest`. On first boot, a `cont-init.d` script appends MCP server registrations to `config.yaml` and writes a sentinel file so re-boots are no-ops. G-Brain runs as an embedded stdio subprocess inside this container — no separate container or HTTP port required.

**gdrive-mcp** — Runs `@modelcontextprotocol/server-gdrive` (stdio) behind a `supergateway` SSE bridge on port 3000. Requires `GOOGLE_SERVICE_ACCOUNT_JSON`. Without it the container starts but Drive tool calls fail.

## Quickstart

```bash
cd assistant
cp .env.example .env
# Fill in ANTHROPIC_API_KEY and at least one platform token (TELEGRAM_BOT_TOKEN, SLACK_BOT_TOKEN, etc.)
# Fill in MONO_REPO_PATH to point at a local clone of your mono-repo
# Optionally fill in GOOGLE_SERVICE_ACCOUNT_JSON for Google Drive access
docker compose up -d
```

## Image references

| Service | Default image | Override env var |
|---------|--------------|-----------------|
| hermes | `ghcr.io/axiomeintelligence/assistant:latest` | `ASSISTANT_IMAGE` |
| gdrive-mcp | `ghcr.io/axiomeintelligence/gdrive-mcp:latest` | `GDRIVE_MCP_IMAGE` |

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | Yes* | — | API key for Anthropic Claude |
| `AI_PROVIDER` | No | `anthropic` | Model provider: `anthropic` \| `openai` \| `openrouter` |
| `OPENAI_API_KEY` | No | — | OpenAI key (required if `AI_PROVIDER=openai`) |
| `OPENROUTER_API_KEY` | No | — | OpenRouter key (required if `AI_PROVIDER=openrouter`) |
| `MONO_REPO_PATH` | No | — | Host path to a local clone of your mono-repo; mounted read-only into G-Brain |
| `BRAIN_SYNC_INTERVAL` | No | `3600` | Seconds between automatic G-Brain sync runs |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | No | — | Full JSON of a Google service account key with Drive API access |
| `TELEGRAM_BOT_TOKEN` | No | — | Enable Telegram platform |
| `TELEGRAM_ALLOWED_USERS` | No | — | Allowed Telegram usernames |
| `SLACK_BOT_TOKEN` | No | — | Enable Slack platform |
| `SLACK_APP_TOKEN` | No | — | Slack app-level token |
| `SLACK_ALLOWED_USERS` | No | — | Allowed Slack users |
| `EMAIL_ADDRESS` | No | — | Gmail address for IMAP/SMTP |
| `EMAIL_PASSWORD` | No | — | Gmail app password |
| `CONTAINER_NAME` | No | `assistant` | Prefix for container names and network |
| `HOST_PORT` | No | `8642` | Host port mapping for Hermes (container port 8642) |
| `TZ` | No | `UTC` | Container timezone |

*Or `OPENAI_API_KEY` / `OPENROUTER_API_KEY` depending on `AI_PROVIDER`.

## Volumes

Data is persisted under `assistant/data/<CONTAINER_NAME>/`:

| Path | Content |
|------|---------|
| `data/<name>/hermes/` | Hermes config, state DB, logs |
| `<MONO_REPO_PATH>` | Mono-repo source (mounted read-only at `/opt/mono-repo`) |
| `/opt/mono-repo/docs/` | G-Brain indexes scanned documents from here |
| `/opt/mono-repo/.gbrain/` | G-Brain PGLite database (persisted inside mono-repo clone) |

## MCP server registration

The `hermes/scripts/init-mcp.sh` cont-init script runs once on first boot and appends the following block to `config.yaml`:

```yaml
mcp_servers:
  gbrain:
    command: "gbrain"
    args: ["serve", "--stdio"]
    timeout: 120
    connect_timeout: 30

  gdrive-mcp:
    url: "http://gdrive-mcp:3000/sse"
    transport: sse
    timeout: 120
    connect_timeout: 30
```

A sentinel file (`data/<name>/hermes/.mcp-init-done`) prevents re-injection on subsequent boots, preserving any manual edits to the block.

> **Upgrading from the 3-container stack?** If you previously ran a separate `gbrain` container with a URL-style MCP registration (pointing at port 3131), delete the sentinel file to force re-injection with the new `command:` style:
> ```bash
> rm data/<name>/hermes/.mcp-init-done
> docker compose up -d
> ```

## Consuming this stack in another repo

Override images via environment variables:

```yaml
# In your repo's docker-compose.yml
services:
  hermes:
    image: ${ASSISTANT_IMAGE:-ghcr.io/axiomeintelligence/assistant:latest}
```

Or build locally:

```bash
docker compose build
docker compose up -d
```

To run multiple instances on the same host, set unique `CONTAINER_NAME` and `HOST_PORT` in each `.env`.

## CI/CD

Two GitHub Actions workflows publish images to GHCR on push to `main`:

| Workflow | Trigger path | Image |
|---------|-------------|-------|
| `publish-assistant.yml` | `assistant/hermes/**` | `ghcr.io/axiomeintelligence/assistant` |
| `publish-gdrive-mcp.yml` | `assistant/gdrive-mcp/**` | `ghcr.io/axiomeintelligence/gdrive-mcp` |

Images are tagged `latest` and `sha-<commit-sha>`.

## Useful commands

```bash
# Attach to the Hermes CLI
docker exec -it assistant hermes

# Manually trigger a G-Brain sync
docker exec assistant sync-brain.sh

# Follow all service logs
docker compose logs -f

# Check health status
docker compose ps

# Rebuild (e.g. after updating the image)
docker compose pull
docker compose up -d

# Wipe and restart fresh (removes data volumes)
docker compose down -v
docker compose up -d
```

## Google Drive setup

`@modelcontextprotocol/server-gdrive` is stdio-only; `supergateway` bridges it to SSE. Without `GOOGLE_SERVICE_ACCOUNT_JSON`, the container starts but Drive tool calls return auth errors.

### 1. Enable APIs

Enable both APIs in your Google Cloud project:

- [Google Drive API](https://console.cloud.google.com/marketplace/product/google/drive.googleapis.com)
- [Google Docs API](https://console.cloud.google.com/apis/api/docs.googleapis.com)

### 2. Create a service account

> **If your org blocks service account key creation**, a Security Admin must first disable the policy:
> 1. Grant yourself the **Security Admin** role at [IAM](https://console.cloud.google.com/iam-admin/iam)
> 2. Disable the [Service Account Key Creation org policy](https://console.cloud.google.com/iam-admin/orgpolicies/iam-disableServiceAccountKeyCreation)

Create the service account at [IAM → Service Accounts](https://console.cloud.google.com/iam-admin/serviceaccounts):

1. Click **Create Service Account** — name it (e.g. `gdrive-mcp`)
2. Skip optional role grants — access is controlled via Drive sharing, not IAM
3. On the service account page, go to **Keys → Add Key → Create new key → JSON**
4. Download the JSON file — paste its full contents (single line) into `GOOGLE_SERVICE_ACCOUNT_JSON`

### 3. Grant Drive access

Share any Google Drive folder or Shared Drive with the service account's email address (shown on the service account page), granting it **Content Manager** or higher.

The service account only has access to folders explicitly shared with it.
