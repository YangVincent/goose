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

// MARK: - Imported daily summaries (recovery + sleep + strain per day)

#[derive(Debug, Clone)]
pub struct ImportedDailySummaryInput<'a> {
    pub date_key: &'a str,
    pub recovery_score: Option<f64>,
    pub hrv_rmssd_ms: Option<f64>,
    pub resting_hr_bpm: Option<f64>,
    pub spo2_pct: Option<f64>,
    pub skin_temp_c: Option<f64>,
    pub sleep_performance_pct: Option<f64>,
    pub sleep_efficiency_pct: Option<f64>,
    pub sleep_in_bed_ms: Option<i64>,
    pub sleep_awake_ms: Option<i64>,
    pub sleep_light_ms: Option<i64>,
    pub sleep_deep_ms: Option<i64>,
    pub sleep_rem_ms: Option<i64>,
    pub sleep_cycle_count: Option<i64>,
    pub sleep_disturbance_count: Option<i64>,
    pub sleep_need_baseline_ms: Option<i64>,
    pub sleep_need_from_debt_ms: Option<i64>,
    pub sleep_need_from_strain_ms: Option<i64>,
    pub sleep_need_from_nap_ms: Option<i64>,
    pub strain_score: Option<f64>,
    pub strain_kilojoules: Option<f64>,
    pub source: &'a str,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ImportedDailySummaryRow {
    pub date_key: String,
    pub recovery_score: Option<f64>,
    pub hrv_rmssd_ms: Option<f64>,
    pub resting_hr_bpm: Option<f64>,
    pub spo2_pct: Option<f64>,
    pub skin_temp_c: Option<f64>,
    pub sleep_performance_pct: Option<f64>,
    pub sleep_efficiency_pct: Option<f64>,
    pub sleep_in_bed_ms: Option<i64>,
    pub sleep_awake_ms: Option<i64>,
    pub sleep_light_ms: Option<i64>,
    pub sleep_deep_ms: Option<i64>,
    pub sleep_rem_ms: Option<i64>,
    pub sleep_cycle_count: Option<i64>,
    pub sleep_disturbance_count: Option<i64>,
    pub sleep_need_baseline_ms: Option<i64>,
    pub sleep_need_from_debt_ms: Option<i64>,
    pub sleep_need_from_strain_ms: Option<i64>,
    pub sleep_need_from_nap_ms: Option<i64>,
    pub strain_score: Option<f64>,
    pub strain_kilojoules: Option<f64>,
    pub source: String,
    pub created_at: String,
    pub updated_at: String,
}

// MARK: - Sleep audio events

