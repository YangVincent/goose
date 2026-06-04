import SwiftUI

/// Per-second HR replay for a completed workout. Pulls samples from
/// `HeartRateSeriesStore` (SQLite-backed) using the workout's start/end
/// window. Zones from `HeartRateZone.zoneID(for:)` are shaded behind the
/// line so the user sees not just BPM but which zone they were in.
struct WorkoutHRTimelineView: View {
  let startedAt: Date
  let endedAt: Date
  let elapsedSeconds: Double
  @State private var samples: [HeartRateSamplePoint] = []
  @State private var hovered: HeartRateSamplePoint?

  init(workout: CompletedWorkout) {
    self.startedAt = workout.startedAt
    self.endedAt = workout.endedAt
    self.elapsedSeconds = workout.elapsedSeconds
  }

  init(startedAt: Date, endedAt: Date, elapsedSeconds: Double) {
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.elapsedSeconds = elapsedSeconds
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      if samples.count < 10 {
        emptyState
      } else {
        ZStack(alignment: .topLeading) {
          zoneBackground
          chart
          if let hovered {
            hoverPill(hovered)
          }
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        xAxisLabels
        legend
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.05))
    )
    .onAppear { load() }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("HR DURING WORKOUT")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      if !samples.isEmpty {
        HStack(spacing: 12) {
          stat(label: "AVG", value: avgString)
          stat(label: "MAX", value: maxString)
          stat(label: "MIN", value: minString)
          stat(label: "PEAK ZONE", value: peakZoneString)
          Spacer()
          Text("\(samples.count) samples")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.4))
            .monospacedDigit()
        }
      }
    }
  }

  private func stat(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.4))
      Text(value)
        .font(.system(size: 14, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
  }

  private var emptyState: some View {
    HStack(spacing: 10) {
      Image(systemName: "waveform.path.ecg")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white.opacity(0.3))
      Text("Not enough HR samples for this workout window.")
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
      Spacer()
    }
    .padding(.vertical, 14)
  }

  /// Color bands at the HRmax-derived zone boundaries so the user can see
  /// which zone the line is sitting in at any moment.
  private var zoneBackground: some View {
    GeometryReader { geo in
      let bounds = bpmBounds
      let mapY: (Double) -> CGFloat = { value in
        let frac = (value - bounds.min) / max(bounds.max - bounds.min, 1)
        return geo.size.height - CGFloat(frac) * geo.size.height
      }
      let maxHR = Double(UserProfile.maxHeartRate)
      let lines = [
        (0.60 * maxHR, Self.zoneColor(1)),
        (0.70 * maxHR, Self.zoneColor(2)),
        (0.80 * maxHR, Self.zoneColor(3)),
        (0.90 * maxHR, Self.zoneColor(4)),
      ]
      ZStack {
        Color.white.opacity(0.02)
        ForEach(0..<lines.count, id: \.self) { idx in
          let value = lines[idx].0
          let color = lines[idx].1
          if value >= bounds.min, value <= bounds.max {
            let y = mapY(value)
            Path { path in
              path.move(to: CGPoint(x: 0, y: y))
              path.addLine(to: CGPoint(x: geo.size.width, y: y))
            }
            .stroke(color.opacity(0.5), style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))
          }
        }
      }
    }
  }

  private var chart: some View {
    GeometryReader { geo in
      let bounds = bpmBounds
      let totalSeconds = max(elapsedSeconds, 1)
      ZStack {
        // Draw each segment in the zone color of its start sample. Color
        // tracks effort intensity rather than a global gradient.
        ForEach(0..<max(samples.count - 1, 0), id: \.self) { idx in
          let s0 = samples[idx]
          let s1 = samples[idx + 1]
          let x0 = CGFloat(s0.capturedAt.timeIntervalSince(startedAt) / totalSeconds) * geo.size.width
          let x1 = CGFloat(s1.capturedAt.timeIntervalSince(startedAt) / totalSeconds) * geo.size.width
          let y0 = geo.size.height - CGFloat((Double(s0.bpm) - bounds.min) / max(bounds.max - bounds.min, 1)) * geo.size.height
          let y1 = geo.size.height - CGFloat((Double(s1.bpm) - bounds.min) / max(bounds.max - bounds.min, 1)) * geo.size.height
          let zone = HeartRateZone.zoneID(for: s0.bpm)
          Path { path in
            path.move(to: CGPoint(x: x0, y: y0))
            path.addLine(to: CGPoint(x: x1, y: y1))
          }
          .stroke(
            Self.zoneColor(zone),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
          )
        }
      }
    }
    .padding(8)
  }

  private func hoverPill(_ sample: HeartRateSamplePoint) -> some View {
    let zone = HeartRateZone.zoneID(for: sample.bpm)
    return HStack(spacing: 6) {
      Circle().fill(Self.zoneColor(zone)).frame(width: 7, height: 7)
      Text("\(sample.bpm) BPM")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
      Text("Z\(zone)")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.7))
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(
      Capsule(style: .continuous).fill(Color.black.opacity(0.55))
    )
    .padding(6)
  }

  private var xAxisLabels: some View {
    HStack {
      Text(timeLabel(startedAt))
      Spacer()
      Text(timeLabel(endedAt))
    }
    .font(.system(size: 9, weight: .heavy, design: .rounded))
    .tracking(1)
    .foregroundStyle(.white.opacity(0.4))
    .monospacedDigit()
  }

  private var legend: some View {
    HStack(spacing: 10) {
      ForEach(1...5, id: \.self) { zone in
        HStack(spacing: 4) {
          RoundedRectangle(cornerRadius: 2)
            .fill(Self.zoneColor(zone))
            .frame(width: 8, height: 8)
          Text("Z\(zone)")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }
      }
      Spacer()
    }
  }

  // MARK: - Data

  private func load() {
    samples = HeartRateSeriesStore.shared.samples(
      from: startedAt,
      to: endedAt
    )
  }

  private var bpmBounds: (min: Double, max: Double) {
    let bpms = samples.map { Double($0.bpm) }
    let mn = bpms.min() ?? 60
    let mx = bpms.max() ?? 180
    if mx - mn < 10 { return (max(mn - 5, 30), mx + 10) }
    return (max(mn - 5, 30), mx + 5)
  }

  private var avgString: String {
    guard !samples.isEmpty else { return "--" }
    let avg = Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)
    return "\(Int(avg.rounded()))"
  }

  private var maxString: String { samples.map(\.bpm).max().map(String.init) ?? "--" }
  private var minString: String { samples.map(\.bpm).min().map(String.init) ?? "--" }

  private var peakZoneString: String {
    guard let maxBpm = samples.map(\.bpm).max() else { return "--" }
    return "Z\(HeartRateZone.zoneID(for: maxBpm))"
  }

  private func timeLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: date)
  }

  private static func zoneColor(_ zone: Int) -> Color {
    switch zone {
    case 1: Color(red: 0.30, green: 0.65, blue: 1.0)
    case 2: Color(red: 0.18, green: 0.88, blue: 0.66)
    case 3: Color(red: 1.0, green: 0.88, blue: 0.40)
    case 4: Color(red: 1.0, green: 0.55, blue: 0.30)
    default: Color(red: 1.0, green: 0.37, blue: 0.42)
    }
  }
}
