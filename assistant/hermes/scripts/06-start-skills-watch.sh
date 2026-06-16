#!/command/with-contenv sh
# 06-start-skills-watch -- launch gbrain skills hot-reload watcher in background.
# Runs as a cont-init.d script; backgrounds immediately so s6 is not blocked.
/usr/local/bin/gbrain-skills-watch.sh &
