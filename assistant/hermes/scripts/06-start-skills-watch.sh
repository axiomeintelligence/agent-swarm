#!/command/with-contenv sh
# 06-start-skills-watch -- launch gbrain skills hot-reload watcher in background.
# Runs as a cont-init.d script; backgrounds immediately so s6 is not blocked.
# Wraps in a restart loop so the watcher self-heals if inotifywait exits.
PIDFILE=/run/skills-watch.pid
if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    echo "[06-start-skills-watch] watcher already running (pid $(cat "${PIDFILE}")) -- skipping"
    exit 0
fi
while true; do
    /usr/local/bin/gbrain-skills-watch.sh
    echo "[06-start-skills-watch] watcher exited -- restarting in 5s" >&2
    sleep 5
done &
echo $! > "${PIDFILE}"
