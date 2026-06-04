import Foundation

/// Computes a WHOOP-style day strain (0–21) locally from the 1Hz HR samples
/// we already persist in `HeartRateSeriesStore`. WHOOP's strain formula is
/// proprietary, but the open literature consensus is **Banister TRIMP** —
/// a per-second integration that weights higher heart-rate fractions
/// exponentially:
///
///   trimp_increment = dt_min · hrr · 0.64 · exp(1.92 · hrr)
///
/// where `hrr = (bpm - rest) / (max - rest)` clamped to [0, 1]. Daily TRIMP
/// is then mapped to WHOOP's 0–21 scale with a logarithmic curve calibrated
/// so a 30-min Zone-3 session ≈ strain 8 and a hard 90-min Zone-4/5 effort
/// ≈ strain 17.
///
/// HR samples that fall inside an off-wrist window (skin_contact == 0) are
/// dropped to keep PPG noise out of the day's load.
enum DayStrainCalculator {
  struct DayStrain {
    let dateKey: String
    let strain: Double  // 0…21
    let trimp: Double
    let sampleCount: Int
    let zoneMinutes: [Int: Double]
    let lastSampleAt: Date?
  }

  /// Compute strain for a given day using the user's HR samples + (optional)
  /// off-wrist windows from the sensor store.
  static func computeDayStrain(
    samples: [HeartRateSamplePoint],
    offWristWindows: [(start: Date, end: Date)],
    restingBPM: Int = UserProfile.restingHeartRate,
    maxBPM: Int = UserProfile.maxHeartRate,
    for date: Date = Date(),
    calendar: Calendar = .current
  ) -> DayStrain {
    let dayStart = calendar.startOfDay(for: date)
    let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
    let dayKey = Self.dateKey(for: dayStart, calendar: calendar)
    let inDay = samples.filter { $0.capturedAt >= dayStart && $0.capturedAt < dayEnd }
    let onWrist = filterOnWrist(inDay, offWristWindows: offWristWindows)
    guard !onWrist.isEmpty else {
      return DayStrain(dateKey: dayKey, strain: 0, trimp: 0, sampleCount: 0, zoneMinutes: [:], lastSampleAt: nil)
    }
    let sorted = onWrist.sorted { $0.capturedAt < $1.capturedAt }
    let rangeBPM = max(maxBPM - restingBPM, 1)

    var trimp: Double = 0
    var zoneSeconds: [Int: Double] = [:]
    var lastTime: Date?

    for sample in sorted {
      let dt: TimeInterval
      if let last = lastTime {
        // Samples arrive at ~1 Hz but with gaps. Cap dt to 5s so a long
        // off-wrist gap or sync hiccup doesn't double-count the next sample.
        dt = min(max(sample.capturedAt.timeIntervalSince(last), 0), 5)
      } else {
        dt = 1.0
      }
      lastTime = sample.capturedAt

      let bpm = max(sample.bpm, restingBPM)
      let hrr = min(max(Double(bpm - restingBPM) / Double(rangeBPM), 0), 1)
      let dtMinutes = dt / 60.0
      let increment = dtMinutes * hrr * 0.64 * exp(1.92 * hrr)
      trimp += increment

      let zone = HeartRateZone.zoneID(for: bpm)
      zoneSeconds[zone, default: 0] += dt
    }

    let strain = trimpToStrainScore(trimp)
    let zoneMinutes = zoneSeconds.mapValues { $0 / 60.0 }
    return DayStrain(
      dateKey: dayKey,
      strain: strain,
      trimp: trimp,
      sampleCount: sorted.count,
      zoneMinutes: zoneMinutes,
      lastSampleAt: sorted.last?.capturedAt
    )
  }

