# Unified Assistant Container Design

**Date:** 2026-06-16
**Status:** Approved

## Goal

Merge gbrain into the hermes container, replacing the existing 3-container assistant stack (hermes + gbrain + gdrive-mcp) with a 2-container stack (unified hermes+gbrain + gdrive-mcp). Connect gbrain via stdio MCP transport (not HTTP), eliminating OAuth complexity. Mount a user-managed mono-repo as volumes to supply brain content, skills, and persistent gbrain state.

---

## Architecture

```
assistant-net
├── hermes  (hermes gateway + gbrain as stdio subprocess + sync-brain s6 service)
│   ├── Hermes gateway  :8642
│   ├── gbrain serve    (stdio, spawned by Hermes via config.yaml command:)
│   └── sync-brain      (s6 background service: git pull + gbrain import loop)
└── gdrive-mcp          (unchanged — separate container, SSE on :3000)
```

Two repos on the host:
- **agent-swarm** (this repo) — Dockerfiles, docker-compose.yml, `.env`
- **mono-repo** (user-managed, separate) — brain content, skills, gbrain data; mounted as volumes

The mono-repo has no Dockerfile or `.env`. The user clones it separately and points `MONO_REPO_PATH` at it.

---

## Volume Map

| Host path | Container path | Purpose |
|---|---|---|
| `$MONO_REPO_PATH/brain/` | `/brain-repo` | Brain content for gbrain import (read-only) |
| `$MONO_REPO_PATH/gbrain-skills/` | `/opt/gbrain-home/.gbrain/skills` | Skills directory (inotifywait hot-reload) |
| `$MONO_REPO_PATH/.gbrain-data/` | `/opt/gbrain-home` | PGLite DB + gbrain config (persistent) |
| `data/<CONTAINER_NAME>/hermes/` | `/opt/data` | Hermes state (unchanged) |

`GBRAIN_HOME=/opt/gbrain-home` — gbrain appends `.gbrain` internally, so the PGLite DB lives at `/opt/gbrain-home/.gbrain/`.

---

## Dockerfile Changes (`assistant/hermes/Dockerfile`)

Extend the existing hermes Dockerfile with:

1. Install `inotifywait` via apt (`inotify-tools` package)
2. Install Bun via the official install script
3. Clone gbrain at `GBRAIN_REF` (default `main`) and install via `bun link`

```dockerfile
ARG GBRAIN_REF=main

# inotify-tools for skills hot-reload
RUN apt-get update && apt-get install -y --no-install-recommends \
    inotify-tools git curl \
    && rm -rf /var/lib/apt/lists/*

# Bun (required for gbrain)
RUN curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash

# gbrain CLI
RUN git clone --depth 1 https://github.com/garrytan/gbrain /opt/gbrain-src \
    && cd /opt/gbrain-src \
    && bun install \
    && bun link
```

`GBRAIN_REF` is a build arg. Default `main`. Override in docker-compose `build.args` to pin to a SHA.

**Scripts removed:** `04-gbrain-auth.sh` — not needed with stdio transport.

**Scripts added:**
- `scripts/sync-brain.sh` — git pull mono-repo + gbrain import; runs from s6 loop or manually via SSH
- `scripts/gbrain-skills-watch.sh` — inotifywait loop; triggers gbrain import on skills directory changes

---

## MCP Config Change (`assistant/hermes/scripts/init-mcp.sh`)

Replace the gbrain HTTP entry with a stdio `command:` entry:

```yaml
mcp_servers:
  gbrain:
    command: "gbrain"
    args: ["serve", "--home", "/opt/gbrain-home"]
    timeout: 120

  gdrive-mcp:
    url: "http://gdrive-mcp:3000/sse"
    transport: sse
    timeout: 120
    connect_timeout: 30
```

No `url:`, no `connect_timeout:`, no OAuth. Hermes spawns `gbrain serve` as a child process over stdio.

---

## docker-compose.yml Changes

### Remove

