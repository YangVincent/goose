import Foundation

@MainActor
final class AppRouter: ObservableObject {
  @Published var selectedTab: GooseAppTab
  @Published var healthPath: [HealthRoute] = []
  @Published var morePath: [MoreRoute] = []
  @Published var codexAuthCallbackURL: URL?
  @Published var codexEmbeddedLoginRequestID = 0
  @Published var coachPromptDraft = ""
  @Published var coachPromptRequestID = 0
  @Published var coachScrollToBottomRequestID = 0

  init() {
    // Allow `xcrun simctl launch booted com.vincenty.goose --goose-launch-tab age`
    // to land directly on a specific tab during dev iteration. Recognized
    // values: home / workouts / age / strap. Unrecognized falls back to home.
    let args = ProcessInfo.processInfo.arguments
    if let i = args.firstIndex(of: "--goose-launch-tab"),
       i + 1 < args.count {
      switch args[i + 1].lowercased() {
      case "workouts", "health": self.selectedTab = .health
      case "age", "coach": self.selectedTab = .coach
      case "strap", "more": self.selectedTab = .more
      default: self.selectedTab = .home
      }
    } else {
      self.selectedTab = .home
    }
  }

  func openHealth(_ route: HealthRoute?) {
    selectedTab = .health
    if let route {
      healthPath = [route]
    } else {
      healthPath = []
    }
  }

  func openCoach(prompt: String? = nil) {
    selectedTab = .coach
    guard let prompt else {
      return
    }
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      return
    }
    coachPromptDraft = trimmedPrompt
    coachPromptRequestID += 1
  }

  func openMore(_ route: MoreRoute?) {
    selectedTab = .more
    if let route {
      morePath = [route]
    } else {
      morePath = []
    }
  }

  func reselect(_ tab: GooseAppTab) {
    switch tab {
    case .coach:
      coachScrollToBottomRequestID += 1
    default:
      break
    }
  }

  @discardableResult
  func handleDeepLink(_ url: URL) -> Bool {
    if isCodexAuthCallback(url) {
      selectedTab = .coach
      codexAuthCallbackURL = url
      return true
    }

    if url.scheme == "gooseswift", url.host == "coach" {
      selectedTab = .coach
      if url.pathComponents.dropFirst().first == "embedded-login" {
        codexEmbeddedLoginRequestID += 1
      }
      return true
    }

    if url.scheme == "gooseswift", url.host == "more" {
      let routeName = url.pathComponents.dropFirst().first ?? ""
      if routeName.isEmpty {
        openMore(nil)
        return true
      }
      guard let route = MoreRoute(rawValue: routeName) else {
        return false
      }
      openMore(route)
      return true
    }

    guard url.scheme == "gooseswift", url.host == "health" else {
      return false
    }
    let routeName = url.pathComponents.dropFirst().first ?? ""
    if routeName.isEmpty {
      openHealth(nil)
      return true
    }
    guard let route = HealthRoute(rawValue: routeName) else {
      return false
    }
    openHealth(route)
    return true
  }

  private func isCodexAuthCallback(_ url: URL) -> Bool {
    guard let scheme = url.scheme?.lowercased() else {
      return false
    }
    return ["gooseswift", "goose"].contains(scheme) && url.host == "codex-auth"
  }
}