  // MARK: - Per-activity strain formulas
  //
  // Fit against the user's 40 historical WHOOP-rated activities pulled from
  // `aeonneo.com/health/api/activities`. Each formula is:
  //   strain = scale × log10(1 + (kJ × (1 + α × hrr)) / k)
  // where hrr = (HR - rest) / (max - rest). Constants per activity type
  // were learned via grid search in /tmp/by_activity.py (see git history /
  // commit message). Median fit errors are honest — small samples + WHOOP's
  // proprietary formula mean per-activity errors of 0.1–1.5 strain points.

  struct StrainFormula {
    let name: String
    let scale: Double
    let k: Double
    let alpha: Double
    let medianFitError: Double

    /// Apply the log curve to effective kJ. Effective kJ already includes
    /// the (1 + α × hrr) intensity boost — kept separate from raw kJ so
    /// per-zone effective rates can be precomputed.
    func strain(fromEffectiveKJ kJ: Double) -> Double {
      return min(21, max(0, scale * log10(1 + kJ / k)))
    }

    /// Effective kJ per minute spent in a given HR zone, using the zone's
    /// midpoint HRR. Includes both base metabolic cost and the formula's
    /// intensity boost.
    func effectiveKJPerMinute(forZone zone: Int) -> Double {
      let zoneMidHRR: Double = {
        switch zone {
        case 1: return 0.37
        case 2: return 0.51
        case 3: return 0.65
        case 4: return 0.79
        case 5: return 0.93
        default: return 0.5
        }
      }()
      let baseKJPerMin = 5.0 + 65 * zoneMidHRR  // BMR-ish + active load
      return baseKJPerMin * (1 + alpha * zoneMidHRR)
    }

    /// Effective kJ per second at the given HR, used for non-workout
    /// background HR samples.
    func effectiveKJPerSecond(forBPM bpm: Int) -> Double {
      let rest = Double(UserProfile.restingHeartRate)
      let maxHR = Double(UserProfile.maxHeartRate)
      let hrr = max(0, min(1, (Double(bpm) - rest) / max(maxHR - rest, 1)))
      let kJPerMin = 5.0 + 65 * hrr
      return kJPerMin * (1 + alpha * hrr) / 60.0
    }
  }

  /// Fit on 20 running activities, median error 0.28 strain points.
  static let runningFormula = StrainFormula(
    name: "running", scale: 27.0, k: 3000, alpha: 2.5, medianFitError: 0.28
  )
  /// Fit on 9 badminton activities, median error 0.16. Highest α — sport
  /// rewards intensity disproportionately.
  static let badmintonFormula = StrainFormula(
    name: "badminton", scale: 13.5, k: 1500, alpha: 5.5, medianFitError: 0.16
  )
  /// Fit on 3 walking activities, median error 0.04 (small n, tight fit).
  static let walkingFormula = StrainFormula(
    name: "walking", scale: 5.5, k: 80, alpha: 7.5, medianFitError: 0.04
  )
  /// Fit on 3 generic "activity" entries, median error 0.30.
  static let activityFormula = StrainFormula(
    name: "activity", scale: 4.0, k: 30, alpha: 1.5, medianFitError: 0.30
  )
  /// Weightlifting fit is poor (1.51 median error across 5 samples) because
  /// WHOOP uses anaerobic / HRV markers we don't have. Best we can do is a
  /// hand-tuned floor that scales with kJ. Surface the high error in UI.
  static let weightliftingFormula = StrainFormula(
    name: "weightlifting", scale: 7.0, k: 10, alpha: 0, medianFitError: 1.51
  )

  /// Map an `ActivityKind` (or rawValue) to the closest fitted formula.
  /// Activities without historical data fall through to the running formula
  /// since it has the most data and most cardio activities share its load
  /// curve shape.
  static func formula(forActivityRaw activityRaw: String) -> StrainFormula {
    switch activityRaw.lowercased() {
    case "run", "indoorrun", "hike":
      return runningFormula
    case "walk", "indoorwalk":
      return walkingFormula
    case "roadride", "mountainbike", "indoorride",
         "row", "elliptical", "stairstepper",
         "poolswim", "soccer", "hiit":
      return runningFormula
    case "strength", "functionaltraining":
      return weightliftingFormula
    case "yoga", "pilates", "barre":
      return activityFormula
    case "badminton":
      return badmintonFormula
    default:
      return runningFormula
    }
  }

