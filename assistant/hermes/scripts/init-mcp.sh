#!/bin/sh
# init-mcp.sh — inject MCP server registrations into Hermes config on first boot.
#
# Runs as a cont-init.d script (s6-overlay legacy-cont-init) after
# 01-hermes-setup has seeded config.yaml from cli-config.yaml.example.
#
# Upgrade migration: if the sentinel exists but config.yaml still contains the
# old HTTP gbrain entry (url: http://gbrain:3131), remove the sentinel so this
# script re-injects with the new stdio command: entry.
#
# Idempotency: sentinel file prevents re-injection on subsequent boots.
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
CONFIG="${HERMES_HOME}/config.yaml"
SENTINEL="${HERMES_HOME}/.mcp-init-done"

# Migration: old stack used HTTP gbrain (url: http://gbrain:3131/mcp).
# Remove sentinel so the new stdio entry is injected on this boot.
if [ -f "${SENTINEL}" ] && [ -f "${CONFIG}" ]; then
    if grep -q "http://gbrain:3131" "${CONFIG}" 2>/dev/null; then
        echo "[hermes-mcp-init] Detected old HTTP gbrain entry — removing sentinel for re-injection"
        rm -f "${SENTINEL}"
    fi
fi

if [ -f "${SENTINEL}" ]; then
    echo "[hermes-mcp-init] MCP servers already registered — skipping"
    exit 0
fi

if [ ! -f "${CONFIG}" ]; then
    echo "[hermes-mcp-init] ERROR: ${CONFIG} not found — cannot inject MCP servers" >&2
    exit 1
fi

echo "[hermes-mcp-init] Registering MCP servers in ${CONFIG}"

cat >> "${CONFIG}" << 'EOF'

# ── MCP servers injected by init-mcp.sh ──────────────────────────────────────
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
EOF

chown hermes:hermes "${CONFIG}" 2>/dev/null || true
chmod 640 "${CONFIG}" 2>/dev/null || true

s6-setuidgid hermes touch "${SENTINEL}" 2>/dev/null || touch "${SENTINEL}" || true

echo "[hermes-mcp-init] MCP config written — gbrain (stdio) and gdrive-mcp (sse) registered"
