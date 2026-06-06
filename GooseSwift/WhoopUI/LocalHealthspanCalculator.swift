import Foundation

/// Locally-computed Healthspan inputs — pulled from CompletedWorkoutStore
/// (Rust SQLite-backed) + HeartRateSeriesStore. Replaces WHOOP cloud
/// aggregates where we have ground truth on the phone.
///
/// WHOOP's cloud aggregates report 0 for HR zone time and strength
/// minutes because their classifier doesn't see our workouts. The phone
/// has the actual zoned-HR data per workout, so we use that.
@MainActor
enum LocalHealthspanCalculator {
  struct Healthspan {
    let hr_zones_1_3_weekly_hours: Double
    let hr_zones_4_5_weekly_hours: Double
    let strength_weekly_minutes: Double
    let rhr_30d: Double?
    let sleep_hours_30d: Double?
    let sleep_consistency_pct_30d: Double?

    let dailyHrZones13: [DailyPoint]
    let dailyHrZones45: [DailyPoint]
    let dailyStrengthMinutes: [DailyPoint]
    let dailyRHR: [DailyPoint]
    let dailySleepHours: [DailyPoint]
    let dailySleepConsistency: [DailyPoint]
  }

  struct DailyPoint {
    let date: Date
    let value: Double
  }

  /// Compute the local healthspan snapshot. Cheap — runs over the
  /// already-loaded CompletedWorkoutStore in-memory list.
  ///
  /// When `zoneMinutesByDay` is provided (keyed by `yyyy-MM-dd`, mapping
  /// zone ID → minutes), HR zone time uses those totals. Those values
  /// come from `daily_strain_readings.zone_minutes` and reflect ALL the
  /// day's HR samples (background + workouts), not just the workout
  /// windows. Days not present in the dict fall back to the workout-only
  /// sum so older days without persisted strain readings still render.
  static func compute(
    now: Date = Date(),
    zoneMinutesByDay: [String: [Int: Double]] = [:]
  ) -> Healthspan {
    let calendar = Calendar.current
    let workouts = CompletedWorkoutStore.shared.workouts
    let isoFmt = DateFormatter()
    isoFmt.dateFormat = "yyyy-MM-dd"
    isoFmt.timeZone = TimeZone.current

    // Weekly windows.
    let weekStart = now.addingTimeInterval(-7 * 86_400)
    let last7d = workouts.filter { $0.startedAt >= weekStart && $0.startedAt <= now }

    // HR zone totals over the last 7 days. Prefer per-day strain
    // overrides; fall back to workout-only zone seconds for days without
    // a stored strain reading.
    var z13Minutes: Double = 0
    var z45Minutes: Double = 0
    let dayStartNow = calendar.startOfDay(for: now)
    for offset in 0..<7 {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: dayStartNow) else { continue }
      let dayKey = isoFmt.string(from: day)
      if let zones = zoneMinutesByDay[dayKey] {
        z13Minutes += (zones[1] ?? 0) + (zones[2] ?? 0) + (zones[3] ?? 0)
        z45Minutes += (zones[4] ?? 0) + (zones[5] ?? 0)
      } else {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
        for w in workouts where w.startedAt >= day && w.startedAt < dayEnd {
          z13Minutes += (w.zoneSeconds(1) + w.zoneSeconds(2) + w.zoneSeconds(3)) / 60.0
          z45Minutes += (w.zoneSeconds(4) + w.zoneSeconds(5)) / 60.0
        }
      }
    }
    let z13 = z13Minutes / 60.0
    let z45 = z45Minutes / 60.0

    let strengthMin = last7d
      .filter { isStrength($0.activityRaw) }
      .reduce(0.0) { $0 + $1.elapsedSeconds } / 60.0

    let rhr = HeartRateSeriesStore.shared.restingEstimate()?.bpm

    // Daily breakdowns for the trend charts (30 days).
    let dailyWindowStart = now.addingTimeInterval(-30 * 86_400)
    let last30d = workouts.filter { $0.startedAt >= dailyWindowStart && $0.startedAt <= now }