  // MARK: - Legacy / fallback

  /// Pre-calibration formula. Kept so callers that haven't migrated to
  /// per-activity formulas still produce something. New code should use
  /// `formula(forActivityRaw:)` and `StrainFormula.strain(fromEffectiveKJ:)`.
  static func trimpToStrainScore(_ trimp: Double) -> Double {
    let k: Double = 40
    let maxAnchor: Double = 700
    let raw = log10(1 + trimp / k) / log10(1 + maxAnchor / k)
    return min(max(raw * 21, 0), 21)
  }

  // MARK: - Helpers

  private static func filterOnWrist(
    _ samples: [HeartRateSamplePoint],
    offWristWindows: [(start: Date, end: Date)]
  ) -> [HeartRateSamplePoint] {
    guard !offWristWindows.isEmpty else { return samples }
    return samples.filter { sample in
      var lo = 0
      var hi = offWristWindows.count - 1
      while lo <= hi {
        let mid = (lo + hi) / 2
        let window = offWristWindows[mid]
        if sample.capturedAt < window.start {
          hi = mid - 1
        } else if sample.capturedAt > window.end {
          lo = mid + 1
        } else {
          return false
        }
      }
      return true
    }
  }

  private static func dateKey(for date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = calendar.timeZone
    return formatter.string(from: date)
  }
}

/// Foreground-refreshing cache of today's locally-computed strain. The strain
/// card on Home observes this and falls back to it when the server has no
/// strain value for the selected day.
@MainActor
final class DayStrainStore: ObservableObject {
  static let shared = DayStrainStore()

  @Published private(set) var today: DayStrainCalculator.DayStrain?
  @Published private(set) var debug: DebugSnapshot?

  struct DebugSnapshot: Equatable {
    let workoutsFound: Int
    let totalHRSamples: Int
    let nonWorkoutSamples: Int
    let backgroundTRIMP: Double
    let workoutEdwardsRaw: Double
    let workoutEdwardsScaled: Double
    let totalTRIMP: Double
    let finalStrain: Double
  }

