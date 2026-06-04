import Foundation
import SwiftUI

/// Device-to-server offload client. Sends rows from the local SQLite to
/// the Goose offload server in idempotent batches. After a successful
/// upload, marks rows synced so they don't get re-sent.
///
/// Phone stays the source of truth. Server never sends raw data back —
/// only `/v1/analysis/results` flows the other direction (consumed
/// once-per-result by the device).
///
/// Trigger points:
///   - App foreground (debounced)
///   - Manual "sync now" debug button
///   - Periodic timer (every 5 min while app is open)
@MainActor
final class GooseOffloadClient: ObservableObject {
  static let shared = GooseOffloadClient()

  enum SyncState: Equatable {
    case idle
    case running
    case failed(String)
  }

  struct LastRunReport: Equatable {
    let at: Date
    let hrSamplesSent: Int
    let dailySummariesSent: Int
    let totalMs: Int
  }

  @Published private(set) var state: SyncState = .idle
  @Published private(set) var lastReport: LastRunReport?

  // Config — when we eventually flip to DigitalOcean, just change baseURL.
  @AppStorage("goose.offload.baseURL") var baseURL: String = "http://127.0.0.1:8787"
  @AppStorage("goose.offload.token") var bearerToken: String = "dev-local-token"
  @AppStorage("goose.offload.enabled") var isEnabled: Bool = false

  private let bridge = GooseRustBridge()
  private let session = URLSession(configuration: .ephemeral)
  private let batchLimit = 500
  private var timer: Timer?

  /// Start the periodic sync timer. Cheap when isEnabled=false — fires
  /// every 5 min and immediately bails if disabled.
  func startPeriodicSync() {
    timer?.invalidate()
    let t = Timer.scheduledTimer(withTimeInterval: 5 * 60, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.runSync() }
    }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }

  /// Run one sync pass. Drains all unsynced rows up to `batchLimit` per
  /// table per call. Successive calls drain the queue.
  func runSync() async {
    guard isEnabled else { return }
    guard state != .running else { return }
    state = .running
    let started = Date()
    var hrSent = 0
    var dailySent = 0
    do {
      hrSent = try await syncHrSamples()
      dailySent = try await syncDailySummaries()
      state = .idle
      lastReport = LastRunReport(
        at: Date(),
        hrSamplesSent: hrSent,
        dailySummariesSent: dailySent,
        totalMs: Int(Date().timeIntervalSince(started) * 1000)
      )
    } catch {
      state = .failed("\(error)")
    }
  }

  // MARK: - Per-table sync passes

  private func syncHrSamples() async throws -> Int {
    let dbPath = HealthDataStore.defaultDatabasePath()
    let result = try await Task.detached(priority: .background) { [bridge, batchLimit] in
      try bridge.request(method: "swift_caches.list_unsynced_hr_samples", args: [
        "database_path": dbPath,
        "limit": batchLimit,
      ])
    }.value
    let rows = result["rows"] as? [[String: Any]] ?? []
    guard !rows.isEmpty else { return 0 }
    let payload = rows.map { row -> [String: Any] in
      [
        "sample_id": row["sample_id"] ?? "",
        "captured_at_ms": row["captured_at_ms"] ?? 0,
        "bpm": row["bpm"] ?? 0,
        "source": row["source"] ?? "",
      ]
    }
    try await postBatch(path: "/v1/ingest/hr_samples", payload: payload)
    let ids = rows.compactMap { $0["sample_id"] as? String }
    let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
    _ = try await Task.detached(priority: .background) { [bridge] in
      try bridge.request(method: "swift_caches.mark_hr_samples_synced", args: [
        "database_path": dbPath,
        "ids": ids,
        "now_unix_ms": nowMs,
      ])
    }.value
    return ids.count
  }

  private func syncDailySummaries() async throws -> Int {
    let dbPath = HealthDataStore.defaultDatabasePath()
    let result = try await Task.detached(priority: .background) { [bridge, batchLimit] in
      try bridge.request(method: "swift_caches.list_unsynced_daily_summaries", args: [
        "database_path": dbPath,
        "limit": batchLimit,
      ])
    }.value
    let rows = result["rows"] as? [[String: Any]] ?? []
    guard !rows.isEmpty else { return 0 }
    let payload = rows.map { row -> [String: Any] in
      var out: [String: Any] = [
        "date_key": row["date_key"] ?? "",
      ]
      let nullableKeys = [
        "recovery_score", "hrv_rmssd_ms", "resting_hr_bpm", "spo2_pct", "skin_temp_c",
        "sleep_performance_pct", "sleep_efficiency_pct",
        "sleep_in_bed_ms", "sleep_awake_ms", "sleep_light_ms",
        "sleep_deep_ms", "sleep_rem_ms", "sleep_cycle_count",
        "sleep_disturbance_count",
        "sleep_need_baseline_ms", "sleep_need_from_debt_ms",
        "sleep_need_from_strain_ms", "sleep_need_from_nap_ms",
        "strain_score", "strain_kilojoules",
      ]
      for k in nullableKeys {
        if let v = row[k], !(v is NSNull) {
          out[k] = v
        }
      }
      return out
    }
    try await postBatch(path: "/v1/ingest/daily_summaries", payload: payload)
    return rows.count
  }

  // MARK: - HTTP

  private func postBatch(path: String, payload: [[String: Any]]) async throws {
    guard let url = URL(string: baseURL + path) else {
      throw NSError(domain: "Offload", code: 1, userInfo: [NSLocalizedDescriptionKey: "Bad URL: \(baseURL + path)"])
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
    request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    let (_, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let code = (response as? HTTPURLResponse)?.statusCode ?? -1
      throw NSError(
        domain: "Offload",
        code: code,
        userInfo: [NSLocalizedDescriptionKey: "\(path) → \(code)"]
      )
    }
  }
}
