//! Sleep reading: aggregate one explicit sleep window into a structured score.
//!
//! Ported from the reference Python implementation
//! (`tools/sleep_reading.py`). The inputs are the typed mirror tables
//! `hr_samples`, `hrv_samples`, and `raw_imu_packets`; the output is a
//! [`SleepReading`] that can be persisted via
//! [`GooseStore::upsert_sleep_reading`] and surfaced in the iOS UI.
//!
//! Per-minute stage classification:
//!   - **awake** : HR >= resting+10 OR movement is in the top decile of the window
//!   - **deep**  : HR <= resting+3 AND movement below window median AND
//!                 RMSSD (10-min mean) >= window-mean RMSSD * 0.9
//!   - **light** : everything else with valid HR
//!   - **n/a**   : no HR samples that minute (counted as awake for efficiency)
//!
//! Composite sleep score (0-100) is the weighted mean of five sub-scores:
//!   - duration    25%  (target = need_hours, default 7.5)
//!   - efficiency  25%  (TST / TIB, 70% floor -> 0 pts, 92% -> 100 pts)
//!   - depth       20%  (deep share of TST, 5% -> 0, 20%+ -> 100)
//!   - hrv         15%  (RMSSD vs personal baseline, 0.5x -> 0, 1.5x -> 100)
//!   - restfulness 15%  (1 - awake share of bed, mapped to 0-100)

use rusqlite::Connection;
use serde::{Deserialize, Serialize};

use crate::{GooseError, GooseResult};

pub const DEFAULT_RESTING_BPM: i64 = 49;
pub const DEFAULT_HRV_BASELINE_MS: f64 = 50.0;
pub const DEFAULT_NEED_HOURS: f64 = 7.5;

#[derive(Debug, Clone, Copy)]
pub struct SleepReadingOptions {
    pub resting_bpm: i64,
    pub hrv_baseline_ms: f64,
    pub need_hours: f64,
}

