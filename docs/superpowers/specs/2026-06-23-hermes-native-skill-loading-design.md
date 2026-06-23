# Hermes Native Skill Loading — Design

**Date:** 2026-06-23
**Status:** Approved
**Scope:** `assistant/` stack — hermes container, mono-repo integration

## Goal

Replace the G-Brain-mediated skill loading path with native Hermes auto-scan. The mono repo's `skills/` directory becomes the single source of truth; Hermes reads it live via a read-only bind-mount. No inotify watcher, no `gbrain import` for skills, no MCP hop.

G-Brain remains for the `brain/` knowledge-content path — only the skills loader is replaced.

## Background

Today, mono-repo skills land in Hermes through G-Brain:

```
mono/gbrain-skills → bind-mount → /opt/gbrain-home/.gbrain/skills
                                → inotify watcher (gbrain-skills-watch.sh)
                                → gbrain import (PGLite)
                                → Hermes calls gbrain MCP to retrieve content
```

This was the right shim when Hermes' own skills system was thin. Hermes now ships a full skills loader (`hermes skills list/install/audit/bundles/...`) with categories under `<HERMES_HOME>/skills/<category>/<skill-name>/SKILL.md`, and it auto-scans that tree on every read — empirically verified by dropping a `SKILL.md` into `/opt/data/skills/test/probe/` on the running container and seeing it appear in `hermes skills list` with no restart.

Both Hermes and gbrain skill-packs already use the same industry-standard format: a per-skill directory containing `SKILL.md` with YAML frontmatter (`name`, `description`, optional `triggers`, …). The same files serve both loaders, so the migration is a wiring change, not a content change.

## Architecture

### New data flow

```
mono/skills → bind-mount (ro) → /opt/data/skills/mono
                              → Hermes native scanner (live)
```

### Mono-repo layout

```
mono/
├── brain/                          # gbrain knowledge content (unchanged)
└── skills/                         # NEW — replaces gbrain-skills/
    ├── <skill-a>/
    │   └── SKILL.md                # frontmatter: name, description, triggers, ...
    └── <skill-b>/
        └── SKILL.md
```

Flat layout — no sub-categories inside `mono/skills/`. All mono skills land under a single Hermes category named `mono`.

### Hermes side

- Mount target: `/opt/data/skills/mono` (i.e., `<HERMES_HOME>/skills/<category>`).
- Mount mode: read-only. Mono repo is the only place a `mono`-category skill can be added/removed/modified. Hermes' `skills install --category mono` and `skills uninstall mono/...` will fail with EROFS, by design.
- Refresh cadence: governed by `SKILL_SYNC_INTERVAL` (default 300 s). One `git pull` per tick refreshes both the bind-mounted skill tree (hot-loaded by Hermes) and the `brain/` content (imported into gbrain by the existing `sync-brain.sh`).
- No watcher: Hermes' auto-scan handles registration. The mono `git pull` is the only periodic action.

### Env-var rename

`BRAIN_SYNC_INTERVAL` → `SKILL_SYNC_INTERVAL` everywhere. No legacy alias. Server-side `.env` files are updated as part of the deploy.

Rationale: one variable, one cadence, but its user-visible effect is now primarily "how fast do new skills appear" — the brain import rides along for free.

## Concrete changes

### `assistant/docker-compose.yml`

Hermes service:

- **Remove** mount: `${MONO_REPO_PATH}/gbrain-skills:/opt/gbrain-home/.gbrain/skills`
- **Add** mount: `${MONO_REPO_PATH}/skills:/opt/data/skills/mono:ro`
- **Keep** mounts: `${MONO_REPO_PATH}/.gbrain-data:/opt/gbrain-home`, `${MONO_REPO_PATH}/brain:/brain-repo`
- **Rename** env: `BRAIN_SYNC_INTERVAL=${BRAIN_SYNC_INTERVAL:-300}` → `SKILL_SYNC_INTERVAL=${SKILL_SYNC_INTERVAL:-300}`

### `assistant/hermes/scripts/`

- **Delete** `06-start-skills-watch.sh` (no longer needed)
- **Delete** `gbrain-skills-watch.sh` (no longer needed)
- **Keep** `05-start-sync-brain.sh` + `sync-brain.sh` — these still drive the periodic `git pull` of mono and the `gbrain import` of `brain/` content. Update `05-start-sync-brain.sh`'s `sleep "${BRAIN_SYNC_INTERVAL:-300}"` → `sleep "${SKILL_SYNC_INTERVAL:-300}"`. No legacy alias.
- **Update** `02-gbrain-http.sh` — verify it does not reference, seed, or symlink skill paths. If it does, remove those bits. Skills are no longer gbrain's concern.

### `assistant/hermes/Dockerfile`

Remove both COPY lines for the deleted scripts:

- `COPY --chmod=755 scripts/06-start-skills-watch.sh /etc/cont-init.d/06-start-skills-watch` (line ~36)
- `COPY --chmod=755 scripts/gbrain-skills-watch.sh /usr/local/bin/gbrain-skills-watch.sh` (line ~40)

### `assistant/.env.example`

