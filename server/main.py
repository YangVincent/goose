"""Goose offload server. Mirrors the device's data tables for offsite
backup + analysis. Phone is source of truth; server never serves raw data
back. The only "down" channel is /analysis/results.
"""

from __future__ import annotations

import json
import os
import sqlite3
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Optional

from fastapi import Depends, FastAPI, Header, HTTPException, status
from pydantic import BaseModel, Field
from starlette.responses import JSONResponse


DB_PATH = Path(os.environ.get("GOOSE_OFFLOAD_DB", "goose-server.db")).resolve()
TOKEN = os.environ.get("GOOSE_OFFLOAD_TOKEN", "dev-local-token")
SCHEMA_PATH = Path(__file__).parent / "schema.sql"


app = FastAPI(title="Goose Offload", version="1.0")


@contextmanager
def db_connection() -> Iterator[sqlite3.Connection]:
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA foreign_keys = ON")
    try:
        yield conn
        conn.commit()
    finally:
        conn.close()


def ensure_schema() -> None:
    with db_connection() as conn:
        conn.executescript(SCHEMA_PATH.read_text())


@app.on_event("startup")
def on_startup() -> None:
    ensure_schema()


def require_token(authorization: Optional[str] = Header(default=None)) -> None:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Bearer token required")
    if authorization.removeprefix("Bearer ").strip() != TOKEN:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Invalid token")


# ============================================================================
# Schemas
# ============================================================================


class HrSample(BaseModel):
    sample_id: str
    captured_at_ms: int
    bpm: int
    source: str = ""


class SensorSample(BaseModel):
    sample_id: str
    captured_at_ms: int
    source: str
    bpm: Optional[int] = None
    rr_intervals_ms: Optional[str] = None
    ppg_green: Optional[int] = None
    ppg_red_ir: Optional[int] = None
    spo2_red: Optional[int] = None
    spo2_ir: Optional[int] = None
    spo2_pct: Optional[int] = None
    skin_temp_raw: Optional[int] = None
    ambient_light: Optional[int] = None
    led_drive_1: Optional[int] = None
    led_drive_2: Optional[int] = None
    signal_quality: Optional[int] = None
    skin_contact: Optional[int] = None
    accel_gravity: Optional[str] = None


class Workout(BaseModel):
    session_id: str
    activity_type: str
    started_at_ms: int
    ended_at_ms: int
    elapsed_seconds: float
    average_hr: Optional[int] = None
    max_hr: Optional[int] = None
    distance_meters: Optional[float] = None
    elevation_gain_meters: Optional[float] = None
    zone_durations_json: str = "{}"
    route_points_json: Optional[str] = None
    detection_method: str
    sync_status: str


class SleepSession(BaseModel):
    session_id: str
    started_at_ms: int
    ended_at_ms: int
    detection_log_json: str = "[]"


class DailySummary(BaseModel):
    date_key: str
    recovery_score: Optional[float] = None
    hrv_rmssd_ms: Optional[float] = None
    resting_hr_bpm: Optional[float] = None
    spo2_pct: Optional[float] = None
    skin_temp_c: Optional[float] = None
    sleep_performance_pct: Optional[float] = None
    sleep_efficiency_pct: Optional[float] = None
    sleep_in_bed_ms: Optional[int] = None
    sleep_awake_ms: Optional[int] = None
    sleep_light_ms: Optional[int] = None
    sleep_deep_ms: Optional[int] = None
    sleep_rem_ms: Optional[int] = None
    sleep_cycle_count: Optional[int] = None
    sleep_disturbance_count: Optional[int] = None
    sleep_need_baseline_ms: Optional[int] = None
    sleep_need_from_debt_ms: Optional[int] = None
    sleep_need_from_strain_ms: Optional[int] = None
    sleep_need_from_nap_ms: Optional[int] = None
    strain_score: Optional[float] = None
    strain_kilojoules: Optional[float] = None


