# Hermes Standalone Design

**Goal:** Add a lightweight `hermes/` service as a simpler alternative to the full `assistant/` stack, using `nousresearch/hermes-agent:latest` directly with no supporting containers.

**Architecture:** Single container, no custom image build, secrets via `.env` file. Sits alongside `devbot/` and `assistant/` as an independent top-level service directory.

**When to use:** Users who want Hermes without gbrain (knowledge graph) or gdrive-mcp (Google Drive). Lower resource footprint, faster to get running.

---

## Files

### `hermes/docker-compose.yml`

- Uses `nousresearch/hermes-agent:latest` directly
- Port vars default to `8642` (gateway) and `9119` (dashboard) with `:-` fallbacks
- Dashboard enabled and insecure by default (safe on Tailscale-only networks)
- Resource limits: 4 GB RAM, 2 CPUs
- Data volume at `./data` (local, not `~/.hermes`)

### `hermes/.env.example`

All vars with comments and sensible defaults:

| Group | Vars |
|---|---|
| AI providers | `ANTHROPIC_API_KEY` (required), `OPENAI_API_KEY`, `OPENROUTER_API_KEY` |
| Telegram | `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS` |
| Slack | `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS` |
| Email | `EMAIL_ADDRESS`, `EMAIL_PASSWORD`, IMAP/SMTP hosts and ports |
| Ports | `HOST_PORT` (8642), `DASHBOARD_PORT` (9119) |
| Container | `CONTAINER_NAME` (hermes) |
