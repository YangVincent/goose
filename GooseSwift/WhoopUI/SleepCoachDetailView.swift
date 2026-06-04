import SwiftUI
import Charts
import Foundation

/// Expanded sleep coach — math behind tonight's recommendation, recent
/// consistency, plain-English reasoning.
struct SleepCoachDetailView: View {
  @ObservedObject private var dayStrain: DayStrainStore = .shared
  @ObservedObject private var sleepStore = SleepWindowStore.shared
  @ObservedObject private var hrvStore = NightlyHRVStore.shared

  @AppStorage("goose.swift.sleepCoach.wakeHour") var wakeHour: Int = 7
  @AppStorage("goose.swift.sleepCoach.baselineHours") var baselineHours: Double = 8.0

  var body: some View {
    ZStack {
      WhoopHomeView.detailBackground.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          hero
          mathCard
          consistencyCard
          windDownCard
          wakeTimePicker
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("Sleep Coach")
    .navigationBarTitleDisplayMode(.large)
    .toolbarColorScheme(.dark, for: .navigationBar)
  }

  // MARK: - Hero

  private var rec: Recommendation { compute() }

  private var hero: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("TARGET BEDTIME")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      HStack(alignment: .lastTextBaseline) {
        Text(Self.clockLabel(rec.bedtime))
          .font(.system(size: 56, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("NEED").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
          Text(String(format: "%.1fh", rec.neededHours))
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
        }
      }
      Text(rec.coachLine)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(rec.severityColor)
    }
  }

  // MARK: - Math

