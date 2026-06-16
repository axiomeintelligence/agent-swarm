# Unified Assistant (Hermes + G-Brain) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Merge G-Brain into the Hermes container so the assistant stack is two containers (hermes + gdrive-mcp) instead of three, using stdio MCP transport for G-Brain.

**Architecture:** The official `nousresearch/hermes-agent` image is extended with Bun, the gbrain CLI, and inotify-tools. G-Brain is registered as a stdio MCP server in Hermes's `config.yaml` via a cont-init.d script. A background loop periodically `git pull`s the mono-repo and triggers `gbrain import`; a second background watcher uses `inotifywait` to hot-reload skills on file changes.

**Tech Stack:** Docker, s6-overlay, Bun, gbrain CLI, inotify-tools, shell scripts

---

### Task 0: Update init-mcp.sh — stdio gbrain entry + migration

**Goal:** Replace the HTTP gbrain MCP entry with a stdio `command:` entry, and add an upgrade migration that strips the old injected block from existing deployments.

**Files:**
- Modify: `assistant/hermes/scripts/init-mcp.sh`

**Acceptance Criteria:**
- [ ] Old HTTP block (`http://gbrain:3131`) stripped on upgrade before re-injecting
- [ ] New YAML block uses `command: "gbrain"` with `args: ["serve", "--home", "/opt/gbrain-home"]`
- [ ] Idempotent: re-running does not duplicate the injected block

**Verify:** `bash -n assistant/hermes/scripts/init-mcp.sh` → no syntax errors

---

### Task 1: Create sync-brain.sh + 05-start-sync-brain.sh

**Goal:** Periodic git pull of the mono-repo brain content and gbrain import when commits land.

**Files:**
- Create: `assistant/hermes/scripts/sync-brain.sh`
- Create: `assistant/hermes/scripts/05-start-sync-brain.sh`

**Acceptance Criteria:**
- [ ] `sync-brain.sh` detects new commits via HEAD SHA comparison before/after pull
- [ ] Only calls `gbrain import` when HEAD changed
- [ ] `05-start-sync-brain.sh` uses `#!/command/with-contenv sh` shebang
- [ ] PID guard prevents double-loop if cont-init.d reruns
- [ ] Loop interval reads `BRAIN_SYNC_INTERVAL` env var (default 300s)

**Verify:** `bash -n assistant/hermes/scripts/sync-brain.sh && bash -n assistant/hermes/scripts/05-start-sync-brain.sh`

---

### Task 2: Create gbrain-skills-watch.sh + 06-start-skills-watch.sh

**Goal:** Hot-reload gbrain skills via inotifywait when files change in the skills directory.

**Files:**
- Create: `assistant/hermes/scripts/gbrain-skills-watch.sh`
- Create: `assistant/hermes/scripts/06-start-skills-watch.sh`

**Acceptance Criteria:**
- [ ] `inotifywait -m -r` watches `$GBRAIN_HOME/.gbrain/skills` for close_write, create, delete, moved_to
- [ ] Each event triggers `gbrain import <SKILLS_DIR> --home <GBRAIN_HOME>`
- [ ] `06-start-skills-watch.sh` uses `#!/command/with-contenv sh` shebang
- [ ] PID guard prevents double-watcher
- [ ] Restart loop self-heals if inotifywait exits

**Verify:** `bash -n assistant/hermes/scripts/gbrain-skills-watch.sh && bash -n assistant/hermes/scripts/06-start-skills-watch.sh`

---

### Task 3: Update Dockerfile — install Bun + gbrain + inotify-tools

**Goal:** Extend `nousresearch/hermes-agent:latest` with all gbrain dependencies and copy init scripts.

**Files:**
- Modify: `assistant/hermes/Dockerfile`

**Acceptance Criteria:**
- [ ] `inotify-tools`, `git`, `curl`, `unzip` installed via apt
- [ ] Bun installed at pinned version via `BUN_INSTALL_VERSION` ARG
- [ ] `GBRAIN_REF` ARG wired into `git clone --branch "${GBRAIN_REF}"`
- [ ] All five scripts COPYed with `--chmod=755`

**Verify:** `docker build -t assistant-test assistant/hermes/` → image builds without error

---

### Task 4: Update docker-compose.yml — remove gbrain service, add volumes

**Goal:** Drop the standalone gbrain service; add mono-repo volumes for the hermes service.

**Files:**
- Modify: `assistant/docker-compose.yml`

**Acceptance Criteria:**
- [ ] No `gbrain` service in compose
- [ ] `.gbrain-data` parent mount listed BEFORE `gbrain-skills` child mount (prevents shadowing)
- [ ] `brain` mount is writable (no `:ro`) so `git pull` can succeed
- [ ] `GBRAIN_HOME`, `BRAIN_SYNC_INTERVAL`, `MONO_REPO_PATH` in hermes environment

**Verify:** `docker compose -f assistant/docker-compose.yml config` → valid compose config

---

### Task 5: Update .env.example

**Goal:** Remove gbrain-specific vars, add mono-repo vars.

**Files:**
- Modify: `assistant/.env.example`

**Acceptance Criteria:**
- [ ] `MONO_REPO_PATH` and `BRAIN_SYNC_INTERVAL` present
- [ ] Removed: `GBRAIN_ADMIN_TOKEN`, `GBRAIN_OPENAI_API_KEY`, `GBRAIN_REF`, `GBRAIN_IMAGE`
- [ ] Commented-out `ASSISTANT_IMAGE` override present

**Verify:** All vars in `.env.example` match what `docker-compose.yml` references

---

### Task 6: Update assistant/README.md

**Goal:** Document the two-container architecture with volume setup and quick-start.

**Files:**
- Modify: `assistant/README.md`

**Acceptance Criteria:**
- [ ] Two-container diagram (hermes + gdrive-mcp)
- [ ] Volume setup section explaining mono-repo path requirements
- [ ] Quick-start commands

**Verify:** File is valid Markdown

---

### Task 7: Create Ansible deploy-agent.yml + example vars

**Goal:** Day-2 operations playbook that clones/pulls both repos and restarts the assistant stack on the server.

**Files:**
- Create: `infrastructure/ansible/deploy-agent.yml`
- Create: `infrastructure/ansible/inventory/example/group_vars/servers/agent_swarm.yml`

**Acceptance Criteria:**
- [ ] Playbook clones agent-swarm repo if absent, pulls if present
- [ ] Playbook clones mono-repo if absent, pulls if present
- [ ] Restarts hermes via `docker compose up -d` in the assistant directory
- [ ] Example vars file documents `agent_swarm_repo`, `agent_swarm_path`, `mono_repo_url`, `mono_repo_path`

**Verify:** `ansible-playbook --syntax-check -i infrastructure/ansible/inventory/example infrastructure/ansible/deploy-agent.yml`
