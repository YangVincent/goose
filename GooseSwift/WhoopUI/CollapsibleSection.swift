import SwiftUI

/// Small wrapper that adds a tappable header bar above any content, with
/// a chevron that flips. Used on Home for low-priority cards (HR all-day,
/// vitals 2x3 grid) so they take zero vertical real estate by default but
/// stay one tap away.
struct CollapsibleSection<Content: View>: View {
  let title: String
  let defaultOpen: Bool
  @ViewBuilder let content: () -> Content

  @State private var isOpen: Bool

  init(title: String, defaultOpen: Bool, @ViewBuilder content: @escaping () -> Content) {
    self.title = title
    self.defaultOpen = defaultOpen
    self._isOpen = State(initialValue: defaultOpen)
    self.content = content
  }

  var body: some View {
    VStack(spacing: 0) {
      Button {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
          isOpen.toggle()
        }
      } label: {
        HStack {
          Text(title)
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2.5)
            .foregroundStyle(.white.opacity(0.55))
          Spacer()
          Image(systemName: isOpen ? "chevron.up" : "chevron.down")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(0.04))
        )
      }
      .buttonStyle(.plain)

      if isOpen {
        content()
          .padding(.top, 8)
          .transition(.opacity.combined(with: .move(edge: .top)))
      }
    }
  }
}
