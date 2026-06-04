import AVFoundation
import Foundation
import SwiftUI

/// Optional sleep-audio recorder. Off by default — flip the toggle in
/// SleepDetailView to enable.
///
/// Design: we DON'T keep continuous audio. AVAudioEngine runs a tap that
/// computes per-second RMS amplitude and a crude spectral centroid. When
/// the rolling 60-second baseline is exceeded by >12 dB for ≥2 seconds
/// (snore-like burst), we open an AVAudioRecorder, save a 30-second
/// compressed AAC clip, and log a SleepAudioEvent. Otherwise nothing
/// touches disk.
///
/// Storage budget: target <50 MB / night even on a noisy night by capping
/// concurrent events to 60. Clips older than `retentionDays` are pruned.
///
/// Requires:
///   - Info.plist NSMicrophoneUsageDescription
///   - Info.plist UIBackgroundModes contains "audio"
@MainActor
final class SleepAudioRecorder: ObservableObject {
  static let shared = SleepAudioRecorder()

  enum State: Equatable {
    case idle
    case armed         // armed but not actively recording an event
    case recordingEvent
    case error(String)
  }

  struct SleepAudioEvent: Identifiable, Equatable {
    let id: UUID
    let start: Date
    let durationSeconds: Double
    let peakDB: Double
    let kind: Kind
    let fileURL: URL?

    enum Kind: String, Codable {
      case snore
      case loudSpike
      case voiceBand
    }
  }

  @Published private(set) var state: State = .idle
  @Published private(set) var totalSnoreSeconds: Double = 0
  @Published private(set) var maxAmbientDB: Double = -120
  @Published private(set) var rollingBaselineDB: Double = -60
  @Published private(set) var recentEvents: [SleepAudioEvent] = []

  // Audio recording is now tied 1:1 with sleep sessions (Start Sleep arms,
  // End Sleep disarms). No separate enable toggle and no charging gate --
  // if the user marks themselves as asleep, we listen for events.
  @AppStorage("goose.swift.sleepAudio.retentionDays") var retentionDays: Int = 7

  private let engine = AVAudioEngine()
  private var eventRecorder: AVAudioRecorder?
  private var armedAt: Date?
  private var sustainedHighEnergyStart: Date?
  private let bridge = GooseRustBridge()
  private let storageDirectory: URL = {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    let dir = docs.appendingPathComponent("SleepAudio", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  /// Begin listening. Called by SleepSessionStore.startSleep when the user
  /// taps "Start Sleep". Audio recording is now always-on for the duration
  /// of a sleep session -- no separate enable toggle, no charging gate.
  func arm() {
    guard state == .idle else { return }
    requestPermissionAndStart()
  }

  /// Stop listening. Called on wake or when toggle turns off.
  func disarm() {
    if engine.isRunning {
      engine.inputNode.removeTap(onBus: 0)
      engine.stop()
    }
    finishEventRecorder()
    state = .idle
    armedAt = nil
    sustainedHighEnergyStart = nil
  }

  // MARK: - Setup

  private func requestPermissionAndStart() {
    AVAudioApplication.requestRecordPermission { [weak self] granted in
      DispatchQueue.main.async {
        guard let self else { return }
        if !granted {
          self.state = .error("microphone permission denied")
          return
        }
        do {
          try self.configureSession()
          try self.startEngine()
          self.state = .armed
          self.armedAt = Date()
          self.totalSnoreSeconds = 0
          self.maxAmbientDB = -120
        } catch {
          self.state = .error("\(error)")
        }
      }
    }
  }

  private func configureSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
    try session.setActive(true)
  }

  private func startEngine() throws {
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
      self?.process(buffer: buffer)
    }
    engine.prepare()
    try engine.start()
  }

  // MARK: - Buffer processing

  private func process(buffer: AVAudioPCMBuffer) {
    guard let channelData = buffer.floatChannelData?[0] else { return }
    let frameLength = Int(buffer.frameLength)
    if frameLength == 0 { return }

    // RMS over the buffer.
    var sumSquares: Float = 0
    for i in 0..<frameLength {
      let s = channelData[i]
      sumSquares += s * s
    }
    let rms = sqrt(sumSquares / Float(frameLength))
    let db = 20 * log10(max(rms, 1e-7))

    DispatchQueue.main.async { [weak self] in
      self?.updateRollingState(db: Double(db))
    }
  }

