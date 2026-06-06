import SwiftUI

/// WHOOP-style contributing factor card. Shows a metric's 6-month and
/// 30-day averages as twin triangle markers on a colored gradient range
/// bar, the years it adds/removes from biological age on the right, and
/// an outperforming/underperforming explanation below.
struct WhoopAgeFactorCard: View {
  let title: String
  let unit: String
  /// Value to show above the bar (6-month avg). Optional — `nil` hides.
  let sixMonthValue: Double?
  /// Value to show below the bar (30-day avg).
  let thirtyDayValue: Double?
  /// Range the bar represents. Markers are positioned as (value - lo)/(hi - lo).
  let valueRange: ClosedRange<Double>
  /// Labels rendered at the ends of the range bar (e.g. "40%"/"100%").
  let rangeStartLabel: String
  let rangeEndLabel: String
  /// Years off biological age (negative = good, makes you younger).
  let yearsContribution: Double
  /// If true, higher value on the bar → "green" (good). If false, lower
  /// is better (e.g. RHR), gradient direction reverses.
  let higherIsBetter: Bool
  /// Optional plain-English explanation surfaced when expanded.
  let outperformingText: String?
  let underperformingText: String?
  /// Optional value formatter; default formats with 0-1 decimal places.
  var valueFormatter: ((Double) -> String)? = nil
  /// Per-day trend series, plotted on the trend detail page. Empty
  /// triggers the "no per-day trend" placeholder there.
  var trendSeries: [WhoopAgeFactorTrendView.TrendPoint] = []

