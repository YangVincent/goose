//! WHOOP → typed-tables converters.
//!
//! ## DO NOT call this from iOS startup.
//!
//! This module is library code for an **offline migration tool**, run
//! once by hand against a pulled DB and pushed back. See
//! `examples/whoop_migrate_smoke.rs` for the canonical caller. The
//! `imported_daily_summary` table is static — once we've migrated, there
//! is no new WHOOP data to import — so any Swift caller that fires this
//! on `.task` / `.onAppear` behind a UserDefaults "did_migrate_v1" flag
//! is dead code that ships forever. The bridge method exposing this
//! exists for Mac-side tools, not for the app's startup path. See
//! README.md "One-off Data Migrations" + the user-memory
//! `feedback_no_runtime_gates_for_static_migrations.md`.
//!
//! Walks `imported_daily_summary` + `external_sleep_sessions` and emits
//! `SleepReading` / `RecoveryReading` / daily strain rows tagged with
//! `source = "whoop.cloud"`, suitable for upserting into the same typed
//! tables that the local compute path (sleep.compute_reading + chained
//! recovery + DayStrainStore finalizer) writes to.
//!
//! Conflict policy is "local wins":
//!
//! - **sleep_readings / recovery_readings** are keyed by `session_id`.
//!   We synthesize `whoop-<date_key>` for whoop.cloud rows. Local rows
//!   use the iOS PastSession UUID. The session_ids never collide, so a
//!   whoop.cloud row coexists with any local row for the same date_key
//!   without overwriting it. UI consumers pick the source they want.
//! - **daily_strain_readings** is keyed by `date_key`. Conflict rule is
//!   enforced by `upsert_daily_strain_reading`'s WHERE clause — a
//!   whoop.cloud upsert on a date_key with an existing goose.local row
//!   no-ops.
//!
//! For the sleep sub-scores (duration / efficiency / depth / hrv /
//! restful) we *re-derive* from WHOOP's aggregates using the same
//! formulas as `sleep_reading::compute_sleep_reading`. Recovery is
//! taken straight from WHOOP's `recovery_score` (no component
//! re-derivation — components stay empty for whoop.cloud rows).

use rusqlite::{Connection, OptionalExtension};
use serde::Deserialize;

use crate::{
    GooseError, GooseResult,
    recovery_reading::{RecoveryComponent, RecoveryReading},
    sleep_reading::SleepReading,
};

const WHOOP_SOURCE: &str = "whoop.cloud";

/// Row from `imported_daily_summary` for a single date_key. All fields
/// nullable on the WHOOP side, so each Option matters.
#[derive(Debug, Clone, Deserialize)]
struct WhoopDaily {
    date_key: String,
    recovery_score: Option<f64>,
    hrv_rmssd_ms: Option<f64>,
    resting_hr_bpm: Option<f64>,
    spo2_pct: Option<f64>,
    skin_temp_c: Option<f64>,
    sleep_performance_pct: Option<f64>,
    sleep_efficiency_pct: Option<f64>,
    sleep_in_bed_ms: Option<i64>,
    sleep_awake_ms: Option<i64>,
    sleep_light_ms: Option<i64>,
    sleep_deep_ms: Option<i64>,
    sleep_rem_ms: Option<i64>,
    sleep_cycle_count: Option<i64>,
    sleep_disturbance_count: Option<i64>,
    sleep_need_baseline_ms: Option<i64>,
    sleep_need_from_debt_ms: Option<i64>,
    sleep_need_from_strain_ms: Option<i64>,
    sleep_need_from_nap_ms: Option<i64>,
    strain_score: Option<f64>,
    strain_kilojoules: Option<f64>,
}

/// Row from `external_sleep_sessions` — gives us the actual sleep
/// start/end times (WHOOP's `imported_daily_summary` only has aggregates).
#[derive(Debug, Clone)]
struct WhoopSleepSession {
    sleep_id: String,
    start_time_unix_ms: i64,
    end_time_unix_ms: i64,
}

