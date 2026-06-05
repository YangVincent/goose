import Foundation

/// One-time backfill of per-day WHOOP summaries (recovery + sleep +
/// strain) into the local `imported_daily_summary` SQLite table. After
/// backfill, every view reads from SQLite via this store — never from
/// the cloud at runtime. Mirrors the architecture of
/// `WhoopImportedSleepStore` but for the full daily summary.
///
/// Source endpoints (called only during backfill):
///   - `GET /api/whoop?days=N` → recovery history (HRV, RHR, recovery
///     score, SpO2, skin temp per day)
///   - `GET /api/whoop/day?date=YYYY-MM-DD` → full overview (sleep
///     stages, strain, recovery) for one day
///
/// Read path at runtime: `swift_caches.list_daily_summaries` → in-memory
/// dictionary keyed by `yyyy-MM-dd`.
@MainActor
final class WhoopImportedDailyStore: ObservableObject {
  static let shared = WhoopImportedDailyStore()

  struct DailySummary: Equatable {
    let dateKey: String
    let recoveryScore: Double?
    let hrvRmssdMs: Double?
    let restingHrBpm: Double?
    let spo2Pct: Double?
    let skinTempC: Double?
    let sleepPerformancePct: Double?
    let sleepEfficiencyPct: Double?
    let sleepInBedMs: Int?
    let sleepAwakeMs: Int?
    let sleepLightMs: Int?
    let sleepDeepMs: Int?
    let sleepRemMs: Int?
    let sleepCycleCount: Int?
    let sleepDisturbanceCount: Int?
    let sleepNeedBaselineMs: Int?
    let sleepNeedFromDebtMs: Int?
    let sleepNeedFromStrainMs: Int?
    let sleepNeedFromNapMs: Int?
    let strainScore: Double?
    let strainKilojoules: Double?
  }

  @Published private(set) var byDate: [String: DailySummary] = [:]
  @Published private(set) var importedCount: Int = 0
  @Published private(set) var lastImportError: String?

  private let bridge = GooseRustBridge()

  /// Read from local SQLite. No cloud calls — historical data is seeded
  /// by an external backfill script (see goose/scripts/backfill_aeonneo.py).
  func bootstrapIfNeeded(databasePath: String) async {
    await refreshFromLocal(databasePath: databasePath)
  }

  func summary(for date: Date) -> DailySummary? {
    byDate[Self.dateKey(for: date)]
  }

  /// View-layer accessor: returns the day in the legacy `WhoopOverview.WhoopDay`
  /// shape so existing view code reads the same fields. Sleep stages aren't
  /// populated from `imported_daily_summary` (they live in
  /// `external_sleep_sessions/stages`), so views that need stage timelines
  /// pull from `WhoopImportedSleepStore` directly.
  func dayOverview(for date: Date) -> WhoopOverview.WhoopDay? {
    guard let s = summary(for: date) else { return nil }
    let recovery = WhoopOverview.Recovery(
      start: nil,
      recovery_score: s.recoveryScore,
      resting_heart_rate: s.restingHrBpm,
      hrv_rmssd_milli: s.hrvRmssdMs,
      spo2_percentage: s.spo2Pct,
      skin_temp_celsius: s.skinTempC
    )
    let stageSummary = WhoopOverview.StageSummary(
      total_in_bed_time_milli: s.sleepInBedMs,
      total_awake_time_milli: s.sleepAwakeMs,
      total_light_sleep_time_milli: s.sleepLightMs,
      total_slow_wave_sleep_time_milli: s.sleepDeepMs,
      total_rem_sleep_time_milli: s.sleepRemMs,
      sleep_cycle_count: s.sleepCycleCount,
      disturbance_count: s.sleepDisturbanceCount
    )
    let sleepNeeded = WhoopOverview.SleepNeeded(
      baseline_milli: s.sleepNeedBaselineMs,
      need_from_sleep_debt_milli: s.sleepNeedFromDebtMs,
      need_from_recent_strain_milli: s.sleepNeedFromStrainMs,
      need_from_recent_nap_milli: s.sleepNeedFromNapMs
    )
    let sleep = WhoopOverview.Sleep(
      start: nil,
      end: nil,
      performance: s.sleepPerformancePct,
      efficiency: s.sleepEfficiencyPct,
      stage_summary: stageSummary,
      sleep_needed: sleepNeeded
    )
    let strain = WhoopOverview.Strain(
      strain: s.strainScore,
      kilojoule: s.strainKilojoules
    )
    return WhoopOverview.WhoopDay(recovery: recovery, sleep: sleep, strain: strain)
  }

