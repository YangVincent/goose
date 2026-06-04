import SwiftUI

/// Pace-of-Aging chart — your estimated biological age over time, computed
/// per-day from `WhoopAPIClient.recoveryHistory` (RHR + HRV).
///
/// Unlike the WHOOP Age widget which gives a single 30-day average number,
/// this surfaces the *trajectory*: are you getting biologically younger or
/// older week-over-week? Trend lines for HRV (ms) and RHR (bpm) live in the
/// same view so you can see what's driving the bio-age number.
///
/// Honest scope: bio-age per day uses only the daily-available components
/// (HRV vs age-norm curve, RHR vs typical decline). Sleep performance,
/// sleep consistency, time-in-zone-1-3, strength activity — all weekly
/// averages from `healthspan` — aren't included per-day because the server
/// only returns them as 30-day rollups.
struct WhoopPaceOfAgingChart: View {
  @ObservedObject var client: WhoopAPIClient
  let chronologicalAge: Int

  @State private var rows: [DayPoint] = []

  struct DayPoint: Identifiable {
    let id: String  // iso date
    let date: Date
    let hrv: Double?    // RMSSD in ms
    let rhr: Double?    // bpm
    /// Bio-age estimate using only HRV + RHR signals for this day.
    let bioAge: Double?
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header

      if rows.compactMap(\.bioAge).count < 3 {
        emptyState
      } else {
        bioAgeChart
        summary

        Divider()
          .background(Color.white.opacity(0.1))

        hrvChart
        rhrChart
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .onAppear { refresh() }
    .onChange(of: client.recoveryHistory.count) { _, _ in refresh() }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("PACE OF AGING")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text("BIOLOGICAL AGE TREND")
          .font(.system(size: 16, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
      }
      Spacer()
      if let recent = rows.compactMap(\.bioAge).suffix(7).first,
         let last = rows.compactMap(\.bioAge).last {
        let weekDelta = last - recent
        Text(weekDelta >= 0
             ? String(format: "+%.1f / wk", weekDelta)
             : String(format: "%.1f / wk", weekDelta))
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(weekDelta >= 0
                           ? Color(red: 1.0, green: 0.55, blue: 0.30)
                           : Color(red: 0.18, green: 0.88, blue: 0.66))
      }
    }
  }

  private var emptyState: some View {
    HStack(spacing: 10) {
      Image(systemName: "chart.line.uptrend.xyaxis")
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(.white.opacity(0.3))
      Text("Need at least 3 days of HRV/RHR history.")
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
      Spacer()
    }
  }

  private var bioAgeChart: some View {
    let values = rows.compactMap(\.bioAge)
    let chronological = Double(chronologicalAge)
    return VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("BIO-AGE")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.5))
        Spacer()
        if let last = values.last {
          Text(String(format: "%.1f yrs", last))
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
        Text("vs \(chronologicalAge) chrono")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.4))
      }
      ZStack {
        chronologicalReferenceLine(value: chronological, values: values)
        Sparkline(values: values, tint: bioAgeTint(values))
      }
      .frame(height: 70)
    }
  }

  /// Horizontal reference line at chronological age, so the user can see
  /// whether their bio-age is trending above or below their actual age.
  private func chronologicalReferenceLine(value: Double, values: [Double]) -> some View {
    GeometryReader { geo in
      let mn = values.min() ?? value - 1
      let mx = values.max() ?? value + 1
      let lo = min(mn, value)
      let hi = max(mx, value)
      let span = max(hi - lo, 1)
      let y = geo.size.height - CGFloat((value - lo) / span) * geo.size.height
      Path { path in
        path.move(to: CGPoint(x: 0, y: y))
        path.addLine(to: CGPoint(x: geo.size.width, y: y))
      }
      .stroke(
        Color.white.opacity(0.25),
        style: StrokeStyle(lineWidth: 1, dash: [3, 3])
      )
    }
  }

  private var summary: some View {
    let confirmedCount = rows.compactMap(\.bioAge).count
    let firstDate = rows.first(where: { $0.bioAge != nil })?.date
    let span: String = {
      guard let first = firstDate else { return "no data" }
      let days = Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 0
      return "\(days) days, \(confirmedCount) daily points"
    }()
    return Text(span)
      .font(.system(size: 9, weight: .heavy, design: .rounded))
      .tracking(1)
      .foregroundStyle(.white.opacity(0.4))
  }

  private var hrvChart: some View {
    let values = rows.compactMap(\.hrv)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("HRV (RMSSD)")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.5))
        Spacer()
        if let last = values.last {
          Text(String(format: "%.0f ms", last))
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
        }
      }
      Sparkline(values: values, tint: Color(red: 0.55, green: 0.85, blue: 1.0))
        .frame(height: 36)
    }
  }

  private var rhrChart: some View {
    let values = rows.compactMap(\.rhr)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text("RHR")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.5))
        Spacer()
        if let last = values.last {
          Text(String(format: "%.0f bpm", last))
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.30))
        }
      }
      Sparkline(values: values, tint: Color(red: 1.0, green: 0.55, blue: 0.30))
        .frame(height: 36)
    }
  }

  // MARK: - Data assembly

  private func refresh() {
    let history = client.recoveryHistory
    let parser = ISO8601DateFormatter()
    parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    rows = history
      .compactMap { recovery -> DayPoint? in
        guard let startISO = recovery.start,
              let date = parser.date(from: startISO) ?? plain.date(from: startISO) else { return nil }
        let bioAge = bioAgeFromHRVRHR(
          hrv: recovery.hrv_rmssd_milli,
          rhr: recovery.resting_heart_rate
        )
        return DayPoint(
          id: Self.isoDate(date),
          date: date,
          hrv: recovery.hrv_rmssd_milli,
          rhr: recovery.resting_heart_rate,
          bioAge: bioAge
        )
      }
      .sorted { $0.date < $1.date }
  }

  /// Per-day bio-age estimate using only HRV + RHR vs typical age-norm
  /// decline curves. Median HRV (RMSSD) drops ~0.8 ms/year; typical RHR
  /// climbs ~0.1 bpm/year. Each signal yields an implied age; we average
  /// them.
  ///
  /// HRV anchor: at age 25, median RMSSD ≈ 60 ms. So implied_age = 25 + (60 - hrv) / 0.8.
  /// RHR anchor: at age 25, typical RHR ≈ 60 bpm. So implied_age = 25 + (rhr - 60) / 0.1.
  ///
  /// Clamp to a plausible 18..90 range.
  private func bioAgeFromHRVRHR(hrv: Double?, rhr: Double?) -> Double? {
    let hrvAge: Double? = hrv.map { 25 + (60 - $0) / 0.8 }
    let rhrAge: Double? = rhr.map { 25 + ($0 - 60) / 0.1 }
    let parts = [hrvAge, rhrAge].compactMap { $0 }
    guard !parts.isEmpty else { return nil }
    let avg = parts.reduce(0, +) / Double(parts.count)
    return min(max(avg, 18), 90)
  }

  private func bioAgeTint(_ values: [Double]) -> Color {
    let chrono = Double(chronologicalAge)
    guard let last = values.last else { return Color.gray }
    if last < chrono - 3 { return Color(red: 0.18, green: 0.88, blue: 0.66) }
    if last <= chrono { return Color(red: 0.55, green: 0.85, blue: 1.0) }
    if last <= chrono + 3 { return Color(red: 1.0, green: 0.88, blue: 0.40) }
    return Color(red: 1.0, green: 0.37, blue: 0.42)
  }

  private static func isoDate(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }
}
