import SwiftUI

/// Compact daily step / active-minutes card. Reads from StepEstimator, which
/// derives its numbers from motion_intensity in the K10/K21 packet stream.
struct WhoopStepCard: View {
  @ObservedObject var estimator: StepEstimator

  var body: some View {
    VStack(spacing: 8) {
      HStack(spacing: 14) {
        Image(systemName: "shoeprints.fill")
          .font(.system(size: 22, weight: .bold))
          .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
          .frame(width: 44, height: 44)
          .background(Circle().fill(Color.white.opacity(0.06)))

        VStack(alignment: .leading, spacing: 2) {
          Text("STEPS · EST")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.55))
          Text("\(Int(estimator.todayTotals.estimatedSteps.rounded()))")
            .font(.system(size: 22, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
        }

        Spacer()

        VStack(alignment: .trailing, spacing: 2) {
          Text("ACTIVE")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.45))
          Text(activeText)
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.85))
        }
      }

      // Diagnostic strip so you can tell if K10/K21 packets are actually
      // streaming — separate from whether they crossed the step threshold.
      HStack(spacing: 10) {
        Text(diagnosticText)
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.4))
        Spacer()
        if estimator.recentPeakIntensity > 0 {
          Text(String(format: "PEAK %.2f", estimator.recentPeakIntensity))
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.4))
            .monospacedDigit()
        }
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var diagnosticText: String {
    guard let last = estimator.lastPacketAt else {
      return "NO PACKETS YET · CONNECT STRAP"
    }
    let secs = Int(Date().timeIntervalSince(last))
    let ago: String
    if secs < 60 { ago = "\(secs)s AGO" }
    else if secs < 3600 { ago = "\(secs / 60)m AGO" }
    else { ago = "\(secs / 3600)h AGO" }
    return "\(estimator.packetsSeen) PACKETS · LAST \(ago)"
  }

  private var activeText: String {
    let totalMinutes = Int((estimator.todayTotals.activeSeconds / 60).rounded())
    if totalMinutes < 60 { return "\(totalMinutes)m" }
    let h = totalMinutes / 60
    let m = totalMinutes % 60
    return "\(h)h \(m)m"
  }
}
