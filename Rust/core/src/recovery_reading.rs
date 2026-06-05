//! Recovery reading: turn one [`SleepReading`] into a 0-100 recovery
//! score by delegating to [`metrics::goose_recovery_v0`] — the single
//! source of truth for the formula. This module is the input gatherer:
//! it pulls HRV / RHR from the sleep window, 28-day baselines from the
//! WHOOP-imported daily summary, and yesterday's strain, then hands
//! everything to `goose_recovery_v0` and reshapes the result for SQLite
//! persistence + the iOS UI.
//!
//! Respiratory rate and skin temperature aren't computed locally yet,
//! so they're synthesized at baseline (full credit, 100 each). When
//! local estimators land we replace the synthesized values with real
//! ones and the formula doesn't move.

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::{
    GooseError, GooseResult,
    metrics::{RecoveryInput, goose_recovery_v0},
    sleep_reading::SleepReading,
};

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
    /// `goose.local` for readings driven by an iOS-initiated
    /// SleepReading; `whoop.cloud` for ones lifted from
    /// `imported_daily_summary.recovery_score`.
    #[serde(default = "default_recovery_source_local")]
    pub source: String,
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

    // Respiratory + skin temp aren't computed locally yet; synthesize
    // "at baseline" (full credit). When local estimators land we drop
    // them in here without changing the formula.
    let respiratory_rate = options.fallback_respiratory_rate_rpm;
    let respiratory_baseline = options.fallback_respiratory_rate_rpm;
    let skin_temp_delta: f64 = 0.0;

    let input = RecoveryInput {
        start_time: sleep_reading.start_time_unix_ms.to_string(),
        end_time: sleep_reading.end_time_unix_ms.to_string(),
        hrv_rmssd_ms: hrv,
        hrv_baseline_rmssd_ms: hrv_baseline,
        resting_hr_bpm: rhr,
        resting_hr_baseline_bpm: rhr_baseline,
        respiratory_rate_rpm: respiratory_rate,
        respiratory_rate_baseline_rpm: respiratory_baseline,
        skin_temp_delta_c: skin_temp_delta,
        sleep_score_0_to_100: sleep_reading.sleep_score,
        prior_strain_0_to_21: prior_strain,
        input_ids: Vec::new(),
    };
    let run = goose_recovery_v0(&input);
    let output = run.output.ok_or_else(|| {
        GooseError::message(format!(
            "goose_recovery_v0 returned no output: errors={:?}",
            run.errors
        ))
    })?;

    // Flatten goose_recovery_v0's components vec into named sub-scores
    // for SQLite columns; the full components list is preserved in the
    // JSON blob below.
    let score_for = |name: &str| -> f64 {
        output
            .components
            .iter()
            .find(|c| c.name == name)
            .map(|c| c.score_0_to_100)
            .unwrap_or(0.0)
    };

    let mut quality_flags = run.quality_flags.clone();
    if baseline_nights == 0 {
        quality_flags.push("baseline_fallback".to_string());
    }
    quality_flags.push("respiratory_temperature_neutralized".to_string());
    quality_flags.sort();
    quality_flags.dedup();

    let components = output
        .components
        .iter()
        .map(|c| RecoveryComponent {
            name: c.name.clone(),
            score_0_to_100: round1(c.score_0_to_100),
            weight: c.weight,
        })
        .collect();

    Ok(RecoveryReading {
        schema: "goose.recovery-reading.v0".to_string(),
        session_id,
        date_key,
        source: "goose.local".to_string(),
        algorithm_id: output.algorithm_id.clone(),
        algorithm_version: output.algorithm_version.clone(),
        start_time_unix_ms: sleep_reading.start_time_unix_ms,
        end_time_unix_ms: sleep_reading.end_time_unix_ms,
        recovery_score: round1(output.score_0_to_100),
        hrv_score: round1(score_for("hrv")),
        rhr_score: round1(score_for("rhr")),
        sleep_score: round1(score_for("sleep")),
        respiratory_score: round1(score_for("respiratory")),
        temperature_score: round1(score_for("temperature")),
        prior_strain_score: round1(score_for("prior_strain")),
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

fn default_recovery_source_local() -> String {
    "goose.local".to_string()
}

fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}
fn round2(v: f64) -> f64 {
    (v * 100.0).round() / 100.0
}
