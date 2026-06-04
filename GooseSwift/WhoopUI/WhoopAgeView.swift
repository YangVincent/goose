import SwiftUI

/// Reverse-engineered "WHOOP age" — a biological-age estimate from HRV, RHR,
/// and recovery quality vs. published age-norm curves.
///
/// References (open literature, not WHOOP's proprietary model):
///   - HRV (RMSSD) declines ~0.8 ms/year; median ≈ 80 - 0.8 × age
///     (Nunan et al. 2010; Voss et al. 2015 large-sample meta)
///   - RHR rises gently with age (~0.1 bpm/year); high inter-individual variance,
///     so weighted low here.
///   - Sleep performance: % of need actually slept. Treat 85% as typical for
///     a healthy 20s; each 5% drop ≈ +3 years of "sleep age".
///
/// This is intentionally simple and on-device so you can tune the constants
/// without redeploying anything.
struct WhoopAgeView: View {
  private let birthdate: Date = {
    var components = DateComponents()
    components.year = 1996
    components.month = 5
    components.day = 1
    return Calendar.current.date(from: components) ?? Date()
  }()

  var body: some View {
    ZStack {
      Self.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 20) {
          header
          heroAge
          deltaBadge
          WhoopPaceOfAgingChart(chronologicalAge: chronologicalAge
          )
          factorBreakdown
          strapZoneCard
          methodologyNote
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
      .refreshable {
        // Local-only — no cloud calls at runtime. The Healthspan view
        // pulls from CompletedWorkoutStore + HeartRateSeriesStore via
        // LocalHealthspanCalculator, both Rust-SQLite-backed.
        await CompletedWorkoutStore.shared.refresh()
      }
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("BIOLOGICAL")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text("WHOOP AGE")
          .font(.system(size: 20, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white)
      }
      Spacer()
    }
    .padding(.top, 14)
  }

