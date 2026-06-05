import SwiftUI

struct WhoopHomeView: View {
  @ObservedObject private var selectedDay = SelectedDayStore.shared
  @ObservedObject private var dayStrain = DayStrainStore.shared
  @ObservedObject private var importedDailyStore = WhoopImportedDailyStore.shared
  @EnvironmentObject private var model: GooseAppModel
  /// Set in More → Developer → Debug → "Show strain debug overlay".
  /// Default off; flip on when the strain card's number looks wrong and
  /// we need to see what the calculator is doing.
  @AppStorage("goose.swift.debug.showStrainOverlay") private var showStrainDebugOverlay = false
  /// Past-day strain values pulled from the `daily_strain_readings` SQLite
  /// table. Today's strain stays on `dayStrain.today` (live, accumulating);
  /// any non-today date reads from here. Populated by `refreshHomeData()`
  /// on appear and on `selectedDay` change.
  @State private var pastStrainByDate: [String: Double] = [:]
  /// Recovery scores keyed by the morning's date_key (the wake day), read
  /// out of the `recovery_readings` table. Today's recovery is "the
  /// reading from last night's sleep" — same table.
  @State private var recoveryByDate: [String: Double] = [:]
  /// Sleep composite scores (0-100) keyed by the wake date_key. Pulled
  /// from the recovery payload's "sleep" component — the SleepReading
  /// .sleep_score that goose_recovery_v0 was fed. Surfaces on the sleep
  /// ring when the day has no WHOOP-imported sleepPerformancePct.
  @State private var sleepByDate: [String: Double] = [:]

  var body: some View {
    NavigationStack {
      content
        .navigationDestination(for: WhoopMetric.self) { metric in
          WhoopMetricDetailView(metric: metric)
        }
    }
  }

  private var content: some View {
    ZStack {
      Self.backgroundGradient.ignoresSafeArea()

      ScrollView(.vertical, showsIndicators: true) {
        VStack(spacing: 20) {
          header

          dateStrip
            .padding(.top, 4)

          // Hero: recovery + strain rings side by side, with target band
          // overlay on the strain ring. Tap routes to detail views.
          heroDualRings
            .padding(.top, 4)
            .padding(.horizontal, 18)

          // Today's activities — sleep summary on top, completed workouts
          // below. Tap a workout → WorkoutDetailView.
          WhoopTodayActivitiesCard()
            .padding(.horizontal, 18)

          // Sleep coach is high-value — moved up to be visible without
          // scrolling past long-term trend cards. Tap → SleepCoachDetailView.
          NavigationLink {
            SleepCoachDetailView()
          } label: {
            WhoopBedtimeRecommendationCard()
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 18)

          // Recovery factor breakdown — what's driving the recovery score.
          // Tap → RecoveryFactorsDetailView ("why").
          NavigationLink {
            RecoveryFactorsDetailView()
          } label: {
            WhoopRecoveryBreakdownCard()
          }
          .buttonStyle(.plain)
          .padding(.horizontal, 18)

          WhoopSleepEnvironmentCard()
            .padding(.horizontal, 18)

          // Collapsible HR-all-day timeline + 2x3 stat grid.
          CollapsibleSection(title: "HR ALL DAY", defaultOpen: false) {
            DayHRTimelineCard(date: selectedDay.currentDate)
          }
          .padding(.horizontal, 18)

          CollapsibleSection(title: "VITALS", defaultOpen: false) {
            statGrid
          }
          .padding(.horizontal, 18)

          WhoopDayComparisonCard()
            .padding(.horizontal, 18)

          WhoopHRMaxAdvisoryCard()
            .padding(.horizontal, 18)

          WhoopStepCard(estimator: StepEstimator.shared)
            .padding(.horizontal, 18)

          JournalEntryCard(date: selectedDay.currentDate)
            .padding(.horizontal, 18)
        }
        .padding(.bottom, 32)
        .frame(maxWidth: .infinity)
      }
      .scrollBounceBehavior(.basedOnSize, axes: [.horizontal])
      .scrollIndicators(.hidden, axes: .horizontal)
      .clipped()
      .refreshable {
      }
    }
    .task {
      // One-time backfill of WHOOP per-day summaries into local SQLite.
      // After this, all reads come from WhoopImportedDailyStore — no
      // runtime cloud reads.
      await importedDailyStore.bootstrapIfNeeded(
        databasePath: HealthDataStore.defaultDatabasePath()
      )
      refreshHomeData()
    }
    .onChange(of: selectedDay.currentDate) { _, _ in
      loadReadingsForSelectedDay()
    }
  }

