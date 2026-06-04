import SwiftUI

struct AppleHealthExportView: View {
  @ObservedObject var exporter: GooseHealthKitExporter = .shared
  @ObservedObject var store: CompletedWorkoutStore = .shared

  var body: some View {
    ZStack {
      Self.background.ignoresSafeArea()
      ScrollView {
        VStack(spacing: 16) {
          header

          statsRow

          actionButton

          if let last = exporter.lastExportedAt {
            Text("LAST EXPORT \(Self.timeLabel(last))")
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .tracking(1.5)
              .foregroundStyle(.white.opacity(0.45))
          }

          if let error = exporter.lastError {
            Text(error)
              .font(.system(size: 11, weight: .semibold, design: .rounded))
              .foregroundStyle(Color(red: 1.0, green: 0.55, blue: 0.30))
              .padding(.horizontal, 18)
              .multilineTextAlignment(.leading)
          }

          notesBlock
        }
        .padding(.bottom, 32)
      }
    }
    .navigationTitle("Apple Health")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("EXPORT")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      Text("Push to Apple Health")
        .font(.system(size: 22, weight: .heavy, design: .rounded))
        .foregroundStyle(.white)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 18)
    .padding(.top, 14)
  }

  private var statsRow: some View {
    HStack(spacing: 10) {
      statCell(label: "LOCAL", value: "\(store.workouts.count)")
      statCell(label: "EXPORTED", value: "\(exporter.sessionsExported)")
      statCell(label: "AUTH", value: exporter.isAuthorized ? "ON" : "—")
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
        .font(.system(size: 18, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  private var actionButton: some View {
    Button {
      Task { await exporter.exportAll() }
    } label: {
      HStack(spacing: 8) {
        if exporter.isWorking {
          ProgressView().tint(.black)
        } else {
          Image(systemName: "square.and.arrow.up")
            .font(.system(size: 13, weight: .heavy))
        }
        Text(exporter.isWorking ? "EXPORTING…" : "EXPORT NOW")
          .font(.system(size: 12, weight: .heavy, design: .rounded))
          .tracking(1.5)
      }
      .foregroundStyle(.black)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 12)
      .background(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .fill(Color.white.opacity(0.95))
      )
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 18)
    .disabled(exporter.isWorking)
  }

  private var notesBlock: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("HOW IT WORKS")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.4))
      Text("Every locally-recorded workout becomes an HKWorkout in Apple Health with avg/max HR, calories, distance, and a metadata tag pointing back to its Goose session id. Re-running export is idempotent — already-exported sessions are skipped.")
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.white.opacity(0.55))
        .lineSpacing(2)
      Text("Activity type is mapped per workout (Run → Running, Walk → Walking, etc.). Source name in Health is \"Goose\".")
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

  private static func timeLabel(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d • h:mm a"
    return formatter.string(from: date).uppercased()
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
