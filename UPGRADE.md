# Upgrade Notes

Breaking changes and migration steps, newest first.

---

## 2026-06-17 — gbrain runs as HTTP MCP server inside hermes container

### What changed

- **`assistant/hermes/scripts/02-gbrain-http.sh`** — new cont-init.d script (runs first) that:
  - Removes any stale PGLite lock from a previous container run
  - Initialises the gbrain brain on first boot
  - Registers a one-time OAuth `client_credentials` client (credentials cached in `${GBRAIN_HOME}/.hermes-oauth-creds`)
  - Starts `gbrain serve --http --port 3131` as a background process so both `hermes gateway run` and `hermes dashboard` share a single gbrain instance
  - Obtains a 30-day bearer token and writes it to `/tmp/gbrain-http-token` for the next script
- **`assistant/hermes/scripts/init-mcp.sh`** (03-mcp-config) — rewritten to:
  - Always strip and re-inject the MCP block (no sentinel) so the fresh bearer token is picked up on every boot
  - Register gbrain as `url: http://localhost:3131/mcp` with `Authorization: Bearer <token>` header instead of the old stdio subprocess
  - Register gdrive-mcp as before
- **`assistant/hermes/Dockerfile`** — adds `02-gbrain-http.sh` to the image
- **`assistant/hermes/scripts/sync-brain.sh`** — detects HTTP mode (gbrain health endpoint) and calls the MCP `import_documents` tool via HTTP instead of the CLI (which cannot acquire the PGLite write lock while the HTTP server holds it)

### Why

Running `hermes dashboard` and `hermes gateway run` each spawned an independent gbrain stdio subprocess. Both competed for the PGLite exclusive write lock — one would succeed, the other would fail after a 30-second timeout. The winner's MCP session was then orphaned (Python `CancelledError`) because the hermes task group cancelled when the loser's connection failed. The HTTP server approach means exactly one gbrain process holds the lock; both hermes processes connect to it over localhost HTTP.

### No new environment variables required

The OAuth client credentials are generated automatically by `02-gbrain-http.sh` on first boot and persisted to `${GBRAIN_HOME}/.hermes-oauth-creds` (a Docker volume, so they survive container restarts). No `GBRAIN_ADMIN_TOKEN` or similar pre-shared secret is needed.

### Migration steps

**Existing deployments** — pull, rebuild, and restart hermes:

```bash
git pull
docker compose build hermes
docker compose up -d hermes
```

The stale sentinel file (`${HERMES_HOME}/.mcp-init-done`) from the old init-mcp.sh is harmless — the new `03-mcp-config` ignores it and always re-injects. To clean it up manually:

```bash
docker exec <hermes-container> rm -f /opt/data/.mcp-init-done
```

On restart, gbrain starts as an HTTP server and hermes connects to it via localhost. Check logs:

```bash
docker exec <hermes-container> cat /opt/data/logs/gbrain-http.log
docker logs <hermes-container> 2>&1 | grep "\[gbrain-http\]\|\[hermes-mcp-init\]"
```

---

## 2026-06-12 — G-Brain OAuth token refresh on every Hermes startup

### What changed

- **`assistant/hermes/scripts/04-gbrain-auth.sh`** — new per-boot cont-init.d script that:
  - Uses `#!/command/with-contenv sh` so `GBRAIN_ADMIN_TOKEN` is available (plain `#!/bin/sh` in s6 cont-init.d does not inherit the Docker container environment)
  - Registers a confidential OAuth client with G-Brain on first boot (credentials cached to avoid accumulation)
  - Refreshes the OAuth 2.1 access token on **every** Hermes startup (tokens expire after ~3600s)
  - Waits up to 30s for G-Brain to be ready before attempting auth (avoids silent failure when G-Brain starts slower than Hermes)
- **`assistant/hermes/Dockerfile`** — adds the new `04-gbrain-auth.sh` script to the image
- **`assistant/docker-compose.yml`** — adds `GBRAIN_ADMIN_TOKEN` to hermes env and `GBRAIN_ADMIN_BOOTSTRAP_TOKEN` to gbrain env
- **`assistant/.env.example`** — documents `GBRAIN_ADMIN_TOKEN`

Without this, Hermes connects to G-Brain anonymously and receives `401 Unauthorized` on every MCP call.

### New environment variable

| Variable | Where to set | Description |
|----------|-------------|-------------|
| `GBRAIN_ADMIN_TOKEN` | `.env` | 32+ char token. Same value passed to both `gbrain` (as `GBRAIN_ADMIN_BOOTSTRAP_TOKEN`) and `hermes` (as `GBRAIN_ADMIN_TOKEN`). Generate: `openssl rand -hex 32` |

### Migration steps

**New deployments** — set `GBRAIN_ADMIN_TOKEN` in `.env` before first `docker compose up`. No other action needed.

