#!/bin/sh
# sync-brain.sh -- pull mono-repo and import content into gbrain.
# Manual use: docker exec <container-name> sync-brain.sh
set -e

BRAIN_REPO="${BRAIN_REPO:-/brain-repo}"
GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"
GBRAIN_PORT="${GBRAIN_PORT:-3131}"
TOKEN_FILE="/tmp/gbrain-http-token"

if ! git -C "${BRAIN_REPO}" rev-parse HEAD >/dev/null 2>&1; then
    echo "[sync-brain] ${BRAIN_REPO} is not a git repo -- skipping"
    exit 0
fi

BEFORE=$(git -C "${BRAIN_REPO}" rev-parse HEAD)
if ! git -C "${BRAIN_REPO}" pull --ff-only 2>&1; then
    echo "[sync-brain] WARNING: git pull failed -- skipping import this cycle" >&2
    exit 0
fi
AFTER=$(git -C "${BRAIN_REPO}" rev-parse HEAD)

if [ "${BEFORE}" = "${AFTER}" ]; then
    echo "[sync-brain] No new commits at $(date -u +%H:%M:%SZ)"
    exit 0
fi

BEFORE_SHORT=$(printf '%.8s' "${BEFORE}")
AFTER_SHORT=$(printf '%.8s' "${AFTER}")
echo "[sync-brain] New commits (${BEFORE_SHORT}..${AFTER_SHORT}) -- importing"

# When gbrain is running as an HTTP server (02-gbrain-http), the CLI cannot
# acquire the PGLite write lock. Use the gbrain CLI only in stdio/standalone mode.
if curl -sf "http://localhost:${GBRAIN_PORT}/health" >/dev/null 2>&1; then
    # HTTP server is running -- attempt import via MCP tool call if token exists.
    ACCESS_TOKEN=""
    if [ -f "${TOKEN_FILE}" ]; then
        ACCESS_TOKEN=$(cat "${TOKEN_FILE}")
    fi
    if [ -n "${ACCESS_TOKEN}" ]; then
        RESULT=$(curl -sf -X POST "http://localhost:${GBRAIN_PORT}/mcp" \
            -H "Authorization: Bearer ${ACCESS_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"import_documents\",\"arguments\":{\"path\":\"${BRAIN_REPO}\"}}}" \
            2>/dev/null) || true
        if [ -n "${RESULT}" ]; then
            echo "[sync-brain] Import via MCP HTTP completed"
        else
            echo "[sync-brain] WARNING: MCP import call returned no response -- skipping" >&2
        fi
    else
        echo "[sync-brain] WARNING: gbrain HTTP running but no token -- skipping import" >&2
    fi
else
    # No HTTP server -- use CLI directly.
    gbrain import "${BRAIN_REPO}"
fi
