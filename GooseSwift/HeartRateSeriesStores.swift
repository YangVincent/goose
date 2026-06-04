import Foundation
import UIKit

struct HeartRateSamplePoint: Codable, Identifiable, Equatable {
  let id: String
  let capturedAt: Date
  let bpm: Int
  let source: String

  init(bpm: Int, source: String, capturedAt: Date) {
    let milliseconds = Int64((capturedAt.timeIntervalSince1970 * 1000).rounded())
    self.id = "\(milliseconds).\(bpm).\(source)"
    self.capturedAt = capturedAt
    self.bpm = bpm
    self.source = source
  }
}

struct HeartRateHourlyRange: Identifiable, Equatable {
  let id: String
  let hourStart: Date
  let minBPM: Int
  let maxBPM: Int
  let averageBPM: Int
  let sampleCount: Int
}

struct HeartRateTimelineSnapshot: Equatable {
  let ranges: [HeartRateHourlyRange]
  let status: String
  let generatedAt: Date
}

struct HeartRateHourlyBucket {
  var minBPM = Int.max
  var maxBPM = Int.min
  var totalBPM = 0
  var sampleCount = 0

  mutating func append(_ bpm: Int) {
    minBPM = min(minBPM, bpm)
    maxBPM = max(maxBPM, bpm)
    totalBPM += bpm
    sampleCount += 1
  }
}

struct HeartRateRestingEstimate: Equatable {
  let bpm: Double
  let sampleCount: Int
  let updatedAt: Date?
  let source: String
}

/// Legacy on-disk shape — kept only because some debug exports reference it.
/// New code goes through the SQLite-backed HeartRateSeriesStore directly.
struct HeartRateSeriesFile: Codable {
  let version: Int
  let samples: [HeartRateSamplePoint]
}

final class HeartRateSeriesStore {
  static let shared = HeartRateSeriesStore()
  static let didUpdateNotification = Notification.Name("GooseHeartRateSeriesStoreDidUpdate")

  private static let retention: TimeInterval = 7 * 24 * 60 * 60
  private static let maxSamples = 100_000
  private static let updateNotificationInterval: TimeInterval = 2.0

  private let stateLock = NSLock()
  private let writeQueue = DispatchQueue(label: "com.goose.swift.heart-rate-series", qos: .utility)
  private let bridge = GooseRustBridge()
  private var samples: [HeartRateSamplePoint]
  private var lastNotificationAt = Date.distantPast

  init() {
    self.samples = Self.loadFromStore(bridge: GooseRustBridge())
    prune(relativeTo: Date())
    // DO NOT delete legacy JSON. Earlier code did, and it dropped HR data
    // that hadn't been imported into SQLite yet. The legacy importer below
    // pulls any remaining samples into SQLite without touching the file.
    Self.importLegacyJSONIntoStoreIfPresent()
    // No init-time decoded_frames recovery — that's a one-shot operation
    // exposed via a "Recover HR from decoded frames" button in More → Debug.
    // Going forward, `Store::insert_decoded_frame` mirrors HR into hr_samples
    // automatically (same transaction), so live capture stays in sync.
  }

  func append(bpm: Int, source: String, capturedAt: Date) -> Bool {
    guard (20...240).contains(bpm) else {
      return false
    }
    stateLock.lock()
    if let last = samples.last,
       last.bpm == bpm,
       last.source == source,
       abs(capturedAt.timeIntervalSince(last.capturedAt)) < 0.15 {
      stateLock.unlock()
      return false
    }

    let point = HeartRateSamplePoint(bpm: bpm, source: source, capturedAt: capturedAt)
    samples.append(point)
    prune(relativeTo: capturedAt)
    persistToStore(point)
    let shouldPostUpdate = markUpdateNotificationIfNeeded()
    stateLock.unlock()
    if shouldPostUpdate {
      NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }
    return true
  }

