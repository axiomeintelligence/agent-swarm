# Hermes Native Skill Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers-extended-cc:subagent-driven-development (recommended) or superpowers-extended-cc:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the G-Brain skill-loading shim with native Hermes auto-scan via a read-only bind-mount of `mono/skills` into `/opt/data/skills/mono`, rename `BRAIN_SYNC_INTERVAL` to `SKILL_SYNC_INTERVAL`, and remove the now-redundant inotify watcher.

**Architecture:** Hermes ≥ this version scans `<HERMES_HOME>/skills/<category>/<name>/SKILL.md` live with no restart. Bind-mounting the mono repo's `skills/` directory directly onto that path means Hermes sees skills the instant `git pull` runs. The existing `sync-brain.sh` cron loop already pulls mono and imports `brain/` content into gbrain — skills come along for free under the same cadence (renamed `SKILL_SYNC_INTERVAL` to reflect the new user-facing semantics).

**Tech Stack:** Docker Compose, s6-overlay cont-init scripts (shell), Dockerfile, bash.

**Spec:** `docs/superpowers/specs/2026-06-23-hermes-native-skill-loading-design.md` (commit `ed49d7b`)

---

## File Structure

Three logical concerns → three tasks → three commits:

1. **Wiring** — `docker-compose.yml`, `hermes/Dockerfile`, `hermes/scripts/05-start-sync-brain.sh`; deletions of `hermes/scripts/06-start-skills-watch.sh` and `hermes/scripts/gbrain-skills-watch.sh`. Touches everything that affects what the image and container actually do.
2. **Documentation** — `assistant/.env.example`, `assistant/README.md`, `UPGRADE.md`. No runtime effect; tells operators what changed and what they need to do.
3. **Deployment** — apply on the live WMC server (`ubuntu-8gb-ash-1`). Manual `.env` migration + `docker compose up -d` + spec-verification checklist. No new code commit; this task closes the loop with empirical confirmation.

---

## Task 1: Swap gbrain-skills shim for native bind-mount and rename env var

**Goal:** After this task, the image builds without the inotify watcher, the compose template mounts `mono/skills` read-only into the Hermes category path, and the periodic sync loop reads `SKILL_SYNC_INTERVAL`. No documentation changes yet.

**Files:**
- Modify: `assistant/docker-compose.yml`
- Modify: `assistant/hermes/Dockerfile`
- Modify: `assistant/hermes/scripts/05-start-sync-brain.sh`
- Delete: `assistant/hermes/scripts/06-start-skills-watch.sh`
- Delete: `assistant/hermes/scripts/gbrain-skills-watch.sh`

**Acceptance Criteria:**
- [ ] `docker-compose.yml` no longer references `gbrain-skills` or `BRAIN_SYNC_INTERVAL`.
- [ ] `docker-compose.yml` mounts `${MONO_REPO_PATH}/skills:/opt/data/skills/mono:ro` and sets `SKILL_SYNC_INTERVAL=${SKILL_SYNC_INTERVAL:-300}`.
- [ ] `Dockerfile` no longer copies the deleted scripts and no longer installs `inotify-tools` (only consumer was the deleted watcher).
- [ ] `05-start-sync-brain.sh` reads `${SKILL_SYNC_INTERVAL:-300}`.
- [ ] `assistant/hermes/scripts/06-start-skills-watch.sh` and `assistant/hermes/scripts/gbrain-skills-watch.sh` do not exist.
- [ ] `cd assistant && MONO_REPO_PATH=/tmp/mono docker compose config` succeeds and shows the new mount + env var.
- [ ] `cd assistant && docker compose build hermes` succeeds.

**Verify:**
```bash
cd /Users/zmoshansky/git/agent-swarm/assistant && \
  ! grep -rn 'BRAIN_SYNC_INTERVAL\|gbrain-skills\|inotify' \
    docker-compose.yml hermes/Dockerfile hermes/scripts/ 2>/dev/null && \
  test ! -f hermes/scripts/06-start-skills-watch.sh && \
  test ! -f hermes/scripts/gbrain-skills-watch.sh && \
  MONO_REPO_PATH=/tmp/mono docker compose config | grep -E 'skills:/opt/data/skills/mono:ro|SKILL_SYNC_INTERVAL' && \
  docker compose build hermes
```
Expected: command exits 0; the `grep -E` line shows both the mount and the env-var; build completes successfully.

