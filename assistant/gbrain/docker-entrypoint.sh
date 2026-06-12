#!/bin/sh
set -e

# Remove stale PGLite lock files left by a previous killed/OOM-killed container.
# Postgres writes postmaster.pid on start and removes it on clean shutdown; a forced
# kill skips cleanup. .gbrain-lock/lock is a gbrain advisory lock with the same
# lifecycle. Safe to remove on startup because only one container accesses this
# data directory.
PGLITE_DIR="${GBRAIN_HOME:-/data}/.gbrain/brain.pglite"
for STALE_LOCK in "${PGLITE_DIR}/postmaster.pid" "${PGLITE_DIR}/.gbrain-lock/lock"; do
    if [ -f "${STALE_LOCK}" ]; then
        rm -f "${STALE_LOCK}"
        echo "[entrypoint] removed stale lock: ${STALE_LOCK}"
    fi
done

# Auto-initialize G-Brain PGLite database on first run.
# gbrain init is idempotent: it exits cleanly if already initialized.
# --pglite:           use local PGLite (no Postgres server required)
# --no-embedding:     skip embedding model setup (can be configured later via env)
# --non-interactive:  no TTY prompts; required for container environments
if ! gbrain init --pglite --no-embedding --non-interactive 2>/dev/null; then
    echo "[entrypoint] gbrain init failed; brain may need manual init or migration" >&2
fi

exec "$@"
