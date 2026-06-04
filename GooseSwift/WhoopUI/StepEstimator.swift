import Foundation

/// Lightweight step / active-minute estimator that consumes the live
/// MovementPacketSample stream the BLE pipeline already publishes.
///
/// Honest caveat: this is an approximation. WHOOP's real step count comes
/// from a Kalman-filtered accelerometer pipeline running on-strap; we only
/// see one motion-intensity scalar per K10/K21 packet. The estimator turns
/// that into:
///
///   - "active seconds" per day (intensity ≥ 0.10 means moving)
///   - "estimated steps" per day (intensity-weighted, calibrated so steady
///     walking ≈ 100 steps/min, brisk walking ≈ 130, easy jog ≈ 160)
///
/// Persistence: today's totals upsert into the SQLite `step_days` table via
/// `swift_caches.upsert_step_day` on every ingest (debounced). History is
/// queried back from the same table on app launch.
@MainActor
final class StepEstimator: ObservableObject {
  static let shared = StepEstimator()

  struct DayTotals: Identifiable, Equatable {
    let dateKey: String
    var activeSeconds: Double
    var estimatedSteps: Double
    var packetCount: Int
    var lastUpdated: Date
    var id: String { dateKey }
  }

  @Published private(set) var todayTotals: DayTotals
  @Published private(set) var history: [DayTotals]

  /// Most recent K10/K21 movement packet we ingested — set whether or not it
  /// counted as motion, so the home card can surface "packets flowing" vs
  /// "everything silent". Reset on midnight rollover.
  @Published private(set) var lastPacketAt: Date?
  /// Highest motion intensity seen this minute, decayed each ingest. Useful
  /// as a "you ARE moving but threshold didn't trip" signal.
  @Published private(set) var recentPeakIntensity: Double = 0
  /// Count of all packets seen (whether moving or quiet) — diagnostic.
  @Published private(set) var packetsSeen: Int = 0

  private let bridge = GooseRustBridge()
  private var pendingPersist: DispatchWorkItem?
  private let persistQueue = DispatchQueue(label: "com.goose.swift.step-persist", qos: .utility)
  private static let persistDelay: TimeInterval = 2.0

  init() {
    // Do NOT delete legacy JSON. The file (if present) stays — SQLite is now
    // the source of truth, JSON is a recoverable copy.
    let dateKey = Self.dateKey(for: Date())
    self.todayTotals = DayTotals(
      dateKey: dateKey,
      activeSeconds: 0,
      estimatedSteps: 0,
      packetCount: 0,
      lastUpdated: Date()
    )
    self.history = []
    Task { await loadFromStore() }
  }

  func ingest(_ sample: MovementPacketSample) {
    let dateKey = Self.dateKey(for: sample.capturedAt)

    packetsSeen += 1
    lastPacketAt = sample.capturedAt
    recentPeakIntensity = max(recentPeakIntensity * 0.9, sample.motionIntensity)

    guard sample.parsedSampleCount > 0 else {
      schedulePersist()
      return
    }
    let packetDuration: Double = 1.0
    let stepsThisPacket = estimateSteps(intensity: sample.motionIntensity, duration: packetDuration)
    let activeSeconds = sample.isMoving ? packetDuration : 0

    if todayTotals.dateKey != dateKey {
      todayTotals = DayTotals(
        dateKey: dateKey,
        activeSeconds: activeSeconds,
        estimatedSteps: stepsThisPacket,
        packetCount: 1,
        lastUpdated: sample.capturedAt
      )
    } else {
      todayTotals.activeSeconds += activeSeconds
      todayTotals.estimatedSteps += stepsThisPacket
      todayTotals.packetCount += 1
      todayTotals.lastUpdated = sample.capturedAt
    }
    schedulePersist()
  }

  func refresh() async {
    await loadFromStore()
  }

  // MARK: - Estimation curve

  private func estimateSteps(intensity: Double, duration: Double) -> Double {
    guard intensity >= 0.10 else { return 0 }
    let stepsPerSecond: Double
    if intensity < 0.20 {
      stepsPerSecond = 1.0
    } else if intensity < 0.40 {
      let t = (intensity - 0.20) / 0.20
      stepsPerSecond = 1.0 + t * (1.67 - 1.0)
    } else if intensity < 0.65 {
      let t = (intensity - 0.40) / 0.25
      stepsPerSecond = 1.67 + t * (2.17 - 1.67)
    } else {
      stepsPerSecond = min(2.67, 2.17 + (intensity - 0.65) * 1.0)
    }
    return stepsPerSecond * duration
  }

  // MARK: - SQLite I/O

  private func loadFromStore() async {
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    let response: [String: Any]? = await Task.detached(priority: .utility) {
      try? bridge.request(
        method: "swift_caches.list_step_days",
        args: ["database_path": dbPath, "limit": 30]
      )
    }.value
    guard let response,
          let rows = response["days"] as? [[String: Any]] else { return }
    let isoParser = ISO8601DateFormatter()
    var loaded: [DayTotals] = []
    for row in rows {
      guard let dateKey = row["date_key"] as? String else { continue }
      let active = (row["active_seconds"] as? Double) ?? 0
      let steps = (row["estimated_steps"] as? Double) ?? 0
      let packets = (row["packet_count"] as? Int) ?? 0
      let lastMs = (row["last_updated_ms"] as? Int64) ?? Int64((row["last_updated_ms"] as? Int) ?? 0)
      _ = isoParser
      loaded.append(DayTotals(
        dateKey: dateKey,
        activeSeconds: active,
        estimatedSteps: steps,
        packetCount: packets,
        lastUpdated: Date(timeIntervalSince1970: TimeInterval(lastMs) / 1000.0)
      ))
    }
    history = loaded.sorted { $0.dateKey < $1.dateKey }
    let todayKey = Self.dateKey(for: Date())
    if let existing = loaded.first(where: { $0.dateKey == todayKey }) {
      todayTotals = existing
    }
  }

  private func schedulePersist() {
    pendingPersist?.cancel()
    let snapshot = todayTotals
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    let work = DispatchWorkItem {
      let _ = try? bridge.request(
        method: "swift_caches.upsert_step_day",
        args: [
          "database_path": dbPath,
          "date_key": snapshot.dateKey,
          "active_seconds": snapshot.activeSeconds,
          "estimated_steps": snapshot.estimatedSteps,
          "packet_count": snapshot.packetCount,
          "last_updated_ms": Int64((snapshot.lastUpdated.timeIntervalSince1970 * 1000).rounded()),
        ]
      )
    }
    pendingPersist = work
    persistQueue.asyncAfter(deadline: .now() + Self.persistDelay, execute: work)
  }

  // MARK: - Helpers

  nonisolated private static func dateKey(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  nonisolated private static func deleteLegacyJSONIfPresent() {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let url = base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("step-estimates.json")
    try? FileManager.default.removeItem(at: url)
  }
}
