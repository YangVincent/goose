import SwiftUI
import Charts

enum WhoopMetric: Hashable, Identifiable {
  case recovery
  case sleep
  case strain

  var id: String { title }

  var title: String {
    switch self {
    case .recovery: return "Recovery"
    case .sleep:    return "Sleep"
    case .strain:   return "Strain"
    }
  }

  var tracking: String {
    switch self {
    case .recovery: return "RECOVERY"
    case .sleep:    return "SLEEP"
    case .strain:   return "STRAIN"
    }
  }
}

struct WhoopMetricDetailView: View {
  let metric: WhoopMetric
  @ObservedObject var client: WhoopAPIClient

  var body: some View {
    ZStack {
      WhoopHomeView.detailBackground.ignoresSafeArea()

      ScrollView {
        VStack(alignment: .leading, spacing: 22) {
          heroSection
          chartSection
          breakdownSection
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle(metric.title)
    .navigationBarTitleDisplayMode(.large)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      if client.recoveryHistory.isEmpty {
        await client.loadRecoveryHistory()
      }
    }
  }

  private var heroSection: some View {
    HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 6) {
        Text(metric.tracking)
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.6))
        Text(primaryValueText)
          .font(.system(size: 56, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text(primaryUnitText)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
      }
      Spacer()
    }
    .padding(.top, 8)
  }

  private var chartSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("LAST 14 DAYS")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))

      Chart(chartData) { point in
        BarMark(
          x: .value("Day", point.label),
          y: .value("Value", point.value),
          width: .ratio(0.55)
        )
        .foregroundStyle(barColor(for: point.value))
        .cornerRadius(3)
      }
      .frame(height: 160)
      .chartYScale(domain: chartYDomain)
      .chartXAxis {
        AxisMarks(values: .automatic(desiredCount: 7)) { _ in
          AxisValueLabel()
            .foregroundStyle(.white.opacity(0.4))
            .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
      }
      .chartYAxis {
        AxisMarks(position: .leading, values: yAxisValues) { _ in
          AxisGridLine().foregroundStyle(.white.opacity(0.05))
          AxisValueLabel()
            .foregroundStyle(.white.opacity(0.4))
            .font(.system(size: 9, weight: .semibold, design: .rounded))
        }
      }
    }
    .padding(18)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var breakdownSection: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("CONTEXT")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))

      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
        spacing: 12
      ) {
        ForEach(breakdownItems, id: \.0) { entry in
          contextTile(label: entry.0, value: entry.1)
        }
      }
    }
  }

  private func contextTile(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      Text(value)
        .font(.system(size: 18, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var primaryValueText: String {
    switch metric {
    case .recovery:
      let v = client.currentDay?.recovery?.recovery_score
      return v.map { "\(Int($0.rounded()))" } ?? "--"
    case .sleep:
      let v = client.currentDay?.sleep?.performance
      return v.map { "\(Int($0.rounded()))" } ?? "--"
    case .strain:
      let v = client.currentDay?.strain?.strain
      return v.map { String(format: "%.1f", $0) } ?? "--"
    }
  }

  private var primaryUnitText: String {
    switch metric {
    case .recovery: return "% recovered"
    case .sleep:    return "% performance"
    case .strain:   return "of 21 day strain"
    }
  }

  private var breakdownItems: [(String, String)] {
    switch metric {
    case .recovery:
      let r = client.currentDay?.recovery
      return [
        ("HRV",        format(r?.hrv_rmssd_milli, unit: "ms", digits: 1)),
        ("RHR",        format(r?.resting_heart_rate, unit: "bpm", digits: 0)),
        ("SPO₂",       format(r?.spo2_percentage, unit: "%", digits: 1)),
        ("SKIN TEMP",  format(r?.skin_temp_celsius, unit: "°C", digits: 1))
      ]
    case .sleep:
      let s = client.currentDay?.sleep
      let stages = s?.stage_summary
      return [
        ("EFFICIENCY",   format(s?.efficiency, unit: "%", digits: 1)),
        ("IN BED",       Self.formatMillis(stages?.total_in_bed_time_milli)),
        ("DEEP",         Self.formatMillis(stages?.total_slow_wave_sleep_time_milli)),
        ("REM",          Self.formatMillis(stages?.total_rem_sleep_time_milli)),
        ("LIGHT",        Self.formatMillis(stages?.total_light_sleep_time_milli)),
        ("CYCLES",       (stages?.sleep_cycle_count).map { "\($0)" } ?? "--")
      ]
    case .strain:
      let strain = client.currentDay?.strain
      return [
        ("KILOJOULES", format(strain?.kilojoule, unit: "kJ", digits: 0))
      ]
    }
  }

  private var chartData: [ChartPoint] {
    let history = client.recoveryHistory.prefix(14).reversed()
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let labelFormatter = DateFormatter()
    labelFormatter.dateFormat = "d"
    return history.compactMap { entry in
      guard let startStr = entry.start,
            let date = isoFormatter.date(from: startStr) ?? ISO8601DateFormatter().date(from: startStr) else {
        return nil
      }
      let value: Double?
      switch metric {
      case .recovery: value = entry.recovery_score
      case .sleep:    value = entry.hrv_rmssd_milli
      case .strain:   value = entry.resting_heart_rate
      }
      guard let v = value else { return nil }
      return ChartPoint(label: labelFormatter.string(from: date), value: v)
    }
  }

  private var chartYDomain: ClosedRange<Double> {
    switch metric {
    case .recovery: return 0...100
    case .sleep:    return 0...120
    case .strain:   return 30...90
    }
  }

  private var yAxisValues: [Double] {
    switch metric {
    case .recovery: return [0, 33, 67, 100]
    case .sleep:    return [0, 40, 80, 120]
    case .strain:   return [40, 60, 80]
    }
  }

  private func barColor(for value: Double) -> Color {
    switch metric {
    case .recovery:
      if value >= 67 { return Color(red: 0.18, green: 0.88, blue: 0.66) }
      if value >= 34 { return Color(red: 1.0, green: 0.88, blue: 0.40) }
      return Color(red: 1.0, green: 0.37, blue: 0.42)
    case .sleep:
      return Color(red: 0.30, green: 0.65, blue: 1.0)
    case .strain:
      return Color(red: 1.0, green: 0.62, blue: 0.35)
    }
  }

  private func format(_ value: Double?, unit: String, digits: Int) -> String {
    guard let value, value.isFinite else { return "--" }
    let v = String(format: "%.\(digits)f", value)
    return unit.isEmpty ? v : "\(v) \(unit)"
  }

  private static func formatMillis(_ value: Int?) -> String {
    guard let value, value > 0 else { return "--" }
    let m = value / 60_000
    let h = m / 60
    let r = m % 60
    if h == 0 { return "\(r)m" }
    return "\(h)h \(r)m"
  }
}

private struct ChartPoint: Identifiable {
  let label: String
  let value: Double
  var id: String { label }
}

extension WhoopHomeView {
  static let detailBackground = LinearGradient(
    colors: [
      Color(red: 0.02, green: 0.04, blue: 0.09),
      Color(red: 0.00, green: 0.00, blue: 0.03)
    ],
    startPoint: .top,
    endPoint: .bottom
  )
}