**Steps:**

- [ ] **Step 1: Modify `assistant/docker-compose.yml`** — swap the mount and rename the env var.

Replace line 21:
```yaml
      - ${MONO_REPO_PATH}/gbrain-skills:/opt/gbrain-home/.gbrain/skills
```
with:
```yaml
      - ${MONO_REPO_PATH}/skills:/opt/data/skills/mono:ro
```

Replace line 52:
```yaml
      - BRAIN_SYNC_INTERVAL=${BRAIN_SYNC_INTERVAL:-300}
```
with:
```yaml
      - SKILL_SYNC_INTERVAL=${SKILL_SYNC_INTERVAL:-300}
```

- [ ] **Step 2: Modify `assistant/hermes/scripts/05-start-sync-brain.sh`** — rename the interval env var.

Replace line 11:
```sh
    sleep "${BRAIN_SYNC_INTERVAL:-300}"
```
with:
```sh
    sleep "${SKILL_SYNC_INTERVAL:-300}"
```

- [ ] **Step 3: Delete the watcher scripts.**

```bash
cd /Users/zmoshansky/git/agent-swarm
rm assistant/hermes/scripts/06-start-skills-watch.sh
rm assistant/hermes/scripts/gbrain-skills-watch.sh
```

- [ ] **Step 4: Modify `assistant/hermes/Dockerfile`** — drop the COPYs for the deleted scripts and drop `inotify-tools` from the apt install (only the deleted watcher used it).

Replace lines 3–9:
```dockerfile
# ── System deps for gbrain + skills hot-reload ────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    inotify-tools \
    git \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*
```
with:
```dockerfile
# ── System deps for gbrain ────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    unzip \
    && rm -rf /var/lib/apt/lists/*
```

Replace lines 26–40 (the cont-init.d comment block and the COPY lines):
```dockerfile
# ── cont-init.d scripts ───────────────────────────────────────────────────────
# Run in lexicographic order after 01-hermes-setup seeds config.yaml:
#   02-gbrain-http        -- starts gbrain as HTTP MCP server on localhost:3131
#   03-mcp-config         -- injects MCP server registrations (gbrain HTTP + gdrive-mcp sse)
#   05-start-sync-brain   -- backgrounds periodic mono-repo sync loop
#   06-start-skills-watch -- backgrounds inotifywait skills hot-reload

COPY --chmod=755 scripts/02-gbrain-http.sh        /etc/cont-init.d/02-gbrain-http
COPY --chmod=755 scripts/init-mcp.sh              /etc/cont-init.d/03-mcp-config
COPY --chmod=755 scripts/05-start-sync-brain.sh   /etc/cont-init.d/05-start-sync-brain
COPY --chmod=755 scripts/06-start-skills-watch.sh /etc/cont-init.d/06-start-skills-watch

# ── Helper scripts in PATH ────────────────────────────────────────────────────
COPY --chmod=755 scripts/sync-brain.sh          /usr/local/bin/sync-brain.sh
COPY --chmod=755 scripts/gbrain-skills-watch.sh /usr/local/bin/gbrain-skills-watch.sh
```
with:
```dockerfile
# ── cont-init.d scripts ───────────────────────────────────────────────────────
# Run in lexicographic order after 01-hermes-setup seeds config.yaml:
#   02-gbrain-http      -- starts gbrain as HTTP MCP server on localhost:3131
#   03-mcp-config       -- injects MCP server registrations (gbrain HTTP + gdrive-mcp sse)
#   05-start-sync-brain -- backgrounds periodic mono-repo pull (skills + brain content)

COPY --chmod=755 scripts/02-gbrain-http.sh      /etc/cont-init.d/02-gbrain-http
COPY --chmod=755 scripts/init-mcp.sh            /etc/cont-init.d/03-mcp-config
COPY --chmod=755 scripts/05-start-sync-brain.sh /etc/cont-init.d/05-start-sync-brain

# ── Helper scripts in PATH ────────────────────────────────────────────────────
COPY --chmod=755 scripts/sync-brain.sh /usr/local/bin/sync-brain.sh
```

