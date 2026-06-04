import Foundation

/// Tracks the user's actual observed HR peaks vs the HRmax configured in
/// `UserProfile`. If the observed 99.5th-percentile peak across the last N
/// days exceeds the configured HRmax by more than the tolerance, we surface
/// a suggestion (via the `WhoopHRMaxAdvisoryCard` on Home) so the user can
/// re-tune.
///
/// Tuning is read-only for now — we don't auto-update `UserProfile`. Once
/// that struct is backed by UserDefaults, this can become a "tap to apply"
/// flow. For today it's a "you might want to tune this" hint.
enum PersonalHRPeakDetector {
  struct Report {
    let configuredHRmax: Int
    let observedPeak: Int          // raw max BPM in window
    let observedP99_5: Int         // 99.5th-percentile BPM in window
    let sampleCount: Int
    let windowDays: Int
    /// Suggested HRmax = max(configured, observedP99_5 + 2). The +2 buffer
    /// avoids the suggested value sliding up by 1 every time we capture a
    /// new noise spike.
    let suggestedHRmax: Int
    /// True when the observed peak is high enough that the configured value
    /// is likely understating real exertion.
    let suggestUpdate: Bool
  }

  /// Walk the persisted HR samples and produce a report. Safe to call from
  /// any thread (reads a snapshot copy of the array). Off-wrist windows are
  /// excluded so a single bad sample doesn't push the peak.
  static func compute(
    samples: [HeartRateSamplePoint],
    offWristWindows: [(start: Date, end: Date)],
    configuredHRmax: Int = UserProfile.maxHeartRate,
    windowDays: Int = 30,
    minSamples: Int = 5_000,
    suggestTolerance: Int = 5
  ) -> Report {
    let cutoff = Calendar.current.date(byAdding: .day, value: -windowDays, to: Date())
      ?? Date().addingTimeInterval(-Double(windowDays) * 86400)
    let inWindow = samples
      .filter { $0.capturedAt >= cutoff && $0.bpm > 30 && $0.bpm < 240 }
    let onWrist = filterOnWrist(inWindow, offWristWindows: offWristWindows)
    guard onWrist.count >= minSamples else {
      return Report(
        configuredHRmax: configuredHRmax,
        observedPeak: 0,
        observedP99_5: 0,
        sampleCount: onWrist.count,
        windowDays: windowDays,
        suggestedHRmax: configuredHRmax,
        suggestUpdate: false
      )
    }

    let bpms = onWrist.map(\.bpm).sorted()
    let peak = bpms.last ?? 0
    let p995Index = max(0, min(bpms.count - 1, Int(Double(bpms.count) * 0.995)))
    let p995 = bpms[p995Index]
    let suggested = max(configuredHRmax, p995 + 2)
    let shouldSuggest = p995 > (configuredHRmax + suggestTolerance)
    return Report(
      configuredHRmax: configuredHRmax,
      observedPeak: peak,
      observedP99_5: p995,
      sampleCount: onWrist.count,
      windowDays: windowDays,
      suggestedHRmax: suggested,
      suggestUpdate: shouldSuggest
    )
  }

  private static func filterOnWrist(
    _ samples: [HeartRateSamplePoint],
    offWristWindows: [(start: Date, end: Date)]
  ) -> [HeartRateSamplePoint] {
    guard !offWristWindows.isEmpty else { return samples }
    return samples.filter { sample in
      var lo = 0
      var hi = offWristWindows.count - 1
      while lo <= hi {
        let mid = (lo + hi) / 2
        let window = offWristWindows[mid]
        if sample.capturedAt < window.start {
          hi = mid - 1
        } else if sample.capturedAt > window.end {
          lo = mid + 1
        } else {
          return false
        }
      }
      return true
    }
  }
}

@MainActor
final class PersonalHRPeakStore: ObservableObject {
  static let shared = PersonalHRPeakStore()

  @Published private(set) var report: PersonalHRPeakDetector.Report?

  func refresh() {
    let allSamples = HeartRateSeriesStore.shared.samples(
      from: Date().addingTimeInterval(-31 * 86400),
      to: Date()
    )
    let off = SensorSampleStore.shared.offWristWindows()
    report = PersonalHRPeakDetector.compute(samples: allSamples, offWristWindows: off)
  }
}
