import SwiftUI

/// Compact "today vs yesterday vs 7-day average" comparison card. Four
/// metrics: recovery, strain, sleep performance, RHR. For each, the user
/// sees a quick at-a-glance directional read.
///
/// All values are resolved with the same fallback chain as the main Home
/// view (server first, local second), so the card works fully offline.
struct WhoopDayComparisonCard: View {
  @ObservedObject var client: WhoopAPIClient

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("TODAY VS RECENT")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))

      VStack(spacing: 8) {
        metricRow(label: "RECOVERY", today: todayRecovery, yesterday: yesterdayRecovery, avg7d: avg7dRecovery, suffix: "%")
        metricRow(label: "STRAIN", today: todayStrain, yesterday: yesterdayStrain, avg7d: avg7dStrain, suffix: "", decimals: 1)
        metricRow(label: "RHR", today: todayRHR, yesterday: yesterdayRHR, avg7d: avg7dRHR, suffix: " bpm", lowerIsBetter: true)
        metricRow(label: "HRV", today: todayHRV, yesterday: yesterdayHRV, avg7d: avg7dHRV, suffix: " ms")
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private func metricRow(
    label: String,
    today: Double?,
    yesterday: Double?,
    avg7d: Double?,
    suffix: String,
    lowerIsBetter: Bool = false,
    decimals: Int = 0
  ) -> some View {
    HStack(spacing: 10) {
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.55))
        .frame(width: 70, alignment: .leading)

      VStack(alignment: .leading, spacing: 1) {
        Text("TODAY")
          .font(.system(size: 7, weight: .heavy, design: .rounded))
          .tracking(0.8)
          .foregroundStyle(.white.opacity(0.4))
        Text(format(today, suffix: suffix, decimals: decimals))
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 1) {
        Text("YESTERDAY")
          .font(.system(size: 7, weight: .heavy, design: .rounded))
          .tracking(0.8)
          .foregroundStyle(.white.opacity(0.4))
        HStack(spacing: 3) {
          Text(format(yesterday, suffix: suffix, decimals: decimals))
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
          arrow(today: today, prior: yesterday, lowerIsBetter: lowerIsBetter)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      VStack(alignment: .leading, spacing: 1) {
        Text("7D AVG")
          .font(.system(size: 7, weight: .heavy, design: .rounded))
          .tracking(0.8)
          .foregroundStyle(.white.opacity(0.4))
        HStack(spacing: 3) {
          Text(format(avg7d, suffix: suffix, decimals: decimals))
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.75))
          arrow(today: today, prior: avg7d, lowerIsBetter: lowerIsBetter)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func arrow(today: Double?, prior: Double?, lowerIsBetter: Bool) -> some View {
    guard let today = today, let prior = prior else {
      return Text("")
        .foregroundStyle(.white.opacity(0))
        .eraseToAnyView()
    }
    let delta = today - prior
    let threshold = abs(prior) * 0.03
    if abs(delta) < threshold {
      return Image(systemName: "arrow.right")
        .font(.system(size: 9, weight: .heavy))
        .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
        .eraseToAnyView()
    }
    let goodDirection = lowerIsBetter ? (delta < 0) : (delta > 0)
    return Image(systemName: delta > 0 ? "arrow.up.right" : "arrow.down.right")
      .font(.system(size: 9, weight: .heavy))
      .foregroundStyle(goodDirection
                       ? Color(red: 0.18, green: 0.88, blue: 0.66)
                       : Color(red: 1.0, green: 0.55, blue: 0.30))
      .eraseToAnyView()
  }

  private func format(_ value: Double?, suffix: String, decimals: Int) -> String {
    guard let value = value else { return "--" }
    if decimals > 0 {
      return String(format: "%.\(decimals)f%@", value, suffix)
    }
    return String(format: "%.0f%@", value, suffix)
  }

  // MARK: - Resolvers

  private var todayRecovery: Double? {
    client.currentDay?.recovery?.recovery_score
  }
  private var yesterdayRecovery: Double? {
    let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    return client.recoveryScore(forISODate: WhoopAPIClient.shared.isoDate(yesterday))
  }
  private var avg7dRecovery: Double? {
    let scores = (1..<8).compactMap { offset -> Double? in
      let d = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
      return client.recoveryScore(forISODate: WhoopAPIClient.shared.isoDate(d))
    }
    return scores.isEmpty ? nil : scores.reduce(0, +) / Double(scores.count)
  }

  private var todayStrain: Double? {
    if let server = client.currentDay?.strain?.strain { return server }
    return DayStrainStore.shared.today?.strain
  }
  private var yesterdayStrain: Double? {
    let date = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    let samples = HeartRateSeriesStore.shared.samples(forDayContaining: date)
    guard samples.count >= 100 else { return nil }
    let off = SensorSampleStore.shared.offWristWindows()
    let day = DayStrainCalculator.computeDayStrain(
      samples: samples,
      offWristWindows: off,
      for: date
    )
    return day.strain
  }
  private var avg7dStrain: Double? {
    let strains = (1..<8).compactMap { offset -> Double? in
      let date = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
      let samples = HeartRateSeriesStore.shared.samples(forDayContaining: date)
      guard samples.count >= 100 else { return nil }
      let off = SensorSampleStore.shared.offWristWindows()
      let day = DayStrainCalculator.computeDayStrain(
        samples: samples,
        offWristWindows: off,
        for: date
      )
      return day.strain
    }
    return strains.isEmpty ? nil : strains.reduce(0, +) / Double(strains.count)
  }

  private var todayRHR: Double? {
    if let server = client.currentDay?.recovery?.resting_heart_rate { return server }
    return HeartRateSeriesStore.shared.restingEstimate()?.bpm
  }
  private var yesterdayRHR: Double? {
    client.recoveryHistory.last?.resting_heart_rate
  }
  private var avg7dRHR: Double? {
    let values = client.recoveryHistory.compactMap(\.resting_heart_rate).suffix(7)
    return values.isEmpty ? nil : Array(values).reduce(0, +) / Double(values.count)
  }

  private var todayHRV: Double? {
    client.currentDay?.recovery?.hrv_rmssd_milli
  }
  private var yesterdayHRV: Double? {
    client.recoveryHistory.last?.hrv_rmssd_milli
  }
  private var avg7dHRV: Double? {
    let values = client.recoveryHistory.compactMap(\.hrv_rmssd_milli).suffix(7)
    return values.isEmpty ? nil : Array(values).reduce(0, +) / Double(values.count)
  }
}

private extension View {
  func eraseToAnyView() -> AnyView {
    AnyView(self)
  }
}
