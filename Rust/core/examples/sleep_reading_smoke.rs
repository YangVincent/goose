//! One-off smoke test for compute_sleep_reading.
//!
//! Prints last night's reading from a pulled phone DB so we can verify
//! the Rust port matches the Python reference (~82.7/100). Window args
//! match /tmp/goose-pull/sleep_reading.json (the Python output).
//!
//! Usage:
//!   cargo run --example sleep_reading_smoke -- \
//!     /tmp/goose-pull/goose-now.sqlite 1780548000000 1780576500000

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

    let conn = Connection::open(&db).expect("open db");
    let reading = compute_sleep_reading(
        &conn,
        Some("smoke-test"),
        start_ms,
        end_ms,
        SleepReadingOptions::default(),
    )
    .expect("compute_sleep_reading");

    println!("db            : {}", db);
    println!("window (ms)   : {} → {}", start_ms, end_ms);
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
}
