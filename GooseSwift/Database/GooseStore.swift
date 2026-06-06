import Foundation

/// Per-table CRUD ported from Rust/core/src/swift_caches.rs. The Rust
/// implementation lives in `impl GooseStore` — this is the Swift mirror,
/// one function per public method. Argument names + SQL strings match
/// the Rust originals so behavior stays in lockstep during the
/// migration window (Phase 6 cuts every Swift bridge.request() call
/// site over to this).
///
/// Wrapper struct owns the GooseDB; SQL stays inline for now. Once Phase
/// 6 is done and the bridge.rs dispatcher is deleted, we can group these
/// into smaller files by domain.
final class GooseStore {
  let db: GooseDB

  init(db: GooseDB) {
    self.db = db
  }

  /// Open the database at `path`, run migrate(), and return the store.
  /// Convenience constructor — most callers use this rather than the
  /// init-with-db form.
  static func open(at path: String) throws -> GooseStore {
    let db = try GooseDB(path: path)
    _ = try GooseSchema.migrate(db: db)
    return GooseStore(db: db)
  }

  // MARK: - HR samples

  struct HrSampleInput {
    let sampleID: String
    let capturedAtMs: Int64
    let bpm: Int64
    let source: String
  }

  struct HrSampleRow {
    let sampleID: String
    let capturedAtMs: Int64
    let bpm: Int64
    let source: String
    let syncedAt: Int64?
    let createdAt: String
  }

  /// Returns true if a row was actually inserted (i.e. the sample_id
  /// wasn't already present). INSERT OR IGNORE matches Rust behavior.
  @discardableResult
  func insertHRSample(_ input: HrSampleInput) throws -> Bool {
    let n = try db.executeStatement(
      """
      INSERT OR IGNORE INTO hr_samples (sample_id, captured_at_ms, bpm, source)
      VALUES (?, ?, ?, ?)
      """,
      params: [input.sampleID, input.capturedAtMs, input.bpm, input.source]
    )
    return n > 0
  }

  func hrSamplesBetween(startMs: Int64, endMs: Int64) throws -> [HrSampleRow] {
    try db.queryMap(
      """
      SELECT sample_id, captured_at_ms, bpm, source, synced_at, created_at
      FROM hr_samples
      WHERE captured_at_ms >= ? AND captured_at_ms < ?
      ORDER BY captured_at_ms ASC
      """,
      params: [startMs, endMs]
    ) { row in
      HrSampleRow(
        sampleID: row.string(0) ?? "",
        capturedAtMs: row.int(1) ?? 0,
        bpm: row.int(2) ?? 0,
        source: row.string(3) ?? "",
        syncedAt: row.int(4),
        createdAt: row.string(5) ?? ""
      )
    }
  }

  func hrSampleCount() throws -> Int64 {
    try db.queryFirst("SELECT COUNT(*) FROM hr_samples") { $0.int(0) ?? 0 } ?? 0
  }

  // MARK: - HRV samples

  struct HrvSampleInput {
    let sampleID: String
    let capturedAtMs: Int64
    let rmssdMs: Double
    let rrIntervalCount: Int64
    let source: String
  }

  struct HrvSampleRow {
    let sampleID: String
    let capturedAtMs: Int64
    let rmssdMs: Double
    let rrIntervalCount: Int64
    let source: String
    let syncedAt: Int64?
    let createdAt: String
  }

  @discardableResult
  func insertHRVSample(_ input: HrvSampleInput) throws -> Bool {
    let n = try db.executeStatement(
      """
      INSERT OR IGNORE INTO hrv_samples (
        sample_id, captured_at_ms, rmssd_ms, rr_interval_count, source
      ) VALUES (?, ?, ?, ?, ?)
      """,
      params: [
        input.sampleID, input.capturedAtMs, input.rmssdMs,
        input.rrIntervalCount, input.source,
      ]
    )
    return n > 0
  }

  func hrvSamplesBetween(startMs: Int64, endMs: Int64) throws -> [HrvSampleRow] {
    try db.queryMap(
      """
      SELECT sample_id, captured_at_ms, rmssd_ms, rr_interval_count, source, synced_at, created_at
      FROM hrv_samples
      WHERE captured_at_ms >= ? AND captured_at_ms < ?
      ORDER BY captured_at_ms ASC
      """,
      params: [startMs, endMs]
    ) { row in
      HrvSampleRow(
        sampleID: row.string(0) ?? "",
        capturedAtMs: row.int(1) ?? 0,
        rmssdMs: row.double(2) ?? 0,
        rrIntervalCount: row.int(3) ?? 0,
        source: row.string(4) ?? "",
        syncedAt: row.int(5),
        createdAt: row.string(6) ?? ""
      )
    }
  }

  func hrvSampleCount() throws -> Int64 {
    try db.queryFirst("SELECT COUNT(*) FROM hrv_samples") { $0.int(0) ?? 0 } ?? 0
  }

