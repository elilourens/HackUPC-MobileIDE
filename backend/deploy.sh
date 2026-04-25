#!/usr/bin/env bash
# One-shot Vercel deploy: pushes env vars from .env to the linked project,
# then ships a production deploy. Idempotent — safely re-runnable; we rm
# any existing var before re-adding so the value picks up local edits.
set -euo pipefail

cd "$(dirname "$0")"

# Load .env into the current shell.
if [ ! -f .env ]; then
  echo "missing backend/.env — bail" >&2
  exit 1
fi
set -a
. ./.env
set +a

push_var() {
  local name="$1"
  local value="$2"
  if [ -z "${value:-}" ]; then
    echo "skip $name (not set in .env)"
    return
  fi
  # Wipe any existing value first so a stale Vercel env doesn't shadow
  # what's in .env. Failures here just mean it didn't exist yet.
  vercel env rm "$name" production --yes 2>/dev/null || true
  vercel env add "$name" production --value "$value" --yes
}

push_var OPENAI_API_KEY "${OPENAI_API_KEY:-}"
push_var MONGODB_URI    "${MONGODB_URI:-}"

vercel deploy --prod --yes