- [ ] **Step 5: Verify the change is internally complete.**

Run from the repo root:
```bash
cd /Users/zmoshansky/git/agent-swarm
grep -rn 'BRAIN_SYNC_INTERVAL\|gbrain-skills\|inotify' \
  assistant/docker-compose.yml \
  assistant/hermes/Dockerfile \
  assistant/hermes/scripts/ 2>/dev/null
```
Expected: no output (exit 1 from grep is fine).

```bash
test -f assistant/hermes/scripts/06-start-skills-watch.sh && echo "STILL THERE" || echo "deleted"
test -f assistant/hermes/scripts/gbrain-skills-watch.sh && echo "STILL THERE" || echo "deleted"
```
Expected: both print `deleted`.

- [ ] **Step 6: Validate compose template.**

```bash
cd /Users/zmoshansky/git/agent-swarm/assistant
MONO_REPO_PATH=/tmp/mono docker compose config | grep -E 'skills:/opt/data/skills/mono:ro|SKILL_SYNC_INTERVAL'
```
Expected output (order may vary):
```
      - /tmp/mono/skills:/opt/data/skills/mono:ro
      SKILL_SYNC_INTERVAL: '300'
```

- [ ] **Step 7: Build the image to confirm Dockerfile is still valid.**

```bash
cd /Users/zmoshansky/git/agent-swarm/assistant
docker compose build hermes
```
Expected: build completes without errors. The build may pull a lot of layers; that's fine.

- [ ] **Step 8: Commit.**

```bash
cd /Users/zmoshansky/git/agent-swarm
git add assistant/docker-compose.yml \
        assistant/hermes/Dockerfile \
        assistant/hermes/scripts/05-start-sync-brain.sh
git rm assistant/hermes/scripts/06-start-skills-watch.sh \
       assistant/hermes/scripts/gbrain-skills-watch.sh
git commit -m "feat(assistant): native Hermes skill loading via mono bind-mount

Mount mono/skills read-only at /opt/data/skills/mono so Hermes
auto-scans skills with no watcher. Rename BRAIN_SYNC_INTERVAL
to SKILL_SYNC_INTERVAL (no legacy alias). Drop inotify-tools
and the gbrain-skills-watch scripts."
```

---

## Task 2: Update operator-facing docs (.env.example, README.md, UPGRADE.md)

**Goal:** Operators reading the repo learn the new mono layout (`skills/` instead of `gbrain-skills/`), the renamed env var, the read-only mount semantics, and how to migrate an existing deployment.

**Files:**
- Modify: `assistant/.env.example`
- Modify: `assistant/README.md`
- Modify: `UPGRADE.md`

**Acceptance Criteria:**
- [ ] `.env.example` documents `<MONO_REPO_PATH>/skills/` as the Hermes skills source (not `gbrain-skills/`).
- [ ] `.env.example` defines `SKILL_SYNC_INTERVAL=300` and does not define `BRAIN_SYNC_INTERVAL`.
- [ ] `README.md` environment-variables table has a `SKILL_SYNC_INTERVAL` row with default `300` and no `BRAIN_SYNC_INTERVAL` row.
- [ ] `README.md` documents the mono layout (`brain/` + `skills/`) and notes that the `mono` skills category is read-only inside the container.
- [ ] `UPGRADE.md` has a new top entry dated 2026-06-23 with migration steps for existing deployments.
- [ ] `grep -rn 'BRAIN_SYNC_INTERVAL\|gbrain-skills' assistant/ UPGRADE.md` returns only references inside `UPGRADE.md`'s migration history (i.e., the new entry mentioning the *old* name is allowed; nothing else).

