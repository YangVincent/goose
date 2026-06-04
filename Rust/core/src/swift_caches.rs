//! SQLite-backed replacements for the Swift JSON caches.
//!
//! Each Swift store (heart-rate-samples, sensor-samples, step-estimates,
//! r17-samples, imu-samples) used to write its own JSON file on disk. This
//! module gives them all a typed Rust home: append rows via bridge, query
//! ranges via bridge, all backed by the same `goose.sqlite` database that
//! holds activity sessions and historical packets.
//!
//! Design choices that matter:
//!
//! * Raw IMU and R17 samples are packed as binary BLOBs (i16 little-endian)
//!   rather than JSON arrays. ~3x smaller than JSON encoding, ~10x cheaper
//!   to (de)serialize.
//! * Every row carries `synced_at INTEGER NULL`. The eventual one-way sync
//!   daemon drains rows where this is null, then sets it; no row is ever
//!   "lost" by the phone.
//! * No retention/eviction logic here — the phone keeps everything until
//!   the user opts into a retention pass. Disk cost is the price for
//!   "phone is canonical until uploaded".

use crate::error::{GooseError, GooseResult};
use crate::store::GooseStore;
use rusqlite::{OptionalExtension, params};
use serde::{Deserialize, Serialize};

/// Parse the ISO-8601 timestamps decoded_frames.created_at uses
/// (`YYYY-MM-DDTHH:MM:SS.sssZ`) into a unix millisecond integer. Returns
/// None for unparseable strings.
pub(crate) fn parse_iso8601_to_ms(iso: &str) -> Option<i64> {
    // Pure-stdlib parse to avoid pulling in chrono. The format is fixed.
    let trimmed = iso.trim_end_matches('Z');
    let (date_part, time_part) = trimmed.split_once('T')?;
    let mut date_parts = date_part.splitn(3, '-');
    let year: i64 = date_parts.next()?.parse().ok()?;
    let month: i64 = date_parts.next()?.parse().ok()?;
    let day: i64 = date_parts.next()?.parse().ok()?;
    let mut time_parts = time_part.splitn(3, ':');
    let hour: i64 = time_parts.next()?.parse().ok()?;
    let minute: i64 = time_parts.next()?.parse().ok()?;
    let sec_full = time_parts.next()?;
    let (sec_part, ms_part) = sec_full.split_once('.').unwrap_or((sec_full, "0"));
    let second: i64 = sec_part.parse().ok()?;
    let ms: i64 = {
        let mut s = ms_part.to_string();
        while s.len() < 3 { s.push('0'); }
        s[0..3].parse().ok()?
    };
    // Days from civil (Howard Hinnant). Works for all CE dates.
    let y = year - if month <= 2 { 1 } else { 0 };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let m = if month > 2 { month - 3 } else { month + 9 };
    let doy = (153 * m + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days_since_epoch = era * 146097 + doe - 719468;
    let seconds = days_since_epoch * 86400 + hour * 3600 + minute * 60 + second;
    Some(seconds * 1000 + ms)
}

// MARK: - Raw IMU packets (K10 / K21)

/// Per-axis metadata (everything except the raw samples) for one K10 / K21
/// motion packet. The samples themselves live in the row's `samples_blob`,
/// concatenated in axis order; this metadata tells the reader where each
/// axis starts and how many samples to read.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RawImuAxisMeta {
    pub name: String,
    pub expected_count: usize,
    pub parsed_count: usize,
    pub min: Option<i16>,
    pub max: Option<i16>,
    pub sum: i64,
}

#[derive(Debug, Clone)]
pub struct RawImuPacketInput<'a> {
    pub packet_id: &'a str,
    pub captured_at_ms: i64,
    pub kind: &'a str,
    pub heart_rate_bpm: Option<i64>,
    pub axes: &'a [RawImuAxisMeta],
    /// Concatenated axis samples in axis order, packed i16 little-endian.
    pub samples_blob: &'a [u8],
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RawImuPacketRow {
    pub packet_id: String,
    pub captured_at_ms: i64,
    pub kind: String,
    pub heart_rate_bpm: Option<i64>,
    pub axes: Vec<RawImuAxisMeta>,
    /// Concatenated axis samples, packed i16 little-endian. The bridge
    /// re-emits this as base64 so JSON-over-FFI doesn't choke on raw bytes.
    pub samples_blob: Vec<u8>,
    pub synced_at: Option<i64>,
    pub created_at: String,
}

