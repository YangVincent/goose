import Foundation

/// View-layer shape for a single day's recovery/sleep/strain. Originally
/// the cloud /api/whoop/day response; now populated entirely from local
/// SQLite (`imported_daily_summary` + `external_sleep_sessions`). The
/// struct shape is preserved so view code reads the same fields.
struct WhoopOverview {
  struct WhoopDay {
    let recovery: Recovery?
    let sleep: Sleep?
    let strain: Strain?
  }

  struct Recovery {
    let start: String?
    let recovery_score: Double?
    let resting_heart_rate: Double?
    let hrv_rmssd_milli: Double?
    let spo2_percentage: Double?
    let skin_temp_celsius: Double?
  }

  struct Sleep {
    let start: String?
    let end: String?
    let performance: Double?
    let efficiency: Double?
    let stage_summary: StageSummary?
    let sleep_needed: SleepNeeded?
  }

  struct StageSummary {
    let total_in_bed_time_milli: Int?
    let total_awake_time_milli: Int?
    let total_light_sleep_time_milli: Int?
    let total_slow_wave_sleep_time_milli: Int?
    let total_rem_sleep_time_milli: Int?
    let sleep_cycle_count: Int?
    let disturbance_count: Int?
  }

  struct SleepNeeded {
    let baseline_milli: Int?
    let need_from_sleep_debt_milli: Int?
    let need_from_recent_strain_milli: Int?
    let need_from_recent_nap_milli: Int?
  }

  struct Strain {
    let strain: Double?
    let kilojoule: Double?
  }
}

/// Long-window aggregate stats. Previously fetched from /api/whoop/healthspan;
/// now computed locally from `imported_daily_summary` rows.
struct WhoopHealthspan {
  let window_days: Int?
  let sleep_consistency_pct_30d: Double?
  let sleep_hours_30d: Double?
  let rhr_30d: Double?
  let hr_zones_1_3_weekly_hours: Double?
  let hr_zones_4_5_weekly_hours: Double?
  let strength_weekly_minutes: Double?
  let vo2_max_estimate: Double?
  let max_hr: Int?
  let series: Series?

  struct Series {
    let sleep: [SleepDay]?
    let recovery: [RecoveryDay]?
    let strain: [StrainDay]?
  }

  struct SleepDay {
    let date: String
    let consistency: Double?
    let asleep_hours: Double?
  }

  struct RecoveryDay {
    let date: String
    let rhr: Double?
    let hrv: Double?
    let recovery: Double?
  }

  struct StrainDay {
    let date: String
    let value: Double?
  }
}

/// View-layer workout record. Local activity store (`CompletedWorkoutStore`)
/// is the authoritative source going forward; this is the "calendar dot"
/// shape some surfaces still expect.
struct WhoopActivity: Identifiable {
  let date: String
  let name: String?
  let type: String?
  let source: String?
  let strain: Double?
  let kilojoule: Double?
  let max_hr: Int?
  let avg_hr: Int?
  let distance: Double?
  let moving_time: Double?
  let elevation: Double?
  let suffer_score: Double?
  var id: String { date }
}

/// Month-grid recovery-score dots. Derived from `imported_daily_summary`.
struct WhoopCalendar {
  let month: String?
  let dates: [DateEntry]
  let workout_dates: [String]?

  struct DateEntry: Identifiable {
    let date: String
    let recovery_score: Double?
    var id: String { date }
  }
}
