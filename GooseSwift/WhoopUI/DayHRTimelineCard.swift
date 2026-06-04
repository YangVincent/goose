import SwiftUI

/// Full-day HR timeline — WHOOP's flagship "your whole day's HR" view.
/// Reads samples from `HeartRateSeriesStore`, plots as a continuous line,
/// shades workout windows in their activity tint, and marks the user's
/// resting HR baseline with a dashed reference line.
struct DayHRTimelineCard: View {
  let date: Date

  @State private var samples: [HeartRateSamplePoint] = []
  @State private var workouts: [CompletedWorkout] = []
  @State private var restingBPM: Double?

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      header

      if samples.count < 20 {
        Text("Not enough HR samples yet today.")
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.5))
          .padding(.vertical, 12)
      } else {
        ZStack {
          restingLine
          workoutOverlays
          line
        }
        .frame(height: 130)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

        xAxis
        statsRow
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .onAppear { reload() }
    .onChange(of: date) { _, _ in reload() }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("HR ALL DAY")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text(Self.dateLabel(date))
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
      }
      Spacer()
      if !workouts.isEmpty {
        Text("\(workouts.count) WORKOUT\(workouts.count == 1 ? "" : "S")")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
      }
    }
  }

  private var restingLine: some View {
    GeometryReader { geo in
      if let rhr = restingBPM {
        let bounds = bpmBounds
        let frac = (rhr - bounds.min) / max(bounds.max - bounds.min, 1)
        let y = geo.size.height - CGFloat(frac) * geo.size.height
        Path { path in
          path.move(to: CGPoint(x: 0, y: y))
          path.addLine(to: CGPoint(x: geo.size.width, y: y))
        }
        .stroke(
          Color.white.opacity(0.25),
          style: StrokeStyle(lineWidth: 1, dash: [3, 3])
        )
        Text(String(format: "RHR %.0f", rhr))
          .font(.system(size: 7, weight: .heavy, design: .rounded))
          .tracking(0.5)
          .foregroundStyle(.white.opacity(0.4))
          .padding(.horizontal, 3)
          .offset(x: 4, y: y - 7)
      }
    }
  }

  private var workoutOverlays: some View {
    GeometryReader { geo in
      let dayStart = Calendar.current.startOfDay(for: date)
      let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
      let totalSec = dayEnd.timeIntervalSince(dayStart)
      ForEach(workouts) { workout in
        let startSec = workout.startedAt.timeIntervalSince(dayStart)
        let endSec = workout.endedAt.timeIntervalSince(dayStart)
        let x1 = CGFloat(max(0, startSec) / totalSec) * geo.size.width
        let x2 = CGFloat(min(totalSec, endSec) / totalSec) * geo.size.width
        Rectangle()
          .fill(Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.10))
          .frame(width: max(x2 - x1, 2))
          .position(x: (x1 + x2) / 2, y: geo.size.height / 2)
      }
    }
  }

  private var line: some View {
    GeometryReader { geo in
      let bounds = bpmBounds
      let dayStart = Calendar.current.startOfDay(for: date)
      let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
      let totalSec = dayEnd.timeIntervalSince(dayStart)
      Path { path in
        var first = true
        for sample in samples {
          let x = CGFloat(sample.capturedAt.timeIntervalSince(dayStart) / totalSec) * geo.size.width
          let frac = (Double(sample.bpm) - bounds.min) / max(bounds.max - bounds.min, 1)
          let y = geo.size.height - CGFloat(frac) * geo.size.height
          if first { path.move(to: CGPoint(x: x, y: y)); first = false }
          else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
      }
      .stroke(
        Color(red: 1.0, green: 0.37, blue: 0.42),
        style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
      )
    }
  }

  private var xAxis: some View {
    HStack {
      Text("00:00")
      Spacer()
      Text("06:00")
      Spacer()
      Text("12:00")
      Spacer()
      Text("18:00")
      Spacer()
      Text("24:00")
    }
    .font(.system(size: 8, weight: .heavy, design: .rounded))
    .tracking(0.5)
    .foregroundStyle(.white.opacity(0.35))
    .monospacedDigit()
  }

  private var statsRow: some View {
    HStack(spacing: 12) {
      stat(label: "AVG", value: avgString)
      stat(label: "MIN", value: minString)
      stat(label: "MAX", value: maxString)
      Spacer()
      Text("\(samples.count) SAMPLES")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.4))
        .monospacedDigit()
    }
  }

  private func stat(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.4))
      Text(value)
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
  }

  private var bpmBounds: (min: Double, max: Double) {
    let bpms = samples.map { Double($0.bpm) }
    let mn = bpms.min() ?? 50
    let mx = bpms.max() ?? 180
    return (max(mn - 5, 30), mx + 5)
  }

  private var avgString: String {
    guard !samples.isEmpty else { return "--" }
    let avg = Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count)
    return "\(Int(avg.rounded()))"
  }
  private var minString: String { samples.map(\.bpm).min().map(String.init) ?? "--" }
  private var maxString: String { samples.map(\.bpm).max().map(String.init) ?? "--" }

  private func reload() {
    samples = HeartRateSeriesStore.shared.samples(forDayContaining: date)
    let isoKey: String = {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.timeZone = TimeZone.current
      return f.string(from: date)
    }()
    workouts = CompletedWorkoutStore.shared.workouts(onISODate: isoKey)
    restingBPM = HeartRateSeriesStore.shared.restingEstimate()?.bpm
  }

  private static func dateLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    if Calendar.current.isDateInToday(date) { return "TODAY" }
    if Calendar.current.isDateInYesterday(date) { return "YESTERDAY" }
    formatter.dateFormat = "EEE MMM d"
    return formatter.string(from: date).uppercased()
  }
}