  /// On every home appear: backfill last night's session (if missing),
  /// recompute today's live strain, finalize any unfinalized past days
  /// into SQLite, trigger a sleep+recovery compute for last night, then
  /// load whatever the selected date strip is on. Caches are cleared
  /// up front so a stale value from a previous (pre-compute) load can't
  /// linger past a refresh.
  private func refreshHomeData() {
    // Don't clear the dicts up-front — the async bridge fetches below
    // overwrite each key when they complete, and showing the stale value
    // for 1-2 seconds (the round-trip) avoids the recovery ring flashing
    // empty on every home tap. Strain and sleep don't have this problem
    // because they read from in-memory observable stores; recovery is
    // the only one keyed by a per-refresh @State dict, so clearing it
    // here was the entire visible flicker.
    // Legacy backfill removed — see SleepDetailView for the same fix.
    DayStrainStore.shared.refresh()
    DayStrainStore.finalizePastDaysIfNeeded()
    ensureSleepAndRecoveryForLastNight()
    loadReadingsForSelectedDay()
  }

  /// Fire `sleep.compute_reading` against the most recent PastSession in
  /// the current sleep-day window (22:00 yesterday → 22:00 today). The
  /// bridge call chains the recovery compute and persists both into
  /// recovery_readings + sleep_readings. WhoopHomeView's loaders read
  /// from those tables on the next pass.
  private func ensureSleepAndRecoveryForLastNight() {
    let cal = Calendar.current
    let dayEnd = cal.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
    let dayStart = dayEnd.addingTimeInterval(-24 * 3600)
    let inWindow = SleepSessionStore.shared.pastSessions.filter {
      $0.startedAt >= dayStart && $0.startedAt < dayEnd
    }
    // Longest session wins — short test taps don't count as "last night".
    guard let primary = inWindow.max(by: { $0.durationSeconds < $1.durationSeconds })
    else { return }
    let dbPath = HealthDataStore.defaultDatabasePath()
    let sessionID = primary.id.uuidString
    let startMs = Int64((primary.startedAt.timeIntervalSince1970 * 1000).rounded())
    let endMs = Int64((primary.endedAt.timeIntervalSince1970 * 1000).rounded())
    Task.detached(priority: .userInitiated) {
      let bridge = GooseRustBridge()
      // sleep.compute_reading chains recovery.compute_from_sleep_reading
      // and upserts both tables. Cheap when the row already exists
      // (same session_id + window → idempotent upsert).
      _ = try? bridge.request(
        method: "sleep.compute_reading",
        args: [
          "database_path": dbPath,
          "session_id": sessionID,
          "start_time_unix_ms": startMs,
          "end_time_unix_ms": endMs,
        ]
      )
      await MainActor.run {
        loadReadingsForSelectedDay()
      }
    }
  }

