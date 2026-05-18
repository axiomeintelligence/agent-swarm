# Agent Swarm

Dockerized [Claude Code](https://claude.ai/claude-code) containers for running AI agents on your own infrastructure.

Pull a pre-built image from GHCR and configure everything with a single `.env` file.

---

## What's inside

**`devbot/`** — A Claude Code container with:
- Claude Code CLI
- [claudecodeui](https://github.com/axiomeintelligence/claudecodeui) web UI (port 3001)
- Chromium (for Playwright / html-to-pdf workloads)
- Cloudflare CLI (`cloudflared`) for tunnel support
- Auto-installs Claude Code plugins and skills on first start

---

## Quickstart

```bash
cd devbot
cp .env.example .env
# Edit .env — fill in GITHUB_PAT, GITHUB_REPO_URL, and any optional fields
docker compose up -d
```

Open `http://localhost:3001` in your browser.

Attach a shell:
```bash
docker exec -it devbot bash
```

---

## Running multiple instances

Each instance needs a unique `DEVBOT_NAME` and `DEVBOT_HOST_PORT` in its `.env`:

```bash
# Instance 1 — .env
DEVBOT_NAME=devbot-research
DEVBOT_HOST_PORT=3001

# Instance 2 — .env
DEVBOT_NAME=devbot-client
DEVBOT_HOST_PORT=3002
```

Both can run from the same `devbot/` directory simultaneously.

---

## Environment variables

See [`devbot/.env.example`](devbot/.env.example) for the full list with descriptions.

Key variables:

| Variable | Required | Description |
|---|---|---|
| `GITHUB_PAT` | Yes | PAT to clone your workspace repo |
| `GITHUB_REPO_URL` | Yes | Repo to clone into `/workspace` |
| `DEVBOT_NAME` | No | Container name (default: `devbot`) |
| `DEVBOT_HOST_PORT` | No | Host port for web UI (default: `3001`) |
| `CLAUDE_PLUGINS` | No | Comma-separated plugins to install |
| `CLAUDE_SKILLS_REPO` | No | Git repo to clone as global skills |
| `API_BEARER_TOKEN` | No | Bearer token for claudecodeui auth |
| `CLOUDFLARE_TUNNEL_TOKEN` | No | Exposes UI via Cloudflare Tunnel |

---

## DevPod

[DevPod](https://devpod.sh) users can point at this repo to get a devbot environment:

1. Install DevPod
2. Create workspace from `https://github.com/axiomeintelligence/agent-swarm`
3. DevPod pulls the pre-built image and mounts your local folder into `/workspace`

---

## Build locally

```bash
cd devbot
docker compose up --build -d
```

---

## Image

Pre-built image: `ghcr.io/axiomeintelligence/devbot:latest`

Built and pushed automatically on every push to `main`.