    // Per-day HR zone series — same override / fallback rule.
    var dailyZ13: [DailyPoint] = []
    var dailyZ45: [DailyPoint] = []
    for offset in 0..<30 {
      guard let day = calendar.date(byAdding: .day, value: -offset, to: dayStartNow) else { continue }
      let dayKey = isoFmt.string(from: day)
      let z13Min: Double
      let z45Min: Double
      if let zones = zoneMinutesByDay[dayKey] {
        z13Min = (zones[1] ?? 0) + (zones[2] ?? 0) + (zones[3] ?? 0)
        z45Min = (zones[4] ?? 0) + (zones[5] ?? 0)
      } else {
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) else { continue }
        var z13Sec: Double = 0
        var z45Sec: Double = 0
        for w in workouts where w.startedAt >= day && w.startedAt < dayEnd {
          z13Sec += w.zoneSeconds(1) + w.zoneSeconds(2) + w.zoneSeconds(3)
          z45Sec += w.zoneSeconds(4) + w.zoneSeconds(5)
        }
        z13Min = z13Sec / 60.0
        z45Min = z45Sec / 60.0
      }
      if z13Min > 0 { dailyZ13.append(DailyPoint(date: day, value: z13Min / 60.0)) }
      if z45Min > 0 { dailyZ45.append(DailyPoint(date: day, value: z45Min / 60.0)) }
    }
    dailyZ13.sort { $0.date < $1.date }
    dailyZ45.sort { $0.date < $1.date }

    let dailyStrength = bucketByDay(last30d, calendar: calendar) { w in
      isStrength(w.activityRaw) ? w.elapsedSeconds / 60.0 : 0
    }

    let dailyRHR = dailyRestingHRSeries(daysBack: 30, now: now)

    // Sleep history derived per-night via SleepWindowDetector.
    let nights = nightlySleepWindows(daysBack: 30, now: now)
    let durationsHours = nights.map { $0.durationHours }
    let avgHours: Double? = durationsHours.isEmpty
      ? nil
      : durationsHours.reduce(0, +) / Double(durationsHours.count)
    let consistencyPct = sleepConsistencyPercent(nights: nights)

    let dailySleepHours = nights.map { DailyPoint(date: $0.wake, value: $0.durationHours) }
    let dailyConsistency: [DailyPoint] = nights.map {
      DailyPoint(date: $0.wake, value: $0.consistencyApprox * 100)
    }

    return Healthspan(
      hr_zones_1_3_weekly_hours: z13,
      hr_zones_4_5_weekly_hours: z45,
      strength_weekly_minutes: strengthMin,
      rhr_30d: rhr,
      sleep_hours_30d: avgHours,
      sleep_consistency_pct_30d: consistencyPct,
      dailyHrZones13: dailyZ13,
      dailyHrZones45: dailyZ45,
      dailyStrengthMinutes: dailyStrength,
      dailyRHR: dailyRHR,
      dailySleepHours: dailySleepHours,
      dailySleepConsistency: dailyConsistency
    )
  }

  // MARK: - Sleep history (per-night windows over the past N days)

  private struct NightlyWindow {
    let onset: Date
    let wake: Date
    let durationHours: Double
    /// Per-night "consistency" approximation: confidence × clamp of bedtime
    /// drift vs cohort mean. Cheap stand-in until we persist real nightly
    /// consistency.
    let consistencyApprox: Double
  }

  /// Per-night windows, used by the Age estimate + trend charts.
  /// First pulls every PastSession we have (user-logged sleep, ground
  /// truth) inside the 30-day window. Then for each calendar day in
  /// range without a logged session, falls back to
  /// SleepWindowDetector.detect against that day's HR. This drops the
  /// 30 × HR-fetch+detect cost dramatically for days the user logged,
  /// and means the Age estimate doesn't go `--` just because HR-only
  /// detection failed on a sparse-data day.
  private static func nightlySleepWindows(daysBack: Int, now: Date) -> [NightlyWindow] {
    let calendar = Calendar.current
    let store = HeartRateSeriesStore.shared
    let resting = store.restingEstimate()
    let cutoff = calendar.date(byAdding: .day, value: -daysBack, to: now) ?? now
    var seenDayKeys = Set<String>()
    var results: [NightlyWindow] = []
    let isoFmt = DateFormatter()
    isoFmt.dateFormat = "yyyy-MM-dd"
    isoFmt.timeZone = TimeZone.current

    for session in SleepSessionStore.shared.pastSessions
      where session.startedAt >= cutoff && session.endedAt <= now {
      let dayKey = isoFmt.string(from: session.endedAt)
      guard !seenDayKeys.contains(dayKey) else { continue }
      seenDayKeys.insert(dayKey)
      results.append(NightlyWindow(
        onset: session.startedAt,
        wake: session.endedAt,
        durationHours: session.durationSeconds / 3600,
        consistencyApprox: 1.0
      ))
    }

    for offset in 0..<daysBack {
      guard let dayStart = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)),
            let wakeReference = calendar.date(byAdding: .hour, value: 9, to: dayStart) else { continue }
      let dayKey = isoFmt.string(from: wakeReference)
      if seenDayKeys.contains(dayKey) { continue }
      let samples = store.samples(from: wakeReference.addingTimeInterval(-18 * 3600), to: wakeReference)
      guard let window = SleepWindowDetector.detect(
        samples: samples,
        restingEstimate: resting,
        now: wakeReference
      ) else { continue }
      seenDayKeys.insert(dayKey)
      results.append(NightlyWindow(
        onset: window.onset,
        wake: window.wake,
        durationHours: window.durationSeconds / 3600,
        consistencyApprox: window.confidence
      ))
    }
    return results.sorted { $0.wake < $1.wake }
  }

  /// Compute an overall consistency %: 100 - σ(bedtime minutes) capped to
  /// 0..100. Higher = bedtimes cluster tighter.
  private static func sleepConsistencyPercent(nights: [NightlyWindow]) -> Double? {
    guard nights.count >= 3 else { return nil }
    let calendar = Calendar.current
    let onsetMinutes: [Double] = nights.map { night in
      let comp = calendar.dateComponents([.hour, .minute], from: night.onset)
      let h = comp.hour ?? 0
      let m = comp.minute ?? 0
      // Wrap so 22:00 and 01:00 are close, not far.
      let raw = Double(h * 60 + m)
      return raw >= 12 * 60 ? raw - 24 * 60 : raw
    }
    let mean = onsetMinutes.reduce(0, +) / Double(onsetMinutes.count)
    let variance = onsetMinutes.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(onsetMinutes.count - 1)
    let stdMinutes = sqrt(variance)
    let pct = max(0, min(100, 100 - stdMinutes))
    return pct
  }

  // MARK: - Helpers

  private static func isStrength(_ raw: String) -> Bool {
    let t = raw.lowercased()
    return t.contains("weight") || t.contains("strength") || t == "lifting" || t.contains("resistance")
  }

  /// Bucket workouts by day (calendar start-of-day) and sum a per-workout
  /// metric. Days with no workouts get value=0. Sorted ascending by date.
  private static func bucketByDay(
    _ workouts: [CompletedWorkout],
    calendar: Calendar,
    metric: (CompletedWorkout) -> Double
  ) -> [DailyPoint] {
    var byDay: [Date: Double] = [:]
    for w in workouts {
      let day = calendar.startOfDay(for: w.startedAt)
      byDay[day, default: 0] += metric(w)
    }
    return byDay
      .map { DailyPoint(date: $0.key, value: $0.value) }
      .sorted { $0.date < $1.date }
  }

  /// Build a per-day RHR series from hr_samples — take the bottom decile
  /// of each day's HR samples as that day's resting estimate. Quick
  /// approximation; refines later when we persist nightly RHR per day.
  private static func dailyRestingHRSeries(daysBack: Int, now: Date) -> [DailyPoint] {
    let calendar = Calendar.current
    var points: [DailyPoint] = []
    let store = HeartRateSeriesStore.shared
    for offset in 0..<daysBack {
      let dayStart = calendar.startOfDay(for: now.addingTimeInterval(-Double(offset) * 86_400))
      let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
      let samples = store.samples(from: dayStart, to: dayEnd)
      guard samples.count >= 60 else { continue }  // need at least 60 samples
      let sorted = samples.map(\.bpm).sorted()
      let decileIdx = max(0, sorted.count / 10)
      let estimate = Double(sorted[decileIdx])
      points.append(DailyPoint(date: dayStart, value: estimate))
    }
    return points.sorted { $0.date < $1.date }
  }
}
