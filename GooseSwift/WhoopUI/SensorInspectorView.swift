import SwiftUI

/// Live look at the per-packet sensor channels we now persist from K12/K18/K24
/// historical frames. Useful both as a sanity check ("am I getting fresh
/// samples from the strap?") and as a way to surface ambient light + skin
/// contact bit for sleep-environment context.
///
/// Pull is on a timer rather than via an `@Published` so we don't thrash
/// SwiftUI when 1 Hz packets arrive on the BLE thread.
struct SensorInspectorView: View {
  @State private var samples: [SensorSample] = []
  @State private var lastRefresh: Date = .distantPast
  @State private var windowMinutes: Double = 10
  @State private var totalInStore: Int = 0
  @State private var mostRecentInStore: Date?
  @State private var r17PacketCount: Int = 0
  @State private var r17SampleCount: Int = 0
  @State private var imuPacketCount: Int = 0
  @State private var imuSampleCount: Int = 0

  private let refreshTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

  var body: some View {
    ZStack {
      Self.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 16) {
          header

          windowSelector
            .padding(.horizontal, 16)

          summaryGrid

          rawPacketsRow

          channelCard(
            title: "HEART RATE",
            unit: "BPM",
            values: bpmSeries,
            tint: Color(red: 1.0, green: 0.37, blue: 0.42)
          )

          channelCard(
            title: "SpO₂",
            unit: "%",
            values: spo2Series,
            tint: Color(red: 0.18, green: 0.66, blue: 0.95)
          )

          channelCard(
            title: "AMBIENT LIGHT",
            unit: "ADC",
            values: ambientSeries,
            tint: Color(red: 1.0, green: 0.88, blue: 0.40)
          )

          channelCard(
            title: "SKIN TEMP (RAW)",
            unit: "ADC",
            values: skinTempSeries,
            tint: Color(red: 1.0, green: 0.55, blue: 0.30)
          )

          contactCard

          channelCard(
            title: "PPG GREEN",
            unit: "ADC",
            values: ppgGreenSeries,
            tint: Color(red: 0.30, green: 0.85, blue: 0.55)
          )

          channelCard(
            title: "LED DRIVE 1",
            unit: "ADC",
            values: ledDriveSeries,
            tint: Color(red: 0.85, green: 0.55, blue: 1.0)
          )
        }
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("Sensor Inspector")
    .navigationBarTitleDisplayMode(.inline)
    .onAppear { refresh() }
    .onReceive(refreshTimer) { _ in refresh() }
  }

  // MARK: - Refresh / windowing

  private func refresh() {
    let end = Date()
    let start = end.addingTimeInterval(-windowMinutes * 60)
    samples = SensorSampleStore.shared.snapshot(from: start, to: end)
    totalInStore = SensorSampleStore.shared.totalSampleCount
    mostRecentInStore = SensorSampleStore.shared.mostRecentCapturedAt
    r17PacketCount = R17PacketStore.shared.totalPacketCount
    r17SampleCount = R17PacketStore.shared.totalSampleCount
    imuPacketCount = IMUPacketStore.shared.totalPacketCount
    imuSampleCount = IMUPacketStore.shared.totalSampleCount
    lastRefresh = end
  }

  private var bpmSeries: [Double] {
    samples.compactMap { $0.bpm.map(Double.init) }
  }
  private var spo2Series: [Double] {
    samples.compactMap { $0.spo2Pct.map(Double.init) }
  }
  private var ambientSeries: [Double] {
    samples.compactMap { $0.ambientLight.map(Double.init) }
  }
  private var skinTempSeries: [Double] {
    samples.compactMap { $0.skinTempRaw.map(Double.init) }
  }
  private var ppgGreenSeries: [Double] {
    samples.compactMap { $0.ppgGreen.map(Double.init) }
  }
  private var ledDriveSeries: [Double] {
    samples.compactMap { $0.ledDrive1.map(Double.init) }
  }