// MARK: - Raw R17 optical packets

#[derive(Debug, Clone)]
pub struct RawR17PacketInput<'a> {
    pub packet_id: &'a str,
    pub captured_at_ms: i64,
    pub flags: Option<i64>,
    pub sample_count: Option<i64>,
    pub channels_or_gain_json: &'a str,
    pub samples_min: Option<i64>,
    pub samples_max: Option<i64>,
    pub samples_sum: i64,
    /// Packed i16 little-endian.
    pub samples_blob: &'a [u8],
    pub source: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct RawR17PacketRow {
    pub packet_id: String,
    pub captured_at_ms: i64,
    pub flags: Option<i64>,
    pub sample_count: Option<i64>,
    pub channels_or_gain: Vec<i64>,
    pub samples_min: Option<i64>,
    pub samples_max: Option<i64>,
    pub samples_sum: i64,
    pub samples_blob: Vec<u8>,
    pub source: String,
    pub synced_at: Option<i64>,
    pub created_at: String,
}

// MARK: - HR samples

#[derive(Debug, Clone)]
pub struct HrSampleInput<'a> {
    pub sample_id: &'a str,
    pub captured_at_ms: i64,
    pub bpm: i64,
    pub source: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct HrSampleRow {
    pub sample_id: String,
    pub captured_at_ms: i64,
    pub bpm: i64,
    pub source: String,
    pub synced_at: Option<i64>,
    pub created_at: String,
}

// MARK: - Sensor samples (K12/K18/K24)

#[derive(Debug, Clone)]
pub struct SensorSampleInput<'a> {
    pub sample_id: &'a str,
    pub captured_at_ms: i64,
    pub source: &'a str,
    pub bpm: Option<i64>,
    pub rr_intervals_ms_json: Option<&'a str>,
    pub ppg_green: Option<i64>,
    pub ppg_red_ir: Option<i64>,
    pub spo2_red: Option<i64>,
    pub spo2_ir: Option<i64>,
    pub spo2_pct: Option<i64>,
    pub skin_temp_raw: Option<i64>,
    pub ambient_light: Option<i64>,
    pub led_drive_1: Option<i64>,
    pub led_drive_2: Option<i64>,
    pub signal_quality: Option<i64>,
    pub skin_contact: Option<i64>,
    pub accel_gravity_json: Option<&'a str>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SensorSampleRow {
    pub sample_id: String,
    pub captured_at_ms: i64,
    pub source: String,
    pub bpm: Option<i64>,
    pub rr_intervals_ms: Option<Vec<i64>>,
    pub ppg_green: Option<i64>,
    pub ppg_red_ir: Option<i64>,
    pub spo2_red: Option<i64>,
    pub spo2_ir: Option<i64>,
    pub spo2_pct: Option<i64>,
    pub skin_temp_raw: Option<i64>,
    pub ambient_light: Option<i64>,
    pub led_drive_1: Option<i64>,
    pub led_drive_2: Option<i64>,
    pub signal_quality: Option<i64>,
    pub skin_contact: Option<i64>,
    pub accel_gravity: Option<Vec<f64>>,
    pub synced_at: Option<i64>,
    pub created_at: String,
}

// MARK: - HRV samples

#[derive(Debug, Clone)]
pub struct HrvSampleInput<'a> {
    pub sample_id: &'a str,
    pub captured_at_ms: i64,
    pub rmssd_ms: f64,
    pub rr_interval_count: i64,
    pub source: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct HrvSampleRow {
    pub sample_id: String,
    pub captured_at_ms: i64,
    pub rmssd_ms: f64,
    pub rr_interval_count: i64,
    pub source: String,
    pub synced_at: Option<i64>,
    pub created_at: String,
}

// MARK: - Step day totals