**Verify:**
```bash
cd /Users/zmoshansky/git/agent-swarm && \
  grep -q '^SKILL_SYNC_INTERVAL=300$' assistant/.env.example && \
  ! grep -q '^BRAIN_SYNC_INTERVAL' assistant/.env.example && \
  grep -q 'SKILL_SYNC_INTERVAL' assistant/README.md && \
  ! grep -qE '\| `BRAIN_SYNC_INTERVAL`' assistant/README.md && \
  grep -q '2026-06-23' UPGRADE.md && \
  echo OK
```
Expected: `OK`.

**Steps:**

- [ ] **Step 1: Modify `assistant/.env.example`** — update the mono-path comment block and rename the env var.

Replace lines 24–33:
```bash
# ── Mono-repo ─────────────────────────────────────────────────────────────────
# Absolute path on the host where your mono-repo is cloned.
# Volumes for brain content, skills, and G-Brain state are mounted from here:
#   <MONO_REPO_PATH>/brain/           -> /brain-repo          (read-only content source)
#   <MONO_REPO_PATH>/gbrain-skills/   -> G-Brain skills dir   (hot-reload on change)
#   <MONO_REPO_PATH>/.gbrain-data/    -> G-Brain PGLite DB    (persistent state)
MONO_REPO_PATH=/path/to/your/mono-repo

# How often (seconds) to poll the mono-repo for new commits and re-import.
BRAIN_SYNC_INTERVAL=300
```
with:
```bash
# ── Mono-repo ─────────────────────────────────────────────────────────────────
# Absolute path on the host where your mono-repo is cloned.
# Volumes for brain content, skills, and G-Brain state are mounted from here:
#   <MONO_REPO_PATH>/brain/         -> /brain-repo                (G-Brain knowledge source)
#   <MONO_REPO_PATH>/skills/        -> /opt/data/skills/mono (ro) (Hermes skills, category `mono`)
#   <MONO_REPO_PATH>/.gbrain-data/  -> G-Brain PGLite DB          (persistent state)
MONO_REPO_PATH=/path/to/your/mono-repo

# How often (seconds) to git-pull the mono-repo. One tick refreshes both
# the Hermes skills tree (auto-loaded on read) and re-imports brain/ into G-Brain.
SKILL_SYNC_INTERVAL=300
```

- [ ] **Step 2: Modify `assistant/README.md`** — replace the env-var table row and add the mono-layout / read-only notes.

Replace line 56:
```
| `BRAIN_SYNC_INTERVAL` | No | `3600` | Seconds between automatic G-Brain sync runs |
```
with:
```
| `SKILL_SYNC_INTERVAL` | No | `300` | Seconds between mono-repo `git pull` ticks (refreshes Hermes skills + re-imports `brain/` into G-Brain) |
```

In the same file, locate the `## Volumes` section (starts around line 71) and replace the row currently describing the mono mount with an updated block. Replace lines 78–79:
```
| `<MONO_REPO_PATH>` | Mono-repo source (mounted read-only at `/opt/mono-repo`) |
| `/opt/mono-repo/docs/` | G-Brain indexes scanned documents from here |
```
with:
```
| `<MONO_REPO_PATH>/brain/` | G-Brain knowledge source; periodically re-imported into PGLite |
| `<MONO_REPO_PATH>/skills/` | Hermes skill packs; bind-mounted **read-only** at `/opt/data/skills/mono`. Hermes auto-scans new `SKILL.md` files within one `SKILL_SYNC_INTERVAL` tick. Authoring is via `git` in the mono repo — `hermes skills install --category mono` is not supported (mount is read-only by design). |
| `<MONO_REPO_PATH>/.gbrain-data/` | G-Brain PGLite database; persistent state |
```

- [ ] **Step 3: Add an entry to `UPGRADE.md`** at the top of the change-log section (after the header on line 5).

