#!/bin/sh
# init-mcp.sh — inject MCP server registrations into Hermes config on first boot.
#
# Runs as a cont-init.d script (s6-overlay legacy-cont-init) after
# 01-hermes-setup has seeded config.yaml from cli-config.yaml.example.
#
# Idempotency: a sentinel file prevents re-injection on subsequent boots.
# This means user edits to the mcp_servers block are preserved.
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
CONFIG="${HERMES_HOME}/config.yaml"
SENTINEL="${HERMES_HOME}/.mcp-init-done"

if [ -f "${SENTINEL}" ]; then
    echo "[hermes-mcp-init] MCP servers already registered — skipping"
    exit 0
fi

if [ ! -f "${CONFIG}" ]; then
    echo "[hermes-mcp-init] ERROR: ${CONFIG} not found — cannot inject MCP servers" >&2
    exit 1
fi

echo "[hermes-mcp-init] First boot detected — registering MCP servers in ${CONFIG}"

cat >> "${CONFIG}" << 'EOF'

# ── MCP servers injected by init-mcp.sh on first boot ────────────────────────
mcp_servers:
  gbrain:
    url: "http://gbrain:3131"
    timeout: 120
    connect_timeout: 30

  gdrive-mcp:
    url: "http://gdrive-mcp:3000/sse"
    transport: sse
    timeout: 120
    connect_timeout: 30
EOF

chown hermes:hermes "${CONFIG}" 2>/dev/null || true
chmod 640 "${CONFIG}" 2>/dev/null || true

s6-setuidgid hermes touch "${SENTINEL}" 2>/dev/null || touch "${SENTINEL}" || true

echo "[hermes-mcp-init] MCP config written — gbrain (http) and gdrive-mcp (sse) registered"
