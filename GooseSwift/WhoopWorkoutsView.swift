import SwiftUI

struct WhoopWorkoutsView: View {
  @StateObject private var client = WhoopAPIClient.shared

  var body: some View {
    NavigationStack {
      ZStack {
        Self.background.ignoresSafeArea()
        ScrollView {
          LazyVStack(spacing: 12) {
            header

            if client.activities.isEmpty {
              if client.isLoading {
                ProgressView().tint(.white).padding(.top, 40)
              } else {
                Text("NO ACTIVITIES")
                  .font(.system(size: 11, weight: .heavy, design: .rounded))
                  .tracking(2)
                  .foregroundStyle(.white.opacity(0.4))
                  .padding(.top, 40)
              }
            }

            ForEach(client.activities) { activity in
              activityRow(activity)
            }
          }
          .padding(.horizontal, 18)
          .padding(.bottom, 32)
        }
        .refreshable {
          await client.loadActivities()
        }
      }
      .navigationBarHidden(true)
      .task {
        if client.activities.isEmpty {
          await client.loadActivities()
        }
      }
    }
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
      Text("\(client.activities.count)")
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .foregroundStyle(.white.opacity(0.6))
    }
    .padding(.top, 14)
    .padding(.bottom, 4)
  }

  private func activityRow(_ activity: WhoopActivity) -> some View {
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
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .overlay(alignment: .bottom) {
      detailStrip(activity)
    }
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
    .padding(.horizontal, 14)
    .padding(.bottom, 10)
    .offset(y: 22)
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
    if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
    return String(format: "%.0f m", meters)
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
