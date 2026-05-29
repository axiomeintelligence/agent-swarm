#!/bin/sh
set -e

# Auto-initialize G-Brain PGLite database on first run.
# gbrain init is idempotent: it exits cleanly if already initialized.
# --pglite:           use local PGLite (no Postgres server required)
# --no-embedding:     skip embedding model setup (can be configured later via env)
# --non-interactive:  no TTY prompts; required for container environments
if ! gbrain init --pglite --no-embedding --non-interactive 2>/dev/null; then
    echo "[entrypoint] gbrain init failed; brain may need manual init or migration" >&2
fi

exec "$@"
