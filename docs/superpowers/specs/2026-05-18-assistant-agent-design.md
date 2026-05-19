# Assistant Agent Design

**Date:** 2026-05-18
**Status:** Approved
**Repo:** `agent-swarm` — `assistant/` directory

---

## Overview

A new public Docker image — `ghcr.io/axiomeintelligence/assistant:latest` — that packages [Hermes Agent](https://github.com/nousresearch/hermes-agent) (Nous Research) as a self-hostable AI assistant reachable across multiple messaging platforms. Built alongside `devbot/` in the same repository, following the same structural principles, but entirely independent: no claudecodeui, no Claude Code CLI, no Chromium.

Target audience: developers and technical users who want to run their own persistent AI assistant across Telegram, Slack, email, and Signal.

---

## Repository Structure

```
agent-swarm/
├── devbot/                        (unchanged)
└── assistant/
    ├── Dockerfile
    ├── docker-compose.yml
    ├── scripts/
    │   └── entrypoint.sh
    └── .env.example
```

---

## Docker Image

**Base:** `ubuntu:22.04` — same OS as devbot, independent build (does not extend the devbot image).

**System dependencies installed:**
- `python3`, `pip3`, `git`, `curl`, `ca-certificates`
- `libsodium-dev`, `dbus-x11` — required for Signal protocol support
- `cloudflared` — via Cloudflare apt repo (same method as devbot)

**Application layer:**
- Hermes Agent cloned from `https://github.com/nousresearch/hermes-agent` and installed via `pip install`
- `mem0` installed via pip

**Runtime user:** Non-root `assistant` user (mirrors devbot's `claude` user).

**No Node.js, no claudecodeui, no Chromium.** The image is lean by design.

---

## Entrypoint Flow

`scripts/entrypoint.sh` runs sequentially on container start:

1. **Validate AI provider** — exit with a clear error if `AI_PROVIDER` is set but the corresponding API key is missing.

2. **Configure mem0**
   - `MEM0_API_KEY` set → mem0 cloud
   - blank → local file storage at `/home/assistant/.mem0`

3. **Detect active platforms** — check each platform's env vars and enable only those that are configured:
   - `TELEGRAM_BOT_TOKEN` → Telegram adapter
   - `SLACK_BOT_TOKEN` + `SLACK_APP_TOKEN` → Slack adapter
   - `AGENTMAIL_API_KEY` → AgentMail adapter (preferred email path)
   - `EMAIL_SMTP_HOST` + `EMAIL_*` → SMTP/IMAP adapter (fallback email path)
   - `SIGNAL_PHONE_NUMBER` → Signal adapter
   - No platforms configured → log "No platforms configured — CLI only" and continue

4. **Write Hermes config** — generate `/home/assistant/.hermes/config.yaml` from detected env vars.

5. **Start Cloudflare Tunnel** (background) — only if `CLOUDFLARE_TUNNEL_TOKEN` is set.

6. **Launch Hermes** — foreground process. Container logs are the assistant's live output; `docker logs -f assistant` is the natural monitoring interface.

---

## Environment Variables

Full `.env.example` with inline documentation and setup links:

```bash
# ── Identity ──────────────────────────────────────────────────────────────────
CONTAINER_NAME=assistant          # Unique per instance; change when running multiples

# ── AI Model ──────────────────────────────────────────────────────────────────
# Get your Anthropic API key: https://console.anthropic.com/settings/keys
AI_PROVIDER=anthropic             # anthropic | openai | openrouter
ANTHROPIC_API_KEY=
OPENAI_API_KEY=
OPENROUTER_API_KEY=

# ── Memory (mem0) ─────────────────────────────────────────────────────────────
# Leave blank for local file-based memory inside the container.
# Set for mem0 cloud (cross-instance memory): https://mem0.ai
MEM0_API_KEY=

# ── Platforms (all optional — leave blank to disable) ─────────────────────────
# At least one platform token enables that platform. Zero platforms = CLI only.

# Telegram
# Setup guide: https://core.telegram.org/bots#how-do-i-create-a-bot
TELEGRAM_BOT_TOKEN=               # From @BotFather on Telegram

# Slack
# Setup guide: https://api.slack.com/apps — create an app, enable Socket Mode,
# add bot scopes (chat:write, channels:read), install to workspace
SLACK_BOT_TOKEN=                  # xoxb-... (OAuth & Permissions → Bot Token)
SLACK_APP_TOKEN=                  # xapp-... (Basic Information → App-Level Tokens)

# Email — AgentMail (recommended: gives the assistant its own @agentmail.to inbox)
# Setup guide: https://agentmail.to/docs
AGENTMAIL_API_KEY=

# Email — Standard SMTP/IMAP (use your own email account instead of AgentMail)
EMAIL_SMTP_HOST=                  # e.g. smtp.gmail.com
EMAIL_SMTP_PORT=587
EMAIL_IMAP_HOST=                  # e.g. imap.gmail.com
EMAIL_USER=
EMAIL_PASSWORD=

# Signal (opt-in — requires a dedicated phone number, registration on first run)
SIGNAL_PHONE_NUMBER=              # E.164 format: +15551234567

# ── Networking ────────────────────────────────────────────────────────────────
HOST_PORT=3002                    # Avoids conflict with devbot default (3001)
CLOUDFLARE_TUNNEL_TOKEN=          # Optional. From Cloudflare Zero Trust → Tunnels.

# ── Runtime ───────────────────────────────────────────────────────────────────
TZ=UTC
```

---

## Platform Notes

| Platform | In .env.example? | Notes |
|---|---|---|
| Telegram | Yes | Simplest setup — single token from @BotFather |
| Slack | Yes | Requires Socket Mode enabled in Slack app settings |
| AgentMail | Yes (preferred email) | AI-native inbox; preferred over SMTP/IMAP |
| SMTP/IMAP | Yes (email fallback) | Standard credentials when AgentMail not used |
| Signal | No (opt-in) | Needs phone number + first-run registration |
| CLI | Always | Available regardless of platform config |

---

## CI/CD

New workflow: `.github/workflows/publish-assistant.yml`

- **Trigger:** push to `main` with changes under `assistant/**`
- **Build:** `docker build assistant/`
- **Push:**
  - `ghcr.io/axiomeintelligence/assistant:latest`
  - `ghcr.io/axiomeintelligence/assistant:sha-<commit>` (for version pinning)

Fully independent of the devbot workflow — path filters ensure each workflow only fires on changes to its own directory.

---

## Naming Conventions

Docker-related env vars use standardized names across all containers in this repo:
- `CONTAINER_NAME` — not `ASSISTANT_NAME` or `DEVBOT_NAME`
- `HOST_PORT` — not `ASSISTANT_HOST_PORT` or `DEVBOT_HOST_PORT`

This makes it trivial to run multiple instances with minimal `.env` differences.

---

## Key Design Decisions

| Decision | Rationale |
|---|---|
| Fresh Ubuntu base, not extending devbot | devbot carries ~1GB of Node/claudecodeui/Chromium unused by Hermes |
| Hermes as foreground process | Natural Docker logging; `docker logs -f` is the monitoring interface |
| All platforms opt-in | Users shouldn't need every token to get started |
| CLI-only as valid state | Zero friction for first run and testing |
| AgentMail preferred over SMTP | Purpose-built for AI agents; simpler auth, better deliverability |
| mem0 local fallback | Works without a cloud account; upgrade path is one env var |
