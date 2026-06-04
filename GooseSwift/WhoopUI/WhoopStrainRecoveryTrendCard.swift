import SwiftUI

/// Multi-day strain-vs-recovery comparison — WHOOP's flagship "are you
/// recovering at the rate you're training" view, on Home.
///
/// Recovery comes from `WhoopAPIClient.calendar` (server, daily).
/// Strain is computed locally from 1Hz HR samples via `DayStrainCalculator`
/// — server doesn't currently surface historical day strain, so we lean on
/// our own retention window (7 days).
///
/// Visualized as a stacked pair of bars per day: recovery on top (colored
/// by zone), strain on bottom (scaled to 0–21). A balanced day has both
/// bars short, an over-trained day has tall strain + short recovery.
struct WhoopStrainRecoveryTrendCard: View {
  @ObservedObject var client: WhoopAPIClient
  @State private var days: [DaySnapshot] = []

  struct DaySnapshot: Identifiable {
    let id: String  // iso date
    let recoveryScore: Int?
    let strain: Double?
    let date: Date
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      if days.isEmpty {
        loadingState
      } else {
        chartRow

        legendRow

        balanceLine
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .onAppear { refresh() }
    .onChange(of: client.calendar?.month ?? "") { _, _ in refresh() }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("LAST 7 DAYS")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text("STRAIN vs RECOVERY")
          .font(.system(size: 16, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
      }
      Spacer()
    }
  }

  private var loadingState: some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.bar.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white.opacity(0.3))
      Text("Loading…")
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.4))
      Spacer()
    }
  }

  private var chartRow: some View {
    HStack(alignment: .bottom, spacing: 6) {
      ForEach(days) { day in
        dayColumn(day)
      }
    }
    .frame(height: 110)
  }

  private func dayColumn(_ day: DaySnapshot) -> some View {
    let recoveryHeight = (day.recoveryScore.map { Double($0) } ?? 0) / 100.0
    let strainHeight = (day.strain ?? 0) / 21.0
    let recoveryColor = recoveryColor(forPercent: day.recoveryScore)
    return VStack(spacing: 2) {
      ZStack(alignment: .bottom) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Color.white.opacity(0.06))
          .frame(width: 22, height: 50)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(recoveryColor.opacity(day.recoveryScore == nil ? 0.18 : 0.9))
          .frame(width: 22, height: max(2, 50 * recoveryHeight))
      }
      ZStack(alignment: .top) {
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Color.white.opacity(0.06))
          .frame(width: 22, height: 50)
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(Self.strainColor.opacity(day.strain == nil ? 0.18 : 0.9))
          .frame(width: 22, height: max(2, 50 * strainHeight))
      }
      Text(Self.weekdayLabel(day.date))
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.5))
    }
    .frame(maxWidth: .infinity)
  }

  private var legendRow: some View {
    HStack(spacing: 14) {
      legendItem(label: "RECOVERY", color: Color(red: 0.18, green: 0.88, blue: 0.66))
      legendItem(label: "STRAIN", color: Self.strainColor)
      Spacer()
    }
  }

  private func legendItem(label: String, color: Color) -> some View {
    HStack(spacing: 5) {
      RoundedRectangle(cornerRadius: 2, style: .continuous)
        .fill(color)
        .frame(width: 8, height: 8)
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.55))
    }
  }

  /// Quick "is the user over- or under-trained" hint based on the last 7 days.
  private var balanceLine: some View {
    let validDays = days.compactMap { day -> (Int, Double)? in
      guard let recovery = day.recoveryScore, let strain = day.strain, strain > 0 else { return nil }
      return (recovery, strain)
    }
    let label: String
    let color: Color
    if validDays.count < 3 {
      label = "NOT ENOUGH DATA YET"
      color = .white.opacity(0.4)
    } else {
      let avgRecovery = validDays.reduce(0) { $0 + $1.0 } / validDays.count
      let avgStrain = validDays.reduce(0.0) { $0 + $1.1 } / Double(validDays.count)
      if avgStrain > 12 && avgRecovery < 50 {
        label = "OVERTRAINING SIGNAL · STRAIN HIGH, RECOVERY LOW"
        color = Color(red: 1.0, green: 0.37, blue: 0.42)
      } else if avgStrain < 6 && avgRecovery > 70 {
        label = "UNDER-LOADED · RECOVERY OUTPACING STRAIN"
        color = Color(red: 0.18, green: 0.88, blue: 0.66)
      } else {
        label = "BALANCED · STRAIN MATCHES RECOVERY"
        color = Color(red: 0.55, green: 0.85, blue: 1.0)
      }
    }
    return Text(label)
      .font(.system(size: 9, weight: .heavy, design: .rounded))
      .tracking(1.2)
      .foregroundStyle(color)
  }

  // MARK: - Data assembly

  private func refresh() {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let dates: [Date] = (0..<7).reversed().compactMap {
      calendar.date(byAdding: .day, value: -$0, to: today)
    }
    days = dates.map { date in
      let iso = Self.isoDate(date)
      let recovery = client.recoveryScore(forISODate: iso).map { Int($0.rounded()) }
      let strain = computeLocalStrain(for: date)
      return DaySnapshot(id: iso, recoveryScore: recovery, strain: strain, date: date)
    }
  }

  private func computeLocalStrain(for date: Date) -> Double? {
    let samples = HeartRateSeriesStore.shared.samples(forDayContaining: date)
    guard samples.count >= 100 else { return nil }
    let off = SensorSampleStore.shared.offWristWindows()
    let day = DayStrainCalculator.computeDayStrain(
      samples: samples,
      offWristWindows: off,
      for: date
    )
    return day.sampleCount >= 100 ? day.strain : nil
  }

  // MARK: - Helpers

  private static func isoDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }

  private static func weekdayLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE"
    return formatter.string(from: date).uppercased()
  }

  private func recoveryColor(forPercent percent: Int?) -> Color {
    guard let percent else { return .white.opacity(0.3) }
    if percent >= 67 { return Color(red: 0.18, green: 0.88, blue: 0.66) }
    if percent >= 34 { return Color(red: 1.0, green: 0.88, blue: 0.40) }
    return Color(red: 1.0, green: 0.37, blue: 0.42)
  }

  private static let strainColor = Color(red: 0.55, green: 0.85, blue: 1.0)
}