class BatchEnvelope(BaseModel):
    items: list[Any] = Field(default_factory=list)


# ============================================================================
# Ingest helpers
# ============================================================================


def _insert_or_ignore(table: str, rows: list[dict], pk: str) -> dict[str, int]:
    if not rows:
        return {"received": 0, "inserted": 0, "skipped": 0}
    cols = list(rows[0].keys())
    placeholders = ", ".join("?" for _ in cols)
    col_list = ", ".join(cols)
    sql = f"INSERT OR IGNORE INTO {table} ({col_list}) VALUES ({placeholders})"
    inserted = 0
    with db_connection() as conn:
        for row in rows:
            cur = conn.execute(sql, tuple(row[c] for c in cols))
            if cur.rowcount > 0:
                inserted += 1
    return {"received": len(rows), "inserted": inserted, "skipped": len(rows) - inserted}


# ============================================================================
# Endpoints
# ============================================================================


@app.get("/v1/health")
def health() -> dict[str, Any]:
    return {"ok": True, "db_path": str(DB_PATH), "schema": "goose.offload.v1"}


@app.post("/v1/ingest/hr_samples", dependencies=[Depends(require_token)])
def ingest_hr_samples(payload: list[HrSample]) -> dict[str, int]:
    return _insert_or_ignore("hr_samples", [p.model_dump() for p in payload], "sample_id")


@app.post("/v1/ingest/sensor_samples", dependencies=[Depends(require_token)])
def ingest_sensor_samples(payload: list[SensorSample]) -> dict[str, int]:
    return _insert_or_ignore("sensor_samples", [p.model_dump() for p in payload], "sample_id")


@app.post("/v1/ingest/workouts", dependencies=[Depends(require_token)])
def ingest_workouts(payload: list[Workout]) -> dict[str, int]:
    return _insert_or_ignore("workouts", [p.model_dump() for p in payload], "session_id")


@app.post("/v1/ingest/sleep_sessions", dependencies=[Depends(require_token)])
def ingest_sleep_sessions(payload: list[SleepSession]) -> dict[str, int]:
    return _insert_or_ignore("sleep_sessions", [p.model_dump() for p in payload], "session_id")


@app.post("/v1/ingest/daily_summaries", dependencies=[Depends(require_token)])
def ingest_daily_summaries(payload: list[DailySummary]) -> dict[str, int]:
    return _insert_or_ignore("daily_summaries", [p.model_dump() for p in payload], "date_key")


@app.get("/v1/analysis/results", dependencies=[Depends(require_token)])
def analysis_results(since: Optional[str] = None) -> dict[str, Any]:
    """Phone pulls newly-produced analysis results. Server marks them
    consumed once the device has them.
    """
    with db_connection() as conn:
        if since:
            cur = conn.execute(
                "SELECT * FROM analysis_results WHERE produced_at > ? "
                "ORDER BY produced_at",
                (since,),
            )
        else:
            cur = conn.execute(
                "SELECT * FROM analysis_results WHERE consumed_by_device = 0 "
                "ORDER BY produced_at"
            )
        rows = [dict(r) for r in cur.fetchall()]
        ids = [r["result_id"] for r in rows]
        if ids:
            conn.executemany(
                "UPDATE analysis_results SET consumed_by_device = 1 WHERE result_id = ?",
                [(i,) for i in ids],
            )
    return {"count": len(rows), "results": rows}


# Diagnostic: counts per table (auth-gated).
@app.get("/v1/diag/counts", dependencies=[Depends(require_token)])
def counts() -> dict[str, int]:
    tables = [
        "hr_samples",
        "sensor_samples",
        "workouts",
        "sleep_sessions",
        "daily_summaries",
        "analysis_results",
    ]
    out: dict[str, int] = {}
    with db_connection() as conn:
        for t in tables:
            out[t] = conn.execute(f"SELECT COUNT(*) AS c FROM {t}").fetchone()["c"]
    return out