  private var mathCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("MATH")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        mathRow("Baseline need", value: String(format: "%.1fh", baselineHours), note: "tunable below")
        mathRow("Strain surcharge", value: rec.strainBonus > 0 ? String(format: "+%.1fh", rec.strainBonus) : "0", note: rec.strainBonus > 0 ? "yesterday's strain > 10" : "no surcharge")
        mathRow("Recent debt", value: rec.debt > 0 ? String(format: "+%.1fh", rec.debt) : "0", note: "missed sleep last night")
        Divider().overlay(Color.white.opacity(0.1))
        mathRow("Tonight's need", value: String(format: "%.1fh", rec.neededHours), note: "sum", emphasize: true)
        mathRow("Wake at", value: Self.clockLabel(rec.wake), note: "set below")
        mathRow("→ bedtime", value: Self.clockLabel(rec.bedtime), note: "wake − need", emphasize: true)
      }
    }
  }

  private func mathRow(_ label: String, value: String, note: String, emphasize: Bool = false) -> some View {
    HStack {
      Text(label)
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(emphasize ? 0.85 : 0.6))
      Spacer()
      VStack(alignment: .trailing, spacing: 0) {
        Text(value)
          .font(.system(size: 14, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(emphasize ? Color(red: 0.55, green: 0.85, blue: 1.0) : .white)
        Text(note)
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
      }
    }
  }

  // MARK: - Consistency

  private var consistencyCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("CONSISTENCY (LAST 7 NIGHTS)")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        let nights = hrvStore.recentNights.suffix(7)
        if nights.count >= 3 {
          let onsetMins = nights.map { hour24Mins(of: $0.onset) }
          let wakeMins = nights.map { hour24Mins(of: $0.wake) }
          let onsetStd = std(onsetMins)
          let wakeStd = std(wakeMins)
          HStack(spacing: 14) {
            kv("BED σ", String(format: "±%.0fm", onsetStd))
            kv("WAKE σ", String(format: "±%.0fm", wakeStd))
            kv("NIGHTS", "\(nights.count)")
            Spacer(minLength: 0)
          }
          Text(consistencyComment(onsetStd: onsetStd, wakeStd: wakeStd))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Need 3+ nights of detected sleep windows.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
      }
    }
  }

  private func consistencyComment(onsetStd: Double, wakeStd: Double) -> String {
    if onsetStd < 20 && wakeStd < 20 {
      return "Excellent consistency. Your circadian system is reinforced — keep this rhythm."
    } else if onsetStd < 45 && wakeStd < 45 {
      return "Decent consistency. Tightening bedtime by ~20 min would lock in stronger circadian entrainment."
    } else {
      return "Variable schedule — large σ means your body keeps re-adjusting. Pick a fixed wake time first; bedtime follows."
    }
  }

  // MARK: - Wind-down + caffeine cutoffs

  private var windDownCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("PREP WINDOW")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        let bedtime = rec.bedtime
        let cal = Calendar.current
        let windDown = cal.date(byAdding: .minute, value: -45, to: bedtime) ?? bedtime
        let lastCaffeine = cal.date(byAdding: .hour, value: -8, to: bedtime) ?? bedtime
        let lastWorkout = cal.date(byAdding: .hour, value: -3, to: bedtime) ?? bedtime
        let lastMeal = cal.date(byAdding: .hour, value: -3, to: bedtime) ?? bedtime
        prepRow("Last caffeine", time: lastCaffeine, glyph: "cup.and.saucer.fill")
        prepRow("Last hard workout", time: lastWorkout, glyph: "figure.run")
        prepRow("Last meal", time: lastMeal, glyph: "fork.knife")
        prepRow("Wind down", time: windDown, glyph: "moon.zzz")
      }
    }
  }

  private func prepRow(_ label: String, time: Date, glyph: String) -> some View {
    HStack(spacing: 10) {
      Image(systemName: glyph)
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(.white.opacity(0.6))
        .frame(width: 20)
      Text(label)
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.7))
      Spacer()
      Text(Self.clockLabel(time))
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
  }

  // MARK: - Wake time picker

  private var wakeTimePicker: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("YOUR WAKE TARGET")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        HStack {
          Text("Wake hour")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
          Spacer()
          Stepper("\(formatHour(wakeHour))", value: $wakeHour, in: 4...11)
            .labelsHidden()
          Text(formatHour(wakeHour))
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
        HStack {
          Text("Baseline need")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.7))
          Spacer()
          Stepper(value: $baselineHours, in: 6.0...10.0, step: 0.25) {
            Text(String(format: "%.2fh", baselineHours))
          }
          .labelsHidden()
          Text(String(format: "%.2fh", baselineHours))
            .font(.system(size: 14, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
      }
    }
  }

  // MARK: - Recommendation

  private struct Recommendation {
    let bedtime: Date
    let wake: Date
    let neededHours: Double
    let strainBonus: Double
    let debt: Double
    let coachLine: String
    let severityColor: Color
  }

  private func compute() -> Recommendation {
    let strain = dayStrain.today?.strain ?? 0
    let strainBonus = max(0, (strain - 10) * 0.05)
    let debt = recentSleepDebt()
    let needed = baselineHours + strainBonus + debt
    let now = Date()
    let wake = nextOccurrence(hour: wakeHour, after: now)
    let bedtime = wake.addingTimeInterval(-needed * 3600)
    let untilSeconds = bedtime.timeIntervalSince(now)
    let coachLine: String
    let severityColor: Color
    if untilSeconds < 0 {
      coachLine = "Past target bedtime — start winding down now."
      severityColor = Color(red: 1.0, green: 0.37, blue: 0.42)
    } else if untilSeconds < 3600 {
      let mins = Int(untilSeconds / 60)
      coachLine = "Bed in \(mins) minutes. Start winding down now."
      severityColor = Color(red: 1.0, green: 0.55, blue: 0.30)
    } else {
      let hrs = Int(untilSeconds / 3600)
      let mins = Int((untilSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
      coachLine = "Bed in \(hrs)h \(mins)m. \(needed > baselineHours + 0.1 ? "Tonight needs extra; rest up." : "On track.")"
      severityColor = Color(red: 0.18, green: 0.88, blue: 0.66)
    }
    return Recommendation(
      bedtime: bedtime, wake: wake, neededHours: needed,
      strainBonus: strainBonus, debt: debt,
      coachLine: coachLine, severityColor: severityColor
    )
  }

  private func recentSleepDebt() -> Double {
    guard let window = sleepStore.lastNight else { return 0 }
    let need = baselineHours * 3600
    let actual = window.durationSeconds
    let deficit = max(0, need - actual) / 3600
    return min(1.5, deficit)
  }

  // MARK: - Helpers

  private func nextOccurrence(hour: Int, after date: Date) -> Date {
    var calendar = Calendar.current
    calendar.timeZone = TimeZone.current
    var components = calendar.dateComponents([.year, .month, .day], from: date)
    components.hour = hour
    components.minute = 0
    components.second = 0
    let candidate = calendar.date(from: components) ?? date
    if candidate <= date {
      return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate
    }
    return candidate
  }

  private func formatHour(_ h: Int) -> String {
    let suffix = h < 12 ? "AM" : "PM"
    let display = h == 0 ? 12 : (h > 12 ? h - 12 : h)
    return "\(display):00 \(suffix)"
  }

  private static func clockLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
  }

  private func hour24Mins(of date: Date) -> Int {
    let comp = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
  }

  private func std(_ values: [Int]) -> Double {
    guard values.count > 1 else { return 0 }
    let mean = Double(values.reduce(0, +)) / Double(values.count)
    let sq = values.map { Double($0) - mean }.map { $0 * $0 }
    let variance = sq.reduce(0.0, +) / Double(values.count - 1)
    return sqrt(variance)
  }

  private func kv(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
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
