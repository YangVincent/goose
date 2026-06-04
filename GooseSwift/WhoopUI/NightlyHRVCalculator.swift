import Foundation

/// Nightly HRV calculator — runs `HRVAnalyzer` over the detected sleep
/// window and surfaces a single representative RMSSD value for the night.
/// This is how WHOOP arrives at its "nightly HRV" baseline.
///
/// Method: take RR intervals from `SensorSampleStore` during the detected
/// onset→wake window, bin into 5-min HRV windows, return the *median* of
/// those windows. Median is more robust than mean to the brief HRV spikes
/// during REM cycles or movement transients.
///
/// Returns nil if we don't have a detected window or fewer than 3 valid
/// HRV windows.
@MainActor
final class NightlyHRVStore: ObservableObject {
  static let shared = NightlyHRVStore()

  struct NightHRV: Identifiable {
    let id: String  // date key
    let dateKey: String
    let medianRMSSD: Double
    let meanRMSSD: Double
    let windowCount: Int
    let onset: Date
    let wake: Date
    let totalBeats: Int
  }

  @Published private(set) var lastNight: NightHRV?
  /// Recent N days of nightly HRV — useful for trend display and as
  /// baseline input for the recovery score when server data is empty.
  @Published private(set) var recentNights: [NightHRV] = []

  func refresh() {
    if let window = SleepWindowStore.shared.lastNight {
      lastNight = computeNight(start: window.onset, end: window.wake)
    } else {
      lastNight = nil
    }
    rebuildRecent()
  }

  private func rebuildRecent() {
    var nights: [NightHRV] = []
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    for offset in 0..<14 {
      guard let dayEnd = calendar.date(byAdding: .day, value: -offset, to: today),
            let nightStart = calendar.date(byAdding: .hour, value: 22, to: calendar.date(byAdding: .day, value: -1, to: dayEnd) ?? dayEnd),
            let nightEnd = calendar.date(byAdding: .hour, value: 8, to: dayEnd) else { continue }
      if let night = computeNight(start: nightStart, end: nightEnd) {
        nights.append(night)
      }
    }
    recentNights = nights.sorted { $0.dateKey < $1.dateKey }
  }

  private func computeNight(start: Date, end: Date) -> NightHRV? {
    let samples = SensorSampleStore.shared.snapshot(from: start, to: end)
    let snapshot = HRVAnalyzer.compute(
      samples: samples,
      windowMinutes: 5,
      strideMinutes: 5
    )
    guard snapshot.windows.count >= 3 else { return nil }
    let rmssds = snapshot.windows.map(\.rmssd).sorted()
    let median = rmssds[rmssds.count / 2]
    let mean = rmssds.reduce(0, +) / Double(rmssds.count)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return NightHRV(
      id: formatter.string(from: end),
      dateKey: formatter.string(from: end),
      medianRMSSD: median,
      meanRMSSD: mean,
      windowCount: snapshot.windows.count,
      onset: start,
      wake: end,
      totalBeats: snapshot.totalRRCount
    )
  }
}
