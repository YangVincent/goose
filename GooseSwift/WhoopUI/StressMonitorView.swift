import SwiftUI

/// Stress / HRV monitor — refreshes off the persisted RR intervals every 30s.
struct StressMonitorView: View {
  @State private var snapshot: HRVAnalyzer.Snapshot?
  @State private var windowHours: Double = 6

  private let refreshTimer = Timer.publish(every: 30.0, on: .main, in: .common).autoconnect()

  var body: some View {
    ZStack {
      Self.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 16) {
          gauge

          stats

          trendChart

          windowSelector
        }
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("Stress · HRV")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { refresh() }
    .onReceive(refreshTimer) { _ in refresh() }
  }

  private func refresh() {
    let end = Date()
    let start = end.addingTimeInterval(-windowHours * 3600)
    let samples = SensorSampleStore.shared.snapshot(from: start, to: end)
    snapshot = HRVAnalyzer.compute(samples: samples)
  }

  // MARK: - Sections

  private var gauge: some View {
    let z = snapshot?.stressZ
    let level = stressLevel(z)
    return VStack(spacing: 6) {
      Text("CURRENT")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.5))

      Text(level.label.uppercased())
        .font(.system(size: 32, weight: .heavy, design: .rounded))
        .foregroundStyle(level.color)

      if let z {
        Text(String(format: "z=%+.2f vs baseline", z))
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.5))
      } else {
        Text("NEED MORE DATA")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.4))
      }
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 20)
    .padding(.horizontal, 16)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(level.color.opacity(0.10))
    )
    .padding(.horizontal, 16)
    .padding(.top, 12)
  }

  private var stats: some View {
    HStack(spacing: 10) {
      stat(label: "RMSSD", value: snapshot?.recentRMSSD.map { String(format: "%.0f ms", $0) } ?? "--")
      stat(label: "BASELINE", value: snapshot?.baselineRMSSD.map { String(format: "%.0f ms", $0) } ?? "--")
      stat(label: "BEATS", value: snapshot.map { "\($0.totalRRCount)" } ?? "--")
    }
    .padding(.horizontal, 16)
  }

  private func stat(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 14, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var trendChart: some View {
    let windows = snapshot?.windows ?? []
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("RMSSD TREND")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.6))
        Spacer()
        Text("\(windows.count) WIN")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.4))
      }

      if windows.count >= 2 {
        Sparkline(
          values: windows.map(\.rmssd),
          tint: Color(red: 0.55, green: 0.85, blue: 1.0)
        )
        .frame(height: 80)
      } else {
        Text("not enough windows yet")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
          .padding(.vertical, 24)
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .padding(.horizontal, 16)
  }

  private var windowSelector: some View {
    HStack(spacing: 8) {
      ForEach([1.0, 6.0, 12.0, 24.0], id: \.self) { hours in
        Button {
          windowHours = hours
          refresh()
        } label: {
          Text("\(Int(hours))h")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              Capsule().fill(
                Color.white.opacity(windowHours == hours ? 0.18 : 0.05)
              )
            )
            .foregroundStyle(.white.opacity(windowHours == hours ? 0.95 : 0.55))
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
    .padding(.horizontal, 16)
  }

  // MARK: - Stress classification

  private struct StressLevel {
    let label: String
    let color: Color
  }

  private func stressLevel(_ z: Double?) -> StressLevel {
    guard let z else {
      return StressLevel(label: "Unknown", color: Color.white.opacity(0.5))
    }
    if z >= 0.75  { return StressLevel(label: "Relaxed", color: Color(red: 0.18, green: 0.88, blue: 0.66)) }
    if z >= -0.25 { return StressLevel(label: "Balanced", color: Color(red: 0.55, green: 0.85, blue: 1.0)) }
    if z >= -0.75 { return StressLevel(label: "Activated", color: Color(red: 1.0, green: 0.88, blue: 0.40)) }
    return StressLevel(label: "Stressed", color: Color(red: 1.0, green: 0.37, blue: 0.42))
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
