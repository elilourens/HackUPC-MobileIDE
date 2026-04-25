#!/usr/bin/env bash
# Spin up the FastAPI backend and the ngrok tunnel pinned to the static
# dev domain that's hardwired into the iOS app (`kDefaultBackendURL`).
# Run from anywhere — the script cd's into the backend dir itself.
#
# Usage:  ./run.sh           # start in foreground, Ctrl-C to stop
#         ./run.sh --bg      # start both in background, log to /tmp
#         ./run.sh --stop    # kill any running uvicorn + ngrok
set -euo pipefail

cd "$(dirname "$0")"

NGROK_DOMAIN="founder-cane-compile.ngrok-free.dev"
PORT=8000

stop() {
  pkill -f "uvicorn backend:app" 2>/dev/null || true
  pkill -f "ngrok http"          2>/dev/null || true
  echo "stopped"
}

case "${1:-}" in
  --stop)
    stop
    exit 0
    ;;
  --bg)
    stop
    sleep 1
    nohup .venv/bin/uvicorn backend:app --host 0.0.0.0 --port "$PORT" --reload \
      > server.log 2>&1 &
    echo "uvicorn pid $!"
    disown
    nohup ngrok http --domain="$NGROK_DOMAIN" "$PORT" --log=stdout \
      > /tmp/ngrok.log 2>&1 &
    echo "ngrok pid $!"
    disown
    sleep 3
    echo "tunnel: https://$NGROK_DOMAIN"
    curl -s -m 5 -H "ngrok-skip-browser-warning: 1" \
      "https://$NGROK_DOMAIN/health" && echo
    exit 0
    ;;
esac

# Foreground default — uvicorn in this terminal, ngrok in the background.
stop
sleep 1
nohup ngrok http --domain="$NGROK_DOMAIN" "$PORT" --log=stdout \
  > /tmp/ngrok.log 2>&1 &
disown
echo "ngrok → https://$NGROK_DOMAIN  (logs: /tmp/ngrok.log)"
echo
exec .venv/bin/uvicorn backend:app --host 0.0.0.0 --port "$PORT" --reload
