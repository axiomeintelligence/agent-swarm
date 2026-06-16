#!/command/with-contenv sh
# 05-start-sync-brain -- launch periodic brain sync loop in background.
# Runs as a cont-init.d script; backgrounds immediately so s6 is not blocked.
while true; do
    /usr/local/bin/sync-brain.sh
    sleep "${BRAIN_SYNC_INTERVAL:-300}"
done &