Insert this block immediately after the `---` on line 5:
```markdown

## 2026-06-23 — Native Hermes skill loading; `BRAIN_SYNC_INTERVAL` → `SKILL_SYNC_INTERVAL`

### What changed

- **`assistant/docker-compose.yml`** — mono skills now bind-mounted read-only at `/opt/data/skills/mono` so Hermes auto-loads them natively (no gbrain hop). The previous `${MONO_REPO_PATH}/gbrain-skills` mount is removed.
- **Env var rename:** `BRAIN_SYNC_INTERVAL` → `SKILL_SYNC_INTERVAL`. The script reads only the new name; if a server `.env` still uses the old name it will be silently ignored and the script default (300 s) will apply.
- **Deleted scripts:** `assistant/hermes/scripts/06-start-skills-watch.sh` and `assistant/hermes/scripts/gbrain-skills-watch.sh`. Hermes auto-scans the skills tree — no inotify watcher needed.
- **Dockerfile:** dropped `inotify-tools` (only the deleted watcher used it).

### Migration (per existing deployment)

1. On the host, rename the variable in the server-side `assistant/.env`:
   ```bash
   sed -i 's/^BRAIN_SYNC_INTERVAL=/SKILL_SYNC_INTERVAL=/' /opt/<deployment>/assistant/.env
   ```
2. In the mono repo, create `skills/` at the top level (or rename the existing `gbrain-skills/` to `skills/`) and ensure at least one `<name>/SKILL.md` exists. Commit and push.
3. On the host, ensure the bind-mount target exists in case the mono repo hasn't been pulled yet:
   ```bash
   mkdir -p ${MONO_REPO_PATH}/skills
   ```
4. Pull the new image and recreate the stack:
   ```bash
   cd /opt/<deployment>/assistant
   docker compose pull
   docker compose up -d
   ```
5. Verify (inside the running container):
   ```bash
   docker exec -u hermes <container> hermes skills list | grep mono
   ```
   Expected: one row per `mono/skills/<name>/SKILL.md`, status `enabled`.

### Why

Hermes' built-in skills system is now mature: dropping a `SKILL.md` into `<HERMES_HOME>/skills/<category>/<name>/` makes it appear in `hermes skills list` immediately, with no restart and no registration step. The gbrain-as-skill-store layer (inotify watcher + `gbrain import` + MCP retrieval) was a workaround from earlier Hermes versions and is no longer required.

---
```

- [ ] **Step 4: Verify docs are internally consistent.**

```bash
cd /Users/zmoshansky/git/agent-swarm
grep -q '^SKILL_SYNC_INTERVAL=300$' assistant/.env.example
echo "env.example: $?"

grep -q 'BRAIN_SYNC_INTERVAL' assistant/.env.example && echo "env.example STILL has old name" || echo "env.example: clean"

grep -q 'SKILL_SYNC_INTERVAL' assistant/README.md
echo "README has new name: $?"

grep -qE '\| `BRAIN_SYNC_INTERVAL`' assistant/README.md && echo "README STILL has old row" || echo "README: clean"

grep -q '2026-06-23' UPGRADE.md
echo "UPGRADE has entry: $?"
```
Expected: every line ends in `0` or prints `clean`.

- [ ] **Step 5: Commit.**

```bash
cd /Users/zmoshansky/git/agent-swarm
git add assistant/.env.example assistant/README.md UPGRADE.md
git commit -m "docs(assistant): document native Hermes skill loading + SKILL_SYNC_INTERVAL rename

Update .env.example mono-layout block, replace README env-var table
row (BRAIN_SYNC_INTERVAL/default 3600 → SKILL_SYNC_INTERVAL/default 300),
note the read-only mono category, and add UPGRADE.md migration steps."
```

---

## Task 3: Deploy to WMC server and verify against spec checklist

**Goal:** Live deployment on `cloud_user@ubuntu-8gb-ash-1` (`/opt/wmc-agent-swarm`) reflects the new wiring; all seven verification items from the spec pass. No new commit in this repo; this task is the operational rollout.

**Files:**
- Modify on host: `/opt/wmc-agent-swarm/assistant/.env`
- Possibly modify on host: `/opt/wmc-mono` directory structure (rename `gbrain-skills/` → `skills/` if non-empty; otherwise create `skills/`)

