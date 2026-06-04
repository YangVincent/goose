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

  @Published private(set) var active: ActiveSession?
  @Published private(set) var detectionLog: [DetectionSample] = []
  @Published private(set) var pastSessions: [PastSession] = []

  private var timer: Timer?
  private let evaluationInterval: TimeInterval = 60

  // Persistence: keep the last N sessions in UserDefaults so we can show
  // detection accuracy over time. Not a primary data store — that's the
  // sleep window detector + SQLite. This is just the comparison log.
  private let storageKey = "goose.swift.sleepSession.history.v1"

  init() {
    pastSessions = Self.loadPersisted(key: storageKey)
  }

  /// User taps "Start Sleep" — record start time, arm audio recorder if
  /// enabled, kick off the 1-min detection timer.
  func startSleep() {
    guard active == nil else { return }
    active = ActiveSession(startedAt: Date())
    detectionLog = []
    if SleepAudioRecorder.shared.isEnabled {
      SleepAudioRecorder.shared.arm()
    }
    scheduleEvaluator()
    // Record one sample immediately so the log starts populated.
    recordDetectionSample()
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
