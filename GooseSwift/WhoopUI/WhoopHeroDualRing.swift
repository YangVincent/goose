import SwiftUI

/// Twin-ring hero: Recovery on the left, Strain on the right.
/// Strain ring includes the target band (calculated from current recovery)
/// rendered as a translucent arc so the user sees "where they should land"
/// at a glance — no separate Strain Target card needed.
struct WhoopHeroDualRing: View {
  let recoveryValue: Int?              // 0-100, nil when unknown
  let recoverySource: String?          // "LOCAL" when locally-computed
  let recoveryColor: Color
  let strainValue: Double              // 0-21
  let strainSource: String?            // "LOCAL"
  let strainColor: Color
  let strainTargetMin: Double          // 0-21
  let strainTargetMax: Double          // 0-21
  let strainTargetLabel: String        // "PUSH" / "MODERATE" / "RECOVERY"

  private static let ringSize: CGFloat = 130
  private static let lineWidth: CGFloat = 10

  var body: some View {
    HStack(spacing: 20) {
      recoveryRing
      strainRing
    }
  }

  private var recoveryRing: some View {
    ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: Self.lineWidth)
      Circle()
        .trim(from: 0, to: recoveryValue.map { Double($0) / 100.0 } ?? 0)
        .stroke(recoveryColor, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .shadow(color: recoveryColor.opacity(0.55), radius: 6)
      VStack(spacing: 2) {
        Text(recoveryValue.map { "\($0)" } ?? "--")
          .font(.system(size: 38, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("RECOVERY")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(recoveryColor)
        if let source = recoverySource {
          Text(source)
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
        }
      }
    }
    .frame(width: Self.ringSize, height: Self.ringSize)
  }

  /// Strain ring: full strain arc (0..21) with the recovery-derived
  /// target band overlaid in a brighter translucent tone, so the user
  /// can see whether their current strain is in the recommended range.
  private var strainRing: some View {
    let strainFraction = min(strainValue / 21.0, 1)
    let targetStart = strainTargetMin / 21.0
    let targetEnd = strainTargetMax / 21.0
    return ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: Self.lineWidth)
      // Target band — fainter arc behind the strain arc
      Circle()
        .trim(from: targetStart, to: targetEnd)
        .stroke(strainColor.opacity(0.30), style: StrokeStyle(lineWidth: Self.lineWidth + 2, lineCap: .butt))
        .rotationEffect(.degrees(-90))
      // Current strain arc
      Circle()
        .trim(from: 0, to: strainFraction)
        .stroke(strainColor, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .shadow(color: strainColor.opacity(0.55), radius: 6)
      VStack(spacing: 2) {
        Text(String(format: "%.1f", strainValue))
          .font(.system(size: 32, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("STRAIN")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(strainColor)
        Text("\(Int(strainTargetMin))–\(Int(strainTargetMax)) " + strainTargetLabel)
          .font(.system(size: 7, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.55))
        if let source = strainSource {
          Text(source)
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
        }
      }
      .padding(.horizontal, 12)
    }
    .frame(width: Self.ringSize, height: Self.ringSize)
  }
}
