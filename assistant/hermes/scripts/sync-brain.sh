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
git -C "${BRAIN_REPO}" pull --ff-only 2>/dev/null || true
AFTER=$(git -C "${BRAIN_REPO}" rev-parse HEAD)

if [ "${BEFORE}" != "${AFTER}" ]; then
    echo "[sync-brain] New commits (${BEFORE%????????}..${AFTER%????????}) -- importing"
    gbrain import "${BRAIN_REPO}" --home "${GBRAIN_HOME}"
else
    echo "[sync-brain] No new commits at $(date -u +%H:%M:%SZ)"
fi