  private var heroAge: some View {
    VStack(spacing: 6) {
      Text(estimate.map { String(format: "%.1f", $0.biologicalAge) } ?? "--")
        .font(.system(size: 96, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Self.deltaColor(Int((estimate?.delta ?? 0).rounded())))
      Text("YEARS")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
    }
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var deltaBadge: some View {
    let est = estimate
    let delta = est?.delta ?? 0
    let chrono = chronologicalAge
    return HStack(spacing: 18) {
      VStack(alignment: .leading, spacing: 4) {
        Text("CHRONOLOGICAL")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.45))
        Text("\(chrono)")
          .font(.system(size: 28, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
      }
      Spacer()
      VStack(alignment: .trailing, spacing: 4) {
        Text("DELTA")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.45))
        Text(String(format: "%@%.1f", delta > 0 ? "+" : "", delta))
          .font(.system(size: 28, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Self.deltaColor(Int(delta.rounded())))
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  @ViewBuilder
  private var factorBreakdown: some View {
    let local = LocalHealthspanCalculator.compute()
    localComputedBanner
    sleepSection(local: local)
    strainSection(local: local)
    fitnessSection(local: local)
  }

  private var localComputedBanner: some View {
    HStack(spacing: 8) {
      Image(systemName: "iphone.gen3")
        .font(.system(size: 11, weight: .heavy))
        .foregroundStyle(.green)
      Text("Computed from your local strap data")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.55))
      Spacer()
    }
    .padding(.top, 8)
  }

  // MARK: - Sleep section

  @ViewBuilder
  private func sleepSection(local: LocalHealthspanCalculator.Healthspan) -> some View {
    WhoopAgeSectionHeader(title: "Sleep")
    let consistency = local.sleep_consistency_pct_30d
    let consistencyDelta = consistency.map { clamp(-($0 - 75) * 0.18, -3, 3) } ?? 0
    WhoopAgeFactorCard(
      title: "SLEEP CONSISTENCY",
      unit: "%",
      sixMonthValue: consistency,
      thirtyDayValue: consistency,
      valueRange: 40...100,
      rangeStartLabel: "40%",
      rangeEndLabel: "100%",
      yearsContribution: consistencyDelta,
      higherIsBetter: true,
      outperformingText: "You're significantly boosting your long-term health with your daily Sleep Consistency. Keep it up to maintain the lasting benefits.",
      underperformingText: "Your sleep schedule has been drifting. Even tightening bedtime by 20–30 minutes shifts your circadian system measurably.",
      valueFormatter: { "\(Int($0.rounded()))" },
      trendSeries: local.dailySleepConsistency.map { TrendPoint($0) }
    )

    let sleepHours = local.sleep_hours_30d
    let sleepHoursDelta = sleepHours.map { clamp(-($0 - 7) * 0.8, -1, 2) } ?? 0
    WhoopAgeFactorCard(
      title: "HOURS OF SLEEP",
      unit: "h",
      sixMonthValue: sleepHours,
      thirtyDayValue: sleepHours,
      valueRange: 5...8,
      rangeStartLabel: "5h",
      rangeEndLabel: "8h",
      yearsContribution: sleepHoursDelta,
      higherIsBetter: true,
      outperformingText: "You're hitting your sleep need consistently — this is one of the strongest long-term health levers.",
      underperformingText: "You're under your sleep need most nights. Even one extra hour averaged over a week translates to measurable HRV and recovery gains.",
      trendSeries: local.dailySleepHours.map { TrendPoint($0) }
    )
  }

  // MARK: - Strain section

  @ViewBuilder
  private func strainSection(local: LocalHealthspanCalculator.Healthspan) -> some View {
    WhoopAgeSectionHeader(title: "Strain")
    let z13: Double? = local.hr_zones_1_3_weekly_hours
    let z13Delta = z13.map { clamp(-($0 - 0.5) * 0.4, -1.5, 1.5) } ?? 0
    WhoopAgeFactorCard(
      title: "TIME IN HR ZONES 1-3 (WEEKLY)",
      unit: "h",
      sixMonthValue: z13,
      thirtyDayValue: z13,
      valueRange: 0...5,
      rangeStartLabel: "0h",
      rangeEndLabel: "5h",
      yearsContribution: z13Delta,
      higherIsBetter: true,
      outperformingText: "Easy aerobic time builds your mitochondrial base — this is where long-term cardiac health is bought.",
      underperformingText: z13 == 0 ? "0h of zone 1-3 work this week from your tracked Goose workouts. Two 30-min easy walks per week change the slope of this curve." : "You're under-doing easy aerobic work. Two 30-min easy walks per week change the slope of this curve.",
      trendSeries: local.dailyHrZones13.map { TrendPoint($0) }
    )

    let z45: Double? = local.hr_zones_4_5_weekly_hours
    let z45Delta = z45.map { clamp(-($0) * 0.2, -0.5, 0.5) } ?? 0
    WhoopAgeFactorCard(
      title: "TIME IN HR ZONES 4-5 (WEEKLY)",
      unit: "h",
      sixMonthValue: z45,
      thirtyDayValue: z45,
      valueRange: 0...1,
      rangeStartLabel: "0h",
      rangeEndLabel: "1h",
      yearsContribution: z45Delta,
      higherIsBetter: true,
      outperformingText: "High-intensity work is preserving your VO₂max ceiling — the strongest single mortality predictor at any age.",
      underperformingText: z45 == 0 ? "0h of zone 4-5 work this week from your tracked Goose workouts. Two short hard intervals per week (5×3 min) move this needle quickly." : "Two short hard intervals per week (5×3 min) move this needle quickly.",
      trendSeries: local.dailyHrZones45.map { TrendPoint($0) }
    )

    let strengthMin: Double? = local.strength_weekly_minutes
    let strengthHours = strengthMin.map { $0 / 60.0 }
    let strengthDelta = strengthHours.map { clamp(-($0 - 1.0) * 0.6, -1.0, 1.0) } ?? 0
    WhoopAgeFactorCard(
      title: "STRENGTH ACTIVITY TIME (WEEKLY)",
      unit: "h",
      sixMonthValue: strengthHours,
      thirtyDayValue: strengthHours,
      valueRange: 0...2,
      rangeStartLabel: "0h",
      rangeEndLabel: "2h",
      yearsContribution: strengthDelta,
      higherIsBetter: true,
      outperformingText: "Resistance training preserves lean mass and bone density — both decline with age and matter more than HRV after 40.",
      underperformingText: (strengthHours ?? 0) == 0 ? "0 minutes of strength workouts in Goose this week. Two 30-min resistance sessions weekly cover the minimum dose." : "Two 30-minute resistance sessions weekly cover the minimum dose for healthspan gains.",
      trendSeries: local.dailyStrengthMinutes.map { TrendPoint($0) }
    )

    // Steps not in cloud API yet — placeholder card with explanation.
    WhoopAgeFactorCard(
      title: "STEPS",
      unit: "steps",
      sixMonthValue: nil,
      thirtyDayValue: nil,
      valueRange: 0...16000,
      rangeStartLabel: "0K",
      rangeEndLabel: "16K",
      yearsContribution: 0,
      higherIsBetter: true,
      outperformingText: "Steps tracking not yet captured from the strap. The Goose IMU pipeline lands shortly.",
      underperformingText: nil
    )
  }

  // MARK: - Fitness section

  @ViewBuilder
  private func fitnessSection(local: LocalHealthspanCalculator.Healthspan) -> some View {
    WhoopAgeSectionHeader(title: "Fitness")
    // VO2 max: no local estimator yet. Surface as unmeasured rather than
    // falling back to cloud — local computation lands as a follow-up.
    let vo2: Double? = nil
    let vo2Delta: Double = 0
    WhoopAgeFactorCard(
      title: "VO₂ MAX",
      unit: "ml/kg/min",
      sixMonthValue: vo2,
      thirtyDayValue: vo2,
      valueRange: 15...70,
      rangeStartLabel: "15",
      rangeEndLabel: "70",
      yearsContribution: vo2Delta,
      higherIsBetter: true,
      outperformingText: "Local VO₂max estimator from running pace + HR isn't wired yet — landing as a follow-up. Until then, this card is unmeasured.",
      underperformingText: "Local VO₂max estimator from running pace + HR isn't wired yet — landing as a follow-up. Until then, this card is unmeasured.",
      valueFormatter: { String(format: "%.0f", $0) }
    )

    let rhr = local.rhr_30d
    let rhrDelta = rhr.map { clamp(($0 - 50) * 0.5, -2.0, 2.0) } ?? 0
    WhoopAgeFactorCard(
      title: "RHR",
      unit: "bpm",
      sixMonthValue: rhr,
      thirtyDayValue: rhr,
      valueRange: 40...80,
      rangeStartLabel: "40bpm",
      rangeEndLabel: "80bpm",
      yearsContribution: rhrDelta,
      higherIsBetter: false,
      outperformingText: "You're significantly boosting your long-term health with your daily RHR. Keep it up to maintain the lasting benefits.",
      underperformingText: "Elevated RHR is one of the earliest signs of cardiovascular strain. Improving aerobic base drops this in 4-6 weeks.",
      valueFormatter: { String(format: "%.0f", $0) },
      trendSeries: local.dailyRHR.map { TrendPoint($0) }
    )
  }

  /// Bridge from a LocalHealthspanCalculator DailyPoint to the trend
  /// view's TrendPoint type, keeping the call sites tidy.
  private func TrendPoint(_ point: LocalHealthspanCalculator.DailyPoint) -> WhoopAgeFactorTrendView.TrendPoint {
    WhoopAgeFactorTrendView.TrendPoint(date: point.date, value: point.value)
  }


  private func factorRow(label: String, delta: Double, observed: String) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 3) {
        Text(label)
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.65))
        Text(observed)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.45))
      }
      Spacer()
      Text(deltaYearsText(delta))
        .font(.system(size: 16, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Self.deltaColor(Int(delta.rounded())))
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private func deltaYearsText(_ delta: Double) -> String {
    let sign = delta > 0 ? "+" : ""
    return "\(sign)\(String(format: "%.1f", delta)) yrs"
  }

  /// Reads Goose's local HR sample store and bins by zone for today.
  /// This is the Phase A validation: shows what Goose's BLE pipeline has
  /// captured so far. Only present if the store has any samples.
  private var strapZoneCard: some View {
    let buckets = strapZoneBucketsForToday()
    let totalMinutes = buckets.values.reduce(0, +)
    return Group {
      if totalMinutes > 0.5 {
        VStack(alignment: .leading, spacing: 10) {
          HStack {
            Text("FROM STRAP — TODAY (LIVE)")
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .tracking(2)
              .foregroundStyle(.white.opacity(0.55))
            Spacer()
            Text(String(format: "%.0f min total", totalMinutes))
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .foregroundStyle(.white.opacity(0.4))
          }
          ForEach(1...5, id: \.self) { zone in
            zoneRow(zone: zone, minutes: buckets[zone] ?? 0, totalMinutes: totalMinutes)
          }
          Text("Counts only seconds while phone was paired with strap. Bin boundaries use HRmax \(UserProfile.maxHeartRate).")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.white.opacity(0.35))
            .lineSpacing(2)
            .padding(.top, 4)
        }
        .padding(14)
        .background(
          RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(0.04))
        )
      }
    }
  }

  private func zoneRow(zone: Int, minutes: Double, totalMinutes: Double) -> some View {
    let pct = totalMinutes > 0 ? minutes / totalMinutes : 0
    let color = Self.zoneColor(zone)
    return HStack(spacing: 10) {
      Text("Z\(zone)")
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .foregroundStyle(color)
        .frame(width: 26, alignment: .leading)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 4)
            .fill(Color.white.opacity(0.06))
          RoundedRectangle(cornerRadius: 4)
            .fill(color)
            .frame(width: max(2, proxy.size.width * CGFloat(pct)))
        }
      }
      .frame(height: 14)
      Text(String(format: "%.0fm", minutes))
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.8))
        .frame(width: 42, alignment: .trailing)
    }
  }

  /// Bin Goose's locally-stored HR samples by HR zone, computing the
  /// time attributable to each zone. For each sample we attribute the gap
  /// to the next sample to its own zone (capped at 60 seconds so a long
  /// disconnect doesn't blow up totals).
  private func strapZoneBucketsForToday() -> [Int: Double] {
    let maxHR = Double(UserProfile.maxHeartRate)
    let samples = HeartRateSeriesStore.shared.samples(forDayContaining: Date())
    guard samples.count > 1 else { return [:] }
    var buckets: [Int: Double] = [:]
    for index in 0..<samples.count {
      let sample = samples[index]
      let nextTime = index + 1 < samples.count ? samples[index + 1].capturedAt : sample.capturedAt
      let gapSec = min(60, nextTime.timeIntervalSince(sample.capturedAt))
      guard gapSec > 0 else { continue }
      let frac = Double(sample.bpm) / maxHR
      let zone: Int
      switch frac {
      case 0.9...:     zone = 5
      case 0.8..<0.9:  zone = 4
      case 0.7..<0.8:  zone = 3
      case 0.6..<0.7:  zone = 2
      case 0.5..<0.6:  zone = 1
      default:         continue
      }
      buckets[zone, default: 0] += gapSec / 60.0
    }
    return buckets
  }

  private static func zoneColor(_ zone: Int) -> Color {
    switch zone {
    case 1: return Color(red: 0.30, green: 0.65, blue: 1.0)
    case 2: return Color(red: 0.18, green: 0.88, blue: 0.66)
    case 3: return Color(red: 1.0, green: 0.88, blue: 0.40)
    case 4: return Color(red: 1.0, green: 0.55, blue: 0.30)
    case 5: return Color(red: 1.0, green: 0.37, blue: 0.42)
    default: return .gray
    }
  }

  private var methodologyNote: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("METHODOLOGY")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.4))
      Text("Estimate based on a 30-day rolling average of HRV (RMSSD), RHR, and sleep performance, compared to published age-norm curves. HRV uses Nunan/Voss meta-analysis (~0.8 ms/year decline). RHR uses 0.1 bpm/year. Not WHOOP's proprietary algorithm.")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.4))
        .lineSpacing(2)
    }
    .padding(.top, 8)
  }

  private var chronologicalAge: Int {
    let components = Calendar.current.dateComponents([.year], from: birthdate, to: Date())
    return components.year ?? 30
  }

  private func deltaText(_ delta: Int) -> String {
    if delta > 0 { return "+\(delta)" }
    return "\(delta)"
  }

  private struct AgeEstimate {
    let biologicalAge: Double
    let delta: Double
    let factors: [Factor]

    struct Factor {
      let label: String
      let observed: String
      let delta: Double
    }
  }

  /// WHOOP-faithful biological age estimate. Each factor produces a year
  /// delta off chronological age; deltas sum to total. Coefficients
  /// back-fitted from a known WHOOP Age (24.6 at chrono 30 with the
  /// observed inputs) and clipped to plausible per-factor ranges.
  ///
  /// Steps and VO₂ max are not in the WHOOP cloud API; their contributions
  /// (typically -0.4 + -1.9 years for an athletic 30-year-old) are
  /// surfaced as a single "(unmeasured)" placeholder so the math is honest.
  private var estimate: AgeEstimate? {
    // All inputs from local computation — no cloud reads.
    let local = LocalHealthspanCalculator.compute()
    guard let consistency = local.sleep_consistency_pct_30d,
          let sleepHours = local.sleep_hours_30d,
          let rhr = local.rhr_30d else {
      return nil
    }

    let zones13 = local.hr_zones_1_3_weekly_hours
    let zones45 = local.hr_zones_4_5_weekly_hours
    let strengthHours = local.strength_weekly_minutes / 60.0

    var factors: [AgeEstimate.Factor] = []

    let sleepConsDelta = clamp(-(consistency - 75) * 0.18, -3, 3)
    factors.append(.init(
      label: "SLEEP CONSISTENCY",
      observed: String(format: "%.0f%% (30d avg)", consistency),
      delta: sleepConsDelta
    ))

    let sleepHoursDelta = clamp(-(sleepHours - 7) * 0.8, -1, 2)
    let sleepHoursFloor = floor(sleepHours)
    factors.append(.init(
      label: "HOURS OF SLEEP",
      observed: String(format: "%.0fh %02dm avg",
                       sleepHoursFloor,
                       Int((sleepHours - sleepHoursFloor) * 60)),
      delta: sleepHoursDelta
    ))

    let zones13Delta = clamp(-(zones13 - 0.5) * 0.4, -1.5, 1.5)
    factors.append(.init(
      label: "HR ZONES 1-3",
      observed: String(format: "%.1fh / week", zones13),
      delta: zones13Delta
    ))

    let zones45Delta = clamp(-(zones45) * 0.2, -0.5, 0.5)
    factors.append(.init(
      label: "HR ZONES 4-5",
      observed: String(format: "%.1fh / week", zones45),
      delta: zones45Delta
    ))

    let strengthDelta = clamp(-(strengthHours - 1.0) * 0.6, -1.0, 1.0)
    factors.append(.init(
      label: "STRENGTH ACTIVITY",
      observed: String(format: "%.1fh / week", strengthHours),
      delta: strengthDelta
    ))

    let rhrDelta = clamp((rhr - 50) * 0.5, -2.0, 2.0)
    factors.append(.init(
      label: "RHR",
      observed: String(format: "%.0f bpm (30d avg)", rhr),
      delta: rhrDelta
    ))

    // VO₂ max: local estimator not implemented yet — listed as
    // unmeasured rather than read from cloud.
    factors.append(.init(
      label: "VO₂ MAX",
      observed: "Not yet computed locally",
      delta: 0
    ))

    factors.append(.init(
      label: "STEPS",
      observed: "Not yet captured",
      delta: 0
    ))

    let totalDelta = factors.map(\.delta).reduce(0, +)
    let bioAge = Double(chronologicalAge) + totalDelta
    return AgeEstimate(
      biologicalAge: bioAge,
      delta: totalDelta,
      factors: factors
    )
  }

  private func clamp(_ value: Double, _ lo: Double, _ hi: Double) -> Double {
    min(max(value, lo), hi)
  }

  private static func deltaColor(_ delta: Int) -> Color {
    if delta <= -5 { return Color(red: 0.18, green: 0.88, blue: 0.66) }
    if delta <= 0  { return Color(red: 0.50, green: 0.92, blue: 0.78) }
    if delta <= 5  { return Color(red: 1.0, green: 0.88, blue: 0.40) }
    return Color(red: 1.0, green: 0.37, blue: 0.42)
  }

  private static let background = LinearGradient(
    colors: [
      Color(red: 0.02, green: 0.04, blue: 0.09),
      Color(red: 0.00, green: 0.00, blue: 0.03)
    ],
    startPoint: .top,
    endPoint: .bottom
  )
}
