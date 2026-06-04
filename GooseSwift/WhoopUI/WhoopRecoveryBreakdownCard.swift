import SwiftUI

/// Transparency card: show what's driving today's recovery score so the
/// number isn't a black box. Splits the weighted average from
/// `GooseRecoveryCalculator` into three visible component rows (HRV, RHR,
/// sleep) with directional indicators relative to baseline.
struct WhoopRecoveryBreakdownCard: View {
  @ObservedObject var client: WhoopAPIClient
  @State private var score: GooseRecoveryCalculator.Score?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if let score, score.confidence > 0 {
        VStack(spacing: 8) {
          componentRow(
            label: "HRV",
            current: score.hrvComponent,
            baseline: score.hrvBaseline,
            unit: "ms",
            higherIsBetter: true,
            weight: 0.55
          )
          componentRow(
            label: "RHR",
            current: score.rhrComponent,
            baseline: score.rhrBaseline,
            unit: "bpm",
            higherIsBetter: false,
            weight: 0.20
          )
          componentRow(
            label: "SLEEP",
            current: score.sleepPerformance,
            baseline: nil,
            unit: "%",
            higherIsBetter: true,
            weight: 0.25
          )
        }

        Text("Confidence \(Int(score.confidence * 100))% · baseline \(score.baselineDayCount) days")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.4))
      } else {
        Text("Need at least 4 days of baseline data.")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .onAppear { refresh() }
    .onChange(of: client.recoveryHistory.count) { _, _ in refresh() }
  }

  private var header: some View {
    HStack {
      Text("RECOVERY FACTORS")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      Spacer()
      if let score {
        Text("\(score.score)")
          .font(.system(size: 18, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(tint(for: score.band))
      }
    }
  }

  private func componentRow(
    label: String,
    current: Double?,
    baseline: Double?,
    unit: String,
    higherIsBetter: Bool,
    weight: Double
  ) -> some View {
    let direction: ComponentDirection = {
      guard let current = current, let baseline = baseline else {
        return current != nil ? .observed : .missing
      }
      let delta = current - baseline
      let threshold = baseline * 0.05
      if higherIsBetter {
        if delta > threshold { return .better }
        if delta < -threshold { return .worse }
      } else {
        if delta < -threshold { return .better }
        if delta > threshold { return .worse }
      }
      return .neutral
    }()
    return HStack(spacing: 10) {
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 50, alignment: .leading)

      // Weight bar
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(direction.color.opacity(0.6))
        .frame(width: 60 * weight, height: 6)
        .frame(width: 60, alignment: .leading)
        .background(
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Color.white.opacity(0.06))
            .frame(width: 60, height: 6)
        )

      Image(systemName: direction.glyph)
        .font(.system(size: 11, weight: .heavy))
        .foregroundStyle(direction.color)
        .frame(width: 14)

      Text(currentValueString(current, unit: unit))
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)

      if let baseline {
        Text("· baseline \(currentValueString(baseline, unit: unit))")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(0.5)
          .foregroundStyle(.white.opacity(0.4))
          .lineLimit(1)
      }
      Spacer()
    }
  }

  private func currentValueString(_ value: Double?, unit: String) -> String {
    guard let value = value else { return "--" }
    if unit == "%" {
      return String(format: "%.0f %@", value, unit)
    }
    if unit == "ms" || unit == "bpm" {
      return String(format: "%.0f %@", value, unit)
    }
    return String(format: "%.1f %@", value, unit)
  }

  private enum ComponentDirection {
    case better
    case worse
    case neutral
    case observed
    case missing

    var color: Color {
      switch self {
      case .better: Color(red: 0.18, green: 0.88, blue: 0.66)
      case .worse: Color(red: 1.0, green: 0.37, blue: 0.42)
      case .neutral: Color(red: 0.55, green: 0.85, blue: 1.0)
      case .observed: Color(red: 0.55, green: 0.85, blue: 1.0)
      case .missing: Color.white.opacity(0.25)
      }
    }

    var glyph: String {
      switch self {
      case .better: "arrow.up.right"
      case .worse: "arrow.down.right"
      case .neutral: "arrow.right"
      case .observed: "circle"
      case .missing: "minus"
      }
    }
  }

  private func tint(for band: GooseRecoveryCalculator.Band) -> Color {
    switch band {
    case .green: Color(red: 0.18, green: 0.88, blue: 0.66)
    case .yellow: Color(red: 1.0, green: 0.88, blue: 0.40)
    case .red: Color(red: 1.0, green: 0.37, blue: 0.42)
    }
  }

  // MARK: - Compute

  private func refresh() {
    NightlyHRVStore.shared.refresh()

    var hrvSeries = client.recoveryHistory.compactMap(\.hrv_rmssd_milli)
    // Fold locally-derived nightly HRV (from our own RR intervals) into the
    // series — when server data is empty (post-OAuth-expiry), this is how
    // the recovery calculator still gets an HRV signal.
    let localHRV = NightlyHRVStore.shared.recentNights.map(\.medianRMSSD)
    hrvSeries.append(contentsOf: localHRV)

    var rhrSeries = client.recoveryHistory.compactMap(\.resting_heart_rate)
    if let localRHR = HeartRateSeriesStore.shared.restingEstimate() {
      rhrSeries.append(localRHR.bpm)
    }

    // Sleep performance: server first, then our local sleep window detector.
    let sleep = client.currentDay?.sleep?.performance
      ?? SleepWindowStore.shared.lastNight.map { $0.performance * 100 }

    guard hrvSeries.count >= 4 || rhrSeries.count >= 4 else { return }
    score = GooseRecoveryCalculator.compute(
      hrvSeries: hrvSeries,
      rhrSeries: rhrSeries,
      sleepPerformance: sleep
    )
  }
}
