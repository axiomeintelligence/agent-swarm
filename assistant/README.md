# assistant/

A self-hostable AI assistant composed of three Docker services: the Hermes AI gateway (official Nous Research image), G-Brain knowledge graph MCP, and Google Drive MCP.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│ assistant-net (Docker bridge)                               │
│                                                             │
│  ┌─────────────┐    ┌──────────────┐    ┌───────────────┐  │
│  │   hermes    │───▶│   gbrain     │    │  gdrive-mcp   │  │
│  │  :8642      │    │  :3131 HTTP  │    │  :3000 SSE    │  │
│  │             │───▶│              │    │               │  │
│  │ Hermes Agent│    │ G-Brain MCP  │    │ GDrive MCP    │  │
│  │ (official)  │    │ PGLite graph │    │ supergateway  │  │
│  └─────────────┘    └──────────────┘    └───────────────┘  │
│        │                  │                    │            │
│     /opt/data          /data/.gbrain       (stateless)     │
└─────────────────────────────────────────────────────────────┘
```

**hermes** — Thin wrapper on `nousresearch/hermes-agent:latest`. On first boot, a `cont-init.d` script appends MCP server registrations to `config.yaml` and writes a sentinel file so re-boots are no-ops.

**gbrain** — Clones `garrytan/gbrain` at `GBRAIN_REF` (default: `master`), installs via Bun, and runs `gbrain serve --http` on port 3131. PGLite database is persisted to the `gbrain` volume. Auto-initializes on first run.

**gdrive-mcp** — Runs `@modelcontextprotocol/server-gdrive` (stdio) behind a `supergateway` SSE bridge on port 3000. Requires `GOOGLE_SERVICE_ACCOUNT_JSON`. Without it the container starts but Drive tool calls fail.

## Quickstart

```bash
cd assistant
cp .env.example .env
# Fill in ANTHROPIC_API_KEY and at least one platform token (TELEGRAM_BOT_TOKEN, SLACK_BOT_TOKEN, etc.)
# Optionally fill in GOOGLE_SERVICE_ACCOUNT_JSON for Google Drive access
docker compose up -d
```

## Image references

| Service | Default image | Override env var |
|---------|--------------|-----------------|
| hermes | `ghcr.io/axiomeintelligence/assistant:latest` | `ASSISTANT_IMAGE` |
| gbrain | `ghcr.io/axiomeintelligence/gbrain:latest` | `GBRAIN_IMAGE` |
| gdrive-mcp | `ghcr.io/axiomeintelligence/gdrive-mcp:latest` | `GDRIVE_MCP_IMAGE` |

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | Yes* | — | API key for Anthropic Claude |
| `AI_PROVIDER` | No | `anthropic` | Model provider: `anthropic` \| `openai` \| `openrouter` |
| `OPENAI_API_KEY` | No | — | OpenAI key; also used by G-Brain for embeddings |
| `OPENROUTER_API_KEY` | No | — | OpenRouter key |
| `GBRAIN_REF` | No | `main` | Git ref to build G-Brain from (branch, tag, or SHA) |
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
| `data/<name>/gbrain/` | G-Brain PGLite database |

## MCP server registration

The `hermes/scripts/init-mcp.sh` cont-init script runs once on first boot and appends the following block to `config.yaml`:

```yaml
mcp_servers:
  gbrain:
    url: "http://gbrain:3131"
    timeout: 120
    connect_timeout: 30

  gdrive-mcp:
    url: "http://gdrive-mcp:3000/sse"
    transport: sse
    timeout: 120
    connect_timeout: 30
```

A sentinel file (`data/<name>/hermes/.mcp-init-done`) prevents re-injection on subsequent boots, preserving any manual edits to the block.

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

Three GitHub Actions workflows publish images to GHCR on push to `main`:

| Workflow | Trigger path | Image |
|---------|-------------|-------|
| `publish-assistant.yml` | `assistant/hermes/**` | `ghcr.io/axiomeintelligence/assistant` |
| `publish-gbrain.yml` | `assistant/gbrain/**` | `ghcr.io/axiomeintelligence/gbrain` |
| `publish-gdrive-mcp.yml` | `assistant/gdrive-mcp/**` | `ghcr.io/axiomeintelligence/gdrive-mcp` |

Images are tagged `latest` and `sha-<commit-sha>`.

## Useful commands

```bash
# Attach to the Hermes CLI
docker exec -it assistant hermes

# Follow all service logs
docker compose logs -f

# Check health status
docker compose ps

# Rebuild (e.g. after changing GBRAIN_REF)
docker compose up --build -d

# Wipe and restart fresh (removes data volumes)
docker compose down -v
docker compose up -d
```

## G-Brain notes

- Default branch is `master` (not `main`). `GBRAIN_REF=main` is aliased automatically.
- Embeddings are disabled by default (`--no-embedding`). Set `OPENAI_API_KEY` and remove `--no-embedding` in the entrypoint to enable.
- HTTP server requires `--bind 0.0.0.0` (default is loopback — unreachable from other containers).

## Google Drive notes

- `@modelcontextprotocol/server-gdrive` is stdio-only; `supergateway` bridges it to SSE.
- The service account must have the Drive API enabled and be granted access to specific folders (or the entire Drive).
- Without `GOOGLE_SERVICE_ACCOUNT_JSON`, the container starts but Drive tool calls return auth errors.
