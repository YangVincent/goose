import Foundation

/// Thin Swift cache over the Rust-side `activity.list_sessions_with_metrics`
/// query. The on-device SQLite database (written by `finishActivityRecording`
/// via `rust.request("activity.create_session")` + metrics) is the single
/// source of truth — this class just shapes those rows into `CompletedWorkout`
/// values for SwiftUI views to observe.
///
/// Design note: every Swift store is moving to this pattern. Rust SQLite
/// holds the canonical bytes; Swift gets a `@Published` snapshot that it
/// refreshes when (a) a new session completes, (b) the user pulls-to-refresh,
/// or (c) the app comes back to the foreground. The previous JSON file at
/// `completed-workouts.json` is no longer written — if it exists from an
/// older build, the next refresh just ignores it.
struct CompletedWorkout: Identifiable, Equatable {
  let id: String  // matches the Rust session_id
  let activityRaw: String
  let activityTitle: String
  let startedAt: Date
  let endedAt: Date
  let elapsedSeconds: Double
  let averageHeartRate: Int?
  let maxHeartRate: Int?
  let zoneDurations: [Int: Double]
  let distanceMeters: Double
  let elevationGainMeters: Double
  let source: String
  let detectionMethod: String
  let syncStatus: String
  let routePoints: [RoutePoint]

  struct RoutePoint: Equatable {
    let latitude: Double
    let longitude: Double
    let altitude: Double
    let timestampMs: Int64
  }

  func zoneSeconds(_ zone: Int) -> Double {
    zoneDurations[zone] ?? 0
  }
}

@MainActor
final class CompletedWorkoutStore: ObservableObject {
  static let shared = CompletedWorkoutStore()

  @Published private(set) var workouts: [CompletedWorkout] = []
  @Published private(set) var lastRefreshedAt: Date?

  private let bridge = GooseRustBridge()
  /// Cap the lookback window so we don't drag tens of thousands of legacy
  /// sessions into memory once the SQLite has a long history. Will tighten
  /// later when we add retention/pagination.
  private let lookbackDays = 365

  init() {
    // Do NOT delete legacy JSON. The file (if present) stays — SQLite is the
    // source of truth, JSON is a recoverable copy.
    Task { await refresh() }
  }

  /// One-time cleanup: an earlier build wrote a Swift-side mirror at
  /// `completed-workouts.json`. Now that Rust SQLite is canonical, drop the
  /// stale file so it can't drift further.
  nonisolated private static func deleteLegacyJSONIfPresent() {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let legacy = base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("completed-workouts.json")
    try? FileManager.default.removeItem(at: legacy)
  }

  /// Re-query Rust SQLite and republish. Call after a session finishes, on
  /// foreground, and on pull-to-refresh.
  func refresh() async {
    let end = Date()
    let start = Calendar.current.date(
      byAdding: .day, value: -lookbackDays, to: end
    ) ?? end.addingTimeInterval(-365 * 86400)
    let bridge = self.bridge
    let startMs = Self.unixMilliseconds(start)
    let endMs = Self.unixMilliseconds(end)
    let dbPath = HealthDataStore.defaultDatabasePath()
    let result = await Task.detached(priority: .utility) {
      Self.query(bridge: bridge, dbPath: dbPath, startMs: startMs, endMs: endMs)
    }.value
    self.workouts = result
    self.lastRefreshedAt = Date()
  }

  func workouts(onISODate isoDate: String) -> [CompletedWorkout] {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return workouts.filter { formatter.string(from: $0.startedAt) == isoDate }
  }

  // MARK: - Query

