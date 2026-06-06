import SwiftUI
import Charts

/// WHOOP-style "Trend View" for the day-strain factor. Reached by
/// tapping the chevron on the STRAIN card inside StrainDetailView.
/// Lets the user step through Week / Month / 6-Month windows, see the
/// average + delta vs the prior window, the bar chart over the range,
/// a strain-band distribution breakdown, and a "What is Day Strain?"
/// explainer matching WHOOP's strain trend page.
struct StrainTrendView: View {
  @ObservedObject private var dailyStore = WhoopImportedDailyStore.shared
  @ObservedObject private var strainStore = DayStrainStore.shared

  @State private var period: Period = .week
  /// End date of the displayed window (inclusive). Starts at today.
  @State private var windowEnd: Date = Calendar.current.startOfDay(for: Date())

  enum Period: String, CaseIterable, Identifiable {
    case week, month, sixMonth
    var id: String { rawValue }
    var label: String {
      switch self {
      case .week: "W"
      case .month: "M"
      case .sixMonth: "6M"
      }
    }
    var days: Int {
      switch self {
      case .week: 7
      case .month: 30
      case .sixMonth: 182
      }
    }
    var dateRangeFormat: String {
      switch self {
      case .week, .month: "MMM d"
      case .sixMonth: "MMM yyyy"
      }
    }
  }

