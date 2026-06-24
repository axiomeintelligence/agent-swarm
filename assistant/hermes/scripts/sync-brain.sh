#!/bin/sh
# sync-brain.sh -- pull mono-repo and import brain content into gbrain.
# Manual use: docker exec <container-name> sync-brain.sh
#
# Two paths matter:
#   MONO_ROOT     -- the mono repo's working-tree root (must contain .git).
#                    Used for `git pull`. Defaults to /mono-repo, which the
#                    compose file bind-mounts from ${MONO_REPO_PATH}.
#   BRAIN_CONTENT -- subtree to feed into gbrain via `import_documents`.
#                    Defaults to the brain/ subdir under this stack's config tree.
set -e

MONO_ROOT="${MONO_ROOT:-/mono-repo}"
BRAIN_CONTENT="${BRAIN_CONTENT:-${MONO_ROOT}/agent-swarm/config/assistant/brain}"
GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"
GBRAIN_PORT="${GBRAIN_PORT:-3131}"
TOKEN_FILE="/tmp/gbrain-http-token"

if ! git -C "${MONO_ROOT}" rev-parse HEAD >/dev/null 2>&1; then
    echo "[sync-brain] ${MONO_ROOT} is not a git repo -- skipping"
    exit 0
fi

BEFORE=$(git -C "${MONO_ROOT}" rev-parse HEAD)
if ! git -C "${MONO_ROOT}" pull --ff-only 2>&1; then
    echo "[sync-brain] WARNING: git pull failed -- skipping import this cycle" >&2
    exit 0
fi
AFTER=$(git -C "${MONO_ROOT}" rev-parse HEAD)

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
            -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"import_documents\",\"arguments\":{\"path\":\"${BRAIN_CONTENT}\"}}}" \
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
    gbrain import "${BRAIN_CONTENT}"
fi
