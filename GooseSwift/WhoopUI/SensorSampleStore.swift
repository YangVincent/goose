import Foundation

/// One full snapshot of the strap's DSP sensor channels at a moment in time,
/// extracted from K12, K18, or K24 historical packets. Most fields are raw
/// ADC values that WHOOP normally uploads to their server for off-device
/// signal processing — keeping them on device means user owns the raw signal.
///
/// Field meanings:
/// - `bpm`: heart rate from K18 byte 14 or K12/K24 byte 14
/// - `rrIntervalsMS`: beat-to-beat intervals in milliseconds (HRV input)
/// - `ppgGreen`, `ppgRedIR`: raw photodiode readings (green = HR; red+IR pair = SpO₂ inputs)
/// - `spo2Red`, `spo2IR`: secondary SpO₂ ADC channels (K12/K24 only)
/// - `spo2Pct`: WHOOP's computed SpO₂ percentage when present (K18 byte 48)
/// - `skinTempRaw`: thermistor ADC; convert with calibration for °C
/// - `ambientLight`: room-light leak into the PPG sensor (signal-quality QC)
/// - `ledDrive1`, `ledDrive2`: how hard the LEDs are being driven (contact-quality QC)
/// - `signalQuality`: WHOOP's own per-sample confidence index
/// - `skinContact`: off-wrist detection bit (1 = on wrist, 0 = off)
/// - `accelGravity`: 3-axis gravity vector for wrist orientation
struct SensorSample: Codable, Identifiable {
  let id: String
  let source: String
  let capturedAt: Date

  let bpm: Int?
  let rrIntervalsMS: [Int]?

  let ppgGreen: Int?
  let ppgRedIR: Int?

  let spo2Red: Int?
  let spo2IR: Int?
  let spo2Pct: Int?

  let skinTempRaw: Int?
  let ambientLight: Int?
  let ledDrive1: Int?
  let ledDrive2: Int?
  let signalQuality: Int?
  let skinContact: Int?

  let accelGravity: [Double]?
}

private struct SensorSampleFile: Codable {
  let version: Int
  let samples: [SensorSample]
}

/// On-device persistence for K12/K24/K18 sensor samples. Same pattern as
/// HeartRateSeriesStore: in-memory ring buffer with debounced JSON writes
/// to Application Support/GooseSwift/sensor-samples.json. Capped at a
/// configurable max (default 250k samples ≈ 70 hours of wear at 1 Hz).
final class SensorSampleStore {
  static let shared = SensorSampleStore()

  private let stateLock = NSLock()
  private let writeQueue = DispatchQueue(label: "com.goose.swift.sensor-samples", qos: .utility)
  private let bridge = GooseRustBridge()
  private var samples: [SensorSample]
  /// Last 7 days kept hot in memory for fast time-range queries (off-wrist
  /// windows, sensor inspector snapshots). Older samples stay in SQLite
  /// until a future read pulls them.
  private static let hotWindow: TimeInterval = 7 * 24 * 60 * 60
  private static let maxSamples = 250_000

  init() {
    self.samples = SensorSampleStore.loadFromStore(bridge: GooseRustBridge())
    // Do NOT delete legacy JSON. Earlier code did, and it dropped a day's
    // worth of sensor samples. The file (if present) stays — SQLite is now
    // the source of truth, JSON is a recoverable copy.
  }

  func append(_ sample: SensorSample) {
    stateLock.lock()
    samples.append(sample)
    if samples.count > Self.maxSamples {
      samples.removeFirst(samples.count - Self.maxSamples)
    }
    stateLock.unlock()
    persistToStore([sample])
  }

  /// Bulk append in a single lock acquire — useful when one packet decodes
  /// into multiple sub-samples (e.g. K12/K24 with RR intervals).
  func appendAll(_ batch: [SensorSample]) {
    guard !batch.isEmpty else { return }
    stateLock.lock()
    samples.append(contentsOf: batch)
    if samples.count > Self.maxSamples {
      samples.removeFirst(samples.count - Self.maxSamples)
    }
    stateLock.unlock()
    persistToStore(batch)
  }

  var totalSampleCount: Int {
    stateLock.lock()
    defer { stateLock.unlock() }
    return samples.count
  }