- Replace `BRAIN_SYNC_INTERVAL=300` with `SKILL_SYNC_INTERVAL=300`.
- Update the documentation comment block (line ~28) that enumerates `<MONO_REPO_PATH>` subdirectories: replace `gbrain-skills/` with `skills/` and update its description from "G-Brain skills dir (hot-reload on change)" to "Hermes skills dir (auto-scanned, category `mono`)".
- Update the comment for the interval var to describe the broader purpose (skills appear in Hermes within one tick; brain content re-imports into gbrain on the same tick).

### `assistant/README.md`

- Document the new mono layout (`brain/` + `skills/`).
- Replace the `BRAIN_SYNC_INTERVAL` table row (currently documents default `3600`, which is inconsistent with the actual `300` in `.env.example` and the script) with a `SKILL_SYNC_INTERVAL` row defaulting to `300`.
- Note: any `SKILL.md` placed under `skills/<name>/` appears in Hermes within one `SKILL_SYNC_INTERVAL` tick.
- Reference `hermes skills list` as the canonical verification command.
- Explicitly note that the `mono` category is read-only inside the container — authoring goes through `git` in the mono repo, not via `hermes skills install --category mono`.

### Inventory `agent_swarm.yml` template (`infrastructure/ansible/inventory/example/group_vars/servers/agent_swarm.yml`)

No structural change — paths are unchanged. Document the new `skills/` requirement in comments if the file already prescribes mono layout.

### `infrastructure/ansible/deploy-agent.yml`

No change required — the playbook does not pre-create mono subdirectories today (clone-only). Subdir creation remains a manual or instance-bootstrap concern, handled in `services-wmc/mono` (and equivalent) repos directly.

### `services-wmc/mono` (and any other instance mono repos)

One-time bootstrap step (manual, outside this repo's scope but documented in the migration section below):
- Add a top-level `skills/` directory containing at least one starter `SKILL.md` (so the bind-mount target exists and is non-empty for verification).

### Server-side migration

For each existing deployment:
1. Update `.env`: replace `BRAIN_SYNC_INTERVAL` with `SKILL_SYNC_INTERVAL`. Same value (default 300).
2. If `${MONO_REPO_PATH}/gbrain-skills/` exists, move/migrate any real content to `${MONO_REPO_PATH}/skills/` and remove the old directory.
3. `docker compose up -d` — hermes recreates with the new mount and env. Scripts have already been deleted from the image so nothing to clean inside the container.

## Skill author workflow

1. In the mono repo, create `skills/<new-skill>/SKILL.md` with frontmatter:
   ```yaml
   ---
   name: <new-skill>
   description: <one-liner>
   triggers:
     - <phrase>
   ---
   # <new-skill>
   <body>
   ```
2. `git commit && git push`.
3. Within ~5 min (or after manual `docker exec <container> sync-brain.sh`), `hermes skills list` shows the new skill under category `mono`, status `enabled`.
4. No container restart.

## Verification

Each item must pass before this design is considered shipped:

1. `docker exec -u hermes <container> hermes skills list | grep mono` enumerates every `mono/skills/*/SKILL.md` as `local`/`enabled`.
2. Drop a probe `SKILL.md` into mono, push, run `docker exec <container> sync-brain.sh`, confirm `hermes skills list` shows it within seconds.
3. `docker exec <container> touch /opt/data/skills/mono/__write_probe` fails with `Read-only file system`.
4. `gbrain` MCP still answers `brain/`-content queries (i.e., the unrelated path is untouched).
5. `docker exec <container> ls /etc/cont-init.d/` no longer contains `06-start-skills-watch`.
6. No `[gbrain-skills-watch]` lines in container logs after a fresh container start.
7. Container env shows `SKILL_SYNC_INTERVAL` set and no `BRAIN_SYNC_INTERVAL`.

## Out of scope

- **Per-instance categories.** Static `mono` for now; revisit if multiple instances accumulate distinct skill sets on the same server.
- **Hermes bundles.** A `mono-pack` bundle (`hermes bundles create mono-pack ...`) can be added later if a single slash command for all mono skills is desired.
- **Skill format validation in CI.** Rely on `hermes skills audit` ad-hoc.
- **Two-way authoring.** Mount stays read-only; authoring goes through git, not `hermes skills install --category mono`.
- **Migration of existing gbrain-imported skill *content* into Hermes-native form.** Assumed minimal-to-none at present; any conversion is a separate task.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Server `.env` files still reference `BRAIN_SYNC_INTERVAL` after image update. The sync script reads only `SKILL_SYNC_INTERVAL`, so it silently uses the script default (300 s). Same effective behavior as long as the operator kept the default, but a custom interval would be lost without warning. | Migration step in `UPGRADE.md` explicitly calls out the rename and instructs operators to rename the key in their server-side `.env`. Deploy playbook can later be extended to rewrite the line idempotently. |
| Empty `mono/skills/` directory means the bind-mount has nothing → no observable change vs. today's empty `gbrain-skills`. | Bootstrap step: add a placeholder skill to each instance's mono repo as part of migration. |
| Hermes auto-scan behavior changes in a future release (e.g., requires explicit registration). | Verification item #1 is a regression check; add to deploy smoke tests. |
| Read-only mount surprises an operator trying `hermes skills install --category mono`. | Document the design choice in `README.md` and in the `mono` category's own placeholder skill. |