  func hourlyRanges(forDayContaining date: Date = Date(), calendar: Calendar = .current) -> [HeartRateHourlyRange] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return hourlyRangesLocked(forDayContaining: date, calendar: calendar)
  }

  func timelineSnapshot(forDayContaining date: Date = Date(), calendar: Calendar = .current) -> HeartRateTimelineSnapshot {
    stateLock.lock()
    defer { stateLock.unlock() }
    let ranges = hourlyRangesLocked(forDayContaining: date, calendar: calendar)
    return HeartRateTimelineSnapshot(
      ranges: ranges,
      status: Self.summary(from: ranges),
      generatedAt: Date()
    )
  }

  private func hourlyRangesLocked(forDayContaining date: Date = Date(), calendar: Calendar = .current) -> [HeartRateHourlyRange] {
    let dayStart = calendar.startOfDay(for: date)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
    let bucketCount = max(1, Int(ceil(dayEnd.timeIntervalSince(dayStart) / 3600)))
    var buckets = Array(repeating: HeartRateHourlyBucket(), count: bucketCount)

    for sample in samples where sample.capturedAt >= dayStart && sample.capturedAt < dayEnd {
      let hourOffset = Int(sample.capturedAt.timeIntervalSince(dayStart) / 3600)
      guard buckets.indices.contains(hourOffset) else {
        continue
      }
      buckets[hourOffset].append(sample.bpm)
    }

    return buckets.enumerated().compactMap { offset, bucket in
      guard bucket.sampleCount > 0 else {
        return nil
      }
      let hourStart = dayStart.addingTimeInterval(TimeInterval(offset * 3600))
      let average = Double(bucket.totalBPM) / Double(bucket.sampleCount)
      return HeartRateHourlyRange(
        id: "\(Int64((hourStart.timeIntervalSince1970 * 1000).rounded()))",
        hourStart: hourStart,
        minBPM: bucket.minBPM,
        maxBPM: bucket.maxBPM,
        averageBPM: Int(average.rounded()),
        sampleCount: bucket.sampleCount
      )
    }
  }

  func samples(forDayContaining date: Date = Date(), calendar: Calendar = .current) -> [HeartRateSamplePoint] {
    let dayStart = calendar.startOfDay(for: date)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
    return samples(from: dayStart, to: dayEnd)
  }

  func samples(from start: Date, to end: Date) -> [HeartRateSamplePoint] {
    stateLock.lock()
    defer { stateLock.unlock() }
    return samples
      .filter { $0.capturedAt >= start && $0.capturedAt < end }
      .sorted { $0.capturedAt < $1.capturedAt }
  }

  func summary(forDayContaining date: Date = Date(), calendar: Calendar = .current) -> String {
    let ranges = hourlyRanges(forDayContaining: date, calendar: calendar)
    return Self.summary(from: ranges)
  }

  static func summary(from ranges: [HeartRateHourlyRange]) -> String {
    let sampleCount = ranges.reduce(0) { $0 + $1.sampleCount }
    guard sampleCount > 0,
          let minBPM = ranges.map(\.minBPM).min(),
          let maxBPM = ranges.map(\.maxBPM).max()
    else {
      return "No HR samples stored today"
    }
    return "\(sampleCount) HR samples today | \(minBPM)-\(maxBPM) bpm | \(ranges.count) hourly buckets"
  }

  func restingEstimate(
    forDayContaining date: Date = Date(),
    calendar: Calendar = .current,
    minimumSamples: Int = 12
  ) -> HeartRateRestingEstimate? {
    stateLock.lock()
    defer { stateLock.unlock() }
    let dayStart = calendar.startOfDay(for: date)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
    let daySamples = samples.filter { $0.capturedAt >= dayStart && $0.capturedAt < dayEnd }
    let candidateSamples: [HeartRateSamplePoint]
    if daySamples.count >= minimumSamples {
      candidateSamples = daySamples
    } else {
      let groupedByDay = Dictionary(grouping: samples) { sample in
        calendar.startOfDay(for: sample.capturedAt)
      }
      candidateSamples = groupedByDay
        .sorted { $0.key > $1.key }
        .first { $0.value.count >= minimumSamples }?
        .value ?? []
    }

    guard candidateSamples.count >= minimumSamples else {
      return nil
    }

    let values = candidateSamples.map(\.bpm).sorted()
    let lowQuartileCount = max(1, values.count / 4)
    let lowQuartileValues = values.prefix(lowQuartileCount)
    let estimate = Double(lowQuartileValues.reduce(0, +)) / Double(lowQuartileValues.count)
    guard estimate.isFinite, (20...240).contains(Int(estimate.rounded())) else {
      return nil
    }

    return HeartRateRestingEstimate(
      bpm: estimate,
      sampleCount: candidateSamples.count,
      updatedAt: candidateSamples.last?.capturedAt,
      source: "ble.hr.sample_store.low_quartile"
    )
  }

  func latestSample() -> HeartRateSamplePoint? {
    stateLock.lock()
    defer { stateLock.unlock() }
    return samples.last
  }

  // MARK: - SQLite persistence

  /// Load the retention window from SQLite into the in-memory cache.
  /// Called once at init; reads after that serve from `self.samples`.
  private static func loadFromStore(bridge: GooseRustBridge) -> [HeartRateSamplePoint] {
    let dbPath = HealthDataStore.defaultDatabasePath()
    let end = Date()
    let start = end.addingTimeInterval(-Self.retention)
    let response: [String: Any]
    do {
      response = try bridge.request(
        method: "swift_caches.list_hr_samples",
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
    return rows.compactMap { row -> HeartRateSamplePoint? in
      guard let bpm = row["bpm"] as? Int,
            let capturedAtMs = (row["captured_at_ms"] as? Int64)
              ?? (row["captured_at_ms"] as? Int).map(Int64.init) else { return nil }
      let source = (row["source"] as? String) ?? ""
      let date = Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1000.0)
      return HeartRateSamplePoint(bpm: bpm, source: source, capturedAt: date)
    }
    .sorted { $0.capturedAt < $1.capturedAt }
  }

  private func persistToStore(_ sample: HeartRateSamplePoint) {
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    let id = sample.id
    let bpm = sample.bpm
    let source = sample.source
    let capturedAtMs = Int64((sample.capturedAt.timeIntervalSince1970 * 1000).rounded())
    writeQueue.async {
      let _ = try? bridge.request(
        method: "swift_caches.append_hr_sample",
        args: [
          "database_path": dbPath,
          "sample_id": id,
          "captured_at_ms": capturedAtMs,
          "bpm": bpm,
          "source": source,
        ]
      )
    }
  }

  /// One-shot recovery: ask Rust to walk decoded_frames for the given time
  /// window and import any HR values it finds into `hr_samples`. Exposed
  /// publicly so the More → Debug "Recover HR from decoded frames" button
  /// can call it and display the report.
  ///
  /// Going forward this should rarely be needed — `Store::insert_decoded_frame`
  /// now mirrors HR into hr_samples in the same transaction. The recovery
  /// exists for back-filling historical data captured before that side-effect
  /// landed.
  struct HRRecoveryReport {
    let framesScanned: Int
    let hrSamplesExtracted: Int
    let hrSamplesInserted: Int
  }

  static func recoverHRFromDecodedFrames(daysBack: Int = 30) -> HRRecoveryReport {
    let bridge = GooseRustBridge()
    let dbPath = HealthDataStore.defaultDatabasePath()
    let end = Date()
    let start = end.addingTimeInterval(-Double(daysBack) * 86400)
    do {
      let response = try bridge.request(
        method: "swift_caches.recover_hr_from_decoded_frames",
        args: [
          "database_path": dbPath,
          "start_time_unix_ms": Int64((start.timeIntervalSince1970 * 1000).rounded()),
          "end_time_unix_ms": Int64((end.timeIntervalSince1970 * 1000).rounded()),
        ]
      )
      let report = response["report"] as? [String: Any] ?? [:]
      return HRRecoveryReport(
        framesScanned: (report["frames_scanned"] as? Int) ?? 0,
        hrSamplesExtracted: (report["hr_samples_extracted"] as? Int) ?? 0,
        hrSamplesInserted: (report["hr_samples_inserted"] as? Int) ?? 0
      )
    } catch {
      return HRRecoveryReport(framesScanned: 0, hrSamplesExtracted: 0, hrSamplesInserted: 0)
    }
  }

  /// Import any HR samples still living in the legacy `heart-rate-samples.json`
  /// file into SQLite, *without* deleting the file. Idempotent — the SQLite
  /// `INSERT OR IGNORE` keeps duplicates from accumulating, and the file is
  /// kept on disk as a recoverable copy.
  private static func importLegacyJSONIntoStoreIfPresent() {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let url = base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("heart-rate-samples.json")
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacySamples: [HeartRateSamplePoint] = {
      if let file = try? decoder.decode(HeartRateSeriesFile.self, from: data) {
        return file.samples
      }
      return (try? decoder.decode([HeartRateSamplePoint].self, from: data)) ?? []
    }()
    guard !legacySamples.isEmpty else { return }
    let bridge = GooseRustBridge()
    let dbPath = HealthDataStore.defaultDatabasePath()
    for sample in legacySamples {
      _ = try? bridge.request(
        method: "swift_caches.append_hr_sample",
        args: [
          "database_path": dbPath,
          "sample_id": sample.id,
          "captured_at_ms": Int64((sample.capturedAt.timeIntervalSince1970 * 1000).rounded()),
          "bpm": sample.bpm,
          "source": sample.source,
        ]
      )
    }
  }

  private func prune(relativeTo date: Date) {
    let cutoff = date.addingTimeInterval(-Self.retention)
    if let firstKept = samples.firstIndex(where: { $0.capturedAt >= cutoff }), firstKept > 0 {
      samples.removeFirst(firstKept)
    } else if samples.allSatisfy({ $0.capturedAt < cutoff }) {
      samples.removeAll()
    }
    if samples.count > Self.maxSamples {
      samples.removeFirst(samples.count - Self.maxSamples)
    }
  }

  private func markUpdateNotificationIfNeeded() -> Bool {
    let now = Date()
    guard now.timeIntervalSince(lastNotificationAt) >= Self.updateNotificationInterval else {
      return false
    }
    lastNotificationAt = now
    return true
  }
}