  var mostRecentCapturedAt: Date? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return samples.last?.capturedAt
  }

  func snapshot(from start: Date, to end: Date) -> [SensorSample] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return samples
      .filter { $0.capturedAt >= start && $0.capturedAt < end }
      .sorted { $0.capturedAt < $1.capturedAt }
  }

  /// Time windows where the strap was reported off-wrist (skin_contact bit
  /// == 0). Returns a sorted list of (start, end) intervals — each interval
  /// is anchored at the off-wrist sample's capturedAt and extends `slackSeconds`
  /// on each side so brief blips between contact bits are smoothed away.
  ///
  /// Used by `GooseUploader` to drop bad HR samples and by the HRV analyzer
  /// to keep PPG-noise beats out of the rolling RMSSD window.
  func offWristWindows(slackSeconds: TimeInterval = 30) -> [(start: Date, end: Date)] {
    stateLock.lock()
    let local = samples
    stateLock.unlock()
    var raw: [(Date, Date)] = []
    for sample in local where sample.skinContact == 0 {
      raw.append((
        sample.capturedAt.addingTimeInterval(-slackSeconds),
        sample.capturedAt.addingTimeInterval(slackSeconds)
      ))
    }
    raw.sort { $0.0 < $1.0 }
    // Merge overlapping intervals.
    var merged: [(Date, Date)] = []
    for window in raw {
      if let last = merged.last, last.1 >= window.0 {
        merged[merged.count - 1] = (last.0, max(last.1, window.1))
      } else {
        merged.append(window)
      }
    }
    return merged
  }

  // MARK: - SQLite persistence

  private static func loadFromStore(bridge: GooseRustBridge) -> [SensorSample] {
    let dbPath = HealthDataStore.defaultDatabasePath()
    let end = Date()
    let start = end.addingTimeInterval(-Self.hotWindow)
    let response: [String: Any]
    do {
      response = try bridge.request(
        method: "swift_caches.list_sensor_samples",
        args: [
          "database_path": dbPath,
          "start_time_unix_ms": Int64((start.timeIntervalSince1970 * 1000).rounded()),
          "end_time_unix_ms": Int64((end.timeIntervalSince1970 * 1000).rounded()),
        ]
      )
    } catch {
      return []
    }
    let rows = response["samples"] as? [[String: Any]] ?? []
    return rows.compactMap { row -> SensorSample? in
      guard let id = row["sample_id"] as? String,
            let capturedAtMs = (row["captured_at_ms"] as? Int64)
              ?? (row["captured_at_ms"] as? Int).map(Int64.init) else { return nil }
      let source = (row["source"] as? String) ?? ""
      return SensorSample(
        id: id,
        source: source,
        capturedAt: Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1000.0),
        bpm: row["bpm"] as? Int,
        rrIntervalsMS: row["rr_intervals_ms"] as? [Int],
        ppgGreen: row["ppg_green"] as? Int,
        ppgRedIR: row["ppg_red_ir"] as? Int,
        spo2Red: row["spo2_red"] as? Int,
        spo2IR: row["spo2_ir"] as? Int,
        spo2Pct: row["spo2_pct"] as? Int,
        skinTempRaw: row["skin_temp_raw"] as? Int,
        ambientLight: row["ambient_light"] as? Int,
        ledDrive1: row["led_drive_1"] as? Int,
        ledDrive2: row["led_drive_2"] as? Int,
        signalQuality: row["signal_quality"] as? Int,
        skinContact: row["skin_contact"] as? Int,
        accelGravity: row["accel_gravity"] as? [Double]
      )
    }
  }

  private func persistToStore(_ batch: [SensorSample]) {
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    writeQueue.async {
      for sample in batch {
        var args: [String: Any] = [
          "database_path": dbPath,
          "sample_id": sample.id,
          "captured_at_ms": Int64((sample.capturedAt.timeIntervalSince1970 * 1000).rounded()),
          "source": sample.source,
        ]
        if let v = sample.bpm { args["bpm"] = v }
        if let v = sample.rrIntervalsMS { args["rr_intervals_ms"] = v }
        if let v = sample.ppgGreen { args["ppg_green"] = v }
        if let v = sample.ppgRedIR { args["ppg_red_ir"] = v }
        if let v = sample.spo2Red { args["spo2_red"] = v }
        if let v = sample.spo2IR { args["spo2_ir"] = v }
        if let v = sample.spo2Pct { args["spo2_pct"] = v }
        if let v = sample.skinTempRaw { args["skin_temp_raw"] = v }
        if let v = sample.ambientLight { args["ambient_light"] = v }
        if let v = sample.ledDrive1 { args["led_drive_1"] = v }
        if let v = sample.ledDrive2 { args["led_drive_2"] = v }
        if let v = sample.signalQuality { args["signal_quality"] = v }
        if let v = sample.skinContact { args["skin_contact"] = v }
        if let v = sample.accelGravity { args["accel_gravity"] = v }
        let _ = try? bridge.request(method: "swift_caches.append_sensor_sample", args: args)
      }
    }
  }

  private static func deleteLegacyJSONIfPresent() {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let url = base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("sensor-samples.json")
    try? FileManager.default.removeItem(at: url)
  }
}
