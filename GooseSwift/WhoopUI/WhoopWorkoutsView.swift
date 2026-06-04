import SwiftUI

struct WhoopWorkoutsView: View {
  @ObservedObject private var localWorkouts = CompletedWorkoutStore.shared

  var body: some View {
    NavigationStack {
      ZStack {
        Self.background.ignoresSafeArea()
        ScrollView {
          LazyVStack(spacing: 12) {
            header

            if localWorkouts.workouts.isEmpty {
              Text("NO ACTIVITIES")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.top, 40)
            }

            // All workouts read from local SQLite via CompletedWorkoutStore.
            // The historical WHOOP backfill via WhoopActivityImporter has
            // already populated this store; runtime cloud reads are gone.
            ForEach(localWorkouts.workouts) { workout in
              NavigationLink {
                WorkoutDetailView(workout: workout)
              } label: {
                localWorkoutRow(workout)
              }
              .buttonStyle(.plain)
            }
          }
          .padding(.horizontal, 18)
          .padding(.bottom, 32)
        }
        .refreshable {
          await localWorkouts.refresh()
        }
      }
      .navigationBarHidden(true)
      .task {
        await localWorkouts.refresh()
      }
    }
  }

  private func localWorkoutRow(_ workout: CompletedWorkout) -> some View {
    VStack(spacing: 12) {
      HStack(alignment: .center, spacing: 14) {
        Image(systemName: Self.icon(for: workout.activityRaw))
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(
            Circle().fill(Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.22))
          )

        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 6) {
            Text(workout.activityTitle)
              .font(.system(size: 15, weight: .bold, design: .rounded))
              .foregroundStyle(.white)
              .lineLimit(1)
            Text("LOCAL")
              .font(.system(size: 8, weight: .heavy, design: .rounded))
              .tracking(1)
              .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
              .padding(.horizontal, 4)
              .padding(.vertical, 2)
              .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                  .fill(Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.18))
              )
          }
          Text(Self.shortDateLabel(workout.startedAt))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }

        Spacer(minLength: 8)

        VStack(alignment: .trailing, spacing: 3) {
          Text(workout.maxHeartRate.map { "\($0)" } ?? "--")
            .font(.system(size: 17, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 1.0, green: 0.37, blue: 0.42))
          Text("MAX HR")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.45))
        }
      }

      localDetailStrip(workout)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private func localDetailStrip(_ workout: CompletedWorkout) -> some View {
    HStack(spacing: 16) {
      stat(label: "TIME", value: Self.shortDuration(workout.elapsedSeconds))
      stat(label: "AVG HR", value: workout.averageHeartRate.map { "\($0)" } ?? "--")
      if workout.distanceMeters > 5 {
        stat(label: "DIST", value: Self.distanceText(workout.distanceMeters))
      }
      stat(label: "Z3-Z5", value: Self.shortDuration(
        workout.zoneSeconds(3) + workout.zoneSeconds(4) + workout.zoneSeconds(5)
      ))
      Spacer(minLength: 0)
    }
  }

  private static func shortDateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE MMM d • h:mm a"
    return formatter.string(from: date)
  }

  private static func shortDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    if total >= 3600 {
      return String(format: "%dh%02dm", total / 3600, (total % 3600) / 60)
    }
    if total >= 60 {
      return "\(total / 60)m"
    }
    return "\(total)s"
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("RECENT")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text("WORKOUTS")
          .font(.system(size: 20, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white)
      }
      Spacer()
      Text("\(localWorkouts.workouts.count)")
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.6))
    }
    .padding(.top, 14)
    .padding(.bottom, 4)
  }

  private func activityRow(_ activity: WhoopActivity) -> some View {
    VStack(spacing: 12) {
      HStack(alignment: .center, spacing: 14) {
        Image(systemName: Self.icon(for: activity.type ?? activity.name ?? ""))
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .background(
            Circle().fill(Color.white.opacity(0.06))
          )

        VStack(alignment: .leading, spacing: 3) {
          Text((activity.name ?? "Activity").capitalized)
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .lineLimit(1)
          Text(Self.dateLabel(activity.date))
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }

        Spacer(minLength: 8)

        VStack(alignment: .trailing, spacing: 3) {
          Text(activity.strain.map { String(format: "%.1f", $0) } ?? "--")
            .font(.system(size: 17, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Self.strainColor(activity.strain ?? 0))
          Text("STRAIN")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.45))
        }
      }

      detailStrip(activity)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private func detailStrip(_ activity: WhoopActivity) -> some View {
    HStack(spacing: 16) {
      stat(label: "AVG HR", value: activity.avg_hr.map { "\($0)" } ?? "--")
      stat(label: "MAX HR", value: activity.max_hr.map { "\($0)" } ?? "--")
      if let distance = activity.distance, distance > 0 {
        stat(label: "DIST", value: Self.distanceText(distance))
      }
      stat(label: "KJ", value: activity.kilojoule.map { String(format: "%.0f", $0) } ?? "--")
      Spacer(minLength: 0)
    }
  }

  private func stat(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.4))
      Text(value)
        .font(.system(size: 11, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.75))
    }
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

  private static let isoFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
  }()

  private static let labelFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEE MMM d • h:mm a"
    return f
  }()

  private static func dateLabel(_ iso: String) -> String {
    let date = isoFormatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
    guard let date else { return iso.prefix(10).description }
    return labelFormatter.string(from: date)
  }

  private static let background = LinearGradient(
    colors: [
      Color(red: 0.02, green: 0.04, blue: 0.09),
      Color(red: 0.00, green: 0.00, blue: 0.03)
    ],
    startPoint: .top,
    endPoint: .bottom
  )
}
