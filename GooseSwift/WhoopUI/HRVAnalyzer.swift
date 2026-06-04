import Foundation

/// Computes our own HRV (RMSSD) from RR intervals streaming off the strap into
/// `SensorSampleStore`. WHOOP only exposes a once-per-night HRV figure; with
/// continuous RR access we can do this in rolling windows, even mid-day.
///
/// Stress estimate is z-scored against the user's recent baseline so a value
/// around 0 = normal, +1 = relaxed, -1 = stressed. This is a heuristic the
/// rest of the field uses (Polar's "Nightly Recharge", Garmin's "Body Battery"
/// internals); it's not validated against WHOOP's own HRV pipeline.
enum HRVAnalyzer {
  struct Window: Identifiable {
    let id: UUID
    let start: Date
    let end: Date
    let sampleCount: Int
    let rmssd: Double
    let mean: Double
    let sdnn: Double
  }

  struct Snapshot {
    let windows: [Window]
    let recentRMSSD: Double?
    let baselineRMSSD: Double?
    let baselineStdDev: Double?
    /// z-score vs baseline; positive = more relaxed, negative = more stressed.
    let stressZ: Double?
    let totalRRCount: Int
    let lastIntervalAt: Date?
  }

  /// Compute rolling-window HRV over the provided sensor sample buffer.
  ///
  /// - Parameters:
  ///   - samples: ordered by capturedAt (older first)
  ///   - windowMinutes: width of each HRV window in minutes (5 is the SDNN/RMSSD industry default)
  ///   - strideMinutes: how often to start a new window
  static func compute(
    samples: [SensorSample],
    windowMinutes: Double = 5,
    strideMinutes: Double = 5
  ) -> Snapshot {
    let beats = flattenBeats(samples)
    guard !beats.isEmpty else {
      return Snapshot(
        windows: [],
        recentRMSSD: nil,
        baselineRMSSD: nil,
        baselineStdDev: nil,
        stressZ: nil,
        totalRRCount: 0,
        lastIntervalAt: nil
      )
    }

    let span = windowMinutes * 60
    let step = strideMinutes * 60
    guard let first = beats.first?.at, let last = beats.last?.at else {
      return Snapshot(
        windows: [],
        recentRMSSD: nil,
        baselineRMSSD: nil,
        baselineStdDev: nil,
        stressZ: nil,
        totalRRCount: beats.count,
        lastIntervalAt: nil
      )
    }

    var windows: [Window] = []
    var cursor = first
    while cursor.addingTimeInterval(span) <= last.addingTimeInterval(0.5) {
      let end = cursor.addingTimeInterval(span)
      let slice = beats.filter { $0.at >= cursor && $0.at < end }
      let intervals = slice.map(\.rr)
      if intervals.count >= 6,
         let stats = HRVStats.compute(intervals: intervals) {
        windows.append(
          Window(
            id: UUID(),
            start: cursor,
            end: end,
            sampleCount: intervals.count,
            rmssd: stats.rmssd,
            mean: stats.mean,
            sdnn: stats.sdnn
          )
        )
      }
      cursor = cursor.addingTimeInterval(step)
    }

    let recent = windows.last?.rmssd
    let baselineCohort = Array(windows.dropLast().suffix(20).map(\.rmssd))
    let baselineMean: Double? = baselineCohort.isEmpty
      ? nil
      : baselineCohort.reduce(0, +) / Double(baselineCohort.count)
    let baselineStd: Double? = {
      guard let mean = baselineMean, baselineCohort.count >= 4 else { return nil }
      let sq = baselineCohort.map { ($0 - mean) * ($0 - mean) }
      return sqrt(sq.reduce(0, +) / Double(baselineCohort.count - 1))
    }()
    let stressZ: Double? = {
      guard let recent, let mean = baselineMean, let std = baselineStd, std > 0.0001 else { return nil }
      return (recent - mean) / std
    }()

    return Snapshot(
      windows: windows,
      recentRMSSD: recent,
      baselineRMSSD: baselineMean,
      baselineStdDev: baselineStd,
      stressZ: stressZ,
      totalRRCount: beats.count,
      lastIntervalAt: beats.last?.at
    )
  }

  // MARK: - Helpers

  private struct Beat {
    let at: Date
    let rr: Double
  }

  /// Re-construct a beat timeline from per-packet sensor samples. Each sample
  /// may carry one or many RR intervals; we walk backward from capturedAt to
  /// approximate the beat timestamps.
  private static func flattenBeats(_ samples: [SensorSample]) -> [Beat] {
    var out: [Beat] = []
    for sample in samples {
      // Off-wrist filtering: skin_contact == 0 means the strap was not on the
      // wrist when the packet was captured. The PPG signal during that window
      // is noise (often a clean 60 bpm aliased from environmental light), so
      // dropping those beats prevents fake HRV from poisoning the baseline.
      if sample.skinContact == 0 { continue }
      guard let intervals = sample.rrIntervalsMS, !intervals.isEmpty else { continue }
      let totalSeconds = Double(intervals.reduce(0, +)) / 1000.0
      var t = sample.capturedAt.addingTimeInterval(-totalSeconds)
      for rrMs in intervals {
        let rr = Double(rrMs) / 1000.0
        guard rr > 0.3, rr < 2.0 else { continue }  // sanity filter
        out.append(Beat(at: t, rr: rr))
        t = t.addingTimeInterval(rr)
      }
    }
    return out.sorted { $0.at < $1.at }
  }
}

enum HRVStats {
  struct Result {
    let mean: Double
    let sdnn: Double
    let rmssd: Double
  }

  /// Compute mean RR, SDNN, and RMSSD for a window. All in milliseconds.
  static func compute(intervals: [Double]) -> Result? {
    let count = intervals.count
    guard count >= 2 else { return nil }
    let ms = intervals.map { $0 * 1000.0 }
    let mean = ms.reduce(0, +) / Double(count)
    let sdnn = sqrt(
      ms.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(count - 1)
    )
    var sqSum: Double = 0
    for idx in 1..<count {
      let diff = ms[idx] - ms[idx - 1]
      sqSum += diff * diff
    }
    let rmssd = sqrt(sqSum / Double(count - 1))
    return Result(mean: mean, sdnn: sdnn, rmssd: rmssd)
  }
}