  var body: some View {
    ZStack {
      WhoopHomeView.detailBackground.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          periodPicker
          rangeNavigator
          averageRow
          chartCard
          breakdownCard
          explainerCard
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("TREND VIEW")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
  }

  // MARK: - Period picker

  private var periodPicker: some View {
    HStack(spacing: 0) {
      ForEach(Period.allCases) { p in
        Button {
          period = p
          windowEnd = Calendar.current.startOfDay(for: Date())
        } label: {
          Text(p.label)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(p == period ? .white : .white.opacity(0.55))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(p == period ? Color.white.opacity(0.10) : .clear)
            )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(4)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  // MARK: - Range navigator

  private var rangeNavigator: some View {
    HStack {
      Button { step(by: -1) } label: {
        Image(systemName: "chevron.left")
          .font(.system(size: 14, weight: .heavy))
          .foregroundStyle(.white.opacity(0.7))
          .padding(8)
      }
      .buttonStyle(.plain)
      Spacer()
      Text(rangeLabel)
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.white)
        .monospacedDigit()
      Spacer()
      Button { step(by: 1) } label: {
        Image(systemName: "chevron.right")
          .font(.system(size: 14, weight: .heavy))
          .foregroundStyle(canStepForward ? .white.opacity(0.7) : .white.opacity(0.2))
          .padding(8)
      }
      .buttonStyle(.plain)
      .disabled(!canStepForward)
    }
  }

  private func step(by direction: Int) {
    let cal = Calendar.current
    let delta = direction * period.days
    guard let newEnd = cal.date(byAdding: .day, value: delta, to: windowEnd) else { return }
    let today = cal.startOfDay(for: Date())
    if newEnd > today {
      windowEnd = today
    } else {
      windowEnd = newEnd
    }
  }

  private var canStepForward: Bool {
    let today = Calendar.current.startOfDay(for: Date())
    return windowEnd < today
  }

  private var rangeLabel: String {
    let cal = Calendar.current
    guard let start = cal.date(byAdding: .day, value: -(period.days - 1), to: windowEnd)
    else { return "" }
    let f = DateFormatter()
    f.dateFormat = period.dateRangeFormat
    let endStr = f.string(from: windowEnd)
    let startStr = f.string(from: start)
    let yearF = DateFormatter()
    yearF.dateFormat = "yyyy"
    let yearStr = yearF.string(from: windowEnd)
    return "\(startStr.uppercased()) – \(endStr.uppercased()), \(yearStr.suffix(2))"
  }

  // MARK: - Average row

  private var averageRow: some View {
    let stats = computeStats()
    let priorStats = computePriorStats()
    let delta: Double? = {
      guard let a = stats.average, let b = priorStats.average else { return nil }
      return a - b
    }()
    return HStack(alignment: .top) {
      VStack(alignment: .leading, spacing: 4) {
        Text("AVERAGE")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        Text(stats.average.map { String(format: "%.1f", $0) } ?? "--")
          .font(.system(size: 48, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        if let delta {
          HStack(spacing: 4) {
            Image(systemName: delta >= 0 ? "triangle.fill" : "triangle.fill")
              .rotationEffect(.degrees(delta >= 0 ? 0 : 180))
              .font(.system(size: 8, weight: .heavy))
              .foregroundStyle(delta >= 0
                ? Color(red: 0.18, green: 0.88, blue: 0.66)
                : Color(red: 1.0, green: 0.62, blue: 0.20))
            Text(String(format: "%.1f vs. prior \(period == .week ? "week" : period == .month ? "month" : "6mo")", abs(delta)))
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .foregroundStyle(.white.opacity(0.65))
          }
          .padding(.horizontal, 8)
          .padding(.vertical, 4)
          .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
              .fill(Color.white.opacity(0.04))
          )
        }
      }
      Spacer()
    }
  }

  // MARK: - Chart card

  private var chartCard: some View {
    let stats = computeStats()
    let priorStats = computePriorStats()
    return VStack(alignment: .leading, spacing: 14) {
      Text(insightSentence(stats: stats, prior: priorStats))
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.85))
        .fixedSize(horizontal: false, vertical: true)
      strainChart(points: stats.points)
        .frame(height: 260)
    }
  }

  private func strainChart(points: [DayPoint]) -> some View {
    Chart(points) { point in
      let v = point.value ?? 0
      let visualHeight = max(v, 0.4)
      let isReal = v > 0
      BarMark(
        x: .value("day", point.barLabel),
        y: .value("strain", visualHeight),
        width: .fixed(barWidth)
      )
      .foregroundStyle(isReal
        ? Color(red: 0.18, green: 0.62, blue: 0.95)
        : Color.white.opacity(0.10))
      .annotation(position: .top, alignment: .center, spacing: 2) {
        if period == .week {
          Text(String(format: "%.1f", v))
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isReal
              ? Color(red: 0.4, green: 0.78, blue: 1.0)
              : Color.white.opacity(0.35))
        }
      }
      .cornerRadius(3)
    }
    .chartYScale(domain: 0...21)
    .chartXAxis {
      AxisMarks(values: chartAxisValues(points)) { value in
        AxisValueLabel {
          if let str = value.as(String.self) {
            Text(str)
              .font(.system(size: 9, weight: .heavy, design: .rounded))
              .foregroundStyle(.white.opacity(0.5))
          }
        }
      }
    }
    .chartYAxis {
      AxisMarks(position: .leading, values: [0, 5, 10, 15, 21]) { value in
        AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
        AxisValueLabel {
          if let v = value.as(Int.self) {
            Text("\(v)")
              .font(.system(size: 9, weight: .semibold, design: .rounded))
              .foregroundStyle(.white.opacity(0.45))
          }
        }
      }
    }
  }

  private var barWidth: CGFloat {
    switch period {
    case .week: 28
    case .month: 8
    case .sixMonth: 3
    }
  }

  /// Sub-set the x-axis labels so a 30-day or 182-day chart doesn't smear
  /// every label on top of itself.
  private func chartAxisValues(_ points: [DayPoint]) -> [String] {
    switch period {
    case .week:
      return points.map(\.barLabel)
    case .month:
      // Every 5th day
      return stride(from: 0, to: points.count, by: 5).map { points[$0].barLabel }
    case .sixMonth:
      // First day of each month present in the range
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM"
      var seenMonths = Set<String>()
      var picks: [String] = []
      for p in points {
        let mKey = f.string(from: p.date)
        if !seenMonths.contains(mKey) {
          seenMonths.insert(mKey)
          picks.append(p.barLabel)
        }
      }
      return picks
    }
  }

  // MARK: - Breakdown card

  private var breakdownCard: some View {
    let stats = computeStats()
    let buckets = strainBuckets(points: stats.points)
    let totalDays = buckets.reduce(0) { $0 + $1.count }
    return VStack(alignment: .leading, spacing: 12) {
      Text("STRAIN BREAKDOWN (DAYS)")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(1.8)
        .foregroundStyle(.white.opacity(0.7))
      // Stacked horizontal segment bar
      GeometryReader { geo in
        HStack(spacing: 1) {
          ForEach(buckets) { b in
            let fraction = totalDays > 0 ? CGFloat(b.count) / CGFloat(totalDays) : 0
            Rectangle()
              .fill(b.color)
              .frame(width: max(0, geo.size.width * fraction))
          }
          if totalDays == 0 {
            Rectangle()
              .fill(Color.white.opacity(0.08))
              .frame(maxWidth: .infinity)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
      }
      .frame(height: 10)
      VStack(spacing: 10) {
        ForEach(buckets) { b in
          HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
              .fill(b.color)
              .frame(width: 12, height: 12)
            Text("\(b.count)x")
              .font(.system(size: 13, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.white)
              .frame(width: 36, alignment: .leading)
            Text(b.label)
              .font(.system(size: 13, weight: .semibold, design: .rounded))
              .foregroundStyle(.white.opacity(0.7))
            Spacer()
          }
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  // MARK: - Explainer

  private var explainerCard: some View {
    VStack(alignment: .leading, spacing: 18) {
      VStack(alignment: .leading, spacing: 10) {
        Text("What is Day Strain?")
          .font(.system(size: 22, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
        Text("Day Strain measures your total Strain accumulated over the course of the entire day. This includes both cardiovascular and muscular Strain.")
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.65))
          .fixedSize(horizontal: false, vertical: true)
        Text("Anything that gets your heart rate up can build cardiovascular Strain — that's why you can wake up with a strain of 0-4 just from being alive. Muscular Strain layers on top from logged workouts.")
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.65))
          .fixedSize(horizontal: false, vertical: true)
        Text("Strain is on a 0-21 scale, log-curve. The harder your body works the more strain you accumulate; the rest of recovery + tonight's sleep need scales with it.")
          .font(.system(size: 14, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.65))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  // MARK: - Data

  private struct DayPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double?
    var dateKey: String {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.timeZone = TimeZone.current
      return f.string(from: date)
    }
    var barLabel: String {
      let f = DateFormatter()
      f.dateFormat = "EEE"
      return String(f.string(from: date).prefix(3))
    }
  }

  private struct Stats {
    let points: [DayPoint]
    let average: Double?
  }

  private func computeStats() -> Stats {
    buildStats(endDay: windowEnd, days: period.days)
  }

  private func computePriorStats() -> Stats {
    let cal = Calendar.current
    guard let priorEnd = cal.date(byAdding: .day, value: -period.days, to: windowEnd)
    else { return Stats(points: [], average: nil) }
    return buildStats(endDay: priorEnd, days: period.days)
  }

  private func buildStats(endDay: Date, days: Int) -> Stats {
    let cal = Calendar.current
    let todayKey: String = {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.timeZone = TimeZone.current
      return f.string(from: Date())
    }()
    let liveStrain = strainStore.today?.strain
    var pts: [DayPoint] = []
    for offset in (0..<days).reversed() {
      guard let day = cal.date(byAdding: .day, value: -offset, to: endDay) else { continue }
      let key: String = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f.string(from: day)
      }()
      let value: Double? = {
        if key == todayKey, let live = liveStrain, live > 0 { return live }
        return dailyStore.byDate[key]?.strainScore
      }()
      pts.append(DayPoint(date: day, value: value))
    }
    let valid = pts.compactMap { $0.value }.filter { $0 > 0 }
    let avg = valid.isEmpty ? nil : valid.reduce(0, +) / Double(valid.count)
    return Stats(points: pts, average: avg)
  }

  // MARK: - Strain bands

  private struct Bucket: Identifiable {
    let id = UUID()
    let label: String
    let color: Color
    let count: Int
  }

  private func strainBuckets(points: [DayPoint]) -> [Bucket] {
    var allOut = 0, strenuous = 0, moderate = 0, light = 0
    for p in points {
      guard let v = p.value, v > 0 else { continue }
      switch v {
      case 18...: allOut += 1
      case 14.1..<18: strenuous += 1
      case 10.1..<14: moderate += 1
      default: light += 1
      }
    }
    return [
      Bucket(label: "All Out (>18.0)", color: Color(red: 1.0, green: 0.37, blue: 0.42), count: allOut),
      Bucket(label: "Strenuous (14.1-18.0)", color: Color(red: 1.0, green: 0.62, blue: 0.30), count: strenuous),
      Bucket(label: "Moderate (10.1-14.0)", color: Color(red: 0.30, green: 0.78, blue: 0.55), count: moderate),
      Bucket(label: "Light (<10.0)", color: Color(red: 0.18, green: 0.62, blue: 0.95), count: light),
    ]
  }

  // MARK: - Insight

  private func insightSentence(stats: Stats, prior: Stats) -> String {
    guard let avg = stats.average else {
      return "Not enough recorded strain in this \(periodLabelLowercase) yet."
    }
    if let priorAvg = prior.average {
      let delta = avg - priorAvg
      if abs(delta) < 0.3 {
        return "During this \(periodLabelLowercase), your average Day Strain (\(format(avg))) was about the same as the prior \(periodLabelLowercase) (\(format(priorAvg)))."
      }
      let direction = delta > 0 ? "above" : "below"
      return "During this \(periodLabelLowercase), your average Day Strain (\(format(avg))) was \(direction) the prior \(periodLabelLowercase) (\(format(priorAvg)))."
    }
    return "During this \(periodLabelLowercase), your average Day Strain was \(format(avg))."
  }

  private var periodLabelLowercase: String {
    switch period {
    case .week: "7-day period"
    case .month: "30-day period"
    case .sixMonth: "6-month period"
    }
  }

  private func format(_ v: Double) -> String {
    String(format: "%.1f", v)
  }
}