impl Default for SleepReadingOptions {
    fn default() -> Self {
        Self {
            resting_bpm: DEFAULT_RESTING_BPM,
            hrv_baseline_ms: DEFAULT_HRV_BASELINE_MS,
            need_hours: DEFAULT_NEED_HOURS,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SleepReading {
    pub schema: String,
    pub session_id: Option<String>,
    /// `goose.local` for readings computed by [`compute_sleep_reading`];
    /// `whoop.cloud` for ones lifted from `imported_daily_summary` +
    /// `external_sleep_sessions` via the WHOOP-to-typed converters.
    /// Lets the UI tag the source without changing column shape.
    #[serde(default = "default_source_local")]
    pub source: String,
    /// Local date_key (yyyy-MM-dd) of the wake day, derived from
    /// `end_time_unix_ms`. Indexed; lets per-day lookups skip
    /// session_id roundtrips.
    #[serde(default)]
    pub date_key: String,
    pub start_time_unix_ms: i64,
    pub end_time_unix_ms: i64,
    pub time_in_bed_minutes: i64,
    pub total_sleep_minutes: i64,
    pub deep_minutes: i64,
    pub light_minutes: i64,
    pub awake_minutes: i64,
    /// REM minutes — WHOOP provides this directly; the local
    /// algorithm doesn't classify REM yet so it's 0 for `goose.local`
    /// rows until the K18/RR-driven REM classifier lands (TODO).
    #[serde(default)]
    pub rem_minutes: i64,
    pub efficiency: f64,
    pub deep_share_of_sleep: f64,
    pub awake_share_of_bed: f64,
    pub onset_latency_minutes: Option<i64>,
    pub wake_after_sleep_onset_minutes: i64,
    /// Number of complete sleep cycles. WHOOP-only for now; 0 for
    /// `goose.local` until the cycle detector lands (TODO).
    #[serde(default)]
    pub cycle_count: i64,
    /// Discrete disturbances (long-enough awake spells mid-sleep).
    /// WHOOP-only for now; 0 for `goose.local` (TODO).
    #[serde(default)]
    pub disturbance_count: i64,
    /// WHOOP's adaptive sleep-need (baseline + debt + strain - nap).
    /// `goose.local` rows compute this from `need_hours * 3600 * 1000`.
    #[serde(default)]
    pub sleep_need_ms: i64,
    pub hr_mean_bpm: Option<f64>,
    pub hr_min_bpm: Option<i64>,
    pub hr_max_bpm: Option<i64>,
    pub hrv_mean_rmssd_ms: f64,
    pub hrv_sample_count: i64,
    pub movement_total_intensity: f64,
    pub movement_peak_minute: f64,
    pub movement_burst_minutes: i64,
    pub duration_score: f64,
    pub efficiency_score: f64,
    pub depth_score: f64,
    pub hrv_score: f64,
    pub restfulness_score: f64,
    pub sleep_score: f64,
    pub resting_bpm_used: i64,
    pub hrv_baseline_ms_used: f64,
    pub need_hours: f64,
}

fn default_source_local() -> String {
    "goose.local".to_string()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Awake,
    Light,
    Deep,
    NotApplicable,
}

#[derive(Debug, Clone)]
struct MinuteRow {
    #[allow(dead_code)]
    bucket_ms: i64,
    hr_mean: Option<f64>,
    hr_min: Option<i64>,
    hr_max: Option<i64>,
    movement: f64,
    rmssd: Option<f64>,
    stage: Stage,
}

fn floor_minute(ms: i64) -> i64 {
    (ms / 60_000) * 60_000
}

/// Re-aggregate (start_ms, end_ms) of hr/hrv/imu rows into a per-minute table.
fn build_minute_series(
    conn: &Connection,
    start_ms: i64,
    end_ms: i64,
) -> GooseResult<Vec<MinuteRow>> {
    // HR -> per-minute bucket of bpm samples.
    let mut hr_per_minute: std::collections::BTreeMap<i64, Vec<i64>> =
        std::collections::BTreeMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT captured_at_ms, bpm FROM hr_samples \
             WHERE captured_at_ms BETWEEN ?1 AND ?2 \
             ORDER BY captured_at_ms",
        )?;
        let mut rows = stmt.query(rusqlite::params![start_ms, end_ms])?;
        while let Some(row) = rows.next()? {
            let t: i64 = row.get(0)?;
            let bpm: i64 = row.get(1)?;
            hr_per_minute.entry(floor_minute(t)).or_default().push(bpm);
        }
    }

    // HRV samples (t, rmssd) collected as a vec for the rolling 10-min mean.
    let mut hrv_samples: Vec<(i64, f64)> = Vec::new();
    {
        let mut stmt = conn.prepare(
            "SELECT captured_at_ms, rmssd_ms FROM hrv_samples \
             WHERE captured_at_ms BETWEEN ?1 AND ?2 \
             ORDER BY captured_at_ms",
        )?;
        let mut rows = stmt.query(rusqlite::params![start_ms, end_ms])?;
        while let Some(row) = rows.next()? {
            let t: i64 = row.get(0)?;
            let v: f64 = row.get(1)?;
            // Drop obvious artifacts so the per-window mean doesn't get pulled.
            if (5.0..=200.0).contains(&v) {
                hrv_samples.push((t, v));
            }
        }
    }

    // IMU -> per-minute movement intensity from accel range magnitude.
    let mut movement_per_minute: std::collections::BTreeMap<i64, f64> =
        std::collections::BTreeMap::new();
    {
        let mut stmt = conn.prepare(
            "SELECT captured_at_ms, axes_meta_json FROM raw_imu_packets \
             WHERE captured_at_ms BETWEEN ?1 AND ?2",
        )?;
        let mut rows = stmt.query(rusqlite::params![start_ms, end_ms])?;
        while let Some(row) = rows.next()? {
            let t: i64 = row.get(0)?;
            let meta_json: String = row.get(1)?;
            let value: serde_json::Value =
                serde_json::from_str(&meta_json).unwrap_or(serde_json::Value::Null);
            let Some(axes) = value.as_array() else {
                continue;
            };
            if axes.len() < 3 {
                continue;
            }
            let mut sq = 0.0;
            for axis in axes.iter().take(3) {
                let max = axis.get("max").and_then(|v| v.as_i64()).unwrap_or(0) as f64;
                let min = axis.get("min").and_then(|v| v.as_i64()).unwrap_or(0) as f64;
                let range = max - min;
                sq += range * range;
            }
            let mag = sq.sqrt();
            *movement_per_minute.entry(floor_minute(t)).or_default() += mag;
        }
    }

    let rmssd_10min_mean = |ms: i64| -> Option<f64> {
        let lo = ms - 5 * 60_000;
        let hi = ms + 5 * 60_000;
        let mut sum = 0.0;
        let mut n = 0;
        for (t, v) in &hrv_samples {
            if *t >= lo && *t <= hi {
                sum += *v;
                n += 1;
            }
        }
        if n == 0 { None } else { Some(sum / n as f64) }
    };

    let start_floor = floor_minute(start_ms);
    let mut rows = Vec::new();
    let mut bucket = start_floor;
    while bucket < end_ms {
        let bpms = hr_per_minute.get(&bucket).cloned().unwrap_or_default();
        let (hr_mean, hr_min, hr_max) = if bpms.is_empty() {
            (None, None, None)
        } else {
            let sum: i64 = bpms.iter().sum();
            let mean = sum as f64 / bpms.len() as f64;
            let min = *bpms.iter().min().unwrap();
            let max = *bpms.iter().max().unwrap();
            (Some(mean), Some(min), Some(max))
        };
        rows.push(MinuteRow {
            bucket_ms: bucket,
            hr_mean,
            hr_min,
            hr_max,
            movement: movement_per_minute.get(&bucket).copied().unwrap_or(0.0),
            rmssd: rmssd_10min_mean(bucket),
            stage: Stage::NotApplicable,
        });
        bucket += 60_000;
    }
    Ok(rows)
}

fn classify_rows(rows: &mut [MinuteRow], options: SleepReadingOptions) -> f64 {
    let mut nonzero_moves: Vec<f64> =
        rows.iter().map(|r| r.movement).filter(|m| *m > 0.0).collect();
    nonzero_moves.sort_by(|a, b| a.partial_cmp(b).unwrap());
    let move_top_decile = if nonzero_moves.is_empty() {
        f64::INFINITY
    } else {
        let idx = (nonzero_moves.len() as f64 * 0.9) as usize;
        nonzero_moves[idx.min(nonzero_moves.len() - 1)]
    };
    let move_median = if nonzero_moves.is_empty() {
        0.0
    } else {
        nonzero_moves[nonzero_moves.len() / 2]
    };
    let rmssd_vals: Vec<f64> = rows.iter().filter_map(|r| r.rmssd).collect();
    let rmssd_window_mean = if rmssd_vals.is_empty() {
        options.hrv_baseline_ms
    } else {
        rmssd_vals.iter().sum::<f64>() / rmssd_vals.len() as f64
    };

    let asleep_threshold = options.resting_bpm as f64 + 3.0;
    let awake_threshold = options.resting_bpm as f64 + 10.0;

    for row in rows.iter_mut() {
        let Some(hr_mean) = row.hr_mean else {
            row.stage = Stage::NotApplicable;
            continue;
        };
        if hr_mean >= awake_threshold || row.movement >= move_top_decile {
            row.stage = Stage::Awake;
        } else if hr_mean <= asleep_threshold
            && row.movement < move_median
            && row.rmssd.is_none_or(|v| v >= rmssd_window_mean * 0.9)
        {
            row.stage = Stage::Deep;
        } else {
            row.stage = Stage::Light;
        }
    }
    rmssd_window_mean
}

fn first_sleep_onset_minutes(rows: &[MinuteRow]) -> Option<i64> {
    let mut run = 0i64;
    for (i, r) in rows.iter().enumerate() {
        if matches!(r.stage, Stage::Light | Stage::Deep) {
            run += 1;
            if run >= 5 {
                return Some(i as i64 - run + 1);
            }
        } else {
            run = 0;
        }
    }
    None
}

fn linear_score(value: f64, zero_at: f64, hundred_at: f64) -> f64 {
    if (hundred_at - zero_at).abs() < f64::EPSILON {
        return 0.0;
    }
    let raw = (value - zero_at) / (hundred_at - zero_at) * 100.0;
    raw.clamp(0.0, 100.0)
}

/// Compute the sleep reading for a window. Reads from the typed mirror
/// tables on `conn`; does not write anything back. Callers persist via
/// [`GooseStore::upsert_sleep_reading`].
pub fn compute_sleep_reading(
    conn: &Connection,
    session_id: Option<&str>,
    start_ms: i64,
    end_ms: i64,
    options: SleepReadingOptions,
) -> GooseResult<SleepReading> {
    if end_ms <= start_ms {
        return Err(GooseError::message(
            "sleep reading window end must be after start",
        ));
    }
    let mut rows = build_minute_series(conn, start_ms, end_ms)?;
    let _ = classify_rows(&mut rows, options);

    let tib_min = rows.len() as i64;
    if tib_min == 0 {
        return Err(GooseError::message(
            "sleep reading window has zero minutes of data",
        ));
    }

    let deep_min = rows.iter().filter(|r| r.stage == Stage::Deep).count() as i64;
    let light_min = rows.iter().filter(|r| r.stage == Stage::Light).count() as i64;
    let awake_min = rows
        .iter()
        .filter(|r| matches!(r.stage, Stage::Awake | Stage::NotApplicable))
        .count() as i64;
    let asleep_min = deep_min + light_min;

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

    let onset_min = first_sleep_onset_minutes(&rows);
    let waso_min = (awake_min - onset_min.unwrap_or(0)).max(0);

    let hr_means: Vec<f64> = rows.iter().filter_map(|r| r.hr_mean).collect();
    let hr_min = rows.iter().filter_map(|r| r.hr_min).min();
    let hr_max = rows.iter().filter_map(|r| r.hr_max).max();
    let hr_mean_bpm = if hr_means.is_empty() {
        None
    } else {
        Some(hr_means.iter().sum::<f64>() / hr_means.len() as f64)
    };

    let rmssd_vals: Vec<f64> = rows.iter().filter_map(|r| r.rmssd).collect();
    let hrv_mean = if rmssd_vals.is_empty() {
        options.hrv_baseline_ms
    } else {
        rmssd_vals.iter().sum::<f64>() / rmssd_vals.len() as f64
    };

    let movement_total: f64 = rows.iter().map(|r| r.movement).sum();
    let movement_peak = rows
        .iter()
        .map(|r| r.movement)
        .fold(0.0_f64, |a, b| a.max(b));
    let movement_burst = rows.iter().filter(|r| r.stage == Stage::Awake).count() as i64;

    let duration_hours = asleep_min as f64 / 60.0;

    let duration_score = (duration_hours / options.need_hours * 100.0).clamp(0.0, 100.0);
    let efficiency_score = linear_score(efficiency, 0.70, 0.92);
    let depth_score = linear_score(deep_share, 0.05, 0.20);
    let hrv_score = linear_score(hrv_mean / options.hrv_baseline_ms, 0.5, 1.5);
    let restfulness_score = ((1.0 - awake_share) * 100.0).clamp(0.0, 100.0);

    let sleep_score = duration_score * 0.25
        + efficiency_score * 0.25
        + depth_score * 0.20
        + hrv_score * 0.15
        + restfulness_score * 0.15;

    Ok(SleepReading {
        schema: "goose.sleep-reading.v1".to_string(),
        session_id: session_id.map(str::to_string),
        source: "goose.local".to_string(),
        date_key: String::new(),
        start_time_unix_ms: start_ms,
        end_time_unix_ms: end_ms,
        time_in_bed_minutes: tib_min,
        total_sleep_minutes: asleep_min,
        deep_minutes: deep_min,
        light_minutes: light_min,
        awake_minutes: awake_min,
        rem_minutes: 0,
        efficiency: round3(efficiency),
        deep_share_of_sleep: round3(deep_share),
        awake_share_of_bed: round3(awake_share),
        onset_latency_minutes: onset_min,
        wake_after_sleep_onset_minutes: waso_min,
        cycle_count: 0,
        disturbance_count: 0,
        sleep_need_ms: (options.need_hours * 3600.0 * 1000.0) as i64,
        hr_mean_bpm: hr_mean_bpm.map(round1),
        hr_min_bpm: hr_min,
        hr_max_bpm: hr_max,
        hrv_mean_rmssd_ms: round1(hrv_mean),
        hrv_sample_count: rmssd_vals.len() as i64,
        movement_total_intensity: round1(movement_total),
        movement_peak_minute: round1(movement_peak),
        movement_burst_minutes: movement_burst,
        duration_score: round1(duration_score),
        efficiency_score: round1(efficiency_score),
        depth_score: round1(depth_score),
        hrv_score: round1(hrv_score),
        restfulness_score: round1(restfulness_score),
        sleep_score: round1(sleep_score),
        resting_bpm_used: options.resting_bpm,
        hrv_baseline_ms_used: options.hrv_baseline_ms,
        need_hours: options.need_hours,
    })
}


fn round1(v: f64) -> f64 {
    (v * 10.0).round() / 10.0
}

fn round3(v: f64) -> f64 {
    (v * 1000.0).round() / 1000.0
}