fn read_daily(conn: &Connection, date_key: &str) -> GooseResult<Option<WhoopDaily>> {
    let mut stmt = conn.prepare(
        "SELECT date_key, recovery_score, hrv_rmssd_ms, resting_hr_bpm, \
                spo2_pct, skin_temp_c, sleep_performance_pct, sleep_efficiency_pct, \
                sleep_in_bed_ms, sleep_awake_ms, sleep_light_ms, sleep_deep_ms, \
                sleep_rem_ms, sleep_cycle_count, sleep_disturbance_count, \
                sleep_need_baseline_ms, sleep_need_from_debt_ms, \
                sleep_need_from_strain_ms, sleep_need_from_nap_ms, \
                strain_score, strain_kilojoules \
         FROM imported_daily_summary WHERE date_key = ?1",
    )?;
    Ok(stmt
        .query_row(rusqlite::params![date_key], |row| {
            Ok(WhoopDaily {
                date_key: row.get(0)?,
                recovery_score: row.get(1)?,
                hrv_rmssd_ms: row.get(2)?,
                resting_hr_bpm: row.get(3)?,
                spo2_pct: row.get(4)?,
                skin_temp_c: row.get(5)?,
                sleep_performance_pct: row.get(6)?,
                sleep_efficiency_pct: row.get(7)?,
                sleep_in_bed_ms: row.get(8)?,
                sleep_awake_ms: row.get(9)?,
                sleep_light_ms: row.get(10)?,
                sleep_deep_ms: row.get(11)?,
                sleep_rem_ms: row.get(12)?,
                sleep_cycle_count: row.get(13)?,
                sleep_disturbance_count: row.get(14)?,
                sleep_need_baseline_ms: row.get(15)?,
                sleep_need_from_debt_ms: row.get(16)?,
                sleep_need_from_strain_ms: row.get(17)?,
                sleep_need_from_nap_ms: row.get(18)?,
                strain_score: row.get(19)?,
                strain_kilojoules: row.get(20)?,
            })
        })
        .optional()?)
}

/// Find the WHOOP sleep session whose wake time lands on `date_key`
/// local. If there are multiple, pick the longest — matches the
/// "longest wins" rule used for PastSession selection.
fn read_session_for_date_key(
    conn: &Connection,
    date_key: &str,
) -> GooseResult<Option<WhoopSleepSession>> {
    let mut stmt = conn.prepare(
        "SELECT sleep_id, start_time_unix_ms, end_time_unix_ms \
         FROM external_sleep_sessions \
         WHERE strftime('%Y-%m-%d', end_time_unix_ms / 1000.0, 'unixepoch', 'localtime') = ?1 \
         ORDER BY (end_time_unix_ms - start_time_unix_ms) DESC LIMIT 1",
    )?;
    Ok(stmt
        .query_row(rusqlite::params![date_key], |row| {
            Ok(WhoopSleepSession {
                sleep_id: row.get(0)?,
                start_time_unix_ms: row.get(1)?,
                end_time_unix_ms: row.get(2)?,
            })
        })
        .optional()?)
}

