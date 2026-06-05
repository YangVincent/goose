//! Recovery reading: turn one [`SleepReading`] into a 0-100 recovery
//! score using the same `goose_recovery_v0` formula the packet-driven
//! daily pipeline uses, but sourced from the sleep window directly so we
//! can compute the moment a sleep session ends — no waiting for the
//! daily rollup pipeline.
//!
//! Components and weights (mirror `metrics::goose_recovery_v0`):
//!   - hrv         35%   clamp(70 + (rmssd/baseline - 1) * 100)
//!   - rhr         20%   clamp(70 + (baseline - rhr) * 5)
//!   - sleep       15%   sleep_reading.sleep_score, passed through
//!   - respiratory 10%   clamp(100 - |rr - rr_baseline| * 20)
//!   - temperature 10%   clamp(100 - |skin_temp_delta_c| * 50)
//!   - prior_strain 10%  clamp(100 - prior_strain/21 * 60)
//!
//! Baselines come from the 28-day rolling median of
//! `imported_daily_summary`. Prior strain is yesterday's `strain_score`
//! (defaults to 0 — a rest day — when missing). Respiratory and skin
//! temperature aren't computed locally yet so they're neutralized to
//! baseline (full credit, 100 each); when those land we drop them in
//! without changing the formula.

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::{GooseError, GooseResult, sleep_reading::SleepReading};

#[derive(Debug, Clone, Copy)]
pub struct RecoveryReadingOptions {
    /// Rolling baseline window in days.
    pub baseline_days: i64,
    /// Used when `imported_daily_summary` has no rows yet.
    pub fallback_hrv_baseline_ms: f64,
    pub fallback_rhr_baseline_bpm: f64,
    /// Used when there's no respiratory or skin temp signal yet.
    pub fallback_respiratory_rate_rpm: f64,
}

