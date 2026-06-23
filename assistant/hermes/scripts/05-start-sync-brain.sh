#!/command/with-contenv sh
# 05-start-sync-brain -- launch periodic brain sync loop in background.
# Runs as a cont-init.d script; backgrounds immediately so s6 is not blocked.
PIDFILE=/run/sync-brain.pid
if [ -f "${PIDFILE}" ] && kill -0 "$(cat "${PIDFILE}")" 2>/dev/null; then
    echo "[05-start-sync-brain] loop already running (pid $(cat "${PIDFILE}")) -- skipping"
    exit 0
fi
while true; do
    /usr/local/bin/sync-brain.sh
    sleep "${SKILL_SYNC_INTERVAL:-300}"
done &
echo $! > "${PIDFILE}"
