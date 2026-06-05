//! One-off smoke test for compute_sleep_reading.
//!
//! Prints last night's reading from a pulled phone DB so we can verify
//! the Rust port matches the Python reference (~82.7/100). Window args
//! match /tmp/goose-pull/sleep_reading.json (the Python output).
//!
//! Usage:
//!   cargo run --example sleep_reading_smoke -- \
//!     /tmp/goose-pull/goose-now.sqlite 1780548000000 1780576500000

use goose_core::recovery_reading::{compute_recovery_from_sleep_reading, RecoveryReadingOptions};
use goose_core::sleep_reading::{compute_sleep_reading, SleepReadingOptions};
use rusqlite::Connection;
use std::env;

fn main() {
    let mut argv = env::args().skip(1);
    let db = argv
        .next()
        .unwrap_or_else(|| "/tmp/goose-pull/goose-now.sqlite".to_string());
    let start_ms: i64 = argv
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1_780_548_000_000);
    let end_ms: i64 = argv
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(1_780_576_500_000);
    let session_id = argv.next().unwrap_or_else(|| "smoke-test".to_string());

    let conn = Connection::open(&db).expect("open db");
    let reading = compute_sleep_reading(
        &conn,
        Some(session_id.as_str()),
        start_ms,
        end_ms,
        SleepReadingOptions::default(),
    )
    .expect("compute_sleep_reading");
    let recovery = compute_recovery_from_sleep_reading(
        &conn,
        &reading,
        RecoveryReadingOptions::default(),
    )
    .expect("compute_recovery");

    println!("db            : {}", db);
    println!("window (ms)   : {} → {}", start_ms, end_ms);
    println!("session_id    : {}", session_id);
    println!("------------- sleep reading -------------");
    println!("sleep_score   : {:.1} / 100", reading.sleep_score);
    println!(
        "  duration    : {:.1}  ({}h{:02}m TIB)",
        reading.duration_score,
        reading.time_in_bed_minutes / 60,
        reading.time_in_bed_minutes % 60
    );
    println!(
        "  efficiency  : {:.1}  ({:.0}% asleep / TIB)",
        reading.efficiency_score,
        reading.efficiency * 100.0
    );
    println!(
        "  depth       : {:.1}  ({:.0}% deep / TST)",
        reading.depth_score,
        reading.deep_share_of_sleep * 100.0
    );
    println!(
        "  hrv         : {:.1}  ({:.1} ms avg)",
        reading.hrv_score, reading.hrv_mean_rmssd_ms
    );
    println!("  restful     : {:.1}", reading.restfulness_score);
    println!();
    println!(
        "TIB / TST     : {} / {} min",
        reading.time_in_bed_minutes, reading.total_sleep_minutes
    );
    println!(
        "deep / light  : {} / {} min  (awake {} min)",
        reading.deep_minutes, reading.light_minutes, reading.awake_minutes
    );
    if let Some(hr) = reading.hr_mean_bpm {
        println!("HR mean       : {:.0} bpm", hr);
    }
    println!(
        "onset / WASO  : {} / {} min",
        reading
            .onset_latency_minutes
            .map(|m| m.to_string())
            .unwrap_or_else(|| "—".to_string()),
        reading.wake_after_sleep_onset_minutes
    );

    println!();
    println!("----------- recovery reading -----------");
    println!(
        "recovery      : {:.1} / 100   (date_key {})",
        recovery.recovery_score, recovery.date_key
    );
    println!("  component      score  weight  contribution");
    for c in &recovery.components {
        println!(
            "  {:<13}  {:5.1}   {:.2}    {:5.1}",
            c.name,
            c.score_0_to_100,
            c.weight,
            c.score_0_to_100 * c.weight
        );
    }
    println!();
    println!(
        "  HRV last night  {:.1} ms   (baseline {:.1} ms)",
        recovery.hrv_rmssd_ms, recovery.hrv_baseline_rmssd_ms
    );
    println!(
        "  RHR last night  {:.0} bpm     (baseline {:.0} bpm)",
        recovery.resting_hr_bpm, recovery.resting_hr_baseline_bpm
    );
    println!(
        "  prior strain    {:.2}        (baseline nights {})",
        recovery.prior_strain_0_to_21, recovery.baseline_nights_used
    );
    if !recovery.quality_flags.is_empty() {
        println!("  flags           {:?}", recovery.quality_flags);
    }
}