#[derive(Debug, Clone)]
pub struct SleepAudioEventInput<'a> {
    pub event_id: &'a str,
    pub started_at_ms: i64,
    pub duration_ms: i64,
    pub peak_db: f64,
    pub kind: &'a str,
    pub file_path: Option<&'a str>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct SleepAudioEventRow {
    pub event_id: String,
    pub started_at_ms: i64,
    pub duration_ms: i64,
    pub peak_db: f64,
    pub kind: String,
    pub file_path: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StrapWornSampleRow {
    pub captured_at_ms: i64,
    pub worn: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StrapEventRow {
    pub event_uid: String,
    pub captured_at_ms: i64,
    pub packet_type: Option<i64>,
    pub event_id: Option<i64>,
    pub event_name: Option<String>,
    pub timestamp_seconds: Option<i64>,
    pub timestamp_subseconds: Option<i64>,
    pub worn: Option<bool>,
    pub battery_pct: Option<i64>,
    pub data_hex: String,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct StrapCommandRow {
    pub command_uid: String,
    pub captured_at_ms: i64,
    pub packet_type: i64,
    pub command: Option<i64>,
    pub command_name: Option<String>,
    pub sequence: Option<i64>,
    pub data_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RawK26PacketRow {
    pub packet_id: String,
    pub captured_at_ms: i64,
    pub counter: Option<i64>,
    pub sample_count: i64,
    pub samples: Vec<i16>,
    pub source: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ConsoleLogRow {
    pub log_uid: String,
    pub captured_at_ms: i64,
    pub packet_type: Option<i64>,
    pub level: Option<String>,
    pub text: Option<String>,
    pub data_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct MetadataPacketRow {
    pub packet_uid: String,
    pub captured_at_ms: i64,
    pub packet_type: i64,
    pub data_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct CommandResponseRow {
    pub response_uid: String,
    pub captured_at_ms: i64,
    pub packet_type: Option<i64>,
    pub response_to_command: Option<i64>,
    pub response_to_command_name: Option<String>,
    pub origin_sequence: Option<i64>,
    pub result_code: Option<i64>,
    pub data_hex: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct RawPacketBodyRow {
    pub packet_uid: String,
    pub captured_at_ms: i64,
    pub packet_type: i64,
    pub packet_type_name: Option<String>,
    pub sequence: Option<i64>,
    pub command_or_event: Option<i64>,
    pub payload_hex: String,
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
    /// Back-fill `hr_samples` rows from historical `decoded_frames` whose
    /// HR byte wasn't mirrored at insert time. Re-parses `payload_hex`
    /// (the canonical raw bytes) on the fly rather than reading any JSON
    /// column, so this still works after `parsed_payload_json` is dropped.
    pub fn recover_hr_samples_from_decoded_frames(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<HrRecoveryReport> {
        use crate::protocol::{
            DataPacketBodySummary, DeviceType, ParsedPayload, build_v5_payload_frame, parse_frame,
        };
        let mut stmt = self.conn.prepare(
            "SELECT frame_id, payload_hex, created_at
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
            let payload_hex: String = row.get(1)?;
            let created_at: String = row.get(2)?;
            frames_scanned += 1;
            let captured_at_ms = parse_iso8601_to_ms(&created_at).unwrap_or(0);
            if captured_at_ms < start_ms || captured_at_ms >= end_ms {
                continue;
            }
            let Ok(payload_bytes) = hex::decode(&payload_hex) else {
                continue;
            };
            let frame_bytes = build_v5_payload_frame(&payload_bytes);
            let Ok(frame) = parse_frame(DeviceType::Goose, &frame_bytes) else {
                continue;
            };
            let bpm = match frame.parsed_payload.as_ref() {
                Some(ParsedPayload::DataPacket {
                    body_summary: Some(body),
                    ..
                }) => match body {
                    DataPacketBodySummary::NormalHistory {
                        heart_rate_bpm: Some(bpm),
                        ..
                    }
                    | DataPacketBodySummary::RawSensorHistory {
                        heart_rate_bpm: Some(bpm),
                        ..
                    } => Some(i64::from(*bpm)),
                    DataPacketBodySummary::RawMotionK10 {
                        heart_rate: Some(bpm),
                        ..
                    } => Some(i64::from(*bpm)),
                    _ => None,
                },
                _ => None,
            };
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

    pub fn list_unsynced_hr_samples(&self, limit: i64) -> GooseResult<Vec<HrSampleRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT sample_id, captured_at_ms, bpm, source, synced_at, created_at
             FROM hr_samples
             WHERE synced_at IS NULL
             ORDER BY captured_at_ms
             LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![limit], |row| {
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

    pub fn mark_hr_samples_synced(&self, sample_ids: &[String], now_ms: i64) -> GooseResult<i64> {
        let mut total: i64 = 0;
        for chunk in sample_ids.chunks(500) {
            let placeholders: Vec<String> = (0..chunk.len()).map(|_| "?".to_string()).collect();
            let sql = format!(
                "UPDATE hr_samples SET synced_at = ?1 WHERE sample_id IN ({})",
                placeholders.join(",")
            );
            let mut stmt = self.conn.prepare(&sql)?;
            let mut params_vec: Vec<rusqlite::types::Value> = vec![now_ms.into()];
            for id in chunk {
                params_vec.push(id.clone().into());
            }
            let n = stmt.execute(rusqlite::params_from_iter(params_vec.into_iter()))?;
            total += n as i64;
        }
        Ok(total)
    }

    pub fn list_unsynced_daily_summaries(&self, limit: i64) -> GooseResult<Vec<ImportedDailySummaryRow>> {
        // Daily summaries don't have synced_at — treat as "always send the
        // most recently updated" by ordering on updated_at and capping the
        // batch. The server's INSERT OR IGNORE keeps this safe.
        let mut stmt = self.conn.prepare(
            r#"
            SELECT
                date_key, recovery_score, hrv_rmssd_ms, resting_hr_bpm,
                spo2_pct, skin_temp_c,
                sleep_performance_pct, sleep_efficiency_pct,
                sleep_in_bed_ms, sleep_awake_ms, sleep_light_ms,
                sleep_deep_ms, sleep_rem_ms, sleep_cycle_count,
                sleep_disturbance_count,
                sleep_need_baseline_ms, sleep_need_from_debt_ms,
                sleep_need_from_strain_ms, sleep_need_from_nap_ms,
                strain_score, strain_kilojoules, source,
                created_at, updated_at
            FROM imported_daily_summary
            ORDER BY updated_at DESC
            LIMIT ?1
            "#,
        )?;
        let rows = stmt.query_map(params![limit], |row| {
            Ok(ImportedDailySummaryRow {
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
                source: row.get(21)?,
                created_at: row.get(22)?,
                updated_at: row.get(23)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn upsert_imported_daily_summary(
        &self,
        input: ImportedDailySummaryInput<'_>,
    ) -> GooseResult<()> {
        self.conn.execute(
            r#"
            INSERT INTO imported_daily_summary (
                date_key, recovery_score, hrv_rmssd_ms, resting_hr_bpm,
                spo2_pct, skin_temp_c,
                sleep_performance_pct, sleep_efficiency_pct,
                sleep_in_bed_ms, sleep_awake_ms, sleep_light_ms,
                sleep_deep_ms, sleep_rem_ms, sleep_cycle_count,
                sleep_disturbance_count,
                sleep_need_baseline_ms, sleep_need_from_debt_ms,
                sleep_need_from_strain_ms, sleep_need_from_nap_ms,
                strain_score, strain_kilojoules, source
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11,
                ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22
            )
            ON CONFLICT(date_key) DO UPDATE SET
                recovery_score = COALESCE(excluded.recovery_score, recovery_score),
                hrv_rmssd_ms = COALESCE(excluded.hrv_rmssd_ms, hrv_rmssd_ms),
                resting_hr_bpm = COALESCE(excluded.resting_hr_bpm, resting_hr_bpm),
                spo2_pct = COALESCE(excluded.spo2_pct, spo2_pct),
                skin_temp_c = COALESCE(excluded.skin_temp_c, skin_temp_c),
                sleep_performance_pct = COALESCE(excluded.sleep_performance_pct, sleep_performance_pct),
                sleep_efficiency_pct = COALESCE(excluded.sleep_efficiency_pct, sleep_efficiency_pct),
                sleep_in_bed_ms = COALESCE(excluded.sleep_in_bed_ms, sleep_in_bed_ms),
                sleep_awake_ms = COALESCE(excluded.sleep_awake_ms, sleep_awake_ms),
                sleep_light_ms = COALESCE(excluded.sleep_light_ms, sleep_light_ms),
                sleep_deep_ms = COALESCE(excluded.sleep_deep_ms, sleep_deep_ms),
                sleep_rem_ms = COALESCE(excluded.sleep_rem_ms, sleep_rem_ms),
                sleep_cycle_count = COALESCE(excluded.sleep_cycle_count, sleep_cycle_count),
                sleep_disturbance_count = COALESCE(excluded.sleep_disturbance_count, sleep_disturbance_count),
                sleep_need_baseline_ms = COALESCE(excluded.sleep_need_baseline_ms, sleep_need_baseline_ms),
                sleep_need_from_debt_ms = COALESCE(excluded.sleep_need_from_debt_ms, sleep_need_from_debt_ms),
                sleep_need_from_strain_ms = COALESCE(excluded.sleep_need_from_strain_ms, sleep_need_from_strain_ms),
                sleep_need_from_nap_ms = COALESCE(excluded.sleep_need_from_nap_ms, sleep_need_from_nap_ms),
                strain_score = COALESCE(excluded.strain_score, strain_score),
                strain_kilojoules = COALESCE(excluded.strain_kilojoules, strain_kilojoules),
                source = excluded.source,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            "#,
            params![
                input.date_key,
                input.recovery_score,
                input.hrv_rmssd_ms,
                input.resting_hr_bpm,
                input.spo2_pct,
                input.skin_temp_c,
                input.sleep_performance_pct,
                input.sleep_efficiency_pct,
                input.sleep_in_bed_ms,
                input.sleep_awake_ms,
                input.sleep_light_ms,
                input.sleep_deep_ms,
                input.sleep_rem_ms,
                input.sleep_cycle_count,
                input.sleep_disturbance_count,
                input.sleep_need_baseline_ms,
                input.sleep_need_from_debt_ms,
                input.sleep_need_from_strain_ms,
                input.sleep_need_from_nap_ms,
                input.strain_score,
                input.strain_kilojoules,
                input.source,
            ],
        )?;
        Ok(())
    }

    pub fn imported_daily_summaries_between(
        &self,
        start_date_key: &str,
        end_date_key: &str,
    ) -> GooseResult<Vec<ImportedDailySummaryRow>> {
        let mut stmt = self.conn.prepare(
            r#"
            SELECT
                date_key, recovery_score, hrv_rmssd_ms, resting_hr_bpm,
                spo2_pct, skin_temp_c,
                sleep_performance_pct, sleep_efficiency_pct,
                sleep_in_bed_ms, sleep_awake_ms, sleep_light_ms,
                sleep_deep_ms, sleep_rem_ms, sleep_cycle_count,
                sleep_disturbance_count,
                sleep_need_baseline_ms, sleep_need_from_debt_ms,
                sleep_need_from_strain_ms, sleep_need_from_nap_ms,
                strain_score, strain_kilojoules, source,
                created_at, updated_at
            FROM imported_daily_summary
            WHERE date_key >= ?1 AND date_key <= ?2
            ORDER BY date_key DESC
            "#,
        )?;
        let rows = stmt.query_map(params![start_date_key, end_date_key], |row| {
            Ok(ImportedDailySummaryRow {
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
                source: row.get(21)?,
                created_at: row.get(22)?,
                updated_at: row.get(23)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn insert_sleep_audio_event(&self, input: SleepAudioEventInput<'_>) -> GooseResult<bool> {
        let changed = self.conn.execute(
            r#"
            INSERT OR IGNORE INTO sleep_audio_events
                (event_id, started_at_ms, duration_ms, peak_db, kind, file_path)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6)
            "#,
            params![
                input.event_id,
                input.started_at_ms,
                input.duration_ms,
                input.peak_db,
                input.kind,
                input.file_path,
            ],
        )?;
        Ok(changed > 0)
    }

    pub fn sleep_audio_events_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<SleepAudioEventRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT event_id, started_at_ms, duration_ms, peak_db, kind, file_path, created_at
             FROM sleep_audio_events
             WHERE started_at_ms >= ?1 AND started_at_ms < ?2
             ORDER BY started_at_ms DESC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(SleepAudioEventRow {
                event_id: row.get(0)?,
                started_at_ms: row.get(1)?,
                duration_ms: row.get(2)?,
                peak_db: row.get(3)?,
                kind: row.get(4)?,
                file_path: row.get(5)?,
                created_at: row.get(6)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    /// Persist (or overwrite) the per-session sleep reading. Keyed on
    /// `session_id` so re-running the analysis -- either from a different
    /// `End Sleep` tap, a UI "recompute" action, or a backfill script --
    /// supersedes the prior row cleanly.
    pub fn upsert_sleep_reading(
        &self,
        reading: &crate::sleep_reading::SleepReading,
    ) -> GooseResult<()> {
        let session_id = reading
            .session_id
            .as_deref()
            .ok_or_else(|| GooseError::message("sleep reading session_id is required"))?;
        let reading_json = serde_json::to_string(reading)
            .map_err(|error| GooseError::message(error.to_string()))?;
        self.conn.execute(
            r#"
            INSERT INTO sleep_readings (
                session_id, start_time_unix_ms, end_time_unix_ms,
                time_in_bed_minutes, total_sleep_minutes, deep_minutes,
                light_minutes, awake_minutes, efficiency,
                deep_share_of_sleep, awake_share_of_bed,
                onset_latency_minutes, wake_after_sleep_onset_minutes,
                hr_mean_bpm, hr_min_bpm, hr_max_bpm,
                hrv_mean_rmssd_ms, hrv_sample_count,
                movement_total_intensity, movement_peak_minute,
                movement_burst_minutes,
                duration_score, efficiency_score, depth_score,
                hrv_score, restfulness_score, sleep_score,
                resting_bpm_used, hrv_baseline_ms_used, need_hours,
                reading_json
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13,
                ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24,
                ?25, ?26, ?27, ?28, ?29, ?30, ?31
            )
            ON CONFLICT(session_id) DO UPDATE SET
                start_time_unix_ms = excluded.start_time_unix_ms,
                end_time_unix_ms = excluded.end_time_unix_ms,
                time_in_bed_minutes = excluded.time_in_bed_minutes,
                total_sleep_minutes = excluded.total_sleep_minutes,
                deep_minutes = excluded.deep_minutes,
                light_minutes = excluded.light_minutes,
                awake_minutes = excluded.awake_minutes,
                efficiency = excluded.efficiency,
                deep_share_of_sleep = excluded.deep_share_of_sleep,
                awake_share_of_bed = excluded.awake_share_of_bed,
                onset_latency_minutes = excluded.onset_latency_minutes,
                wake_after_sleep_onset_minutes = excluded.wake_after_sleep_onset_minutes,
                hr_mean_bpm = excluded.hr_mean_bpm,
                hr_min_bpm = excluded.hr_min_bpm,
                hr_max_bpm = excluded.hr_max_bpm,
                hrv_mean_rmssd_ms = excluded.hrv_mean_rmssd_ms,
                hrv_sample_count = excluded.hrv_sample_count,
                movement_total_intensity = excluded.movement_total_intensity,
                movement_peak_minute = excluded.movement_peak_minute,
                movement_burst_minutes = excluded.movement_burst_minutes,
                duration_score = excluded.duration_score,
                efficiency_score = excluded.efficiency_score,
                depth_score = excluded.depth_score,
                hrv_score = excluded.hrv_score,
                restfulness_score = excluded.restfulness_score,
                sleep_score = excluded.sleep_score,
                resting_bpm_used = excluded.resting_bpm_used,
                hrv_baseline_ms_used = excluded.hrv_baseline_ms_used,
                need_hours = excluded.need_hours,
                reading_json = excluded.reading_json,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            "#,
            params![
                session_id,
                reading.start_time_unix_ms,
                reading.end_time_unix_ms,
                reading.time_in_bed_minutes,
                reading.total_sleep_minutes,
                reading.deep_minutes,
                reading.light_minutes,
                reading.awake_minutes,
                reading.efficiency,
                reading.deep_share_of_sleep,
                reading.awake_share_of_bed,
                reading.onset_latency_minutes,
                reading.wake_after_sleep_onset_minutes,
                reading.hr_mean_bpm,
                reading.hr_min_bpm,
                reading.hr_max_bpm,
                reading.hrv_mean_rmssd_ms,
                reading.hrv_sample_count,
                reading.movement_total_intensity,
                reading.movement_peak_minute,
                reading.movement_burst_minutes,
                reading.duration_score,
                reading.efficiency_score,
                reading.depth_score,
                reading.hrv_score,
                reading.restfulness_score,
                reading.sleep_score,
                reading.resting_bpm_used,
                reading.hrv_baseline_ms_used,
                reading.need_hours,
                reading_json,
            ],
        )?;
        Ok(())
    }

    pub fn sleep_reading_for_session(
        &self,
        session_id: &str,
    ) -> GooseResult<Option<crate::sleep_reading::SleepReading>> {
        use rusqlite::OptionalExtension;
        let raw: Option<String> = self
            .conn
            .query_row(
                "SELECT reading_json FROM sleep_readings WHERE session_id = ?1",
                params![session_id],
                |row| row.get(0),
            )
            .optional()?;
        match raw {
            None => Ok(None),
            Some(text) => serde_json::from_str(&text)
                .map(Some)
                .map_err(|error| GooseError::message(error.to_string())),
        }
    }

    pub fn upsert_recovery_reading(
        &self,
        reading: &crate::recovery_reading::RecoveryReading,
    ) -> GooseResult<()> {
        let reading_json = serde_json::to_string(reading)
            .map_err(|error| GooseError::message(error.to_string()))?;
        self.conn.execute(
            r#"
            INSERT INTO recovery_readings (
                session_id, date_key, algorithm_id, algorithm_version,
                start_time_unix_ms, end_time_unix_ms,
                recovery_score, hrv_score, rhr_score, sleep_score,
                respiratory_score, temperature_score, prior_strain_score,
                hrv_rmssd_ms, hrv_baseline_rmssd_ms,
                resting_hr_bpm, resting_hr_baseline_bpm,
                respiratory_rate_rpm, respiratory_rate_baseline_rpm,
                skin_temp_delta_c, prior_strain_0_to_21,
                baseline_nights_used, reading_json
            ) VALUES (
                ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12,
                ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23
            )
            ON CONFLICT(session_id) DO UPDATE SET
                date_key = excluded.date_key,
                algorithm_id = excluded.algorithm_id,
                algorithm_version = excluded.algorithm_version,
                start_time_unix_ms = excluded.start_time_unix_ms,
                end_time_unix_ms = excluded.end_time_unix_ms,
                recovery_score = excluded.recovery_score,
                hrv_score = excluded.hrv_score,
                rhr_score = excluded.rhr_score,
                sleep_score = excluded.sleep_score,
                respiratory_score = excluded.respiratory_score,
                temperature_score = excluded.temperature_score,
                prior_strain_score = excluded.prior_strain_score,
                hrv_rmssd_ms = excluded.hrv_rmssd_ms,
                hrv_baseline_rmssd_ms = excluded.hrv_baseline_rmssd_ms,
                resting_hr_bpm = excluded.resting_hr_bpm,
                resting_hr_baseline_bpm = excluded.resting_hr_baseline_bpm,
                respiratory_rate_rpm = excluded.respiratory_rate_rpm,
                respiratory_rate_baseline_rpm = excluded.respiratory_rate_baseline_rpm,
                skin_temp_delta_c = excluded.skin_temp_delta_c,
                prior_strain_0_to_21 = excluded.prior_strain_0_to_21,
                baseline_nights_used = excluded.baseline_nights_used,
                reading_json = excluded.reading_json,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now')
            "#,
            params![
                reading.session_id,
                reading.date_key,
                reading.algorithm_id,
                reading.algorithm_version,
                reading.start_time_unix_ms,
                reading.end_time_unix_ms,
                reading.recovery_score,
                reading.hrv_score,
                reading.rhr_score,
                reading.sleep_score,
                reading.respiratory_score,
                reading.temperature_score,
                reading.prior_strain_score,
                reading.hrv_rmssd_ms,
                reading.hrv_baseline_rmssd_ms,
                reading.resting_hr_bpm,
                reading.resting_hr_baseline_bpm,
                reading.respiratory_rate_rpm,
                reading.respiratory_rate_baseline_rpm,
                reading.skin_temp_delta_c,
                reading.prior_strain_0_to_21,
                reading.baseline_nights_used,
                reading_json,
            ],
        )?;
        Ok(())
    }

    pub fn recovery_reading_for_session(
        &self,
        session_id: &str,
    ) -> GooseResult<Option<crate::recovery_reading::RecoveryReading>> {
        use rusqlite::OptionalExtension;
        let raw: Option<String> = self
            .conn
            .query_row(
                "SELECT reading_json FROM recovery_readings WHERE session_id = ?1",
                params![session_id],
                |row| row.get(0),
            )
            .optional()?;
        match raw {
            None => Ok(None),
            Some(text) => serde_json::from_str(&text)
                .map(Some)
                .map_err(|error| GooseError::message(error.to_string())),
        }
    }

    /// Most-recent recovery_readings row by `end_time_unix_ms`, or None
    /// when the table is empty. Used by `recovery.latest_reading` to
    /// populate the iOS Recovery card.
    pub fn latest_recovery_reading(
        &self,
    ) -> GooseResult<Option<crate::recovery_reading::RecoveryReading>> {
        use rusqlite::OptionalExtension;
        let raw: Option<String> = self
            .conn
            .query_row(
                "SELECT reading_json FROM recovery_readings \
                 ORDER BY end_time_unix_ms DESC LIMIT 1",
                [],
                |row| row.get(0),
            )
            .optional()?;
        match raw {
            None => Ok(None),
            Some(text) => serde_json::from_str(&text)
                .map(Some)
                .map_err(|error| GooseError::message(error.to_string())),
        }
    }

    /// Trailing N-day rolling history of recovery_readings: one row per
    /// date_key, most-recent first. Drives the iOS recovery trend chart
    /// (previously fed by `metrics.recovery_score_from_features.daily`).
    pub fn recovery_reading_history(
        &self,
        days: i64,
    ) -> GooseResult<Vec<crate::recovery_reading::RecoveryReading>> {
        let mut stmt = self.conn.prepare(
            "SELECT reading_json FROM recovery_readings \
             ORDER BY end_time_unix_ms DESC LIMIT ?1",
        )?;
        let rows = stmt.query_map(params![days], |row| row.get::<_, String>(0))?;
        let mut out = Vec::new();
        for row in rows {
            let text = row?;
            let parsed: crate::recovery_reading::RecoveryReading =
                serde_json::from_str(&text)
                    .map_err(|error| GooseError::message(error.to_string()))?;
            out.push(parsed);
        }
        Ok(out)
    }

    /// One row per STRAP_CONDITION_REPORT (~every 10 minutes) covering the
    /// requested window. Callers use this to derive worn intervals: each
    /// pair of consecutive same-value rows defines a confirmed worn/off
    /// span; transitions narrow the boundary to within the ~10-minute
    /// reporting cadence.
    pub fn strap_worn_samples_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<StrapWornSampleRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT captured_at_ms, worn
             FROM strap_worn_samples
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            let worn_int: i64 = row.get(1)?;
            Ok(StrapWornSampleRow {
                captured_at_ms: row.get(0)?,
                worn: worn_int != 0,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn strap_events_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<StrapEventRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT event_uid, captured_at_ms, packet_type, event_id,
                    event_name, timestamp_seconds, timestamp_subseconds,
                    worn, battery_pct, data_hex, created_at
             FROM strap_events
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            let worn_raw: Option<i64> = row.get(7)?;
            Ok(StrapEventRow {
                event_uid: row.get(0)?,
                captured_at_ms: row.get(1)?,
                packet_type: row.get(2)?,
                event_id: row.get(3)?,
                event_name: row.get(4)?,
                timestamp_seconds: row.get(5)?,
                timestamp_subseconds: row.get(6)?,
                worn: worn_raw.map(|v| v != 0),
                battery_pct: row.get(8)?,
                data_hex: row.get(9)?,
                created_at: row.get(10)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn strap_commands_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<StrapCommandRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT command_uid, captured_at_ms, packet_type, command,
                    command_name, sequence, data_hex
             FROM strap_commands
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(StrapCommandRow {
                command_uid: row.get(0)?,
                captured_at_ms: row.get(1)?,
                packet_type: row.get(2)?,
                command: row.get(3)?,
                command_name: row.get(4)?,
                sequence: row.get(5)?,
                data_hex: row.get(6)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn raw_k26_packets_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<RawK26PacketRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT packet_id, captured_at_ms, counter, sample_count,
                    samples_blob, source
             FROM raw_k26_packets
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            let blob: Vec<u8> = row.get(4)?;
            let mut samples = Vec::with_capacity(blob.len() / 2);
            for chunk in blob.chunks_exact(2) {
                samples.push(i16::from_le_bytes([chunk[0], chunk[1]]));
            }
            Ok(RawK26PacketRow {
                packet_id: row.get(0)?,
                captured_at_ms: row.get(1)?,
                counter: row.get(2)?,
                sample_count: row.get(3)?,
                samples,
                source: row.get(5)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn console_logs_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<ConsoleLogRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT log_uid, captured_at_ms, packet_type, level, text, data_hex
             FROM console_logs
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(ConsoleLogRow {
                log_uid: row.get(0)?,
                captured_at_ms: row.get(1)?,
                packet_type: row.get(2)?,
                level: row.get(3)?,
                text: row.get(4)?,
                data_hex: row.get(5)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn metadata_packets_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<MetadataPacketRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT packet_uid, captured_at_ms, packet_type, data_hex
             FROM metadata_packets
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(MetadataPacketRow {
                packet_uid: row.get(0)?,
                captured_at_ms: row.get(1)?,
                packet_type: row.get(2)?,
                data_hex: row.get(3)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn command_responses_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<CommandResponseRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT response_uid, captured_at_ms, packet_type,
                    response_to_command, response_to_command_name,
                    origin_sequence, result_code, data_hex
             FROM command_responses
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(CommandResponseRow {
                response_uid: row.get(0)?,
                captured_at_ms: row.get(1)?,
                packet_type: row.get(2)?,
                response_to_command: row.get(3)?,
                response_to_command_name: row.get(4)?,
                origin_sequence: row.get(5)?,
                result_code: row.get(6)?,
                data_hex: row.get(7)?,
            })
        })?;
        let mut out = Vec::new();
        for row in rows {
            out.push(row?);
        }
        Ok(out)
    }

    pub fn raw_packet_bodies_between(
        &self,
        start_ms: i64,
        end_ms: i64,
    ) -> GooseResult<Vec<RawPacketBodyRow>> {
        let mut stmt = self.conn.prepare(
            "SELECT packet_uid, captured_at_ms, packet_type,
                    packet_type_name, sequence, command_or_event,
                    payload_hex
             FROM raw_packet_bodies
             WHERE captured_at_ms >= ?1 AND captured_at_ms < ?2
             ORDER BY captured_at_ms ASC",
        )?;
        let rows = stmt.query_map(params![start_ms, end_ms], |row| {
            Ok(RawPacketBodyRow {
                packet_uid: row.get(0)?,
                captured_at_ms: row.get(1)?,
                packet_type: row.get(2)?,
                packet_type_name: row.get(3)?,
                sequence: row.get(4)?,
                command_or_event: row.get(5)?,
                payload_hex: row.get(6)?,
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
