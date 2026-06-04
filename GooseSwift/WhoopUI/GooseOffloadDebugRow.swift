import SwiftUI

/// Debug row in More → Debug for the device-to-server offload. Lets you
/// toggle it on/off, edit the base URL + token, see the last run report,
/// and force a sync immediately.
struct GooseOffloadDebugRow: View {
  @ObservedObject private var client = GooseOffloadClient.shared

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(isOn: $client.isEnabled) {
        Text("Enable offload")
          .font(.system(size: 13, weight: .heavy))
      }
      TextField("Base URL", text: $client.baseURL)
        .font(.system(size: 11, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      TextField("Bearer token", text: $client.bearerToken)
        .font(.system(size: 11, design: .monospaced))
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
      HStack(spacing: 8) {
        statusIndicator
        Spacer()
        Button {
          Task { await client.runSync() }
        } label: {
          Label("Sync now", systemImage: "icloud.and.arrow.up")
        }
        .disabled(client.state == .running)
      }
      if let report = client.lastReport {
        Text("Last: \(report.hrSamplesSent) HR + \(report.dailySummariesSent) summaries · \(report.totalMs)ms · \(Self.relative(report.at))")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
  }

  private var statusIndicator: some View {
    HStack(spacing: 6) {
      switch client.state {
      case .idle:
        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
        Text("Idle").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      case .running:
        ProgressView().scaleEffect(0.7)
        Text("Syncing").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
      case .failed(let err):
        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        Text(err).font(.system(size: 10, weight: .semibold)).foregroundStyle(.red).lineLimit(2)
      }
    }
  }

  private static func relative(_ date: Date) -> String {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
  }
}
