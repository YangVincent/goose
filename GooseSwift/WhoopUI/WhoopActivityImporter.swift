import Foundation

/// Imports historical `WhoopActivity` entries from the server into local
/// SQLite via `activity.create_session`. The phone becomes the source of
/// truth for ALL workouts (locally-recorded Goose sessions + WHOOP cloud
/// history), so date-strip dots, strain trends, and workout lists all
/// query a single store.
///
/// Idempotent: each WhoopActivity → stable session_id like
/// `whoop.cloud.<iso_date>`. INSERT OR IGNORE in Rust means re-running
/// the import doesn't duplicate.
@MainActor
enum WhoopActivityImporter {
  /// Walk the activities array, insert any missing into SQLite, then
  /// refresh `CompletedWorkoutStore` so the UI picks them up.
  /// Returns count of newly-imported rows.
  @discardableResult
  static func importHistorical(_ activities: [WhoopActivity]) async -> Int {
    let bridge = GooseRustBridge()
    let dbPath = HealthDataStore.defaultDatabasePath()
    var newCount = 0
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plainParser = ISO8601DateFormatter()

    let existingIds = Set(CompletedWorkoutStore.shared.workouts.map(\.id))

    for activity in activities {
      guard let strain = activity.strain, strain > 0 else { continue }
      guard let startDate = parser.date(from: activity.date)
              ?? plainParser.date(from: activity.date) else { continue }

      let sessionID = "whoop.cloud.\(activity.date.prefix(19))"
      if existingIds.contains(sessionID) { continue }

      // Estimate duration: WHOOP doesn't ship moving_time on this endpoint.
      // We use kJ + avg_hr to estimate ~kJ/min, then derive duration.
      // Default 60min if we can't estimate.
      let durationSeconds = estimateDurationSeconds(
        kJ: activity.kilojoule,
        avgHR: activity.avg_hr
      )
      let endDate = startDate.addingTimeInterval(durationSeconds)

      let startMs = Int64((startDate.timeIntervalSince1970 * 1000).rounded())
      let endMs = Int64((endDate.timeIntervalSince1970 * 1000).rounded())

      // Provenance carries the original WhoopActivity payload so the row
      // is round-trippable even after import.
      var provenance: [String: Any] = [
        "import_source": "whoop.cloud.api",
        "imported_at_unix_ms": Int64(Date().timeIntervalSince1970 * 1000),
        "whoop_strain_rating": strain,
      ]
      if let kj = activity.kilojoule { provenance["whoop_kilojoule"] = kj }
      if let maxHR = activity.max_hr { provenance["whoop_max_hr"] = maxHR }
      if let avgHR = activity.avg_hr { provenance["whoop_avg_hr"] = avgHR }
      if let dist = activity.distance { provenance["whoop_distance_m"] = dist }

      let activityRaw = mapActivityType(activity.type ?? activity.name ?? "activity")

      do {
        _ = try bridge.request(
          method: "activity.create_session",
          args: [
            "database_path": dbPath,
            "session_id": sessionID,
            "source": "whoop.cloud.api",
            "start_time_unix_ms": startMs,
            "end_time_unix_ms": endMs,
            "activity_type": activityRaw,
            "external_activity_type_name": activity.name ?? activity.type ?? "",
            "custom_label": (activity.name ?? "Activity").capitalized,
            "confidence": 1.0,
            "detection_method": "imported",
            "sync_status": "synced",
            "provenance": provenance,
          ]
        )

        // Attach metrics where we have them. Skip zone durations — the
        // server doesn't expose a per-zone breakdown, so we can't
        // reconstruct them. avg_hr / max_hr / distance / duration are
        // straightforward.
        var metrics: [[String: Any]] = []
        let durationStr = "\(sessionID).duration"
        metrics.append([
          "metric_id": durationStr,
          "activity_session_id": sessionID,
          "metric_name": "duration",
          "value": durationSeconds,
          "unit": "s",
          "start_time_unix_ms": startMs,
          "end_time_unix_ms": endMs,
          "quality_flags_json": "[]",
          "provenance_json": "{\"source\":\"whoop.cloud.api\"}",
        ])
        if let avgHR = activity.avg_hr {
          metrics.append(metricRow(
            sessionID: sessionID, name: "average_hr", value: Double(avgHR), unit: "bpm",
            startMs: startMs, endMs: endMs
          ))
        }
        if let maxHR = activity.max_hr {
          metrics.append(metricRow(
            sessionID: sessionID, name: "max_hr", value: Double(maxHR), unit: "bpm",
            startMs: startMs, endMs: endMs
          ))
        }
        if let dist = activity.distance, dist > 0 {
          metrics.append(metricRow(
            sessionID: sessionID, name: "distance", value: dist, unit: "m",
            startMs: startMs, endMs: endMs
          ))
        }

        if !metrics.isEmpty {
          _ = try bridge.request(
            method: "activity.attach_metrics",
            args: [
              "database_path": dbPath,
              "metrics": metrics,
            ]
          )
        }
        newCount += 1
      } catch {
        // Skip but don't crash — bad rows from server shouldn't break the
        // whole import.
        continue
      }
    }
    if newCount > 0 {
      await CompletedWorkoutStore.shared.refresh()
    }
    return newCount
  }

