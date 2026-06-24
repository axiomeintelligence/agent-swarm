# assistant/

A self-hostable AI assistant composed of two Docker services: the Hermes AI gateway (official Nous Research image, with G-Brain running as an HTTP MCP server on `localhost:3131` inside the same container), and Google Drive MCP.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ assistant-net (Docker bridge)                               │
│                                                             │
│  ┌──────────────────────────────┐    ┌───────────────┐      │
│  │           hermes             │    │  gdrive-mcp   │      │
│  │          :9119 dashboard     │    │  :3000 SSE    │      │
│  │          (gateway = outbound │    │               │      │
│  │           telegram/slack/...│    │               │      │
│  │           — no HTTP server) │    │               │      │
│  │                              │    │ GDrive MCP    │      │
│  │  Hermes Agent (official)     │    │ supergateway  │      │
│  │  + G-Brain HTTP MCP          │    │               │      │
│  │    on localhost:3131         │    │               │      │
│  │    PGLite store              │    │               │      │
│  └──────────────────────────────┘    └───────────────┘      │
│        │                                  │                 │
│   /opt/data (hermes state)           (stateless)            │
│   /opt/gbrain-home (gbrain state)                           │
│   /opt/data/skills/mono (ro) ←─ mono/agent-swarm/.../skills │
│   /brain-repo               ←─ mono/agent-swarm/.../brain   │
└─────────────────────────────────────────────────────────────┘
```

**hermes** — Thin wrapper on `nousresearch/hermes-agent:latest`. On every container start, `cont-init.d` scripts start G-Brain as an HTTP MCP server on `localhost:3131` and inject fresh MCP server registrations into `config.yaml` (the old MCP block is stripped and re-injected on each boot so the bearer token stays current — do not rely on manual edits to the injected block; they will be overwritten).

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
| `MONO_REPO_PATH` | No | — | Host path to a local clone of your mono-repo. The stack reads from `<MONO_REPO_PATH>/agent-swarm/config/assistant/`: `skills/` (bind-mounted read-only into Hermes), `brain/` (periodic G-Brain import source), `.gbrain-data/` (PGLite database) |
| `SKILL_SYNC_INTERVAL` | No | `300` | Seconds between mono-repo `git pull` ticks (refreshes Hermes skills + re-imports `brain/` into G-Brain) |
| `GOOGLE_SERVICE_ACCOUNT_JSON` | No | — | Full JSON of a Google service account key with Drive API access |
| `TELEGRAM_BOT_TOKEN` | No | — | Enable Telegram platform |
| `TELEGRAM_ALLOWED_USERS` | No | — | Allowed Telegram usernames |
| `SLACK_BOT_TOKEN` | No | — | Enable Slack platform |
| `SLACK_APP_TOKEN` | No | — | Slack app-level token |
| `SLACK_ALLOWED_USERS` | No | — | Allowed Slack users |
| `EMAIL_ADDRESS` | No | — | Gmail address for IMAP/SMTP |
| `EMAIL_PASSWORD` | No | — | Gmail app password |
| `CONTAINER_NAME` | No | `assistant` | Prefix for container names and network |
| `DASHBOARD_PORT` | No | `9119` | Host port mapping for the Hermes dashboard (the only HTTP service this stack exposes) |
| `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` | Yes** | — | Dashboard basic-auth username |
| `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD` | Yes** | — | Dashboard basic-auth password (plaintext; hashed at runtime). Without both username + password, the dashboard refuses to bind on non-loopback addresses. |
| `TZ` | No | `UTC` | Container timezone |

*Or `OPENAI_API_KEY` / `OPENROUTER_API_KEY` depending on `AI_PROVIDER`.
**Required if you expose the dashboard outside loopback (i.e., in any compose deploy where `:9119` is published). OAuth via `hermes dashboard register` is the alternative.

## Volumes

Data is persisted under `assistant/data/<CONTAINER_NAME>/`:

| Path | Content |
|------|---------|
| `data/<name>/hermes/` | Hermes config, state DB, logs |
| `<MONO_REPO_PATH>/` | Whole mono repo; bind-mounted at `/mono-repo` (rw). `sync-brain.sh` runs `git pull` against this path every `SKILL_SYNC_INTERVAL` seconds. Read-write because git needs to update refs/objects — the container has no business writing application files here. |
| `<MONO_REPO_PATH>/agent-swarm/config/assistant/brain/` | G-Brain knowledge source; read by `sync-brain.sh` (as `/mono-repo/agent-swarm/config/assistant/brain` inside the container) and imported into PGLite via the gbrain MCP `import_documents` tool whenever a new commit lands. |
| `<MONO_REPO_PATH>/agent-swarm/config/assistant/skills/` | Hermes skill packs; bind-mounted **read-only** at `/opt/data/skills/mono`. Hermes auto-scans new `SKILL.md` files within one `SKILL_SYNC_INTERVAL` tick. Authoring is via `git` in the mono repo — `hermes skills install --category mono` is not supported (mount is read-only by design). |
| `<MONO_REPO_PATH>/agent-swarm/config/assistant/.gbrain-data/` | G-Brain PGLite database; persistent state |

## MCP server registration

The `hermes/scripts/init-mcp.sh` cont-init script runs on every container start. It strips any previously-injected block and re-injects fresh MCP server registrations into `config.yaml` so the bearer token (issued each boot by `02-gbrain-http.sh`) is always current. Manual edits to the injected `mcp_servers` block will not survive a reboot.

```yaml
# ── MCP servers injected by init-mcp.sh ──────────────────────────────────────
mcp_servers:
  gbrain:
    url: "http://localhost:3131/mcp"
    headers:
      Authorization: "Bearer <token-issued-at-boot>"
    timeout: 120
    connect_timeout: 30
  gdrive-mcp:
    url: "http://gdrive-mcp:3000/sse"
    transport: sse
    timeout: 120
    connect_timeout: 30
```

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