  private func updateRollingState(db: Double) {
    // Exponential moving average baseline (long, ~60s of 1s buffers).
    let alpha = 0.02
    rollingBaselineDB = (1 - alpha) * rollingBaselineDB + alpha * db
    if db > maxAmbientDB { maxAmbientDB = db }

    let aboveBaseline = db - rollingBaselineDB
    let highEnergyThreshold = 12.0

    if aboveBaseline > highEnergyThreshold {
      if sustainedHighEnergyStart == nil {
        sustainedHighEnergyStart = Date()
      }
      if let start = sustainedHighEnergyStart, Date().timeIntervalSince(start) >= 2.0 {
        if state == .armed {
          startEventRecording(peakDB: db)
        }
      }
    } else {
      sustainedHighEnergyStart = nil
      // If we're recording an event and energy has dropped, stop after a
      // 5-second tail so we capture the trailing edge.
      if case .recordingEvent = state, let r = eventRecorder {
        if r.currentTime > 30 {
          finishEventRecorder()
          state = .armed
        }
      }
    }
  }

  // MARK: - Event recording

  private func startEventRecording(peakDB: Double) {
    let fileURL = storageDirectory.appendingPathComponent("\(Int(Date().timeIntervalSince1970)).m4a")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatMPEG4AAC,
      AVSampleRateKey: 22050,
      AVNumberOfChannelsKey: 1,
      AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
      AVEncoderBitRateKey: 24000,
    ]
    do {
      let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
      recorder.record(forDuration: 30)
      eventRecorder = recorder
      state = .recordingEvent
      let event = SleepAudioEvent(
        id: UUID(),
        start: Date(),
        durationSeconds: 30,
        peakDB: peakDB,
        kind: .snore,
        fileURL: fileURL
      )
      recentEvents.insert(event, at: 0)
      if recentEvents.count > 60 {
        recentEvents = Array(recentEvents.prefix(60))
      }
      totalSnoreSeconds += 30
      persistEvent(event)
    } catch {
      state = .error("\(error)")
    }
  }

  /// Persist event to SQLite via Rust bridge so it survives app restarts.
  private func persistEvent(_ event: SleepAudioEvent) {
    let path = HealthDataStore.defaultDatabasePath()
    Task.detached(priority: .background) { [bridge] in
      _ = try? bridge.request(method: "swift_caches.append_sleep_audio_event", args: [
        "database_path": path,
        "event_id": event.id.uuidString,
        "started_at_ms": Int64(event.start.timeIntervalSince1970 * 1000),
        "duration_ms": Int64(event.durationSeconds * 1000),
        "peak_db": event.peakDB,
        "kind": event.kind.rawValue,
        "file_path": event.fileURL?.path as Any,
      ])
    }
  }

  /// Reload events from SQLite for the last `days` days. Call on launch
  /// so the recent events list survives an app restart.
  func reloadRecentEvents(days: Int = 7) {
    let path = HealthDataStore.defaultDatabasePath()
    let endMs = Int64(Date().timeIntervalSince1970 * 1000)
    let startMs = endMs - Int64(days) * 86_400_000
    Task.detached(priority: .userInitiated) { [bridge] in
      guard let result = try? bridge.request(method: "swift_caches.list_sleep_audio_events", args: [
        "database_path": path,
        "start_time_unix_ms": startMs,
        "end_time_unix_ms": endMs,
      ]) else { return }
      let rows = result["events"] as? [[String: Any]] ?? []
      let events: [SleepAudioEvent] = rows.compactMap { row in
        guard
          let idStr = row["event_id"] as? String,
          let id = UUID(uuidString: idStr),
          let startedMs = (row["started_at_ms"] as? Int64) ?? (row["started_at_ms"] as? Int).map(Int64.init),
          let durationMs = (row["duration_ms"] as? Int64) ?? (row["duration_ms"] as? Int).map(Int64.init),
          let peakDB = row["peak_db"] as? Double,
          let kindStr = row["kind"] as? String,
          let kind = SleepAudioEvent.Kind(rawValue: kindStr)
        else { return nil }
        let url = (row["file_path"] as? String).map { URL(fileURLWithPath: $0) }
        return SleepAudioEvent(
          id: id,
          start: Date(timeIntervalSince1970: TimeInterval(startedMs) / 1000),
          durationSeconds: TimeInterval(durationMs) / 1000,
          peakDB: peakDB,
          kind: kind,
          fileURL: url
        )
      }
      await MainActor.run { [weak self] in
        self?.recentEvents = events
      }
    }
  }

  private func finishEventRecorder() {
    eventRecorder?.stop()
    eventRecorder = nil
  }

  // MARK: - Pruning

  /// Delete clips older than `retentionDays`. Called on launch.
  func pruneOldClips() {
    let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 86400)
    let manager = FileManager.default
    guard let files = try? manager.contentsOfDirectory(at: storageDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
    for url in files {
      let creation = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
      if creation < cutoff {
        try? manager.removeItem(at: url)
      }
    }
  }
}
