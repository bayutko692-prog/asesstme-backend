#!/bin/bash
# =====================================================================
#  ASESSTME — free SSH reverse tunnel (NO cloudflare, NO ngrok)
#  Owner: @dvc | Builder: promode
# ---------------------------------------------------------------------
#  Providers, in order of preference (all free, no signup):
#    1. localhost.run  -> https://<id>.lhr.life   (TLS terminated)
#    2. serveo.net     -> https://<id>.serveo.net
#    3. bore.pub       -> http://<id>.bore.pub    (plain http)
#
#  The public URL is written to relay_url.txt as soon as it is known.
# =====================================================================
set -u

PORT="${PORT:-8080}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
URL_FILE="${URL_FILE:-$DIR/../relay_url.txt}"
LOG_FILE="${LOG_FILE:-$DIR/../tunnel.log}"

: > "$URL_FILE"
echo "[tunnel] starting, port=$PORT" | tee -a "$LOG_FILE"

grab_url () {
  # pull the real tunnel URL out of the provider banner.
  # the banner also contains doc/admin links, so filter those out and
  # take the LAST matching host (the tunnel url always comes last).
  local line="$1" u
  u=$(printf '%s' "$line" \
        | grep -aoE 'https?://[A-Za-z0-9._-]+' \
        | grep -viE 'admin\.|/docs|^https?://localhost\.run$|serveo\.net$|^https?://localhost$' \
        | tail -1)
  if [ -z "$u" ]; then
    # bore.pub prints a bare host:port
    u=$(printf '%s' "$line" | grep -aoE '\b[a-z0-9]{4,}\.bore\.pub\b' | tail -1)
    [ -n "$u" ] && u="http://$u"
  fi
  if [ -n "$u" ]; then
    u="${u%%[.,)]}"
    echo "$u" > "$URL_FILE"
    echo "[tunnel] public url = $u" | tee -a "$LOG_FILE"
  fi
}

run_provider () {
  local label="$1"; shift
  echo "[tunnel] trying $label" | tee -a "$LOG_FILE"
  "$@" 2>&1 | while IFS= read -r line; do
      echo "[$label] $line" >> "$LOG_FILE"
      if [ ! -s "$URL_FILE" ]; then grab_url "$line"; fi
  done
}

# ---- provider loop: keep trying, never give up ------------------------
attempt=0
while true; do
  attempt=$((attempt+1))
  echo "[tunnel] cycle $attempt" | tee -a "$LOG_FILE"

  run_provider "localhost.run" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -R 80:localhost:$PORT nokey@localhost.run

  run_provider "serveo.net" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -R 80:localhost:$PORT serveo.net

  run_provider "bore.pub" \
    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
        -p 2222 bore.pub

  echo "[tunnel] all providers failed, retrying in 10s" | tee -a "$LOG_FILE"
  sleep 10
done