struct HRVSamplePoint: Codable, Identifiable, Equatable {
  let id: String
  let capturedAt: Date
  let rmssdMS: Double
  let rrIntervalCount: Int
  let source: String

  init(rmssdMS: Double, rrIntervalCount: Int, source: String, capturedAt: Date) {
    let milliseconds = Int64((capturedAt.timeIntervalSince1970 * 1000).rounded())
    self.id = "\(milliseconds).\(Int((rmssdMS * 10).rounded())).\(rrIntervalCount).\(source)"
    self.capturedAt = capturedAt
    self.rmssdMS = rmssdMS
    self.rrIntervalCount = rrIntervalCount
    self.source = source
  }
}

struct HRVDailyEstimate: Equatable {
  let rmssdMS: Double
  let sampleCount: Int
  let rrIntervalCount: Int
  let updatedAt: Date?
  let source: String
}

struct HRVSeriesFile: Codable {
  let version: Int
  let samples: [HRVSamplePoint]
}

final class HRVSeriesStore {
  static let shared = HRVSeriesStore()
  static let didUpdateNotification = Notification.Name("GooseHRVSeriesStoreDidUpdate")

  private static let retention: TimeInterval = 14 * 24 * 60 * 60
  private static let maxSamples = 20_000
  private static let persistDelay: TimeInterval = 1.0
  private static let updateNotificationInterval: TimeInterval = 2.0

