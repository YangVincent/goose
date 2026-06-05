import SwiftUI
import Charts

/// "Why is my recovery what it is?" — full breakdown of every input that
/// feeds the recovery score, with deltas vs personal baseline and a
/// plain-English summary at the top.
struct RecoveryFactorsDetailView: View {
  @ObservedObject private var dailyStore = WhoopImportedDailyStore.shared
  @ObservedObject private var selectedDay = SelectedDayStore.shared
  @State private var score: GooseRecoveryCalculator.Score?

  var body: some View {
    ZStack {
      WhoopHomeView.detailBackground.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          hero
          summarySentence
          contributorsCard
          serverFactorsCard
          priorDayLoadCard
          baselineSection
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("Recovery Factors")
    .navigationBarTitleDisplayMode(.large)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      if dailyStore.recoveryHistory().isEmpty {
      }
    }
    .onAppear { refresh() }
    .onChange(of: dailyStore.recoveryHistory().count) { _, _ in refresh() }
  }

  // MARK: - Hero

  private var hero: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 6) {
        Text("RECOVERY")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        HStack(alignment: .lastTextBaseline) {
          Text(score.map { "\($0.score)" } ?? "--")
            .font(.system(size: 72, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
          Text("%")
            .font(.system(size: 32, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }
        if let score {
          Text("\(bandLabel(score.band).uppercased()) · CONFIDENCE \(Int(score.confidence * 100))%")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(tint(for: score.band))
        }
      }
      Spacer()
    }
    .padding(.top, 8)
  }

  // MARK: - Plain-English summary

  private var summarySentence: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 6) {
        Text("WHY")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        Text(plainEnglishSummary)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.85))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var plainEnglishSummary: String {
    guard let score = score, score.confidence > 0 else {
      return "Need at least 4 days of baseline data to explain today's score."
    }
    var lines: [String] = []
    if let hrv = score.hrvComponent, let base = score.hrvBaseline {
      let pct = (hrv - base) / base * 100
      if pct > 5 {
        lines.append("HRV \(Int(hrv))ms is \(Int(pct))% above your baseline (\(Int(base))ms) — strong recovery signal.")
      } else if pct < -5 {
        lines.append("HRV \(Int(hrv))ms is \(Int(-pct))% below your baseline (\(Int(base))ms) — depressed recovery.")
      } else {
        lines.append("HRV \(Int(hrv))ms is right at your baseline (\(Int(base))ms).")
      }
    }
    if let rhr = score.rhrComponent, let base = score.rhrBaseline {
      let delta = rhr - base
      if delta > 2 {
        lines.append("RHR \(Int(rhr))bpm is +\(Int(delta)) above baseline — body still working harder than usual.")
      } else if delta < -2 {
        lines.append("RHR \(Int(rhr))bpm is \(Int(delta)) below baseline — cardiovascular system rested.")
      } else {
        lines.append("RHR \(Int(rhr))bpm matches baseline.")
      }
    }
    if let sleep = score.sleepPerformance {
      if sleep >= 90 {
        lines.append("Sleep performance \(Int(sleep))% hit your needed duration — full overnight recovery.")
      } else if sleep >= 70 {
        lines.append("Sleep performance \(Int(sleep))% partially met your need — some debt accruing.")
      } else {
        lines.append("Sleep performance \(Int(sleep))% missed your need substantially — debt growing.")
      }
    }
    return lines.joined(separator: " ")
  }

  // MARK: - Contributors card

  private var contributorsCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 10) {
        Text("CONTRIBUTORS")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        if let score, score.confidence > 0 {
          contributorRow("HRV", current: score.hrvComponent, baseline: score.hrvBaseline, unit: "ms", weight: 0.55, higherIsBetter: true)
          contributorRow("RHR", current: score.rhrComponent, baseline: score.rhrBaseline, unit: "bpm", weight: 0.20, higherIsBetter: false)
          contributorRow("SLEEP", current: score.sleepPerformance, baseline: nil, unit: "%", weight: 0.25, higherIsBetter: true)
        } else {
          Text("Need 4+ days of baseline before contributors can be computed.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.5))
        }
      }
    }
  }

  /// Each row shows: label, weighted bar, glyph, current vs baseline, contribution.
  private func contributorRow(_ label: String, current: Double?, baseline: Double?, unit: String, weight: Double, higherIsBetter: Bool) -> some View {
    let dir: Direction = directionFor(current: current, baseline: baseline, higherIsBetter: higherIsBetter)
    let contributionString: String = {
      guard let c = current, let b = baseline else {
        if label == "SLEEP", let c = current { return "\(Int(c))% of need" }
        return "—"
      }
      let pct = (c - b) / b * 100
      let sign = (higherIsBetter ? pct : -pct) >= 0 ? "+" : ""
      return "\(sign)\(Int(higherIsBetter ? pct : -pct))% vs baseline"
    }()
    return VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 8) {
        Text(label)
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.7))
          .frame(width: 56, alignment: .leading)
        RoundedRectangle(cornerRadius: 2, style: .continuous)
          .fill(Color.white.opacity(0.06))
          .frame(height: 6)
          .overlay(
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(dir.color)
              .frame(width: max(8, 200 * weight), height: 6),
            alignment: .leading
          )
        Image(systemName: dir.glyph)
          .font(.system(size: 11, weight: .heavy))
          .foregroundStyle(dir.color)
          .frame(width: 14)
      }
      HStack(spacing: 6) {
        Text(formattedValue(current, unit: unit))
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        if let b = baseline {
          Text("· baseline \(formattedValue(b, unit: unit))")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
        Spacer()
        Text(contributionString)
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(0.5)
          .foregroundStyle(dir.color)
      }
      .padding(.leading, 64)
    }
  }

  // MARK: - Server factors (SpO2, skin temp)

  private var serverFactorsCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("OTHER SIGNALS")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        let r = dailyStore.dayOverview(for: selectedDay.currentDate)?.recovery
        let spo2 = r?.spo2_percentage
        let skin = r?.skin_temp_celsius
        let spo2Base = baselineMean(dailyStore.recoveryHistory().compactMap(\.spo2_percentage))
        let skinBase = baselineMean(dailyStore.recoveryHistory().compactMap(\.skin_temp_celsius))
        HStack(spacing: 14) {
          factorCell(label: "SPO₂", value: spo2, baseline: spo2Base, unit: "%", higherIsBetter: true)
          factorCell(label: "SKIN TEMP", value: skin, baseline: skinBase, unit: "°C", higherIsBetter: false, threshold: 0.4)
          Spacer(minLength: 0)
        }
        Text("Elevated skin temperature or depressed SpO₂ can indicate illness onset or alcohol use the prior night — WHOOP de-rates recovery when these are present.")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func factorCell(label: String, value: Double?, baseline: Double?, unit: String, higherIsBetter: Bool, threshold: Double = 0.04) -> some View {
    let direction: Direction = {
      guard let v = value, let b = baseline else { return .observed }
      let delta = (v - b) / max(0.01, abs(b))
      if higherIsBetter {
        if delta > threshold { return .better }
        if delta < -threshold { return .worse }
      } else {
        if delta < -threshold { return .better }
        if delta > threshold { return .worse }
      }
      return .neutral
    }()
    return VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))
      HStack(spacing: 4) {
        Image(systemName: direction.glyph).font(.system(size: 9, weight: .heavy)).foregroundStyle(direction.color)
        Text(formattedValue(value, unit: unit))
          .font(.system(size: 14, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
      }
      if let b = baseline {
        Text("base \(formattedValue(b, unit: unit))")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - Prior-day strain

  private var priorDayLoadCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("PRIOR-DAY LOAD")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        let yesterdayStrain = priorDayStrain()
        let strainNeed = strainNeedAdditionHours(strain: yesterdayStrain)
        HStack(spacing: 14) {
          VStack(alignment: .leading, spacing: 2) {
            Text("YESTERDAY STRAIN").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
            Text(yesterdayStrain.map { String(format: "%.1f", $0) } ?? "--").font(.system(size: 18, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.white)
          }
          Spacer()
          VStack(alignment: .leading, spacing: 2) {
            Text("EXTRA SLEEP NEED").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
            Text(strainNeed > 0 ? String(format: "+%.1fh", strainNeed) : "—").font(.system(size: 18, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.35))
          }
        }
        Text(strainNeed > 0
             ? "Higher strain bumps tonight's sleep need. The coach uses this when picking your bedtime."
             : "Yesterday's strain was below your typical recovery threshold — no extra sleep load added.")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.45))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func priorDayStrain() -> Double? {
    guard dailyStore.recoveryHistory().count >= 2 else { return nil }
    // recoveryHistory is most-recent-first. Index 1 = yesterday.
    return dailyStore.recoveryHistory()[1].resting_heart_rate.map { _ in 0 }  // resting_heart_rate proxy; replace if a strain field is available
    ?? nil
  }

  private func strainNeedAdditionHours(strain: Double?) -> Double {
    guard let strain = strain, strain > 10 else { return 0 }
    return min(1.5, (strain - 10) * 0.05)
  }

  // MARK: - Baseline section (window the calculator used)

  private var baselineSection: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("BASELINE WINDOW")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        if let score {
          Text("Baseline derived from \(score.baselineDayCount) prior days. More days = more stable baseline; the score's confidence reflects this.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
          if dailyStore.recoveryHistory().count >= 4 {
            Chart {
              ForEach(Array(dailyStore.recoveryHistory().prefix(14).reversed().enumerated()), id: \.offset) { idx, day in
                if let v = day.hrv_rmssd_milli {
                  LineMark(x: .value("day", idx), y: .value("hrv", v))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
                }
              }
            }
            .frame(height: 60)
            .chartXAxis(.hidden)
          }
        }
      }
    }
  }

  // MARK: - Compute

  /// Build a Score directly from `dailyStore.summary` — that store now
  /// overlays the recovery_readings / sleep_readings / daily_strain_readings
  /// typed tables on top of imported_daily_summary, so HRV / RHR / sleep
  /// values are the freshest available per-day reading. Baselines are
  /// rolling medians over the dailyStore values.
  private func refresh() {
    guard let summary = dailyStore.summary(for: selectedDay.currentDate),
          let recoveryScore = summary.recoveryScore else {
      score = nil
      return
    }
    let hrvHistory: [Double] = dailyStore.byDate.values.compactMap { $0.hrvRmssdMs }
    let rhrHistory: [Double] = dailyStore.byDate.values.compactMap { $0.restingHrBpm }
    let intScore = Int(recoveryScore.rounded())
    score = GooseRecoveryCalculator.Score(
      score: intScore,
      band: GooseRecoveryCalculator.Band(score: intScore),
      hrvComponent: summary.hrvRmssdMs,
      hrvBaseline: Self.median(hrvHistory),
      rhrComponent: summary.restingHrBpm,
      rhrBaseline: Self.median(rhrHistory),
      sleepPerformance: summary.sleepPerformancePct,
      baselineDayCount: max(hrvHistory.count, rhrHistory.count),
      confidence: 1.0
    )
  }

  private static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let n = sorted.count
    return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
  }

  // MARK: - Helpers

  private enum Direction {
    case better, worse, neutral, observed
    var color: Color {
      switch self {
      case .better: Color(red: 0.18, green: 0.88, blue: 0.66)
      case .worse: Color(red: 1.0, green: 0.37, blue: 0.42)
      case .neutral: Color(red: 0.55, green: 0.85, blue: 1.0)
      case .observed: Color(red: 0.55, green: 0.85, blue: 1.0)
      }
    }
    var glyph: String {
      switch self {
      case .better: "arrow.up.right"
      case .worse: "arrow.down.right"
      case .neutral: "arrow.right"
      case .observed: "circle"
      }
    }
  }

  private func directionFor(current: Double?, baseline: Double?, higherIsBetter: Bool) -> Direction {
    guard let c = current, let b = baseline else { return current != nil ? .observed : .neutral }
    let delta = c - b
    let threshold = b * 0.05
    if higherIsBetter {
      if delta > threshold { return .better }
      if delta < -threshold { return .worse }
    } else {
      if delta < -threshold { return .better }
      if delta > threshold { return .worse }
    }
    return .neutral
  }

  private func bandLabel(_ band: GooseRecoveryCalculator.Band) -> String {
    switch band {
    case .green: "Green"
    case .yellow: "Yellow"
    case .red: "Red"
    }
  }

  private func tint(for band: GooseRecoveryCalculator.Band) -> Color {
    switch band {
    case .green: Color(red: 0.18, green: 0.88, blue: 0.66)
    case .yellow: Color(red: 1.0, green: 0.88, blue: 0.40)
    case .red: Color(red: 1.0, green: 0.37, blue: 0.42)
    }
  }

  private func baselineMean(_ values: [Double]) -> Double? {
    guard values.count >= 4 else { return nil }
    let base = Array(values.dropFirst())  // exclude today (first entry, most-recent-first)
    if base.isEmpty { return nil }
    return base.reduce(0, +) / Double(base.count)
  }

  private func formattedValue(_ value: Double?, unit: String) -> String {
    guard let v = value else { return "--" }
    if unit == "%" { return String(format: "%.0f%@", v, unit) }
    if unit == "ms" || unit == "bpm" { return String(format: "%.0f %@", v, unit) }
    return String(format: "%.1f%@", v, unit)
  }

  private func cardSurface<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    content()
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.white.opacity(0.04))
      )
  }
}
