import Foundation
import SwiftUI

/// Holds the currently-selected day (the date strip selection). Replaces
/// `WhoopAPIClient.currentDate` which conflated cloud-fetch state with UI
/// selection. This store has no I/O — it's just the date.
@MainActor
final class SelectedDayStore: ObservableObject {
  static let shared = SelectedDayStore()

  @Published var currentDate: Date = Date()

  func select(_ date: Date) {
    currentDate = date
  }

  /// ISO yyyy-MM-dd in the device's local time zone — matches the keys
  /// used by `imported_daily_summary.date_key`.
  func isoDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f.string(from: date)
  }
}
