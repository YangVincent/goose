//! Dry-run the WHOOP → typed-tables migration against a pulled phone
//! DB. Opens the file via `GooseStore` (which runs schema migrations
//! v23-v25 on open), then invokes `whoop_migrate_to_typed_tables` and
//! prints a per-table count.
//!
//! Usage:
//!   cargo run --example whoop_migrate_smoke -- /tmp/goose-cleanup/goose-now.sqlite

use goose_core::store::GooseStore;
use rusqlite::Connection;
use std::env;
use std::path::PathBuf;

fn count(conn: &Connection, table: &str) -> i64 {
    conn.query_row(&format!("SELECT COUNT(*) FROM {table}"), [], |r| r.get(0))
        .unwrap_or(0)
}

fn main() {
    let mut argv = env::args().skip(1);
    let db_path: PathBuf = argv
        .next()
        .unwrap_or_else(|| "/tmp/goose-cleanup/goose-now.sqlite".to_string())
        .into();

    println!("db                : {}", db_path.display());

    let store = GooseStore::open(&db_path).expect("open store + run migrations");
    // Pre-migration counts via a fresh connection — examples can't reach
    // the store's pub(crate) field.
    let pre_conn = Connection::open(&db_path).expect("open pre conn");
    let pre_sleep = count(&pre_conn, "sleep_readings");
    let pre_recovery = count(&pre_conn, "recovery_readings");
    let pre_strain = count(&pre_conn, "daily_strain_readings");
    let pre_vitals = count(&pre_conn, "daily_vitals_readings");
    let pre_imported = count(&pre_conn, "imported_daily_summary");
    drop(pre_conn);

    println!();
    println!("before migration ----------");
    println!("  imported_daily_summary  : {pre_imported}");
    println!("  sleep_readings          : {pre_sleep}");
    println!("  recovery_readings       : {pre_recovery}");
    println!("  daily_strain_readings   : {pre_strain}");
    println!("  daily_vitals_readings   : {pre_vitals}");

    let report = store
        .whoop_migrate_to_typed_tables()
        .expect("migrate WHOOP -> typed tables");
    drop(store);

    let post_conn = Connection::open(&db_path).expect("open post conn");
    let post_sleep = count(&post_conn, "sleep_readings");
    let post_recovery = count(&post_conn, "recovery_readings");
    let post_strain = count(&post_conn, "daily_strain_readings");
    let post_vitals = count(&post_conn, "daily_vitals_readings");

    println!();
    println!("migration report ----------");
    println!("  dates seen                       : {}", report.dates_seen);
    println!(
        "  sleep rows landed                : {}",
        report.sleep_rows_landed
    );
    println!(
        "  sleep rows skipped (local wins)  : {}",
        report.sleep_rows_skipped_local_wins
    );
    println!(
        "  recovery rows landed             : {}",
        report.recovery_rows_landed
    );
    println!(
        "  recovery rows skipped (local wins): {}",
        report.recovery_rows_skipped_local_wins
    );
    println!(
        "  strain rows landed               : {}",
        report.strain_rows_landed
    );
    println!(
        "  vitals rows landed               : {}",
        report.vitals_rows_landed
    );

    println!();
    println!("after migration -----------");
    println!("  sleep_readings          : {post_sleep}  (was {pre_sleep})");
    println!("  recovery_readings       : {post_recovery}  (was {pre_recovery})");
    println!("  daily_strain_readings   : {post_strain}  (was {pre_strain})");
    println!("  daily_vitals_readings   : {post_vitals}  (was {pre_vitals})");

    // Sample one WHOOP-imported row from each table to eyeball.
    println!();
    println!("sample whoop.cloud rows ---");

    let sleep_sample: Option<(String, String, f64, i64, i64, i64)> = post_conn
        .query_row(
            "SELECT session_id, date_key, sleep_score, time_in_bed_minutes, \
             total_sleep_minutes, deep_minutes \
             FROM sleep_readings WHERE source = 'whoop.cloud' \
             ORDER BY date_key DESC LIMIT 1",
            [],
            |r| {
                Ok((
                    r.get(0)?,
                    r.get(1)?,
                    r.get(2)?,
                    r.get(3)?,
                    r.get(4)?,
                    r.get(5)?,
                ))
            },
        )
        .ok();
    if let Some((sid, dk, score, tib, tst, deep)) = sleep_sample {
        println!(
            "  sleep    {dk}  session_id={sid}  score={score}  tib={tib}min  tst={tst}min  deep={deep}min"
        );
    }
    let recovery_sample: Option<(String, String, f64)> = post_conn
        .query_row(
            "SELECT session_id, date_key, recovery_score \
             FROM recovery_readings WHERE source = 'whoop.cloud' \
             ORDER BY date_key DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .ok();
    if let Some((sid, dk, score)) = recovery_sample {
        println!("  recovery {dk}  session_id={sid}  score={score}");
    }
    let strain_sample: Option<(String, f64, f64)> = post_conn
        .query_row(
            "SELECT date_key, strain_score, strain_kilojoules \
             FROM daily_strain_readings WHERE source = 'whoop.cloud' \
             ORDER BY date_key DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .ok();
    if let Some((dk, score, kj)) = strain_sample {
        println!("  strain   {dk}  score={score}  kJ={kj}");
    }
    let vitals_sample: Option<(String, Option<f64>, Option<f64>)> = post_conn
        .query_row(
            "SELECT date_key, spo2_pct, skin_temp_c \
             FROM daily_vitals_readings WHERE source = 'whoop.cloud' \
             ORDER BY date_key DESC LIMIT 1",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
        )
        .ok();
    if let Some((dk, spo2, temp)) = vitals_sample {
        println!(
            "  vitals   {dk}  spo2={:?}  skin_temp_c={:?}",
            spo2, temp
        );
    }
}