  /// Pull strain + recovery rows for whatever date the strip is on.
  /// Strain is per-day, recovery is per-wake-day; both share the same
  /// `yyyy-MM-dd` local key.
  private func loadReadingsForSelectedDay() {
    let date = selectedDay.currentDate
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    let key = formatter.string(from: date)
    let dbPath = HealthDataStore.defaultDatabasePath()

    // Strain: today comes from live in-memory store; past days from sqlite.
    // Always re-fetch (no cache short-circuit) — refreshHomeData clears
    // the cache up-front; this fetch is what populates it.
    if !Calendar.current.isDateInToday(date) {
      Task.detached(priority: .userInitiated) {
        let bridge = GooseRustBridge()
        let response = try? bridge.request(
          method: "strain.get_for_date",
          args: ["database_path": dbPath, "date_key": key]
        )
        let raw = response?["strain"]
        let value = (raw as? Double) ?? (raw as? NSNumber).map { $0.doubleValue } ?? nil
        await MainActor.run {
          if let value, value > 0 { pastStrainByDate[key] = value }
        }
      }
    }

    // Recovery: same key, fetched from recovery.latest_reading. The
    // bridge returns the most-recent row; for today's home that IS the
    // last night's reading. For past dates we walk the daily history.
    // Also extract sleep_score from the components — surfaces on the
    // sleep ring when there's no WHOOP-imported sleepPerformancePct.
    // Always re-fetch — see strain comment above.
    do {
      Task.detached(priority: .userInitiated) {
        let bridge = GooseRustBridge()
        let response = try? bridge.request(
          method: "recovery.latest_reading",
          args: ["database_path": dbPath, "history_days": 30]
        )
        var recoveryScore: Double? = nil
        var sleepScore: Double? = nil
        let dateKey = (response?["date_key"] as? String)
        if dateKey == key,
           let output = (response?["score_result"] as? [String: Any])?["output"] as? [String: Any] {
          recoveryScore = (output["score_0_to_100"] as? Double)
            ?? (output["score_0_to_100"] as? NSNumber).map { $0.doubleValue }
          if let components = output["components"] as? [[String: Any]],
             let sleepComponent = components.first(where: { ($0["name"] as? String) == "sleep" }) {
            sleepScore = (sleepComponent["score_0_to_100"] as? Double)
              ?? (sleepComponent["score_0_to_100"] as? NSNumber).map { $0.doubleValue }
          }
        } else if let daily = response?["daily"] as? [[String: Any]],
                  let match = daily.first(where: { ($0["date_key"] as? String) == key }) {
          recoveryScore = (match["score_0_to_100"] as? Double)
            ?? (match["score_0_to_100"] as? NSNumber).map { $0.doubleValue }
        }
        await MainActor.run {
          if let s = recoveryScore, s > 0 { recoveryByDate[key] = s }
          if let s = sleepScore, s > 0 { sleepByDate[key] = s }
        }
      }
    }
  }

