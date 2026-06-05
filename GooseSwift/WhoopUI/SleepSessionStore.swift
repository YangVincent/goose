import Foundation
import SwiftUI

/// Explicit "I'm going to sleep" / "I'm awake" session, started and
/// ended by the user. Ground truth for the sleep window, no heuristics.
///
/// While the session is active, we run a parallel auto-detection
/// evaluator once per minute (looking at last-30-min HR vs resting) and
/// log what it WOULD have said. Comparing that log to your actual
/// start/end is how we'll tune the heuristic into a real auto-arm.
@MainActor
final class SleepSessionStore: ObservableObject {
  static let shared = SleepSessionStore()

  struct ActiveSession: Equatable {
    let startedAt: Date
  }

  struct DetectionSample: Identifiable, Equatable {
    let id: UUID = UUID()
    let time: Date
    let meanHR: Double?
    let restingBaseline: Double
    let asleepThreshold: Double
    let awakeThreshold: Double
    /// What the heuristic would output at this moment.
    let inferredState: InferredState

    enum InferredState: String { case unknown, asleep, awake }
  }

  struct PastSession: Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let detectionLog: [DetectionSample]

    var durationSeconds: Double { endedAt.timeIntervalSince(startedAt) }
  }

  @Published private(set) var active: ActiveSession? {
    didSet { Self.persistActive(active, key: activeStorageKey) }
  }
  @Published private(set) var detectionLog: [DetectionSample] = []
  @Published private(set) var pastSessions: [PastSession] = []

  private var timer: Timer?
  private let evaluationInterval: TimeInterval = 60

  // Persistence: keep the last N sessions in UserDefaults so we can show
  // detection accuracy over time. Not a primary data store — that's the
  // sleep window detector + SQLite. This is just the comparison log.
  private let storageKey = "goose.swift.sleepSession.history.v1"
  // Persist the live "Start Sleep" tap separately so it survives process
  // death (iOS will reclaim background apps overnight; without this an
  // 8-hour session disappears the moment the OS kills us).
  private let activeStorageKey = "goose.swift.sleepSession.active.v1"
  /// How long we'll trust a restored active session. If the persisted
  /// startedAt is older than this, treat it as stale (user forgot to tap
  /// End or the app crashed days ago) and discard.
  private let maxActiveAge: TimeInterval = 16 * 3600

  /// Posted whenever a sleep session begins (manual tap or cold-launch
  /// restore). Carried in `userInfo["startedAt"]`. Observed by
  /// `GooseAppModel` so it can acquire HIGH_FREQ_SYNC for the duration.
  static let sessionStartedNotification = Notification.Name("goose.sleep.session.started")
  /// Posted on End Sleep, or when a stale restore is discarded.
  static let sessionEndedNotification = Notification.Name("goose.sleep.session.ended")
  /// Posted after sleep.compute_reading returns; userInfo carries the
  /// session id and the raw bridge response. SleepDetailView observes
  /// this to refresh the per-session sleep card.
  static let sleepReadingComputedNotification = Notification.Name("goose.sleep.reading.computed")

  init() {
    pastSessions = Self.loadPersisted(key: storageKey)
    if let restored = Self.loadActive(key: activeStorageKey),
       Date().timeIntervalSince(restored.startedAt) < maxActiveAge {
      active = restored
      // Re-arm audio and the per-minute evaluator on cold launch so the
      // session keeps working after the OS killed and re-spawned us.
      SleepAudioRecorder.shared.arm()
      scheduleEvaluator()
      recordDetectionSample()
      NotificationCenter.default.post(
        name: Self.sessionStartedNotification,
        object: nil,
        userInfo: ["startedAt": restored.startedAt, "restored": true]
      )
    } else if Self.loadActive(key: activeStorageKey) != nil {
      // Stale ghost from a previous run -- discard.
      Self.persistActive(nil, key: activeStorageKey)
    }
  }

  /// One-shot backfill for the 2026-06-04 sleep window (00:40 → 08:35
  /// EDT). The auto-detect bug fixed in `f38f577` set `active = nil`
  /// without going through `endSleep()`, so that night never reached
  /// the persistence path. The reading + recovery were computed from
  /// SQLite-side HR/HRV data and verified out-of-band (82.7 / 71.6), so
  /// the data exists — only the PastSession metadata is missing.
  ///
  /// Idempotent: skip if a session already lives in the same window.
  /// detectionLog is rebuilt from HR samples so the SLEEP SESSION card
  /// surfaces the real wake spells. Safe to call from `.onAppear` or
  /// `runPacketScores()` — first caller writes, the rest no-op.
  func backfillKnownNightIfMissing() {
    let start = Date(timeIntervalSince1970: 1_780_548_000)
    let end = Date(timeIntervalSince1970: 1_780_576_500)
    if pastSessions.contains(where: { abs($0.startedAt.timeIntervalSince(start)) < 60 }) {
      return
    }
    let resting = HeartRateSeriesStore.shared.restingEstimate()?.bpm
                  ?? Double(UserProfile.restingHeartRate)
    let asleep = resting + 5
    let awake = resting + 12
    let samples = HeartRateSeriesStore.shared.samples(from: start, to: end)
    let stride: TimeInterval = 60
    var log: [DetectionSample] = []
    var cursor = start
    while cursor <= end {
      let cutoff = cursor.addingTimeInterval(-30 * 60)
      let recent = samples.filter { $0.capturedAt >= cutoff && $0.capturedAt <= cursor }
      let meanHR: Double?
      if recent.count >= 5 {
        var total: Int = 0
        for sample in recent { total += sample.bpm }
        meanHR = Double(total) / Double(recent.count)
      } else {
        meanHR = nil
      }
      let state: DetectionSample.InferredState
      if let m = meanHR {
        if m <= asleep { state = .asleep }
        else if m >= awake { state = .awake }
        else { state = .unknown }
      } else {
        state = .unknown
      }
      log.append(DetectionSample(
        time: cursor, meanHR: meanHR, restingBaseline: resting,
        asleepThreshold: asleep, awakeThreshold: awake, inferredState: state
      ))
      cursor = cursor.addingTimeInterval(stride)
    }
    let session = PastSession(id: UUID(), startedAt: start, endedAt: end, detectionLog: log)
    pastSessions.insert(session, at: 0)
    if pastSessions.count > 30 { pastSessions = Array(pastSessions.prefix(30)) }
    Self.persist(pastSessions, key: storageKey)
  }

  /// User taps "Start Sleep" — record start time, arm the audio recorder,
  /// and kick off the 1-min detection timer. Audio is on for the full
  /// session by design; the range between startedAt and endedAt is what
  /// downstream sleep analysis runs against.
  func startSleep() {
    guard active == nil else { return }
    let session = ActiveSession(startedAt: Date())
    active = session
    detectionLog = []
    SleepAudioRecorder.shared.arm()
    scheduleEvaluator()
    // Record one sample immediately so the log starts populated.
    recordDetectionSample()
    NotificationCenter.default.post(
      name: Self.sessionStartedNotification,
      object: nil,
      userInfo: ["startedAt": session.startedAt, "restored": false]
    )
  }

  /// User taps "End Sleep" — store the session + log, disarm recorder,
  /// stop the evaluator.
  func endSleep() {
    guard let session = active else { return }
    let now = Date()
    timer?.invalidate()
    timer = nil
    if case .armed = SleepAudioRecorder.shared.state {
      SleepAudioRecorder.shared.disarm()
    } else if case .recordingEvent = SleepAudioRecorder.shared.state {
      SleepAudioRecorder.shared.disarm()
    }
    let past = PastSession(
      id: UUID(),
      startedAt: session.startedAt,
      endedAt: now,
      detectionLog: detectionLog
    )
    pastSessions.insert(past, at: 0)
    if pastSessions.count > 30 { pastSessions = Array(pastSessions.prefix(30)) }
    Self.persist(pastSessions, key: storageKey)
    active = nil
    NotificationCenter.default.post(
      name: Self.sessionEndedNotification,
      object: nil,
      userInfo: ["endedAt": now]
    )
    computeAndStoreReading(for: past)
  }

  /// Kick off the Rust-side sleep_reading computation for the just-ended
  /// session. Runs off the main thread; result is persisted into the
  /// sleep_readings SQLite table by the bridge and observable via the
  /// `sleepReadingComputedNotification` (carries the session id).
  private func computeAndStoreReading(for past: PastSession) {
    let bridge = GooseRustBridge()
    let dbPath = HealthDataStore.defaultDatabasePath()
    let sessionID = past.id.uuidString
    let startMs = Int64((past.startedAt.timeIntervalSince1970 * 1000).rounded())
    let endMs = Int64((past.endedAt.timeIntervalSince1970 * 1000).rounded())
    Task.detached(priority: .userInitiated) {
      let result = try? bridge.request(
        method: "sleep.compute_reading",
        args: [
          "database_path": dbPath,
          "session_id": sessionID,
          "start_time_unix_ms": startMs,
          "end_time_unix_ms": endMs,
        ]
      )
      await MainActor.run {
        NotificationCenter.default.post(
          name: Self.sleepReadingComputedNotification,
          object: nil,
          userInfo: ["sessionId": sessionID, "reading": result as Any]
        )
      }
    }
  }

  // MARK: - Evaluator

  private func scheduleEvaluator() {
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: evaluationInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.recordDetectionSample() }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
  }

  /// Snapshot what the heuristic would say RIGHT NOW. Appended to the
  /// log so we can compare it to the user's actual start/end.
  private func recordDetectionSample() {
    let now = Date()
    let resting = HeartRateSeriesStore.shared.restingEstimate()?.bpm
                  ?? Double(UserProfile.restingHeartRate)
    let samples = HeartRateSeriesStore.shared.samples(
      from: now.addingTimeInterval(-30 * 60),
      to: now
    )
    let meanHR: Double?
    if samples.count >= 5 {
      meanHR = Double(samples.map(\.bpm).reduce(0, +)) / Double(samples.count)
    } else {
      meanHR = nil
    }
    let asleepThreshold = resting + 5
    let awakeThreshold = resting + 12
    let inferred: DetectionSample.InferredState
    if let m = meanHR {
      if m <= asleepThreshold { inferred = .asleep }
      else if m >= awakeThreshold { inferred = .awake }
      else { inferred = .unknown }  // hysteresis band
    } else {
      inferred = .unknown
    }
    let sample = DetectionSample(
      time: now,
      meanHR: meanHR,
      restingBaseline: resting,
      asleepThreshold: asleepThreshold,
      awakeThreshold: awakeThreshold,
      inferredState: inferred
    )
    detectionLog.append(sample)
    // Cap to ~12h of 1-per-min samples.
    if detectionLog.count > 720 {
      detectionLog = Array(detectionLog.suffix(720))
    }
  }

  // MARK: - Persistence (UserDefaults-backed for now)

  private static func loadPersisted(key: String) -> [PastSession] {
    guard let data = UserDefaults.standard.data(forKey: key),
          let decoded = try? JSONDecoder().decode([PersistedPastSession].self, from: data) else { return [] }
    return decoded.map { $0.toPastSession() }
  }

  private static func persist(_ sessions: [PastSession], key: String) {
    let encodable = sessions.map(PersistedPastSession.init)
    if let data = try? JSONEncoder().encode(encodable) {
      UserDefaults.standard.set(data, forKey: key)
    }
  }

  private static func loadActive(key: String) -> ActiveSession? {
    guard let data = UserDefaults.standard.data(forKey: key),
          let decoded = try? JSONDecoder().decode(PersistedActiveSession.self, from: data)
    else { return nil }
    return ActiveSession(startedAt: decoded.startedAt)
  }

  private static func persistActive(_ session: ActiveSession?, key: String) {
    if let session {
      let encodable = PersistedActiveSession(startedAt: session.startedAt)
      if let data = try? JSONEncoder().encode(encodable) {
        UserDefaults.standard.set(data, forKey: key)
      }
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}

private struct PersistedActiveSession: Codable {
  let startedAt: Date
}

/// Codable mirror of PastSession for UserDefaults persistence. PastSession
/// uses UUID + Date which are Codable already, so this is straightforward.
private struct PersistedPastSession: Codable {
  let id: UUID
  let startedAt: Date
  let endedAt: Date
  let detectionLog: [PersistedDetectionSample]

  init(_ s: SleepSessionStore.PastSession) {
    id = s.id
    startedAt = s.startedAt
    endedAt = s.endedAt
    detectionLog = s.detectionLog.map(PersistedDetectionSample.init)
  }

  func toPastSession() -> SleepSessionStore.PastSession {
    SleepSessionStore.PastSession(
      id: id,
      startedAt: startedAt,
      endedAt: endedAt,
      detectionLog: detectionLog.map { $0.toDetectionSample() }
    )
  }
}

private struct PersistedDetectionSample: Codable {
  let time: Date
  let meanHR: Double?
  let restingBaseline: Double
  let asleepThreshold: Double
  let awakeThreshold: Double
  let inferredState: String

  init(_ s: SleepSessionStore.DetectionSample) {
    time = s.time
    meanHR = s.meanHR
    restingBaseline = s.restingBaseline
    asleepThreshold = s.asleepThreshold
    awakeThreshold = s.awakeThreshold
    inferredState = s.inferredState.rawValue
  }

  func toDetectionSample() -> SleepSessionStore.DetectionSample {
    SleepSessionStore.DetectionSample(
      time: time,
      meanHR: meanHR,
      restingBaseline: restingBaseline,
      asleepThreshold: asleepThreshold,
      awakeThreshold: awakeThreshold,
      inferredState: SleepSessionStore.DetectionSample.InferredState(rawValue: inferredState) ?? .unknown
    )
  }
}