  private let stateLock = NSLock()
  private let writeQueue = DispatchQueue(label: "com.goose.swift.hrv-series", qos: .utility)
  private let bridge = GooseRustBridge()
  private var samples: [HRVSamplePoint]
  private var lastNotificationAt = Date.distantPast

  init() {
    self.samples = Self.loadFromStore(bridge: GooseRustBridge())
    if samples.isEmpty, let migratedSample = Self.loadPersistedLiveSample() {
      samples = [migratedSample]
      persistToStore(migratedSample)
    }
    prune(relativeTo: Date())
    Self.importLegacyJSONIntoStoreIfPresent()
  }

  func append(rmssdMS: Double, rrIntervalCount: Int, source: String, capturedAt: Date) -> Bool {
    guard rmssdMS.isFinite, (0...300).contains(rmssdMS), rrIntervalCount >= 2 else {
      return false
    }
    stateLock.lock()
    if let last = samples.last,
       abs(last.rmssdMS - rmssdMS) < 0.05,
       last.rrIntervalCount == rrIntervalCount,
       last.source == source,
       abs(capturedAt.timeIntervalSince(last.capturedAt)) < 0.5 {
      stateLock.unlock()
      return false
    }

    let point = HRVSamplePoint(rmssdMS: rmssdMS, rrIntervalCount: rrIntervalCount, source: source, capturedAt: capturedAt)
    samples.append(point)
    prune(relativeTo: capturedAt)
    persistToStore(point)
    let shouldPostUpdate = markUpdateNotificationIfNeeded()
    stateLock.unlock()
    if shouldPostUpdate {
      NotificationCenter.default.post(name: Self.didUpdateNotification, object: self)
    }
    return true
  }

