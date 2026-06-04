import Foundation

/// Single-source-of-truth for the user's physiological constants. All HR-zone
/// math (live workout, daily aggregates, WHOOP-age, server upload) reads
/// from here so the same number controls every screen.
///
/// Reverse-engineered to match WHOOP's reported zone bins for this user:
/// strain 0% at RHR ~54, 100% / Zone 5 floor at 187. If you want to retune
/// later, change `maxHeartRate` here and rebuild — no other call sites need
/// to be touched.
enum UserProfile {
  static let maxHeartRate: Int = 187
  static let restingHeartRate: Int = 54
}