/// Convert a WHOOP-imported day into a `SleepReading` with
/// `source = "whoop.cloud"`. Returns None when WHOOP has neither the
/// daily summary nor the per-session row for this date_key (nothing to
/// surface).
///
/// Sub-scores are re-derived from WHOOP's aggregates using the same
/// formulas as `sleep_reading::compute_sleep_reading` — the composite
/// score won't be identical to WHOOP's `sleep_performance_pct` but it's
/// computed from the same shape of inputs so consumers can mix sources
/// without surprises.
pub fn sleep_reading_from_whoop_import(
    conn: &Connection,
    date_key: &str,
) -> GooseResult<Option<SleepReading>> {
    let daily = match read_daily(conn, date_key)? {
        Some(d) => d,
        None => return Ok(None),
    };
    if daily.sleep_in_bed_ms.unwrap_or(0) <= 0 {
        return Ok(None);
    }

    let session = read_session_for_date_key(conn, date_key)?;
    let (start_ms, end_ms) = match &session {
        Some(s) => (s.start_time_unix_ms, s.end_time_unix_ms),
        None => synthesize_session_times(date_key, daily.sleep_in_bed_ms.unwrap_or(0)),
    };

    let tib_min = ms_to_min(daily.sleep_in_bed_ms.unwrap_or(0));
    let asleep_min = tib_min
        - ms_to_min(daily.sleep_awake_ms.unwrap_or(0)).min(tib_min);
    let deep_min = ms_to_min(daily.sleep_deep_ms.unwrap_or(0));
    let light_min = ms_to_min(daily.sleep_light_ms.unwrap_or(0));
    let awake_min = ms_to_min(daily.sleep_awake_ms.unwrap_or(0));
    let rem_min = ms_to_min(daily.sleep_rem_ms.unwrap_or(0));

    let efficiency = if tib_min > 0 {
        asleep_min as f64 / tib_min as f64
    } else {
        0.0
    };
    let deep_share = if asleep_min > 0 {
        deep_min as f64 / asleep_min as f64
    } else {
        0.0
    };
    let awake_share = if tib_min > 0 {
        awake_min as f64 / tib_min as f64
    } else {
        0.0
    };

    // Need: WHOOP's adaptive baseline + debt + strain - nap.
    let need_ms = daily.sleep_need_baseline_ms.unwrap_or(0)
        + daily.sleep_need_from_debt_ms.unwrap_or(0)
        + daily.sleep_need_from_strain_ms.unwrap_or(0)
        - daily.sleep_need_from_nap_ms.unwrap_or(0);
    let need_hours = if need_ms > 0 {
        need_ms as f64 / 3_600_000.0
    } else {
        crate::sleep_reading::DEFAULT_NEED_HOURS
    };

    // Sub-scores: same formulas as compute_sleep_reading. HRV sub-score
    // uses WHOOP's daily HRV vs the default baseline; consumers
    // computing recovery off this row will overwrite with their own
    // baseline lookup.
    let duration_hours = asleep_min as f64 / 60.0;
    let duration_score = (duration_hours / need_hours * 100.0).clamp(0.0, 100.0);
    let efficiency_score = linear_score(efficiency, 0.70, 0.92);
    let depth_score = linear_score(deep_share, 0.05, 0.20);
    let hrv_for_scoring = daily
        .hrv_rmssd_ms
        .unwrap_or(crate::sleep_reading::DEFAULT_HRV_BASELINE_MS);
    let hrv_score = linear_score(
        hrv_for_scoring / crate::sleep_reading::DEFAULT_HRV_BASELINE_MS,
        0.5,
        1.5,
    );
    let restfulness_score = ((1.0 - awake_share) * 100.0).clamp(0.0, 100.0);
    let sleep_score = duration_score * 0.25
        + efficiency_score * 0.25
        + depth_score * 0.20
        + hrv_score * 0.15
        + restfulness_score * 0.15;

    let session_id = session
        .as_ref()
        .map(|s| format!("whoop-{}", s.sleep_id))
        .unwrap_or_else(|| format!("whoop-{}", daily.date_key));

    Ok(Some(SleepReading {
        schema: "goose.sleep-reading.v1".to_string(),
        session_id: Some(session_id),
        source: WHOOP_SOURCE.to_string(),
        date_key: daily.date_key.clone(),
        start_time_unix_ms: start_ms,
        end_time_unix_ms: end_ms,
        time_in_bed_minutes: tib_min,
        total_sleep_minutes: asleep_min,
        deep_minutes: deep_min,
        light_minutes: light_min,
        awake_minutes: awake_min,
        rem_minutes: rem_min,
        no_data_minutes: 0,
        efficiency: round3(efficiency),
        deep_share_of_sleep: round3(deep_share),
        awake_share_of_bed: round3(awake_share),
        // WHOOP doesn't break onset latency / WASO out of in-bed-ms
        // separately, so we leave them empty/zero for whoop.cloud rows.
        onset_latency_minutes: None,
        wake_after_sleep_onset_minutes: 0,
        cycle_count: daily.sleep_cycle_count.unwrap_or(0),
        disturbance_count: daily.sleep_disturbance_count.unwrap_or(0),
        sleep_need_ms: need_ms.max(0),
        hr_mean_bpm: daily.resting_hr_bpm,
        hr_min_bpm: None,
        hr_max_bpm: None,
        hrv_mean_rmssd_ms: round1(daily.hrv_rmssd_ms.unwrap_or(0.0)),
        hrv_sample_count: 0,
        movement_total_intensity: 0.0,
        movement_peak_minute: 0.0,
        movement_burst_minutes: 0,
        duration_score: round1(duration_score),
        efficiency_score: round1(efficiency_score),
        depth_score: round1(depth_score),
        hrv_score: round1(hrv_score),
        restfulness_score: round1(restfulness_score),
        sleep_score: round1(sleep_score),
        resting_bpm_used: daily.resting_hr_bpm.map(|b| b as i64).unwrap_or(0),
        hrv_baseline_ms_used: crate::sleep_reading::DEFAULT_HRV_BASELINE_MS,
        need_hours,
    }))
}

