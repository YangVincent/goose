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

    // Single-pass walk: instead of N×M filters, sort once and advance
    // pointers across the HR and sensor streams as we step through epochs.
    // Sleep windows are ~7 hours × ~25k HR samples × ~840 epochs; the old
    // filter-per-epoch implementation was 21M ops on the main thread and
    // hung the Sleep tab for seconds.
    let hrSorted = hrSamples.sorted { $0.capturedAt < $1.capturedAt }
    let sensorSorted = sensorSamples.sorted { $0.capturedAt < $1.capturedAt }
    var hrIdx = 0
    var sensorIdx = 0
    var rawEpochs: [Epoch] = []
    var cursor = window.start
    while cursor.addingTimeInterval(epochSeconds) <= window.end.addingTimeInterval(0.5) {
      let end = cursor.addingTimeInterval(epochSeconds)

      // Advance hrIdx past anything before cursor (e.g. on first iteration
      // or when sample timestamps drift behind the window).
      while hrIdx < hrSorted.count && hrSorted[hrIdx].capturedAt < cursor {
        hrIdx += 1
      }
      // Collect all HR samples whose capturedAt is in [cursor, end).
      var hrSum: Int = 0
      var hrCount: Int = 0
      var hrValuesForStd: [Double] = []
      var hrConsumeIdx = hrIdx
      while hrConsumeIdx < hrSorted.count && hrSorted[hrConsumeIdx].capturedAt < end {
        let bpm = hrSorted[hrConsumeIdx].bpm
        hrSum += bpm
        hrCount += 1
        hrValuesForStd.append(Double(bpm))
        hrConsumeIdx += 1
      }

      if hrCount == 0 {
        cursor = end
        // hrIdx unchanged — next epoch starts where this one left off.
        continue
      }

      // Same single-pass walk over sensor samples.
      while sensorIdx < sensorSorted.count && sensorSorted[sensorIdx].capturedAt < cursor {
        sensorIdx += 1
      }
      var rrIntervalsMs: [Int] = []
      var lastSkinTempRaw: Int?
      var contactOnCount = 0
      var contactTotal = 0
      var sensorConsumeIdx = sensorIdx
      while sensorConsumeIdx < sensorSorted.count && sensorSorted[sensorConsumeIdx].capturedAt < end {
        let sample = sensorSorted[sensorConsumeIdx]
        if let rr = sample.rrIntervalsMS { rrIntervalsMs.append(contentsOf: rr) }
        if let temp = sample.skinTempRaw { lastSkinTempRaw = temp }
        if let contact = sample.skinContact {
          contactTotal += 1
          if contact != 0 { contactOnCount += 1 }
        }
        sensorConsumeIdx += 1
      }

      let majorityOffWrist = contactTotal > 0
        && (contactTotal - contactOnCount) > contactTotal / 2
      if majorityOffWrist {
        // Advance pointers and move on without emitting an epoch.
        hrIdx = hrConsumeIdx
        sensorIdx = sensorConsumeIdx
        cursor = end
        continue
      }

      let meanHR = Double(hrSum) / Double(hrCount)
      let hrStd = stddev(hrValuesForStd, mean: meanHR)
      let rmssd: Double? = rrIntervalsMs.count >= 6 ? hrvRmssd(intervalsMS: rrIntervalsMs) : nil
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
        skinTempRaw: lastSkinTempRaw
      ))
      hrIdx = hrConsumeIdx
      sensorIdx = sensorConsumeIdx
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
