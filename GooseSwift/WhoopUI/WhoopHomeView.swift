import SwiftUI

struct WhoopHomeView: View {
  @StateObject private var client = WhoopAPIClient.shared

  var body: some View {
    NavigationStack {
      content
        .navigationDestination(for: WhoopMetric.self) { metric in
          WhoopMetricDetailView(metric: metric, client: client)
        }
    }
  }

  private var content: some View {
    ZStack {
      Self.backgroundGradient.ignoresSafeArea()

      ScrollView {
        VStack(spacing: 20) {
          header

          if let error = client.lastError {
            Text(error)
              .font(.system(size: 11, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 1.0, green: 0.37, blue: 0.42))
              .multilineTextAlignment(.leading)
              .padding(.horizontal, 22)
              .frame(maxWidth: .infinity, alignment: .leading)
          }

          dateStrip
            .padding(.top, 4)

          WhoopTodaySection(client: client, activities: client.activities)

          NavigationLink(value: WhoopMetric.recovery) {
            recoveryRing
          }
          .buttonStyle(.plain)
          .padding(.top, 4)

          statGrid
            .padding(.horizontal, 18)

          NavigationLink(value: WhoopMetric.sleep) {
            sleepCard
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 18)

          NavigationLink(value: WhoopMetric.strain) {
            strainCard
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 18)
        }
        .padding(.bottom, 32)
      }
      .refreshable {
        await client.loadDay(client.currentDate)
        await client.loadCalendar()
      }
    }
    .task {
      if client.currentDay == nil {
        await client.loadCalendar()
        await client.loadDay(Date())
      }
      if client.activities.isEmpty {
        await client.loadActivities()
      }
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(selectedDayHeaderLabel.uppercased())
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text("OVERVIEW")
          .font(.system(size: 20, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white)
      }
      Spacer()
      if client.isLoading {
        ProgressView()
          .tint(.white)
      }
    }
    .padding(.horizontal, 22)
    .padding(.top, 10)
  }

  private var selectedDayHeaderLabel: String {
    let formatter = DateFormatter()
    if Calendar.current.isDateInToday(client.currentDate) {
      return "TODAY"
    }
    if Calendar.current.isDateInYesterday(client.currentDate) {
      return "YESTERDAY"
    }
    formatter.dateFormat = "EEEE, MMM d"
    return formatter.string(from: client.currentDate)
  }

  private var lastSyncedLabel: String {
    guard let dataDate = dataDateFromOverview() else {
      return "NO DATA"
    }
    let days = Calendar.current.dateComponents([.day], from: dataDate, to: Date()).day ?? 0
    if days <= 0 { return "DATA: TODAY" }
    if days == 1 { return "DATA: 1 DAY OLD" }
    return "DATA: \(days) DAYS OLD"
  }

