#!/bin/sh
# sync-brain.sh -- pull mono-repo and import content into gbrain.
# Manual use: docker exec <container-name> sync-brain.sh
set -e

BRAIN_REPO="${BRAIN_REPO:-/brain-repo}"
GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"

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

if [ "${BEFORE}" != "${AFTER}" ]; then
    BEFORE_SHORT=$(printf '%.8s' "${BEFORE}")
    AFTER_SHORT=$(printf '%.8s' "${AFTER}")
    echo "[sync-brain] New commits (${BEFORE_SHORT}..${AFTER_SHORT}) -- importing"
    gbrain import "${BRAIN_REPO}"
else
    echo "[sync-brain] No new commits at $(date -u +%H:%M:%SZ)"
fi
