import SwiftUI
import Charts

/// Trend detail page pushed when the user taps "VIEW TREND →" on a
/// factor card. Reuses the same gradient bar + markers as the card so
/// the context carries, then renders a 30-day line chart if we have a
/// time series. Falls back to a "no per-day history" note for factors
/// (sleep consistency, weekly zones, etc.) that only have aggregates.
struct WhoopAgeFactorTrendView: View {
  let title: String
  let unit: String
  let valueRange: ClosedRange<Double>
  let rangeStartLabel: String
  let rangeEndLabel: String
  let sixMonthValue: Double?
  let thirtyDayValue: Double?
  let yearsContribution: Double
  let higherIsBetter: Bool
  let outperformingText: String?
  let underperformingText: String?
  let trendSeries: [TrendPoint]
  /// Optional override of value formatting on the chart Y-axis.
  var valueFormatter: ((Double) -> String)? = nil

  struct TrendPoint: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
  }

  var body: some View {
    ZStack {
      WhoopHomeView.detailBackground.ignoresSafeArea()
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
          summaryCard
          chartCard
          explanationCard
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle(title)
    .navigationBarTitleDisplayMode(.large)
    .toolbarColorScheme(.dark, for: .navigationBar)
  }

  // MARK: - Summary card (reuses the factor bar)

  private var summaryCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 16) {
        Text(title)
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white)
        HStack(alignment: .center, spacing: 12) {
          rangeBar
          yearsBadge
        }
      }
    }
  }

  private var rangeBar: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
          .fill(gradient)
          .frame(height: 18)
        ForEach(1..<10, id: \.self) { i in
          let x = geo.size.width * CGFloat(i) / 10.0
          Rectangle()
            .fill(Color.black.opacity(0.35))
            .frame(width: 1, height: 18)
            .offset(x: x)
        }
        if let v = thirtyDayValue {
          let raw = geo.size.width * CGFloat(normalised(v))
          let cx = max(4.5, min(geo.size.width - 4.5, raw))
          Triangle()
            .fill(Color.white.opacity(0.55))
            .frame(width: 9, height: 7)
            .offset(x: cx - 4.5, y: 20)
        }
        if let v = sixMonthValue {
          let raw = geo.size.width * CGFloat(normalised(v))
          let cx = max(4.5, min(geo.size.width - 4.5, raw))
          Triangle()
            .fill(Color.white)
            .rotationEffect(.degrees(180))
            .frame(width: 9, height: 7)
            .offset(x: cx - 4.5, y: -10)
        }
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
        .frame(height: 18)
      }
    }
    .frame(height: 28)
  }

  private var yearsBadge: some View {
    let isGood = yearsContribution <= 0
    let sign = yearsContribution > 0 ? "+" : ""
    return VStack(alignment: .leading, spacing: 0) {
      Text("\(sign)\(String(format: "%.1f", yearsContribution))")
        .font(.system(size: 24, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(isGood ? Color(red: 0.18, green: 0.85, blue: 0.55) : Color(red: 0.92, green: 0.55, blue: 0.15))
      Text("years")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.55))
    }
    .frame(width: 70, alignment: .leading)
  }

  // MARK: - Chart

  private var chartCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 10) {
        Text("TREND (LAST \(trendSeries.count) DAYS)")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        if trendSeries.count >= 2 {
          Chart {
            ForEach(trendSeries) { point in
              LineMark(
                x: .value("date", point.date),
                y: .value("value", point.value)
              )
              .interpolationMethod(.catmullRom)
              .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
              PointMark(
                x: .value("date", point.date),
                y: .value("value", point.value)
              )
              .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0))
              .symbolSize(20)
            }
            if let thirty = thirtyDayValue {
              RuleMark(y: .value("30d avg", thirty))
                .foregroundStyle(.white.opacity(0.2))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .annotation(position: .top, alignment: .trailing) {
                  Text("30d avg \(format(thirty)) \(unit)")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
          }
          .frame(height: 180)
          .chartYAxis {
            AxisMarks(position: .leading) { _ in
              AxisGridLine().foregroundStyle(.white.opacity(0.05))
              AxisValueLabel().foregroundStyle(.white.opacity(0.4)).font(.system(size: 9, weight: .heavy, design: .rounded))
            }
          }
          .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: max(1, trendSeries.count / 7))) { _ in
              AxisValueLabel(format: .dateTime.month(.abbreviated).day()).foregroundStyle(.white.opacity(0.4)).font(.system(size: 9, weight: .heavy, design: .rounded))
            }
          }
        } else {
          VStack(alignment: .leading, spacing: 6) {
            Text("No per-day trend yet")
              .font(.system(size: 13, weight: .heavy, design: .rounded))
              .foregroundStyle(.white.opacity(0.75))
            Text("This metric is currently only available as a 30-day aggregate. Once we have a daily time series we'll plot it here.")
              .font(.system(size: 11, weight: .semibold, design: .rounded))
              .foregroundStyle(.white.opacity(0.5))
              .fixedSize(horizontal: false, vertical: true)
          }
        }
      }
    }
  }

  // MARK: - Explanation

  private var explanationCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text(yearsContribution <= 0 ? "Outperforming" : "Underperforming")
          .font(.system(size: 18, weight: .heavy, design: .rounded))
          .foregroundStyle(.white)
        Text(text)
          .font(.system(size: 13, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.7))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var text: String {
    if yearsContribution <= 0 {
      return outperformingText ?? "You're outperforming your age cohort on this metric."
    } else {
      return underperformingText ?? "This metric is underperforming relative to your cohort."
    }
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

  private var gradient: LinearGradient {
    let bad = Color(red: 0.92, green: 0.55, blue: 0.15)
    let mid = Color(red: 0.55, green: 0.50, blue: 0.25)
    let good = Color(red: 0.18, green: 0.85, blue: 0.55)
    let stops: [Color] = higherIsBetter ? [bad, mid, good] : [good, mid, bad]
    return LinearGradient(colors: stops, startPoint: .leading, endPoint: .trailing)
  }

  private func cardSurface<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    content()
      .padding(16)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 18, style: .continuous)
          .fill(Color.white.opacity(0.05))
      )
  }
}
