import SwiftUI
import Charts

/// Full sleep detail page. Surfaces server-rated sleep + our locally-
/// derived data (sleep onset/wake window, nightly HRV, ambient
/// environment, stage breakdown vs need).
struct SleepDetailView: View {
  @ObservedObject private var selectedDay = SelectedDayStore.shared
  @ObservedObject private var sleepStore = SleepWindowStore.shared
  @ObservedObject private var hrvStore = NightlyHRVStore.shared
  @ObservedObject private var hypnoStore = SleepHypnogramStore.shared
  @ObservedObject private var importedStore = WhoopImportedSleepStore.shared
  @ObservedObject private var dailyStore = WhoopImportedDailyStore.shared
  @ObservedObject private var audioRecorder = SleepAudioRecorder.shared
  @ObservedObject private var sleepSession = SleepSessionStore.shared

  /// Loaded asynchronously by `refreshReading()` against the latest
  /// PastSession (or, failing that, the detected sleep window). Drives
  /// the SLEEP READING card.
  @State private var reading: SleepReadingSnapshot?
  @State private var readingLoading: Bool = false
  @State private var readingError: String?

  var body: some View {
    GeometryReader { geo in
      ZStack {
        WhoopHomeView.detailBackground.ignoresSafeArea()
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 20) {
            hero
            sleepReadingCard
            recoveryReadingCard
            stageHypnogram
            stageBreakdownCard
            needVsActualCard
            windowAndConsistencyCard
            environmentCard
            sleepSessionCard
            sleepAudioCard
            hrvCard
            trendChart
          }
          .padding(.horizontal, 18)
          .padding(.bottom, 32)
          .frame(width: geo.size.width, alignment: .leading)
        }
      }
    }
    .navigationTitle("Sleep")
    .navigationBarTitleDisplayMode(.large)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .task {
      // SQLite-only: refresh from local store. No runtime cloud loads.
      await dailyStore.refreshFromLocal(databasePath: HealthDataStore.defaultDatabasePath())
    }
    .onAppear {
      refreshForCurrentDate()
      Task {
        await importedStore.bootstrapIfNeeded(databasePath: HealthDataStore.defaultDatabasePath())
      }
      audioRecorder.reloadRecentEvents()
      sleepSession.backfillKnownNightIfMissing()
      refreshReading()
    }
    .onChange(of: selectedDay.currentDate) { _, _ in
      refreshForCurrentDate()
      refreshReading()
    }
    .onChange(of: sleepSession.pastSessions.first?.id) { _, _ in
      refreshReading()
    }
    .onReceive(NotificationCenter.default.publisher(for: SleepSessionStore.sleepReadingComputedNotification)) { _ in
      refreshReading()
    }
  }

  // MARK: - Hero

  private var hero: some View {
    let perf = resolvedPerformance
    return VStack(alignment: .leading, spacing: 8) {
      Text("SLEEP")
        .font(.system(size: 11, weight: .heavy, design: .rounded))
        .tracking(2.5)
        .foregroundStyle(.white.opacity(0.55))
      HStack(alignment: .lastTextBaseline) {
        Text(perf.value.map { "\($0)" } ?? "--")
          .font(.system(size: 72, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("%")
          .font(.system(size: 32, weight: .heavy, design: .rounded))
          .foregroundStyle(.white.opacity(0.55))
        Spacer()
      }
      HStack(spacing: 10) {
        Text(perf.source == .local ? "LOCAL · DETECTED WINDOW" : "PERFORMANCE")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.55))
        if let duration = totalSleepDurationText {
          Text("· \(duration) total")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(.white.opacity(0.55))
        }
      }
    }
  }

  private var resolvedPerformance: (value: Int?, source: SleepDetailSource) {
    if let server = dailyStore.summary(for: selectedDay.currentDate)?.sleepPerformancePct {
      return (Int(server.rounded()), .server)
    }
    if let window = sleepStore.lastNight {
      return (Int((window.performance * 100).rounded()), .local)
    }
    return (nil, .none)
  }

  private enum SleepDetailSource { case server, local, none }

  private var totalSleepDurationText: String? {
    if let inBed = dailyStore.summary(for: selectedDay.currentDate)?.sleepInBedMs {
      return Self.formatMillis(inBed)
    }
    if let window = sleepStore.lastNight {
      let total = Int(window.durationSeconds.rounded())
      let h = total / 3600
      let m = (total % 3600) / 60
      return "\(h)h \(String(format: "%02d", m))m"
    }
    return nil
  }

  // MARK: - Hypnogram (stage timeline)

  /// True overnight hypnogram from locally-computed per-epoch sleep stages
  /// (SleepStageEstimator). Falls back to a stacked proportion bar from
  /// the server's stage totals when the local estimator has nothing.
  private var stageHypnogram: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 10) {
        HStack(spacing: 6) {
          Text("HYPNOGRAM")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.55))
          if hypnoStore.lastNight != nil {
            sourceTag("LOCAL", color: Self.greenAccent)
          } else if importedHypnogram != nil {
            sourceTag("WHOOP", color: Self.hrvAccent)
          }
          Spacer()
        }

        // Lift Y-axis labels OUT of hypnogramTimeline so they show in both
        // the local-timeline path AND the server-stages-fallback path.
        HStack(alignment: .top, spacing: 6) {
          stageAxisColumn
            .frame(width: 46, height: 96)
          if let hypno = hypnoStore.lastNight, !hypno.epochs.isEmpty {
            hypnogramTimeline(hypno)
              .frame(height: 96)
              .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          } else if let importedHypno = importedHypnogram, !importedHypno.epochs.isEmpty {
            hypnogramTimeline(importedHypno)
              .frame(height: 96)
              .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          } else if let summary = dailyStore.summary(for: selectedDay.currentDate),
                    summary.sleepInBedMs != nil {
            // Stack the server's stage totals into 4 horizontal rows, one
            // per stage, so the Y-axis labels still align with rows.
            stagesRowsFromSummary(summary: summary)
              .frame(height: 96)
          } else {
            ZStack {
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.02))
              VStack(spacing: 4) {
                Text(emptyHypnogramMainText)
                  .font(.system(size: 10, weight: .heavy, design: .rounded))
                  .foregroundStyle(.white.opacity(0.55))
                  .multilineTextAlignment(.center)
                if let hint = emptyHypnogramHint {
                  Text(hint)
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .multilineTextAlignment(.center)
                }
              }
              .padding(.horizontal, 12)
            }
            .frame(height: 96)
          }
        }

        importStatusRow

        if let hypno = hypnoStore.lastNight ?? importedHypnogram, !hypno.epochs.isEmpty {
          hypnogramAxis(hypno)
          HStack(spacing: 16) {
            stageLegend(label: "DEEP", minutes: hypno.stageMinutes[.deep] ?? 0, color: Self.deep)
            stageLegend(label: "REM", minutes: hypno.stageMinutes[.rem] ?? 0, color: Self.rem)
            stageLegend(label: "LIGHT", minutes: hypno.stageMinutes[.light] ?? 0, color: Self.light)
            stageLegend(label: "AWAKE", minutes: hypno.stageMinutes[.wake] ?? 0, color: Self.awake)
          }
        } else if let summary = dailyStore.summary(for: selectedDay.currentDate),
                  summary.sleepInBedMs != nil {
          HStack(spacing: 16) {
            stageLegend(label: "DEEP", millis: summary.sleepDeepMs, color: Self.deep)
            stageLegend(label: "REM", millis: summary.sleepRemMs, color: Self.rem)
            stageLegend(label: "LIGHT", millis: summary.sleepLightMs, color: Self.light)
            stageLegend(label: "AWAKE", millis: summary.sleepAwakeMs, color: Self.awake)
          }
        }
      }
    }
  }

  /// Clean WHOOP-style hypnogram. Coalesce adjacent epochs of the same
  /// stage into runs, draw each run as one filled rounded rectangle at
  /// its stage's row. No connector lines, no per-epoch slivers.
  private func hypnogramTimeline(_ hypno: SleepStageEstimator.Hypnogram) -> some View {
    let totalSeconds = max(hypno.windowEnd.timeIntervalSince(hypno.windowStart), 1)
    let yFracs = Self.stageYFracs
    let stageRowY: [SleepStageEstimator.Stage: CGFloat] = [
      .wake: yFracs[0],
      .rem: yFracs[1],
      .light: yFracs[2],
      .deep: yFracs[3],
    ]
    let runs = Self.coalesceRuns(epochs: hypno.epochs)

    return GeometryReader { geo in
      let barHeight: CGFloat = 12

      ZStack(alignment: .topLeading) {
        // Faint row guidelines
        ForEach(0..<4, id: \.self) { row in
          let y = geo.size.height * yFracs[row]
          Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(width: geo.size.width, height: 0.5)
            .offset(y: y)
        }

        // Connector strokes — one vertical line per stage transition,
        // drawn at the boundary X between consecutive runs.
        Path { p in
          for i in 1..<runs.count {
            let prev = runs[i - 1]
            let next = runs[i]
            if prev.stage == next.stage { continue }
            let boundaryX = CGFloat(prev.end.timeIntervalSince(hypno.windowStart) / totalSeconds) * geo.size.width
            let prevY = (stageRowY[prev.stage] ?? 0.5) * geo.size.height
            let nextY = (stageRowY[next.stage] ?? 0.5) * geo.size.height
            p.move(to: CGPoint(x: boundaryX, y: prevY))
            p.addLine(to: CGPoint(x: boundaryX, y: nextY))
          }
        }
        .stroke(Color.white.opacity(0.55), lineWidth: 1.2)

        // One rectangle per coalesced run
        ForEach(runs) { run in
          let x0 = CGFloat(run.start.timeIntervalSince(hypno.windowStart) / totalSeconds) * geo.size.width
          let x1 = CGFloat(run.end.timeIntervalSince(hypno.windowStart) / totalSeconds) * geo.size.width
          let width = max(1.5, x1 - x0)
          let y = (stageRowY[run.stage] ?? 0.5) * geo.size.height - barHeight / 2
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Self.color(for: run.stage))
            .frame(width: width, height: barHeight)
            .offset(x: x0, y: y)
        }
      }
    }
  }

  /// Group consecutive epochs of the same stage into a single run so we
  /// can draw one solid bar rather than 60 stacked sliver lines.
  private struct StageRun: Identifiable {
    let id = UUID()
    let stage: SleepStageEstimator.Stage
    let start: Date
    let end: Date
  }

  private static func coalesceRuns(epochs: [SleepStageEstimator.Epoch]) -> [StageRun] {
    var runs: [StageRun] = []
    var curStage: SleepStageEstimator.Stage?
    var curStart: Date?
    var curEnd: Date?
    for epoch in epochs {
      if epoch.stage == curStage, let endPrev = curEnd, epoch.start.timeIntervalSince(endPrev) < 60 {
        curEnd = epoch.end
      } else {
        if let s = curStage, let start = curStart, let end = curEnd {
          runs.append(StageRun(stage: s, start: start, end: end))
        }
        curStage = epoch.stage
        curStart = epoch.start
        curEnd = epoch.end
      }
    }
    if let s = curStage, let start = curStart, let end = curEnd {
      runs.append(StageRun(stage: s, start: start, end: end))
    }
    return runs
  }

  /// Y-axis column — AWAKE / REM / LIGHT / DEEP labels at the same
  /// fractional Y positions used by the timeline.
  private var stageAxisColumn: some View {
    GeometryReader { geo in
      let labels = ["AWAKE", "REM", "LIGHT", "DEEP"]
      let yFracs = Self.stageYFracs
      ForEach(0..<4, id: \.self) { row in
        Text(labels[row])
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(0.5)
          .foregroundStyle(.white.opacity(0.7))
          .lineLimit(1)
          .fixedSize(horizontal: true, vertical: false)
          .position(x: geo.size.width - 4 - labelHalfWidth(labels[row]), y: geo.size.height * yFracs[row])
      }
    }
  }

  /// Rough half-width estimate for right-aligning the label inside the
  /// axis gutter without it getting clipped at small widths.
  private func labelHalfWidth(_ s: String) -> CGFloat {
    // 9pt heavy rounded ≈ 5.2pt per char. Approximation good enough for
    // right-edge alignment.
    CGFloat(s.count) * 2.6
  }

  /// Server-side stage totals as 4 horizontal proportional bars stacked
  /// vertically, one per stage row — so they align with the Y-axis labels.
  /// SQLite-backed variant. Same render as stagesRows, but reads from a
  /// DailySummary instead of the cloud WhoopOverview.StageSummary.
  private func stagesRowsFromSummary(summary: WhoopImportedDailyStore.DailySummary) -> some View {
    let total = summary.sleepInBedMs ?? 0
    let rows: [(label: String, millis: Int?, color: Color)] = [
      ("AWAKE", summary.sleepAwakeMs, Self.awake),
      ("REM", summary.sleepRemMs, Self.rem),
      ("LIGHT", summary.sleepLightMs, Self.light),
      ("DEEP", summary.sleepDeepMs, Self.deep),
    ]
    return GeometryReader { geo in
      let rowH = geo.size.height / 4
      ZStack(alignment: .topLeading) {
        ForEach(0..<4, id: \.self) { i in
          let frac = total > 0 ? CGFloat(rows[i].millis ?? 0) / CGFloat(total) : 0
          let yCenter = (CGFloat(i) + 0.5) * rowH
          Path { p in
            p.move(to: CGPoint(x: 0, y: yCenter))
            p.addLine(to: CGPoint(x: geo.size.width, y: yCenter))
          }
          .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(rows[i].color)
            .frame(width: max(2, frac * geo.size.width), height: 8)
            .position(x: max(1, frac * geo.size.width) / 2, y: yCenter)
        }
      }
    }
  }

  private func stagesRows(stages: WhoopOverview.StageSummary) -> some View {
    let total = stages.total_in_bed_time_milli ?? 0
    let rows: [(label: String, millis: Int?, color: Color)] = [
      ("AWAKE", stages.total_awake_time_milli, Self.awake),
      ("REM", stages.total_rem_sleep_time_milli, Self.rem),
      ("LIGHT", stages.total_light_sleep_time_milli, Self.light),
      ("DEEP", stages.total_slow_wave_sleep_time_milli, Self.deep),
    ]
    return GeometryReader { geo in
      let rowH = geo.size.height / 4
      ZStack(alignment: .topLeading) {
        ForEach(0..<4, id: \.self) { i in
          let frac = total > 0 ? CGFloat(rows[i].millis ?? 0) / CGFloat(total) : 0
          let yCenter = (CGFloat(i) + 0.5) * rowH
          Path { p in
            p.move(to: CGPoint(x: 0, y: yCenter))
            p.addLine(to: CGPoint(x: geo.size.width, y: yCenter))
          }
          .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
          RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(rows[i].color)
            .frame(width: max(2, frac * geo.size.width), height: 8)
            .position(x: max(1, frac * geo.size.width) / 2, y: yCenter)
        }
      }
    }
  }

  private static let stageYFracs: [CGFloat] = [0.125, 0.375, 0.625, 0.875]

  // MARK: - Empty-state hints

  private var emptyHypnogramMainText: String {
    if Calendar.current.isDateInToday(selectedDay.currentDate) {
      return "No sleep data for today yet."
    }
    return "No sleep data on this date."
  }

  /// Hint pointing at dates that DO have imported data.
  private var emptyHypnogramHint: String? {
    let keys = importedStore.sessionsByDateKey.keys.sorted()
    guard !keys.isEmpty else { return "Wear strap to bed; stages run locally from HR/HRV." }
    if Calendar.current.isDateInToday(selectedDay.currentDate) {
      return "Imported WHOOP data: \(keys.first ?? "—") → \(keys.last ?? "—"). Swipe the date strip."
    }
    return "Have WHOOP data \(keys.first ?? "—") → \(keys.last ?? "—")."
  }

  /// Inline status of the local sleep cache: how many nights cached, any
  /// load error. No more import progress — historical sleep is seeded by
  /// the external backfill script, not by the app.
  private var importStatusRow: some View {
    HStack(spacing: 8) {
      if let err = importedStore.lastImportError {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 10, weight: .heavy))
          .foregroundStyle(Self.redAccent)
        Text(err)
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(0.5)
          .foregroundStyle(Self.redAccent)
          .lineLimit(2)
      } else {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 10, weight: .heavy))
          .foregroundStyle(importedStore.importedNightCount > 0 ? Self.greenAccent : .white.opacity(0.3))
        Text("\(importedStore.importedNightCount) WHOOP nights cached")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1)
          .foregroundStyle(.white.opacity(0.5))
      }
      Spacer()
    }
  }

  /// Fall back to the imported WHOOP hypnogram for the selected date when
  /// we don't have a locally-computed one (e.g. for past nights).
  private var importedHypnogram: SleepStageEstimator.Hypnogram? {
    importedStore.hypnogram(for: selectedDay.currentDate)
  }

  private func sourceTag(_ text: String, color: Color) -> some View {
    Text(text)
      .font(.system(size: 8, weight: .heavy, design: .rounded))
      .tracking(1)
      .foregroundStyle(color)
      .padding(.horizontal, 4)
      .padding(.vertical, 2)
      .background(
        RoundedRectangle(cornerRadius: 3, style: .continuous)
          .fill(color.opacity(0.18))
      )
  }

  /// Refresh all sibling stores against `selectedDay.currentDate`. The
  /// "wake reference" is the end of the selected day so the 18-hour
  /// look-back captures that night's sleep window.
  private func refreshForCurrentDate() {
    let cal = Calendar.current
    let dayStart = cal.startOfDay(for: selectedDay.currentDate)
    let wakeReference: Date
    if cal.isDateInToday(selectedDay.currentDate) {
      wakeReference = Date()
    } else {
      wakeReference = cal.date(byAdding: .hour, value: 12, to: dayStart) ?? selectedDay.currentDate
    }
    sleepStore.refresh(wakeReference: wakeReference)
    hrvStore.refresh()
    hypnoStore.refresh()
  }

  private func hypnogramAxis(_ hypno: SleepStageEstimator.Hypnogram) -> some View {
    HStack {
      Text(Self.clockLabel(hypno.windowStart))
      Spacer()
      Text(Self.clockLabel(hypno.windowEnd))
    }
    .font(.system(size: 8, weight: .heavy, design: .rounded))
    .tracking(1)
    .foregroundStyle(.white.opacity(0.4))
    .monospacedDigit()
  }

  private static func color(for stage: SleepStageEstimator.Stage) -> Color {
    switch stage {
    case .wake: awake
    case .light: light
    case .rem: rem
    case .deep: deep
    }
  }

  private func stageLegend(label: String, minutes: Double, color: Color) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
      Text("\(label) \(Int(minutes))m")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.7))
    }
  }

  private func stagesBar(stages: WhoopOverview.StageSummary) -> some View {
    let total = (stages.total_in_bed_time_milli ?? 0)
    return GeometryReader { proxy in
      HStack(spacing: 1) {
        Rectangle().fill(Self.deep)
          .frame(width: width(forMillis: stages.total_slow_wave_sleep_time_milli, totalMillis: total, parent: proxy.size.width))
        Rectangle().fill(Self.rem)
          .frame(width: width(forMillis: stages.total_rem_sleep_time_milli, totalMillis: total, parent: proxy.size.width))
        Rectangle().fill(Self.light)
          .frame(width: width(forMillis: stages.total_light_sleep_time_milli, totalMillis: total, parent: proxy.size.width))
        Rectangle().fill(Self.awake)
          .frame(width: width(forMillis: stages.total_awake_time_milli, totalMillis: total, parent: proxy.size.width))
      }
    }
  }

  private func width(forMillis ms: Int?, totalMillis total: Int, parent: CGFloat) -> CGFloat {
    guard let ms, total > 0 else { return 0 }
    return parent * CGFloat(ms) / CGFloat(total)
  }

  private func stageLegend(label: String, millis: Int?, color: Color) -> some View {
    HStack(spacing: 6) {
      RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
      Text("\(label) \(Self.formatMillis(millis))")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1)
        .foregroundStyle(.white.opacity(0.7))
    }
  }

  // MARK: - Stage breakdown (numbers grid)

  private var stageBreakdownCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 10) {
        Text("STAGES")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        let summary = dailyStore.summary(for: selectedDay.currentDate)
        LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 10) {
          stageStat(label: "DEEP", millis: summary?.sleepDeepMs, ideal: "13–23%", color: Self.deep, totalMillis: summary?.sleepInBedMs)
          stageStat(label: "REM", millis: summary?.sleepRemMs, ideal: "20–25%", color: Self.rem, totalMillis: summary?.sleepInBedMs)
          stageStat(label: "LIGHT", millis: summary?.sleepLightMs, ideal: "50–60%", color: Self.light, totalMillis: summary?.sleepInBedMs)
          stageStat(label: "AWAKE", millis: summary?.sleepAwakeMs, ideal: "<10%", color: Self.awake, totalMillis: summary?.sleepInBedMs)
        }
        if let cycles = summary?.sleepCycleCount {
          Text("\(cycles) sleep cycles · target 4–5")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.55))
        }
        if let dist = summary?.sleepDisturbanceCount {
          Text("\(dist) disturbances")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.45))
        }
      }
    }
  }

  private func stageStat(label: String, millis: Int?, ideal: String, color: Color, totalMillis: Int?) -> some View {
    let pct: Double? = {
      guard let m = millis, let t = totalMillis, t > 0 else { return nil }
      return Double(m) / Double(t) * 100
    }()
    return VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 5) {
        Circle().fill(color).frame(width: 6, height: 6)
        Text(label)
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.6))
      }
      Text(Self.formatMillis(millis))
        .font(.system(size: 14, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
      Text("\(pct.map { String(format: "%.0f", $0) } ?? "--")% · ideal \(ideal)")
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(0.5)
        .foregroundStyle(.white.opacity(0.45))
    }
  }

  // MARK: - Need vs actual

  private var needVsActualCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("NEED VS GOT")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        let summary = dailyStore.summary(for: selectedDay.currentDate)
        let baseMillis = summary?.sleepNeedBaselineMs ?? (8 * 3600 * 1000)
        let debtMillis = summary?.sleepNeedFromDebtMs ?? 0
        let strainMillis = summary?.sleepNeedFromStrainMs ?? 0
        let napMillis = summary?.sleepNeedFromNapMs ?? 0
        let totalNeed = baseMillis + debtMillis + strainMillis - napMillis
        let inBed = summary?.sleepInBedMs
                  ?? Int((sleepStore.lastNight?.durationSeconds ?? 0) * 1000)
        let coverage = totalNeed > 0 ? Double(inBed) / Double(totalNeed) * 100 : 0
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text("NEED").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
            Text(Self.formatMillis(totalNeed)).font(.system(size: 18, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.white)
          }
          Spacer()
          VStack(alignment: .leading, spacing: 1) {
            Text("GOT").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
            Text(Self.formatMillis(inBed)).font(.system(size: 18, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(.white)
          }
          Spacer()
          VStack(alignment: .leading, spacing: 1) {
            Text("COVER").font(.system(size: 9, weight: .heavy, design: .rounded)).tracking(1.5).foregroundStyle(.white.opacity(0.5))
            Text(String(format: "%.0f%%", coverage)).font(.system(size: 18, weight: .heavy, design: .rounded)).monospacedDigit().foregroundStyle(coverage >= 90 ? Self.greenAccent : (coverage >= 70 ? Self.yellowAccent : Self.redAccent))
          }
        }
        if debtMillis > 0 || strainMillis > 0 {
          HStack(spacing: 10) {
            if debtMillis > 0 {
              Text("DEBT +\(Self.formatMillis(debtMillis))")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(Self.redAccent)
            }
            if strainMillis > 0 {
              Text("STRAIN +\(Self.formatMillis(strainMillis))")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .tracking(1)
                .foregroundStyle(Self.yellowAccent)
            }
            Spacer()
          }
        }
      }
    }
  }

  // MARK: - Window & consistency

  private var windowAndConsistencyCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("WINDOW")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        if let window = sleepStore.lastNight {
          HStack(spacing: 14) {
            kvCell(label: "ASLEEP", value: Self.clockLabel(window.onset))
            kvCell(label: "WAKE", value: Self.clockLabel(window.wake))
            kvCell(label: "DURATION", value: Self.durationLabel(window.durationSeconds))
            kvCell(label: "CONFIDENCE", value: String(format: "%.0f%%", window.confidence * 100))
            Spacer(minLength: 0)
          }
          if let consistency = avgWindowConsistency() {
            Text("Last 7 nights avg bedtime \(consistency.bedtime), wake \(consistency.wake)")
              .font(.system(size: 10, weight: .heavy, design: .rounded))
              .tracking(0.5)
              .foregroundStyle(.white.opacity(0.55))
          }
        } else {
          Text("No detected sleep window yet. Wear the strap to bed for HR drop detection.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
      }
    }
  }

  private struct WindowConsistency {
    let bedtime: String
    let wake: String
  }

  /// Rough average over the last 7 detected nights using the nightly HRV
  /// store's onset/wake fields (those windows match the sleep detector).
  private func avgWindowConsistency() -> WindowConsistency? {
    let nights = hrvStore.recentNights.suffix(7)
    guard nights.count >= 2 else { return nil }
    let onsetMins = nights.map { hour24Minutes(of: $0.onset) }
    let wakeMins = nights.map { hour24Minutes(of: $0.wake) }
    let avgOnset = onsetMins.reduce(0, +) / onsetMins.count
    let avgWake = wakeMins.reduce(0, +) / wakeMins.count
    return WindowConsistency(
      bedtime: clockFromMinutes(avgOnset),
      wake: clockFromMinutes(avgWake)
    )
  }

  private func hour24Minutes(of date: Date) -> Int {
    let comp = Calendar.current.dateComponents([.hour, .minute], from: date)
    return (comp.hour ?? 0) * 60 + (comp.minute ?? 0)
  }

  private func clockFromMinutes(_ mins: Int) -> String {
    let h = (mins / 60 + 24) % 24
    let m = mins % 60
    let suffix = h < 12 ? "AM" : "PM"
    let display = h == 0 ? 12 : (h > 12 ? h - 12 : h)
    return String(format: "%d:%02d %@", display, m, suffix)
  }

  // MARK: - Environment

  private var environmentCard: some View {
    cardSurface {
      WhoopSleepEnvironmentCard()
        .padding(.horizontal, -14)
        .padding(.vertical, -14)
    }
  }

  // MARK: - Sleep audio (always on for the duration of a sleep session)

  private var sleepAudioCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("SLEEP AUDIO")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        Text(audioStatusText)
          .font(.system(size: 11, weight: .semibold, design: .rounded))
          .foregroundStyle(audioStatusColor)
          .fixedSize(horizontal: false, vertical: true)
        if !audioRecorder.recentEvents.isEmpty {
          Divider().overlay(Color.white.opacity(0.1))
          HStack(spacing: 14) {
            kvCell(label: "EVENTS", value: "\(audioRecorder.recentEvents.count)")
            kvCell(label: "SNORE MIN", value: String(format: "%.0f", audioRecorder.totalSnoreSeconds / 60))
            kvCell(label: "PEAK DB", value: String(format: "%.0f", audioRecorder.maxAmbientDB))
            Spacer(minLength: 0)
          }
        }
        Text("Audio listens for the entire duration of a sleep session. Only events (>+12dB above baseline) are saved as 30s clips. Clips auto-prune after \(audioRecorder.retentionDays) days.")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // MARK: - Sleep reading (Rust-computed composite score)

  /// Composite sleep reading for the latest session (or, failing that,
  /// the auto-detected sleep window). Loaded asynchronously via the
  /// Rust bridge; if no cached row exists, the card kicks off a
  /// compute_reading call which persists for next time.
  private var sleepReadingCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 6) {
          Text("SLEEP READING")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.55))
          sourceTag("RUST", color: Self.hrvAccent)
          Spacer()
          if readingLoading {
            ProgressView()
              .progressViewStyle(.circular)
              .tint(.white.opacity(0.4))
              .scaleEffect(0.6)
          }
        }
        if let r = reading {
          readingBody(r)
        } else if let err = readingError {
          Text(err)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Self.redAccent.opacity(0.85))
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("End a sleep session (or wear the strap overnight) and a composite reading shows up here.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private func readingBody(_ r: SleepReadingSnapshot) -> some View {
    HStack(alignment: .lastTextBaseline, spacing: 6) {
      Text(String(format: "%.0f", r.sleepScore))
        .font(.system(size: 52, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
      Text("/ 100")
        .font(.system(size: 16, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.45))
      Spacer()
      VStack(alignment: .trailing, spacing: 2) {
        Text(Self.formatMinutes(r.timeInBedMinutes))
          .font(.system(size: 14, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
        Text("TIME IN BED")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.45))
      }
    }
    LazyVGrid(columns: [
      GridItem(.flexible(), alignment: .leading),
      GridItem(.flexible(), alignment: .leading),
      GridItem(.flexible(), alignment: .leading),
    ], spacing: 10) {
      subscoreCell("DURATION", r.durationScore)
      subscoreCell("EFFICIENCY", r.efficiencyScore)
      subscoreCell("DEPTH", r.depthScore)
      subscoreCell("HRV", r.hrvScore)
      subscoreCell("RESTFUL", r.restfulnessScore)
    }
    Divider().overlay(Color.white.opacity(0.1))
    HStack(spacing: 14) {
      kvCell(label: "ASLEEP", value: Self.formatMinutes(r.totalSleepMinutes))
      kvCell(label: "DEEP", value: Self.formatMinutes(r.deepMinutes))
      kvCell(label: "LIGHT", value: Self.formatMinutes(r.lightMinutes))
      kvCell(label: "AWAKE", value: Self.formatMinutes(r.awakeMinutes))
      Spacer(minLength: 0)
    }
    HStack(spacing: 14) {
      kvCell(label: "EFF", value: String(format: "%.0f%%", r.efficiency * 100))
      kvCell(label: "ONSET", value: r.onsetLatencyMinutes.map { "\($0) min" } ?? "—")
      kvCell(label: "WASO", value: "\(r.wakeAfterSleepOnsetMinutes) min")
      kvCell(label: "HR MEAN", value: r.hrMeanBpm.map { String(format: "%.0f", $0) } ?? "—")
      kvCell(label: "HRV", value: String(format: "%.0f ms", r.hrvMeanRmssdMs))
      Spacer(minLength: 0)
    }
  }

  private func subscoreCell(_ label: String, _ value: Double) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))
      HStack(alignment: .lastTextBaseline, spacing: 3) {
        Text(String(format: "%.0f", value))
          .font(.system(size: 16, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(scoreColor(value))
        Text("/100")
          .font(.system(size: 8, weight: .heavy, design: .rounded))
          .foregroundStyle(.white.opacity(0.35))
      }
      GeometryReader { geo in
        ZStack(alignment: .leading) {
          Capsule().fill(Color.white.opacity(0.08)).frame(height: 3)
          Capsule().fill(scoreColor(value))
            .frame(width: geo.size.width * CGFloat(max(0, min(value, 100)) / 100), height: 3)
        }
      }
      .frame(height: 3)
    }
  }

  // MARK: - Recovery reading (Rust goose_recovery_v0)

  /// Recovery card. Lives right under the sleep card because they're
  /// computed from the same sleep window: HRV 35% + RHR 20% + Sleep 15% +
  /// Respiratory 10% + Temperature 10% + Prior strain 10%. Respiratory
  /// + temperature are neutralized to baseline until we wire local
  /// estimators for them — that's the `respiratory_temperature_neutralized`
  /// flag the bridge returns.
  @ViewBuilder
  private var recoveryReadingCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 12) {
        HStack(spacing: 6) {
          Text("RECOVERY")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.55))
          sourceTag("FROM SLEEP", color: Self.greenAccent)
          Spacer()
        }
        if let rec = reading?.recovery {
          recoveryBody(rec)
        } else if reading != nil {
          Text("Couldn't compute recovery — need at least an HRV baseline. Wear the strap a few more nights and it'll fill in.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
            .fixedSize(horizontal: false, vertical: true)
        } else {
          Text("Recovery appears once a sleep reading is available.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
    }
  }

  @ViewBuilder
  private func recoveryBody(_ r: RecoveryReadingSnapshot) -> some View {
    HStack(alignment: .lastTextBaseline, spacing: 6) {
      Text(String(format: "%.0f", r.recoveryScore))
        .font(.system(size: 52, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(scoreColor(r.recoveryScore))
      Text("/ 100")
        .font(.system(size: 16, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.45))
      Spacer()
      Text(recoveryZoneLabel(r.recoveryScore))
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(scoreColor(r.recoveryScore))
    }
    LazyVGrid(columns: [
      GridItem(.flexible(), alignment: .leading),
      GridItem(.flexible(), alignment: .leading),
      GridItem(.flexible(), alignment: .leading),
    ], spacing: 10) {
      subscoreCell("HRV (35%)", r.hrvScore)
      subscoreCell("RHR (20%)", r.rhrScore)
      subscoreCell("SLEEP (15%)", r.sleepScore)
      subscoreCell("RESP (10%)", r.respiratoryScore)
      subscoreCell("TEMP (10%)", r.temperatureScore)
      subscoreCell("STRAIN (10%)", r.priorStrainScore)
    }
    Divider().overlay(Color.white.opacity(0.1))
    HStack(spacing: 14) {
      kvCell(
        label: "HRV",
        value: String(format: "%.0f / %.0f ms", r.hrvRmssdMs, r.hrvBaselineRmssdMs)
      )
      kvCell(
        label: "RHR",
        value: String(format: "%.0f / %.0f bpm", r.restingHrBpm, r.restingHrBaselineBpm)
      )
      kvCell(label: "PRIOR STRAIN", value: String(format: "%.1f", r.priorStrain))
      kvCell(label: "BASELINE", value: "\(r.baselineNightsUsed) nights")
      Spacer(minLength: 0)
    }
    if r.qualityFlags.contains("respiratory_temperature_neutralized") {
      Text("Respiratory rate and skin temperature are neutralized to baseline (full credit) until those are computed locally — they account for 20% of the score.")
        .font(.system(size: 9, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.4))
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  private func recoveryZoneLabel(_ v: Double) -> String {
    if v >= 67 { return "GREEN" }
    if v >= 34 { return "YELLOW" }
    return "RED"
  }

  private func scoreColor(_ v: Double) -> Color {
    if v >= 85 { return Self.greenAccent }
    if v >= 70 { return Self.yellowAccent }
    if v >= 50 { return Color(red: 1.0, green: 0.62, blue: 0.32) }
    return Self.redAccent
  }

  private static func formatMinutes(_ minutes: Int) -> String {
    let h = minutes / 60
    let m = minutes % 60
    return "\(h)h\(String(format: "%02d", m))m"
  }

  /// A "sleep day" runs from 22:00 the previous calendar day to 22:00
  /// of the selected day. All explicit SleepSessionStore sessions whose
  /// `startedAt` falls in that window count as last night's sleep. The
  /// card computes one reading over `min(start) ... max(end)` — for a
  /// single-sleep night that's just the session, for a night-plus-nap
  /// case it stitches them into one contiguous window (gaps land in
  /// "awake" because there are no HR samples there). When zero sessions
  /// are in the window, the card shows the empty state — no guessing
  /// from raw HR.
  private func refreshReading() {
    let cal = Calendar.current
    let dayEnd = cal.date(
      bySettingHour: 22, minute: 0, second: 0,
      of: selectedDay.currentDate
    ) ?? selectedDay.currentDate
    let dayStart = dayEnd.addingTimeInterval(-24 * 3600)
    let inWindow = sleepSession.pastSessions.filter {
      $0.startedAt >= dayStart && $0.startedAt < dayEnd
    }
    guard let earliest = inWindow.map(\.startedAt).min(),
          let latest = inWindow.map(\.endedAt).max(),
          let primary = inWindow.min(by: { $0.startedAt < $1.startedAt })
    else {
      reading = nil
      return
    }
    loadReading(
      sessionID: primary.id.uuidString,
      startMs: Int64((earliest.timeIntervalSince1970 * 1000).rounded()),
      endMs: Int64((latest.timeIntervalSince1970 * 1000).rounded())
    )
  }

  private static func dateKeyForReading(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: date)
  }

  /// Try the cached row first (sleep.get_reading). If missing, compute
  /// (which also upserts so the next open is instant).
  private func loadReading(sessionID: String, startMs: Int64, endMs: Int64) {
    readingError = nil
    readingLoading = true
    let dbPath = HealthDataStore.defaultDatabasePath()
    Task.detached(priority: .userInitiated) {
      let bridge = GooseRustBridge()
      let cached = try? bridge.request(
        method: "sleep.get_reading",
        args: ["database_path": dbPath, "session_id": sessionID]
      )
      if let cached, let snap = SleepReadingSnapshot.from(bridgeResponse: cached) {
        await MainActor.run {
          self.reading = snap
          self.readingLoading = false
        }
        return
      }
      do {
        let computed = try bridge.request(
          method: "sleep.compute_reading",
          args: [
            "database_path": dbPath,
            "session_id": sessionID,
            "start_time_unix_ms": startMs,
            "end_time_unix_ms": endMs,
          ]
        )
        let snap = SleepReadingSnapshot.from(bridgeResponse: computed)
        await MainActor.run {
          self.reading = snap
          self.readingLoading = false
          if snap == nil { self.readingError = "Couldn't parse the sleep reading response." }
        }
      } catch {
        await MainActor.run {
          self.reading = nil
          self.readingLoading = false
          self.readingError = "Couldn't compute: \(error.localizedDescription)"
        }
      }
    }
  }

  // MARK: - Sleep session + detection log

  private var sleepSessionCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("SLEEP SESSION")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        if let active = sleepSession.active {
          activeSessionView(active)
        } else if let lastSession = sleepSession.pastSessions.first {
          lastSessionSummary(lastSession)
        } else {
          Text("No sleep sessions yet. Tap START SLEEP on the home page.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.4))
        }
      }
    }
  }

  private func activeSessionView(_ active: SleepSessionStore.ActiveSession) -> some View {
    let elapsed = Date().timeIntervalSince(active.startedAt)
    let inferred = sleepSession.detectionLog.last
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "moon.fill").foregroundStyle(Self.hrvAccent)
        Text("ACTIVE")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(Self.hrvAccent)
        Spacer()
        Text(Self.durationLabel(elapsed))
          .font(.system(size: 14, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
      }
      Text("Started \(Self.clockLabel(active.startedAt))")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
      if let i = inferred {
        Divider().overlay(Color.white.opacity(0.1))
        HStack(spacing: 14) {
          kvCell(label: "HEURISTIC", value: i.inferredState.rawValue.uppercased())
          kvCell(label: "MEAN HR", value: i.meanHR.map { String(format: "%.0f", $0) } ?? "—")
          kvCell(label: "RESTING", value: String(format: "%.0f", i.restingBaseline))
          Spacer(minLength: 0)
        }
        Text("Heuristic check runs every 60 sec. We log it during your session so we can compare with your actual start/end and tune the auto-detection.")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private func lastSessionSummary(_ s: SleepSessionStore.PastSession) -> some View {
    let totalSamples = s.detectionLog.count
    let asleepSamples = s.detectionLog.filter { $0.inferredState == .asleep }.count
    let awakeSamples = s.detectionLog.filter { $0.inferredState == .awake }.count
    let unknownSamples = s.detectionLog.filter { $0.inferredState == .unknown }.count
    return VStack(alignment: .leading, spacing: 8) {
      HStack {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(Self.greenAccent)
        Text("LAST SESSION")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.65))
        Spacer()
        Text(Self.durationLabel(s.durationSeconds))
          .font(.system(size: 14, weight: .heavy, design: .rounded))
          .monospacedDigit()
          .foregroundStyle(.white)
      }
      Text("\(Self.clockLabel(s.startedAt)) → \(Self.clockLabel(s.endedAt))")
        .font(.system(size: 10, weight: .heavy, design: .rounded))
        .foregroundStyle(.white.opacity(0.5))
      if totalSamples > 0 {
        Divider().overlay(Color.white.opacity(0.1))
        Text("HEURISTIC OVER SESSION")
          .font(.system(size: 9, weight: .heavy, design: .rounded))
          .tracking(1.5)
          .foregroundStyle(.white.opacity(0.5))
        HStack(spacing: 14) {
          kvCell(label: "ASLEEP", value: "\(asleepSamples)/\(totalSamples)")
          kvCell(label: "AWAKE", value: "\(awakeSamples)/\(totalSamples)")
          kvCell(label: "MID", value: "\(unknownSamples)/\(totalSamples)")
          Spacer(minLength: 0)
        }
        Text("\(Int(round(100 * Double(asleepSamples) / Double(max(1, totalSamples)))))% of the session the heuristic correctly said you were asleep. \(unknownSamples > 0 ? "\(unknownSamples) samples landed in the hysteresis band (between resting+5 and resting+12)." : "")")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.45))
          .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var audioStatusText: String {
    switch audioRecorder.state {
    case .idle: return "Idle — listens whenever a sleep session is active."
    case .armed: return "Listening · baseline \(Int(audioRecorder.rollingBaselineDB)) dB"
    case .recordingEvent: return "Recording event · peak \(Int(audioRecorder.maxAmbientDB)) dB"
    case .error(let msg): return "Error: \(msg)"
    }
  }

  private var audioStatusColor: Color {
    switch audioRecorder.state {
    case .idle: .white.opacity(0.5)
    case .armed: Self.greenAccent
    case .recordingEvent: Self.yellowAccent
    case .error: Self.redAccent
    }
  }

  // MARK: - HRV during sleep

  private var hrvCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("HRV DURING SLEEP")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        if let night = hrvStore.lastNight {
          HStack(spacing: 14) {
            kvCell(label: "MEDIAN", value: String(format: "%.0f ms", night.medianRMSSD))
            kvCell(label: "MEAN", value: String(format: "%.0f ms", night.meanRMSSD))
            kvCell(label: "WINDOWS", value: "\(night.windowCount)")
            kvCell(label: "BEATS", value: "\(night.totalBeats)")
            Spacer(minLength: 0)
          }
          if hrvStore.recentNights.count >= 3 {
            Chart {
              ForEach(hrvStore.recentNights) { night in
                LineMark(
                  x: .value("date", night.dateKey),
                  y: .value("RMSSD", night.medianRMSSD)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Self.hrvAccent)
                PointMark(
                  x: .value("date", night.dateKey),
                  y: .value("RMSSD", night.medianRMSSD)
                )
                .foregroundStyle(Self.hrvAccent)
                .symbolSize(15)
              }
            }
            .chartXAxis(.hidden)
            .frame(height: 60)
          }
        } else {
          Text("Need detected sleep window + RR intervals. Wear the strap to bed.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
      }
    }
  }

  // MARK: - Performance trend

  private var trendChart: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        Text("14-DAY PERFORMANCE")
          .font(.system(size: 10, weight: .heavy, design: .rounded))
          .tracking(2)
          .foregroundStyle(.white.opacity(0.55))
        let series = trendSeries
        if series.count >= 3 {
          Chart {
            ForEach(series, id: \.label) { p in
              BarMark(
                x: .value("date", p.label),
                y: .value("perf", p.value)
              )
              .foregroundStyle(perfColor(p.value))
              .cornerRadius(2)
            }
            RuleMark(y: .value("target", 85))
              .foregroundStyle(.white.opacity(0.25))
              .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
          }
          .frame(height: 100)
          .chartYAxis {
            AxisMarks(values: [0, 50, 85, 100]) { _ in
              AxisGridLine().foregroundStyle(.white.opacity(0.04))
              AxisValueLabel().foregroundStyle(.white.opacity(0.4))
            }
          }
        } else {
          Text("Need 3+ days of recovery history.")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.45))
        }
      }
    }
  }

  private var trendSeries: [TrendPoint] {
    // SQLite-backed: pull recent imported daily summaries.
    let labelFormatter = DateFormatter()
    labelFormatter.dateFormat = "d"
    let parser = DateFormatter()
    parser.dateFormat = "yyyy-MM-dd"
    parser.timeZone = TimeZone.current
    let entries = dailyStore.byDate.values
      .compactMap { day -> (Date, Double)? in
        guard let date = parser.date(from: day.dateKey),
              let perf = day.sleepPerformancePct ?? day.recoveryScore else { return nil }
        return (date, perf)
      }
      .sorted { $0.0 < $1.0 }
      .suffix(14)
    return entries.map { TrendPoint(label: labelFormatter.string(from: $0.0), value: $0.1) }
  }

  private struct TrendPoint {
    let label: String
    let value: Double
  }

  private func perfColor(_ value: Double) -> Color {
    if value >= 85 { return Self.greenAccent }
    if value >= 70 { return Self.yellowAccent }
    return Self.redAccent
  }

  // MARK: - Helpers

  private func kvCell(label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label)
        .font(.system(size: 9, weight: .heavy, design: .rounded))
        .tracking(1.5)
        .foregroundStyle(.white.opacity(0.5))
      Text(value)
        .font(.system(size: 13, weight: .heavy, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white)
    }
  }

  private func cardSurface<C: View>(@ViewBuilder _ content: () -> C) -> some View {
    content()
      .padding(14)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(
        RoundedRectangle(cornerRadius: 16, style: .continuous)
          .fill(Color.white.opacity(0.04))
      )
  }

  private static func formatMillis(_ millis: Int?) -> String {
    guard let millis else { return "--" }
    let total = millis / 1000
    let h = total / 3600
    let m = (total % 3600) / 60
    return "\(h)h\(String(format: "%02d", m))m"
  }

  private static func clockLabel(_ date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    return f.string(from: date)
  }

  private static func durationLabel(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    return "\(h)h\(String(format: "%02d", m))m"
  }

  private static let deep = Color(red: 0.55, green: 0.35, blue: 1.0)
  private static let rem = Color(red: 0.55, green: 0.85, blue: 1.0)
  private static let light = Color(red: 0.30, green: 0.85, blue: 0.66)
  private static let awake = Color.white.opacity(0.35)
  private static let greenAccent = Color(red: 0.18, green: 0.88, blue: 0.66)
  private static let yellowAccent = Color(red: 1.0, green: 0.88, blue: 0.40)
  private static let redAccent = Color(red: 1.0, green: 0.37, blue: 0.42)
  private static let hrvAccent = Color(red: 0.55, green: 0.85, blue: 1.0)
}

