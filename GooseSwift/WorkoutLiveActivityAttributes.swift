import ActivityKit
import Foundation

struct WorkoutLiveActivityAttributes: ActivityAttributes {
  struct ContentState: Codable, Hashable {
    var status: String
    var timerStartDate: Date?
    var elapsedSeconds: TimeInterval
    var currentHeartRate: Int?
    var averageHeartRate: Int?
    var maxHeartRate: Int?
    var activeCalories: Int
    var distanceMeters: Double?
    var isPaused: Bool
    var updatedAt: Date
    /// Current zone (1...5) based on `currentHeartRate / HRmax`. Nil while HR
    /// is missing. Lock-screen widget highlights the corresponding pip in
    /// the zone ribbon.
    var currentZone: Int?
    /// Seconds accumulated in each zone, packed as a 5-element array so the
    /// widget extension can read it without sharing the `[Int: Double]`
    /// dictionary type.
    var zoneSecondsZ1Z5: [Double]
  }

  var sessionID: String
  var activityName: String
  var activitySystemImage: String
  var activityTintHex: String
  var environmentName: String
  var usesGPS: Bool
}
