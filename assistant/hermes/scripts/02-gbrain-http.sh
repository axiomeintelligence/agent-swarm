#!/bin/sh
# 02-gbrain-http.sh — initialise gbrain and start it as an HTTP MCP server.
#
# Runs as cont-init.d/02-gbrain-http BEFORE 03-mcp-config so the token is
# available when hermes config is written. Starts gbrain serve --http and
# writes the bearer token to /tmp/gbrain-http-token for 03-mcp-config to use.
#
# Re-runs cleanly on each container start: stale lock is removed, the HTTP
# server is started fresh, and a new short-lived token is obtained.
set -e

GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"
GBRAIN_PORT="${GBRAIN_PORT:-3131}"
CREDS_FILE="${GBRAIN_HOME}/.hermes-oauth-creds"
TOKEN_FILE="/tmp/gbrain-http-token"

# ── Ownership ─────────────────────────────────────────────────────────────────
mkdir -p "${GBRAIN_HOME}"
if id hermes >/dev/null 2>&1; then
    chown -R hermes:hermes "${GBRAIN_HOME}" 2>/dev/null || true
fi

# ── Remove stale PGLite lock from a previous container run ───────────────────
PGLITE_LOCK="${GBRAIN_HOME}/.gbrain/brain.pglite/.gbrain-lock/lock"
if [ -f "${PGLITE_LOCK}" ]; then
    LOCK_PID=$(python3 -c \
        "import json; print(json.load(open('${PGLITE_LOCK}')).get('pid', 0))" \
        2>/dev/null || echo 0)
    if [ -n "${LOCK_PID}" ] && [ "${LOCK_PID}" != "0" ] && \
       ! kill -0 "${LOCK_PID}" 2>/dev/null; then
        echo "[gbrain-http] Removing stale PGLite lock (dead pid ${LOCK_PID})"
        rm -f "${PGLITE_LOCK}"
    fi
fi

# ── Init brain (first boot only) ─────────────────────────────────────────────
if [ ! -f "${GBRAIN_HOME}/.gbrain/config.json" ]; then
    echo "[gbrain-http] Initializing gbrain (PGLite, no embeddings)"
    s6-setuidgid hermes gbrain init --pglite --no-embedding 2>&1 || true
fi

# ── Disable self-upgrade (would close stdio connection mid-handshake) ─────────
if [ -f "${GBRAIN_HOME}/.gbrain/config.json" ]; then
    python3 -c "
import json
p = '${GBRAIN_HOME}/.gbrain/config.json'
with open(p) as f: c = json.load(f)
if c.get('self_upgrade', {}).get('mode') != 'off':
    c['self_upgrade'] = {'mode': 'off'}
    with open(p, 'w') as f: json.dump(c, f, indent=2)
    print('[gbrain-http] Disabled gbrain self-upgrade (mode=off)')
" 2>/dev/null || true
fi

# ── Register OAuth client once ────────────────────────────────────────────────
# Credentials are persisted in CREDS_FILE so they survive container restarts.
if [ ! -f "${CREDS_FILE}" ]; then
    echo "[gbrain-http] Registering hermes OAuth client (hermes-mcp)"
    RESULT=$(s6-setuidgid hermes gbrain auth register-client hermes-mcp \
        --grant-types client_credentials \
        --scopes read --scopes write --scopes admin 2>&1) || true
    CLIENT_ID=$(printf '%s' "${RESULT}" | grep "Client ID:" | awk '{print $NF}')
    CLIENT_SECRET=$(printf '%s' "${RESULT}" | grep "Client Secret:" | awk '{print $NF}')
    if [ -n "${CLIENT_ID}" ] && [ -n "${CLIENT_SECRET}" ]; then
        printf 'CLIENT_ID=%s\nCLIENT_SECRET=%s\n' "${CLIENT_ID}" "${CLIENT_SECRET}" \
            > "${CREDS_FILE}"
        chmod 600 "${CREDS_FILE}"
        chown hermes:hermes "${CREDS_FILE}" 2>/dev/null || true
        echo "[gbrain-http] OAuth client registered: ${CLIENT_ID}"
    else
        echo "[gbrain-http] ERROR: Could not register OAuth client" >&2
        echo "[gbrain-http] gbrain output: ${RESULT}" >&2
        exit 1
    fi
fi

# shellcheck disable=SC1090
. "${CREDS_FILE}"

# ── Start gbrain HTTP MCP server ──────────────────────────────────────────────
# 30-day token TTL: containers restart more frequently than 30 days, so each
# boot gets a fresh token; the 30-day window just avoids token churn mid-run.
echo "[gbrain-http] Starting gbrain HTTP MCP server on port ${GBRAIN_PORT}"
mkdir -p /opt/data/logs
s6-setuidgid hermes gbrain serve --http --port "${GBRAIN_PORT}" \
    --token-ttl 2592000 >> /opt/data/logs/gbrain-http.log 2>&1 &
GBRAIN_PID=$!
echo "[gbrain-http] gbrain serve started (pid ${GBRAIN_PID})"

# ── Wait for HTTP server to be ready ─────────────────────────────────────────
i=0; MAX_WAIT=30
while [ "${i}" -lt "${MAX_WAIT}" ]; do
    if curl -sf "http://localhost:${GBRAIN_PORT}/health" >/dev/null 2>&1; then
        echo "[gbrain-http] Server ready after ${i}s"
        break
    fi
    sleep 1
    i=$((i + 1))
done
if ! curl -sf "http://localhost:${GBRAIN_PORT}/health" >/dev/null 2>&1; then
    echo "[gbrain-http] ERROR: gbrain HTTP server not ready after ${MAX_WAIT}s" >&2
    exit 1
fi

# ── Obtain bearer token ───────────────────────────────────────────────────────
TOKEN_RESPONSE=$(curl -s -X POST "http://localhost:${GBRAIN_PORT}/token" \
    --data-urlencode "grant_type=client_credentials" \
    --data-urlencode "client_id=${CLIENT_ID}" \
    --data-urlencode "client_secret=${CLIENT_SECRET}" \
    --data-urlencode "scope=admin" 2>/dev/null)
ACCESS_TOKEN=$(printf '%s' "${TOKEN_RESPONSE}" | \
    python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('access_token',''))" \
    2>/dev/null || true)

if [ -z "${ACCESS_TOKEN}" ]; then
    echo "[gbrain-http] WARNING: Could not get token — client creds may be stale" >&2
    echo "[gbrain-http] Re-registering client on next boot" >&2
    rm -f "${CREDS_FILE}"
    exit 1
fi

printf '%s' "${ACCESS_TOKEN}" > "${TOKEN_FILE}"
chmod 600 "${TOKEN_FILE}"
echo "[gbrain-http] Bearer token written to ${TOKEN_FILE}"
