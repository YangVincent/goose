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

  private let url: URL
  private let stateLock = NSLock()
  private let writeQueue = DispatchQueue(label: "com.goose.swift.sensor-samples", qos: .utility)
  private var samples: [SensorSample]
  private var pendingWrite: DispatchWorkItem?
  private static let persistDelay: TimeInterval = 2.0
  private static let maxSamples = 250_000

  init(url: URL = SensorSampleStore.defaultURL()) {
    self.url = url
    self.samples = SensorSampleStore.loadSamples(from: url)
  }

  func append(_ sample: SensorSample) {
    stateLock.lock()
    samples.append(sample)
    if samples.count > Self.maxSamples {
      samples.removeFirst(samples.count - Self.maxSamples)
    }
    stateLock.unlock()
    schedulePersist()
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
    schedulePersist()
  }

  func snapshot(from start: Date, to end: Date) -> [SensorSample] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return samples
      .filter { $0.capturedAt >= start && $0.capturedAt < end }
      .sorted { $0.capturedAt < $1.capturedAt }
  }

  // MARK: - Persistence

  private func schedulePersist() {
    guard pendingWrite == nil else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.stateLock.lock()
      self.pendingWrite = nil
      let url = self.url
      let payload = SensorSampleFile(version: 1, samples: self.samples)
      self.stateLock.unlock()
      Self.persist(payload: payload, to: url)
    }
    pendingWrite = workItem
    writeQueue.asyncAfter(deadline: .now() + Self.persistDelay, execute: workItem)
  }

  private static func persist(payload: SensorSampleFile, to url: URL) {
    do {
      let directory = url.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let encoder = JSONEncoder()
      encoder.dateEncodingStrategy = .iso8601
      let data = try encoder.encode(payload)
      try data.write(to: url, options: .atomic)
    } catch {
      // Logging swallowed intentionally — sensor persistence is best-effort.
    }
  }

  private static func loadSamples(from url: URL) -> [SensorSample] {
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode(SensorSampleFile.self, from: data))?.samples ?? []
  }

  private static func defaultURL() -> URL {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let directory = base.appendingPathComponent("GooseSwift", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("sensor-samples.json")
  }
}
