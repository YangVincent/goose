import SwiftUI

/// Home-screen card that surfaces the workouts (activities) recorded on the
/// currently-selected day. Tappable rows route into the existing Workouts tab
/// path via `WhoopMetric.strain` (the closest existing metric detail).
struct WhoopWorkoutHomeCard: View {
  @ObservedObject var client: WhoopAPIClient
  @ObservedObject var localWorkouts: CompletedWorkoutStore = .shared

  var body: some View {
    let activities = todaysActivities
    let locals = todaysLocalWorkouts
    return VStack(alignment: .leading, spacing: 14) {
      header(count: activities.count + locals.count)

      if activities.isEmpty && locals.isEmpty {
        emptyState
      } else {
        VStack(spacing: 10) {
          ForEach(locals) { workout in
            NavigationLink {
              WorkoutDetailView(workout: workout)
            } label: {
              localWorkoutRow(workout)
            }
            .buttonStyle(.plain)
          }
          ForEach(activities) { activity in
            activityRow(activity)
          }
        }
      }

      NavigationLink {
        LiveActivityView()
      } label: {
        HStack(spacing: 8) {
          Image(systemName: "play.fill")
            .font(.system(size: 11, weight: .heavy))
          Text("START WORKOUT")
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
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var todaysActivities: [WhoopActivity] {
    let iso = client.isoDate(client.currentDate)
    return client.activities.filter { activity in
      String(activity.date.prefix(10)) == iso
    }
  }

  private var todaysLocalWorkouts: [CompletedWorkout] {
    let iso = client.isoDate(client.currentDate)
    return localWorkouts.workouts(onISODate: iso)
  }

  private func localWorkoutRow(_ workout: CompletedWorkout) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: Self.icon(for: workout.activityRaw))
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(Circle().fill(Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.18)))

      VStack(alignment: .leading, spacing: 2) {
        Text(workout.activityRaw.capitalized)
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(1)
        Text(localMetaLine(workout))
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
          .tracking(1.2)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
  }

  private func localMetaLine(_ workout: CompletedWorkout) -> String {
    var parts: [String] = ["LOCAL"]
    let mins = Int(workout.elapsedSeconds / 60)
    parts.append("\(mins)m")
    if let avg = workout.averageHeartRate { parts.append("avg \(avg) bpm") }
    if workout.distanceMeters > 5 {
      parts.append(Self.distanceText(workout.distanceMeters))
    }
    return parts.joined(separator: " · ")
  }

  private func header(count: Int) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("WORKOUTS")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text(headlineText(for: count))
          .font(.system(size: 16, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
      }
      Spacer()
      if count > 0 {
        Text("\(count)")
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.55))
      }
    }
  }

  private func headlineText(for count: Int) -> String {
    if count == 0 { return "NO WORKOUTS" }
    if count == 1 { return "1 SESSION" }
    return "\(count) SESSIONS"
  }

  private var emptyState: some View {
    HStack(spacing: 10) {
      Image(systemName: "figure.mixed.cardio")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white.opacity(0.35))
      Text("Nothing logged for this day yet.")
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.45))
      Spacer()
    }
  }

  private func activityRow(_ activity: WhoopActivity) -> some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: Self.icon(for: activity.type ?? activity.name ?? ""))
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white)
        .frame(width: 34, height: 34)
        .background(Circle().fill(Color.white.opacity(0.07)))

      VStack(alignment: .leading, spacing: 2) {
        Text((activity.name ?? "Activity").capitalized)
          .font(.system(size: 13, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
          .lineLimit(1)
        Text(metaLine(activity))
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
      }

      Spacer(minLength: 8)

      VStack(alignment: .trailing, spacing: 2) {
        Text(activity.strain.map { String(format: "%.1f", $0) } ?? "--")
          .font(.system(size: 15, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Self.strainColor(activity.strain ?? 0))
        Text("STRAIN")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1.2)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
  }

  private func metaLine(_ activity: WhoopActivity) -> String {
    var parts: [String] = []
    if let max = activity.max_hr { parts.append("max \(max) bpm") }
    if let moving = activity.moving_time, moving > 0 {
      parts.append(Self.durationText(moving))
    }
    if let distance = activity.distance, distance > 0 {
      parts.append(Self.distanceText(distance))
    }
    if let kj = activity.kilojoule, kj > 0 {
      parts.append("\(Int(kj.rounded())) kJ")
    }
    return parts.joined(separator: " · ")
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

  private static func strainColor(_ strain: Double) -> Color {
    if strain >= 14 { return Color(red: 1.0, green: 0.37, blue: 0.42) }
    if strain >= 8  { return Color(red: 1.0, green: 0.88, blue: 0.40) }
    return Color(red: 0.18, green: 0.88, blue: 0.66)
  }

  private static func distanceText(_ meters: Double) -> String {
    UnitFormatting.distanceCompact(meters: meters)
  }

  private static func durationText(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return String(format: "%dh %02dm", h, m) }
    return "\(m)m"
  }
}