/// Strongly-typed view of the bridge response from `sleep.compute_reading`
/// and `sleep.get_reading`. Only the fields the SleepDetailView card
/// actually renders are pulled out — extending it is cheap if the UI
/// grows. Returns nil when the bridge returns null (no cached row) or
/// when required fields are missing.
struct SleepReadingSnapshot: Equatable {
  let sleepScore: Double
  let durationScore: Double
  let efficiencyScore: Double
  let depthScore: Double
  let hrvScore: Double
  let restfulnessScore: Double
  let timeInBedMinutes: Int
  let totalSleepMinutes: Int
  let deepMinutes: Int
  let lightMinutes: Int
  let awakeMinutes: Int
  let efficiency: Double
  let onsetLatencyMinutes: Int?
  let wakeAfterSleepOnsetMinutes: Int
  let hrMeanBpm: Double?
  let hrvMeanRmssdMs: Double
  let recovery: RecoveryReadingSnapshot?

  static func from(bridgeResponse dict: [String: Any]) -> SleepReadingSnapshot? {
    // sleep.get_reading returns serde_json(None) = NSNull when there's
    // no row; that arrives as an empty dict via the JSON-RPC bridge,
    // OR with explicit `"is_null": true`. Either way, treat absence of
    // sleep_score as "no reading".
    guard let score = Self.double(dict["sleep_score"]) else { return nil }
    let recovery = (dict["recovery_reading"] as? [String: Any])
      .flatMap(RecoveryReadingSnapshot.from(bridgeResponse:))
    return SleepReadingSnapshot(
      sleepScore: score,
      durationScore: Self.double(dict["duration_score"]) ?? 0,
      efficiencyScore: Self.double(dict["efficiency_score"]) ?? 0,
      depthScore: Self.double(dict["depth_score"]) ?? 0,
      hrvScore: Self.double(dict["hrv_score"]) ?? 0,
      restfulnessScore: Self.double(dict["restfulness_score"]) ?? 0,
      timeInBedMinutes: Self.int(dict["time_in_bed_minutes"]) ?? 0,
      totalSleepMinutes: Self.int(dict["total_sleep_minutes"]) ?? 0,
      deepMinutes: Self.int(dict["deep_minutes"]) ?? 0,
      lightMinutes: Self.int(dict["light_minutes"]) ?? 0,
      awakeMinutes: Self.int(dict["awake_minutes"]) ?? 0,
      efficiency: Self.double(dict["efficiency"]) ?? 0,
      onsetLatencyMinutes: Self.int(dict["onset_latency_minutes"]),
      wakeAfterSleepOnsetMinutes: Self.int(dict["wake_after_sleep_onset_minutes"]) ?? 0,
      hrMeanBpm: Self.double(dict["hr_mean_bpm"]),
      hrvMeanRmssdMs: Self.double(dict["hrv_mean_rmssd_ms"]) ?? 0,
      recovery: recovery
    )
  }