  func dailyEstimate(
    forDayContaining date: Date = Date(),
    calendar: Calendar = .current,
    minimumSamples: Int = 1
  ) -> HRVDailyEstimate? {
    stateLock.lock()
    defer { stateLock.unlock() }
    let dayStart = calendar.startOfDay(for: date)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(24 * 60 * 60)
    let daySamples = samples.filter { $0.capturedAt >= dayStart && $0.capturedAt < dayEnd }
    let candidateSamples: [HRVSamplePoint]
    if daySamples.count >= minimumSamples {
      candidateSamples = daySamples
    } else {
      let groupedByDay = Dictionary(grouping: samples) { sample in
        calendar.startOfDay(for: sample.capturedAt)
      }
      candidateSamples = groupedByDay
        .sorted { $0.key > $1.key }
        .first { $0.value.count >= minimumSamples }?
        .value ?? []
    }

    guard candidateSamples.count >= minimumSamples else {
      return nil
    }

    let totalRR = candidateSamples.reduce(0) { $0 + $1.rrIntervalCount }
    guard totalRR > 0 else {
      return nil
    }
    let weightedRMSSD = candidateSamples.reduce(0.0) { $0 + ($1.rmssdMS * Double($1.rrIntervalCount)) } / Double(totalRR)
    guard weightedRMSSD.isFinite, (0...300).contains(weightedRMSSD) else {
      return nil
    }

    return HRVDailyEstimate(
      rmssdMS: weightedRMSSD,
      sampleCount: candidateSamples.count,
      rrIntervalCount: totalRR,
      updatedAt: candidateSamples.last?.capturedAt,
      source: "ble.hr.sample_store.rmssd_daily_average"
    )
  }

  // MARK: - SQLite persistence