#[derive(Debug, Clone)]
pub struct StepDayInput<'a> {
    pub date_key: &'a str,
    pub active_seconds: f64,
    pub estimated_steps: f64,
    pub packet_count: i64,
    pub last_updated_ms: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StepDayRow {
    pub date_key: String,
    pub active_seconds: f64,
    pub estimated_steps: f64,
    pub packet_count: i64,
    pub last_updated_ms: i64,
    pub synced_at: Option<i64>,
    pub created_at: String,
    pub updated_at: String,
}

/// One-shot recovery summary returned by
/// `recover_hr_samples_from_decoded_frames`. Diagnostic only; callers can
/// surface this to the UI ("recovered N HR samples from decoded frames").
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HrRecoveryReport {
    pub frames_scanned: i64,
    pub hr_samples_extracted: i64,
    pub hr_samples_inserted: i64,
    pub time_range_start_ms: Option<i64>,
    pub time_range_end_ms: Option<i64>,
}

// MARK: - Store impls

impl GooseStore {
    // ---- Raw IMU ----

    pub fn insert_raw_imu_packet(&self, input: RawImuPacketInput<'_>) -> GooseResult<bool> {
        let axes_json = serde_json::to_string(input.axes).map_err(|err| {
            GooseError::message(format!("encode imu axes: {err}"))
        })?;
        let changed = self.conn.execute(
            r#"
            INSERT OR IGNORE INTO raw_imu_packets (
                packet_id, captured_at_ms, kind, heart_rate_bpm,
                axes_meta_json, samples_blob
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                input.packet_id,
                input.captured_at_ms,
                input.kind,
                input.heart_rate_bpm,
                axes_json,
                input.samples_blob,
            ],
        )?;
        Ok(changed > 0)
    }

