import SwiftUI

struct HomeWhoopSleepCard: View {
  let sleep: PrimarySleepDetail?
  let openDetail: () -> Void

  var body: some View {
    Button {
      openDetail()
    } label: {
      VStack(alignment: .leading, spacing: 16) {
        header

        if let sleep, !sleep.stages.isEmpty {
          stageBar(stages: sleep.stages)
          stageLegend(stages: sleep.stages)
        } else {
          emptyState
        }
      }
      .padding(.vertical, 18)
      .padding(.horizontal, 18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Self.cardBackground)
      )
    }
    .buttonStyle(.plain)
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline, spacing: 8) {
      Text("SLEEP")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.6))

      Spacer()

      if let sleep {
        Text(sleep.durationText)
          .font(.system(size: 20, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)

        Text("•")
          .foregroundStyle(.white.opacity(0.3))

        Text(sleep.scoreDisplayText)
          .font(.system(size: 16, weight: .bold, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(Self.accentColor)
      }
    }
  }

  private func stageBar(stages: [HealthSleepStageSegment]) -> some View {
    GeometryReader { proxy in
      HStack(spacing: 2) {
        ForEach(stages) { stage in
          RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(Self.stageColor(stage.stage))
            .frame(width: width(for: stage, stages: stages, total: proxy.size.width))
        }
      }
    }
    .frame(height: 24)
  }

  private func stageLegend(stages: [HealthSleepStageSegment]) -> some View {
    let grouped = Self.groupedByStage(stages)
    return LazyVGrid(
      columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
      alignment: .leading,
      spacing: 10
    ) {
      ForEach(grouped, id: \.0) { stage, minutes in
        HStack(spacing: 8) {
          Circle()
            .fill(Self.stageColor(stage))
            .frame(width: 8, height: 8)
          Text(stage.uppercased())
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(1.5)
            .foregroundStyle(.white.opacity(0.7))
          Spacer(minLength: 4)
          Text(HealthDataStore.minutesText(minutes))
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
      }
    }
  }

  private var emptyState: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("No sleep data yet")
        .font(.system(size: 14, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.85))
      Text("Wear the strap overnight and sync from More → Device → Advanced.")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(2)
    }
    .padding(.vertical, 6)
  }

  private func width(for stage: HealthSleepStageSegment, stages: [HealthSleepStageSegment], total: CGFloat) -> CGFloat {
    let totalMinutes = max(stages.map(\.durationMinutes).reduce(0, +), 1)
    return max(8, total * CGFloat(stage.durationMinutes / totalMinutes))
  }

  private static func groupedByStage(_ stages: [HealthSleepStageSegment]) -> [(String, Double)] {
    let order = ["deep", "rem", "core", "light", "awake"]
    var totals: [String: Double] = [:]
    for stage in stages {
      let key = stage.stage.lowercased()
      totals[key, default: 0] += stage.durationMinutes
    }
    return order.compactMap { key in
      guard let minutes = totals[key], minutes > 0 else { return nil }
      return (key, minutes)
    }
  }

  private static func stageColor(_ stage: String) -> Color {
    switch stage.lowercased() {
    case "awake":
      return Color(red: 1.0, green: 0.55, blue: 0.30)
    case "rem":
      return Color(red: 0.55, green: 0.35, blue: 1.0)
    case "deep":
      return Color(red: 0.18, green: 0.40, blue: 0.95)
    case "core", "light":
      return Color(red: 0.30, green: 0.65, blue: 1.0)
    default:
      return Color(red: 0.50, green: 0.50, blue: 0.65)
    }
  }

  private static let accentColor = Color(red: 0.30, green: 0.65, blue: 1.0)

  private static let cardBackground = LinearGradient(
    colors: [
      Color(red: 0.05, green: 0.09, blue: 0.16),
      Color(red: 0.03, green: 0.05, blue: 0.10)
    ],
    startPoint: .top,
    endPoint: .bottom
  )
}
