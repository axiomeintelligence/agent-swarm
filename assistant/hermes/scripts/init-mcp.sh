#!/bin/sh
# 03-mcp-config — inject MCP server registrations into Hermes config.
#
# Runs after 02-gbrain-http has started gbrain as an HTTP MCP server and
# written the bearer token to /tmp/gbrain-http-token.
#
# Always strips the previously injected block and re-injects with a fresh
# token — no sentinel, so the token in config.yaml stays current on each boot.
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
CONFIG="${HERMES_HOME}/config.yaml"
TOKEN_FILE="/tmp/gbrain-http-token"
GBRAIN_PORT="${GBRAIN_PORT:-3131}"

if [ ! -f "${CONFIG}" ]; then
    echo "[hermes-mcp-init] ERROR: ${CONFIG} not found -- cannot inject MCP servers" >&2
    exit 1
fi

# ── Strip any previously injected block ───────────────────────────────────────
if grep -q "^# .* MCP servers injected by init-mcp.sh" "${CONFIG}" 2>/dev/null; then
    echo "[hermes-mcp-init] Stripping old MCP block for re-injection"
    awk '/^# .* MCP servers injected by init-mcp.sh/{exit} {print}' \
        "${CONFIG}" > "${CONFIG}.tmp" && mv "${CONFIG}.tmp" "${CONFIG}"
fi

# ── Read gbrain bearer token ──────────────────────────────────────────────────
ACCESS_TOKEN=""
if [ -f "${TOKEN_FILE}" ]; then
    ACCESS_TOKEN=$(cat "${TOKEN_FILE}")
fi
if [ -z "${ACCESS_TOKEN}" ]; then
    echo "[hermes-mcp-init] WARNING: No gbrain token found -- gbrain will not be registered" >&2
fi

echo "[hermes-mcp-init] Registering MCP servers in ${CONFIG}"

# ── Inject gbrain (HTTP) if token is available ────────────────────────────────
if [ -n "${ACCESS_TOKEN}" ]; then
    cat >> "${CONFIG}" << YAML

# ── MCP servers injected by init-mcp.sh ──────────────────────────────────────
mcp_servers:
  gbrain:
    url: "http://localhost:${GBRAIN_PORT}/mcp"
    headers:
      Authorization: "Bearer ${ACCESS_TOKEN}"
    timeout: 120
    connect_timeout: 30

YAML
else
    cat >> "${CONFIG}" << 'YAML'

# ── MCP servers injected by init-mcp.sh ──────────────────────────────────────
mcp_servers:
YAML
fi

# ── Inject gdrive-mcp (always) ────────────────────────────────────────────────
cat >> "${CONFIG}" << 'YAML'
  gdrive-mcp:
    url: "http://gdrive-mcp:3000/sse"
    transport: sse
    timeout: 120
    connect_timeout: 30
YAML

chown hermes:hermes "${CONFIG}" 2>/dev/null || true
chmod 640 "${CONFIG}" 2>/dev/null || true

if [ -n "${ACCESS_TOKEN}" ]; then
    echo "[hermes-mcp-init] MCP config written -- gbrain (HTTP localhost:${GBRAIN_PORT}) and gdrive-mcp registered"
else
    echo "[hermes-mcp-init] MCP config written -- gdrive-mcp only (gbrain token unavailable)"
fi
