import SwiftUI

/// "Today's strain target" — WHOOP's flagship coaching feature. Given your
/// recovery score, recommends a strain band to aim for:
///
///   - 67-100% recovery  → push hard (target 14-18)
///   - 34-66%            → moderate (target 10-14)
///   - 0-33%             → recovery day (target 6-10)
///
/// Surfaces "X more to hit minimum target" given today's accumulated
/// strain from `DayStrainStore` — so you know whether you've done enough.
struct WhoopStrainTargetCard: View {
  @ObservedObject private var selectedDay = SelectedDayStore.shared
  @ObservedObject private var dailyStore = WhoopImportedDailyStore.shared
  @ObservedObject var dayStrain: DayStrainStore = .shared

  var body: some View {
    let recovery = resolvedRecoveryScore
    let target = strainTarget(forRecovery: recovery)
    let progress = currentStrain
    let needed = max(0, target.minimum - progress)
    return VStack(alignment: .leading, spacing: 10) {
      header(target: target)

      HStack(alignment: .center, spacing: 14) {
        VStack(alignment: .leading, spacing: 2) {
          Text("TARGET")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.5))
          Text(String(format: "%.0f – %.0f", target.minimum, target.maximum))
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(target.color)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("CURRENT")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.5))
          Text(String(format: "%.1f", progress))
            .font(.system(size: 24, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
      }

      progressBar(progress: progress, target: target)

      Text(coachLine(progress: progress, needed: needed, target: target))
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.75))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private func header(target: StrainTarget) -> some View {
    HStack {
      Text("STRAIN TARGET")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      Spacer()
      Text(target.label.uppercased())
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(target.color)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
          Capsule(style: .continuous)
            .fill(target.color.opacity(0.12))
        )
    }
  }

  private func progressBar(progress: Double, target: StrainTarget) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Color.white.opacity(0.06))
        let xMin = CGFloat(target.minimum / 21) * geo.size.width
        let xMax = CGFloat(target.maximum / 21) * geo.size.width
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(target.color.opacity(0.18))
          .frame(width: max(xMax - xMin, 4))
          .offset(x: xMin)
        let xProgress = CGFloat(min(progress / 21, 1)) * geo.size.width
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(target.color)
          .frame(width: max(xProgress, 2))
      }
    }
    .frame(height: 7)
  }

  private func coachLine(progress: Double, needed: Double, target: StrainTarget) -> String {
    if progress >= target.minimum && progress <= target.maximum {
      return "On target — \(target.encouragement)"
    }
    if progress < target.minimum {
      return String(
        format: "Need %.1f more to hit minimum. %@",
        needed,
        target.guidance
      )
    }
    return "You've exceeded the recommended range — consider winding down."
  }

  // MARK: - Recovery resolution (mirror of WhoopHomeView's logic)

  private var resolvedRecoveryScore: Int? {
    if let score = dailyStore.summary(for: selectedDay.currentDate)?.recoveryScore, score >= 0 {
      return Int(score.rounded())
    }
    let hrvSeries = dailyStore.byDate.values.compactMap { $0.hrvRmssdMs }
    var rhrSeries = dailyStore.byDate.values.compactMap { $0.restingHrBpm }
    if let local = HeartRateSeriesStore.shared.restingEstimate() {
      rhrSeries.append(local.bpm)
    }
    let sleep = dailyStore.summary(for: selectedDay.currentDate)?.sleepPerformancePct
    guard hrvSeries.count >= 4 || rhrSeries.count >= 4 else { return nil }
    let score = GooseRecoveryCalculator.compute(
      hrvSeries: hrvSeries,
      rhrSeries: rhrSeries,
      sleepPerformance: sleep
    )
    return score.confidence > 0 ? score.score : nil
  }

  private var currentStrain: Double {
    if let server = dailyStore.summary(for: selectedDay.currentDate)?.strainScore, server > 0 {
      return server
    }
    return dayStrain.today?.strain ?? 0
  }

  // MARK: - Target table

  private struct StrainTarget {
    let label: String
    let minimum: Double
    let maximum: Double
    let color: Color
    let encouragement: String
    let guidance: String
  }

  private func strainTarget(forRecovery recovery: Int?) -> StrainTarget {
    guard let recovery else {
      return StrainTarget(
        label: "BASELINE",
        minimum: 10,
        maximum: 14,
        color: Color(red: 0.55, green: 0.85, blue: 1.0),
        encouragement: "ease into the day.",
        guidance: "Without recovery context, baseline moderate target applies."
      )
    }
    if recovery >= 67 {
      return StrainTarget(
        label: "PUSH",
        minimum: 14,
        maximum: 18,
        color: Color(red: 0.18, green: 0.88, blue: 0.66),
        encouragement: "your body's ready for hard work.",
        guidance: "Recovery is green — high strain is well tolerated today."
      )
    }
    if recovery >= 34 {
      return StrainTarget(
        label: "MODERATE",
        minimum: 10,
        maximum: 14,
        color: Color(red: 1.0, green: 0.88, blue: 0.40),
        encouragement: "stay aerobic, avoid all-out efforts.",
        guidance: "Recovery is yellow — moderate aerobic work is the sweet spot."
      )
    }
    return StrainTarget(
      label: "RECOVERY",
      minimum: 6,
      maximum: 10,
      color: Color(red: 1.0, green: 0.37, blue: 0.42),
      encouragement: "active recovery, mobility, walk.",
      guidance: "Recovery is red — keep effort low and prioritize sleep."
    )
  }
}