  // MARK: - Helpers

  /// Rough duration estimate. ~40 kJ/min for a Z3-ish workout is the
  /// historical average. Falls back to 60 minutes when inputs are missing.
  private static func estimateDurationSeconds(kJ: Double?, avgHR: Int?) -> Double {
    let defaultDuration: Double = 60 * 60
    guard let kJ = kJ, kJ > 0 else { return defaultDuration }
    guard let avgHR = avgHR, avgHR > 0 else {
      return min(max(kJ * 60 / 40, 60), 4 * 3600)
    }
    let rest = Double(UserProfile.restingHeartRate)
    let maxHR = Double(UserProfile.maxHeartRate)
    let hrr = max(0, min(1, (Double(avgHR) - rest) / max(maxHR - rest, 1)))
    let kJPerMin = max(8, 5 + 65 * hrr)
    let minutes = kJ / kJPerMin
    return min(max(minutes * 60, 60), 5 * 3600)
  }

  /// Map server-provided activity names to Rust's validated activity_type
  /// list (see ALLOWED_ACTIVITY_TYPES in store.rs). Anything we can't
  /// confidently map falls through to "unknown".
  private static func mapActivityType(_ raw: String) -> String {
    let lower = raw.lowercased()
    if lower.contains("run") { return "running" }
    if lower.contains("walk") { return "walking" }
    if lower.contains("hike") { return "hiking" }
    if lower.contains("cycl") || lower.contains("bike") || lower.contains("ride") { return "cycling" }
    if lower.contains("swim") { return "swimming" }
    if lower.contains("row") { return "rowing" }
    if lower.contains("weight") || lower.contains("powerlift") { return "weightlifting" }
    if lower.contains("strength") { return "strength" }
    if lower.contains("yoga") { return "yoga" }
    if lower.contains("pilates") { return "pilates" }
    if lower.contains("hiit") { return "hiit" }
    if lower.contains("box") { return "boxing" }
    if lower.contains("badminton") { return "unknown" }  // not in allowed list
    return "unknown"
  }

  private static func metricRow(
    sessionID: String, name: String, value: Double, unit: String,
    startMs: Int64, endMs: Int64
  ) -> [String: Any] {
    [
      "metric_id": "\(sessionID).\(name)",
      "activity_session_id": sessionID,
      "metric_name": name,
      "value": value,
      "unit": unit,
      "start_time_unix_ms": startMs,
      "end_time_unix_ms": endMs,
      "quality_flags_json": "[]",
      "provenance_json": "{\"source\":\"whoop.cloud.api\"}",
    ]
  }
}
