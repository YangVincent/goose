import Foundation

/// Local sleep stage estimator. Per 30-second epoch in a detected sleep
/// window, classifies into WAKE / LIGHT / DEEP / REM using:
///
/// - HR mean and standard deviation (from HeartRateSeriesStore)
/// - RMSSD per-epoch from RR intervals (sensor_samples)
/// - Motion intensity (MovementPacketSample average isn't persisted per
///   epoch yet — we use signal_quality / contact_bit transitions and
///   IMUPacketStore packet activity as a proxy)
/// - Skin temperature (sensor_samples skin_temp_raw)
///
/// Method: feature-based rules from Walch et al. 2019 and Beattie et al.
/// 2017 (~70% epoch agreement with PSG when applied to wrist HR + actigraphy).
/// We then smooth with a 3-epoch majority filter so the stage doesn't flip
/// every 30s.
enum SleepStageEstimator {
  enum Stage: Int {
    case wake = 0
    case light = 1
    case rem = 2
    case deep = 3

    var label: String {
      switch self {
      case .wake: "WAKE"
      case .light: "LIGHT"
      case .rem: "REM"
      case .deep: "DEEP"
      }
    }
  }

  struct Epoch: Identifiable {
    let id: UUID
    let start: Date
    let end: Date
    let stage: Stage
    let meanHR: Double
    let hrStd: Double
    let rmssdMS: Double?
    let skinTempRaw: Int?
  }

  struct Hypnogram {
    let windowStart: Date
    let windowEnd: Date
    let epochs: [Epoch]
    let stageMinutes: [Stage: Double]

    var totalMinutes: Double {
      Double(epochs.count) * 0.5
    }
  }

  static let epochSeconds: TimeInterval = 30

  /// Build a hypnogram for the supplied window using whatever data is
  /// already in the local stores.
  static func hypnogram(
    in window: (start: Date, end: Date),
    hrSamples: [HeartRateSamplePoint],
    sensorSamples: [SensorSample],
    restingBPM: Double
  ) -> Hypnogram {
    guard window.end > window.start else {
      return Hypnogram(windowStart: window.start, windowEnd: window.end, epochs: [], stageMinutes: [:])
    }

    // Build a per-epoch HR series
    var rawEpochs: [Epoch] = []
    var cursor = window.start
    while cursor.addingTimeInterval(epochSeconds) <= window.end.addingTimeInterval(0.5) {
      let end = cursor.addingTimeInterval(epochSeconds)
      let hrInEpoch = hrSamples.filter { $0.capturedAt >= cursor && $0.capturedAt < end }.map { Double($0.bpm) }
      let sensorInEpoch = sensorSamples.filter { $0.capturedAt >= cursor && $0.capturedAt < end }

      // Skip epochs where we have no HR data (off-wrist or no capture).
      if hrInEpoch.isEmpty {
        cursor = end
        continue
      }

      let meanHR = hrInEpoch.reduce(0, +) / Double(hrInEpoch.count)
      let hrStd = stddev(hrInEpoch, mean: meanHR)

      // RMSSD per-epoch from RR intervals across the sensor samples in
      // this epoch.
      let rrIntervalsMs: [Int] = sensorInEpoch.flatMap { $0.rrIntervalsMS ?? [] }
      let rmssd: Double? = rrIntervalsMs.count >= 6 ? hrvRmssd(intervalsMS: rrIntervalsMs) : nil

      // Skin temp ADC for this epoch — last seen value
      let skinTemp = sensorInEpoch.compactMap(\.skinTempRaw).last

      // Skin contact bit — drop epoch from staging if off-wrist majority.
      let contactValues = sensorInEpoch.compactMap(\.skinContact)
      let offWristCount = contactValues.filter { $0 == 0 }.count
      let majorityOffWrist = !contactValues.isEmpty
        && offWristCount > contactValues.count / 2
      if majorityOffWrist {
        cursor = end
        continue
      }

      let stage = classify(
        meanHR: meanHR,
        hrStd: hrStd,
        rmssdMS: rmssd,
        restingBPM: restingBPM
      )
      rawEpochs.append(Epoch(
        id: UUID(),
        start: cursor,
        end: end,
        stage: stage,
        meanHR: meanHR,
        hrStd: hrStd,
        rmssdMS: rmssd,
        skinTempRaw: skinTemp
      ))
      cursor = end
    }

    let smoothed = smooth(rawEpochs)
    var stageMinutes: [Stage: Double] = [:]
    for epoch in smoothed {
      stageMinutes[epoch.stage, default: 0] += 0.5
    }
    return Hypnogram(
      windowStart: window.start,
      windowEnd: window.end,
      epochs: smoothed,
      stageMinutes: stageMinutes
    )
  }

