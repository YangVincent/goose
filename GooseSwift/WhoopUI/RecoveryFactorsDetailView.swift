import SwiftUI
import Charts

/// Full recovery drill-in matching WHOOP's layout: ring hero → factor
/// rows (HRV/RHR/RR/Sleep) → plain-English insight → Weekly Trends
/// section with one chart per factor. Reached by tapping the home
/// recovery ring (WhoopMetric.recovery → here via WhoopMetricDetailView).
struct RecoveryFactorsDetailView: View {
  @ObservedObject private var dailyStore = WhoopImportedDailyStore.shared
  @ObservedObject private var selectedDay = SelectedDayStore.shared
  @State private var score: GooseRecoveryCalculator.Score?

  var body: some View {
    ZStack {
      WhoopHomeView.detailBackground.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          ringHero
            .padding(.top, 8)
          factorList
          insightCard
          weeklyTrendsHeader
          recoveryChart
          hrvChart
          rhrChart
          respiratoryRateChart
          sleepPerformanceChart
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle(headerDateLabel)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .onAppear { refresh() }
    .onChange(of: selectedDay.currentDate) { _, _ in refresh() }
    .onChange(of: dailyStore.byDate.count) { _, _ in refresh() }
  }

  // MARK: - Header

  private var headerDateLabel: String {
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f.string(from: selectedDay.currentDate).uppercased()
  }

  // MARK: - Ring hero

  private var ringHero: some View {
    let val = score?.score
    let color = score.map { tint(for: $0.band) } ?? Color.white.opacity(0.3)
    return VStack {
      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.08), lineWidth: 14)
        Circle()
          .trim(from: 0, to: val.map { min(Double($0) / 100.0, 1.0) } ?? 0)
          .stroke(color, style: StrokeStyle(lineWidth: 14, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .shadow(color: color.opacity(0.4), radius: 8)
        VStack(spacing: 4) {
          Text("GOOSE")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.4))
          HStack(alignment: .lastTextBaseline, spacing: 0) {
            Text(val.map { "\($0)" } ?? "--")
              .font(.system(size: 64, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.white)
            Text("%")
              .font(.system(size: 28, weight: .heavy, design: .rounded))
              .foregroundStyle(.white.opacity(0.55))
          }
          Text("RECOVERY")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.55))
        }
      }
      .frame(width: 230, height: 230)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Factor list (HRV, RHR, Respiratory Rate, Sleep)

  private var factorList: some View {
    let summary = dailyStore.summary(for: selectedDay.currentDate)
    return cardSurface {
      VStack(spacing: 0) {
        factorRow(
          icon: "waveform.path.ecg",
          label: "HEART RATE VARIABILITY",
          value: summary?.hrvRmssdMs,
          baseline: hrvBaseline,
          unit: "",
          digits: 0,
          higherIsBetter: true
        )
        Divider().background(Color.white.opacity(0.08))
        factorRow(
          icon: "heart.fill",
          label: "RESTING HEART RATE",
          value: summary?.restingHrBpm,
          baseline: rhrBaseline,
          unit: "",
          digits: 0,
          higherIsBetter: false
        )
        Divider().background(Color.white.opacity(0.08))
        factorRow(
          icon: "lungs.fill",
          label: "RESPIRATORY RATE",
          value: nil, // not yet tracked in Goose
          baseline: nil,
          unit: "",
          digits: 1,
          higherIsBetter: false
        )
        Divider().background(Color.white.opacity(0.08))
        factorRow(
          icon: "moon.fill",
          label: "SLEEP PERFORMANCE",
          value: summary?.sleepPerformancePct,
          baseline: sleepPerfBaseline,
          unit: "%",
          digits: 0,
          higherIsBetter: true
        )
      }
    }
  }

  private func factorRow(
    icon: String,
    label: String,
    value: Double?,
    baseline: Double?,
    unit: String,
    digits: Int,
    higherIsBetter: Bool
  ) -> some View {
    let dir = directionFor(current: value, baseline: baseline, higherIsBetter: higherIsBetter)
    return HStack(alignment: .center, spacing: 14) {
      Image(systemName: icon)
        .font(.system(size: 18, weight: .semibold))
        .foregroundStyle(.white.opacity(0.65))
        .frame(width: 28)
      Text(label)
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(1.4)
        .foregroundStyle(.white.opacity(0.85))
      Spacer(minLength: 8)
      VStack(alignment: .trailing, spacing: 2) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          Text(formatNumber(value, digits: digits) + unit)
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
          Image(systemName: dir.glyph)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(dir.color)
        }
        if let baseline {
          Text(formatNumber(baseline, digits: digits) + unit)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.4))
        }
      }
    }
    .padding(.vertical, 12)
  }

  // MARK: - Insight card

  private var insightCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text(plainEnglishSummary)
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.9))
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
        .overlay(
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .stroke(
              LinearGradient(
                colors: [
                  Color(red: 0.55, green: 0.85, blue: 1.0).opacity(0.55),
                  Color(red: 0.7, green: 0.5, blue: 1.0).opacity(0.55)
                ],
                startPoint: .leading,
                endPoint: .trailing
              ),
              lineWidth: 1
            )
        )
    )
  }

  // MARK: - Weekly Trends header

  private var weeklyTrendsHeader: some View {
    Text("Weekly Trends")
      .font(.system(size: 24, weight: .heavy, design: .rounded))
      .foregroundStyle(.white)
      .padding(.top, 8)
  }

  // MARK: - Weekly charts

  private struct DayPoint: Identifiable {
    let id = UUID()
    let date: Date
    let dateKey: String
    let value: Double?
    let band: GooseRecoveryCalculator.Band?
    var dayLetter: String {
      let f = DateFormatter()
      f.dateFormat = "EEE"
      return String(f.string(from: date).prefix(3))
    }
    var dayNumber: String {
      let f = DateFormatter()
      f.dateFormat = "d"
      return f.string(from: date)
    }
  }

  /// Last 7 days ending at selectedDay (inclusive). For each, pull the
  /// matching dailyStore.byDate entry — value is nil when missing.
  private func weeklyData(_ extract: (WhoopImportedDailyStore.DailySummary?) -> Double?) -> [DayPoint] {
    let cal = Calendar.current
    let end = cal.startOfDay(for: selectedDay.currentDate)
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    var points: [DayPoint] = []
    for offset in (0..<7).reversed() {
      guard let date = cal.date(byAdding: .day, value: -offset, to: end) else { continue }
      let key = f.string(from: date)
      let summary = dailyStore.byDate[key]
      let value = extract(summary)
      let band: GooseRecoveryCalculator.Band? = summary?.recoveryScore.map {
        GooseRecoveryCalculator.Band(score: Int($0.rounded()))
      }
      points.append(DayPoint(date: date, dateKey: key, value: value, band: band))
    }
    return points
  }

  @ViewBuilder
  private var recoveryChart: some View {
    let points = weeklyData { $0?.recoveryScore }
    trendCard(title: "RECOVERY") {
      Chart(points) { point in
        if let v = point.value {
          BarMark(
            x: .value("day", point.dayLetter),
            y: .value("recovery", v),
            width: .fixed(18)
          )
          .foregroundStyle(point.band.map { tint(for: $0) } ?? Color.white.opacity(0.2))
          .annotation(position: .top, alignment: .center, spacing: 2) {
            Text("\(Int(v.rounded()))%")
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(point.band.map { tint(for: $0) } ?? .white.opacity(0.55))
          }
          .cornerRadius(3)
        }
      }
      .chartYScale(domain: 0...100)
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .frame(height: 160)
    }
  }

  @ViewBuilder
  private var hrvChart: some View {
    let points = weeklyData { $0?.hrvRmssdMs }
    trendCard(title: "HEART RATE VARIABILITY") {
      lineChart(points: points, unit: "", digits: 0)
        .frame(height: 160)
    }
  }

  @ViewBuilder
  private var rhrChart: some View {
    let points = weeklyData { $0?.restingHrBpm }
    trendCard(title: "RESTING HEART RATE") {
      lineChart(points: points, unit: "", digits: 0)
        .frame(height: 160)
    }
  }

  @ViewBuilder
  private var respiratoryRateChart: some View {
    let points = weeklyData { _ in nil as Double? }
    trendCard(title: "RESPIRATORY RATE") {
      VStack {
        Spacer()
        Text("NOT TRACKED YET")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.35))
        Spacer()
        chartXLabelRow(points: points)
      }
      .frame(height: 160)
    }
  }

  @ViewBuilder
  private var sleepPerformanceChart: some View {
    let points = weeklyData { $0?.sleepPerformancePct }
    trendCard(title: "SLEEP PERFORMANCE") {
      Chart(points) { point in
        if let v = point.value {
          BarMark(
            x: .value("day", point.dayLetter),
            y: .value("sleep", v),
            width: .fixed(18)
          )
          .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 0.95))
          .annotation(position: .top, alignment: .center, spacing: 2) {
            Text("\(Int(v.rounded()))%")
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(Color(red: 0.7, green: 0.85, blue: 1.0))
          }
          .cornerRadius(3)
        }
      }
      .chartYScale(domain: 0...100)
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .frame(height: 160)
    }
  }

  @ViewBuilder
  private func lineChart(points: [DayPoint], unit: String, digits: Int) -> some View {
    let nonNil = points.compactMap { $0.value }
    if nonNil.count >= 2 {
      let minV = nonNil.min() ?? 0
      let maxV = nonNil.max() ?? 1
      let pad = max(1, (maxV - minV) * 0.25)
      Chart(points) { point in
        if let v = point.value {
          LineMark(
            x: .value("day", point.dayLetter),
            y: .value("value", v)
          )
          .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
          .interpolationMethod(.catmullRom)
          .lineStyle(StrokeStyle(lineWidth: 2))
          PointMark(
            x: .value("day", point.dayLetter),
            y: .value("value", v)
          )
          .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
          .symbolSize(45)
          .annotation(position: .top, alignment: .center, spacing: 2) {
            Text(formatNumber(v, digits: digits) + unit)
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(Color(red: 0.7, green: 0.9, blue: 1.0))
          }
        }
      }
      .chartYScale(domain: (minV - pad)...(maxV + pad))
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
    } else {
      VStack {
        Spacer()
        Text("NOT ENOUGH DATA")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.35))
        Spacer()
        chartXLabelRow(points: points)
      }
    }
  }

  private func chartXAxis(_ points: [DayPoint]) -> some AxisContent {
    AxisMarks(values: points.map(\.dayLetter)) { value in
      AxisValueLabel {
        if let str = value.as(String.self),
           let point = points.first(where: { $0.dayLetter == str }) {
          VStack(spacing: 1) {
            Text(point.dayLetter)
              .font(.system(size: 10, weight: .semibold, design: .rounded))
              .foregroundStyle(.white.opacity(0.55))
            Text(point.dayNumber)
              .font(.system(size: 9, weight: .heavy, design: .rounded))
              .foregroundStyle(.white.opacity(0.45))
          }
        }
      }
    }
  }

  /// Fallback x-axis row when a chart has no data points (Chart wouldn't
  /// render the AxisMarks otherwise).
  private func chartXLabelRow(points: [DayPoint]) -> some View {
    HStack {
      ForEach(points) { p in
        VStack(spacing: 1) {
          Text(p.dayLetter)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
          Text(p.dayNumber)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity)
      }
    }
  }

  private func trendCard<C: View>(title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text(title)
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.7))
        Spacer()
        Image(systemName: "chevron.right")
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(.white.opacity(0.4))
      }
      content()
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  // MARK: - Plain-English summary (unchanged from old view)

  private var plainEnglishSummary: String {
    guard let score = score, score.confidence > 0 else {
      return "Need at least 4 days of baseline data to explain today's score."
    }
    var lines: [String] = []
    if let hrv = score.hrvComponent, let base = score.hrvBaseline {
      let pct = (hrv - base) / base * 100
      if pct > 5 {
        lines.append("Your HRV \(Int(hrv))ms is \(Int(pct))% above its usual range, supporting a strong recovery.")
      } else if pct < -5 {
        lines.append("Your HRV \(Int(hrv))ms is \(Int(-pct))% below its usual range, resulting in a depressed recovery. If you can, spend extra time on recovery activities like hydrating and eating healthy.")
      } else {
        lines.append("Your HRV \(Int(hrv))ms is right at its usual range.")
      }
    }
    if lines.isEmpty, let rhr = score.rhrComponent, let base = score.rhrBaseline {
      let delta = rhr - base
      if delta > 2 {
        lines.append("Your resting HR \(Int(rhr))bpm is \(Int(delta)) above baseline — body still working harder than usual.")
      } else if delta < -2 {
        lines.append("Your resting HR \(Int(rhr))bpm is \(Int(-delta)) below baseline — cardiovascular system fully rested.")
      }
    }
    return lines.first ?? "Your factors are tracking within their usual ranges."
  }

  // MARK: - Baselines

  private var hrvBaseline: Double? {
    Self.median(dailyStore.byDate.values.compactMap(\.hrvRmssdMs))
  }
  private var rhrBaseline: Double? {
    Self.median(dailyStore.byDate.values.compactMap(\.restingHrBpm))
  }
  private var sleepPerfBaseline: Double? {
    Self.median(dailyStore.byDate.values.compactMap(\.sleepPerformancePct))
  }

  // MARK: - Compute (unchanged)

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

  // MARK: - Direction + formatting helpers

  private enum Direction {
    case better, worse, neutral, observed
    var color: Color {
      switch self {
      case .better: Color(red: 0.18, green: 0.88, blue: 0.66)
      case .worse: Color(red: 1.0, green: 0.62, blue: 0.20)
      case .neutral: Color.white.opacity(0.45)
      case .observed: Color.white.opacity(0.45)
      }
    }
    var glyph: String {
      switch self {
      case .better: "arrow.up"
      case .worse: "arrow.down"
      case .neutral: "minus"
      case .observed: "circle"
      }
    }
  }

  private func directionFor(current: Double?, baseline: Double?, higherIsBetter: Bool) -> Direction {
    guard let c = current, let b = baseline else { return current != nil ? .observed : .neutral }
    let delta = c - b
    let threshold = max(0.001, b * 0.03)
    if higherIsBetter {
      if delta > threshold { return .better }
      if delta < -threshold { return .worse }
    } else {
      if delta < -threshold { return .better }
      if delta > threshold { return .worse }
    }
    return .neutral
  }

  private func tint(for band: GooseRecoveryCalculator.Band) -> Color {
    switch band {
    case .green: Color(red: 0.18, green: 0.88, blue: 0.66)
    case .yellow: Color(red: 1.0, green: 0.88, blue: 0.40)
    case .red: Color(red: 1.0, green: 0.37, blue: 0.42)
    }
  }

  private func formatNumber(_ value: Double?, digits: Int) -> String {
    guard let v = value else { return "--" }
    return String(format: "%.\(digits)f", v)
  }

  private func cardSurface<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    content()
      .padding(.horizontal, 16)
      .padding(.vertical, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.white.opacity(0.04))
      )
  }
}
