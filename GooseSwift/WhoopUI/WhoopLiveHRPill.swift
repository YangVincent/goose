import SwiftUI

/// Small pill that surfaces live BLE state from the strap directly on the
/// WHOOP-style Home view. Anchored to the top-right corner of the OVERVIEW
/// header so the user can glance at a connection / heart rate signal without
/// dipping into the Goose Strap tab.
struct WhoopLiveHRPill: View {
  @ObservedObject var ble: GooseBLEClient

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(statusColor)
        .frame(width: 7, height: 7)
        .shadow(color: statusColor.opacity(0.7), radius: 4)

      if let bpm = freshBPM {
        Text("\(bpm)")
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("BPM")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1.1)
          .foregroundStyle(.white.opacity(0.55))
      } else {
        Text(statusLabel)
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.6))
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 5)
    .background(
      Capsule(style: .continuous)
        .fill(Color.white.opacity(0.06))
    )
    .overlay(
      Capsule(style: .continuous)
        .stroke(statusColor.opacity(isConnected ? 0.55 : 0.18), lineWidth: 1)
    )
  }

  private var freshBPM: Int? {
    guard let bpm = ble.liveHeartRateBPM, bpm > 0 else { return nil }
    guard let updated = ble.liveHeartRateUpdatedAt else { return nil }
    if Date().timeIntervalSince(updated) > 15 { return nil }
    return bpm
  }

  private var isConnected: Bool {
    ble.connectionState.lowercased() == "connected"
  }

  private var statusLabel: String {
    switch ble.connectionState.lowercased() {
    case "connected": return "WAITING"
    case "connecting", "scanning": return ble.connectionState.uppercased()
    case "disconnected": return "OFFLINE"
    default: return ble.connectionState.uppercased()
    }
  }

  private var statusColor: Color {
    if freshBPM != nil {
      return Color(red: 1.0, green: 0.37, blue: 0.42)
    }
    switch ble.connectionState.lowercased() {
    case "connected": return Color(red: 0.18, green: 0.88, blue: 0.66)
    case "connecting", "scanning": return Color(red: 1.0, green: 0.88, blue: 0.40)
    default: return Color.white.opacity(0.35)
    }
  }
}
