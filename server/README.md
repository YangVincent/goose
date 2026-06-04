# Goose Offload Server

Local-first server that mirrors device SQLite tables for offsite backup and
analysis. Phone is still the source of truth — this server only:

1. **Receives** data from the phone (HR samples, sensor samples, workouts,
   sleep sessions, daily summaries).
2. **Analyzes** that data offline (computes recovery trends, anomaly
   detection, long-horizon stats that don't need to run on-device).
3. **Serves results back** via a single `/analysis/results` pickup endpoint.

It never serves raw data back to the phone. No dedupe call from the device.
The phone keeps its own SQLite and decides what to send.

## Running locally

```bash
cd server
./start.sh
```

Serves on `http://127.0.0.1:8787`. SQLite DB lives at `./goose-server.db`.

## Endpoints

All ingest endpoints accept a JSON batch and require `Authorization: Bearer
<token>` matching `GOOSE_OFFLOAD_TOKEN` env var. They're idempotent —
re-uploading the same rows is safe (INSERT OR IGNORE on primary key).

| Method | Path | Purpose |
|--------|------|---------|
| POST | `/v1/ingest/hr_samples` | Heart rate samples |
| POST | `/v1/ingest/sensor_samples` | Full sensor frames |
| POST | `/v1/ingest/workouts` | Completed workouts |
| POST | `/v1/ingest/sleep_sessions` | User-tagged sleep sessions |
| POST | `/v1/ingest/daily_summaries` | Per-day recovery/sleep/strain |
| GET  | `/v1/analysis/results?since=<iso8601>` | Computed insights |
| GET  | `/v1/health` | Liveness check |

## Future: DigitalOcean

Drop in the same code on the SSH-accessible droplet at `vincent@68.183.55.141`
behind nginx. Same env var for the bearer token. Phone re-points to
`https://aeonneo.com/offload/v1/...` instead of `127.0.0.1:8787`.
