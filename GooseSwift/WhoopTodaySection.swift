import SwiftUI

struct WhoopTodaySection: View {
  @ObservedObject var client: WhoopAPIClient
  let activities: [WhoopActivity]

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header
      VStack(spacing: 8) {
        if let sleep = client.currentDay?.sleep, sleep.start != nil {
          sleepRow(sleep)
        }
        ForEach(todaysActivities) { activity in
          activityRow(activity)
        }
        if let target = sleepTonight {
          sleepTonightRow(target)
        }
      }
    }
    .padding(.horizontal, 18)
  }

  private var header: some View {
    Text("TODAY")
      .font(.system(size: 11, weight: .heavy, design: .rounded))
      .tracking(2.5)
      .foregroundStyle(.white.opacity(0.55))
      .padding(.leading, 4)
  }

  private func sleepRow(_ sleep: WhoopOverview.Sleep) -> some View {
    HStack(spacing: 14) {
      iconCircle(systemName: "moon.fill", tint: Self.sleepTint)

      VStack(alignment: .leading, spacing: 3) {
        Text("Sleep")
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
        Text(sleepSubtitle(sleep))
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 3) {
        Text(sleep.performance.map { "\(Int($0.rounded()))" } ?? "--")
          .font(.system(size: 17, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Self.sleepTint)
        Text("PERFORMANCE")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
    .padding(12)
    .background(rowBackground)
  }

  private func activityRow(_ activity: WhoopActivity) -> some View {
    HStack(spacing: 14) {
      iconCircle(systemName: Self.icon(for: activity.type ?? activity.name ?? ""), tint: Self.strainTint(activity.strain ?? 0))

      VStack(alignment: .leading, spacing: 3) {
        Text((activity.name ?? "Activity").capitalized)
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
        Text(activitySubtitle(activity))
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 3) {
        Text(activity.strain.map { String(format: "%.1f", $0) } ?? "--")
          .font(.system(size: 17, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Self.strainTint(activity.strain ?? 0))
        Text("STRAIN")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
    .padding(12)
    .background(rowBackground)
  }

  private func sleepTonightRow(_ target: SleepTarget) -> some View {
    HStack(spacing: 14) {
      iconCircle(systemName: "bed.double.fill", tint: Self.recommendTint)

      VStack(alignment: .leading, spacing: 3) {
        Text("Sleep by \(target.bedtimeText)")
          .font(.system(size: 15, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
        Text("\(target.neededText) needed • wake \(target.wakeText)")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 3) {
        Text(target.neededText)
          .font(.system(size: 17, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Self.recommendTint)
        Text("TONIGHT")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
    .padding(12)
    .background(rowBackground)
  }

  private func iconCircle(systemName: String, tint: Color) -> some View {
    Image(systemName: systemName)
      .font(.system(size: 17, weight: .semibold))
      .foregroundStyle(tint)
      .frame(width: 38, height: 38)
      .background(Circle().fill(tint.opacity(0.16)))
  }

  private var rowBackground: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(Color.white.opacity(0.04))
  }

  private var todaysActivities: [WhoopActivity] {
    let cal = Calendar.current
    let target = cal.startOfDay(for: client.currentDate)
    return activities.filter { activity in
      guard let date = Self.isoFormatter.date(from: activity.date) ?? ISO8601DateFormatter().date(from: activity.date) else { return false }
      return cal.isDate(date, inSameDayAs: target)
    }
  }

  private struct SleepTarget {
    let bedtimeText: String
    let neededText: String
    let wakeText: String
  }

  private var sleepTonight: SleepTarget? {
    guard let sleep = client.currentDay?.sleep,
          let needed = sleep.sleep_needed,
          let baseline = needed.baseline_milli else {
      return nil
    }
    let totalNeededMillis = baseline
      + (needed.need_from_sleep_debt_milli ?? 0)
      + (needed.need_from_recent_strain_milli ?? 0)
      - (needed.need_from_recent_nap_milli ?? 0)
    let totalNeededSec = Double(totalNeededMillis) / 1000.0

    let wakeHour = preferredWakeHour(sleep)
    let cal = Calendar.current
    let tomorrowStart = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date())) ?? Date()
    guard let wakeDate = cal.date(bySettingHour: wakeHour, minute: 0, second: 0, of: tomorrowStart),
          let bedtime = cal.date(byAdding: .second, value: -Int(totalNeededSec), to: wakeDate) else {
      return nil
    }
    let timeFormatter = DateFormatter()
    timeFormatter.dateFormat = "h:mm a"
    return SleepTarget(
      bedtimeText: timeFormatter.string(from: bedtime),
      neededText: Self.formatDurationMillis(totalNeededMillis),
      wakeText: timeFormatter.string(from: wakeDate)
    )
  }

  private func preferredWakeHour(_ sleep: WhoopOverview.Sleep) -> Int {
    guard let end = sleep.end,
          let endDate = Self.isoFormatter.date(from: end) ?? ISO8601DateFormatter().date(from: end) else {
      return 7
    }
    return Calendar.current.component(.hour, from: endDate)
  }

  private func sleepSubtitle(_ sleep: WhoopOverview.Sleep) -> String {
    let stages = sleep.stage_summary
    let inBed = Self.formatDurationMillis(stages?.total_in_bed_time_milli)
    let start = Self.timeText(sleep.start)
    let end = Self.timeText(sleep.end)
    if start != nil, end != nil {
      return "\(inBed) • \(start!)–\(end!)"
    }
    return inBed
  }

  private func activitySubtitle(_ activity: WhoopActivity) -> String {
    var parts: [String] = []
    if let dist = activity.distance, dist > 0 { parts.append(Self.distanceText(dist)) }
    if let avgHR = activity.avg_hr { parts.append("\(avgHR) avg HR") }
    if let kj = activity.kilojoule { parts.append("\(Int(kj.rounded())) kJ") }
    return parts.joined(separator: " • ")
  }

  private static func formatDurationMillis(_ value: Int?) -> String {
    guard let value, value > 0 else { return "--" }
    let m = value / 60_000
    let h = m / 60
    let r = m % 60
    if h == 0 { return "\(r)m" }
    return "\(h)h \(r)m"
  }

  private static func timeText(_ iso: String?) -> String? {
    guard let iso, let date = isoFormatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) else { return nil }
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
  }

  private static func distanceText(_ meters: Double) -> String {
    if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
    return String(format: "%.0f m", meters)
  }

  private static func strainTint(_ strain: Double) -> Color {
    if strain >= 14 { return Color(red: 1.0, green: 0.37, blue: 0.42) }
    if strain >= 8  { return Color(red: 1.0, green: 0.88, blue: 0.40) }
    return Color(red: 0.18, green: 0.88, blue: 0.66)
  }

  private static func icon(for type: String) -> String {
    let t = type.lowercased()
    if t.contains("run") { return "figure.run" }
    if t.contains("walk") { return "figure.walk" }
    if t.contains("cycl") || t.contains("bike") { return "figure.outdoor.cycle" }
    if t.contains("swim") { return "figure.pool.swim" }
    if t.contains("weight") || t.contains("strength") { return "dumbbell" }
    if t.contains("yoga") { return "figure.yoga" }
    return "figure.mixed.cardio"
  }

  private static let sleepTint = Color(red: 0.55, green: 0.35, blue: 1.0)
  private static let recommendTint = Color(red: 0.30, green: 0.65, blue: 1.0)

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()
}
