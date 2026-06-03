import Darwin
import Foundation
import SwiftUI
import UIKit

struct HealthView: View {
  @EnvironmentObject private var model: GooseAppModel
  @ObservedObject var store: HealthDataStore
  @State private var cachedLandingSnapshots: [HealthRoute: HealthMetricSnapshot] = [:]
  @State private var cachedHealthMonitorSnapshots: [HealthMetricSnapshot] = []

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 22) {
        HealthDashboardStatusHeader(
          catalogStatus: store.catalogStatus,
          usesSampleData: store.usesSampleData
        )

        HealthActivityOverviewSection(
          steps: store.whoopStepsDisplayText(),
          activeEnergy: store.whoopActiveCaloriesDisplayText(),
          stepsFreshness: store.whoopStepsStatusText(),
          stepsSource: store.whoopStepsSource(),
          activeEnergyFreshness: store.whoopActiveCaloriesStatusText(),
          activeEnergySource: store.whoopActiveCaloriesSource(),
          heartRateValue: liveHeartRateValue,
          heartRateStatus: liveHeartRateStatus,
          heartRateSource: liveHeartRateSource
        )

        HealthVitalsPreviewSection(snapshots: vitalSnapshots)

        HealthRouteShortcutSection(
          title: "Explore Health",
          snapshots: snapshots(for: [.sleep, .recovery, .strain, .stress, .cardioLoad, .energyBank])
        )

        HealthRouteShortcutSection(
          title: "Data & Algorithms",
          snapshots: snapshots(for: [.packetInputs, .algorithms, .calibration])
        )
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .gooseScreenBackground()
    .navigationTitle("Health")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .navigationDestination(for: HealthRoute.self) { route in
      HealthRouteContentView(route: route, store: store)
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          refreshDashboard()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
        .accessibilityLabel("Refresh Health")
      }
    }
    .onAppear {
      model.recordUIAction("page.opened", detail: "Health")
      store.loadBridgeCatalogsIfNeeded()
      store.refreshHeartRateTimeline()
      recomputeHealthState()
    }
    .onChange(of: model.ble.liveHeartRateBPM) { _, _ in
      recomputeHealthState()
    }
    .onChange(of: store.packetInputStatus) { _, _ in
      recomputeHealthState()
    }
    .onChange(of: store.catalogStatus) { _, _ in
      recomputeHealthState()
    }
  }

  private func recomputeHealthState() {
    let snapshots = store.landingSnapshots(
      liveHeartRateBPM: model.ble.liveHeartRateBPM,
      liveHeartRateSource: model.ble.liveHeartRateSource,
      liveHeartRateUpdatedAt: model.ble.liveHeartRateUpdatedAt
    )
    cachedLandingSnapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.route, $0) })
    cachedHealthMonitorSnapshots = store.healthMonitorSnapshots()
  }

  private var vitalSnapshots: [HealthMetricSnapshot] {
    Array(cachedHealthMonitorSnapshots.prefix(4))
  }

  private var liveHeartRateValue: String {
    guard let bpm = model.ble.liveHeartRateBPM else {
      return "--"
    }
    return "\(bpm) bpm"
  }

  private var liveHeartRateStatus: String {
    guard model.ble.liveHeartRateBPM != nil else {
      return store.heartRateTimelineStatus
    }
    return HealthDataStore.relativeText(for: model.ble.liveHeartRateUpdatedAt) ?? "Live"
  }

  private var liveHeartRateSource: HealthDataSource {
    model.ble.liveHeartRateBPM == nil
      ? .unavailable("BLE heart-rate stream waiting")
      : .live(model.ble.liveHeartRateSource)
  }

  private func snapshots(for routes: [HealthRoute]) -> [HealthMetricSnapshot] {
    routes.compactMap { route in
      cachedLandingSnapshots[route] ?? store.snapshot(for: route)
    }
  }

  @MainActor
  private func refreshDashboard() {
    store.refreshBridgeCatalogs()
    store.refreshHeartRateTimeline()
    store.refreshPacketInputsIfNeeded()
  }
}