**Existing deployments** — pull, rebuild, and restart:

```bash
git pull
docker compose build hermes
docker compose up -d hermes gbrain
```

The script will register a new OAuth client and write a fresh token on the next Hermes startup. Hermes does not need to be fully stopped; a restart is sufficient.

---

## 2026-06-11 — MCP URL fixes (gbrain, devbot-mcp), gdrive-mcp service account

### What changed

- **`assistant/hermes/scripts/init-mcp.sh`** — fixed gbrain registered URL from `http://gbrain:3131` to `http://gbrain:3131/mcp`. Without this Hermes cannot connect to G-Brain.
- **`assistant/gdrive-mcp/Dockerfile`** — replaced deprecated `@modelcontextprotocol/server-gdrive` (OAuth-only) with `@piotr-agier/google-drive-mcp` which supports service account auth via `GOOGLE_APPLICATION_CREDENTIALS`.
- **`assistant/gdrive-mcp/docker-entrypoint.sh`** — switched from `echo` to `printf` when writing service account JSON to avoid newline expansion corrupting the file.

### Migration steps

**Existing deployments** — the sentinel files prevent init scripts from re-running. Apply manually:

```bash
# Fix gbrain URL in live config
docker exec <assistant-container> sed -i 's|url: http://gbrain:3131$|url: http://gbrain:3131/mcp|' /opt/data/config.yaml

# Rebuild gdrive-mcp with new server
git pull
docker compose build gdrive-mcp
docker compose up -d gdrive-mcp

# Restart hermes to reconnect
docker compose restart hermes
```

**New deployments** — no action needed, all fixes are included.

---

## 2026-06-11 — gateway run mode, remove hermes-webui

### What changed

- **`assistant/docker-compose.yml`** — hermes now runs `hermes gateway run` as its command instead of the interactive TUI. Without this, Hermes starts in TUI mode and never listens for Telegram/Slack/email messages.
- **`assistant/docker-compose.yml`** — `hermes-webui` service removed. The webui runs its own in-process Hermes instance rather than connecting to the existing container, making it incompatible with this multi-container stack.
- Removed `tty: true` / `stdin_open: true` (no longer needed — gateway run doesn't require a terminal).
- Removed `hermes-home` and `hermes-agent-src` volumes (were only needed by hermes-webui).

### Migration steps

```bash
git pull
docker compose up -d hermes
```

If you had hermes-webui running, stop and remove it:

```bash
docker compose stop hermes-webui
docker compose rm hermes-webui
```

### Breaking

**Existing deployments without `command: hermes gateway run`** will have Hermes running in TUI mode — it will appear healthy but never respond to any messages. This is a silent failure. The fix is to pull and restart.

---

## 2026-06-11 — hermes-webui + TTY fix

### What changed

- **`assistant/docker-compose.yml`** — added `tty: true` and `stdin_open: true` to the `hermes` service. Without these, Hermes detects no terminal and exits immediately, causing a restart loop.
- **`assistant/docker-compose.yml`** — added `hermes-webui` service (`ghcr.io/nesquena/hermes-webui:latest`) on port 8787.
- **`assistant/docker-compose.yml`** — added two named volumes (`hermes-home`, `hermes-agent-src`) shared between `hermes` and `hermes-webui`.

### Migration steps

**If you are upgrading an existing deployment:**

1. Pull the latest compose file and images:
   ```bash
   git pull
   docker compose pull
   docker compose up -d
   ```

2. Hermes will now stay running correctly. No data is lost — the existing bind mount (`./data/<name>/hermes`) is unchanged.

3. The web UI is available at `http://<host>:8787`. Set `HERMES_WEBUI_PASSWORD` in your `.env` if the port is exposed beyond a private network.

**Volume note:** The `hermes-agent-src` volume is populated from the Hermes image on first start. If you upgrade the Hermes image in future and the web UI cannot find agent files, remove this volume and restart to repopulate it:
```bash
docker compose down
docker volume rm <project>-hermes-agent-src
docker compose up -d
```

### New environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `WEBUI_PORT` | `8787` | Host port for the Hermes web UI |
| `HERMES_WEBUI_PASSWORD` | _(none)_ | Optional password auth for the web UI |
| `HERMES_UID` | `1000` | UID the web UI runs as — must match the hermes container user |
| `HERMES_GID` | `1000` | GID the web UI runs as — must match the hermes container user |

---

## 2026-06-08 — Playwright in devbot

### What changed

- **`devbot/Dockerfile`** — `playwright` npm package installed globally alongside Claude Code CLI. Wired to the system Chromium via `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` and `PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=/usr/bin/chromium`.

### Migration steps

Rebuild the devbot image:
```bash
docker compose build devbot
docker compose up -d devbot
```

No configuration changes required.
