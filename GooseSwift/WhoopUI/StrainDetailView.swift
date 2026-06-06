import SwiftUI
import Charts

/// Full strain drill-in matching WHOOP's strain detail screen: ring
/// hero → factor rows (HR zones 1-3, HR zones 4-5, strength time,
/// steps) → plain-English insight → Weekly Trends with one chart per
/// factor. Reached by tapping the home strain ring (WhoopMetric.strain
/// → here via WhoopMetricDetailView).
struct StrainDetailView: View {
  @ObservedObject private var selectedDay = SelectedDayStore.shared
  @ObservedObject private var dailyStore = WhoopImportedDailyStore.shared
  @ObservedObject private var strainStore = DayStrainStore.shared
  @ObservedObject private var workoutStore = CompletedWorkoutStore.shared
  @ObservedObject private var stepEstimator = StepEstimator.shared
  /// Per-day strain reading payload (the JSON written by
  /// `strain.upsert_reading` and read back via the new
  /// `strain.list_readings_range` bridge call). Keyed by date_key,
  /// holds zone_minutes + trimp + strain so the weekly trend charts
  /// can render zone stacks and calories without N round-trips.
  @State private var weeklyReadings: [String: [String: Any]] = [:]

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
          strainChart
          hrZones13Chart
          hrZones45Chart
          stepsChart
          caloriesChart
          strengthActivityChart
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle(headerDateLabel)
    .navigationBarTitleDisplayMode(.inline)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task { await loadWeeklyReadings() }
    .onChange(of: selectedDay.currentDate) { _, _ in
      Task { await loadWeeklyReadings() }
    }
  }

  /// One bridge call pulls the last 7 days of daily_strain_readings
  /// (date_key + the full reading payload). Use the parsed
  /// zone_minutes / trimp / strain to populate the per-zone stacks
  /// and calorie chart without N round-trips.
  private func loadWeeklyReadings() async {
    let cal = Calendar.current
    let end = cal.startOfDay(for: selectedDay.currentDate)
    guard let start = cal.date(byAdding: .day, value: -6, to: end) else { return }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    let dbPath = HealthDataStore.defaultDatabasePath()
    let bridge = GooseRustBridge()
    let response: [String: Any]? = await Task.detached(priority: .userInitiated) {
      try? bridge.request(
        method: "strain.list_readings_range",
        args: [
          "database_path": dbPath,
          "start_date": f.string(from: start),
          "end_date": f.string(from: end),
        ]
      )
    }.value
    guard let response,
          let rows = response["readings"] as? [[String: Any]] else { return }
    var byKey: [String: [String: Any]] = [:]
    for row in rows {
      guard let dateKey = row["date_key"] as? String,
            let reading = row["reading"] as? [String: Any] else { continue }
      byKey[dateKey] = reading
    }
    await MainActor.run { self.weeklyReadings = byKey }
  }

  // MARK: - Header

  private var headerDateLabel: String {
    let f = DateFormatter()
    f.dateFormat = "EEE, MMM d"
    return f.string(from: selectedDay.currentDate).uppercased()
  }

  // MARK: - Ring hero

  /// Strain spans 0-21. The ring scales linearly (clamp 0..1).
  private var ringHero: some View {
    let strain = selectedDayStrain
    let progress = strain.map { min($0 / 21.0, 1.0) } ?? 0
    let ringColor = Color(red: 0.18, green: 0.62, blue: 0.95) // WHOOP-like blue
    return VStack {
      ZStack {
        Circle()
          .stroke(Color.white.opacity(0.08), lineWidth: 14)
        Circle()
          .trim(from: 0, to: progress)
          .stroke(ringColor, style: StrokeStyle(lineWidth: 14, lineCap: .round))
          .rotationEffect(.degrees(-90))
          .shadow(color: ringColor.opacity(0.4), radius: 8)
        VStack(spacing: 4) {
          Text("GOOSE")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.4))
          Text(strain.map { String(format: "%.1f", $0) } ?? "--")
            .font(.system(size: 64, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
          Text("STRAIN")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.55))
        }
      }
      .frame(width: 230, height: 230)
    }
    .frame(maxWidth: .infinity)
  }

  // MARK: - Factor list

  private var factorList: some View {
    let isToday = Calendar.current.isDateInToday(selectedDay.currentDate)
    let zones = isToday ? (strainStore.today?.zoneMinutes ?? [:]) : [:]
    let z13 = (zones[1] ?? 0) + (zones[2] ?? 0) + (zones[3] ?? 0)
    let z45 = (zones[4] ?? 0) + (zones[5] ?? 0)
    let baselineZ13 = baselineMinutesInZones([1, 2, 3])
    let baselineZ45 = baselineMinutesInZones([4, 5])
    let strengthMin = strengthActivityMinutes(for: selectedDay.currentDate)
    let strengthBaseline = strengthActivityBaseline()
    let stepsToday = selectedDayStepCount
    let stepsBaseline = stepsBaselineMedian
    return cardSurface {
      VStack(spacing: 0) {
        factorRow(
          icon: "heart",
          label: "HEART RATE ZONES 1-3",
          value: isToday ? z13 : nil,
          baseline: baselineZ13,
          format: .duration,
          higherIsBetter: true
        )
        Divider().background(Color.white.opacity(0.08))
        factorRow(
          icon: "heart.fill",
          label: "HEART RATE ZONES 4-5",
          value: isToday ? z45 : nil,
          baseline: baselineZ45,
          format: .duration,
          higherIsBetter: true
        )
        Divider().background(Color.white.opacity(0.08))
        factorRow(
          icon: "dumbbell.fill",
          label: "STRENGTH ACTIVITY TIME",
          value: strengthMin,
          baseline: strengthBaseline,
          format: .duration,
          higherIsBetter: true
        )
        Divider().background(Color.white.opacity(0.08))
        factorRow(
          icon: "figure.walk",
          label: "STEPS",
          value: stepsToday,
          baseline: stepsBaseline,
          format: .integer,
          higherIsBetter: true
        )
      }
    }
  }

  private enum ValueFormat {
    case duration  // minutes → "h:mm"
    case integer   // raw number with commas
  }

  private func factorRow(
    icon: String,
    label: String,
    value: Double?,
    baseline: Double?,
    format: ValueFormat,
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
          Text(formatValue(value, as: format))
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
          Image(systemName: dir.glyph)
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(dir.color)
        }
        if let baseline {
          Text(formatValue(baseline, as: format))
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

  private var plainEnglishSummary: String {
    guard let s = selectedDayStrain else {
      return "No strain data yet for this day."
    }
    let band: String = {
      switch s {
      case 0..<6: return "Strain between 0 and 5.9 is considered resting. Your accumulated cardiovascular load is minimal."
      case 6..<10: return "Strain between 6 and 9.9 is considered light. You're getting some load in but well within your recovery capacity."
      case 10..<14: return "Strain between 10 and 13.9 is considered moderate. You're building cardiovascular fitness."
      case 14..<18: return "Strain between 14 and 17.9 is considered high. Watch tomorrow's recovery — this load takes more than overnight to clear."
      default: return "Strain above 18 is all-out. Significant sleep and recovery time needed before another effort of this magnitude."
      }
    }()
    return band
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

  private func weeklyData(_ extract: (String) -> Double?) -> [DayPoint] {
    let cal = Calendar.current
    let end = cal.startOfDay(for: selectedDay.currentDate)
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    var points: [DayPoint] = []
    for offset in (0..<7).reversed() {
      guard let date = cal.date(byAdding: .day, value: -offset, to: end) else { continue }
      let key = f.string(from: date)
      points.append(DayPoint(date: date, dateKey: key, value: extract(key)))
    }
    return points
  }

  @ViewBuilder
  private var strainChart: some View {
    let todayKey: String = {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.timeZone = TimeZone.current
      return f.string(from: Date())
    }()
    let liveStrain = strainStore.today?.strain
    let points = weeklyData { key in
      if key == todayKey, let live = liveStrain, live > 0 { return live }
      return dailyStore.byDate[key]?.strainScore
    }
    trendCard(title: "STRAIN", destination: AnyView(StrainTrendView())) {
      Chart(points) { point in
        // Render every day's column, even at 0 — a tiny faint stub keeps
        // the day labels grounded to a visible mark instead of dangling
        // axis text floating over empty space.
        let v = point.value ?? 0
        let visualHeight = max(v, 0.4)
        let isReal = v > 0
        BarMark(
          x: .value("day", point.dayLetter),
          y: .value("strain", visualHeight),
          width: .fixed(18)
        )
        .foregroundStyle(isReal
          ? Color(red: 0.18, green: 0.62, blue: 0.95)
          : Color.white.opacity(0.10))
        .annotation(position: .top, alignment: .center, spacing: 2) {
          Text(String(format: "%.1f", v))
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isReal
              ? Color(red: 0.4, green: 0.78, blue: 1.0)
              : Color.white.opacity(0.35))
        }
        .cornerRadius(3)
      }
      .chartYScale(domain: 0...21)
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .frame(height: 180)
    }
  }

  @ViewBuilder
  private var stepsChart: some View {
    let stepsByKey: [String: Double] = Dictionary(uniqueKeysWithValues:
      stepEstimator.history.map { ($0.dateKey, $0.estimatedSteps) }
    )
    let points = weeklyData { key in stepsByKey[key] }
    let maxSteps = max(points.compactMap { $0.value }.max() ?? 0, 1)
    trendCard(title: "STEPS") {
      Chart(points) { point in
        let v = point.value ?? 0
        let visualHeight = max(v, maxSteps * 0.02)
        let isReal = v > 0
        BarMark(
          x: .value("day", point.dayLetter),
          y: .value("steps", visualHeight),
          width: .fixed(18)
        )
        .foregroundStyle(isReal
          ? Color(red: 0.18, green: 0.62, blue: 0.95)
          : Color.white.opacity(0.10))
        .annotation(position: .top, alignment: .center, spacing: 2) {
          Text(formatStepCount(Int(v)))
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isReal
              ? Color(red: 0.4, green: 0.78, blue: 1.0)
              : Color.white.opacity(0.35))
        }
        .cornerRadius(3)
      }
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .frame(height: 180)
    }
  }

  private struct ZoneSegment: Identifiable {
    let id = UUID()
    let dayLetter: String
    let dayNumber: String
    let zone: Int
    let minutes: Double
  }

  /// Sum the minutes in each requested zone for each of the past 7 days,
  /// expanded into per-zone segments so SwiftUI Charts can stack them
  /// within a single x value via `.foregroundStyle(by:)`.
  private func zoneSegments(for zoneIDs: [Int]) -> [ZoneSegment] {
    let points = weeklyData { _ in nil as Double? }
    var out: [ZoneSegment] = []
    for point in points {
      let reading = weeklyReadings[point.dateKey]
      let zoneMap = reading?["zone_minutes"] as? [String: Any] ?? [:]
      for zoneID in zoneIDs {
        let raw = zoneMap[String(zoneID)]
        let minutes: Double = (raw as? Double)
          ?? (raw as? NSNumber).map { $0.doubleValue }
          ?? 0
        if minutes > 0 {
          out.append(ZoneSegment(
            dayLetter: point.dayLetter,
            dayNumber: point.dayNumber,
            zone: zoneID,
            minutes: minutes
          ))
        }
      }
    }
    return out
  }

  @ViewBuilder
  private var hrZones13Chart: some View {
    let segments = zoneSegments(for: [1, 2, 3])
    let totalsByDay = totalsByDayLetter(segments)
    let points = weeklyData { _ in nil as Double? }
    trendCard(title: "HR ZONES 1-3") {
      zoneLegend(items: [
        (label: "ZONE 1", color: Self.zoneColor(1)),
        (label: "ZONE 2", color: Self.zoneColor(2)),
        (label: "ZONE 3", color: Self.zoneColor(3)),
      ])
      Chart(segments) { segment in
        BarMark(
          x: .value("day", segment.dayLetter),
          y: .value("minutes", segment.minutes),
          width: .fixed(20)
        )
        .foregroundStyle(by: .value("zone", "ZONE \(segment.zone)"))
        .cornerRadius(2)
      }
      .chartForegroundStyleScale([
        "ZONE 1": Self.zoneColor(1),
        "ZONE 2": Self.zoneColor(2),
        "ZONE 3": Self.zoneColor(3),
      ])
      .chartLegend(.hidden)
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .chartOverlay { proxy in
        zoneTotalsOverlay(points: points, totals: totalsByDay, proxy: proxy)
      }
      .frame(height: 180)
    }
  }

  @ViewBuilder
  private var hrZones45Chart: some View {
    let segments = zoneSegments(for: [4, 5])
    let totalsByDay = totalsByDayLetter(segments)
    let points = weeklyData { _ in nil as Double? }
    trendCard(title: "HR ZONES 4-5") {
      zoneLegend(items: [
        (label: "ZONE 4", color: Self.zoneColor(4)),
        (label: "ZONE 5", color: Self.zoneColor(5)),
      ])
      Chart(segments) { segment in
        BarMark(
          x: .value("day", segment.dayLetter),
          y: .value("minutes", segment.minutes),
          width: .fixed(20)
        )
        .foregroundStyle(by: .value("zone", "ZONE \(segment.zone)"))
        .cornerRadius(2)
      }
      .chartForegroundStyleScale([
        "ZONE 4": Self.zoneColor(4),
        "ZONE 5": Self.zoneColor(5),
      ])
      .chartLegend(.hidden)
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .chartOverlay { proxy in
        zoneTotalsOverlay(points: points, totals: totalsByDay, proxy: proxy)
      }
      .frame(height: 180)
    }
  }

  private func totalsByDayLetter(_ segments: [ZoneSegment]) -> [String: Double] {
    var totals: [String: Double] = [:]
    for s in segments { totals[s.dayLetter, default: 0] += s.minutes }
    return totals
  }

  /// Render the column-total label above each stack column. SwiftUI
  /// Charts' .annotation only attaches to individual BarMarks, not
  /// to the stack total — so use a chartOverlay to place the label
  /// at the column's x position above the highest stack height.
  private func zoneTotalsOverlay(
    points: [DayPoint],
    totals: [String: Double],
    proxy: ChartProxy
  ) -> some View {
    GeometryReader { geo in
      let plotFrame: CGRect = {
        if let anchor = proxy.plotFrame {
          return geo[anchor]
        }
        return geo.frame(in: .local)
      }()
      let yScaleMax = totals.values.max() ?? 0
      ForEach(points) { point in
        if let total = totals[point.dayLetter], total > 0,
           let xPos = proxy.position(forX: point.dayLetter) {
          let height = yScaleMax > 0 ? (total / yScaleMax) * plotFrame.height : 0
          Text(durationLabel(minutes: total))
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
            .position(
              x: plotFrame.minX + xPos,
              y: plotFrame.maxY - height - 12
            )
        }
      }
    }
  }

  private func zoneLegend(items: [(label: String, color: Color)]) -> some View {
    HStack(spacing: 14) {
      Spacer()
      ForEach(items, id: \.label) { item in
        HStack(spacing: 6) {
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(item.color)
            .frame(width: 10, height: 10)
          Text(item.label)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.55))
        }
      }
    }
  }

  /// Calories per day, derived from TRIMP. 1 kJ ≈ 0.239 kcal, and
  /// effective TRIMP × 60 kJ/min approximates the energy expended at
  /// the day's mean intensity. This is a rough match for what WHOOP
  /// reports; better fit would use mass-weighted VO2-derived kcal.
  @ViewBuilder
  private var caloriesChart: some View {
    let points = weeklyData { key in caloriesForDay(key: key) }
    let maxKcal = max(points.compactMap { $0.value }.max() ?? 0, 1)
    trendCard(title: "CALORIES") {
      Chart(points) { point in
        let v = point.value ?? 0
        let visualHeight = max(v, maxKcal * 0.02)
        let isReal = v > 0
        BarMark(
          x: .value("day", point.dayLetter),
          y: .value("kcal", visualHeight),
          width: .fixed(18)
        )
        .foregroundStyle(isReal
          ? Color(red: 0.18, green: 0.62, blue: 0.95)
          : Color.white.opacity(0.10))
        .annotation(position: .top, alignment: .center, spacing: 2) {
          Text(formatStepCount(Int(v)))
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(isReal
              ? Color(red: 0.4, green: 0.78, blue: 1.0)
              : Color.white.opacity(0.35))
        }
        .cornerRadius(3)
      }
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .frame(height: 180)
    }
  }

  private func caloriesForDay(key: String) -> Double? {
    let reading = weeklyReadings[key]
    let trimp = (reading?["trimp"] as? Double)
      ?? (reading?["trimp"] as? NSNumber).map { $0.doubleValue }
    if let trimp, trimp > 0 {
      // TRIMP is in effective-kJ-minutes; 1 kJ ≈ 0.239 kcal.
      return trimp * 0.239
    }
    if let kJ = dailyStore.byDate[key]?.strainKilojoules, kJ > 0 {
      return kJ * 0.239
    }
    return nil
  }

  private static func zoneColor(_ zone: Int) -> Color {
    switch zone {
    case 1: return Color(red: 0.65, green: 0.75, blue: 0.85) // muted blue-grey
    case 2: return Color(red: 0.18, green: 0.62, blue: 0.95) // mid-blue
    case 3: return Color(red: 0.30, green: 0.85, blue: 0.55) // green
    case 4: return Color(red: 1.0,  green: 0.65, blue: 0.30) // orange
    case 5: return Color(red: 1.0,  green: 0.37, blue: 0.20) // red-orange
    default: return Color.white.opacity(0.3)
    }
  }

  @ViewBuilder
  private var strengthActivityChart: some View {
    let points = weeklyData { key in
      let workouts = workoutStore.workouts.filter { isStrength($0) && Self.dateKey(for: $0.startedAt) == key }
      let total = workouts.reduce(0.0) { $0 + $1.elapsedSeconds / 60.0 }
      return total > 0 ? total : 0
    }
    trendCard(title: "STRENGTH ACTIVITY TIME") {
      Chart(points) { point in
        if let v = point.value {
          BarMark(
            x: .value("day", point.dayLetter),
            y: .value("minutes", v),
            width: .fixed(18)
          )
          .foregroundStyle(Color(red: 0.18, green: 0.62, blue: 0.95))
          .annotation(position: .top, alignment: .center, spacing: 2) {
            Text(durationLabel(minutes: v))
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(Color(red: 0.4, green: 0.78, blue: 1.0))
          }
          .cornerRadius(3)
        }
      }
      .chartYAxis(.hidden)
      .chartXAxis { chartXAxis(points) }
      .frame(height: 180)
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

  /// `destination` makes the header chevron a NavigationLink. Pass nil
  /// for trends that don't have a drill-down view yet (the chevron then
  /// renders as a non-tappable decoration).
  private func trendCard<C: View>(
    title: String,
    destination: AnyView? = nil,
    @ViewBuilder _ content: () -> C
  ) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let destination {
        NavigationLink { destination } label: {
          HStack {
            Text(title)
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .tracking(2)
              .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Image(systemName: "chevron.right")
              .font(.system(size: 11, weight: .semibold))
              .foregroundStyle(.white.opacity(0.55))
          }
        }
        .buttonStyle(.plain)
      } else {
        HStack {
          Text(title)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.7))
          Spacer()
          Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.25))
        }
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

  // MARK: - Data helpers

  private var selectedDayStrain: Double? {
    let key = Self.dateKey(for: selectedDay.currentDate)
    let todayKey = Self.dateKey(for: Date())
    if key == todayKey, let live = strainStore.today?.strain, live > 0 { return live }
    return dailyStore.byDate[key]?.strainScore
  }

  private var selectedDayStepCount: Double? {
    let key = Self.dateKey(for: selectedDay.currentDate)
    if let row = stepEstimator.history.first(where: { $0.dateKey == key }) {
      return row.estimatedSteps
    }
    if Calendar.current.isDateInToday(selectedDay.currentDate) {
      return stepEstimator.todayTotals.estimatedSteps
    }
    return nil
  }

  private var stepsBaselineMedian: Double? {
    let vals = stepEstimator.history
      .map(\.estimatedSteps)
      .filter { $0 > 0 }
    return Self.median(vals)
  }

  private func baselineMinutesInZones(_ zoneIDs: [Int]) -> Double? {
    // Without per-past-day zone breakdown stored, fall back to a static
    // "no baseline yet" — the row still renders with just the current
    // value. Surface a baseline once daily zone aggregates are persisted.
    _ = zoneIDs
    return nil
  }

  private func strengthActivityMinutes(for date: Date) -> Double? {
    let key = Self.dateKey(for: date)
    let total = workoutStore.workouts
      .filter { isStrength($0) && Self.dateKey(for: $0.startedAt) == key }
      .reduce(0.0) { $0 + $1.elapsedSeconds / 60.0 }
    return total > 0 ? total : 0
  }

  private func strengthActivityBaseline() -> Double? {
    let cal = Calendar.current
    let now = Date()
    guard let cutoff = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: now))
    else { return nil }
    let dayTotals = Dictionary(grouping: workoutStore.workouts.filter { $0.startedAt >= cutoff && isStrength($0) }) {
      Self.dateKey(for: $0.startedAt)
    }.mapValues { workouts in
      workouts.reduce(0.0) { $0 + $1.elapsedSeconds / 60.0 }
    }
    return Self.median(Array(dayTotals.values))
  }

  private func isStrength(_ workout: CompletedWorkout) -> Bool {
    let raw = workout.activityRaw.lowercased()
    return raw.contains("strength") || raw.contains("weight") || raw.contains("functional")
  }

  // MARK: - Formatting

  private func formatValue(_ value: Double?, as format: ValueFormat) -> String {
    guard let v = value else { return "--" }
    switch format {
    case .duration:
      return durationLabel(minutes: v)
    case .integer:
      let n = Int(v.rounded())
      return Self.numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
  }

  private func formatStepCount(_ n: Int) -> String {
    Self.numberFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
  }

  private func durationLabel(minutes: Double) -> String {
    let total = Int(minutes.rounded())
    let h = total / 60
    let m = total % 60
    return String(format: "%d:%02d", h, m)
  }

  private static let numberFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    return f
  }()

  private static func dateKey(for date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f.string(from: date)
  }

  private static func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let n = sorted.count
    return n % 2 == 1 ? sorted[n / 2] : (sorted[n / 2 - 1] + sorted[n / 2]) / 2
  }

  // MARK: - Direction + colors

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
    let threshold = max(1.0, b * 0.05)
    if higherIsBetter {
      if delta > threshold { return .better }
      if delta < -threshold { return .worse }
    } else {
      if delta < -threshold { return .better }
      if delta > threshold { return .worse }
    }
    return .neutral
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
