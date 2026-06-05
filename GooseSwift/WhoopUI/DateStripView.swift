import SwiftUI

/// Reusable horizontal date strip. Tap a chip to set
/// `SelectedDayStore.shared.currentDate`. Lazy-renders chips so the
/// 365-day strip stays snappy.
struct DateStripView: View {
  @ObservedObject private var selectedDay = SelectedDayStore.shared
  @ObservedObject private var dailyStore = WhoopImportedDailyStore.shared

  let days: [Date]

  init(daysBack: Int = 365) {
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    self.days = (0..<daysBack).reversed().compactMap {
      calendar.date(byAdding: .day, value: -$0, to: today)
    }
  }

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 10) {
          ForEach(days, id: \.self) { day in
            chip(for: day)
              .id(day)
              .onTapGesture { selectedDay.select(day) }
          }
        }
        .padding(.horizontal, 22)
      }
      // Default to the trailing edge (today) so the strip never lands on
      // a year-old date on first appear. The explicit scrollTo below
      // then nudges to whatever selectedDay says (almost always today)
      // once layout's stable.
      .defaultScrollAnchor(.trailing)
      .task {
        // Wait one runloop tick for LazyHStack to lay out before scrolling,
        // otherwise the proxy.scrollTo silently no-ops on cold launch.
        try? await Task.sleep(nanoseconds: 150_000_000)
        proxy.scrollTo(selectedDay.currentDate, anchor: .center)
      }
    }
  }

  private func chip(for day: Date) -> some View {
    let isoString = selectedDay.isoDate(day)
    let recoveryScore = dailyStore.recoveryScore(forISODate: isoString)
    let hasWorkout = !CompletedWorkoutStore.shared.workouts(onISODate: isoString).isEmpty
    let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedDay.currentDate)
    let isToday = Calendar.current.isDateInToday(day)
    let weekday: String = {
      let f = DateFormatter(); f.dateFormat = "EEE"
      return f.string(from: day).uppercased()
    }()
    let dayNum: String = {
      let f = DateFormatter(); f.dateFormat = "d"
      return f.string(from: day)
    }()
    return VStack(spacing: 4) {
      Text(weekday)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(isSelected ? 0.85 : 0.45))
      Text(dayNum)
        .font(.system(size: 16, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
      Circle()
        .fill(Self.recoveryColor(forPercent: recoveryScore.map { Int($0.rounded()) } ?? -1))
        .frame(width: 6, height: 6)
        .opacity(recoveryScore == nil ? 0.18 : 1)
    }
    .frame(width: 38, height: 64)
    .background(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .fill(isSelected ? Color.white.opacity(0.10) : Color.white.opacity(0.025))
    )
    .overlay(alignment: .topTrailing) {
      if hasWorkout {
        Circle()
          .fill(Color.white.opacity(0.9))
          .frame(width: 5, height: 5)
          .padding(5)
      }
    }
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .stroke(isToday ? Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.6) : Color.clear, lineWidth: 1)
    )
  }

  private static func recoveryColor(forPercent percent: Int) -> Color {
    if percent < 0 { return Color.white.opacity(0.15) }
    if percent >= 67 { return Color(red: 0.18, green: 0.88, blue: 0.66) }
    if percent >= 34 { return Color(red: 1.0, green: 0.88, blue: 0.40) }
    return Color(red: 1.0, green: 0.37, blue: 0.42)
  }
}
