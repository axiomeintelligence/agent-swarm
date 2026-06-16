#!/bin/sh
# gbrain-skills-watch.sh -- hot-reload gbrain skills on file changes.
# Uses inotifywait to watch the skills directory and triggers gbrain import
# whenever a file is written, created, deleted, or moved in.
SKILLS_DIR="${GBRAIN_HOME:-/opt/gbrain-home}/.gbrain/skills"
GBRAIN_HOME="${GBRAIN_HOME:-/opt/gbrain-home}"

mkdir -p "${SKILLS_DIR}"

echo "[gbrain-skills-watch] Watching ${SKILLS_DIR} for changes"

inotifywait -m -r -e close_write,create,delete,moved_to "${SKILLS_DIR}" |
while read -r _dir _event _file; do
    echo "[gbrain-skills-watch] ${_event} ${_file} -- reimporting skills"
    gbrain import "${SKILLS_DIR}" --home "${GBRAIN_HOME}" || true
done
