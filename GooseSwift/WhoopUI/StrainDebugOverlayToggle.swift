import SwiftUI

/// Small toggle in More → Debug → Overlays for flipping the strain-debug
/// overlay on the Home tab. Defaults off — strain card stays clean for
/// normal use, flip on when diagnosing weird strain numbers.
struct StrainDebugOverlayToggle: View {
  @AppStorage("goose.swift.debug.showStrainOverlay") private var showStrainOverlay = false

  var body: some View {
    Toggle(isOn: $showStrainOverlay) {
      Label("Show strain debug overlay", systemImage: "rectangle.dashed")
    }
  }
}