**Acceptance Criteria:**
- [ ] Spec verification item 1 passes: `hermes skills list | grep mono` enumerates every `mono/skills/*/SKILL.md` as `local`/`enabled`.
- [ ] Spec verification item 2 passes: dropping a probe `SKILL.md` into mono + push + `sync-brain.sh` makes it appear in `hermes skills list` within seconds.
- [ ] Spec verification item 3 passes: `touch /opt/data/skills/mono/__write_probe` fails with `Read-only file system`.
- [ ] Spec verification item 4 passes: gbrain MCP still answers `brain/`-content queries.
- [ ] Spec verification item 5 passes: `/etc/cont-init.d/` no longer contains `06-start-skills-watch`.
- [ ] Spec verification item 6 passes: no `[gbrain-skills-watch]` lines in fresh container logs.
- [ ] Spec verification item 7 passes: container env has `SKILL_SYNC_INTERVAL` and no `BRAIN_SYNC_INTERVAL`.

**Verify:**
The collection of `Step N` verify commands below collectively prove the acceptance criteria. The task is complete when every step's "Expected" output is observed.

**Steps:**

- [ ] **Step 1: Wait for the image to publish** to GHCR after Task 1's commit hits `main`.

```bash
gh run list --workflow publish-assistant.yml --limit 3
```
Expected: most recent run for the Task 1 commit shows `completed / success`. If still running, wait. (CI tags `latest` and `sha-<commit>`.)

- [ ] **Step 2: Pull latest agent-swarm on the server.**

```bash
ssh cloud_user@ubuntu-8gb-ash-1 'cd /opt/wmc-agent-swarm && git pull --ff-only'
```
Expected: pull succeeds and includes both commits from Tasks 1 + 2.

- [ ] **Step 3: Migrate the server-side `.env`.**

```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  'grep -E "^(BRAIN_SYNC_INTERVAL|SKILL_SYNC_INTERVAL)=" /opt/wmc-agent-swarm/assistant/.env'
```
Expected: shows `BRAIN_SYNC_INTERVAL=300` (the value we appended during the original WMC deploy). If `SKILL_SYNC_INTERVAL` is already present, skip the next command.

```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  'sed -i.bak "s/^BRAIN_SYNC_INTERVAL=/SKILL_SYNC_INTERVAL=/" /opt/wmc-agent-swarm/assistant/.env && \
   grep -E "^(BRAIN_SYNC_INTERVAL|SKILL_SYNC_INTERVAL)=" /opt/wmc-agent-swarm/assistant/.env'
```
Expected: shows `SKILL_SYNC_INTERVAL=300` only; backup left at `assistant/.env.bak`.

- [ ] **Step 4: Ensure the mono `skills/` mount target exists with a probe skill** so the bind-mount has something to enumerate.

```bash
ssh cloud_user@ubuntu-8gb-ash-1 'ls /opt/wmc-mono/'
```
If `gbrain-skills/` exists and contains real skills, rename it:
```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  '[ -d /opt/wmc-mono/gbrain-skills ] && [ "$(ls -A /opt/wmc-mono/gbrain-skills 2>/dev/null)" ] && \
   mv /opt/wmc-mono/gbrain-skills /opt/wmc-mono/skills || mkdir -p /opt/wmc-mono/skills'
```
Then drop a placeholder skill (so verification item 1 has something to enumerate even if the mono repo is empty):
```bash
ssh cloud_user@ubuntu-8gb-ash-1 'mkdir -p /opt/wmc-mono/skills/wmc-placeholder && \
  cat > /opt/wmc-mono/skills/wmc-placeholder/SKILL.md <<"EOF"
---
name: wmc-placeholder
description: Placeholder mono skill confirming the bind-mount is live. Replace with real skills committed to services-wmc/mono.
---

# wmc-placeholder

The `mono` category is mounted **read-only** from `${MONO_REPO_PATH}/skills`. To add or modify a `mono` skill, edit `services-wmc/mono` and push — Hermes will pick up the change within one `SKILL_SYNC_INTERVAL` tick (default 300 s).
EOF'
```

- [ ] **Step 5: Pull the new image and recreate the stack.**

