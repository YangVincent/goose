import SwiftUI

/// BPM distribution histogram for a workout — complements the zone bars
/// with a finer view of where you actually spent time. Useful for catching
/// "I was at 165 the whole time" vs "I had a bimodal distribution from
/// intervals".
struct WorkoutHRHistogramView: View {
  let startedAt: Date
  let endedAt: Date
  @State private var bins: [HistogramBin] = []

  struct HistogramBin: Identifiable {
    let id: Int  // bin lower bound
    let bucket: Int  // bpm bucket label (e.g. 140 means 140-144)
    let count: Int
    let zone: Int
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("BPM DISTRIBUTION")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))

      if bins.isEmpty {
        Text("Not enough samples for distribution.")
          .font(.system(size: 10, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
      } else {
        chart
        xAxis
      }
    }
    .padding(12)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .onAppear { load() }
  }

  private var chart: some View {
    let maxCount = bins.map(\.count).max() ?? 1
    return HStack(alignment: .bottom, spacing: 1) {
      ForEach(bins) { bin in
        let h = max(2, CGFloat(bin.count) / CGFloat(maxCount) * 80)
        Rectangle()
          .fill(Self.zoneColor(bin.zone).opacity(0.85))
          .frame(height: h)
      }
    }
    .frame(height: 80)
    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }

  private var xAxis: some View {
    HStack {
      if let first = bins.first {
        Text("\(first.bucket)")
      }
      Spacer()
      if let mid = bins.dropFirst(bins.count / 2).first {
        Text("\(mid.bucket)")
      }
      Spacer()
      if let last = bins.last {
        Text("\(last.bucket)")
      }
    }
    .font(.system(size: 9, weight: .heavy, design: .rounded))
    .tracking(1)
    .foregroundStyle(.white.opacity(0.4))
    .monospacedDigit()
  }

  // MARK: - Bucket logic

  private func load() {
    let samples = HeartRateSeriesStore.shared.samples(from: startedAt, to: endedAt)
    guard samples.count >= 30 else { return }
    let bpms = samples.map(\.bpm)
    let mn = (bpms.min() ?? 60) / 5 * 5  // round down to 5
    let mx = ((bpms.max() ?? 180) / 5 + 1) * 5
    var buckets: [Int: Int] = [:]
    for bpm in bpms {
      let bucket = (bpm / 5) * 5
      buckets[bucket, default: 0] += 1
    }
    var ordered: [HistogramBin] = []
    for bucket in stride(from: mn, through: mx, by: 5) {
      let count = buckets[bucket, default: 0]
      let zone = HeartRateZone.zoneID(for: bucket + 2)
      ordered.append(HistogramBin(id: bucket, bucket: bucket, count: count, zone: zone))
    }
    bins = ordered
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
