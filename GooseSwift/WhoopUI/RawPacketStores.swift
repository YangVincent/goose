import Foundation

// MARK: - Models

/// One R17 optical packet — full i16 filtered PPG sample stream + summary
/// stats. WHOOP processes these into HR/HRV on the server; persisting the
/// full series here means we can re-run those algorithms ourselves later.
struct R17PacketSample: Identifiable, Equatable {
  let id: String
  let capturedAt: Date
  let flags: Int?
  let sampleCount: Int?
  let channelsOrGain: [Int]
  let samplesMin: Int?
  let samplesMax: Int?
  let samplesSum: Int
  let samples: [Int]
  let source: String
}

/// One K10 / K21 IMU packet — full per-axis i16 series.
struct IMUPacketSample: Identifiable, Equatable {
  let id: String
  let capturedAt: Date
  let kind: String   // "raw_motion_k10" or "raw_motion_k21"
  let heartRateBPM: Int?
  let axes: [Axis]

  struct Axis: Equatable {
    let name: String
    let expectedCount: Int
    let parsedCount: Int
    let min: Int?
    let max: Int?
    let sum: Int
    /// Full sample stream straight off the strap.
    let samples: [Int]
  }
}

// MARK: - Stores (SQLite-backed)

/// Thin Swift cache over `swift_caches.append_raw_r17_packet` /
/// `list_raw_r17_packets`. The on-device SQLite (`goose.sqlite`) is the
/// single source of truth — no JSON mirror.
@MainActor
final class R17PacketStore: ObservableObject {
  static let shared = R17PacketStore()

  @Published private(set) var totalPacketCount: Int = 0
  @Published private(set) var totalSampleCount: Int = 0
  @Published private(set) var mostRecentCapturedAt: Date?

  private let bridge = GooseRustBridge()
  /// Batch inserts so we don't hit the bridge once per packet at K10/K21
  /// rates. Packets queue here, flush on a 1-second debounce or on app
  /// background.
  private var pendingBatch: [R17PacketSample] = []
  private var pendingFlush: DispatchWorkItem?
  private let flushQueue = DispatchQueue(label: "com.goose.swift.r17-flush", qos: .utility)
  private static let flushDelay: TimeInterval = 1.0

  init() {
    // Do NOT delete legacy JSON. The file (if present) stays — SQLite is the
    // source of truth, JSON is a recoverable copy.
    Task { await refreshCounts() }
  }

  func append(_ packet: R17PacketSample) {
    pendingBatch.append(packet)
    scheduleFlush()
  }

  func flushNow() async {
    let batch = pendingBatch
    pendingBatch.removeAll()
    pendingFlush?.cancel()
    pendingFlush = nil
    if batch.isEmpty {
      await refreshCounts()
      return
    }
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    await Task.detached(priority: .utility) {
      for packet in batch {
        let _ = try? bridge.request(
          method: "swift_caches.append_raw_r17_packet",
          args: [
            "database_path": dbPath,
            "packet_id": packet.id,
            "captured_at_ms": Self.unixMs(packet.capturedAt),
            "flags": packet.flags as Any,
            "sample_count": packet.sampleCount as Any,
            "channels_or_gain": packet.channelsOrGain,
            "samples_min": packet.samplesMin as Any,
            "samples_max": packet.samplesMax as Any,
            "samples_sum": packet.samplesSum,
            "samples": packet.samples,
            "source": packet.source,
          ]
        )
      }
    }.value
    await refreshCounts()
  }

  func refreshCounts() async {
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    let response: [String: Any]? = await Task.detached(priority: .utility) {
      try? bridge.request(
        method: "swift_caches.counts",
        args: ["database_path": dbPath]
      )
    }.value
    if let response {
      totalPacketCount = (response["raw_r17_packet_count"] as? Int) ?? 0
      totalSampleCount = totalPacketCount  // PPG sample blob bytes not exposed yet
    }
  }

  private func scheduleFlush() {
    pendingFlush?.cancel()
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in await self?.flushNow() }
    }
    pendingFlush = work
    flushQueue.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
  }

  nonisolated private static func unixMs(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  nonisolated private static func deleteLegacyJSONIfPresent() {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let url = base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("r17-samples.json")
    try? FileManager.default.removeItem(at: url)
  }
}

@MainActor
final class IMUPacketStore: ObservableObject {
  static let shared = IMUPacketStore()

  @Published private(set) var totalPacketCount: Int = 0
  @Published private(set) var totalSampleCount: Int = 0
  @Published private(set) var mostRecentCapturedAt: Date?

  private let bridge = GooseRustBridge()
  private var pendingBatch: [IMUPacketSample] = []
  private var pendingFlush: DispatchWorkItem?
  private let flushQueue = DispatchQueue(label: "com.goose.swift.imu-flush", qos: .utility)
  private static let flushDelay: TimeInterval = 1.0

  init() {
    // Do NOT delete legacy JSON. The file (if present) stays — SQLite is the
    // source of truth, JSON is a recoverable copy.
    Task { await refreshCounts() }
  }

  func append(_ packet: IMUPacketSample) {
    pendingBatch.append(packet)
    scheduleFlush()
  }

  func flushNow() async {
    let batch = pendingBatch
    pendingBatch.removeAll()
    pendingFlush?.cancel()
    pendingFlush = nil
    if batch.isEmpty {
      await refreshCounts()
      return
    }
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    await Task.detached(priority: .utility) {
      for packet in batch {
        let axes: [[String: Any]] = packet.axes.map { axis in
          var dict: [String: Any] = [
            "name": axis.name,
            "expected_count": axis.expectedCount,
            "parsed_count": axis.parsedCount,
            "sum": axis.sum,
            "samples": axis.samples,
          ]
          if let min = axis.min { dict["min"] = min }
          if let max = axis.max { dict["max"] = max }
          return dict
        }
        var args: [String: Any] = [
          "database_path": dbPath,
          "packet_id": packet.id,
          "captured_at_ms": Self.unixMs(packet.capturedAt),
          "kind": packet.kind,
          "axes": axes,
        ]
        if let bpm = packet.heartRateBPM { args["heart_rate_bpm"] = bpm }
        let _ = try? bridge.request(
          method: "swift_caches.append_raw_imu_packet",
          args: args
        )
      }
    }.value
    await refreshCounts()
  }

  func refreshCounts() async {
    let bridge = self.bridge
    let dbPath = HealthDataStore.defaultDatabasePath()
    let response: [String: Any]? = await Task.detached(priority: .utility) {
      try? bridge.request(
        method: "swift_caches.counts",
        args: ["database_path": dbPath]
      )
    }.value
    if let response {
      totalPacketCount = (response["raw_imu_packet_count"] as? Int) ?? 0
      totalSampleCount = totalPacketCount  // axis sample bytes not exposed yet
    }
  }

  private func scheduleFlush() {
    pendingFlush?.cancel()
    let work = DispatchWorkItem { [weak self] in
      Task { @MainActor [weak self] in await self?.flushNow() }
    }
    pendingFlush = work
    flushQueue.asyncAfter(deadline: .now() + Self.flushDelay, execute: work)
  }

  nonisolated private static func unixMs(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1000).rounded())
  }

  nonisolated private static func deleteLegacyJSONIfPresent() {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    let url = base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("imu-samples.json")
    try? FileManager.default.removeItem(at: url)
  }
}
