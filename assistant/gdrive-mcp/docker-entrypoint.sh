#!/bin/sh
set -e

# Google Drive MCP server (stdio) wrapped by supergateway (SSE on port 3000).
#
# GOOGLE_SERVICE_ACCOUNT_JSON must be set to the full JSON content of a
# Google service account key with Drive API access. If absent, the server
# starts in unauthenticated mode and Drive operations will fail at runtime.
#
# The @modelcontextprotocol/server-gdrive package reads credentials from the
# GOOGLE_APPLICATION_CREDENTIALS env var pointing to a file on disk, so we
# write the JSON to a temp file and export the path.

if [ -n "${GOOGLE_SERVICE_ACCOUNT_JSON}" ]; then
    echo "${GOOGLE_SERVICE_ACCOUNT_JSON}" > /tmp/service-account.json
    export GOOGLE_APPLICATION_CREDENTIALS=/tmp/service-account.json
else
    echo "[gdrive-mcp] WARNING: GOOGLE_SERVICE_ACCOUNT_JSON not set — Google Drive operations will fail" >&2
fi

# Resolve the gdrive server binary path.
GDRIVE_BIN="$(npm root -g)/@modelcontextprotocol/server-gdrive/dist/index.js"

exec supergateway \
    --stdio "node ${GDRIVE_BIN}" \
    --port 3000 \
    --healthEndpoint /healthz