/// WHOOP recovery → `RecoveryReading` with `source = "whoop.cloud"`.
/// Stores WHOOP's recovery_score directly; components are empty (per
/// user-confirmed policy 2b — re-deriving components from WHOOP's
/// inputs would diverge from WHOOP's own formula, which would be more
/// confusing than helpful).
pub fn recovery_reading_from_whoop_import(
    conn: &Connection,
    date_key: &str,
) -> GooseResult<Option<RecoveryReading>> {
    let daily = match read_daily(conn, date_key)? {
        Some(d) => d,
        None => return Ok(None),
    };
    let recovery_score = match daily.recovery_score {
        Some(v) => v,
        None => return Ok(None),
    };

    let session = read_session_for_date_key(conn, date_key)?;
    let (start_ms, end_ms) = match &session {
        Some(s) => (s.start_time_unix_ms, s.end_time_unix_ms),
        None => synthesize_session_times(date_key, daily.sleep_in_bed_ms.unwrap_or(0)),
    };
    let session_id = session
        .as_ref()
        .map(|s| format!("whoop-{}", s.sleep_id))
        .unwrap_or_else(|| format!("whoop-{}", daily.date_key));

    Ok(Some(RecoveryReading {
        schema: "goose.recovery-reading.v0".to_string(),
        session_id,
        date_key: daily.date_key.clone(),
        source: WHOOP_SOURCE.to_string(),
        algorithm_id: "whoop.cloud.recovery".to_string(),
        algorithm_version: "imported".to_string(),
        start_time_unix_ms: start_ms,
        end_time_unix_ms: end_ms,
        recovery_score: round1(recovery_score),
        // Sub-score columns stay 0 for WHOOP — we don't have WHOOP's
        // per-component breakdown, and re-deriving would lie. The UI
        // surfaces "WHOOP" as the source so consumers can hide the
        // sub-score row when source != "goose.local".
        hrv_score: 0.0,
        rhr_score: 0.0,
        sleep_score: round1(daily.sleep_performance_pct.unwrap_or(0.0)),
        respiratory_score: 0.0,
        temperature_score: 0.0,
        prior_strain_score: 0.0,
        components: Vec::<RecoveryComponent>::new(),
        hrv_rmssd_ms: round1(daily.hrv_rmssd_ms.unwrap_or(0.0)),
        hrv_baseline_rmssd_ms: 0.0,
        resting_hr_bpm: round1(daily.resting_hr_bpm.unwrap_or(0.0)),
        resting_hr_baseline_bpm: 0.0,
        respiratory_rate_rpm: 0.0,
        respiratory_rate_baseline_rpm: 0.0,
        skin_temp_delta_c: 0.0,
        prior_strain_0_to_21: 0.0,
        baseline_nights_used: 0,
        quality_flags: vec!["whoop_imported_no_components".to_string()],
    }))
}

/// WHOOP day strain → daily_strain_readings shape, for direct upsert.
/// Returns (date_key, strain_score, strain_kilojoules) or None.
pub fn daily_strain_reading_from_whoop_import(
    conn: &Connection,
    date_key: &str,
) -> GooseResult<Option<(String, f64, f64)>> {
    let daily = match read_daily(conn, date_key)? {
        Some(d) => d,
        None => return Ok(None),
    };
    let score = match daily.strain_score {
        Some(v) if v > 0.0 => v,
        _ => return Ok(None),
    };
    let kj = daily.strain_kilojoules.unwrap_or(0.0);
    Ok(Some((daily.date_key, score, kj)))
}