  /// Most-recent-first list of recovery rows, for the trailing N days.
  /// Replaces `WhoopAPIClient.recoveryHistory`.
  func recoveryHistory(limit: Int = 90) -> [WhoopOverview.Recovery] {
    let keys = byDate.keys.sorted(by: >)  // newest first
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    var out: [WhoopOverview.Recovery] = []
    for k in keys.prefix(limit) {
      guard let s = byDate[k] else { continue }
      let startISO: String?
      if let date = f.date(from: k) {
        let iso = ISO8601DateFormatter()
        startISO = iso.string(from: date)
      } else {
        startISO = nil
      }
      out.append(WhoopOverview.Recovery(
        start: startISO,
        recovery_score: s.recoveryScore,
        resting_heart_rate: s.restingHrBpm,
        hrv_rmssd_milli: s.hrvRmssdMs,
        spo2_percentage: s.spo2Pct,
        skin_temp_celsius: s.skinTempC
      ))
    }
    return out
  }

  /// Recovery score for a given ISO yyyy-MM-dd. Replaces
  /// `WhoopAPIClient.recoveryScore(forISODate:)`.
  func recoveryScore(forISODate dateKey: String) -> Double? {
    byDate[dateKey]?.recoveryScore
  }

  /// Calendar dots for a month. Replaces `WhoopAPIClient.calendar`.
  func calendar(forMonth monthPrefix: String) -> WhoopCalendar {
    let dates = byDate.keys
      .filter { $0.hasPrefix(monthPrefix) }
      .sorted()
      .map { key in
        WhoopCalendar.DateEntry(date: key, recovery_score: byDate[key]?.recoveryScore)
      }
    return WhoopCalendar(month: monthPrefix, dates: dates, workout_dates: nil)
  }

  static func dateKey(for date: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f.string(from: date)
  }

  // MARK: - Local read

