import SwiftUI

/// Sleep-environment card surfaces the strap's PPG-adjacent sensors during
/// the user's overnight window — ambient light leakage (low = dark room),
/// skin temperature ADC, and skin-contact stability. WHOOP keeps these
/// server-side; we keep them on-device, so this view validates that the
/// raw channels we persist are actually useful for sleep quality.
struct WhoopSleepEnvironmentCard: View {
  @State private var snapshot: Snapshot?
  @ObservedObject private var sleepStore = SleepWindowStore.shared

  /// Sleep window defaults: last night 22:00 → today 09:00 local. We don't
  /// have a "sleep onset detected" signal yet — when we do, this becomes a
  /// per-night exact window.
  private static let defaultStartHour = 22
  private static let defaultEndHour = 9

  struct Snapshot {
    let sampleCount: Int
    let ambientMean: Double?
    let ambientMax: Double?
    let ambientReadings: [Double]
    let skinTempMean: Double?
    let skinTempReadings: [Double]
    let skinContactOnPercent: Double
    let windowStart: Date
    let windowEnd: Date
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      detectedWindowRow

      if let snapshot, snapshot.sampleCount > 0 {
        contentRow(snapshot)
        chartsRow(snapshot)
      } else {
        emptyState
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .onAppear { refresh() }
  }

  private func refresh() {
    // Prefer the detected sleep window if the local detector found one;
    // fall back to the hard-coded 22:00→09:00 window otherwise.
    SleepWindowStore.shared.refresh()
    let (start, end): (Date, Date)
    if let detected = SleepWindowStore.shared.lastNight {
      start = detected.onset
      end = detected.wake
    } else {
      (start, end) = Self.lastNightWindow(now: Date())
    }
    let samples = SensorSampleStore.shared.snapshot(from: start, to: end)
    let ambient = samples.compactMap { $0.ambientLight.map(Double.init) }
    let skin = samples.compactMap { $0.skinTempRaw.map(Double.init) }
    let contacts = samples.compactMap { $0.skinContact }
    let onCount = contacts.filter { $0 != 0 }.count

    snapshot = Snapshot(
      sampleCount: samples.count,
      ambientMean: average(ambient),
      ambientMax: ambient.max(),
      ambientReadings: Array(ambient.suffix(120)),
      skinTempMean: average(skin),
      skinTempReadings: Array(skin.suffix(120)),
      skinContactOnPercent: contacts.isEmpty ? 0 : Double(onCount) / Double(contacts.count) * 100,
      windowStart: start,
      windowEnd: end
    )
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("SLEEP ENVIRONMENT")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text(headlineText)
          .font(.system(size: 15, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
      }
      Spacer()
      if let snapshot {
        Text("\(snapshot.sampleCount) samples")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
  }

  private var headlineText: String {
    guard let snapshot, snapshot.sampleCount > 0 else { return "WAITING FOR DATA" }
    return darknessLabel(for: snapshot.ambientMean)
  }

  @ViewBuilder private var detectedWindowRow: some View {
    if let window = sleepStore.lastNight {
      HStack(spacing: 12) {
        sleepStat(label: "ASLEEP", value: Self.clockLabel(window.onset))
        sleepStat(label: "WAKE", value: Self.clockLabel(window.wake))
        sleepStat(
          label: "DURATION",
          value: Self.durationLabel(window.durationSeconds)
        )
        sleepStat(
          label: "PERF",
          value: String(format: "%.0f%%", window.performance * 100)
        )
        Spacer()
      }
      Text(String(
        format: "RHR baseline %.0f bpm · confidence %.0f%%",
        window.restingHRBaseline,
        window.confidence * 100
      ))
      .font(.system(size: 9, weight: .heavy, design: .rounded))
      .tracking(1)
      .foregroundStyle(.white.opacity(0.4))
    }
  }

  private func sleepStat(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
    }
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private static func clockLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
  }

  private static func durationLabel(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    return "\(h)h \(String(format: "%02d", m))m"
  }

  private func darknessLabel(for ambientMean: Double?) -> String {
    guard let mean = ambientMean else { return "—" }
    if mean < 30 { return "DARK ROOM" }
    if mean < 120 { return "DIM" }
    if mean < 500 { return "LIGHT BLEED" }
    return "VERY BRIGHT"
  }

  private var emptyState: some View {
    HStack(spacing: 10) {
      Image(systemName: "moon.zzz")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white.opacity(0.35))
      Text("No overnight sensor data yet. Wear the strap to bed.")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
      Spacer()
    }
  }

  private func contentRow(_ snapshot: Snapshot) -> some View {
    HStack(spacing: 10) {
      statCell(
        label: "AVG LIGHT",
        value: snapshot.ambientMean.map { String(format: "%.0f", $0) } ?? "--",
        tint: Color(red: 1.0, green: 0.88, blue: 0.40)
      )
      statCell(
        label: "PEAK LIGHT",
        value: snapshot.ambientMax.map { String(format: "%.0f", $0) } ?? "--",
        tint: Color(red: 1.0, green: 0.55, blue: 0.30)
      )
      statCell(
        label: "SKIN TEMP",
        value: snapshot.skinTempMean.map { String(format: "%.0f", $0) } ?? "--",
        tint: Color(red: 0.85, green: 0.55, blue: 1.0)
      )
      statCell(
        label: "CONTACT",
        value: String(format: "%.0f%%", snapshot.skinContactOnPercent),
        tint: snapshot.skinContactOnPercent > 80
          ? Color(red: 0.18, green: 0.88, blue: 0.66)
          : Color(red: 1.0, green: 0.37, blue: 0.42)
      )
    }
  }

  private func statCell(label: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.45))
      Text(value)
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(tint)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private func chartsRow(_ snapshot: Snapshot) -> some View {
    HStack(spacing: 12) {
      miniChart(values: snapshot.ambientReadings, label: "LIGHT", tint: Color(red: 1.0, green: 0.88, blue: 0.40))
      miniChart(values: snapshot.skinTempReadings, label: "SKIN", tint: Color(red: 0.85, green: 0.55, blue: 1.0))
    }
  }

  private func miniChart(values: [Double], label: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.45))
      Sparkline(values: values, tint: tint)
        .frame(height: 42)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(0.03))
    )
  }

  // MARK: - Helpers

  private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
  }

  /// Returns last night's sleep window using local time.
  ///
  /// - If now is BEFORE the morning end hour: use yesterday 22:00 → today
  ///   end-hour.
  /// - If now is AT/AFTER end hour: use last night 22:00 → today end-hour
  ///   (frozen — we surface the prior sleep until evening rolls in).
  private static func lastNightWindow(now: Date) -> (Date, Date) {
    var calendar = Calendar.current
    calendar.timeZone = TimeZone.current
    let dayStart = calendar.startOfDay(for: now)
    let endHour = calendar.date(byAdding: .hour, value: defaultEndHour, to: dayStart) ?? dayStart
    let startBaseDay = calendar.date(byAdding: .day, value: -1, to: dayStart) ?? dayStart
    let startHour = calendar.date(byAdding: .hour, value: defaultStartHour, to: startBaseDay) ?? startBaseDay
    return (startHour, endHour)
  }
}
