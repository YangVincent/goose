import SwiftUI

/// Surfaced on Home only when the personal HR peak detector spots that the
/// user's configured HRmax is likely too low. Read-only for now — see
/// `PersonalHRPeakDetector` for the threshold logic.
struct WhoopHRMaxAdvisoryCard: View {
  @ObservedObject var store: PersonalHRPeakStore = .shared

  var body: some View {
    if let report = store.report, report.suggestUpdate {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 8) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .heavy))
            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.30))
          Text("HRMAX MAY BE LOW")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.65))
          Spacer()
        }

        Text("Observed \(report.observedP99_5) bpm peak (last \(report.windowDays)d, \(report.sampleCount) samples). Your set HRmax is \(report.configuredHRmax).")
          .font(.system(size: 12, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.75))
          .fixedSize(horizontal: false, vertical: true)

        Text("Consider re-tuning UserProfile.maxHeartRate → \(report.suggestedHRmax). Zone math everywhere will follow.")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(Color(red: 1.0, green: 0.88, blue: 0.40))
      }
      .padding(14)
      .background(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .fill(Color(red: 1.0, green: 0.55, blue: 0.30).opacity(0.08))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 14, style: .continuous)
          .stroke(Color(red: 1.0, green: 0.55, blue: 0.30).opacity(0.35), lineWidth: 1)
      )
    }
  }
}