  fileprivate static func double(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    if let i = v as? Int { return Double(i) }
    return nil
  }
  fileprivate static func int(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let n = v as? NSNumber { return n.intValue }
    if let d = v as? Double { return Int(d) }
    return nil
  }
}

/// Strongly-typed view of the `recovery_reading` block nested in the
/// sleep bridge response. The Rust `sleep.compute_reading` chains a
/// recovery compute so a single bridge call returns both. Nil here means
/// recovery isn't computable yet (missing HRV samples, no baseline).
struct RecoveryReadingSnapshot: Equatable {
  let recoveryScore: Double
  let hrvScore: Double
  let rhrScore: Double
  let sleepScore: Double
  let respiratoryScore: Double
  let temperatureScore: Double
  let priorStrainScore: Double
  let hrvRmssdMs: Double
  let hrvBaselineRmssdMs: Double
  let restingHrBpm: Double
  let restingHrBaselineBpm: Double
  let priorStrain: Double
  let baselineNightsUsed: Int
  let qualityFlags: [String]

  static func from(bridgeResponse dict: [String: Any]) -> RecoveryReadingSnapshot? {
    guard let score = SleepReadingSnapshot.double(dict["recovery_score"]) else { return nil }
    return RecoveryReadingSnapshot(
      recoveryScore: score,
      hrvScore: SleepReadingSnapshot.double(dict["hrv_score"]) ?? 0,
      rhrScore: SleepReadingSnapshot.double(dict["rhr_score"]) ?? 0,
      sleepScore: SleepReadingSnapshot.double(dict["sleep_score"]) ?? 0,
      respiratoryScore: SleepReadingSnapshot.double(dict["respiratory_score"]) ?? 0,
      temperatureScore: SleepReadingSnapshot.double(dict["temperature_score"]) ?? 0,
      priorStrainScore: SleepReadingSnapshot.double(dict["prior_strain_score"]) ?? 0,
      hrvRmssdMs: SleepReadingSnapshot.double(dict["hrv_rmssd_ms"]) ?? 0,
      hrvBaselineRmssdMs: SleepReadingSnapshot.double(dict["hrv_baseline_rmssd_ms"]) ?? 0,
      restingHrBpm: SleepReadingSnapshot.double(dict["resting_hr_bpm"]) ?? 0,
      restingHrBaselineBpm: SleepReadingSnapshot.double(dict["resting_hr_baseline_bpm"]) ?? 0,
      priorStrain: SleepReadingSnapshot.double(dict["prior_strain_0_to_21"]) ?? 0,
      baselineNightsUsed: SleepReadingSnapshot.int(dict["baseline_nights_used"]) ?? 0,
      qualityFlags: (dict["quality_flags"] as? [String]) ?? []
    )
  }
}