  @State private var expanded: Bool = true

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      header
      bar
      if expanded, let text = explanationText {
        Divider().overlay(Color.white.opacity(0.08))
        VStack(alignment: .leading, spacing: 8) {
          Text(yearsContribution <= 0 ? "Outperforming" : "Underperforming")
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
          Text(text)
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.65))
            .fixedSize(horizontal: false, vertical: true)
          NavigationLink {
            WhoopAgeFactorTrendView(
              title: title,
              unit: unit,
              valueRange: valueRange,
              rangeStartLabel: rangeStartLabel,
              rangeEndLabel: rangeEndLabel,
              sixMonthValue: sixMonthValue,
              thirtyDayValue: thirtyDayValue,
              yearsContribution: yearsContribution,
              higherIsBetter: higherIsBetter,
              outperformingText: outperformingText,
              underperformingText: underperformingText,
              trendSeries: trendSeries,
              valueFormatter: valueFormatter
            )
          } label: {
            Text("VIEW TREND →")
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .tracking(1.2)
              .foregroundStyle(Color(red: 0.30, green: 0.60, blue: 1.0))
          }
          .buttonStyle(.plain)
        }
      }
    }
    .padding(16)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.05))
    )
  }

  // MARK: - Header

  private var header: some View {
    HStack {
      Text(title)
        .font(.system(size: 12, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white)
      Spacer()
      Button { expanded.toggle() } label: {
        Image(systemName: expanded ? "chevron.up" : "chevron.down")
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(.white.opacity(0.55))
      }
      .buttonStyle(.plain)
    }
  }

  // MARK: - Bar
  //
  // Single shared GeometryReader so the label text, the triangle markers,
  // and the bar itself all use one width. Previously the labels used a
  // hardcoded 280pt assumption while the markers used the bar's actual
  // pixel width — so on devices where the bar resolved to ~330pt the
  // labels drifted off the markers by ~15-25pt.

  private var bar: some View {
    HStack(spacing: 12) {
      GeometryReader { geo in
        VStack(spacing: 4) {
          labelOverlay(
            value: sixMonthValue,
            captionAbove: "6 Month avg.",
            captionBelow: nil,
            valueColor: .white,
            valueSize: 14,
            captionColor: .white.opacity(0.55),
            barWidth: geo.size.width
          )
          .frame(height: 26)
          gradientBar(width: geo.size.width)
          labelOverlay(
            value: thirtyDayValue,
            captionAbove: nil,
            captionBelow: "30 Day avg.",
            valueColor: .white.opacity(0.85),
            valueSize: 13,
            captionColor: .white.opacity(0.4),
            barWidth: geo.size.width
          )
          .frame(height: 26)
        }
      }
      .frame(height: 86)
      yearsBadge
    }
  }

  /// Label centered on the marker's x position. We size the label to its
  /// natural width and clamp the center so the label can't overflow off
  /// either edge of the bar.
  private func labelOverlay(
    value: Double?,
    captionAbove: String?,
    captionBelow: String?,
    valueColor: Color,
    valueSize: CGFloat,
    captionColor: Color,
    barWidth: CGFloat
  ) -> some View {
    ZStack(alignment: .leading) {
      Color.clear
      if let v = value {
        let target = barWidth * CGFloat(normalised(v))
        // Approximate half-width of the label so we can keep it onscreen.
        let approxHalfWidth: CGFloat = 36
        let cx = min(max(target, approxHalfWidth), barWidth - approxHalfWidth)
        VStack(spacing: 0) {
          if let captionAbove {
            Text(captionAbove)
              .font(.system(size: 9, weight: .heavy, design: .rounded))
              .foregroundStyle(captionColor)
          }
          Text("\(format(v)) \(unit)")
            .font(.system(size: valueSize, weight: .heavy, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(valueColor)
          if let captionBelow {
            Text(captionBelow)
              .font(.system(size: 9, weight: .heavy, design: .rounded))
              .foregroundStyle(captionColor)
          }
        }
        .fixedSize()
        .position(x: cx, y: 13)
      }
    }
  }

  private func gradientBar(width: CGFloat) -> some View {
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(gradient)
        .frame(height: 18)

      // Subtle dividers across 10 segments
      ForEach(1..<10, id: \.self) { i in
        let x = width * CGFloat(i) / 10.0
        Rectangle()
          .fill(Color.black.opacity(0.35))
          .frame(width: 1, height: 18)
          .offset(x: x)
      }

      // 30-day marker (gray triangle pointing up, sitting just below bar)
      if let v = thirtyDayValue {
        let raw = width * CGFloat(normalised(v))
        let cx = max(4.5, min(width - 4.5, raw))
        Triangle()
          .fill(Color.white.opacity(0.55))
          .frame(width: 9, height: 7)
          .offset(x: cx - 4.5, y: 20)
      }
      // 6-month marker (white triangle pointing down, sitting above bar)
      if let v = sixMonthValue {
        let raw = width * CGFloat(normalised(v))
        let cx = max(4.5, min(width - 4.5, raw))
        Triangle()
          .fill(Color.white)
          .rotationEffect(.degrees(180))
          .frame(width: 9, height: 7)
          .offset(x: cx - 4.5, y: -10)
      }

      // Range labels at the ends, overlaid on the bar
      HStack {
        Text(rangeStartLabel)
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .foregroundStyle(.black.opacity(0.7))
          .padding(.leading, 6)
        Spacer()
        Text(rangeEndLabel)
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .foregroundStyle(.black.opacity(0.7))
          .padding(.trailing, 6)
      }
      .frame(width: width, height: 18, alignment: .leading)
    }
    .frame(height: 28)
  }

  private var gradient: LinearGradient {
    let bad = Color(red: 0.92, green: 0.55, blue: 0.15)  // orange
    let mid = Color(red: 0.55, green: 0.50, blue: 0.25)  // muddy transition
    let good = Color(red: 0.18, green: 0.85, blue: 0.55) // green
    let stops: [Color] = higherIsBetter ? [bad, mid, good] : [good, mid, bad]
    return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
  }

  // MARK: - Years badge

  private var yearsBadge: some View {
    let isGood = yearsContribution <= 0
    let sign = yearsContribution > 0 ? "+" : ""
    return VStack(alignment: .leading, spacing: 0) {
      Text("\(sign)\(String(format: "%.1f", yearsContribution))")
        .font(.system(size: 22, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(isGood ? Color(red: 0.18, green: 0.85, blue: 0.55) : Color(red: 0.92, green: 0.55, blue: 0.15))
      Text("years")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
    }
    .frame(width: 64, alignment: .leading)
  }

  // MARK: - Explanation

  private var explanationText: String? {
    yearsContribution <= 0 ? outperformingText : underperformingText
  }

  // MARK: - Helpers

  private func normalised(_ value: Double) -> Double {
    let lo = valueRange.lowerBound
    let hi = valueRange.upperBound
    guard hi > lo else { return 0 }
    return min(1, max(0, (value - lo) / (hi - lo)))
  }

  private func format(_ value: Double) -> String {
    if let f = valueFormatter { return f(value) }
    if value >= 100 { return String(format: "%.0f", value) }
    if value >= 10 { return String(format: "%.0f", value) }
    return String(format: "%.1f", value)
  }
}

/// Section header — "Sleep" / "Strain" / "Fitness" with the
/// 6-month / 30-day twin marker explainer aligned on the right.
struct WhoopAgeSectionHeader: View {
  let title: String
  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.system(size: 26, weight: .heavy, design: .rounded))
        .foregroundStyle(.white)
      Spacer()
      HStack(spacing: 14) {
        HStack(spacing: 4) {
          Triangle()
            .fill(Color.white)
            .rotationEffect(.degrees(180))
            .frame(width: 7, height: 6)
          Text("6 Month avg.")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.65))
        }
        Rectangle()
          .fill(Color.white.opacity(0.2))
          .frame(width: 1, height: 12)
        HStack(spacing: 4) {
          Triangle()
            .fill(Color.white.opacity(0.55))
            .frame(width: 7, height: 6)
          Text("30 Day avg.")
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .foregroundStyle(.white.opacity(0.55))
        }
      }
    }
    .padding(.top, 12)
    .padding(.bottom, 6)
  }
}

