-- Server-side mirror of the device's data tables. Phone is source of
-- truth; this is the persistent backup + analysis surface.

CREATE TABLE IF NOT EXISTS hr_samples (
    sample_id TEXT PRIMARY KEY,
    captured_at_ms INTEGER NOT NULL,
    bpm INTEGER NOT NULL,
    source TEXT NOT NULL DEFAULT '',
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_hr_samples_captured_at ON hr_samples(captured_at_ms);

CREATE TABLE IF NOT EXISTS sensor_samples (
    sample_id TEXT PRIMARY KEY,
    captured_at_ms INTEGER NOT NULL,
    source TEXT NOT NULL,
    bpm INTEGER,
    rr_intervals_ms TEXT,
    ppg_green INTEGER,
    ppg_red_ir INTEGER,
    spo2_red INTEGER,
    spo2_ir INTEGER,
    spo2_pct INTEGER,
    skin_temp_raw INTEGER,
    ambient_light INTEGER,
    led_drive_1 INTEGER,
    led_drive_2 INTEGER,
    signal_quality INTEGER,
    skin_contact INTEGER,
    accel_gravity TEXT,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_sensor_samples_captured_at ON sensor_samples(captured_at_ms);

CREATE TABLE IF NOT EXISTS workouts (
    session_id TEXT PRIMARY KEY,
    activity_type TEXT NOT NULL,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER NOT NULL,
    elapsed_seconds REAL NOT NULL,
    average_hr INTEGER,
    max_hr INTEGER,
    distance_meters REAL,
    elevation_gain_meters REAL,
    zone_durations_json TEXT NOT NULL DEFAULT '{}',
    route_points_json TEXT,
    detection_method TEXT NOT NULL,
    sync_status TEXT NOT NULL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_workouts_started_at ON workouts(started_at_ms);

CREATE TABLE IF NOT EXISTS sleep_sessions (
    session_id TEXT PRIMARY KEY,
    started_at_ms INTEGER NOT NULL,
    ended_at_ms INTEGER NOT NULL,
    detection_log_json TEXT NOT NULL DEFAULT '[]',
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);
CREATE INDEX IF NOT EXISTS idx_sleep_sessions_started_at ON sleep_sessions(started_at_ms);

CREATE TABLE IF NOT EXISTS daily_summaries (
    date_key TEXT PRIMARY KEY,
    recovery_score REAL,
    hrv_rmssd_ms REAL,
    resting_hr_bpm REAL,
    spo2_pct REAL,
    skin_temp_c REAL,
    sleep_performance_pct REAL,
    sleep_efficiency_pct REAL,
    sleep_in_bed_ms INTEGER,
    sleep_awake_ms INTEGER,
    sleep_light_ms INTEGER,
    sleep_deep_ms INTEGER,
    sleep_rem_ms INTEGER,
    sleep_cycle_count INTEGER,
    sleep_disturbance_count INTEGER,
    sleep_need_baseline_ms INTEGER,
    sleep_need_from_debt_ms INTEGER,
    sleep_need_from_strain_ms INTEGER,
    sleep_need_from_nap_ms INTEGER,
    strain_score REAL,
    strain_kilojoules REAL,
    received_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

-- Server-computed analysis output. Phone pulls this and renders insights.
CREATE TABLE IF NOT EXISTS analysis_results (
    result_id TEXT PRIMARY KEY,
    produced_at TEXT NOT NULL,
    kind TEXT NOT NULL,
    payload_json TEXT NOT NULL,
    consumed_by_device INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_analysis_produced_at ON analysis_results(produced_at);
