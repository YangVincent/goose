import SwiftUI

/// Top-level Data Recovery surface: lists the recovery operations the app
/// supports and lets the user trigger them on demand. Lives under More →
/// Device so the path is one tap deep instead of three (was buried under
/// Developer → Debug).
struct DataRecoveryView: View {
  var body: some View {
    List {
      Section {
        HRRecoveryButton()
      } header: {
        Text("Heart Rate")
      } footer: {
        Text("Walks Goose's decoded_frames table for HR bytes (K10/K18/K12/K24) and back-fills the hr_samples table. Use this if the strain calculator says 0 but you've been wearing the strap, or to recover historical data after a destructive event.")
      }

      Section {
        VStack(alignment: .leading, spacing: 6) {
          Text("Live capture is automatic.")
            .font(.system(size: 13, weight: .heavy, design: .rounded))
          Text("Going forward, every BLE frame Goose decodes that contains an HR byte writes to hr_samples in the same Rust transaction as decoded_frames. The two tables can't drift. Recovery is only needed for historical data captured before that side-effect existed.")
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
      } header: {
        Text("How Recovery Works")
      }
    }
    .listStyle(.insetGrouped)
    .gooseListBackground()
    .navigationTitle("Data Recovery")
    .navigationBarTitleDisplayMode(.inline)
  }
}