  private var header: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(selectedDayHeaderLabel.uppercased())
          .font(.system(size: 11, weight: .heavy, design: .rounded))
          .tracking(2.5)
          .foregroundStyle(.white.opacity(0.55))
        Text("OVERVIEW")
          .font(.system(size: 20, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white)
      }
      Spacer()
      WhoopLiveHRPill(ble: model.ble)
      if false {
        ProgressView()
          .tint(.white)
      }
    }
    .padding(.horizontal, 22)
    .padding(.top, 10)
  }

  private var selectedDayHeaderLabel: String {
    let formatter = DateFormatter()
    if Calendar.current.isDateInToday(selectedDay.currentDate) {
      return "TODAY"
    }
    if Calendar.current.isDateInYesterday(selectedDay.currentDate) {
      return "YESTERDAY"
    }
    formatter.dateFormat = "EEEE, MMM d"
    return formatter.string(from: selectedDay.currentDate)
  }

  private var lastSyncedLabel: String {
    guard let dataDate = dataDateFromOverview() else {
      return "NO DATA"
    }
    let days = Calendar.current.dateComponents([.day], from: dataDate, to: Date()).day ?? 0
    if days <= 0 { return "DATA: TODAY" }
    if days == 1 { return "DATA: 1 DAY OLD" }
    return "DATA: \(days) DAYS OLD"
  }

  private var stalenessColor: Color {
    guard let dataDate = dataDateFromOverview() else {
      return Color.red.opacity(0.85)
    }
    let days = Calendar.current.dateComponents([.day], from: dataDate, to: Date()).day ?? 0
    if days <= 1 { return Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.85) }
    if days <= 3 { return Color(red: 1.0, green: 0.88, blue: 0.40).opacity(0.85) }
    return Color(red: 1.0, green: 0.37, blue: 0.42).opacity(0.85)
  }

  private func dataDateFromOverview() -> Date? {
    // Now reads from local SQLite cache: the most recent imported summary.
    let keys = importedDailyStore.byDate.keys.sorted()
    guard let dateKey = keys.last else { return nil }
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f.date(from: dateKey)
  }

  private var dateStrip: some View {
    DateStripView()
  }

  /// Three-ring hero: sleep on left, recovery middle, strain right.
  /// Matches WHOOP's home layout.
  private var heroDualRings: some View {
    let resolvedRecovery = resolvedRecoveryScore
    let recoveryValue = resolvedRecovery.value
    let recoveryColor = Self.recoveryColor(forPercent: recoveryValue)
    let resolvedStrainTuple = resolvedStrain
    let strainColor = Self.strainColor
    let target = strainTarget(forRecovery: recoveryValue, isUnknown: resolvedRecovery.source == .none)
    let resolvedSleep = resolvedSleepPerformance
    return HStack(spacing: 16) {
      Spacer(minLength: 0)
      NavigationLink {
        SleepDetailView()
      } label: {
        sleepRingHero(
          value: resolvedSleep.value,
          source: resolvedSleep.source == .local ? "LOCAL" : (resolvedSleep.source == .none ? nil : nil)
        )
      }
      .buttonStyle(.plain)
      NavigationLink(value: WhoopMetric.recovery) {
        recoveryRingHero(
          value: resolvedRecovery.source == .none ? nil : recoveryValue,
          color: recoveryColor,
          source: resolvedRecovery.source == .local ? "LOCAL" : nil
        )
      }
      .buttonStyle(.plain)
      NavigationLink(value: WhoopMetric.strain) {
        strainRingHero(
          value: resolvedStrainTuple.value,
          color: strainColor,
          source: resolvedStrainTuple.source == .local ? "LOCAL" : nil,
          targetMin: target.minimum,
          targetMax: target.maximum,
          targetLabel: target.label
        )
      }
      .buttonStyle(.plain)
      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity)
  }

  private enum SleepSource {
    case server
    case local
    case none
  }

  /// Sleep performance fallback chain: SQLite-imported summary → detected
  /// sleep-window perf × 100 → none.
  private var resolvedSleepPerformance: (value: Int?, source: SleepSource) {
    if let perf = importedDailyStore.summary(for: selectedDay.currentDate)?.sleepPerformancePct, perf > 0 {
      return (Int(perf.rounded()), .server)
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    let key = formatter.string(from: selectedDay.currentDate)
    if let local = sleepByDate[key], local > 0 {
      return (Int(local.rounded()), .local)
    }
    return (nil, .none)
  }

  private func sleepRingHero(value: Int?, source: String?) -> some View {
    let color = Color(red: 0.55, green: 0.85, blue: 1.0)
    return ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: 8)
      Circle()
        .trim(from: 0, to: value.map { min(Double($0) / 100.0, 1) } ?? 0)
        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.55), radius: 5)
      VStack(spacing: 2) {
        Text(value.map { "\($0)" } ?? "--")
          .font(.system(size: 26, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("SLEEP")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1.8)
          .foregroundStyle(color)
        if let source {
          Text(source)
            .font(.system(size: 6, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
        }
      }
    }
    .frame(width: 104, height: 104)
  }

  private func recoveryRingHero(value: Int?, color: Color, source: String?) -> some View {
    ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: 8)
      Circle()
        .trim(from: 0, to: value.map { Double($0) / 100.0 } ?? 0)
        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.55), radius: 5)
      VStack(spacing: 2) {
        Text(value.map { "\($0)" } ?? "--")
          .font(.system(size: 26, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("RECOVERY")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1.8)
          .foregroundStyle(color)
        if let source {
          Text(source)
            .font(.system(size: 6, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
        }
      }
    }
    .frame(width: 104, height: 104)
  }

  private func strainRingHero(
    value: Double, color: Color, source: String?,
    targetMin: Double, targetMax: Double, targetLabel: String
  ) -> some View {
    let frac = min(value / 21.0, 1)
    let target = (targetMin + targetMax) / 2
    let targetFrac = target / 21.0
    let bandStart = targetMin / 21.0
    let bandEnd = targetMax / 21.0
    let tickEpsilon = 0.002
    return ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: 8)
      // Gray-filled range arc spanning the target band.
      Circle()
        .trim(from: bandStart, to: bandEnd)
        .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        .rotationEffect(.degrees(-90))
      // Thin white center line at the midpoint of the band — the target.
      Circle()
        .trim(from: targetFrac - tickEpsilon, to: targetFrac + tickEpsilon)
        .stroke(Color.white, style: StrokeStyle(lineWidth: 8, lineCap: .butt))
        .rotationEffect(.degrees(-90))
      Circle()
        .trim(from: 0, to: frac)
        .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.55), radius: 5)
      VStack(spacing: 2) {
        Text(String(format: "%.1f", value))
          .font(.system(size: 22, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("STRAIN")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1.8)
          .foregroundStyle(color)
        Text("target \(Int(target))")
          .font(.system(size: 6, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.55))
        if let source {
          Text(source)
            .font(.system(size: 6, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
        }
      }
      .padding(.horizontal, 8)
    }
    .frame(width: 104, height: 104)
  }

  private struct HeroStrainTarget {
    let label: String
    let minimum: Double
    let maximum: Double
  }

  /// Same band tiers used by `WhoopStrainTargetCard`, kept in sync.
  private func strainTarget(forRecovery recovery: Int, isUnknown: Bool) -> HeroStrainTarget {
    if isUnknown { return HeroStrainTarget(label: "BASELINE", minimum: 10, maximum: 14) }
    if recovery >= 67 { return HeroStrainTarget(label: "PUSH", minimum: 14, maximum: 18) }
    if recovery >= 34 { return HeroStrainTarget(label: "MODERATE", minimum: 10, maximum: 14) }
    return HeroStrainTarget(label: "RECOVERY", minimum: 6, maximum: 10)
  }

  private var recoveryRing: some View {
    let resolved = resolvedRecoveryScore
    let value = resolved.value
    let color = Self.recoveryColor(forPercent: value)

    return ZStack {
      Circle()
        .stroke(Color.white.opacity(0.06), lineWidth: 10)

      Circle()
        .trim(from: 0, to: resolved.source == .none ? 0 : Double(value) / 100.0)
        .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
        .rotationEffect(.degrees(-90))
        .shadow(color: color.opacity(0.6), radius: 6, x: 0, y: 0)

      VStack(spacing: 2) {
        Text(resolved.source == .none ? "--" : "\(value)")
          .font(.system(size: 42, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
          .minimumScaleFactor(0.5)

        Text("RECOVERY")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(color)
        if resolved.source == .local {
          Text("LOCAL")
            .font(.system(size: 7, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
        }
      }
      .padding(14)
    }
    .frame(width: 130, height: 130)
  }

  private enum RecoverySource {
    case server
    case local
    case none
  }

  /// Recovery fallback: SQLite-cached imported daily summary first, then
  /// our local `GooseRecoveryCalculator`. No runtime cloud reads.
  private var resolvedRecoveryScore: (value: Int, source: RecoverySource) {
    // Recovery comes from the recovery_readings table — written by
    // sleep.compute_reading (which chains the goose_recovery_v0 formula
    // off the just-computed SleepReading). For the selected day, look
    // up the wake-date key; if it's there, render. No more in-memory
    // GooseRecoveryCalculator fallback — one path, one formula.
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    let key = formatter.string(from: selectedDay.currentDate)
    if let value = recoveryByDate[key], value > 0 {
      return (Int(value.rounded()), .local)
    }
    return (0, .none)
  }

  private var statGrid: some View {
    let summary = importedDailyStore.summary(for: selectedDay.currentDate)
    return LazyVGrid(
      columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)],
      spacing: 12
    ) {
      statTile(label: "HRV",        value: format(summary?.hrvRmssdMs, unit: "ms", digits: 0))
      statTile(label: "RHR",        value: format(summary?.restingHrBpm, unit: "bpm", digits: 0))
      statTile(label: "SLEEP",      value: format(summary?.sleepPerformancePct, unit: "%", digits: 0))
      statTile(label: "STRAIN",     value: format(summary?.strainScore, unit: "", digits: 1))
      statTile(label: "SPO₂",       value: format(summary?.spo2Pct, unit: "%", digits: 0))
      statTile(label: "SKIN TEMP",  value: format(summary?.skinTempC, unit: "°C", digits: 1))
    }
  }

  private func statTile(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(2)
        .foregroundStyle(.white.opacity(0.55))
      Text(value)
        .font(.system(size: 22, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
    .padding(14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: 14, style: .continuous)
        .fill(Color.white.opacity(0.04))
    )
  }

  @ViewBuilder
  private var sleepCard: some View {
    if let summary = importedDailyStore.summary(for: selectedDay.currentDate),
       summary.sleepInBedMs != nil || summary.sleepDeepMs != nil {
      cardSurface {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline) {
            Text("SLEEP")
              .font(.system(size: 11, weight: .heavy, design: .rounded))
              .tracking(2.5)
              .foregroundStyle(.white.opacity(0.6))
            Spacer()
            Text(Self.formatMillis(summary.sleepInBedMs))
              .font(.system(size: 20, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.white)
          }

          stageBarFromSummary(summary: summary)
            .frame(height: 22)

          LazyVGrid(
            columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
            alignment: .leading,
            spacing: 8
          ) {
            stageRow(label: "DEEP", color: Self.stageDeep, millis: summary.sleepDeepMs)
            stageRow(label: "REM",  color: Self.stageREM,  millis: summary.sleepRemMs)
            stageRow(label: "LIGHT",color: Self.stageLight,millis: summary.sleepLightMs)
            stageRow(label: "AWAKE",color: Self.stageAwake,millis: summary.sleepAwakeMs)
          }
        }
      }
    } else if let window = SleepWindowStore.shared.lastNight {
      // Server has no sleep stages — fall back to our locally-detected
      // sleep window from `SleepWindowDetector`. Doesn't have stages but
      // duration + performance is enough to keep the sleep card useful.
      cardSurface {
        VStack(alignment: .leading, spacing: 14) {
          HStack(alignment: .firstTextBaseline) {
            HStack(spacing: 6) {
              Text("SLEEP")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.6))
              Text("LOCAL")
                .font(.system(size: 8, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(
                  RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.18))
                )
            }
            Spacer()
            Text(localSleepDurationLabel(window.durationSeconds))
              .font(.system(size: 20, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.white)
          }
          HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
              Text("ASLEEP").font(.system(size: 8, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(.white.opacity(0.45))
              Text(localClockLabel(window.onset))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
              Text("WAKE").font(.system(size: 8, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(.white.opacity(0.45))
              Text(localClockLabel(window.wake))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
              Text("PERFORMANCE").font(.system(size: 8, weight: .heavy, design: .rounded)).tracking(1).foregroundStyle(.white.opacity(0.45))
              Text(String(format: "%.0f%%", window.performance * 100))
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
            }
            Spacer()
          }
        }
      }
    }
  }

  private func localClockLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
  }

  private func localSleepDurationLabel(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    return "\(h)h \(String(format: "%02d", m))m"
  }

  @ViewBuilder
  private var strainCard: some View {
    let resolved = resolvedStrain
    if showStrainDebugOverlay, let debug = dayStrain.debug {
      // Temporary diagnostic block so we can see what the strain calculator
      // is actually doing. Will go away once today's data is sorted out.
      VStack(alignment: .leading, spacing: 2) {
        Text("STRAIN DEBUG (TODAY)")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1.2)
          .foregroundStyle(.white.opacity(0.6))
        Text("workouts=\(debug.workoutsFound)  hr_samples=\(debug.totalHRSamples)  non_workout=\(debug.nonWorkoutSamples)")
          .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(.white.opacity(0.55))
        Text(String(format: "bg_trimp=%.1f  edw_raw=%.1f  edw_scaled=%.1f  total=%.1f  strain=%.2f",
                    debug.backgroundTRIMP, debug.workoutEdwardsRaw,
                    debug.workoutEdwardsScaled, debug.totalTRIMP, debug.finalStrain))
          .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(.white.opacity(0.55))
        Text("formulas: per-activity (running fit α=2.5; walking α=7.5; ...)")
          .font(.system(size: 9, weight: .semibold, design: .rounded).monospacedDigit())
          .foregroundStyle(Color(red: 0.55, green: 0.85, blue: 1.0).opacity(0.85))
      }
      .padding(8)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color(red: 0.18, green: 0.65, blue: 0.45).opacity(0.12))
      )
    }
    if resolved.value > 0 || resolved.source != .none {
      cardSurface {
        HStack(alignment: .center, spacing: 14) {
          VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
              Text("STRAIN")
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .tracking(2.5)
                .foregroundStyle(.white.opacity(0.6))
              if resolved.source == .local {
                Text("LOCAL")
                  .font(.system(size: 8, weight: .heavy, design: .rounded))
                  .tracking(1)
                  .foregroundStyle(Color(red: 0.18, green: 0.88, blue: 0.66))
                  .padding(.horizontal, 4)
                  .padding(.vertical, 2)
                  .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                      .fill(Color(red: 0.18, green: 0.88, blue: 0.66).opacity(0.18))
                  )
              }
            }
            Text(String(format: "%.1f", resolved.value))
              .font(.system(size: 36, weight: .heavy, design: .rounded))
              .monospacedDigit()
              .foregroundStyle(.white)
            Text("of 21")
              .font(.system(size: 11, weight: .semibold, design: .rounded))
              .foregroundStyle(.white.opacity(0.5))
          }
          Spacer()
          ZStack {
            Circle()
              .stroke(Color.white.opacity(0.08), lineWidth: 8)
            Circle()
              .trim(from: 0, to: min(resolved.value / 21.0, 1))
              .stroke(Self.strainColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
              .rotationEffect(.degrees(-90))
          }
          .frame(width: 72, height: 72)
        }
      }
    }
  }

  private enum StrainSource {
    case server
    case local
    case none
  }

  private var resolvedStrain: (value: Double, source: StrainSource) {
    // Today: live in-memory value accumulating as the day goes on.
    // Past days: read from daily_strain_readings (written by
    // StrainFinalizer the next time the app opens after midnight).
    // imported_daily_summary is no longer consulted — it was the
    // long-stale WHOOP cloud field that produced 0.5 for active days.
    if Calendar.current.isDateInToday(selectedDay.currentDate) {
      if let local = dayStrain.today, local.strain > 0 {
        return (local.strain, .local)
      }
      return (0, .none)
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone.current
    let key = formatter.string(from: selectedDay.currentDate)
    if let value = pastStrainByDate[key], value > 0 {
      return (value, .local)
    }
    return (0, .none)
  }

  private func stageBarFromSummary(summary: WhoopImportedDailyStore.DailySummary) -> some View {
    let total = max(
      (summary.sleepDeepMs ?? 0)
        + (summary.sleepRemMs ?? 0)
        + (summary.sleepLightMs ?? 0)
        + (summary.sleepAwakeMs ?? 0),
      1
    )
    let segments: [(Int, Color)] = [
      (summary.sleepDeepMs ?? 0,  Self.stageDeep),
      (summary.sleepRemMs ?? 0,   Self.stageREM),
      (summary.sleepLightMs ?? 0, Self.stageLight),
      (summary.sleepAwakeMs ?? 0, Self.stageAwake),
    ]
    return GeometryReader { proxy in
      HStack(spacing: 2) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, entry in
          if entry.0 > 0 {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(entry.1)
              .frame(width: proxy.size.width * CGFloat(entry.0) / CGFloat(total))
          }
        }
      }
    }
  }

  private func stageBar(stages: WhoopOverview.StageSummary) -> some View {
    let total = max(
      (stages.total_slow_wave_sleep_time_milli ?? 0)
        + (stages.total_rem_sleep_time_milli ?? 0)
        + (stages.total_light_sleep_time_milli ?? 0)
        + (stages.total_awake_time_milli ?? 0),
      1
    )
    let segments: [(Int, Color)] = [
      (stages.total_slow_wave_sleep_time_milli ?? 0, Self.stageDeep),
      (stages.total_rem_sleep_time_milli ?? 0,        Self.stageREM),
      (stages.total_light_sleep_time_milli ?? 0,      Self.stageLight),
      (stages.total_awake_time_milli ?? 0,            Self.stageAwake)
    ]
    return GeometryReader { proxy in
      HStack(spacing: 2) {
        ForEach(Array(segments.enumerated()), id: \.offset) { _, entry in
          if entry.0 > 0 {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
              .fill(entry.1)
              .frame(width: proxy.size.width * CGFloat(entry.0) / CGFloat(total))
          }
        }
      }
    }
  }

  private func stageRow(label: String, color: Color, millis: Int?) -> some View {
    HStack(spacing: 8) {
      Circle().fill(color).frame(width: 8, height: 8)
      Text(label)
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.7))
      Spacer(minLength: 4)
      Text(Self.formatMillis(millis))
        .font(.system(size: 13, weight: .bold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
  }

  private func cardSurface<Content: View>(@ViewBuilder content: () -> Content) -> some View {
    content()
      .padding(18)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 22, style: .continuous)
          .fill(Self.cardBackground)
      )
  }

  private func format(_ value: Double?, unit: String, digits: Int) -> String {
    guard let value, value.isFinite else { return "--" }
    let formatted = String(format: "%.\(digits)f", value)
    return unit.isEmpty ? formatted : "\(formatted) \(unit)"
  }

  private var headerDateLabel: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "EEEE, MMM d"
    return formatter.string(from: Date())
  }

  private static func formatMillis(_ value: Int?) -> String {
    guard let value, value > 0 else { return "--" }
    let totalMinutes = value / 60_000
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 { return "\(minutes)m" }
    return "\(hours)h \(minutes)m"
  }

  private static func recoveryColor(forPercent value: Int) -> Color {
    switch value {
    case 67...:    return Color(red: 0.18, green: 0.88, blue: 0.66)
    case 34...:    return Color(red: 1.0, green: 0.88, blue: 0.40)
    case 0...:     return Color(red: 1.0, green: 0.37, blue: 0.42)
    default:       return Color.white.opacity(0.3)
    }
  }

  private static let strainColor = Color(red: 0.30, green: 0.65, blue: 1.0)
  private static let stageDeep   = Color(red: 0.18, green: 0.40, blue: 0.95)
  private static let stageREM    = Color(red: 0.55, green: 0.35, blue: 1.0)
  private static let stageLight  = Color(red: 0.30, green: 0.65, blue: 1.0)
  private static let stageAwake  = Color(red: 1.0,  green: 0.55, blue: 0.30)

  private static let cardBackground = LinearGradient(
    colors: [
      Color(red: 0.05, green: 0.09, blue: 0.16),
      Color(red: 0.03, green: 0.05, blue: 0.10)
    ],
    startPoint: .top,
    endPoint: .bottom
  )

  private static let backgroundGradient = LinearGradient(
    colors: [
      Color(red: 0.02, green: 0.04, blue: 0.09),
      Color(red: 0.00, green: 0.00, blue: 0.03)
    ],
    startPoint: .top,
    endPoint: .bottom
  )
}

private extension WhoopOverview.StageSummary {
  func value(for stage: String) -> Int {
    switch stage {
    case "deep":  return total_slow_wave_sleep_time_milli ?? 0
    case "rem":   return total_rem_sleep_time_milli ?? 0
    case "light": return total_light_sleep_time_milli ?? 0
    case "awake": return total_awake_time_milli ?? 0
    default:      return 0
    }
  }
}
