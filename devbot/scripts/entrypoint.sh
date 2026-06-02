#!/usr/bin/env bash
set -euo pipefail

# ── 0. Validate required env vars ─────────────────────────────────────────
if [ -z "${GITHUB_PAT:-}" ]; then
  echo "[devbot] ERROR: GITHUB_PAT not set. Copy .env.example to .env and fill in values."
  exit 1
fi
if [ -z "${GITHUB_REPO_URL:-}" ]; then
  echo "[devbot] ERROR: GITHUB_REPO_URL not set."
  exit 1
fi

# ── 0b. Write Claude settings (skip permissions — sandboxed container) ────
export CLAUDE_SETTINGS="/home/claude/.claude/settings.json"
mkdir -p "$(dirname "$CLAUDE_SETTINGS")"
if [ ! -f "$CLAUDE_SETTINGS" ]; then
  echo '{}' > "$CLAUDE_SETTINGS"
fi
python3 - <<'EOF'
import json, os
path = os.environ.get("CLAUDE_SETTINGS", "/home/claude/.claude/settings.json")
with open(path) as f:
    s = json.load(f)
s["dangerouslySkipPermissions"] = True
with open(path, "w") as f:
    json.dump(s, f, indent=2)
EOF

# ── 1. Clone or pull repo ──────────────────────────────────────────────────
REPO_NAME=$(basename "${GITHUB_REPO_URL}" .git)
REPO_DIR="/workspace/${REPO_NAME}"

# Use a credential helper so the PAT is never stored in .git/config
git config --global credential.helper \
  '!f() { echo "username=x-access-token"; echo "password='"${GITHUB_PAT}"'"; }; f'

if [ ! -d "$REPO_DIR/.git" ]; then
  echo "[devbot] Cloning ${GITHUB_REPO_URL} ..."
  git clone "${GITHUB_REPO_URL}" "$REPO_DIR"
else
  echo "[devbot] Pulling latest changes ..."
  git -C "$REPO_DIR" pull --ff-only || {
    echo "[devbot] WARNING: Pull failed (branch diverged?). Continuing with existing state."
  }
fi

# ── 2. Install Claude plugins ──────────────────────────────────────────────
if [ -n "${CLAUDE_PLUGINS:-}" ]; then
  _add_marketplace() {
    local name="$1" source="$2"
    if ! claude plugin marketplace list 2>/dev/null | grep -q "$name"; then
      echo "[devbot] Registering marketplace: $name ..."
      claude plugin marketplace add "$source" || true
    fi
  }

  # Register marketplaces used by CLAUDE_PLUGINS defaults (idempotent)
  _add_marketplace "claude-plugins-official"             "anthropics/claude-plugins-official"
  _add_marketplace "superpowers-extended-cc-marketplace" "pcvelz/superpowers"
  _add_marketplace "mem0-plugins"                        "mem0ai/mem0"
  _add_marketplace "ui-ux-pro-max-skill"                 "nextlevelbuilder/ui-ux-pro-max-skill"

  echo "[devbot] Updating plugin marketplaces ..."
  claude plugin marketplace update 2>/dev/null || true

  IFS=',' read -ra PLUGINS <<< "$CLAUDE_PLUGINS"
  for plugin in "${PLUGINS[@]}"; do
    echo "[devbot] Installing plugin: $plugin"
    claude plugins install "$plugin" || true
  done
fi

# ── 2b. Clone skills repo (if provided) ───────────────────────────────────
if [ -n "${CLAUDE_SKILLS_REPO:-}" ]; then
  SKILLS_DIR="/home/claude/.claude/skills"
  if [ ! -d "$SKILLS_DIR/.git" ]; then
    echo "[devbot] Cloning skills repo ..."
    git clone --depth 1 "${CLAUDE_SKILLS_REPO}" "$SKILLS_DIR"
  else
    echo "[devbot] Pulling skills repo ..."
    git -C "$SKILLS_DIR" pull --ff-only || true
  fi
fi

# ── 3. Register Cloudflare MCP server (idempotent) ────────────────────────
if [ -n "${CLOUDFLARE_API_TOKEN:-}" ]; then
  if ! claude mcp list 2>/dev/null | grep -q "cloudflare"; then
    echo "[devbot] Registering Cloudflare MCP server ..."
    claude mcp add cloudflare -- npx -y @cloudflare/mcp-server-cloudflare
  else
    echo "[devbot] Cloudflare MCP already registered, skipping."
  fi
fi

# ── 4. Start claudecodeui ──────────────────────────────────────────────────
echo "[devbot] Starting claudecodeui on port 3001 ..."
cd /opt/claudecodeui
npm start &

# ── 5. Idle ───────────────────────────────────────────────────────────────
echo "[devbot] Ready. Attach via: docker exec -it ${HOSTNAME} bash"
echo "[devbot] Web UI: http://localhost:${HOST_PORT:-3001}"
tail -f /dev/null