/// WHOOP day vitals → (spo2, skin_temp) or None.
pub fn daily_vitals_from_whoop_import(
    conn: &Connection,
    date_key: &str,
) -> GooseResult<Option<(String, Option<f64>, Option<f64>)>> {
    let daily = match read_daily(conn, date_key)? {
        Some(d) => d,
        None => return Ok(None),
    };
    if daily.spo2_pct.is_none() && daily.skin_temp_c.is_none() {
        return Ok(None);
    }
    Ok(Some((daily.date_key, daily.spo2_pct, daily.skin_temp_c)))
}

/// All distinct date_keys present in `imported_daily_summary`. Used by
/// the migration bridge method to walk every WHOOP day exactly once.
pub fn imported_date_keys(conn: &Connection) -> GooseResult<Vec<String>> {
    let mut stmt = conn.prepare(
        "SELECT date_key FROM imported_daily_summary ORDER BY date_key ASC",
    )?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(0))?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Fallback when external_sleep_sessions doesn't have a matching row.
/// Uses date_key + reasonable midnight-to-morning timing so the
/// reading has *some* start/end. UI prefers the real WHOOP session
/// times via this; this path is only taken when WHOOP gave aggregate
/// data without per-session detail.
fn synthesize_session_times(date_key: &str, in_bed_ms: i64) -> (i64, i64) {
    // WHOOP attributes a sleep to the wake day. Approximate end at
    // local 07:00, start = end - in_bed_ms. The date_key parses to
    // midnight local; we add 7h. SQLite's strftime would be more exact
    // but this only fires when WHOOP gave us aggregate-only data, which
    // is rare.
    let parts: Vec<&str> = date_key.split('-').collect();
    if parts.len() != 3 {
        return (0, in_bed_ms);
    }
    let year: i64 = parts[0].parse().unwrap_or(2025);
    let month: i64 = parts[1].parse().unwrap_or(1);
    let day: i64 = parts[2].parse().unwrap_or(1);
    let unix_midnight_secs = civil_to_unix(year, month, day);
    let end_ms = (unix_midnight_secs + 7 * 3600) * 1000;
    let start_ms = end_ms - in_bed_ms.max(0);
    (start_ms, end_ms)
}

/// civil → unix epoch seconds for midnight UTC. Same algorithm as
/// `chrono` would give but without the dep.
fn civil_to_unix(year: i64, month: i64, day: i64) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = (y - era * 400) as u64;
    let m = month as u64;
    let d = day as u64;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe as i64 - 719_468;
    days * 86_400
}

fn ms_to_min(ms: i64) -> i64 {
    (ms / 60_000).max(0)
}

fn linear_score(value: f64, zero_at: f64, hundred_at: f64) -> f64 {
    if hundred_at <= zero_at {
        return 0.0;
    }
    ((value - zero_at) / (hundred_at - zero_at) * 100.0).clamp(0.0, 100.0)
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}

/// Surfaces `crate::sleep_reading::DEFAULT_NEED_HOURS`-like constants
/// to the bridge layer; not currently used externally but keeps the
/// migration code grepable from one place.
#[allow(dead_code)]
fn _unused_to_silence_warnings() -> (f64, f64) {
    (
        crate::sleep_reading::DEFAULT_NEED_HOURS,
        crate::sleep_reading::DEFAULT_HRV_BASELINE_MS,
    )
}

/// Test seam: skip the migration in a transaction when the source
/// table doesn't exist (e.g. a fresh fixture DB). Bridge handler uses
/// the public helpers above.
#[allow(dead_code)]
pub fn imported_daily_summary_exists(conn: &Connection) -> GooseResult<bool> {
    let exists: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM sqlite_master \
             WHERE type='table' AND name='imported_daily_summary'",
            [],
            |row| row.get(0),
        )
        .map_err(|error| GooseError::message(error.to_string()))?;
    Ok(exists > 0)
}
