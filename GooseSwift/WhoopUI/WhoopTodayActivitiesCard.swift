import SwiftUI

/// Combined "today's activities" card — replaces the separate sleep card
/// + workouts card. Top row: last night's sleep summary. Bottom rows:
/// each completed workout. Tap a workout → WorkoutDetailView.
struct WhoopTodayActivitiesCard: View {
  @ObservedObject var client: WhoopAPIClient
  @ObservedObject private var workoutStore = CompletedWorkoutStore.shared
  @ObservedObject private var sleepStore = SleepWindowStore.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      sleepRow
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
        )

      ForEach(todaysWorkouts) { workout in
        NavigationLink {
          WorkoutDetailView(workout: workout)
        } label: {
          workoutRow(workout)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
              RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
      }

      if todaysWorkouts.isEmpty {
        Text("NO WORKOUTS YET")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.35))
          .frame(maxWidth: .infinity, alignment: .leading)
      }

      if Calendar.current.isDateInToday(client.currentDate) {
        NavigationLink {
          LiveActivityView()
        } label: {
          HStack(spacing: 8) {
            Image(systemName: "play.fill")
              .font(.system(size: 12, weight: .heavy))
            Text("START ACTIVITY")
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .tracking(1.5)
          }
          .foregroundStyle(.black)
          .frame(maxWidth: .infinity)
          .padding(.vertical, 10)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.white.opacity(0.95))
          )
        }
        .buttonStyle(.plain)
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var header: some View {
    HStack {
      Text("TODAY")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      Spacer()
    }
  }

  // MARK: - Sleep row

  private var sleepRow: some View {
    HStack(spacing: 12) {
      Image(systemName: "moon.zzz.fill")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(
          Circle().fill(Color(red: 0.55, green: 0.85, blue: 1.0).opacity(0.18))
        )

      VStack(alignment: .leading, spacing: 2) {
        Text("SLEEP")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white)
        Text(sleepSubtitle)
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 2) {
        Text(sleepDurationText)
          .font(.system(size: 15, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
        Text("DURATION")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
  }

  private var sleepSubtitle: String {
    if let stages = client.currentDay?.sleep?.stage_summary {
      let inBed = Self.formatMillis(stages.total_in_bed_time_milli)
      if let performance = client.currentDay?.sleep?.performance {
        return "\(inBed) in bed · \(Int(performance.rounded()))% performance"
      }
      return "\(inBed) in bed"
    }
    if let window = sleepStore.lastNight {
      let onset = Self.clockLabel(window.onset)
      let wake = Self.clockLabel(window.wake)
      return "\(onset) – \(wake) · LOCAL"
    }
    return "no sleep data yet"
  }

  private var sleepDurationText: String {
    if let stages = client.currentDay?.sleep?.stage_summary,
       let millis = stages.total_in_bed_time_milli {
      return Self.formatMillis(millis)
    }
    if let window = sleepStore.lastNight {
      let total = Int(window.durationSeconds.rounded())
      let h = total / 3600
      let m = (total % 3600) / 60
      return "\(h)h\(String(format: "%02d", m))m"
    }
    return "--"
  }

  // MARK: - Workout row

  private var todaysWorkouts: [CompletedWorkout] {
    // Filter against the *selected* date in the date strip, not always
    // today — so tapping a previous day surfaces that day's workouts.
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: client.currentDate)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    return workoutStore.workouts.filter {
      $0.startedAt >= dayStart && $0.startedAt < dayEnd
    }
  }

  private func workoutRow(_ workout: CompletedWorkout) -> some View {
    HStack(spacing: 12) {
      Image(systemName: Self.icon(for: workout.activityRaw))
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(
          Circle().fill(Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.18))
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(workout.activityTitle)
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(1)
        Text(metaLine(workout))
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 2) {
        Text(workout.maxHeartRate.map { "\($0)" } ?? "--")
          .font(.system(size: 15, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Color(red: 1.0, green: 0.37, blue: 0.42))
        Text("MAX HR")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
  }

  private func metaLine(_ workout: CompletedWorkout) -> String {
    var parts: [String] = []
    let mins = Int(workout.elapsedSeconds / 60)
    parts.append("\(mins)m")
    if let avg = workout.averageHeartRate { parts.append("avg \(avg)") }
    if workout.distanceMeters > 5 {
      parts.append(UnitFormatting.distanceCompact(meters: workout.distanceMeters))
    }
    let z345 = workout.zoneSeconds(3) + workout.zoneSeconds(4) + workout.zoneSeconds(5)
    if z345 > 0 {
      parts.append("Z3-5 \(Int(z345 / 60))m")
    }
    return parts.joined(separator: " · ")
  }

  // MARK: - Helpers

  private static func formatMillis(_ millis: Int?) -> String {
    guard let millis else { return "--" }
    let total = millis / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    return "\(h)h\(String(format: "%02d", m))m"
  }

  private static func clockLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
  }

  private static func icon(for raw: String) -> String {
    let t = raw.lowercased()
    if t.contains("run") { return "figure.run" }
    if t.contains("walk") { return "figure.walk" }
    if t.contains("cycl") || t.contains("bike") || t.contains("ride") { return "figure.outdoor.cycle" }
    if t.contains("swim") { return "figure.pool.swim" }
    if t.contains("weight") || t.contains("strength") { return "dumbbell" }
    if t.contains("yoga") { return "figure.yoga" }
    return "figure.mixed.cardio"
  }
}