  func refreshFromLocal(databasePath: String) async {
    let calendar = Calendar.current
    let endDate = Date()
    // Read window: 365 days back. Local SQLite is cheap; pull everything
    // we might display in trends and charts. Backfilled by external script.
    let startDate = calendar.date(byAdding: .day, value: -365, to: endDate) ?? endDate
    let start = Self.dateKey(for: startDate)
    let end = Self.dateKey(for: endDate)
    do {
      let result = try await Task.detached(priority: .userInitiated) { [bridge] in
        try bridge.request(method: "swift_caches.list_daily_summaries", args: [
          "database_path": databasePath,
          "start_date_key": start,
          "end_date_key": end,
        ])
      }.value
      let days = result["days"] as? [[String: Any]] ?? []
      var byKey: [String: DailySummary] = [:]
      for row in days {
        if let parsed = Self.parseRow(row) {
          byKey[parsed.dateKey] = parsed
        }
      }
      // Overlay recovery_readings on top of imported_daily_summary. Any
      // date_key where we have a local-computed recovery score (Goose-
      // initiated sleep session) takes precedence — that's what surfaces
      // recovery dots on the date strip for days WHOOP never imported
      // (the local-only nights and "today" before WHOOP syncs).
      do {
        let response = try await Task.detached(priority: .userInitiated) { [bridge] in
          try bridge.request(method: "recovery.list_by_date_range", args: [
            "database_path": databasePath,
            "start_date_key": start,
            "end_date_key": end,
          ])
        }.value
        let rows = response["rows"] as? [[String: Any]] ?? []
        for row in rows {
          guard let dateKey = row["date_key"] as? String,
                let score = (row["recovery_score"] as? Double)
                  ?? (row["recovery_score"] as? NSNumber).map({ $0.doubleValue }) else {
            continue
          }
          let existing = byKey[dateKey]
          byKey[dateKey] = DailySummary(
            dateKey: dateKey,
            recoveryScore: score,
            hrvRmssdMs: existing?.hrvRmssdMs,
            restingHrBpm: existing?.restingHrBpm,
            spo2Pct: existing?.spo2Pct,
            skinTempC: existing?.skinTempC,
            sleepPerformancePct: existing?.sleepPerformancePct,
            sleepEfficiencyPct: existing?.sleepEfficiencyPct,
            sleepInBedMs: existing?.sleepInBedMs,
            sleepAwakeMs: existing?.sleepAwakeMs,
            sleepLightMs: existing?.sleepLightMs,
            sleepDeepMs: existing?.sleepDeepMs,
            sleepRemMs: existing?.sleepRemMs,
            sleepCycleCount: existing?.sleepCycleCount,
            sleepDisturbanceCount: existing?.sleepDisturbanceCount,
            sleepNeedBaselineMs: existing?.sleepNeedBaselineMs,
            sleepNeedFromDebtMs: existing?.sleepNeedFromDebtMs,
            sleepNeedFromStrainMs: existing?.sleepNeedFromStrainMs,
            sleepNeedFromNapMs: existing?.sleepNeedFromNapMs,
            strainScore: existing?.strainScore,
            strainKilojoules: existing?.strainKilojoules
          )
        }
      } catch {
        // Recovery overlay failure isn't fatal; the imported summaries
        // are still valid.
      }
      self.byDate = byKey
      self.importedCount = byKey.count
    } catch {
      self.lastImportError = "list failed: \(error)"
    }
  }

  // MARK: - Parsing

  private static func parseRow(_ row: [String: Any]) -> DailySummary? {
    guard let dateKey = row["date_key"] as? String else { return nil }
    return DailySummary(
      dateKey: dateKey,
      recoveryScore: row["recovery_score"] as? Double,
      hrvRmssdMs: row["hrv_rmssd_ms"] as? Double,
      restingHrBpm: row["resting_hr_bpm"] as? Double,
      spo2Pct: row["spo2_pct"] as? Double,
      skinTempC: row["skin_temp_c"] as? Double,
      sleepPerformancePct: row["sleep_performance_pct"] as? Double,
      sleepEfficiencyPct: row["sleep_efficiency_pct"] as? Double,
      sleepInBedMs: intValue(row["sleep_in_bed_ms"]),
      sleepAwakeMs: intValue(row["sleep_awake_ms"]),
      sleepLightMs: intValue(row["sleep_light_ms"]),
      sleepDeepMs: intValue(row["sleep_deep_ms"]),
      sleepRemMs: intValue(row["sleep_rem_ms"]),
      sleepCycleCount: intValue(row["sleep_cycle_count"]),
      sleepDisturbanceCount: intValue(row["sleep_disturbance_count"]),
      sleepNeedBaselineMs: intValue(row["sleep_need_baseline_ms"]),
      sleepNeedFromDebtMs: intValue(row["sleep_need_from_debt_ms"]),
      sleepNeedFromStrainMs: intValue(row["sleep_need_from_strain_ms"]),
      sleepNeedFromNapMs: intValue(row["sleep_need_from_nap_ms"]),
      strainScore: row["strain_score"] as? Double,
      strainKilojoules: row["strain_kilojoules"] as? Double
    )
  }

  private static func intValue(_ v: Any?) -> Int? {
    if let i = v as? Int { return i }
    if let i64 = v as? Int64 { return Int(i64) }
    if let d = v as? Double { return Int(d) }
    return nil
  }

}
