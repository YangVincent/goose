import Foundation

/// Value types for recovery score breakdown UIs. The compute logic was
/// deleted as part of the migration to the typed `recovery_readings`
/// table — consumers now read `dailyStore.summary.recoveryScore` and
/// build a `Score` directly from the daily store's overlay (which
/// already merges recovery_readings on top of imported_daily_summary).
///
/// Keep `Score` + `Band` here because `WhoopRecoveryBreakdownCard`,
/// `RecoveryFactorsDetailView`, and friends still render breakdowns
/// against this shape. Marked as a tiny module-level facade rather
/// than dispersing the types into each view.
enum GooseRecoveryCalculator {
  struct Score {
    let score: Int                  // 0..100
    let band: Band
    let hrvComponent: Double?       // most recent HRV (ms)
    let hrvBaseline: Double?
    let rhrComponent: Double?       // most recent RHR (bpm)
    let rhrBaseline: Double?
    let sleepPerformance: Double?   // 0..100
    let baselineDayCount: Int
    let confidence: Double          // 0..1
  }

  enum Band: String {
    case green
    case yellow
    case red

    init(score: Int) {
      if score >= 67 { self = .green }
      else if score >= 34 { self = .yellow }
      else { self = .red }
    }
  }
}
