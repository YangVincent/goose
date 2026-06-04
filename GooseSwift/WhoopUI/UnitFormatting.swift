import Foundation

/// Centralized distance / pace / speed formatting that respects the user's
/// `OnboardingStorage.unitSystem` preference. All workout views, summary
/// cards, and history rows should go through here so unit changes in
/// Profile flow through automatically.
enum UnitFormatting {
  /// Pulls the current unit system from UserDefaults. Defaults to imperial
  /// (matches the existing app default).
  static var currentUnitSystem: UnitSystem {
    let raw = UserDefaults.standard.string(forKey: OnboardingStorage.unitSystem) ?? "imperial"
    return raw == "metric" ? .metric : .imperial
  }

  enum UnitSystem {
    case metric
    case imperial
  }

  // MARK: - Distance

  /// Format meters → "1.23 km" or "0.76 mi". For small values (< short
  /// distance) we use the small unit ("520 m" or "1700 ft").
  static func distance(meters: Double) -> String {
    switch currentUnitSystem {
    case .metric:
      if meters >= 1000 {
        return String(format: "%.2f km", meters / 1000)
      }
      return String(format: "%.0f m", meters)
    case .imperial:
      let miles = meters / 1609.344
      if miles >= 0.1 {
        return String(format: "%.2f mi", miles)
      }
      let feet = meters * 3.28084
      return String(format: "%.0f ft", feet)
    }
  }

  /// Shorter version for compact displays (rows / chips). "3.2 km" / "2.0 mi".
  static func distanceCompact(meters: Double) -> String {
    switch currentUnitSystem {
    case .metric:
      if meters >= 1000 {
        return String(format: "%.1f km", meters / 1000)
      }
      return String(format: "%.0f m", meters)
    case .imperial:
      let miles = meters / 1609.344
      if miles >= 0.1 {
        return String(format: "%.1f mi", miles)
      }
      let feet = meters * 3.28084
      return String(format: "%.0f ft", feet)
    }
  }

  // MARK: - Pace (seconds per unit)

  /// Format seconds-per-kilometer pace → "5:23 /km" or "8:40 /mi". Imperial
  /// converts km pace to mi pace by multiplying by `mi_per_km` ratio.
  static func pace(secondsPerKilometer: TimeInterval) -> String {
    guard secondsPerKilometer > 0, secondsPerKilometer.isFinite else { return "--" }
    switch currentUnitSystem {
    case .metric:
      return formatMinSec(secondsPerKilometer) + " /km"
    case .imperial:
      let secondsPerMile = secondsPerKilometer * 1.609344
      return formatMinSec(secondsPerMile) + " /mi"
    }
  }

  // MARK: - Speed (meters per second)

  /// Format m/s → "12.4 km/h" or "7.7 mph".
  static func speed(metersPerSecond: Double) -> String {
    guard metersPerSecond > 0 else { return "--" }
    switch currentUnitSystem {
    case .metric:
      return String(format: "%.1f km/h", metersPerSecond * 3.6)
    case .imperial:
      return String(format: "%.1f mph", metersPerSecond * 2.23694)
    }
  }

  /// Compute pace-style speed from distance over elapsed time.
  static func speed(distanceMeters: Double, elapsedSeconds: TimeInterval) -> String {
    guard elapsedSeconds > 0 else { return "--" }
    return speed(metersPerSecond: distanceMeters / elapsedSeconds)
  }

  // MARK: - Helpers

  private static func formatMinSec(_ totalSeconds: TimeInterval) -> String {
    let total = Int(totalSeconds.rounded())
    let minutes = total / 60
    let seconds = total % 60
    return String(format: "%d:%02d", minutes, seconds)
  }
}