  private static func loadFromStore(bridge: GooseRustBridge) -> [HRVSamplePoint] {
    let dbPath = HealthDataStore.defaultDatabasePath()
    let end = Date()
    let start = end.addingTimeInterval(-Self.retention)
    let response: [String: Any]
    do {
      response = try bridge.request(
        method: "swift_caches.list_hrv_samples",
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
    return rows.compactMap { row -> HRVSamplePoint? in
      guard let rmssd = row["rmssd_ms"] as? Double,
            let capturedAtMs = (row["captured_at_ms"] as? Int64)
              ?? (row["captured_at_ms"] as? Int).map(Int64.init) else { return nil }
      let rrCount = (row["rr_interval_count"] as? Int) ?? 0
      let source = (row["source"] as? String) ?? ""
      return HRVSamplePoint(
        rmssdMS: rmssd,
        rrIntervalCount: rrCount,
        source: source,
        capturedAt: Date(timeIntervalSince1970: TimeInterval(capturedAtMs) / 1000.0)
      )
    }
    .sorted { $0.capturedAt < $1.capturedAt }
  }

  private func persistToStore(_ sample: HRVSamplePoint) {
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    let id = sample.id
    let rmssd = sample.rmssdMS
    let rrCount = sample.rrIntervalCount
    let source = sample.source
    let capturedAtMs = Int64((sample.capturedAt.timeIntervalSince1970 * 1000).rounded())
    writeQueue.async {
      _ = try? bridge.request(
        method: "swift_caches.append_hrv_sample",
        args: [
          "database_path": dbPath,
          "sample_id": id,
          "captured_at_ms": capturedAtMs,
          "rmssd_ms": rmssd,
          "rr_interval_count": rrCount,
          "source": source,
        ]
      )
    }
  }

  /// Import any HRV samples in the legacy `hrv-samples.json` into SQLite,
  /// WITHOUT deleting the file. Safe to run on every launch — duplicates
  /// are blocked by `INSERT OR IGNORE` on the SQLite side.
  private static func importLegacyJSONIntoStoreIfPresent() {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let url = base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("hrv-samples.json")
    guard FileManager.default.fileExists(atPath: url.path),
          let data = try? Data(contentsOf: url) else { return }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy: [HRVSamplePoint] = {
      if let file = try? decoder.decode(HRVSeriesFile.self, from: data) {
        return file.samples
      }
      return (try? decoder.decode([HRVSamplePoint].self, from: data)) ?? []
    }()
    guard !legacy.isEmpty else { return }
    let bridge = GooseRustBridge()
    let dbPath = HealthDataStore.defaultDatabasePath()
    for sample in legacy {
      _ = try? bridge.request(
        method: "swift_caches.append_hrv_sample",
        args: [
          "database_path": dbPath,
          "sample_id": sample.id,
          "captured_at_ms": Int64((sample.capturedAt.timeIntervalSince1970 * 1000).rounded()),
          "rmssd_ms": sample.rmssdMS,
          "rr_interval_count": sample.rrIntervalCount,
          "source": sample.source,
        ]
      )
    }
  }

  private static func loadPersistedLiveSample() -> HRVSamplePoint? {
    let defaults = UserDefaults.standard
    guard defaults.object(forKey: "goose.swift.liveHRVRMSSD") != nil else {
      return nil
    }
    let rmssd = defaults.double(forKey: "goose.swift.liveHRVRMSSD")
    let rrIntervalCount = defaults.integer(forKey: "goose.swift.liveHRVRRIntervalCount")
    let source = defaults.string(forKey: "goose.swift.liveHRVSource") ?? "ble.hr.standard.average.migrated"
    let capturedAt = defaults.object(forKey: "goose.swift.liveHRVUpdatedAt") as? Date ?? Date()
    guard rmssd.isFinite, (0...300).contains(rmssd), rrIntervalCount >= 2 else {
      return nil
    }
    return HRVSamplePoint(
      rmssdMS: rmssd,
      rrIntervalCount: rrIntervalCount,
      source: "\(source).migrated_to_store",
      capturedAt: capturedAt
    )
  }

  private func prune(relativeTo date: Date) {
    let cutoff = date.addingTimeInterval(-Self.retention)
    if let firstKept = samples.firstIndex(where: { $0.capturedAt >= cutoff }), firstKept > 0 {
      samples.removeFirst(firstKept)
    } else if samples.allSatisfy({ $0.capturedAt < cutoff }) {
      samples.removeAll()
    }
    if samples.count > Self.maxSamples {
      samples.removeFirst(samples.count - Self.maxSamples)
    }
  }

  private func markUpdateNotificationIfNeeded() -> Bool {
    let now = Date()
    guard now.timeIntervalSince(lastNotificationAt) >= Self.updateNotificationInterval else {
      return false
    }
    lastNotificationAt = now
    return true
  }
}

final class HeartRateSamplePipeline {
  var onHeartRateTimelineSnapshot: ((HeartRateTimelineSnapshot) -> Void)?

  private let queue = DispatchQueue(label: "com.goose.swift.heart-rate-sample-pipeline", qos: .utility)
  private let heartRateStore: HeartRateSeriesStore
  private let hrvStore: HRVSeriesStore
  private let timelinePublishInterval: TimeInterval
  private var lastTimelinePublishedAt = Date.distantPast

  init(
    heartRateStore: HeartRateSeriesStore = .shared,
    hrvStore: HRVSeriesStore = .shared,
    timelinePublishInterval: TimeInterval = 1
  ) {
    self.heartRateStore = heartRateStore
    self.hrvStore = hrvStore
    self.timelinePublishInterval = timelinePublishInterval
  }

  func refreshHeartRateTimeline(for date: Date = Date()) {
    queue.async { [weak self] in
      self?.publishHeartRateTimeline(for: date, force: true)
    }
  }

  func recordHeartRateSample(bpm: Int, source: String, capturedAt: Date) {
    queue.async { [weak self] in
      guard let self,
            self.heartRateStore.append(bpm: bpm, source: source, capturedAt: capturedAt) else {
        return
      }

      let now = Date()
      guard now.timeIntervalSince(self.lastTimelinePublishedAt) >= self.timelinePublishInterval else {
        return
      }
      self.publishHeartRateTimeline(for: now, force: true)
    }
  }

  func recordHRVSample(rmssdMS: Double, rrIntervalCount: Int, source: String, capturedAt: Date) {
    queue.async { [weak self] in
      _ = self?.hrvStore.append(rmssdMS: rmssdMS, rrIntervalCount: rrIntervalCount, source: source, capturedAt: capturedAt)
    }
  }

  private func publishHeartRateTimeline(for date: Date, force: Bool) {
    let now = Date()
    if !force, now.timeIntervalSince(lastTimelinePublishedAt) < timelinePublishInterval {
      return
    }
    let snapshot = heartRateStore.timelineSnapshot(forDayContaining: date)
    lastTimelinePublishedAt = now
    onHeartRateTimelineSnapshot?(snapshot)
  }
}