impl Default for RecoveryReadingOptions {
    fn default() -> Self {
        Self {
            baseline_days: 28,
            fallback_hrv_baseline_ms: 60.0,
            fallback_rhr_baseline_bpm: 50.0,
            fallback_respiratory_rate_rpm: 14.0,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RecoveryComponent {
    pub name: String,
    pub score_0_to_100: f64,
    pub weight: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RecoveryReading {
    pub schema: String,
    pub session_id: String,
    pub date_key: String,
    pub algorithm_id: String,
    pub algorithm_version: String,
    pub start_time_unix_ms: i64,
    pub end_time_unix_ms: i64,
    pub recovery_score: f64,
    pub hrv_score: f64,
    pub rhr_score: f64,
    pub sleep_score: f64,
    pub respiratory_score: f64,
    pub temperature_score: f64,
    pub prior_strain_score: f64,
    pub components: Vec<RecoveryComponent>,
    /// Same overnight HRV mean as `SleepReading.hrv_mean_rmssd_ms`,
    /// duplicated here so `recovery.get_reading` is self-contained.
    pub hrv_rmssd_ms: f64,
    pub hrv_baseline_rmssd_ms: f64,
    pub resting_hr_bpm: f64,
    pub resting_hr_baseline_bpm: f64,
    pub respiratory_rate_rpm: f64,
    pub respiratory_rate_baseline_rpm: f64,
    pub skin_temp_delta_c: f64,
    pub prior_strain_0_to_21: f64,
    pub baseline_nights_used: i64,
    pub quality_flags: Vec<String>,
}

pub const RECOVERY_READING_ALGORITHM_ID: &str = "goose.recovery.from_sleep_reading.v0";
pub const RECOVERY_READING_ALGORITHM_VERSION: &str = "0.1.0";

fn clamp_0_100(v: f64) -> f64 {
    v.max(0.0).min(100.0)
}

/// 10th-percentile BPM across the sleep window — same convention WHOOP
/// uses for "resting" HR during sleep. Falls back to the SleepReading's
/// `hr_min` (clamped above 35) when there are no samples.
fn resting_hr_from_window(conn: &Connection, sr: &SleepReading) -> GooseResult<f64> {
    let mut stmt = conn.prepare(
        "SELECT bpm FROM hr_samples \
         WHERE captured_at_ms BETWEEN ?1 AND ?2 \
         ORDER BY bpm",
    )?;
    let mut rows = stmt.query(rusqlite::params![
        sr.start_time_unix_ms,
        sr.end_time_unix_ms
    ])?;
    let mut bpms: Vec<i64> = Vec::new();
    while let Some(row) = rows.next()? {
        bpms.push(row.get(0)?);
    }
    if bpms.is_empty() {
        return Ok(sr
            .hr_min_bpm
            .map(|b| (b as f64).max(35.0))
            .unwrap_or(50.0));
    }
    let idx = ((bpms.len() as f64 * 0.10).floor() as usize).saturating_sub(1);
    Ok(bpms[idx.min(bpms.len() - 1)] as f64)
}

/// Rolling 28-day median of HRV / RHR from the WHOOP-imported daily
/// summary. Walks back from the sleep window's wake date.
fn baselines_and_strain(
    conn: &Connection,
    date_key: &str,
    options: RecoveryReadingOptions,
) -> GooseResult<(f64, f64, f64, i64)> {
    let mut stmt = conn.prepare(
        "SELECT hrv_rmssd_ms, resting_hr_bpm FROM imported_daily_summary \
         WHERE date_key < ?1 AND hrv_rmssd_ms IS NOT NULL AND resting_hr_bpm IS NOT NULL \
         ORDER BY date_key DESC LIMIT ?2",
    )?;
    let mut rows = stmt.query(rusqlite::params![date_key, options.baseline_days])?;
    let mut hrvs: Vec<f64> = Vec::new();
    let mut rhrs: Vec<f64> = Vec::new();
    while let Some(row) = rows.next()? {
        hrvs.push(row.get::<_, f64>(0)?);
        rhrs.push(row.get::<_, f64>(1)?);
    }
    let nights = hrvs.len() as i64;
    let hrv_baseline = if hrvs.is_empty() {
        options.fallback_hrv_baseline_ms
    } else {
        median(&mut hrvs)
    };
    let rhr_baseline = if rhrs.is_empty() {
        options.fallback_rhr_baseline_bpm
    } else {
        median(&mut rhrs)
    };

    let strain: f64 = conn
        .query_row(
            "SELECT strain_score FROM imported_daily_summary \
             WHERE date_key < ?1 AND strain_score IS NOT NULL \
             ORDER BY date_key DESC LIMIT 1",
            rusqlite::params![date_key],
            |row| row.get(0),
        )
        .unwrap_or(0.0);

    Ok((hrv_baseline, rhr_baseline, strain, nights))
}

fn median(v: &mut Vec<f64>) -> f64 {
    v.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let n = v.len();
    if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}

/// Derive the wake date_key (YYYY-MM-DD, local-ish) from the end of the
/// sleep window. SQLite has no timezone library but the imported
/// summaries are local-day-keyed; using `strftime('%Y-%m-%d', ..., 'unixepoch')`
/// off the end_time_unix_ms with a UTC interpretation is good enough for
/// matching the WHOOP convention since wake times rarely cross midnight.
fn wake_date_key(conn: &Connection, end_time_unix_ms: i64) -> GooseResult<String> {
    let key: String = conn.query_row(
        "SELECT strftime('%Y-%m-%d', ?1 / 1000.0, 'unixepoch', 'localtime')",
        rusqlite::params![end_time_unix_ms],
        |row| row.get(0),
    )?;
    Ok(key)
}

pub fn compute_recovery_from_sleep_reading(
    conn: &Connection,
    sleep_reading: &SleepReading,
    options: RecoveryReadingOptions,
) -> GooseResult<RecoveryReading> {
    let session_id = sleep_reading
        .session_id
        .clone()
        .ok_or_else(|| GooseError::message("sleep_reading.session_id is required"))?;

    let date_key = wake_date_key(conn, sleep_reading.end_time_unix_ms)?;
    let (hrv_baseline, rhr_baseline, prior_strain, baseline_nights) =
        baselines_and_strain(conn, &date_key, options)?;
    let rhr = resting_hr_from_window(conn, sleep_reading)?;
    let hrv = sleep_reading.hrv_mean_rmssd_ms;

    let mut quality_flags = Vec::new();
    if baseline_nights == 0 {
        quality_flags.push("baseline_fallback".to_string());
    }
    if hrv == 0.0 {
        quality_flags.push("hrv_missing".to_string());
    }
    if sleep_reading.sleep_score < 60.0 {
        quality_flags.push("low_sleep_score".to_string());
    }
    if prior_strain > 14.0 {
        quality_flags.push("high_prior_strain".to_string());
    }

    // Respiratory rate + skin temp delta aren't computed locally yet;
    // assume "at baseline" (full credit). When those land we plumb them
    // in here and the math doesn't change.
    let respiratory_rate = options.fallback_respiratory_rate_rpm;
    let respiratory_baseline = options.fallback_respiratory_rate_rpm;
    let skin_temp_delta: f64 = 0.0;
    quality_flags.push("respiratory_temperature_neutralized".to_string());

    let hrv_score = if hrv_baseline > 0.0 {
        clamp_0_100(70.0 + (hrv / hrv_baseline - 1.0) * 100.0)
    } else {
        0.0
    };
    let rhr_score = clamp_0_100(70.0 + (rhr_baseline - rhr) * 5.0);
    let respiratory_score =
        clamp_0_100(100.0 - (respiratory_rate - respiratory_baseline).abs() * 20.0);
    let temperature_score = clamp_0_100(100.0 - skin_temp_delta.abs() * 50.0);
    let prior_strain_score = clamp_0_100(100.0 - prior_strain / 21.0 * 60.0);
    let sleep_score = sleep_reading.sleep_score;

    let components = vec![
        RecoveryComponent {
            name: "hrv".to_string(),
            score_0_to_100: round1(hrv_score),
            weight: 0.35,
        },
        RecoveryComponent {
            name: "rhr".to_string(),
            score_0_to_100: round1(rhr_score),
            weight: 0.20,
        },
        RecoveryComponent {
            name: "sleep".to_string(),
            score_0_to_100: round1(sleep_score),
            weight: 0.15,
        },
        RecoveryComponent {
            name: "respiratory".to_string(),
            score_0_to_100: round1(respiratory_score),
            weight: 0.10,
        },
        RecoveryComponent {
            name: "temperature".to_string(),
            score_0_to_100: round1(temperature_score),
            weight: 0.10,
        },
        RecoveryComponent {
            name: "prior_strain".to_string(),
            score_0_to_100: round1(prior_strain_score),
            weight: 0.10,
        },
    ];
    let recovery_score: f64 = components
        .iter()
        .map(|c| c.score_0_to_100 * c.weight)
        .sum();

    Ok(RecoveryReading {
        schema: "goose.recovery-reading.v0".to_string(),
        session_id,
        date_key,
        algorithm_id: RECOVERY_READING_ALGORITHM_ID.to_string(),
        algorithm_version: RECOVERY_READING_ALGORITHM_VERSION.to_string(),
        start_time_unix_ms: sleep_reading.start_time_unix_ms,
        end_time_unix_ms: sleep_reading.end_time_unix_ms,
        recovery_score: round1(recovery_score),
        hrv_score: round1(hrv_score),
        rhr_score: round1(rhr_score),
        sleep_score: round1(sleep_score),
        respiratory_score: round1(respiratory_score),
        temperature_score: round1(temperature_score),
        prior_strain_score: round1(prior_strain_score),
        components,
        hrv_rmssd_ms: round1(hrv),
        hrv_baseline_rmssd_ms: round1(hrv_baseline),
        resting_hr_bpm: round1(rhr),
        resting_hr_baseline_bpm: round1(rhr_baseline),
        respiratory_rate_rpm: respiratory_rate,
        respiratory_rate_baseline_rpm: respiratory_baseline,
        skin_temp_delta_c: skin_temp_delta,
        prior_strain_0_to_21: round2(prior_strain),
        baseline_nights_used: baseline_nights,
        quality_flags,
    })
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}
fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}