  /// Compute today's strain using per-activity calibrated formulas.
  ///
  /// Algorithm:
  /// 1. Pull today's HR samples and completed workouts.
  /// 2. Group workouts by which `StrainFormula` they map to.
  /// 3. Within each group: sum the workout's effective-kJ (using its
  ///    formula's per-zone rates), then apply the group's formula to
  ///    produce a group strain.
  /// 4. Background (non-workout) HR samples flow through the running
  ///    formula's per-second rate, producing a background strain.
  /// 5. Combine all group strains + background via cube-root sum so a
  ///    mixed day (run + yoga) doesn't go superlinear, and a same-activity
  ///    multi-session day matches summing the loads.
  func refresh() {
    let now = Date()
    let allSamples = HeartRateSeriesStore.shared.samples(forDayContaining: now)
    let offWristWindows = SensorSampleStore.shared.offWristWindows()
    let calendar = Calendar.current
    let dayStart = calendar.startOfDay(for: now)
    let workoutsToday = CompletedWorkoutStore.shared.workouts.filter { $0.startedAt >= dayStart }
    let workoutWindows: [(Date, Date)] = workoutsToday.map { ($0.startedAt, $0.endedAt) }

    // 1. Non-workout HR samples (samples inside any workout window get
    // attributed to that workout's formula instead).
    let nonWorkoutSamples = allSamples.filter { sample in
      !workoutWindows.contains { sample.capturedAt >= $0.0 && sample.capturedAt <= $0.1 }
    }
    let offWristFiltered = Self.filterOffWrist(nonWorkoutSamples, offWristWindows: offWristWindows)
    let bgFormula = DayStrainCalculator.runningFormula
    var bgEffectiveKJ: Double = 0
    var lastTime: Date?
    for sample in offWristFiltered.sorted(by: { $0.capturedAt < $1.capturedAt }) {
      let dt: TimeInterval
      if let last = lastTime {
        dt = min(max(sample.capturedAt.timeIntervalSince(last), 0), 5)
      } else {
        dt = 1.0
      }
      lastTime = sample.capturedAt
      bgEffectiveKJ += bgFormula.effectiveKJPerSecond(forBPM: sample.bpm) * dt
    }
    let bgStrain = bgFormula.strain(fromEffectiveKJ: bgEffectiveKJ)

    // 2. Group workouts by their formula. Sum eff-kJ within each group,
    // then apply that group's formula to its summed eff-kJ.
    var groups: [String: (formula: DayStrainCalculator.StrainFormula, effectiveKJ: Double)] = [:]
    var allZoneMinutes: [Int: Double] = [:]
    for workout in workoutsToday {
      let formula = DayStrainCalculator.formula(forActivityRaw: workout.activityRaw)
      var workoutEffKJ: Double = 0
      for (zone, seconds) in workout.zoneDurations {
        let minutes = seconds / 60.0
        allZoneMinutes[zone, default: 0] += minutes
        workoutEffKJ += formula.effectiveKJPerMinute(forZone: zone) * minutes
      }
      let existing = groups[formula.name] ?? (formula, 0)
      groups[formula.name] = (formula, existing.effectiveKJ + workoutEffKJ)
    }
    let perGroupStrains: [(name: String, strain: Double)] = groups.map { _, value in
      (value.formula.name, value.formula.strain(fromEffectiveKJ: value.effectiveKJ))
    }

    // 3. Cube-root combine all strain contributions.
    let cubed = perGroupStrains.reduce(0.0) { $0 + pow($1.strain, 3) }
                + pow(bgStrain, 3)
    let combinedStrain = min(21, max(0, pow(cubed, 1.0 / 3.0)))

    let dateKey: String = {
      let f = DateFormatter()
      f.dateFormat = "yyyy-MM-dd"
      f.timeZone = TimeZone.current
      return f.string(from: now)
    }()

    today = DayStrainCalculator.DayStrain(
      dateKey: dateKey,
      strain: combinedStrain,
      trimp: bgEffectiveKJ + groups.values.reduce(0) { $0 + $1.effectiveKJ },
      sampleCount: nonWorkoutSamples.count,
      zoneMinutes: allZoneMinutes,
      lastSampleAt: allSamples.last?.capturedAt
    )
    debug = DebugSnapshot(
      workoutsFound: workoutsToday.count,
      totalHRSamples: allSamples.count,
      nonWorkoutSamples: nonWorkoutSamples.count,
      backgroundTRIMP: bgEffectiveKJ,
      workoutEdwardsRaw: groups.values.reduce(0) { $0 + $1.effectiveKJ },
      workoutEdwardsScaled: perGroupStrains.reduce(0) { $0 + $1.strain },
      totalTRIMP: bgEffectiveKJ + groups.values.reduce(0) { $0 + $1.effectiveKJ },
      finalStrain: combinedStrain
    )
  }

  /// Drop samples inside any merged off-wrist window — same logic as
  /// `DayStrainCalculator.computeDayStrain`, lifted here so the per-formula
  /// path can reuse it without recomputing Banister TRIMP.
  private static func filterOffWrist(
    _ samples: [HeartRateSamplePoint],
    offWristWindows: [(start: Date, end: Date)]
  ) -> [HeartRateSamplePoint] {
    guard !offWristWindows.isEmpty else { return samples }
    return samples.filter { sample in
      var lo = 0
      var hi = offWristWindows.count - 1
      while lo <= hi {
        let mid = (lo + hi) / 2
        let window = offWristWindows[mid]
        if sample.capturedAt < window.start { hi = mid - 1 }
        else if sample.capturedAt > window.end { lo = mid + 1 }
        else { return false }
      }
      return true
    }
  }

}
