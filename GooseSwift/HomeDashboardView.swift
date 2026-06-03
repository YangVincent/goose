import SwiftUI

struct HomeDashboardView: View {
  @EnvironmentObject private var model: GooseAppModel
  @EnvironmentObject private var router: AppRouter
  @ObservedObject var healthStore: HealthDataStore
  @Binding var selectedDate: Date
  let openHealthRoute: (HealthRoute) -> Void
  @State private var showingScoreDatePicker = false
  @State private var showingCardioLoadSheet = false
  @State private var selectedHealthMonitorTrend: HealthMetricSnapshot?
  @State private var cachedLandingSnapshots: [HealthRoute: HealthMetricSnapshot] = [:]
  @State private var cachedCardioLoadDays: [CardioLoadDay] = []
  @State private var cachedHealthMonitorSnapshots: [HealthMetricSnapshot] = []
  @State private var cachedHomeCoachTip: CoachInlineTip?

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 18) {
        WhoopScoreCard(
          scores: scoreSnapshots,
          actionSummary: dailyActionSummary,
          coachTip: cachedHomeCoachTip ?? CoachTipFactory.homeTip(healthStore: healthStore, appModel: model),
          openScore: openHealth,
          openCoach: openCoach
        )

        HomeStressEnergySection(
          stress: landingSnapshot(for: .stress),
          energy: landingSnapshot(for: .energyBank),
          openStress: { openHealth(.stress) }
        )

        HomeCardioLoadWidget(
          snapshot: landingSnapshot(for: .cardioLoad),
          days: cachedCardioLoadDays.isEmpty ? healthStore.cardioLoadWeeklyPoints() : cachedCardioLoadDays
        ) {
          showingCardioLoadSheet = true
          model.recordUIAction("health.sheet.opened", detail: "Cardio Load home widget")
        }

        HomeHealthMonitorSection(
          snapshots: cachedHealthMonitorSnapshots.isEmpty
            ? healthStore.healthMonitorSnapshots(allowLiveFallbacks: false)
            : cachedHealthMonitorSnapshots,
          openSnapshot: openHealthMonitorSnapshot
        )

        HomeTimelineSection(
          sleep: homeSnapshot(for: .sleep),
          activity: homeSnapshot(for: .strain),
          recovery: homeSnapshot(for: .recovery),
          activities: model.homeActivityTimelineItems,
          openSleep: { openHealth(.sleep) },
          openActivity: { openHealth(.strain) },
          openRecovery: { openHealth(.recovery) }
        )

      }
      .padding(.horizontal, 16)
      .padding(.vertical, 18)
    }
    .scrollClipDisabled()
    .gooseScreenBackground()
    .navigationTitle("Today")
    .navigationBarTitleDisplayMode(.inline)
    .toolbarBackground(.hidden, for: .navigationBar)
    .overlay(alignment: .top) {
      HomeTopScrollFade()
        .allowsHitTesting(false)
    }
    .safeAreaInset(edge: .bottom, alignment: .trailing) {
      HomeStartActivityFloatingButton(session: model.activitySession)
        .padding(.trailing, 18)
        .padding(.bottom, 10)
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        ScoreDateTitleButton(
          title: homeTitle,
          subtitle: nil,
          action: { showingScoreDatePicker = true }
        )
      }
      ToolbarItem(placement: .topBarTrailing) {
        NavigationLink {
          DeviceView()
        } label: {
          Image(systemName: "applewatch")
            .font(.system(size: 17, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(deviceToolbarTint)
        }
        .accessibilityLabel("Device")
        .accessibilityValue(deviceToolbarAccessibilityValue)
      }
    }
    .onAppear {
      model.recordUIAction("page.opened", detail: "Home")
    }
    .task(id: selectedDate) {
      healthStore.loadBridgeCatalogsIfNeeded()
      model.refreshActivityTimeline(for: selectedDate)
      recomputeHomeState()
    }
    .onChange(of: selectedDate) { _, newValue in
      model.refreshActivityTimeline(for: newValue)
    }
    .onChange(of: model.ble.liveHeartRateBPM) { _, _ in
      recomputeHomeState()
    }
    .onChange(of: healthStore.packetInputStatus) { _, _ in
      recomputeHomeState()
    }
    .onChange(of: healthStore.catalogStatus) { _, _ in
      recomputeHomeState()
    }
    .sheet(isPresented: $showingScoreDatePicker) {
      ScoreDatePickerSheet(
        title: "Daily Scores",
        routes: [.sleep, .recovery, .strain],
        snapshots: scorePickerSnapshots,
        selectedDate: $selectedDate
      )
    }
    .sheet(isPresented: $showingCardioLoadSheet) {
      CardioLoadSheet(store: healthStore)
    }
    .sheet(item: $selectedHealthMonitorTrend) { snapshot in
      SleepV2BevelTrendSheet(snapshot: snapshot)
    }
  }

  private var scoreSnapshots: [HealthMetricSnapshot] {
    [
      datedHomeSnapshot(for: .sleep),
      datedHomeSnapshot(for: .recovery),
      datedHomeSnapshot(for: .strain),
    ]
  }

  private var scorePickerSnapshots: [HealthMetricSnapshot] {
    [
      homeSnapshot(for: .sleep),
      homeSnapshot(for: .recovery),
      homeSnapshot(for: .strain),
    ]
  }

  private var homeTitle: String {
    ScoreDateTimeline.dateLabel(for: selectedDate)
  }

  private var deviceToolbarTint: Color {
    deviceToolbarConnected ? .green : .red
  }

  private var deviceToolbarAccessibilityValue: String {
    deviceToolbarConnected ? "Connected" : "Disconnected"
  }

  private var deviceToolbarConnected: Bool {
    let state = model.ble.connectionState.lowercased()
    return state == "ready" || state == "connected"
  }

  private var dailyActionSummary: String {
    let inputAction = healthStore.metricInputReadinessNextActionSummary()
    if !inputAction.isEmpty {
      return inputAction
    }
    return healthStore.packetDerivedScoreNextActionSummary()
  }

  private func recomputeHomeState() {
    let snapshots = healthStore.landingSnapshots(
      liveHeartRateBPM: model.ble.liveHeartRateBPM,
      liveHeartRateSource: model.ble.liveHeartRateSource,
      liveHeartRateUpdatedAt: model.ble.liveHeartRateUpdatedAt,
      stableDailyMetrics: true
    )
    cachedLandingSnapshots = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.route, $0) })
    cachedCardioLoadDays = healthStore.cardioLoadWeeklyPoints()
    cachedHealthMonitorSnapshots = healthStore.healthMonitorSnapshots(allowLiveFallbacks: false)
    cachedHomeCoachTip = CoachTipFactory.homeTip(healthStore: healthStore, appModel: model)
  }

  private func landingSnapshot(for route: HealthRoute) -> HealthMetricSnapshot {
    cachedLandingSnapshots[route] ?? healthStore.snapshot(for: route)
  }

  private func homeSnapshot(for route: HealthRoute) -> HealthMetricSnapshot {
    let snapshot = landingSnapshot(for: route)
    guard route == .strain, snapshot.unit != "%" else {
      return snapshot
    }
    let rawValue = firstNumber(in: snapshot.displayValue) ?? firstNumber(in: snapshot.value) ?? 0
    let percent = min(max(Int((rawValue / 21 * 100).rounded()), 0), 100)
    return HealthMetricSnapshot(
      id: snapshot.id,
      route: snapshot.route,
      group: snapshot.group,
      title: snapshot.title,
      value: "\(percent)",
      unit: "%",
      status: snapshot.status,
      freshness: snapshot.freshness,
      provenance: snapshot.provenance,
      source: snapshot.source,
      systemImage: snapshot.systemImage,
      tint: snapshot.tint,
      trend: snapshot.trend
    )
  }

  private func datedHomeSnapshot(for route: HealthRoute) -> HealthMetricSnapshot {
    ScoreDateTimeline.datedSnapshot(from: homeSnapshot(for: route), date: selectedDate)
  }

  private func openHealth(_ route: HealthRoute) {
    openHealthRoute(route)
    model.recordUIAction("health.deep_link.opened", detail: route.title)
  }

  private func openHealthMonitorSnapshot(_ snapshot: HealthMetricSnapshot) {
    if snapshot.id == "resting-hr" {
      selectedHealthMonitorTrend = snapshot
    } else {
      openHealth(.healthMonitor)
    }
  }

  private func openCoach(_ prompt: String) {
    router.openCoach(prompt: prompt)
    model.recordUIAction("coach.opened", detail: "Home daily score card")
  }
}

