import Foundation

/// One-time backfill of historical sleep hypnograms from the aeonneo
/// server's `sleep_events.json`. WHOOP's internal API returns per-stage
/// segments (WAKE/REM/LIGHT/SWS) that we cannot reproduce locally for
/// nights before we wore the strap with the Goose app. We import them
/// once into the local SQLite `external_sleep_sessions` /
/// `external_sleep_stages` tables, then render them via the same
/// hypnogram code path as locally-computed sleep stages.
///
/// Going forward we compute hypnograms locally from raw HR+RR data;
/// this store only fills the gap for *past* nights.
@MainActor
final class WhoopImportedSleepStore: ObservableObject {
  static let shared = WhoopImportedSleepStore()

  @Published private(set) var importedNightCount: Int = 0
  @Published private(set) var lastImportError: String?
  @Published private(set) var sessionsByDateKey: [String: ImportedSession] = [:]

  private let bridge = GooseRustBridge()

  struct ImportedSegment: Identifiable {
    let id: String
    let startMs: Int64
    let endMs: Int64
    let stage: SleepStageEstimator.Stage

    var start: Date { Date(timeIntervalSince1970: TimeInterval(startMs) / 1000) }
    var end: Date { Date(timeIntervalSince1970: TimeInterval(endMs) / 1000) }
  }

  struct ImportedSession {
    let sleepID: String
    let dateKey: String  // local wake-day yyyy-MM-dd
    let onset: Date
    let wake: Date
    let segments: [ImportedSegment]
  }

  /// Build a SleepStageEstimator.Hypnogram from an imported session by
  /// chopping the timeline into 30s epochs and tagging each with the
  /// dominant stage in that epoch. Lets the existing rendering code work.
  func hypnogram(for date: Date) -> SleepStageEstimator.Hypnogram? {
    let key = Self.dateKey(for: date)
    guard let session = sessionsByDateKey[key], !session.segments.isEmpty else { return nil }
    return Self.epochify(session: session)
  }

  /// Read from local SQLite. Historical hypnograms are seeded by an
  /// external backfill script — no runtime cloud calls.
  func bootstrapIfNeeded(databasePath: String) async {
    await refreshFromLocal(databasePath: databasePath)
  }

  // MARK: - Refresh from local SQLite

  func refreshFromLocal(databasePath: String) async {
    let startMs: Int64 = 0
    let endMs = Int64(Date().timeIntervalSince1970 * 1000)
    do {
      let result = try await Task.detached(priority: .userInitiated) { [bridge] in
        try bridge.request(method: "sleep.list_external_history", args: [
          "database_path": databasePath,
          "start_time_unix_ms": startMs,
          "end_time_unix_ms": endMs,
        ])
      }.value
      guard let sessions = result["sessions"] as? [[String: Any]] else { return }
      var byKey: [String: ImportedSession] = [:]
      for raw in sessions {
        guard let parsed = Self.parseSession(raw) else { continue }
        byKey[parsed.dateKey] = parsed
      }
      self.sessionsByDateKey = byKey
      self.importedNightCount = byKey.count
    } catch {
      self.lastImportError = "list failed: \(error)"
    }
  }

  // MARK: - Parse list response

  private static func parseSession(_ raw: [String: Any]) -> ImportedSession? {
    guard let sleepID = raw["sleep_id"] as? String,
          let startMs = (raw["start_time_unix_ms"] as? Int64) ?? (raw["start_time_unix_ms"] as? Int).map(Int64.init),
          let endMs = (raw["end_time_unix_ms"] as? Int64) ?? (raw["end_time_unix_ms"] as? Int).map(Int64.init) else {
      return nil
    }
    let onset = Date(timeIntervalSince1970: TimeInterval(startMs) / 1000)
    let wake = Date(timeIntervalSince1970: TimeInterval(endMs) / 1000)
    let stagesRaw = raw["stages"] as? [[String: Any]] ?? []
    let segs: [ImportedSegment] = stagesRaw.compactMap { dict -> ImportedSegment? in
      guard let stageID = dict["stage_id"] as? String,
            let stageKind = dict["stage_kind"] as? String,
            let segStartMs = (dict["start_time_unix_ms"] as? Int64) ?? (dict["start_time_unix_ms"] as? Int).map(Int64.init),
            let segEndMs = (dict["end_time_unix_ms"] as? Int64) ?? (dict["end_time_unix_ms"] as? Int).map(Int64.init) else {
        return nil
      }
      let stage: SleepStageEstimator.Stage
      switch stageKind.lowercased() {
      case "awake", "wake": stage = .wake
      case "rem": stage = .rem
      // Rust canonicalises "light" → "core" on insert, so we get "core"
      // back on read. "asleep" is the Apple Health generic-asleep label.
      case "light", "core", "asleep": stage = .light
      case "deep", "sws": stage = .deep
      default: return nil
      }
      return ImportedSegment(id: stageID, startMs: segStartMs, endMs: segEndMs, stage: stage)
    }
    let key = Self.dateKey(for: wake)
    return ImportedSession(
      sleepID: sleepID,
      dateKey: key,
      onset: onset,
      wake: wake,
      segments: segs.sorted { $0.startMs < $1.startMs }
    )
  }

  static func dateKey(for date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  // MARK: - Segments → Hypnogram

  /// Chop into 30s epochs, tagging each with the segment that dominates
  /// it. Reuses `SleepStageEstimator.Hypnogram` so the same render path
  /// works whether the data came from local computation or this importer.
  private static func epochify(session: ImportedSession) -> SleepStageEstimator.Hypnogram {
    let epochSeconds: TimeInterval = SleepStageEstimator.epochSeconds
    let start = session.onset
    let end = session.wake
    var epochs: [SleepStageEstimator.Epoch] = []
    var stageMinutes: [SleepStageEstimator.Stage: Double] = [:]
    var cursor = start
    while cursor.addingTimeInterval(epochSeconds) <= end.addingTimeInterval(0.5) {
      let epochEnd = cursor.addingTimeInterval(epochSeconds)
      // Find the segment with the most overlap with [cursor, epochEnd].
      var bestStage: SleepStageEstimator.Stage = .light
      var bestOverlap: TimeInterval = 0
      for seg in session.segments {
        let overlap = max(
          0,
          min(epochEnd.timeIntervalSince1970, seg.end.timeIntervalSince1970)
          - max(cursor.timeIntervalSince1970, seg.start.timeIntervalSince1970)
        )
        if overlap > bestOverlap {
          bestOverlap = overlap
          bestStage = seg.stage
        }
      }
      if bestOverlap > 0 {
        epochs.append(SleepStageEstimator.Epoch(
          id: UUID(),
          start: cursor,
          end: epochEnd,
          stage: bestStage,
          meanHR: 0,
          hrStd: 0,
          rmssdMS: nil,
          skinTempRaw: nil
        ))
        stageMinutes[bestStage, default: 0] += 0.5
      }
      cursor = epochEnd
    }
    return SleepStageEstimator.Hypnogram(
      windowStart: start,
      windowEnd: end,
      epochs: epochs,
      stageMinutes: stageMinutes
    )
  }
}
