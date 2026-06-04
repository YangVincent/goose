import Foundation

/// Phase 3 of strap-independence: reads Goose's local `heart-rate-samples.json`,
/// aggregates the last 24h into per-zone minutes, and POSTs the result to
/// `https://aeonneo.com/health/api/whoop/upload`.
///
/// Runs in three places:
///   - At app foreground (`uploadNowIfStale` triggered from RootView/.task)
///   - On a 30-minute foreground timer while the app is open
///   - On iOS background-app-refresh wake-ups (BGAppRefreshTask, scheduled
///     via `BGTaskScheduler` in WhoopUploaderBackgroundTask.swift if we
///     ever want to chase truly always-on uploading — not wired yet).
///
/// Failure mode is "try again next tick" — uploads are idempotent on the
/// server side (UPSERT by date), so retrying with overlapping windows is
/// safe and the server takes the latest aggregate.
@MainActor
final class GooseUploader: ObservableObject {
  static let shared = GooseUploader()

  @Published private(set) var lastUploadedAt: Date?
  @Published private(set) var lastError: String?
  @Published private(set) var lastSampleCount: Int = 0
  @Published private(set) var isUploading = false

  private let uploadURL = URL(string: "https://aeonneo.com/health/api/whoop/upload")!
  private let minimumIntervalSeconds: TimeInterval = 5 * 60
  private let maxHR: Int

