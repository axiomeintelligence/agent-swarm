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

## Security note

The container sets `dangerouslySkipPermissions: true` in Claude Code settings on every start. This disables Claude Code's tool permission prompts. It is intentional — the container runs in an isolated Docker environment where unrestricted tool access is safe. Do not run this container with access to sensitive host filesystems or credentials beyond what your workspace requires.

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

Each instance needs a unique `CONTAINER_NAME` and `HOST_PORT` in its `.env`:

```bash
# Instance 1 — .env
CONTAINER_NAME=devbot-research
HOST_PORT=3001

# Instance 2 — .env
CONTAINER_NAME=devbot-client
HOST_PORT=3002
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
| `CONTAINER_NAME` | No | Container name (default: `devbot`) |
| `HOST_PORT` | No | Host port for web UI (default: `3001`) |
| `CLAUDE_PLUGINS` | No | Comma-separated plugins to install |
| `CLAUDE_SKILLS_REPO` | No | Git repo to clone as global skills |
| `API_BEARER_TOKEN` | No | Bearer token for claudecodeui auth |
| `CLOUDFLARE_TUNNEL_TOKEN` | No | Exposes UI via Cloudflare Tunnel |
| `ANTHROPIC_API_KEY` | No | Anthropic API key (or authenticate via web UI) |

---

## DevPod

[DevPod](https://devpod.sh) users can point at this repo to get a devbot environment:

1. Install DevPod
2. In DevPod workspace settings, set these environment variables before starting:
   - `GITHUB_PAT` — your GitHub personal access token
   - `GITHUB_REPO_URL` — the repo to clone into `/workspace`
3. Create workspace from `https://github.com/axiomeintelligence/agent-swarm` with devcontainer path `devbot/.devcontainer`
4. DevPod pulls the pre-built image and mounts your local folder into `/workspace`

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
