# Upgrade Notes

Breaking changes and migration steps, newest first.

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