  private let samplesURL: URL = {
    let base = FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)
      .first ?? FileManager.default.temporaryDirectory
    return base
      .appendingPathComponent("GooseSwift", isDirectory: true)
      .appendingPathComponent("heart-rate-samples.json")
  }()

  private let session: URLSession = {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 15
    config.timeoutIntervalForResource = 25
    config.urlCache = nil
    return URLSession(configuration: config)
  }()

  // MARK: - Public API

  init(maxHR: Int = UserProfile.maxHeartRate) {
    self.maxHR = maxHR
  }

  /// Upload if we haven't uploaded recently and there are local samples.
  func uploadNowIfStale() async {
    guard !isUploading else { return }
    if let last = lastUploadedAt,
       Date().timeIntervalSince(last) < minimumIntervalSeconds {
      return
    }
    await uploadNow()
  }

  /// Force an upload regardless of when the last one happened.
  func uploadNow() async {
    isUploading = true
    defer { isUploading = false }

    let allSamples = readSamples()
    if allSamples.isEmpty {
      lastError = "no samples available"
      return
    }
    // Drop samples that landed during off-wrist windows so daily aggregates
    // don't include PPG noise from the strap sitting on a desk.
    let offWrist = SensorSampleStore.shared.offWristWindows()
    let samples = filterOnWrist(allSamples, offWristWindows: offWrist)

    let aggregates = aggregateByDay(samples: samples)
    let payload: [String: Any] = [
      "device_id": "ios.goose",
      "uploaded_at": ISO8601DateFormatter().string(from: Date()),
      "days": aggregates,
    ]

    var request = URLRequest(url: uploadURL)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try JSONSerialization.data(withJSONObject: payload)
    } catch {
      lastError = "encode failed: \(error.localizedDescription)"
      return
    }

    do {
      let (data, response) = try await session.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        lastError = "server returned status \(code)"
        return
      }
      // Server returns {"saved": N}; pull the count out for visibility.
      if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
         let saved = body["saved"] as? Int {
        lastSampleCount = saved
      }
      lastError = nil
      lastUploadedAt = Date()
    } catch {
      lastError = "POST failed: \(error.localizedDescription)"
    }
  }

  // MARK: - Internals

  private struct Sample: Decodable {
    let bpm: Int
    let source: String?
    let capturedAt: String
  }

  private struct SamplesFile: Decodable {
    let version: Int?
    let samples: [Sample]
  }

  private func filterOnWrist(_ samples: [Sample], offWristWindows: [(start: Date, end: Date)]) -> [Sample] {
    guard !offWristWindows.isEmpty else { return samples }
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plainParser = ISO8601DateFormatter()
    return samples.filter { sample in
      let date = parser.date(from: sample.capturedAt) ?? plainParser.date(from: sample.capturedAt)
      guard let date else { return true }
      // Binary-search the sorted, non-overlapping windows.
      var lo = 0
      var hi = offWristWindows.count - 1
      while lo <= hi {
        let mid = (lo + hi) / 2
        let window = offWristWindows[mid]
        if date < window.start {
          hi = mid - 1
        } else if date > window.end {
          lo = mid + 1
        } else {
          return false
        }
      }
      return true
    }
  }

  private func readSamples() -> [Sample] {
    guard FileManager.default.fileExists(atPath: samplesURL.path),
          let data = try? Data(contentsOf: samplesURL),
          let decoded = try? JSONDecoder().decode(SamplesFile.self, from: data) else {
      return []
    }
    return decoded.samples
  }

  /// Group samples by local date, then bin BPM values into zones. Each
  /// sample is attributed 1 second of zone time (Goose collects at ~1Hz
  /// via standard BLE). For historical packets that arrive in bursts the
  /// per-second attribution is a slight under-count but fine for v1.
  private func aggregateByDay(samples: [Sample]) -> [[String: Any]] {
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plainParser = ISO8601DateFormatter()
    let calendar = Calendar(identifier: .gregorian)
    let dateFormatter = DateFormatter()
    dateFormatter.calendar = calendar
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone.current

    struct Bucket {
      var bpms: [Int] = []
      var sources: [String: Int] = [:]
      var firstAt: Date?
      var lastAt: Date?
    }

    var byDay: [String: Bucket] = [:]

    for sample in samples {
      let date = parser.date(from: sample.capturedAt) ?? plainParser.date(from: sample.capturedAt)
      guard let date else { continue }
      let dayKey = dateFormatter.string(from: date)
      var bucket = byDay[dayKey] ?? Bucket()
      bucket.bpms.append(sample.bpm)
      let src = sample.source ?? "unknown"
      bucket.sources[src, default: 0] += 1
      if bucket.firstAt == nil || date < bucket.firstAt! {
        bucket.firstAt = date
      }
      if bucket.lastAt == nil || date > bucket.lastAt! {
        bucket.lastAt = date
      }
      byDay[dayKey] = bucket
    }

    let isoFormatter = ISO8601DateFormatter()
    var result: [[String: Any]] = []
    for (day, bucket) in byDay {
      guard !bucket.bpms.isEmpty else { continue }
      let zones = binZones(bpms: bucket.bpms)
      let minBPM = bucket.bpms.min() ?? 0
      let maxBPM = bucket.bpms.max() ?? 0
      let meanBPM = Double(bucket.bpms.reduce(0, +)) / Double(bucket.bpms.count)
      var row: [String: Any] = [
        "date": day,
        "source": "phone.aggregate",
        "sample_count": bucket.bpms.count,
        "bpm_min": minBPM,
        "bpm_max": maxBPM,
        "bpm_mean": meanBPM,
        "zone_minutes": zones,
        "source_breakdown": bucket.sources,
      ]
      if let first = bucket.firstAt {
        row["first_sample_at"] = isoFormatter.string(from: first)
      }
      if let last = bucket.lastAt {
        row["last_sample_at"] = isoFormatter.string(from: last)
      }
      result.append(row)
    }
    return result
  }

  private func binZones(bpms: [Int]) -> [String: Double] {
    var below_z1 = 0
    var z1 = 0, z2 = 0, z3 = 0, z4 = 0, z5 = 0
    for bpm in bpms {
      let frac = Double(bpm) / Double(maxHR)
      switch frac {
      case 0.9...:     z5 += 1
      case 0.8..<0.9:  z4 += 1
      case 0.7..<0.8:  z3 += 1
      case 0.6..<0.7:  z2 += 1
      case 0.5..<0.6:  z1 += 1
      default:         below_z1 += 1
      }
    }
    // Assume 1Hz sampling; minutes = samples / 60.
    return [
      "below_z1": Double(below_z1) / 60.0,
      "z1": Double(z1) / 60.0,
      "z2": Double(z2) / 60.0,
      "z3": Double(z3) / 60.0,
      "z4": Double(z4) / 60.0,
      "z5": Double(z5) / 60.0,
    ]
  }
}