  // MARK: - Sensor samples

  struct SensorSampleInput {
    let sampleID: String
    let capturedAtMs: Int64
    let source: String
    let bpm: Int64?
    let rrIntervalsMsJSON: String?
    let ppgGreen: Int64?
    let ppgRedIR: Int64?
    let spo2Red: Int64?
    let spo2IR: Int64?
    let spo2Pct: Int64?
    let skinTempRaw: Int64?
    let ambientLight: Int64?
    let ledDrive1: Int64?
    let ledDrive2: Int64?
    let signalQuality: Int64?
    let skinContact: Int64?
    let accelGravityJSON: String?
  }

  struct SensorSampleRow {
    let sampleID: String
    let capturedAtMs: Int64
    let source: String
    let bpm: Int64?
    let rrIntervalsMs: [Int64]?
    let ppgGreen: Int64?
    let ppgRedIR: Int64?
    let spo2Red: Int64?
    let spo2IR: Int64?
    let spo2Pct: Int64?
    let skinTempRaw: Int64?
    let ambientLight: Int64?
    let ledDrive1: Int64?
    let ledDrive2: Int64?
    let signalQuality: Int64?
    let skinContact: Int64?
    let accelGravity: [Double]?
    let syncedAt: Int64?
    let createdAt: String
  }

  @discardableResult
  func insertSensorSample(_ input: SensorSampleInput) throws -> Bool {
    // Type-checker can't handle the 17-element heterogeneous array
    // literal inline; build it step-by-step so each step has a
    // concrete type.
    var params: [Any?] = []
    params.append(input.sampleID)
    params.append(input.capturedAtMs)
    params.append(input.source)
    params.append(input.bpm)
    params.append(input.rrIntervalsMsJSON)
    params.append(input.ppgGreen)
    params.append(input.ppgRedIR)
    params.append(input.spo2Red)
    params.append(input.spo2IR)
    params.append(input.spo2Pct)
    params.append(input.skinTempRaw)
    params.append(input.ambientLight)
    params.append(input.ledDrive1)
    params.append(input.ledDrive2)
    params.append(input.signalQuality)
    params.append(input.skinContact)
    params.append(input.accelGravityJSON)
    let n = try db.executeStatement(
      """
      INSERT OR IGNORE INTO sensor_samples (
        sample_id, captured_at_ms, source,
        bpm, rr_intervals_ms,
        ppg_green, ppg_red_ir,
        spo2_red, spo2_ir, spo2_pct,
        skin_temp_raw, ambient_light,
        led_drive_1, led_drive_2,
        signal_quality, skin_contact,
        accel_gravity
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      """,
      params: params
    )
    return n > 0
  }

  func sensorSamplesBetween(startMs: Int64, endMs: Int64) throws -> [SensorSampleRow] {
    try db.queryMap(
      """
      SELECT sample_id, captured_at_ms, source,
             bpm, rr_intervals_ms,
             ppg_green, ppg_red_ir,
             spo2_red, spo2_ir, spo2_pct,
             skin_temp_raw, ambient_light,
             led_drive_1, led_drive_2,
             signal_quality, skin_contact,
             accel_gravity,
             synced_at, created_at
      FROM sensor_samples
      WHERE captured_at_ms >= ? AND captured_at_ms < ?
      ORDER BY captured_at_ms ASC
      """,
      params: [startMs, endMs]
    ) { row in
      try Self.decodeSensorSampleRow(row)
    }
  }

  private static func decodeSensorSampleRow(_ row: GooseDBRow) throws -> SensorSampleRow {
    let rrJSON = row.string(4)
    let rrIntervals: [Int64]? = rrJSON
      .flatMap { $0.data(using: .utf8) }
      .flatMap { data in
        let raw = try? JSONSerialization.jsonObject(with: data)
        return (raw as? [NSNumber])?.map { $0.int64Value }
      }
    let gravityJSON = row.string(16)
    let accelGravity: [Double]? = gravityJSON
      .flatMap { $0.data(using: .utf8) }
      .flatMap { data in
        let raw = try? JSONSerialization.jsonObject(with: data)
        return (raw as? [NSNumber])?.map { $0.doubleValue }
      }
    return SensorSampleRow(
      sampleID: row.string(0) ?? "",
      capturedAtMs: row.int(1) ?? 0,
      source: row.string(2) ?? "",
      bpm: row.int(3),
      rrIntervalsMs: rrIntervals,
      ppgGreen: row.int(5),
      ppgRedIR: row.int(6),
      spo2Red: row.int(7),
      spo2IR: row.int(8),
      spo2Pct: row.int(9),
      skinTempRaw: row.int(10),
      ambientLight: row.int(11),
      ledDrive1: row.int(12),
      ledDrive2: row.int(13),
      signalQuality: row.int(14),
      skinContact: row.int(15),
      accelGravity: accelGravity,
      syncedAt: row.int(17),
      createdAt: row.string(18) ?? ""
    )
  }

