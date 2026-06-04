#!/usr/bin/env bash
# Launch the local offload server. Creates a venv on first run.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
  ./.venv/bin/pip install --upgrade pip
  ./.venv/bin/pip install -r requirements.txt
fi

# Bind to all interfaces by default so the phone on the same LAN can hit us.
HOST="${GOOSE_OFFLOAD_HOST:-0.0.0.0}"
PORT="${GOOSE_OFFLOAD_PORT:-8787}"
echo "Goose offload listening on http://${HOST}:${PORT}"
echo "DB: ${GOOSE_OFFLOAD_DB:-$HERE/goose-server.db}"
echo "Token: ${GOOSE_OFFLOAD_TOKEN:-dev-local-token}"

exec ./.venv/bin/uvicorn main:app --host "${HOST}" --port "${PORT}"
