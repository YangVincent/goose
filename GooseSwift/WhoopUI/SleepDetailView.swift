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

  var body: some View {
    GeometryReader { geo in
      ZStack {
        WhoopHomeView.detailBackground.ignoresSafeArea()
        ScrollView(.vertical, showsIndicators: true) {
          VStack(alignment: .leading, spacing: 20) {
            hero
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
    }
    .onChange(of: selectedDay.currentDate) { _, _ in
      refreshForCurrentDate()
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

  // MARK: - Sleep audio (off by default, ties to sleep session)

  private var sleepAudioCard: some View {
    cardSurface {
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text("SLEEP AUDIO")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(2)
            .foregroundStyle(.white.opacity(0.55))
          Spacer()
          Toggle("", isOn: $audioRecorder.isEnabled)
            .labelsHidden()
            .tint(Self.hrvAccent)
            .onChange(of: audioRecorder.isEnabled) { _, newValue in
              // Only arm immediately if a sleep session is already active.
              // Otherwise audio waits for "Start Sleep".
              if newValue, sleepSession.active != nil {
                audioRecorder.arm()
              } else if !newValue {
                audioRecorder.disarm()
              }
            }
        }
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
        Text("Tap **Start Sleep** on the home page to begin a session. Audio records only while a session is active and only events (>+12dB above baseline) are saved. Clips auto-prune after \(audioRecorder.retentionDays) days.")
          .font(.system(size: 9, weight: .semibold, design: .rounded))
          .foregroundStyle(.white.opacity(0.4))
          .fixedSize(horizontal: false, vertical: true)
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
    case .idle: return audioRecorder.isEnabled ? "Idle — armed when you fall asleep." : "Disabled."
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
