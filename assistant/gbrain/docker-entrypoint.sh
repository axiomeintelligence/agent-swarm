#!/bin/sh
set -e

# Remove stale PGLite postmaster.pid left by a previous killed/OOM-killed container.
# Postgres writes this file on start and removes it on clean shutdown; a forced kill
# skips cleanup. Safe to delete on startup because no other gbrain process can be
# running against the same data directory in this stack.
PGLITE_DIR="${GBRAIN_HOME:-/data}/.gbrain/brain.pglite"
if [ -f "${PGLITE_DIR}/postmaster.pid" ]; then
    rm -f "${PGLITE_DIR}/postmaster.pid"
    echo "[entrypoint] removed stale PGLite lock from ${PGLITE_DIR}/postmaster.pid"
fi

# Auto-initialize G-Brain PGLite database on first run.
# gbrain init is idempotent: it exits cleanly if already initialized.
# --pglite:           use local PGLite (no Postgres server required)
# --no-embedding:     skip embedding model setup (can be configured later via env)
# --non-interactive:  no TTY prompts; required for container environments
if ! gbrain init --pglite --no-embedding --non-interactive 2>/dev/null; then
    echo "[entrypoint] gbrain init failed; brain may need manual init or migration" >&2
fi

exec "$@"