  // MARK: - Step days

  struct StepDayInput {
    let dateKey: String
    let activeSeconds: Double
    let estimatedSteps: Double
    let packetCount: Int64
    let lastUpdatedMs: Int64
  }

  struct StepDayRow {
    let dateKey: String
    let activeSeconds: Double
    let estimatedSteps: Double
    let packetCount: Int64
    let lastUpdatedMs: Int64
    let syncedAt: Int64?
    let createdAt: String
    let updatedAt: String
  }

  func upsertStepDay(_ input: StepDayInput) throws {
    try db.executeStatement(
      """
      INSERT INTO step_days (
        date_key, active_seconds, estimated_steps,
        packet_count, last_updated_ms
      ) VALUES (?, ?, ?, ?, ?)
      ON CONFLICT(date_key) DO UPDATE SET
        active_seconds = excluded.active_seconds,
        estimated_steps = excluded.estimated_steps,
        packet_count = excluded.packet_count,
        last_updated_ms = excluded.last_updated_ms,
        updated_at = strftime('%Y-%m-%dT%H:%M:%fZ', 'now'),
        synced_at = NULL
      """,
      params: [
        input.dateKey, input.activeSeconds, input.estimatedSteps,
        input.packetCount, input.lastUpdatedMs,
      ]
    )
  }

  func stepDaysRecent(limit: Int64) throws -> [StepDayRow] {
    try db.queryMap(
      """
      SELECT date_key, active_seconds, estimated_steps,
             packet_count, last_updated_ms,
             synced_at, created_at, updated_at
      FROM step_days
      ORDER BY date_key DESC
      LIMIT ?
      """,
      params: [limit]
    ) { row in
      StepDayRow(
        dateKey: row.string(0) ?? "",
        activeSeconds: row.double(1) ?? 0,
        estimatedSteps: row.double(2) ?? 0,
        packetCount: row.int(3) ?? 0,
        lastUpdatedMs: row.int(4) ?? 0,
        syncedAt: row.int(5),
        createdAt: row.string(6) ?? "",
        updatedAt: row.string(7) ?? ""
      )
    }
  }

  // MARK: - Cache counts (debug surface)

  struct CacheCounts {
    let hrSamples: Int64
    let hrvSamples: Int64
    let sensorSamples: Int64
    let stepDays: Int64
    let importedDailySummaries: Int64
    let sleepAudioEvents: Int64
  }

  func cacheCounts() throws -> CacheCounts {
    func count(_ table: String) throws -> Int64 {
      try db.queryFirst("SELECT COUNT(*) FROM \(table)") { row in
        row.int(0) ?? 0
      } ?? 0
    }
    let hrSamples = try count("hr_samples")
    let hrvSamples = try count("hrv_samples")
    let sensorSamples = try count("sensor_samples")
    let stepDays = try count("step_days")
    let importedDailySummaries = try count("imported_daily_summary")
    let sleepAudioEvents = try count("sleep_audio_events")
    return CacheCounts(
      hrSamples: hrSamples,
      hrvSamples: hrvSamples,
      sensorSamples: sensorSamples,
      stepDays: stepDays,
      importedDailySummaries: importedDailySummaries,
      sleepAudioEvents: sleepAudioEvents
    )
  }

  // MARK: - Sleep audio events

  struct SleepAudioEventInput {
    let eventID: String
    let capturedAtMs: Int64
    let durationMs: Int64
    let kind: String
    let detail: String?
  }

  @discardableResult
  func insertSleepAudioEvent(_ input: SleepAudioEventInput) throws -> Bool {
    let n = try db.executeStatement(
      """
      INSERT OR IGNORE INTO sleep_audio_events (
        event_id, captured_at_ms, duration_ms, kind, detail
      ) VALUES (?, ?, ?, ?, ?)
      """,
      params: [
        input.eventID, input.capturedAtMs, input.durationMs,
        input.kind, input.detail as Any?,
      ]
    )
    return n > 0
  }

  // MARK: - Raw IMU packets

  struct RawImuPacketInput {
    let packetID: String
    let capturedAtMs: Int64
    let payloadHex: String
    let axesMetaJSON: String
    let sequence: Int64
    let kPacketType: Int64
  }

  @discardableResult
  func insertRawImuPacket(_ input: RawImuPacketInput) throws -> Bool {
    let n = try db.executeStatement(
      """
      INSERT OR IGNORE INTO raw_imu_packets (
        packet_id, captured_at_ms, payload_hex,
        axes_meta_json, sequence, k_packet_type
      ) VALUES (?, ?, ?, ?, ?, ?)
      """,
      params: [
        input.packetID, input.capturedAtMs, input.payloadHex,
        input.axesMetaJSON, input.sequence, input.kPacketType,
      ]
    )
    return n > 0
  }
}
