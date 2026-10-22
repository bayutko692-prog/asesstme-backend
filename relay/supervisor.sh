#!/bin/bash
# =====================================================================
#  ASESSTME — backend supervisor (keeps the relay + tunnel alive 24/7)
#  Owner: @dvc | Builder: promode
# =====================================================================
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"
set -a; . "$DIR/env"; set +a

export PORT
export MY_URL_FILE="$DIR/relay_url.txt"
export URL_FILE="$DIR/relay_url.txt"
export LOG_FILE="$DIR/tunnel.log"
export LEASE_FILE="$DIR/relay-lease.json"
export GITHUB_TOKEN GITHUB_REPO GROQ_KEY_POOL

log() { echo "[$(date '+%F %T')] $*" >> "$DIR/supervisor.log"; }

log "supervisor starting (pid $$)"
echo $$ > "$DIR/supervisor.pid"

# clean any stale processes
pkill -f "$DIR/relay.js" 2>/dev/null
pkill -f "$DIR/tunnel.sh" 2>/dev/null
pkill -f "app/backend/relay/tunnel.sh" 2>/dev/null
pkill -f "ssh .*localhost.run" 2>/dev/null
pkill -f "ssh .*serveo.net" 2>/dev/null
pkill -f "ssh .*bore.pub" 2>/dev/null
sleep 2

# ---- tunnel ----
nohup "$DIR/tunnel.sh" > "$DIR/tunnel.out" 2>&1 &
echo $! > "$DIR/tunnel.pid"
log "tunnel started pid $(cat "$DIR/tunnel.pid")"

# ---- relay (waits for the tunnel url) ----
( for i in $(seq 1 60); do
    [ -s "$DIR/relay_url.txt" ] && break
    sleep 2
  done
  exec /usr/bin/node "$DIR/relay.js" ) > "$DIR/relay.out" 2>&1 &
echo $! > "$DIR/relay.pid"
log "relay started pid $(cat "$DIR/relay.pid")"

# ---- keep-alive: free SSH tunnels close idle sessions, so poke the
#      local endpoint every 2 minutes to hold the tunnel open ----
( while true; do
    curl -sf -m 10 "http://127.0.0.1:$PORT/health" > /dev/null 2>&1 && \
      curl -sf -m 10 "http://127.0.0.1:$PORT/health" > /dev/null 2>&1
    sleep 120
  done ) > "$DIR/keepalive.out" 2>&1 &
echo $! > "$DIR/keepalive.pid"
log "keepalive started pid $(cat "$DIR/keepalive.pid")"

# ---- watchdog loop: restart anything that dies ----
while true; do
    sleep 30
    if ! pgrep -f "$DIR/relay.js" > /dev/null 2>&1; then
        log "relay DOWN - restarting"
        ( for i in $(seq 1 60); do [ -s "$DIR/relay_url.txt" ] && break; sleep 2; done
          exec /usr/bin/node "$DIR/relay.js" ) > "$DIR/relay.out" 2>&1 &
        echo $! > "$DIR/relay.pid"
    fi
    if ! pgrep -f "$DIR/tunnel.sh" > /dev/null 2>&1; then
        log "tunnel DOWN - restarting"
        nohup "$DIR/tunnel.sh" > "$DIR/tunnel.out" 2>&1 &
        echo $! > "$DIR/tunnel.pid"
    fi
done
