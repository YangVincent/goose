import SwiftUI

/// Sleep coach — recommends tonight's bedtime based on:
///   - Today's day strain (high strain → more sleep needed)
///   - Recent sleep debt (last 3 nights, if we have local sleep window data)
///   - Default wake time (server-configurable later; for now 7:00 AM)
///
/// Output: target bedtime + a "go to bed in X" countdown.
struct WhoopBedtimeRecommendationCard: View {
  @ObservedObject var dayStrain: DayStrainStore = .shared
  let wakeHour: Int = 7

  var body: some View {
    let recommendation = computeRecommendation()
    return VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("SLEEP COACH")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Spacer()
        Text(recommendation.severityLabel.uppercased())
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(recommendation.severityColor)
          .padding(.horizontal, 6)
          .padding(.vertical, 3)
          .background(Capsule(style: .continuous).fill(recommendation.severityColor.opacity(0.15)))
      }

      HStack(alignment: .firstTextBaseline, spacing: 10) {
        VStack(alignment: .leading, spacing: 2) {
          Text("TARGET BEDTIME")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.5))
          Text(Self.clockLabel(recommendation.bedtime))
            .font(.system(size: 28, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 2) {
          Text("NEEDED")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.5))
          Text(String(format: "%.1fh", recommendation.neededHours))
            .font(.system(size: 18, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
        }
      }

      Text(recommendation.coachLine)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.75))
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private struct Recommendation {
    let bedtime: Date
    let neededHours: Double
    let coachLine: String
    let severityLabel: String
    let severityColor: Color
  }

  private func computeRecommendation() -> Recommendation {
    let baseline: Double = 8.0
    let strain = dayStrain.today?.strain ?? 0
    let strainBonus = max(0, (strain - 10) * 0.05)  // each strain point above 10 = +3min
    let debt = recentSleepDebt()
    let needed = baseline + strainBonus + debt
    let now = Date()
    let wake = nextOccurrence(hour: wakeHour, after: now)
    let bedtime = wake.addingTimeInterval(-needed * 3600)

    let untilSeconds = bedtime.timeIntervalSince(now)
    let coachLine: String
    let severityLabel: String
    let severityColor: Color
    if untilSeconds < 0 {
      coachLine = "You're past target bedtime — wind down now."
      severityLabel = "Late"
      severityColor = Color(red: 1.0, green: 0.37, blue: 0.42)
    } else if untilSeconds < 3600 {
      let mins = Int(untilSeconds / 60)
      coachLine = "Go to bed in \(mins) min. \(needed > baseline + 0.1 ? "Strain-adjusted." : "")"
      severityLabel = "Soon"
      severityColor = Color(red: 1.0, green: 0.55, blue: 0.30)
    } else {
      let hrs = Int(untilSeconds / 3600)
      let mins = Int((untilSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
      coachLine = "Target bedtime in \(hrs)h \(mins)m. \(needed > baseline + 0.1 ? "Need extra recovery." : "")"
      severityLabel = "On Track"
      severityColor = Color(red: 0.18, green: 0.88, blue: 0.66)
    }
    return Recommendation(
      bedtime: bedtime,
      neededHours: needed,
      coachLine: coachLine,
      severityLabel: severityLabel,
      severityColor: severityColor
    )
  }

  /// Accumulated sleep debt over the last 3 nights (capped at +1.5h to
  /// avoid runaway recommendations). NightlyHRVStore + SleepWindowStore
  /// were deleted; sleep debt now uses dailyStore.summary.sleepInBedMs
  /// against an 8h need target.
  private func recentSleepDebt() -> Double {
    let summary = WhoopImportedDailyStore.shared.summary(for: Date())
    guard let inBedMs = summary?.sleepInBedMs, inBedMs > 0 else { return 0 }
    let need = 8.0 * 3600
    let actual = Double(inBedMs) / 1000
    let deficit = max(0, need - actual) / 3600
    return min(1.5, deficit)
  }

  // MARK: - Time helpers

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

  private static func clockLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "h:mm a"
    return formatter.string(from: date)
  }
}
