#!/bin/sh
# init-mcp.sh — inject MCP server registrations into Hermes config on first boot.
#
# Runs as a cont-init.d script (s6-overlay legacy-cont-init) after
# 01-hermes-setup has seeded config.yaml from cli-config.yaml.example.
#
# Upgrade migration: if the sentinel exists but config.yaml still contains the
# old HTTP gbrain entry (url: http://gbrain:3131/mcp), the old injected block
# is stripped and the sentinel removed so this script re-injects on this boot.
#
# Idempotency: sentinel file prevents re-injection on subsequent boots.
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
CONFIG="${HERMES_HOME}/config.yaml"
SENTINEL="${HERMES_HOME}/.mcp-init-done"

# Migration: old stack used HTTP gbrain (url: http://gbrain:3131/mcp).
# Also migrate stdio gbrain that passed --home as an arg instead of via env.
# Strip the old injected block and remove sentinel so the new stdio entry
# is injected on this boot.
if [ -f "${SENTINEL}" ] && [ -f "${CONFIG}" ]; then
    if grep -q "http://gbrain:3131" "${CONFIG}" 2>/dev/null; then
        echo "[hermes-mcp-init] Detected old HTTP gbrain entry -- stripping and re-injecting"
        awk '/^# .* MCP servers injected by init-mcp.sh/{exit} {print}' \
            "${CONFIG}" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "${CONFIG}"
        rm -f "${SENTINEL}"
    elif grep -q -- "--home" "${CONFIG}" 2>/dev/null; then
        echo "[hermes-mcp-init] Detected old --home arg in gbrain entry -- stripping and re-injecting"
        awk '/^# .* MCP servers injected by init-mcp.sh/{exit} {print}' \
            "${CONFIG}" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "${CONFIG}"
        rm -f "${SENTINEL}"
    fi
fi

GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"

# Ensure gbrain home is owned by the hermes user and brain is initialized.
# init-mcp.sh runs as root; gbrain serve runs as hermes -- files must be writable by hermes.
mkdir -p "${GBRAIN_HOME}"
if [ -n "$(id -u hermes 2>/dev/null)" ]; then
    chown -R hermes:hermes "${GBRAIN_HOME}" 2>/dev/null || true
fi
if [ ! -f "${GBRAIN_HOME}/.gbrain/config.json" ]; then
    echo "[hermes-mcp-init] Initializing gbrain brain (PGLite, no embeddings)"
    s6-setuidgid hermes gbrain init --pglite --no-embedding 2>&1 || true
fi
# Disable gbrain self-upgrade: it auto-updates during startup which closes the
# MCP stdio connection before hermes completes the handshake.
if [ -f "${GBRAIN_HOME}/.gbrain/config.json" ]; then
    python3 -c "
import json, sys
p = '${GBRAIN_HOME}/.gbrain/config.json'
with open(p) as f: c = json.load(f)
if c.get('self_upgrade', {}).get('mode') != 'off':
    c['self_upgrade'] = {'mode': 'off'}
    with open(p, 'w') as f: json.dump(c, f, indent=2)
    print('[hermes-mcp-init] Disabled gbrain self-upgrade (mode=off)')
" 2>/dev/null || true
fi

if [ -f "${SENTINEL}" ]; then
    echo "[hermes-mcp-init] MCP servers already registered -- skipping"
    exit 0
fi

if [ ! -f "${CONFIG}" ]; then
    echo "[hermes-mcp-init] ERROR: ${CONFIG} not found -- cannot inject MCP servers" >&2
    exit 1
fi

echo "[hermes-mcp-init] Registering MCP servers in ${CONFIG}"

cat >> "${CONFIG}" << 'EOF'

# ── MCP servers injected by init-mcp.sh ──────────────────────────────────────
mcp_servers:
  gbrain:
    command: "gbrain"
    args: ["serve"]
    env:
      GBRAIN_HOME: "/opt/gbrain-home"
    timeout: 120

  gdrive-mcp:
    url: "http://gdrive-mcp:3000/sse"
    transport: sse
    timeout: 120
    connect_timeout: 30
EOF

chown hermes:hermes "${CONFIG}" 2>/dev/null || true
chmod 640 "${CONFIG}" 2>/dev/null || true

s6-setuidgid hermes touch "${SENTINEL}" 2>/dev/null || touch "${SENTINEL}" || true

echo "[hermes-mcp-init] MCP config written -- gbrain (stdio) and gdrive-mcp (sse) registered"