    pub fn raw_imu_packets_between(
        &self,
        start_ms: i64,
        end_ms: i64,
        limit: Option<i64>,
    ) -> GooseResult<Vec<RawImuPacketRow>> {
        let sql = if limit.is_some() {
            "SELECT packet_id, captured_at_ms, kind, heart_rate_bpm,
                    axes_meta_json, samples_blob, synced_at, created_at
             FROM raw_imu_packets
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms DESC
             LIMIT ?3"
        } else {
            "SELECT packet_id, captured_at_ms, kind, heart_rate_bpm,
                    axes_meta_json, samples_blob, synced_at, created_at
             FROM raw_imu_packets
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms DESC"
        };
        let mut stmt = self.conn.prepare(sql)?;
        let mut rows = if let Some(limit) = limit {
            stmt.query(params![start_ms, end_ms, limit])?
        } else {
            stmt.query(params![start_ms, end_ms])?
        };
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            let axes_json: String = row.get(4)?;
            let axes: Vec<RawImuAxisMeta> = serde_json::from_str(&axes_json).map_err(|err| {
                GooseError::message(format!("decode imu axes: {err}"))
            })?;
            out.push(RawImuPacketRow {
                packet_id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                kind: row.get(2)?,
                heart_rate_bpm: row.get(3)?,
                axes,
                samples_blob: row.get(5)?,
                synced_at: row.get(6)?,
                created_at: row.get(7)?,
            });
        }
        Ok(out)
    }

    pub fn raw_imu_packet_count(&self) -> GooseResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM raw_imu_packets", [], |row| row.get(0))?;
        Ok(count)
    }

    // ---- Raw R17 ----

    pub fn insert_raw_r17_packet(&self, input: RawR17PacketInput<'_>) -> GooseResult<bool> {
        let changed = self.conn.execute(
            r#"
            INSERT OR IGNORE INTO raw_r17_packets (
                packet_id, captured_at_ms, flags, sample_count,
                channels_or_gain, samples_min, samples_max, samples_sum,
                samples_blob, source
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            "#,
            params![
                input.packet_id,
                input.captured_at_ms,
                input.flags,
                input.sample_count,
                input.channels_or_gain_json,
                input.samples_min,
                input.samples_max,
                input.samples_sum,
                input.samples_blob,
                input.source,
            ],
        )?;
        Ok(changed > 0)
    }

    pub fn raw_r17_packets_between(
        &self,
        start_ms: i64,
        end_ms: i64,
        limit: Option<i64>,
    ) -> GooseResult<Vec<RawR17PacketRow>> {
        let sql = if limit.is_some() {
            "SELECT packet_id, captured_at_ms, flags, sample_count,
                    channels_or_gain, samples_min, samples_max, samples_sum,
                    samples_blob, source, synced_at, created_at
             FROM raw_r17_packets
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms DESC
             LIMIT ?3"
        } else {
            "SELECT packet_id, captured_at_ms, flags, sample_count,
                    channels_or_gain, samples_min, samples_max, samples_sum,
                    samples_blob, source, synced_at, created_at
             FROM raw_r17_packets
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms DESC"
        };
        let mut stmt = self.conn.prepare(sql)?;
        let mut rows = if let Some(limit) = limit {
            stmt.query(params![start_ms, end_ms, limit])?
        } else {
            stmt.query(params![start_ms, end_ms])?
        };
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            let channels_json: Option<String> = row.get(4)?;
            let channels: Vec<i64> = channels_json
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok())
                .unwrap_or_default();
            out.push(RawR17PacketRow {
                packet_id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                flags: row.get(2)?,
                sample_count: row.get(3)?,
                channels_or_gain: channels,
                samples_min: row.get(5)?,
                samples_max: row.get(6)?,
                samples_sum: row.get(7)?,
                samples_blob: row.get(8)?,
                source: row.get(9)?,
                synced_at: row.get(10)?,
                created_at: row.get(11)?,
            });
        }
        Ok(out)
    }

    pub fn raw_r17_packet_count(&self) -> GooseResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM raw_r17_packets", [], |row| row.get(0))?;
        Ok(count)
    }

    // ---- HR samples ----

    pub fn insert_hr_sample(&self, input: HrSampleInput<'_>) -> GooseResult<bool> {
        let changed = self.conn.execute(
            r#"
            INSERT OR IGNORE INTO hr_samples (sample_id, captured_at_ms, bpm, source)
            VALUES (?1, ?2, ?3, ?4)
            "#,
            params![input.sample_id, input.captured_at_ms, input.bpm, input.source],
        )?;
        Ok(changed > 0)
    }

    pub fn hr_samples_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<HrSampleRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT sample_id, captured_at_ms, bpm, source, synced_at, created_at
             FROM hr_samples
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(HrSampleRow {
                sample_id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                bpm: row.get(2)?,
                source: row.get(3)?,
                synced_at: row.get(4)?,
                created_at: row.get(5)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn hr_sample_count(&self) -> GooseResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM hr_samples", [], |row| row.get(0))?;
        Ok(count)
    }

    // ---- Sensor samples ----

    pub fn insert_sensor_sample(&self, input: SensorSampleInput<'_>) -> GooseResult<bool> {
        let changed = self.conn.execute(
            r#"
            INSERT OR IGNORE INTO sensor_samples (
                sample_id, captured_at_ms, source,
                bpm, rr_intervals_ms,
                ppg_green, ppg_red_ir,
                spo2_red, spo2_ir, spo2_pct,
                skin_temp_raw, ambient_light,
                led_drive_1, led_drive_2,
                signal_quality, skin_contact,
                accel_gravity
            ) VALUES (
                ?1, ?2, ?3,
                ?4, ?5,
                ?6, ?7,
                ?8, ?9, ?10,
                ?11, ?12,
                ?13, ?14,
                ?15, ?16,
                ?17
            )
            "#,
            params![
                input.sample_id,
                input.captured_at_ms,
                input.source,
                input.bpm,
                input.rr_intervals_ms_json,
                input.ppg_green,
                input.ppg_red_ir,
                input.spo2_red,
                input.spo2_ir,
                input.spo2_pct,
                input.skin_temp_raw,
                input.ambient_light,
                input.led_drive_1,
                input.led_drive_2,
                input.signal_quality,
                input.skin_contact,
                input.accel_gravity_json,
            ],
        )?;
        Ok(changed > 0)
    }

    pub fn sensor_samples_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<SensorSampleRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT sample_id, captured_at_ms, source,
                    bpm, rr_intervals_ms,
                    ppg_green, ppg_red_ir,
                    spo2_red, spo2_ir, spo2_pct,
                    skin_temp_raw, ambient_light,
                    led_drive_1, led_drive_2,
                    signal_quality, skin_contact,
                    accel_gravity,
                    synced_at, created_at
             FROM sensor_samples
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let mut rows = stmt.query(params![start_ms, end_ms])?;
        let mut out = Vec::new();
        while let Some(row) = rows.next()? {
            let rr_json: Option<String> = row.get(4)?;
            let rr_intervals_ms: Option<Vec<i64>> = rr_json
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok());
            let gravity_json: Option<String> = row.get(16)?;
            let accel_gravity: Option<Vec<f64>> = gravity_json
                .as_deref()
                .and_then(|json| serde_json::from_str(json).ok());
            out.push(SensorSampleRow {
                sample_id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                source: row.get(2)?,
                bpm: row.get(3)?,
                rr_intervals_ms,
                ppg_green: row.get(5)?,
                ppg_red_ir: row.get(6)?,
                spo2_red: row.get(7)?,
                spo2_ir: row.get(8)?,
                spo2_pct: row.get(9)?,
                skin_temp_raw: row.get(10)?,
                ambient_light: row.get(11)?,
                led_drive_1: row.get(12)?,
                led_drive_2: row.get(13)?,
                signal_quality: row.get(14)?,
                skin_contact: row.get(15)?,
                accel_gravity,
                synced_at: row.get(17)?,
                created_at: row.get(18)?,
            });
        }
        Ok(out)
    }

    pub fn sensor_sample_count(&self) -> GooseResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM sensor_samples", [], |row| row.get(0))?;
        Ok(count)
    }

    pub fn most_recent_sensor_sample_at(&self) -> GooseResult<Option<i64>> {
        let value: Option<i64> = self
            .conn
            .query_row(
                "SELECT MAX(captured_at_ms) FROM sensor_samples",
                [],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        Ok(value)
    }

    /// One-shot recovery: walk decoded_frames between two timestamps,
    /// extract any HR readings the parser found, and INSERT OR IGNORE
    /// them into hr_samples. Designed to back-fill the hr_samples table
    /// from frames Goose decoded *before* the Swift HR cache was wired up,
    /// or after a destructive Swift cache reset.
    ///
    /// The decoded_frames table doesn't carry a captured_at column; we
    /// fall back to `created_at`. For each frame, we look at the parsed
    /// JSON's body_summary for fields named:
    ///   - "heart_rate_bpm"  (K18, K12, K24)
    ///   - "heart_rate"      (K10/K21)
    ///
    /// Returns a diagnostic report.
    pub fn recover_hr_samples_from_decoded_frames(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<HrRecoveryReport> {
        let mut stmt = self.conn.prepare(
            "SELECT frame_id, parsed_payload_json, created_at
             FROM decoded_frames
             ORDER BY created_at ASC",
        )?;
        let mut rows = stmt.query([])?;
        let mut frames_scanned: i64 = 0;
        let mut extracted: i64 = 0;
        let mut inserted: i64 = 0;
        let mut earliest: Option<i64> = None;
        let mut latest: Option<i64> = None;

        while let Some(row) = rows.next()? {
            let frame_id: String = row.get(0)?;
            let parsed_json: String = row.get(1)?;
            let created_at: String = row.get(2)?;
            frames_scanned += 1;
            let captured_at_ms = parse_iso8601_to_ms(&created_at).unwrap_or(0);
            if captured_at_ms < start_ms || captured_at_ms >= end_ms {
                continue;
            }
            let value: serde_json::Value = match serde_json::from_str(&parsed_json) {
                Ok(v) => v,
                Err(_) => continue,
            };
            let body = value
                .get("parsed_payload")
                .and_then(|p| p.get("body_summary"));
            let Some(body) = body else { continue };
            let bpm = body
                .get("heart_rate_bpm")
                .and_then(|v| v.as_i64())
                .or_else(|| body.get("heart_rate").and_then(|v| v.as_i64()));
            let Some(bpm) = bpm else { continue };
            if !(20..=240).contains(&bpm) {
                continue;
            }
            extracted += 1;
            earliest = Some(earliest.map_or(captured_at_ms, |e| e.min(captured_at_ms)));
            latest = Some(latest.map_or(captured_at_ms, |e| e.max(captured_at_ms)));
            let sample_id = format!("recovered.{}.{}", frame_id, captured_at_ms);
            let changed = self.conn.execute(
                "INSERT OR IGNORE INTO hr_samples (sample_id, captured_at_ms, bpm, source)
                 VALUES (?1, ?2, ?3, 'recovered.decoded_frames')",
                params![sample_id, captured_at_ms, bpm],
            )?;
            inserted += changed as i64;
        }

        Ok(HrRecoveryReport {
            frames_scanned,
            hr_samples_extracted: extracted,
            hr_samples_inserted: inserted,
            time_range_start_ms: earliest,
            time_range_end_ms: latest,
        })
    }

    // ---- HRV samples ----

    pub fn insert_hrv_sample(&self, input: HrvSampleInput<'_>) -> GooseResult<bool> {
        let changed = self.conn.execute(
            r#"
            INSERT OR IGNORE INTO hrv_samples (
                sample_id, captured_at_ms, rmssd_ms, rr_interval_count, source
            ) VALUES (?1, ?2, ?3, ?4, ?5)
            "#,
            params![
                input.sample_id,
                input.captured_at_ms,
                input.rmssd_ms,
                input.rr_interval_count,
                input.source,
            ],
        )?;
        Ok(changed > 0)
    }

    pub fn hrv_samples_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<HrvSampleRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT sample_id, captured_at_ms, rmssd_ms, rr_interval_count,
                    source, synced_at, created_at
             FROM hrv_samples
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(HrvSampleRow {
                sample_id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                rmssd_ms: row.get(2)?,
                rr_interval_count: row.get(3)?,
                source: row.get(4)?,
                synced_at: row.get(5)?,
                created_at: row.get(6)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn hrv_sample_count(&self) -> GooseResult<i64> {
        let count: i64 = self
            .conn
            .query_row("SELECT COUNT(*) FROM hrv_samples", [], |row| row.get(0))?;
        Ok(count)
    }

    // ---- Step days ----

    pub fn upsert_step_day(&self, input: StepDayInput<'_>) -> GooseResult<()> {
        self.conn.execute(
            r#"
            INSERT INTO step_days (
                date_key, active_seconds, estimated_steps,
                packet_count, last_updated_ms
            ) VALUES (?1, ?2, ?3, ?4, ?5)
            ON CONFLICT(date_key) DO UPDATE SET
                active_seconds = excluded.active_seconds,
                estimated_steps = excluded.estimated_steps,
                packet_count = excluded.packet_count,
                last_updated_ms = excluded.last_updated_ms,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
                synced_at = NULL
            "#,
            params![
                input.date_key,
                input.active_seconds,
                input.estimated_steps,
                input.packet_count,
                input.last_updated_ms,
            ],
        )?;
        Ok(())
    }

    pub fn step_days_recent(&self, limit: i64) -> GooseResult<Vec<StepDayRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT date_key, active_seconds, estimated_steps,
                    packet_count, last_updated_ms,
                    synced_at, created_at, updated_at
             FROM step_days
             ORDER BY date_key DESC
             LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            Ok(StepDayRow {
                date_key: row.get(0)?,
                active_seconds: row.get(1)?,
                estimated_steps: row.get(2)?,
                packet_count: row.get(3)?,
                last_updated_ms: row.get(4)?,
                synced_at: row.get(5)?,
                created_at: row.get(6)?,
                updated_at: row.get(7)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn step_day(&self, date_key: &str) -> GooseResult<Option<StepDayRow>> {
        let row = self
            .conn
            .query_row(
                "SELECT date_key, active_seconds, estimated_steps,
                        packet_count, last_updated_ms,
                        synced_at, created_at, updated_at
                 FROM step_days WHERE date_key = ?1",
                params![date_key],
                |row| {
                    Ok(StepDayRow {
                        date_key: row.get(0)?,
                        active_seconds: row.get(1)?,
                        estimated_steps: row.get(2)?,
                        packet_count: row.get(3)?,
                        last_updated_ms: row.get(4)?,
                        synced_at: row.get(5)?,
                        created_at: row.get(6)?,
                        updated_at: row.get(7)?,
                    })
                },
            )
            .optional()?;
        Ok(row)
    }
}
