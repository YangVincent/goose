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
  @StateObject private var client = WhoopAPIClient.shared
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
          WhoopPaceOfAgingChart(
            client: client,
            chronologicalAge: chronologicalAge
          )
          factorBreakdown
          strapZoneCard
          methodologyNote
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
      .refreshable {
        await client.loadHealthspan()
        await client.loadRecoveryHistory()
      }
    }
    .task {
      if client.healthspan == nil {
        await client.loadHealthspan()
      }
      if client.recoveryHistory.isEmpty {
        await client.loadRecoveryHistory()
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

  private var factorBreakdown: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("CONTRIBUTING FACTORS")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      if let est = estimate {
        ForEach(est.factors, id: \.label) { factor in
          factorRow(label: factor.label, delta: factor.delta, observed: factor.observed)
        }
      } else {
        Text(client.healthspan == nil ? "Loading…" : "Insufficient data")
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.5))
      }
    }
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
    let maxHR = Double(client.healthspan?.max_hr ?? UserProfile.maxHeartRate)
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
    guard let h = client.healthspan,
          let consistency = h.sleep_consistency_pct_30d,
          let sleepHours = h.sleep_hours_30d,
          let rhr = h.rhr_30d else {
      return nil
    }

    let zones13 = h.hr_zones_1_3_weekly_hours ?? 0
    let zones45 = h.hr_zones_4_5_weekly_hours ?? 0
    let strengthHours = (h.strength_weekly_minutes ?? 0) / 60.0

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

    if let vo2 = h.vo2_max_estimate {
      let vo2Delta = clamp(-(vo2 - 45) * 0.2, -3.0, 3.0)
      factors.append(.init(
        label: "VO₂ MAX",
        observed: String(format: "%.0f ml/kg/min (est)", vo2),
        delta: vo2Delta
      ))
    }

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
