import SwiftUI

struct WhoopScoreCard: View {
  let scores: [HealthMetricSnapshot]
  let actionSummary: String
  let coachTip: CoachInlineTip
  let openScore: (HealthRoute) -> Void
  let openCoach: (String) -> Void

  var body: some View {
    VStack(spacing: 18) {
      Button {
        openScore(.recovery)
      } label: {
        recoveryRing
      }
      .buttonStyle(.plain)

      HStack(spacing: 14) {
        Button {
          openScore(.sleep)
        } label: {
          metricStat(snapshot: sleep, label: "SLEEP")
        }
        .buttonStyle(.plain)

        Rectangle()
          .fill(Color.white.opacity(0.08))
          .frame(width: 1, height: 36)

        Button {
          openScore(.strain)
        } label: {
          metricStat(snapshot: strain, label: "STRAIN")
        }
        .buttonStyle(.plain)
      }
      .frame(maxWidth: .infinity)

      CoachTipCard(tip: displayCoachTip) {
        openCoach(coachTip.prompt)
      }
      .padding(.top, 2)
    }
    .padding(.vertical, 22)
    .padding(.horizontal, 18)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 22, style: .continuous)
        .fill(Self.cardBackground)
    )
  }

  private var recoveryRing: some View {
    let value = recoveryPercent
    let color = Self.recoveryColor(forPercent: value)

    return ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: 14)

      Circle()
        .trim(from: 0, to: Double(value) / 100)
        .stroke(
          color,
          style: StrokeStyle(lineWidth: 14, lineCap: .round)
        )
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.6), radius: 8, x: 0, y: 0)

      VStack(spacing: 4) {
        Text("\(value)")
          .font(.system(size: 68, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
          .lineLimit(1)
          .minimumScaleFactor(0.5)
        Text("RECOVERY")
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(color)
      }
      .padding(20)
    }
    .frame(width: 220, height: 220)
    .padding(.top, 4)
  }

  private func metricStat(snapshot: HealthMetricSnapshot, label: String) -> some View {
    VStack(spacing: 4) {
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.6))

      Text(snapshot.displayValue.isEmpty ? "--" : snapshot.displayValue)
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
    .frame(maxWidth: .infinity)
  }

  private var recovery: HealthMetricSnapshot {
    scores.first { $0.route == .recovery } ?? scores.first ?? HealthMetricSnapshot.placeholder
  }

  private var sleep: HealthMetricSnapshot {
    scores.first { $0.route == .sleep } ?? HealthMetricSnapshot.placeholder
  }

  private var strain: HealthMetricSnapshot {
    scores.first { $0.route == .strain } ?? HealthMetricSnapshot.placeholder
  }

  private var recoveryPercent: Int {
    let raw = firstNumber(in: recovery.displayValue) ?? 0
    return min(max(Int(raw.rounded()), 0), 100)
  }

  private var displayCoachTip: CoachInlineTip {
    guard coachTip.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return coachTip
    }
    return CoachInlineTip(
      id: coachTip.id,
      title: coachTip.title,
      message: actionSummary,
      source: coachTip.source,
      prompt: coachTip.prompt,
      systemImage: coachTip.systemImage,
      tint: coachTip.tint
    )
  }

  private static let cardBackground = LinearGradient(
    colors: [
      Color(red: 0.05, green: 0.09, blue: 0.16),
      Color(red: 0.03, green: 0.05, blue: 0.10)
    ],
    startPoint: .top,
    endPoint: .bottom
  )

  private static func recoveryColor(forPercent value: Int) -> Color {
    switch value {
    case 67...:
      return Color(red: 0.18, green: 0.88, blue: 0.66)
    case 34...:
      return Color(red: 1.0, green: 0.88, blue: 0.40)
    default:
      return Color(red: 1.0, green: 0.37, blue: 0.42)
    }
  }
}

private extension HealthMetricSnapshot {
  static var placeholder: HealthMetricSnapshot {
    HealthMetricSnapshot(
      id: "placeholder",
      route: .recovery,
      group: .today,
      title: "",
      value: "--",
      unit: "",
      status: "",
      freshness: "",
      provenance: "",
      source: .unavailable("no data"),
      systemImage: "circle",
      tint: .gray,
      trend: HealthTrendModel(id: "", title: "", rangeLabel: "", summary: "", analysis: "", resources: [], points: [])
    )
  }
}
