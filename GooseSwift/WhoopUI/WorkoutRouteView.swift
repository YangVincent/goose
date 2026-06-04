import CoreLocation
import MapKit
import SwiftUI

/// Full-screen route map for a completed workout. Tappable from the
/// workout detail view. Plots the persisted route polyline plus start/end
/// pins.
struct WorkoutRouteView: View {
  let workout: CompletedWorkout

  @State private var cameraPosition: MapCameraPosition

  init(workout: CompletedWorkout) {
    self.workout = workout
    let coordinates = workout.routePoints.map {
      CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
    }
    let region = Self.regionFor(coordinates: coordinates)
    self._cameraPosition = State(initialValue: .region(region))
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      mapView
      summaryPill
    }
    .ignoresSafeArea(edges: .top)
    .navigationTitle("Route")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var mapView: some View {
    Map(position: $cameraPosition) {
      if !workout.routePoints.isEmpty {
        MapPolyline(coordinates: workout.routePoints.map {
          CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)
        })
        .stroke(
          Color(red: 0.18, green: 0.88, blue: 0.66),
          style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
        )
      }
      if let start = workout.routePoints.first {
        Marker("Start", systemImage: "play.fill",
               coordinate: CLLocationCoordinate2D(latitude: start.latitude, longitude: start.longitude))
          .tint(Color(red: 0.18, green: 0.88, blue: 0.66))
      }
      if let end = workout.routePoints.last, workout.routePoints.count > 1 {
        Marker("End", systemImage: "flag.checkered",
               coordinate: CLLocationCoordinate2D(latitude: end.latitude, longitude: end.longitude))
          .tint(Color(red: 1.0, green: 0.37, blue: 0.42))
      }
    }
    .mapStyle(.standard(elevation: .realistic))
    .mapControls {
      MapUserLocationButton()
      MapCompass()
      MapScaleView()
    }
  }

  private var summaryPill: some View {
    HStack(spacing: 16) {
      pillStat(label: "DIST", value: UnitFormatting.distance(meters: workout.distanceMeters))
      pillStat(label: "TIME", value: durationLabel)
      pillStat(label: "AVG", value: paceLabel)
      pillStat(label: "PTS", value: "\(workout.routePoints.count)")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(.ultraThinMaterial)
    )
    .padding(.horizontal, 16)
    .padding(.bottom, 24)
  }

  private func pillStat(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.primary)
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

  private var paceLabel: String {
    UnitFormatting.speed(
      distanceMeters: workout.distanceMeters,
      elapsedSeconds: workout.elapsedSeconds
    )
  }

  private static func regionFor(coordinates: [CLLocationCoordinate2D]) -> MKCoordinateRegion {
    guard !coordinates.isEmpty else {
      return MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194),
        span: MKCoordinateSpan(latitudeDelta: 0.05, longitudeDelta: 0.05)
      )
    }
    let lats = coordinates.map(\.latitude)
    let lons = coordinates.map(\.longitude)
    let minLat = lats.min() ?? 0
    let maxLat = lats.max() ?? 0
    let minLon = lons.min() ?? 0
    let maxLon = lons.max() ?? 0
    let center = CLLocationCoordinate2D(
      latitude: (minLat + maxLat) / 2,
      longitude: (minLon + maxLon) / 2
    )
    let span = MKCoordinateSpan(
      latitudeDelta: max((maxLat - minLat) * 1.3, 0.005),
      longitudeDelta: max((maxLon - minLon) * 1.3, 0.005)
    )
    return MKCoordinateRegion(center: center, span: span)
  }
}