  nonisolated private static func query(
    bridge: GooseRustBridge,
    dbPath: String,
    startMs: Int64,
    endMs: Int64
  ) -> [CompletedWorkout] {
    let report: [String: Any]
    do {
      report = try bridge.request(
        method: "activity.list_sessions_with_metrics",
        args: [
          "database_path": dbPath,
          "start_time_unix_ms": startMs,
          "end_time_unix_ms": endMs,
        ]
      )
    } catch {
      return []
    }
    let sessions = report["sessions"] as? [[String: Any]] ?? []
    let metricsBySession = report["metrics_by_session"] as? [String: [[String: Any]]] ?? [:]
    return sessions
      .compactMap { session -> CompletedWorkout? in
        guard let sessionID = session["session_id"] as? String,
              let startMs = int64Value(session["start_time_unix_ms"]),
              let endMs = int64Value(session["end_time_unix_ms"]) else { return nil }
        let activityRaw = session["activity_type"] as? String ?? "unknown"
        let customLabel = session["custom_label"] as? String
        let metrics = metricsBySession[sessionID] ?? []
        let byName = Dictionary(uniqueKeysWithValues: metrics.compactMap { metric -> (String, Double)? in
          guard let name = metric["metric_name"] as? String,
                let value = doubleValue(metric["value"]) else { return nil }
          return (name, value)
        })
        var zoneDurations: [Int: Double] = [:]
        for zone in 1...5 {
          zoneDurations[zone] = byName["hr_zone_\(zone)_duration"] ?? 0
        }
        let provJSON = session["provenance_json"] as? String ?? ""
        let routePoints = Self.parseRoutePoints(provJSON: provJSON)
        return CompletedWorkout(
          id: sessionID,
          activityRaw: activityRaw,
          activityTitle: customLabel ?? activityRaw.capitalized,
          startedAt: Date(timeIntervalSince1970: TimeInterval(startMs) / 1000.0),
          endedAt: Date(timeIntervalSince1970: TimeInterval(endMs) / 1000.0),
          elapsedSeconds: byName["duration"] ?? Double(endMs - startMs) / 1000.0,
          averageHeartRate: byName["average_hr"].map { Int($0.rounded()) },
          maxHeartRate: byName["max_hr"].map { Int($0.rounded()) },
          zoneDurations: zoneDurations,
          distanceMeters: byName["distance"] ?? 0,
          elevationGainMeters: byName["elevation_gain"] ?? 0,
          source: session["source"] as? String ?? "unknown",
          detectionMethod: session["detection_method"] as? String ?? "unknown",
          syncStatus: session["sync_status"] as? String ?? "unknown",
          routePoints: routePoints
        )
      }
      .sorted { $0.startedAt > $1.startedAt }
  }

  /// Parse `route_points` array out of the activity session's provenance
  /// JSON. Returns empty array if missing or malformed.
  nonisolated private static func parseRoutePoints(provJSON: String) -> [CompletedWorkout.RoutePoint] {
    guard !provJSON.isEmpty,
          let data = provJSON.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let raw = obj["route_points"] as? [[String: Any]] else {
      return []
    }
    return raw.compactMap { dict -> CompletedWorkout.RoutePoint? in
      guard let lat = dict["lat"] as? Double,
            let lon = dict["lon"] as? Double else { return nil }
      let alt = dict["alt"] as? Double ?? 0
      let ts = (dict["t_ms"] as? Int64) ?? (dict["t_ms"] as? Int).map(Int64.init) ?? 0
      return CompletedWorkout.RoutePoint(
        latitude: lat,
        longitude: lon,
        altitude: alt,
        timestampMs: ts
      )
    }
  }

  nonisolated private static func int64Value(_ raw: Any?) -> Int64? {
    if let v = raw as? Int64 { return v }
    if let v = raw as? Int { return Int64(v) }
    if let v = raw as? Double { return Int64(v) }
    if let v = raw as? String { return Int64(v) }
    return nil
  }

  nonisolated private static func doubleValue(_ raw: Any?) -> Double? {
    if let v = raw as? Double { return v }
    if let v = raw as? NSNumber { return v.doubleValue }
    if let v = raw as? Int { return Double(v) }
    if let v = raw as? String { return Double(v) }
    return nil
  }

  nonisolated private static func unixMilliseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }
}
