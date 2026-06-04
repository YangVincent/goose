import SwiftUI

/// One-shot button surfaced in More → Debug → Recovery. Walks Goose's
/// `decoded_frames` table for HR bytes and back-fills `hr_samples`. The
/// architectural fix (Rust mirrors HR into hr_samples inside
/// `insert_decoded_frame`) means this should rarely matter going forward —
/// it exists for historical data captured before that side-effect landed,
/// or for any other recovery scenario.
struct HRRecoveryButton: View {
  @State private var lastReport: HeartRateSeriesStore.HRRecoveryReport?
  @State private var isRunning = false
  @State private var daysBack: Double = 30

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text("Window")
        Spacer()
        Text("\(Int(daysBack)) days")
          .foregroundStyle(.secondary)
      }
      Slider(value: $daysBack, in: 1...90, step: 1)

      Button {
        run()
      } label: {
        if isRunning {
          ProgressView().tint(.primary)
        } else {
          Label("Recover HR from Decoded Frames", systemImage: "arrow.counterclockwise.heart")
        }
      }
      .disabled(isRunning)

      if let report = lastReport {
        VStack(alignment: .leading, spacing: 2) {
          Text("Last run:")
            .font(.system(size: 12, weight: .heavy, design: .rounded))
            .foregroundStyle(.secondary)
          Text("• \(report.framesScanned) frames scanned")
          Text("• \(report.hrSamplesExtracted) HR readings found")
          Text("• \(report.hrSamplesInserted) inserted into hr_samples")
            .foregroundStyle(report.hrSamplesInserted > 0
                             ? Color(red: 0.18, green: 0.65, blue: 0.45)
                             : .secondary)
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
      }
    }
    .padding(.vertical, 4)
  }

  private func run() {
    isRunning = true
    let days = Int(daysBack)
    DispatchQueue.global(qos: .userInitiated).async {
      let report = HeartRateSeriesStore.recoverHRFromDecodedFrames(daysBack: days)
      DispatchQueue.main.async {
        self.lastReport = report
        self.isRunning = false
        // Tell downstream calculators to re-read so the home view picks up
        // any newly-inserted samples immediately.
        DayStrainStore.shared.refresh()
      }
    }
  }
}