  private var stalenessColor: Color {
    guard let dataDate = dataDateFromOverview() else {
      return Color.red.opacity(0.85)
    }
    let days = Calendar.current.dateComponents([.day], from: dataDate, to: Date()).day ?? 0
    if days <= 1 { return Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.85) }
    if days <= 3 { return Color(red: 1.0, green: 0.88, blue: 0.40).opacity(0.85) }
    return Color(red: 1.0, green: 0.37, blue: 0.42).opacity(0.85)
  }

  private func dataDateFromOverview() -> Date? {
    guard let startString = client.currentDay?.recovery?.start else { return nil }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: startString)
      ?? ISO8601DateFormatter().date(from: startString)
  }

  private var dateStrip: some View {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let days: [Date] = (0..<30).reversed().compactMap {
      calendar.date(byAdding: .day, value: -$0, to: today)
    }
    return ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 10) {
          ForEach(days, id: \.self) { day in
            dateChip(for: day)
              .id(day)
              .onTapGesture {
                Task { await client.loadDay(day) }
              }
          }
        }
        .padding(.horizontal, 22)
      }
      .onAppear {
        DispatchQueue.main.async {
          proxy.scrollTo(today, anchor: .trailing)
        }
      }
    }
  }

  private func dateChip(for day: Date) -> some View {
    let isoString = client.isoDate(day)
    let recoveryScore = client.recoveryScore(forISODate: isoString)
    let hasWorkout = client.hasWorkout(onISODate: isoString)
    let isSelected = Calendar.current.isDate(day, inSameDayAs: client.currentDate)
    let isToday = Calendar.current.isDateInToday(day)

    let weekday: String = {
      let f = DateFormatter()
      f.dateFormat = "EEE"
      return f.string(from: day).uppercased()
    }()
    let dayNum: String = {
      let f = DateFormatter()
      f.dateFormat = "d"
      return f.string(from: day)
    }()

    return VStack(spacing: 4) {
      Text(weekday)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(isSelected ? 0.85 : 0.45))

      Text(dayNum)
        .font(.system(size: 16, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(isSelected ? .white : .white.opacity(0.75))

      Circle()
        .fill(Self.recoveryColor(forPercent: recoveryScore.map { Int($0.rounded()) } ?? -1))
        .frame(width: 6, height: 6)
        .opacity(recoveryScore == nil ? 0.18 : 1)
    }
    .frame(width: 38, height: 64)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.025))
    )
    .overlay(alignment: .topTrailing) {
      if hasWorkout {
        Circle()
          .fill(Color.white.opacity(0.9))
          .frame(width: 5, height: 5)
          .padding(5)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isToday ? Self.strainColor.opacity(0.6) : Color.clear, lineWidth: 1)
    )
  }

  private var recoveryRing: some View {
    let score = client.currentDay?.recovery?.recovery_score
    let value = score.map { Int($0.rounded()) } ?? 0
    let color = Self.recoveryColor(forPercent: value)

    return ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: 18)

      Circle()
        .trim(from: 0, to: score == nil ? 0 : Double(value) / 100.0)
        .stroke(color, style: StrokeStyle(lineWidth: 18, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.6), radius: 12, x: 0, y: 0)

      VStack(spacing: 4) {
        Text(score == nil ? "--" : "\(value)")
          .font(.system(size: 84, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
          .minimumScaleFactor(0.5)

        Text("RECOVERY")
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .tracking(3)
          .foregroundStyle(color)
      }
      .padding(28)
    }
    .frame(width: 260, height: 260)
  }

  private var statGrid: some View {
    let recovery = client.currentDay?.recovery
    let sleep = client.currentDay?.sleep
    let strain = client.currentDay?.strain
    return LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
      spacing: 12
    ) {
      statTile(label: "HRV",        value: format(recovery?.hrv_rmssd_milli, unit: "ms", digits: 0))
      statTile(label: "RHR",        value: format(recovery?.resting_heart_rate, unit: "bpm", digits: 0))
      statTile(label: "SLEEP",      value: format(sleep?.performance, unit: "%", digits: 0))
      statTile(label: "STRAIN",     value: format(strain?.strain, unit: "", digits: 1))
      statTile(label: "SPO₂",       value: format(recovery?.spo2_percentage, unit: "%", digits: 0))
      statTile(label: "SKIN TEMP",  value: format(recovery?.skin_temp_celsius, unit: "°C", digits: 1))
    }
  }

  private func statTile(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      Text(value)
        .font(.system(size: 22, weight: .bold, design: .rounded))
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

  @ViewBuilder
  private var sleepCard: some View {
    if let stages = client.currentDay?.sleep?.stage_summary {
      cardSurface {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline) {
            Text("SLEEP")
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .tracking(2.5)
              .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(Self.formatMillis(stages.total_in_bed_time_milli))
              .font(.system(size: 20, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.white)
          }

          stageBar(stages: stages)
            .frame(height: 22)

          LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 8
          ) {
            stageRow(label: "DEEP", color: Self.stageDeep, millis: stages.total_slow_wave_sleep_time_milli)
            stageRow(label: "REM",  color: Self.stageREM,  millis: stages.total_rem_sleep_time_milli)
            stageRow(label: "LIGHT",color: Self.stageLight,millis: stages.total_light_sleep_time_milli)
            stageRow(label: "AWAKE",color: Self.stageAwake,millis: stages.total_awake_time_milli)
          }
        }
      }
    }
  }

  @ViewBuilder
  private var strainCard: some View {
    if let strain = client.currentDay?.strain?.strain {
      cardSurface {
        HStack(alignment: .center, spacing: 14) {
          VStack(alignment: .leading, spacing: 4) {
            Text("STRAIN")
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .tracking(2.5)
              .foregroundStyle(.white.opacity(0.6))
            Text(String(format: "%.1f", strain))
              .font(.system(size: 36, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.white)
            Text("of 21")
              .font(.system(size: 11, weight: .semibold, design: .rounded))
              .foregroundStyle(.white.opacity(0.5))
          }
          Spacer()
          ZStack {
            Circle()
              .stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle()
              .trim(from: 0, to: min(strain / 21.0, 1))
              .stroke(Self.strainColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 72, height: 72)
        }
      }
    }
  }

  private func stageBar(stages: WhoopOverview.StageSummary) -> some View {
    let total = max(
      (stages.total_slow_wave_sleep_time_milli ?? 0)
        + (stages.total_rem_sleep_time_milli ?? 0)
        + (stages.total_light_sleep_time_milli ?? 0)
        + (stages.total_awake_time_milli ?? 0),
      1
    )
    let segments: [(Int, Color)] = [
      (stages.total_slow_wave_sleep_time_milli ?? 0, Self.stageDeep),
      (stages.total_rem_sleep_time_milli ?? 0,        Self.stageREM),
      (stages.total_light_sleep_time_milli ?? 0,      Self.stageLight),
      (stages.total_awake_time_milli ?? 0,            Self.stageAwake)
    ]
    return GeometryReader { proxy in
      HStack(spacing: 2) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, entry in
          if entry.0 > 0 {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(entry.1)
              .frame(width: proxy.size.width * CGFloat(entry.0) / CGFloat(total))
          }
        }
      }
    }
  }

  private func stageRow(label: String, color: Color, millis: Int?) -> some View {
    HStack(spacing: 8) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.7))
      Spacer(minLength: 4)
      Text(Self.formatMillis(millis))
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
  }

  private func cardSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Self.cardBackground)
      )
  }

  private func format(_ value: Double?, unit: String, digits: Int) -> String {
    guard let value, value.isFinite else { return "--" }
    let formatted = String(format: "%.\(digits)f", value)
    return unit.isEmpty ? formatted : "\(formatted) \(unit)"
  }

  private var headerDateLabel: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d"
    return formatter.string(from: Date())
  }

  private static func formatMillis(_ value: Int?) -> String {
    guard let value, value > 0 else { return "--" }
    let totalMinutes = value / 60_000
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes)m" }
    return "\(hours)h \(minutes)m"
  }

  private static func recoveryColor(forPercent value: Int) -> Color {
    switch value {
    case 67...:    return Color(red: 0.18, green: 0.88, blue: 0.66)
    case 34...:    return Color(red: 1.0, green: 0.88, blue: 0.40)
    case 0...:     return Color(red: 1.0, green: 0.37, blue: 0.42)
    default:       return Color.white.opacity(0.3)
    }
  }

  private static let strainColor = Color(red: 0.30, green: 0.65, blue: 1.0)
  private static let stageDeep   = Color(red: 0.18, green: 0.40, blue: 0.95)
  private static let stageREM    = Color(red: 0.55, green: 0.35, blue: 1.0)
  private static let stageLight  = Color(red: 0.30, green: 0.65, blue: 1.0)
  private static let stageAwake  = Color(red: 1.0,  green: 0.55, blue: 0.30)

  private static let cardBackground = LinearGradient(
    colors: [
      Color(red: 0.05, green: 0.09, blue: 0.16),
      Color(red: 0.03, green: 0.05, blue: 0.10)
    ],
    startPoint: .top,
    endPoint: .bottom
  )

  private static let backgroundGradient = LinearGradient(
    colors: [
      Color(red: 0.02, green: 0.04, blue: 0.09),
      Color(red: 0.00, green: 0.00, blue: 0.03)
    ],
    startPoint: .top,
    endPoint: .bottom
  )
}

private extension WhoopOverview.StageSummary {
  func value(for stage: String) -> Int {
    switch stage {
    case "deep":  return total_slow_wave_sleep_time_milli ?? 0
    case "rem":   return total_rem_sleep_time_milli ?? 0
    case "light": return total_light_sleep_time_milli ?? 0
    case "awake": return total_awake_time_milli ?? 0
    default:      return 0
    }
  }
}
