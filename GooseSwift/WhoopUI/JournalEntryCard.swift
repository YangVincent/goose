import SwiftUI

/// Daily journal — WHOOP-style behavior tracking. Quick taps for things
/// known to affect recovery (alcohol, caffeine timing, stress, late meal,
/// late workout, meditation, cold/heat exposure, jet lag). Each day's
/// selections persist to UserDefaults under a date key.
///
/// Once we have sync, journal entries will graduate to a Rust SQLite
/// `journal_entries` table so the server can run correlation analysis
/// (e.g. "alcohol → HRV drops 12 ms next morning"). For now it's local.
struct JournalEntryCard: View {
  let date: Date
  @State private var selected: Set<JournalBehavior> = []
  @State private var saveTask: DispatchWorkItem?

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      LazyVGrid(
        columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
        spacing: 8
      ) {
        ForEach(JournalBehavior.allCases, id: \.self) { behavior in
          behaviorChip(behavior)
        }
      }

      if !selected.isEmpty {
        summaryLine
      }
    }
    .padding(14)
    .background(
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
    .onAppear { load() }
    .onChange(of: date) { _, _ in load() }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text("JOURNAL")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text("\(selected.count) of \(JournalBehavior.allCases.count) logged")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.4))
      }
      Spacer()
    }
  }

  private func behaviorChip(_ behavior: JournalBehavior) -> some View {
    Button {
      toggle(behavior)
    } label: {
      HStack(spacing: 6) {
        Image(systemName: selected.contains(behavior) ? behavior.activeIcon : behavior.icon)
          .font(.system(size: 12, weight: .heavy))
          .foregroundStyle(selected.contains(behavior)
                           ? behavior.tint
                           : .white.opacity(0.45))
        Text(behavior.title.uppercased())
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(selected.contains(behavior)
                           ? .white
                           : .white.opacity(0.6))
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 8)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(selected.contains(behavior)
                ? behavior.tint.opacity(0.18)
                : Color.white.opacity(0.04))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .stroke(selected.contains(behavior)
                  ? behavior.tint.opacity(0.5)
                  : Color.clear, lineWidth: 1)
      )
    }
    .buttonStyle(.plain)
  }

  private var summaryLine: some View {
    Text("Saved automatically • Used for correlation analysis later.")
      .font(.system(size: 9, weight: .heavy, design: .rounded))
      .tracking(1)
      .foregroundStyle(.white.opacity(0.4))
  }

  // MARK: - Persistence

  private static let storageKey = "com.goose.swift.journal.entries"

  private func toggle(_ behavior: JournalBehavior) {
    if selected.contains(behavior) {
      selected.remove(behavior)
    } else {
      selected.insert(behavior)
    }
    schedulePersist()
  }

  private func load() {
    let key = Self.dateKey(for: date)
    let allEntries = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
    let raw = allEntries[key] ?? []
    selected = Set(raw.compactMap { JournalBehavior(rawValue: $0) })
  }

  private func schedulePersist() {
    saveTask?.cancel()
    let key = Self.dateKey(for: date)
    let payload = selected.map(\.rawValue)
    let work = DispatchWorkItem {
      var allEntries = UserDefaults.standard.dictionary(forKey: Self.storageKey) as? [String: [String]] ?? [:]
      if payload.isEmpty {
        allEntries.removeValue(forKey: key)
      } else {
        allEntries[key] = payload
      }
      UserDefaults.standard.set(allEntries, forKey: Self.storageKey)
    }
    saveTask = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  private static func dateKey(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    return formatter.string(from: date)
  }
}

enum JournalBehavior: String, CaseIterable {
  case alcohol
  case caffeineLate
  case lateMeal
  case lateWorkout
  case meditation
  case coldExposure
  case heatExposure
  case highStress
  case poorSleep
  case jetLag

  var title: String {
    switch self {
    case .alcohol: "Alcohol"
    case .caffeineLate: "Caffeine PM"
    case .lateMeal: "Late Meal"
    case .lateWorkout: "Late Workout"
    case .meditation: "Meditation"
    case .coldExposure: "Cold Plunge"
    case .heatExposure: "Sauna"
    case .highStress: "High Stress"
    case .poorSleep: "Poor Sleep"
    case .jetLag: "Jet Lag"
    }
  }

  var icon: String {
    switch self {
    case .alcohol: "wineglass"
    case .caffeineLate: "cup.and.saucer"
    case .lateMeal: "fork.knife"
    case .lateWorkout: "figure.run"
    case .meditation: "leaf"
    case .coldExposure: "snowflake"
    case .heatExposure: "thermometer.sun"
    case .highStress: "bolt"
    case .poorSleep: "bed.double"
    case .jetLag: "airplane"
    }
  }

  var activeIcon: String {
    switch self {
    case .alcohol: "wineglass.fill"
    case .caffeineLate: "cup.and.saucer.fill"
    case .lateMeal: "fork.knife"
    case .lateWorkout: "figure.run"
    case .meditation: "leaf.fill"
    case .coldExposure: "snowflake"
    case .heatExposure: "thermometer.sun.fill"
    case .highStress: "bolt.fill"
    case .poorSleep: "bed.double.fill"
    case .jetLag: "airplane"
    }
  }

  var tint: Color {
    switch self {
    case .alcohol: Color(red: 0.85, green: 0.45, blue: 0.60)
    case .caffeineLate: Color(red: 0.65, green: 0.45, blue: 0.30)
    case .lateMeal: Color(red: 1.0, green: 0.55, blue: 0.30)
    case .lateWorkout: Color(red: 1.0, green: 0.37, blue: 0.42)
    case .meditation: Color(red: 0.30, green: 0.85, blue: 0.55)
    case .coldExposure: Color(red: 0.40, green: 0.70, blue: 1.0)
    case .heatExposure: Color(red: 1.0, green: 0.65, blue: 0.20)
    case .highStress: Color(red: 1.0, green: 0.37, blue: 0.42)
    case .poorSleep: Color(red: 0.85, green: 0.55, blue: 1.0)
    case .jetLag: Color(red: 0.55, green: 0.85, blue: 1.0)
    }
  }
}
