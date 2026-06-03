import SwiftUI

/// Lets the user set, view, or clear strap alarms via the existing
/// GooseBLEClient.writeAlarmCommand path (V5 commands 66 SET_ALARM_TIME,
/// 67 GET_ALARM_TIME, 68 RUN_ALARM, 69 DISABLE_ALARM).
///
/// The strap fires haptics at the configured time using a built-in waveform.
/// We use `AlarmHapticsPattern.whoopDefault` so the buzz matches what WHOOP's
/// own app schedules.
struct SmartAlarmView: View {
  @EnvironmentObject private var model: GooseAppModel
  @State private var wakeTime: Date = SmartAlarmView.defaultWakeTime
  @State private var alarmSlot: Int = 1

  var body: some View {
    ZStack {
      Self.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 20) {
          header
          timePickerCard
          slotPickerCard
          actionRow
          statusCard
          fireNowCard
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("Smart Alarm")
    .navigationBarTitleDisplayMode(.large)
    .toolbarColorScheme(.dark, for: .navigationBar)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("STRAP ALARM")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      Text("Vibrates the strap on your wrist at a target time")
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(.white.opacity(0.45))
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.top, 8)
  }

  private var timePickerCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("WAKE TIME")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      DatePicker(
        "Wake at",
        selection: $wakeTime,
        displayedComponents: [.date, .hourAndMinute]
      )
      .labelsHidden()
      .datePickerStyle(.compact)
      .colorScheme(.dark)
    }
    .padding(16)
    .background(cardBackground)
  }

  private var slotPickerCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("SLOT")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      Text("The strap can hold multiple scheduled alarms keyed by slot ID 0–255. Use the same slot ID to replace an existing alarm; different IDs to layer.")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.4))
        .lineSpacing(2)
      Stepper(value: $alarmSlot, in: 0...255) {
        Text("Slot \(alarmSlot)")
          .font(.system(size: 16, weight: .bold, design: .rounded))
          .foregroundStyle(.white)
      }
      .colorScheme(.dark)
    }
    .padding(16)
    .background(cardBackground)
  }

  private var actionRow: some View {
    HStack(spacing: 12) {
      Button {
        setAlarm()
      } label: {
        Text("SET ALARM")
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Self.accentColor)
          )
      }
      .disabled(!model.ble.canWriteAlarm)
      .opacity(model.ble.canWriteAlarm ? 1.0 : 0.4)

      Button {
        readAlarm()
      } label: {
        Text("READ")
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Color.white.opacity(0.08))
          )
      }
      .disabled(!model.ble.canWriteAlarm)
      .opacity(model.ble.canWriteAlarm ? 1.0 : 0.4)

      Button {
        disableAll()
      } label: {
        Text("CLEAR")
          .font(.system(size: 13, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 48)
          .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
              .fill(Color.white.opacity(0.08))
          )
      }
      .disabled(!model.ble.canWriteAlarm)
      .opacity(model.ble.canWriteAlarm ? 1.0 : 0.4)
    }
  }

  private var statusCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("STATUS")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))

      statusRow(label: "Latest command", value: model.ble.alarmCommandStatus)
      statusRow(label: "Last response", value: model.ble.lastAlarmResponseSummary)
      statusRow(label: "Last event", value: model.ble.lastAlarmEventSummary)
      if !model.ble.canWriteAlarm {
        Text(model.ble.alarmWriteSupportSummary)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(Color(red: 1.0, green: 0.88, blue: 0.40))
          .padding(.top, 4)
      }
    }
    .padding(16)
    .background(cardBackground)
  }

  private var fireNowCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("TEST")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      Text("Trigger the haptics immediately without waiting for the scheduled time. Useful to confirm the strap is reachable and to test the wave pattern.")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.4))
        .lineSpacing(2)
      Button {
        runNow()
      } label: {
        Text("FIRE HAPTICS NOW")
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white)
          .frame(maxWidth: .infinity, minHeight: 44)
          .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
              .fill(Color.white.opacity(0.08))
          )
      }
      .disabled(!model.ble.canWriteAlarm)
      .opacity(model.ble.canWriteAlarm ? 1.0 : 0.4)
    }
    .padding(16)
    .background(cardBackground)
  }

  private func statusRow(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label.uppercased())
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.4))
      Text(value)
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.85))
    }
  }

  // MARK: - Actions

  private func setAlarm() {
    guard let slotID = UInt8(exactly: alarmSlot) else { return }
    model.ble.writeAlarmCommand(
      .set(
        alarmID: slotID,
        date: wakeTime,
        pattern: GooseBLEClient.AlarmHapticsPattern.whoopDefault
      )
    )
  }

  private func readAlarm() {
    guard let slotID = UInt8(exactly: alarmSlot) else { return }
    model.ble.writeAlarmCommand(.get(alarmID: slotID))
  }

  private func disableAll() {
    model.ble.writeAlarmCommand(.disableAll)
  }

  private func runNow() {
    guard let slotID = UInt8(exactly: alarmSlot) else { return }
    model.ble.writeAlarmCommand(.run(alarmID: slotID))
  }

  // MARK: - Style

  private var cardBackground: some View {
    RoundedRectangle(cornerRadius: 14, style: .continuous)
      .fill(Color.white.opacity(0.04))
  }

  private static let accentColor = Color(red: 0.55, green: 0.35, blue: 1.0)

  private static let background = LinearGradient(
    colors: [
      Color(red: 0.02, green: 0.04, blue: 0.09),
      Color(red: 0.00, green: 0.00, blue: 0.03)
    ],
    startPoint: .top,
    endPoint: .bottom
  )

  private static var defaultWakeTime: Date {
    // Default to 7am tomorrow.
    var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
    components.day = (components.day ?? 1) + 1
    components.hour = 7
    components.minute = 0
    return Calendar.current.date(from: components) ?? Date().addingTimeInterval(24 * 60 * 60)
  }
}
