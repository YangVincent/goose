import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

/// Bridges Goose's local `CompletedWorkoutStore` into Apple Health. Each
/// completed workout becomes one `HKWorkout` with average/max HR, calorie,
/// and distance metrics, written under the "Goose" source name.
///
/// We only WRITE — never read — so the user keeps full provenance: every
/// HKWorkout we produce is tagged with `metadata["GooseSessionID"]` and the
/// strap source ("WHOOP MG via Goose"). Reading from HealthKit would
/// duplicate workouts already in the local store.
///
/// Authorization is asked on first export attempt. If the user denies, we
/// surface the error but don't disable the export button (in case they want
/// to grant permission later).
@MainActor
final class GooseHealthKitExporter: ObservableObject {
  static let shared = GooseHealthKitExporter()

  @Published private(set) var lastExportedAt: Date?
  @Published private(set) var lastError: String?
  @Published private(set) var sessionsExported: Int = 0
  @Published private(set) var isAuthorized = false
  @Published private(set) var isWorking = false

  #if canImport(HealthKit)
  private let store = HKHealthStore()
  #endif

  /// Request read+write for the workout + HR/calorie/distance types we'll
  /// be writing. Apple Health treats workout authorization as
  /// per-data-type so we ask only for what we touch.
  func requestAuthorization() async {
    #if canImport(HealthKit)
    guard HKHealthStore.isHealthDataAvailable() else {
      lastError = "HealthKit unavailable on this device"
      return
    }
    let typesToShare: Set<HKSampleType> = [
      HKObjectType.workoutType(),
      HKQuantityType(.heartRate),
      HKQuantityType(.activeEnergyBurned),
      HKQuantityType(.distanceWalkingRunning),
    ]
    do {
      try await store.requestAuthorization(toShare: typesToShare, read: [])
      isAuthorized = true
    } catch {
      lastError = "auth failed: \(error.localizedDescription)"
    }
    #else
    lastError = "HealthKit unavailable"
    #endif
  }

  /// Export every completed workout that hasn't been exported yet. We
  /// track exported session IDs in UserDefaults so re-runs are idempotent.
  func exportAll() async {
    guard !isWorking else { return }
    isWorking = true
    defer { isWorking = false }

    #if canImport(HealthKit)
    if !isAuthorized {
      await requestAuthorization()
      guard isAuthorized else { return }
    }
    var exportedIds = Self.exportedSessionIDs
    var newlyExported = 0
    for workout in CompletedWorkoutStore.shared.workouts {
      guard !exportedIds.contains(workout.id) else { continue }
      do {
        try await exportOne(workout)
        exportedIds.insert(workout.id)
        newlyExported += 1
      } catch {
        lastError = "export \(workout.id) failed: \(error.localizedDescription)"
      }
    }
    Self.exportedSessionIDs = exportedIds
    sessionsExported += newlyExported
    lastExportedAt = Date()
    lastError = newlyExported > 0 ? nil : lastError
    #else
    lastError = "HealthKit unavailable"
    #endif
  }

  #if canImport(HealthKit)
  private func exportOne(_ workout: CompletedWorkout) async throws {
    let activityType = Self.hkActivityType(for: workout.activityRaw)
    let metadata: [String: Any] = [
      HKMetadataKeyWorkoutBrandName: "WHOOP MG via Goose",
      "GooseSessionID": workout.id,
      "GooseActivityRaw": workout.activityRaw,
      "GooseAvgHR": workout.averageHeartRate ?? 0,
      "GooseMaxHR": workout.maxHeartRate ?? 0,
      "GooseZoneSeconds": workout.zoneDurations.map { "\($0.key):\($0.value)" }.joined(separator: ","),
    ]
    let configuration = HKWorkoutConfiguration()
    configuration.activityType = activityType

    let builder = HKWorkoutBuilder(
      healthStore: store,
      configuration: configuration,
      device: .local()
    )
    try await builder.beginCollection(at: workout.startedAt)

    // Distance + calorie samples — both required for HKWorkout to be
    // meaningful in the Health app's workout list.
    let activeCaloriesKcal = max(1.0, workout.elapsedSeconds / 8.0)
    let energyType = HKQuantityType(.activeEnergyBurned)
    let energyQuantity = HKQuantity(unit: .kilocalorie(), doubleValue: activeCaloriesKcal)
    let energySample = HKQuantitySample(
      type: energyType,
      quantity: energyQuantity,
      start: workout.startedAt,
      end: workout.endedAt,
      metadata: nil
    )
    try await builder.addSamples([energySample])

    if workout.distanceMeters > 5 {
      let distanceType = HKQuantityType(.distanceWalkingRunning)
      let distanceQuantity = HKQuantity(unit: .meter(), doubleValue: workout.distanceMeters)
      let distanceSample = HKQuantitySample(
        type: distanceType,
        quantity: distanceQuantity,
        start: workout.startedAt,
        end: workout.endedAt,
        metadata: nil
      )
      try await builder.addSamples([distanceSample])
    }

    if let avgHR = workout.averageHeartRate, avgHR > 30 {
      let hrType = HKQuantityType(.heartRate)
      let hrUnit = HKUnit.count().unitDivided(by: .minute())
      let hrSample = HKQuantitySample(
        type: hrType,
        quantity: HKQuantity(unit: hrUnit, doubleValue: Double(avgHR)),
        start: workout.startedAt,
        end: workout.endedAt,
        metadata: nil
      )
      try await builder.addSamples([hrSample])
    }

    try await builder.addMetadata(metadata)
    try await builder.endCollection(at: workout.endedAt)
    _ = try await builder.finishWorkout()
  }

  private static func hkActivityType(for raw: String) -> HKWorkoutActivityType {
    let lower = raw.lowercased()
    if lower.contains("run") { return .running }
    if lower.contains("walk") { return .walking }
    if lower.contains("hike") { return .hiking }
    if lower.contains("ride") || lower.contains("cycl") { return .cycling }
    if lower.contains("bike") { return .cycling }
    if lower.contains("swim") { return .swimming }
    if lower.contains("strength") { return .functionalStrengthTraining }
    if lower.contains("hiit") { return .highIntensityIntervalTraining }
    if lower.contains("yoga") { return .yoga }
    if lower.contains("pilates") { return .pilates }
    if lower.contains("row") { return .rowing }
    if lower.contains("elliptical") { return .elliptical }
    if lower.contains("stair") { return .stairs }
    if lower.contains("barre") { return .barre }
    if lower.contains("functional") { return .functionalStrengthTraining }
    return .other
  }
  #endif

  // MARK: - Idempotency tracking

  private static let exportedKey = "com.goose.swift.healthkit.exported_session_ids"

  private static var exportedSessionIDs: Set<String> {
    get {
      let array = UserDefaults.standard.stringArray(forKey: exportedKey) ?? []
      return Set(array)
    }
    set {
      UserDefaults.standard.set(Array(newValue), forKey: exportedKey)
    }
  }
}
