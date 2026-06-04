#!/usr/bin/env bash
# Smoke test: hit /v1/health, post one fake HR sample, post one daily
# summary, read counts back. Use after start.sh to confirm the server is
# wired correctly.
set -euo pipefail

TOKEN="${GOOSE_OFFLOAD_TOKEN:-dev-local-token}"
BASE="${GOOSE_OFFLOAD_BASE:-http://127.0.0.1:8787}"

echo "→ Health"
curl -s "$BASE/v1/health" | jq

NOW_MS=$(python3 -c 'import time; print(int(time.time()*1000))')

echo "→ Ingest 1 HR sample"
curl -s -X POST "$BASE/v1/ingest/hr_samples" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "[{\"sample_id\":\"smoke-$NOW_MS\",\"captured_at_ms\":$NOW_MS,\"bpm\":62,\"source\":\"smoketest\"}]" | jq

echo "→ Ingest 1 daily summary"
curl -s -X POST "$BASE/v1/ingest/daily_summaries" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '[{"date_key":"2026-06-04","recovery_score":78.0,"hrv_rmssd_ms":52.0,"resting_hr_bpm":48.0}]' | jq

echo "→ Counts"
curl -s "$BASE/v1/diag/counts" \
  -H "Authorization: Bearer $TOKEN" | jq

echo "✓ Done"
