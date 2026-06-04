import Foundation

/// Local recovery score (0-100) computed from our own HRV + RHR + sleep
/// performance. Mirrors WHOOP's recovery semantics:
///
///   - Higher than your baseline HRV → recovered
///   - Lower RHR than baseline       → recovered
///   - Better sleep performance      → recovered
///
/// Each signal contributes a z-score; weights average them with HRV
/// weighted heaviest (matching WHOOP's published methodology that HRV is
/// the primary recovery driver). The final score maps to 0–100 with the
/// same green / yellow / red bands the strain card uses.
enum GooseRecoveryCalculator {
  struct Score {
    let score: Int                  // 0..100
    let band: Band
    let hrvComponent: Double?       // most recent HRV (ms)
    let hrvBaseline: Double?
    let rhrComponent: Double?       // most recent RHR (bpm)
    let rhrBaseline: Double?
    let sleepPerformance: Double?   // server-side, 0..100
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

  /// Compute today's recovery from arrays of recent daily HRV / RHR values.
  /// Pass the values ordered oldest-first; the last entry is treated as
  /// today's measurement (the one being scored).
  ///
  /// `hrvSeries` and `rhrSeries` are usually drawn from
  /// `WhoopAPIClient.recoveryHistory` (server) — we don't compute our own
  /// nightly HRV yet (Goose's HRVAnalyzer runs intra-day on RR intervals).
  /// Once nightly HRV lands, swap the inputs and this calculator works
  /// unchanged.
  static func compute(
    hrvSeries: [Double],
    rhrSeries: [Double],
    sleepPerformance: Double?
  ) -> Score {
    let hrvCore = scoreFromHRV(series: hrvSeries)
    let rhrCore = scoreFromRHR(series: rhrSeries)
    let sleepCore = sleepPerformance.map { $0 / 100.0 }

    // Weighted average. Matches WHOOP's published methodology that HRV is
    // the primary input.
    let weights: [(score: Double?, weight: Double)] = [
      (hrvCore?.score, 0.55),
      (rhrCore?.score, 0.20),
      (sleepCore,      0.25),
    ]
    let active = weights.filter { $0.score != nil }
    guard !active.isEmpty else {
      return Score(
        score: 0,
        band: .red,
        hrvComponent: hrvSeries.last,
        hrvBaseline: nil,
        rhrComponent: rhrSeries.last,
        rhrBaseline: nil,
        sleepPerformance: sleepPerformance,
        baselineDayCount: 0,
        confidence: 0
      )
    }
    let totalWeight = active.reduce(0) { $0 + $1.weight }
    let weightedSum = active.reduce(0.0) { sum, item in
      sum + (item.score ?? 0) * item.weight
    }
    let normalized = weightedSum / totalWeight
    let score = Int((normalized * 100).rounded())

    return Score(
      score: max(0, min(100, score)),
      band: Band(score: score),
      hrvComponent: hrvSeries.last,
      hrvBaseline: hrvCore?.baseline,
      rhrComponent: rhrSeries.last,
      rhrBaseline: rhrCore?.baseline,
      sleepPerformance: sleepPerformance,
      baselineDayCount: max(hrvSeries.count, rhrSeries.count) - 1,
      confidence: confidence(active.count, baselineDays: max(hrvSeries.count, rhrSeries.count))
    )
  }

  private struct ComponentScore {
    let score: Double  // 0..1
    let baseline: Double
  }

  /// Score HRV: higher than baseline = better recovery. Z-score from prior
  /// N days (excluding today), squashed by tanh into a 0–1 range with the
  /// midpoint at the baseline mean.
  private static func scoreFromHRV(series: [Double]) -> ComponentScore? {
    guard series.count >= 4, let today = series.last else { return nil }
    let baseline = Array(series.dropLast())
    let mean = baseline.reduce(0, +) / Double(baseline.count)
    let std = stdDev(values: baseline, mean: mean)
    guard std > 0.0001 else { return nil }
    let z = (today - mean) / std
    let squashed = (tanh(z / 1.5) + 1) / 2
    return ComponentScore(score: squashed, baseline: mean)
  }

  /// Score RHR: LOWER than baseline = better recovery. Flip the z so a
  /// lower-than-baseline RHR pushes the score up.
  private static func scoreFromRHR(series: [Double]) -> ComponentScore? {
    guard series.count >= 4, let today = series.last else { return nil }
    let baseline = Array(series.dropLast())
    let mean = baseline.reduce(0, +) / Double(baseline.count)
    let std = stdDev(values: baseline, mean: mean)
    guard std > 0.0001 else { return nil }
    let z = -(today - mean) / std
    let squashed = (tanh(z / 1.5) + 1) / 2
    return ComponentScore(score: squashed, baseline: mean)
  }

  private static func stdDev(values: [Double], mean: Double) -> Double {
    guard values.count >= 2 else { return 0 }
    let sq = values.map { ($0 - mean) * ($0 - mean) }
    return sqrt(sq.reduce(0, +) / Double(values.count - 1))
  }

  private static func confidence(_ componentsPresent: Int, baselineDays: Int) -> Double {
    let compFactor = min(1.0, Double(componentsPresent) / 3.0)
    let dayFactor = min(1.0, Double(baselineDays) / 14.0)
    return compFactor * dayFactor
  }
}