```bash
ssh cloud_user@ubuntu-8gb-ash-1 'cd /opt/wmc-agent-swarm/assistant && docker compose pull hermes && docker compose up -d hermes'
```
Expected: hermes is `Recreated` and starts cleanly.

- [ ] **Step 6: Verify spec item 5 + 6** (script and watcher are gone inside the container).

```bash
ssh cloud_user@ubuntu-8gb-ash-1 'docker exec WMC-assistant ls /etc/cont-init.d/'
```
Expected: no `06-start-skills-watch` line.

```bash
ssh cloud_user@ubuntu-8gb-ash-1 'docker logs WMC-assistant 2>&1 | grep -c "\[gbrain-skills-watch\]"'
```
Expected: `0`.

- [ ] **Step 7: Verify spec item 7** (env var rename is live).

```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  'docker exec WMC-assistant sh -c "env | grep -E \"BRAIN_SYNC_INTERVAL|SKILL_SYNC_INTERVAL\""'
```
Expected: exactly one line, `SKILL_SYNC_INTERVAL=300`.

- [ ] **Step 8: Verify spec item 3** (mount is read-only).

```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  'docker exec WMC-assistant sh -c "touch /opt/data/skills/mono/__write_probe 2>&1"; echo "exit=$?"'
```
Expected: error message containing `Read-only file system` and `exit=1`.

- [ ] **Step 9: Verify spec item 1** (`hermes skills list` enumerates mono skills).

```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  'docker exec -u hermes WMC-assistant sh -c "HERMES_HOME=/opt/data hermes skills list" | grep mono'
```
Expected: at least one row containing `wmc-placeholder` and category `mono`, status `enabled`.

- [ ] **Step 10: Verify spec item 2** (hot-load via mono `git pull`). Skip if `services-wmc/mono` has no real new content to push — the placeholder added in Step 4 already proves auto-scan. If you want the full end-to-end check:

```bash
# On your laptop, in a clone of services-wmc/mono:
mkdir -p skills/hotload-probe
cat > skills/hotload-probe/SKILL.md <<'EOF'
---
name: hotload-probe
description: Temporary probe to verify mono → Hermes hot-load. Safe to delete after verification.
---
# hotload-probe
Verify-only.
EOF
git add skills/hotload-probe && git commit -m "test: hotload probe" && git push
```
Then on the server:
```bash
ssh cloud_user@ubuntu-8gb-ash-1 'docker exec WMC-assistant sync-brain.sh && sleep 2 && \
  docker exec -u hermes WMC-assistant sh -c "HERMES_HOME=/opt/data hermes skills list" | grep hotload-probe'
```
Expected: a row containing `hotload-probe` / category `mono` / `enabled`. Then revert the probe commit on the mono side.

- [ ] **Step 11: Verify spec item 4** (gbrain MCP still works for `brain/` content).

```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  'docker exec WMC-assistant sh -c "curl -sf http://localhost:3131/health"'
```
Expected: HTTP 200 / health-OK response.

```bash
ssh cloud_user@ubuntu-8gb-ash-1 \
  'docker exec -u hermes WMC-assistant sh -c "HERMES_HOME=/opt/data hermes mcp test gbrain" 2>&1 | head -5'
```
Expected: `✓ Connected` and `✓ Tools discovered: N` (N > 0).

- [ ] **Step 12: Confirm the rollout is clean.**

```bash
ssh cloud_user@ubuntu-8gb-ash-1 'cd /opt/wmc-agent-swarm/assistant && docker compose ps'
```
Expected: `WMC-assistant` and `WMC-assistant-gdrive-mcp` both `Up` and healthy.

If every step's expected output matched, the rollout is complete. Notify the user; no commit on this task.

---

## Out of scope

- Per-instance Hermes categories (`mono` is static — handled by a future change if multi-instance arrives).
- A `mono-pack` Hermes bundle (`hermes bundles create ...`).
- CI-level skill format validation (`hermes skills audit` is ad-hoc).
- Two-way authoring of `mono` skills via Hermes CLI (mount is read-only by design).
- Migrating existing gbrain-imported skill *content* into Hermes-native form (assumed minimal/none in WMC).
