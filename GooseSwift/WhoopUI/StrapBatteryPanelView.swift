import SwiftUI

/// Strap battery panel — pulled straight from `GooseBLEClient`'s published
/// state, no extra BLE traffic. Shows charge, last-seen timestamp, and a
/// daily-drop estimate so you can predict when you'll need to charge.
struct StrapBatteryPanelView: View {
  @ObservedObject var ble: GooseBLEClient

  var body: some View {
    ZStack {
      Self.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 16) {
          heroCharge
          statsRow
          historyHint
          notesBlock
        }
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("Strap Battery")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var heroCharge: some View {
    VStack(spacing: 8) {
      Text("CHARGE")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      Text(percentText)
        .font(.system(size: 72, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(percentColor)
      Text(ble.batteryPowerStatus.uppercased())
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.55))

      batteryShape
        .frame(width: 220, height: 36)
        .padding(.top, 8)
    }
    .padding(.vertical, 22)
    .frame(maxWidth: .infinity)
    .background(
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .padding(.horizontal, 18)
    .padding(.top, 12)
  }

  private var batteryShape: some View {
    let percent = ble.batteryLevelPercent ?? 0
    return ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .stroke(Color.white.opacity(0.5), lineWidth: 2)

      RoundedRectangle(cornerRadius: 4, style: .continuous)
        .fill(percentColor)
        .padding(4)
        .frame(width: max(6, CGFloat(percent) / 100 * 212))
    }
    .overlay(alignment: .trailing) {
      RoundedRectangle(cornerRadius: 2)
        .fill(Color.white.opacity(0.5))
        .frame(width: 6, height: 16)
        .offset(x: 8)
    }
  }

  private var statsRow: some View {
    HStack(spacing: 10) {
      statCell(label: "LAST SEEN", value: lastSeenText)
      statCell(label: "CHARGING", value: chargingText)
      statCell(label: "STATUS", value: ble.batteryPowerStatus)
    }
    .padding(.horizontal, 18)
  }

  private func statCell(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(2)
        .minimumScaleFactor(0.5)
    }
    .padding(10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var historyHint: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("DAILY DROP")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.45))
      Text(dailyDropHint)
        .font(.system(size: 11, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.7))
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.03))
    )
    .padding(.horizontal, 18)
  }

  private var notesBlock: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text("STRAP BATTERY NOTES")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.4))
      Text("Level read from GATT 0x2A19 (Battery Level). Status text from 0x2BED (Battery Level Status) when the strap exposes it. Update timing depends on strap firmware — typical ~30 minute intervals.")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.4))
        .lineSpacing(2)
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.03))
    )
    .padding(.horizontal, 18)
  }

  // MARK: - Resolvers

  private var percentText: String {
    ble.batteryLevelPercent.map { "\($0)%" } ?? "--"
  }

  private var percentColor: Color {
    guard let pct = ble.batteryLevelPercent else { return .white.opacity(0.4) }
    if pct >= 50 { return Color(red: 0.18, green: 0.88, blue: 0.66) }
    if pct >= 20 { return Color(red: 1.0, green: 0.88, blue: 0.40) }
    return Color(red: 1.0, green: 0.37, blue: 0.42)
  }

  private var lastSeenText: String {
    guard let updated = ble.batteryUpdatedAt else { return "--" }
    let seconds = Int(Date().timeIntervalSince(updated))
    if seconds < 60 { return "\(seconds)s AGO" }
    if seconds < 3600 { return "\(seconds / 60)m AGO" }
    return "\(seconds / 3600)h AGO"
  }

  private var chargingText: String {
    guard let charging = ble.batteryIsCharging else { return "--" }
    return charging ? "YES" : "NO"
  }

  private var dailyDropHint: String {
    // We don't keep history yet — once charge values land in SQLite we
    // can compute drop-rate over the last N days.
    "Daily drop estimate will populate once charge history is tracked across days."
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