  // MARK: - Header / window selector

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("LAST \(Int(windowMinutes)) MIN")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.5))
      Text("\(samples.count) samples")
        .font(.system(size: 20, weight: .heavy, design: .rounded))
        .foregroundStyle(.white)
      Text(storeStatusLine)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.45))
      if let updatedAgo {
        Text("REFRESHED \(updatedAgo)")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.4))
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.top, 12)
  }

  private var storeStatusLine: String {
    if totalInStore == 0 {
      return "STORE EMPTY · CONNECT STRAP & WAIT FOR PACKETS"
    }
    var line = "STORE: \(totalInStore) TOTAL"
    let hrCount = samples.compactMap { $0.bpm }.count
    let sensorCount = samples.compactMap { $0.ambientLight ?? $0.skinTempRaw ?? $0.ppgGreen }.count
    line += " · \(hrCount) HR · \(sensorCount) PPG"
    if let last = mostRecentInStore {
      let secs = Int(Date().timeIntervalSince(last))
      let lastStr: String
      if secs < 60 { lastStr = "\(secs)s AGO" }
      else if secs < 3600 { lastStr = "\(secs / 60)m AGO" }
      else { lastStr = "\(secs / 3600)h AGO" }
      line += " · LAST \(lastStr)"
    }
    return line
  }

  private var updatedAgo: String? {
    guard lastRefresh != .distantPast else { return nil }
    let seconds = Int(Date().timeIntervalSince(lastRefresh))
    if seconds < 2 { return "JUST NOW" }
    return "\(seconds)s AGO"
  }

  private var windowSelector: some View {
    HStack(spacing: 8) {
      ForEach([2.0, 10.0, 30.0, 120.0], id: \.self) { minutes in
        Button {
          windowMinutes = minutes
          refresh()
        } label: {
          Text("\(Int(minutes))m")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(1)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
              Capsule().fill(
                Color.white.opacity(windowMinutes == minutes ? 0.18 : 0.05)
              )
            )
            .foregroundStyle(.white.opacity(windowMinutes == minutes ? 0.95 : 0.55))
        }
        .buttonStyle(.plain)
      }
      Spacer()
    }
  }

  // MARK: - Summary

  private var summaryGrid: some View {
    let last = samples.last
    return HStack(spacing: 10) {
      summaryCell(label: "BPM", value: last?.bpm.map { "\($0)" } ?? "--")
      summaryCell(label: "SpO₂", value: last?.spo2Pct.map { "\($0)" } ?? "--")
      summaryCell(label: "CONTACT", value: contactLabel(last?.skinContact))
      summaryCell(label: "QUAL", value: last?.signalQuality.map { "\($0)" } ?? "--")
    }
    .padding(.horizontal, 16)
  }

  private func summaryCell(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 16, weight: .heavy, design: .rounded))
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

  private var rawPacketsRow: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("RAW PACKET STORES")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      HStack(spacing: 10) {
        rawPacketCell(
          label: "R17 OPTICAL",
          detail: "\(r17PacketCount) PKT · \(formatCount(r17SampleCount)) PPG SAMPLES",
          tint: Color(red: 0.30, green: 0.85, blue: 0.55)
        )
        rawPacketCell(
          label: "K10/K21 IMU",
          detail: "\(imuPacketCount) PKT · \(formatCount(imuSampleCount)) AXIS SAMPLES",
          tint: Color(red: 0.55, green: 0.85, blue: 1.0)
        )
      }
    }
    .padding(.horizontal, 16)
  }

  private func rawPacketCell(label: String, detail: String, tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.2)
        .foregroundStyle(tint)
      Text(detail)
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.8))
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private func formatCount(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
  }

  private func contactLabel(_ bit: Int?) -> String {
    guard let bit else { return "--" }
    return bit == 0 ? "OFF" : "ON"
  }

  // MARK: - Channel cards

  private func channelCard(title: String, unit: String, values: [Double], tint: Color) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(title)
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.6))
        Spacer()
        if let last = values.last {
          Text(String(format: "%.0f %@", last, unit))
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(tint)
        } else {
          Text("--")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
        }
      }

      Sparkline(values: values, tint: tint)
        .frame(height: 56)

      if !values.isEmpty {
        HStack {
          statTag(label: "MIN", value: values.min())
          statTag(label: "AVG", value: average(values))
          statTag(label: "MAX", value: values.max())
          Spacer()
          Text("n=\(values.count)")
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.4))
        }
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .padding(.horizontal, 16)
  }

  private var contactCard: some View {
    let contacts = samples.compactMap { $0.skinContact }
    let onCount = contacts.filter { $0 != 0 }.count
    let total = contacts.count
    let onPct: Double = total > 0 ? Double(onCount) / Double(total) * 100 : 0
    let lastBit = samples.last?.skinContact

    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text("SKIN CONTACT BIT")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.6))
        Spacer()
        Circle()
          .fill(lastBit == 0
            ? Color(red: 1.0, green: 0.37, blue: 0.42)
            : Color(red: 0.18, green: 0.88, blue: 0.66))
          .frame(width: 10, height: 10)
        Text(contactLabel(lastBit))
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
      }

      Text("ON-WRIST \(String(format: "%.0f%%", onPct)) OF \(total) SAMPLES")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))

      // Visualize the bit timeline as a stripe.
      GeometryReader { geo in
        let count = max(contacts.count, 1)
        let w = geo.size.width / CGFloat(count)
        HStack(spacing: 0) {
          ForEach(0..<contacts.count, id: \.self) { idx in
            Rectangle()
              .fill(contacts[idx] == 0
                ? Color(red: 1.0, green: 0.37, blue: 0.42).opacity(0.85)
                : Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.85))
              .frame(width: w)
          }
        }
        .frame(maxWidth: .infinity)
      }
      .frame(height: 18)
      .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .padding(.horizontal, 16)
  }

  private func statTag(label: String, value: Double?) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text(label)
        .font(.system(size: 8, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.4))
      Text(value.map { String(format: "%.0f", $0) } ?? "--")
        .font(.system(size: 10, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.75))
    }
    .frame(minWidth: 36, alignment: .leading)
  }

  private func average(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    return values.reduce(0, +) / Double(values.count)
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

/// Tiny path-based sparkline. Tuned for short channel snapshots — auto-scales
/// to its values so 3 readings or 600 all render meaningfully.
struct Sparkline: View {
  let values: [Double]
  let tint: Color

  var body: some View {
    GeometryReader { geo in
      ZStack {
        if values.count >= 2 {
          Path { path in
            let (mn, mx) = bounds()
            let span = max(mx - mn, 1)
            let w = geo.size.width
            let h = geo.size.height
            for (idx, v) in values.enumerated() {
              let x = CGFloat(idx) / CGFloat(values.count - 1) * w
              let y = h - CGFloat((v - mn) / span) * h
              if idx == 0 { path.move(to: CGPoint(x: x, y: y)) }
              else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
          }
          .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
          .shadow(color: tint.opacity(0.5), radius: 4)
        } else {
          Text("not enough samples")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.3))
        }
      }
    }
  }

  private func bounds() -> (Double, Double) {
    let mn = values.min() ?? 0
    let mx = values.max() ?? 1
    if mn == mx { return (mn - 1, mx + 1) }
    return (mn, mx)
  }
}
