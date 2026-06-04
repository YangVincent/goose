import Foundation

/// Local sleep-window detection from the persisted 1Hz HR samples in
/// `HeartRateSeriesStore`. No server, no actigraphy module — just a simple
/// HR-drop heuristic that's surprisingly effective for a single user.
///
/// Algorithm:
///   1. Take last night's overnight window (default 18:00 yesterday →
///      noon today).
///   2. Compute the user's RHR baseline from the longest 10-minute window
///      of stable HR. If `HeartRateSeriesStore.restingEstimate` already
///      has a recent value, prefer that — it uses 7 days of bottom-quartile
///      data which is more reliable than a single overnight.
///   3. Slide a 10-minute window across the overnight period. A window
///      qualifies as "asleep" if average HR is within +5 bpm of RHR.
///   4. The longest run of consecutive qualifying windows = sleep period.
///   5. Sleep onset = start of that run; wake = end of run.
///
/// Returns nil if we don't have enough samples to be confident. Sleep
/// performance is then `duration / needBaseline`, clamped 0-100.
enum SleepWindowDetector {
  struct DetectedWindow {
    let onset: Date
    let wake: Date
    let durationSeconds: Double
    let restingHRBaseline: Double
    let qualifiedWindowCount: Int
    /// Fraction of the suggested 8-hour need that we slept (0-1).
    let performance: Double
    /// Confidence based on baseline stability + sample density.
    let confidence: Double
  }

  /// Detect last night's sleep window using HR samples retrieved from the
  /// caller. The `now` parameter is the "wake morning" reference — we look
  /// back 18 hours from it.
  static func detect(
    samples: [HeartRateSamplePoint],
    restingEstimate: HeartRateRestingEstimate?,
    now: Date = Date(),
    sleepNeedHours: Double = 8.0
  ) -> DetectedWindow? {
    let windowStart = now.addingTimeInterval(-18 * 3600)
    let windowEnd = now
    let inWindow = samples.filter { $0.capturedAt >= windowStart && $0.capturedAt < windowEnd }
    guard inWindow.count >= 120 else { return nil }  // ~2 hours of 1Hz samples minimum

    // Baseline: prefer the store's resting estimate if it's recent, else
    // bottom-decile of the in-window samples.
    let resting: Double
    let baselineConfidence: Double
    if let estimate = restingEstimate {
      resting = estimate.bpm
      baselineConfidence = 1.0
    } else {
      let sorted = inWindow.map(\.bpm).sorted()
      let decileIdx = max(0, sorted.count / 10)
      resting = Double(sorted[decileIdx])
      baselineConfidence = 0.5
    }
    let threshold = resting + 5

    // Bin samples into 10-min buckets, compute avg HR per bucket.
    let bucketSeconds: TimeInterval = 600
    let bucketCount = Int(windowEnd.timeIntervalSince(windowStart) / bucketSeconds)
    guard bucketCount > 6 else { return nil }
    var bucketSums = Array(repeating: 0, count: bucketCount)
    var bucketCounts = Array(repeating: 0, count: bucketCount)
    for sample in inWindow {
      let offset = sample.capturedAt.timeIntervalSince(windowStart) / bucketSeconds
      let idx = Int(offset)
      guard bucketCounts.indices.contains(idx) else { continue }
      bucketSums[idx] += sample.bpm
      bucketCounts[idx] += 1
    }
    var qualified: [Bool] = []
    for idx in 0..<bucketCount {
      if bucketCounts[idx] >= 30 {
        let avg = Double(bucketSums[idx]) / Double(bucketCounts[idx])
        qualified.append(avg <= threshold)
      } else {
        qualified.append(false)
      }
    }

    // Longest consecutive run of qualified buckets.
    var bestStart: Int?
    var bestLen = 0
    var curStart = 0
    var curLen = 0
    for (idx, ok) in qualified.enumerated() {
      if ok {
        if curLen == 0 { curStart = idx }
        curLen += 1
        if curLen > bestLen {
          bestLen = curLen
          bestStart = curStart
        }
      } else {
        curLen = 0
      }
    }
    guard let startIdx = bestStart, bestLen >= 18 else { return nil }  // need ≥ 3 hours
    let onset = windowStart.addingTimeInterval(Double(startIdx) * bucketSeconds)
    let wake = windowStart.addingTimeInterval(Double(startIdx + bestLen) * bucketSeconds)
    let duration = wake.timeIntervalSince(onset)

    let need = sleepNeedHours * 3600
    let performance = min(1.0, duration / need)

    let densityConfidence = min(1.0, Double(inWindow.count) / 600)  // 1Hz for 10 minutes = strong
    let lengthConfidence = min(1.0, Double(bestLen) / 36)  // 6h = high confidence
    let confidence = baselineConfidence * 0.4
                   + densityConfidence * 0.3
                   + lengthConfidence * 0.3

    return DetectedWindow(
      onset: onset,
      wake: wake,
      durationSeconds: duration,
      restingHRBaseline: resting,
      qualifiedWindowCount: bestLen,
      performance: performance,
      confidence: confidence
    )
  }
}

@MainActor
final class SleepWindowStore: ObservableObject {
  static let shared = SleepWindowStore()

  @Published private(set) var lastNight: SleepWindowDetector.DetectedWindow?

  func refresh() {
    let samples = HeartRateSeriesStore.shared.samples(
      from: Date().addingTimeInterval(-18 * 3600),
      to: Date()
    )
    let resting = HeartRateSeriesStore.shared.restingEstimate()
    lastNight = SleepWindowDetector.detect(samples: samples, restingEstimate: resting)
  }
}
