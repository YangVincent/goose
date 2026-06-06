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
  /// `refreshFromLocal` is throttled — re-loading 365 days of rows on
  /// every WhoopHomeView appear is expensive and the data only grows
  /// once per session. The store only re-fetches if `byDate` is empty
  /// or the last refresh is older than this interval.
  private var lastRefreshAt: Date?
  private static let minRefreshInterval: TimeInterval = 60
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
    if !byDate.isEmpty,
       let last = lastRefreshAt,
       Date().timeIntervalSince(last) < Self.minRefreshInterval {
      return
    }
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
      // Overlay our four typed reading tables on top of
      // imported_daily_summary via the unified daily_readings bridge.
      // For any date_key where we have a locally-computed value
      // (Goose-initiated session, finalized strain, etc.) that value
      // takes precedence — that's what surfaces recovery dots, today's
      // strain, and any local sleep numbers on past-day views without
      // each UI surface needing per-table queries.
      do {
        let response = try await Task.detached(priority: .userInitiated) { [bridge] in
          try bridge.request(method: "daily_readings.list_by_date_range", args: [
            "database_path": databasePath,
            "start_date_key": start,
            "end_date_key": end,
          ])
        }.value
        let rows = response["rows"] as? [[String: Any]] ?? []
        for row in rows {
          guard let dateKey = row["date_key"] as? String else { continue }
          let existing = byKey[dateKey]
          byKey[dateKey] = Self.merge(existing: existing, dateKey: dateKey, typed: row)
        }
      } catch {
        // Daily-readings overlay failure isn't fatal; the imported
        // summaries are still valid.
      }
      self.byDate = byKey
      self.importedCount = byKey.count
      self.lastRefreshAt = Date()
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

  private static func doubleValue(_ v: Any?) -> Double? {
    if let d = v as? Double { return d }
    if let n = v as? NSNumber { return n.doubleValue }
    if let i = v as? Int { return Double(i) }
    return nil
  }

  /// Build a DailySummary by overlaying our typed-table values on top of
  /// the WHOOP-imported baseline. Field-by-field: prefer the typed-table
  /// value when present (`source == "goose.local"` rows are recompute
  /// outputs we trust), otherwise keep whatever WHOOP gave us.
  private static func merge(
    existing: DailySummary?,
    dateKey: String,
    typed: [String: Any]
  ) -> DailySummary {
    let sleepScore = doubleValue(typed["sleep_score"])
    let tibMin = intValue(typed["time_in_bed_minutes"])
    let asleepMin = intValue(typed["total_sleep_minutes"])
    let deepMin = intValue(typed["deep_minutes"])
    let lightMin = intValue(typed["light_minutes"])
    let awakeMin = intValue(typed["awake_minutes"])
    let remMin = intValue(typed["rem_minutes"])
    let cycleCount = intValue(typed["cycle_count"])
    let disturbanceCount = intValue(typed["disturbance_count"])
    let sleepNeedMs = intValue(typed["sleep_need_ms"])
    let efficiencyFraction = doubleValue(typed["efficiency"])
    let recoveryScore = doubleValue(typed["recovery_score"])
    let hrvMs = doubleValue(typed["hrv_rmssd_ms"])
    let rhrBpm = doubleValue(typed["resting_hr_bpm"])
    let strainScore = doubleValue(typed["strain_score"])
    let strainKj = doubleValue(typed["strain_kilojoules"])
    let spo2 = doubleValue(typed["spo2_pct"])
    let skinTemp = doubleValue(typed["skin_temp_c"])

    return DailySummary(
      dateKey: dateKey,
      recoveryScore: recoveryScore ?? existing?.recoveryScore,
      hrvRmssdMs: hrvMs ?? existing?.hrvRmssdMs,
      restingHrBpm: rhrBpm ?? existing?.restingHrBpm,
      spo2Pct: spo2 ?? existing?.spo2Pct,
      skinTempC: skinTemp ?? existing?.skinTempC,
      sleepPerformancePct: sleepScore ?? existing?.sleepPerformancePct,
      sleepEfficiencyPct: efficiencyFraction.map { $0 * 100 } ?? existing?.sleepEfficiencyPct,
      sleepInBedMs: tibMin.map { $0 * 60_000 } ?? existing?.sleepInBedMs,
      sleepAwakeMs: awakeMin.map { $0 * 60_000 } ?? existing?.sleepAwakeMs,
      sleepLightMs: lightMin.map { $0 * 60_000 } ?? existing?.sleepLightMs,
      sleepDeepMs: deepMin.map { $0 * 60_000 } ?? existing?.sleepDeepMs,
      sleepRemMs: remMin.map { $0 * 60_000 } ?? existing?.sleepRemMs,
      sleepCycleCount: cycleCount ?? existing?.sleepCycleCount,
      sleepDisturbanceCount: disturbanceCount ?? existing?.sleepDisturbanceCount,
      sleepNeedBaselineMs: sleepNeedMs ?? existing?.sleepNeedBaselineMs,
      sleepNeedFromDebtMs: existing?.sleepNeedFromDebtMs,
      sleepNeedFromStrainMs: existing?.sleepNeedFromStrainMs,
      sleepNeedFromNapMs: existing?.sleepNeedFromNapMs,
      // Strain/kJ from the typed table can be 0.0 if a goose.local row
      // was finalized for a day with no HR samples (e.g. before the
      // strap was capturing). Don't let a zero override WHOOP's real
      // imported value — prefer non-zero, fall back to existing.
      strainScore: ((strainScore ?? 0) > 0 ? strainScore : nil) ?? existing?.strainScore,
      strainKilojoules: ((strainKj ?? 0) > 0 ? strainKj : nil) ?? existing?.strainKilojoules
    )
  }

}
