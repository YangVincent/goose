import CoreLocation
import MapKit
import SwiftUI

/// Detail view for a completed workout — opened by tapping a row in the
/// Workouts tab or the Home workout card. Surfaces every signal we
/// captured during the session: HR timeline, BPM distribution, zone
/// breakdown, calories estimate, distance / elevation if outdoor.
struct WorkoutDetailView: View {
  let workout: CompletedWorkout

  var body: some View {
    ZStack {
      Self.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 16) {
          heroSection

          summaryGrid

          if !workout.routePoints.isEmpty {
            NavigationLink {
              WorkoutRouteView(workout: workout)
            } label: {
              routePreviewCard
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
          }

          WorkoutHRTimelineView(workout: workout)
            .padding(.horizontal, 16)

          WorkoutHRHistogramView(
            startedAt: workout.startedAt,
            endedAt: workout.endedAt
          )
          .padding(.horizontal, 16)

          zoneBreakdownCard
            .padding(.horizontal, 16)

          metadataCard
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 32)
      }
    }
    .navigationTitle(workout.activityTitle)
    .navigationBarTitleDisplayMode(.inline)
  }

  private var heroSection: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(Self.dateLabel(workout.startedAt))
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      Text(workout.activityTitle)
        .font(.system(size: 26, weight: .heavy, design: .rounded))
        .foregroundStyle(.white)
      Text(durationLabel)
        .font(.system(size: 14, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.6))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 18)
    .padding(.top, 12)
  }

  private var summaryGrid: some View {
    HStack(spacing: 10) {
      summaryTile(label: "AVG HR", value: workout.averageHeartRate.map { "\($0)" } ?? "--", tint: Color(red: 1.0, green: 0.55, blue: 0.30))
      summaryTile(label: "MAX HR", value: workout.maxHeartRate.map { "\($0)" } ?? "--", tint: Color(red: 1.0, green: 0.37, blue: 0.42))
      summaryTile(label: "KCAL", value: caloriesLabel, tint: Color(red: 1.0, green: 0.88, blue: 0.40))
      if workout.distanceMeters > 5 {
        summaryTile(label: "DIST", value: distanceLabel, tint: Color(red: 0.55, green: 0.85, blue: 1.0))
        summaryTile(label: "AVG SPD", value: paceLabel, tint: Color(red: 0.30, green: 0.85, blue: 0.55))
      }
    }
    .padding(.horizontal, 16)
  }

  private func summaryTile(label: String, value: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 18, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(tint)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var routePreviewCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("ROUTE")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        Spacer()
        Text("\(workout.routePoints.count) PTS")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.45))
        Image(systemName: "arrow.up.right.square")
          .font(.system(size: 11, weight: .heavy))
          .foregroundStyle(.white.opacity(0.6))
      }
      Map(initialPosition: .region(Self.previewRegion(for: workout.routePoints)),
          interactionModes: []) {
        MapPolyline(coordinates: workout.routePoints.map {
          CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        })
        .stroke(
          Color(red: 0.18, green: 0.88, blue: 0.66),
          style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
        )
      }
      .mapStyle(.standard)
      .frame(height: 160)
      .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
      .allowsHitTesting(false)

      Text("TAP TO EXPLORE")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private static func previewRegion(for points: [CompletedWorkout.RoutePoint]) -> MKCoordinateRegion {
    guard !points.isEmpty else {
      return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
      )
    }
    let lats = points.map(\.latitude)
    let lons = points.map(\.longitude)
    let minLat = lats.min()!, maxLat = lats.max()!
    let minLon = lons.min()!, maxLon = lons.max()!
    return MKCoordinateRegion(
      center: CLLocationCoordinate2D(
        latitude: (minLat + maxLat) / 2,
        longitude: (minLon + maxLon) / 2
      ),
      span: MKCoordinateSpan(
        latitudeDelta: max((maxLat - minLat) * 1.4, 0.005),
        longitudeDelta: max((maxLon - minLon) * 1.4, 0.005)
      )
    )
  }

  private var zoneBreakdownCard: some View {
    FitnessZoneBreakdownCard(
      zoneDurations: workout.zoneDurations,
      totalElapsed: workout.elapsedSeconds
    )
  }

  private var metadataCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("PROVENANCE")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.4))
      keyValueRow(key: "SESSION ID", value: workout.id)
      keyValueRow(key: "SOURCE", value: workout.source)
      keyValueRow(key: "DETECTION", value: workout.detectionMethod)
      keyValueRow(key: "SYNC STATUS", value: workout.syncStatus)
      if workout.elevationGainMeters > 0.5 {
        keyValueRow(key: "ELEVATION", value: String(format: "%.0f m gain", workout.elevationGainMeters))
      }
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.03))
    )
  }

  private func keyValueRow(key: String, value: String) -> some View {
    HStack(alignment: .top) {
      Text(key)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))
        .frame(width: 110, alignment: .leading)
      Text(value)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(2)
        .truncationMode(.middle)
      Spacer()
    }
  }

  // MARK: - Helpers

  private var durationLabel: String {
    let total = Int(workout.elapsedSeconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
  }

  private var caloriesLabel: String {
    let kcal = Int(workout.elapsedSeconds / 8.0)
    return "\(kcal)"
  }

  private var distanceLabel: String {
    UnitFormatting.distance(meters: workout.distanceMeters)
  }

  private var paceLabel: String {
    UnitFormatting.speed(
      distanceMeters: workout.distanceMeters,
      elapsedSeconds: workout.elapsedSeconds
    )
  }

  private static func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEE MMM d • h:mm a"
    return formatter.string(from: date).uppercased()
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
