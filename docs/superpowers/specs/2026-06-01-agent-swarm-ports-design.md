# Agent Swarm Ports Design

**Goal:** Extract agent container port rules into a shared `tasks/agent-swarm.yml` task file, imported by both `arcane.yml` and `komodo.yml`, so port management is not tied to a specific orchestrator.

**Architecture:** New `tasks/agent-swarm.yml` handles iptables rules for all agent-facing ports. Both orchestrator playbooks import it unconditionally. Hermes rules are removed from `tasks/arcane.yml`.

---

## Ports Managed

| Port | Service | Notes |
|---|---|---|
| 8642 | Hermes gateway API | Always open |
| 9119 | Hermes dashboard | Open when HERMES_DASHBOARD=1 |
| 3001 | DevBot web UI | Always open |

All rules scoped to `tailscale0` interface only.

## Tags

- `--tags agent-swarm` — open all three ports + persist
- `--tags teardown` (+ `never`) — remove all three rules + persist

## Integration

Both `arcane.yml` and `komodo.yml` import `tasks/agent-swarm.yml` with `tags: agent-swarm`, running it automatically on every deploy.
