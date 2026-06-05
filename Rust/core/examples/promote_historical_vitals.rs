//! Offline-only pass that walks `decoded_frames` for K12 / K24
//! HISTORICAL_DATA packets, re-parses each via
//! `protocol::parsed_payload_from_payload_hex`, and inserts one row per
//! `RawSensorHistory` body into `sensor_samples` with PPG / SpO2 /
//! skin_temp / ambient_light / signal_quality / skin_contact filled in.
//!
//! The live event pipeline already routes K10 / K21 motion packets into
//! `sensor_samples` (timestamp + source + bpm), but the K12 / K24
//! historical sync path that carries the vitals doesn't have a
//! SensorSample writer — so the columns sit NULL even though the parser
//! extracts them. This pass closes the gap.
//!
//! Usage:
//!   cargo run --example promote_historical_vitals -- /tmp/goose.sqlite

use goose_core::store::GooseStore;
use rusqlite::Connection;
use std::env;
use std::path::PathBuf;

fn main() {
    let mut argv = env::args().skip(1);
    let db_path: PathBuf = argv
        .next()
        .unwrap_or_else(|| "/tmp/goose-cleanup/goose-live.sqlite".to_string())
        .into();

    println!("db                  : {}", db_path.display());

    let store = GooseStore::open(&db_path).expect("open store");

    let pre_total: i64 = Connection::open(&db_path)
        .and_then(|c| c.query_row("SELECT COUNT(*) FROM sensor_samples", [], |r| r.get(0)))
        .unwrap_or(0);
    let pre_with_vitals: i64 = Connection::open(&db_path)
        .and_then(|c| {
            c.query_row(
                "SELECT COUNT(*) FROM sensor_samples WHERE spo2_pct IS NOT NULL \
                 OR skin_temp_raw IS NOT NULL OR ppg_green IS NOT NULL",
                [],
                |r| r.get(0),
            )
        })
        .unwrap_or(0);

    println!();
    println!("before --------------");
    println!("  sensor_samples total       : {pre_total}");
    println!("  sensor_samples with vitals : {pre_with_vitals}");

    let report = store
        .promote_decoded_historical_to_sensor_samples()
        .expect("promote historical → sensor_samples");
    drop(store);

    let post_total: i64 = Connection::open(&db_path)
        .and_then(|c| c.query_row("SELECT COUNT(*) FROM sensor_samples", [], |r| r.get(0)))
        .unwrap_or(0);
    let post_with_vitals: i64 = Connection::open(&db_path)
        .and_then(|c| {
            c.query_row(
                "SELECT COUNT(*) FROM sensor_samples WHERE spo2_pct IS NOT NULL \
                 OR skin_temp_raw IS NOT NULL OR ppg_green IS NOT NULL",
                [],
                |r| r.get(0),
            )
        })
        .unwrap_or(0);

    println!();
    println!("report --------------");
    println!("  frames scanned             : {}", report.frames_scanned);
    println!("  frames unparsable          : {}", report.frames_unparsable);
    println!("  frames missing timestamp   : {}", report.frames_no_timestamp);
    println!(
        "  frames skipped (other body): {}",
        report.frames_skipped_other_body
    );
    println!("  samples inserted           : {}", report.samples_inserted);
    println!(
        "  samples already present    : {}",
        report.samples_already_present
    );

    println!();
    println!("after ---------------");
    println!(
        "  sensor_samples total       : {post_total}  (was {pre_total})"
    );
    println!(
        "  sensor_samples with vitals : {post_with_vitals}  (was {pre_with_vitals})"
    );
}