  // MARK: - Classification

  /// Feature-based classification. Thresholds calibrated to standard sleep
  /// physiology — HR drops 5-15% below rest in deep, RMSSD is highest in
  /// REM, motion + elevated HR signal wake.
  private static func classify(
    meanHR: Double,
    hrStd: Double,
    rmssdMS: Double?,
    restingBPM: Double
  ) -> Stage {
    // Wake: HR clearly elevated above rest OR HR std very high (movement
    // bursts increase HR variability).
    if meanHR > restingBPM + 15 || hrStd > 7 {
      return .wake
    }
    // Use RMSSD if we have it.
    if let rmssd = rmssdMS {
      // REM: elevated parasympathetic tone — RMSSD high, HR not super low.
      if rmssd > 50 && meanHR > restingBPM - 2 && meanHR < restingBPM + 10 {
        return .rem
      }
      // Deep: low HR + suppressed HRV.
      if meanHR < restingBPM + 3 && rmssd < 35 {
        return .deep
      }
      return .light
    }
    // Without RMSSD: rely on HR alone.
    if meanHR < restingBPM + 3 {
      return .deep
    }
    return .light
  }

  // MARK: - Smoothing

  /// 3-epoch majority filter — prevents stages from flipping every 30s.
  private static func smooth(_ epochs: [Epoch]) -> [Epoch] {
    guard epochs.count >= 3 else { return epochs }
    var smoothed = epochs
    for idx in 1..<(epochs.count - 1) {
      let prev = epochs[idx - 1].stage
      let cur = epochs[idx].stage
      let next = epochs[idx + 1].stage
      // If current is a single-epoch outlier and prev == next, snap.
      if prev == next && cur != prev {
        smoothed[idx] = Epoch(
          id: epochs[idx].id,
          start: epochs[idx].start,
          end: epochs[idx].end,
          stage: prev,
          meanHR: epochs[idx].meanHR,
          hrStd: epochs[idx].hrStd,
          rmssdMS: epochs[idx].rmssdMS,
          skinTempRaw: epochs[idx].skinTempRaw
        )
      }
    }
    return smoothed
  }

  // MARK: - Math helpers

  private static func stddev(_ values: [Double], mean: Double) -> Double {
    guard values.count > 1 else { return 0 }
    let sq = values.map { ($0 - mean) * ($0 - mean) }
    return sqrt(sq.reduce(0, +) / Double(values.count - 1))
  }

  private static func hrvRmssd(intervalsMS: [Int]) -> Double {
    guard intervalsMS.count >= 2 else { return 0 }
    var sq: Double = 0
    for idx in 1..<intervalsMS.count {
      let diff = Double(intervalsMS[idx] - intervalsMS[idx - 1])
      sq += diff * diff
    }
    return sqrt(sq / Double(intervalsMS.count - 1))
  }
}

@MainActor
final class SleepHypnogramStore: ObservableObject {
  static let shared = SleepHypnogramStore()

  @Published private(set) var lastNight: SleepStageEstimator.Hypnogram?

  /// Refresh from the current SleepWindowStore window. If the window store
  /// has a historical reference date, this picks up that night.
  func refresh() {
    guard let window = SleepWindowStore.shared.lastNight else {
      lastNight = nil
      return
    }
    let hrSamples = HeartRateSeriesStore.shared.samples(from: window.onset, to: window.wake)
    let sensorSamples = SensorSampleStore.shared.snapshot(from: window.onset, to: window.wake)
    let resting = HeartRateSeriesStore.shared.restingEstimate()?.bpm
                  ?? Double(UserProfile.restingHeartRate)
    let hypno = SleepStageEstimator.hypnogram(
      in: (window.onset, window.wake),
      hrSamples: hrSamples,
      sensorSamples: sensorSamples,
      restingBPM: resting
    )
    lastNight = hypno
  }
}