- `gbrain` service (entire block)
- `GBRAIN_ADMIN_TOKEN` from hermes environment and from `.env.example`
- `GBRAIN_OPENAI_API_KEY` from hermes environment (gbrain no longer runs as a separate service; if embeddings are desired they can be configured in gbrain's own config via the shared volume)
- gbrain-specific `healthcheck` dependency in hermes `depends_on`

### Add to hermes service

```yaml
volumes:
  - ./data/${CONTAINER_NAME:-assistant}/hermes:/opt/data
  - ${MONO_REPO_PATH}/brain:/brain-repo:ro
  - ${MONO_REPO_PATH}/gbrain-skills:/opt/gbrain-home/.gbrain/skills
  - ${MONO_REPO_PATH}/.gbrain-data:/opt/gbrain-home

environment:
  - MONO_REPO_PATH=${MONO_REPO_PATH:-}
  - BRAIN_SYNC_INTERVAL=${BRAIN_SYNC_INTERVAL:-300}
  - GBRAIN_HOME=/opt/gbrain-home
```

### New env vars in `.env.example`

```env
# ── Mono-repo ─────────────────────────────────────────────────────────────────
# Absolute path on the host where the mono-repo is cloned.
# Volumes for brain content, skills, and gbrain state are mounted from here.
MONO_REPO_PATH=/path/to/your/mono-repo

# How often sync-brain polls for new commits in the mono-repo (seconds).
BRAIN_SYNC_INTERVAL=300
```

---

## sync-brain.sh

`assistant/hermes/scripts/sync-brain.sh` — runs on boot (via s6 loop) and is callable manually:

```sh
#!/bin/sh
# sync-brain.sh — pull mono-repo and import content into gbrain.
# Manual use: docker exec <container> sync-brain.sh
set -e

BRAIN_REPO="${BRAIN_REPO:-/brain-repo}"
GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"

if ! git -C "${BRAIN_REPO}" rev-parse HEAD >/dev/null 2>&1; then
    echo "[sync-brain] ${BRAIN_REPO} is not a git repo — skipping"
    exit 0
fi

BEFORE=$(git -C "${BRAIN_REPO}" rev-parse HEAD)
git -C "${BRAIN_REPO}" pull --ff-only 2>/dev/null || true
AFTER=$(git -C "${BRAIN_REPO}" rev-parse HEAD)

if [ "${BEFORE}" != "${AFTER}" ]; then
    echo "[sync-brain] New commits (${BEFORE:0:7}..${AFTER:0:7}) — importing"
    gbrain import "${BRAIN_REPO}" --home "${GBRAIN_HOME}"
else
    echo "[sync-brain] No new commits at $(date -u +%H:%M:%SZ)"
fi
```

The s6 loop service (`cont-init.d/05-start-sync-brain`) starts a background process:

```sh
while true; do
    sync-brain.sh
    sleep "${BRAIN_SYNC_INTERVAL:-300}"
done
```

---

## gbrain-skills-watch.sh

`assistant/hermes/scripts/gbrain-skills-watch.sh` — s6 service that hot-reloads skills on file changes:

```sh
#!/bin/sh
SKILLS_DIR="/opt/gbrain-home/.gbrain/skills"
GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"

mkdir -p "${SKILLS_DIR}"

inotifywait -m -r -e close_write,create,delete,moved_to "${SKILLS_DIR}" |
while read -r _dir _event _file; do
    echo "[gbrain-skills-watch] Change detected (${_event} ${_file}) — reimporting skills"
    gbrain import "${SKILLS_DIR}" --home "${GBRAIN_HOME}" || true
done
```

Started by `cont-init.d/06-start-skills-watch`.

---

## Multi-User Scoping

Directory convention inside `/brain-repo`:

```
brain/
└── users/
    ├── alice/      — imported with tag "user:alice"
    └── bob/        — imported with tag "user:bob"
shared/             — shared knowledge, all users
```

`gbrain import /brain-repo --home /opt/gbrain-home` recurses the full tree. Gbrain's retrieval-reflex surfaces relevant context per turn. Skills at `.gbrain/skills/` are shared across all users.

---

## Ansible deploy-agent.yml

`infrastructure/ansible/deploy-agent.yml` — day-2 operations playbook for deploying/updating the agent stack on a provisioned server:

```yaml
- name: Deploy agent-swarm assistant stack
  hosts: servers
  tasks:
    - name: Ensure agent-swarm repo is present and up to date
      git:
        repo: "{{ agent_swarm_repo }}"
        dest: "{{ agent_swarm_path }}"
        version: main
        update: yes

    - name: Ensure mono-repo is present and up to date
      git:
        repo: "{{ mono_repo_url }}"
        dest: "{{ mono_repo_path }}"
        version: main
        update: yes

    - name: Pull latest images and restart assistant stack
      community.docker.docker_compose_v2:
        project_src: "{{ agent_swarm_path }}/assistant"
        pull: always
        state: present
```

Vars `agent_swarm_repo`, `agent_swarm_path`, `mono_repo_url`, `mono_repo_path` defined in inventory `group_vars/servers/agent_swarm.yml`.

The `.env` file is NOT managed by Ansible — the user creates it on the server from `.env.example` and it is never committed.

---

## Files Changed

| File | Action |
|---|---|
| `assistant/hermes/Dockerfile` | Add inotify-tools, Bun, gbrain install |
| `assistant/hermes/scripts/init-mcp.sh` | Replace gbrain HTTP entry with stdio command entry |
| `assistant/hermes/scripts/04-gbrain-auth.sh` | **Delete** |
| `assistant/hermes/scripts/sync-brain.sh` | **Create** |
| `assistant/hermes/scripts/gbrain-skills-watch.sh` | **Create** |
| `assistant/hermes/scripts/05-start-sync-brain.sh` | **Create** (cont-init.d entry) |
| `assistant/hermes/scripts/06-start-skills-watch.sh` | **Create** (cont-init.d entry) |
| `assistant/docker-compose.yml` | Remove gbrain service; add volume mounts and new env vars |
| `assistant/.env.example` | Remove GBRAIN_ADMIN_TOKEN; add MONO_REPO_PATH, BRAIN_SYNC_INTERVAL |
| `assistant/README.md` | Update architecture diagram, env table, volume table |
| `infrastructure/ansible/deploy-agent.yml` | **Create** |
| `infrastructure/ansible/inventory/example/group_vars/servers/agent_swarm.yml` | **Create** (template) |

---

## Out of Scope

- gdrive-mcp — unchanged, no modifications
- Hermes dashboard, Slack/Telegram/Email config — unchanged
- Komodo/Periphery Ansible playbooks — unchanged
- gbrain HTTP API endpoint — no longer exposed (stdio only)
