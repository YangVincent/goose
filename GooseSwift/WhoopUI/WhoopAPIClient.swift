import Foundation

struct WhoopOverview: Codable {
  let whoop: WhoopDay?

  struct WhoopDay: Codable {
    let recovery: Recovery?
    let sleep: Sleep?
    let strain: Strain?

    init(recovery: Recovery?, sleep: Sleep?, strain: Strain?) {
      self.recovery = recovery
      self.sleep = sleep
      self.strain = strain
    }
  }
}

struct WhoopDayResponse: Codable {
  let date: String?
  let recovery: WhoopOverview.Recovery?
  let sleep: WhoopOverview.Sleep?
  let strain: WhoopOverview.Strain?

  var asDay: WhoopOverview.WhoopDay {
    WhoopOverview.WhoopDay(recovery: recovery, sleep: sleep, strain: strain)
  }
}

struct WhoopHealthspan: Codable {
  let window_days: Int?
  let sleep_consistency_pct_30d: Double?
  let sleep_hours_30d: Double?
  let rhr_30d: Double?
  let hr_zones_1_3_weekly_hours: Double?
  let hr_zones_4_5_weekly_hours: Double?
  let strength_weekly_minutes: Double?
  let vo2_max_estimate: Double?
  let max_hr: Int?
}

struct WhoopActivity: Codable, Identifiable {
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

struct WhoopCalendar: Codable {
  let month: String?
  let dates: [DateEntry]
  let workout_dates: [String]?

  struct DateEntry: Codable, Identifiable {
    let date: String
    let recovery_score: Double?
    var id: String { date }
  }
}

extension WhoopOverview {
  struct Recovery: Codable {
    let start: String?
    let recovery_score: Double?
    let resting_heart_rate: Double?
    let hrv_rmssd_milli: Double?
    let spo2_percentage: Double?
    let skin_temp_celsius: Double?
  }

  struct Sleep: Codable {
    let start: String?
    let end: String?
    let performance: Double?
    let efficiency: Double?
    let stage_summary: StageSummary?
    let sleep_needed: SleepNeeded?
  }

  struct StageSummary: Codable {
    let total_in_bed_time_milli: Int?
    let total_awake_time_milli: Int?
    let total_light_sleep_time_milli: Int?
    let total_slow_wave_sleep_time_milli: Int?
    let total_rem_sleep_time_milli: Int?
    let sleep_cycle_count: Int?
    let disturbance_count: Int?
  }

  struct SleepNeeded: Codable {
    let baseline_milli: Int?
    let need_from_sleep_debt_milli: Int?
    let need_from_recent_strain_milli: Int?
    let need_from_recent_nap_milli: Int?
  }

  struct Strain: Codable {
    let strain: Double?
    let kilojoule: Double?
  }
}

@MainActor
final class WhoopAPIClient: ObservableObject {
  static let shared = WhoopAPIClient()

  @Published private(set) var currentDay: WhoopOverview.WhoopDay?
  @Published private(set) var currentDate: Date = Date()
  @Published private(set) var calendar: WhoopCalendar?
  @Published private(set) var recoveryHistory: [WhoopOverview.Recovery] = []
  @Published private(set) var activities: [WhoopActivity] = []
  @Published private(set) var healthspan: WhoopHealthspan?
  @Published private(set) var lastError: String?
  @Published private(set) var isLoading = false
  @Published private(set) var lastFetchedAt: Date?

  private let baseURL = URL(string: "https://aeonneo.com/health")!
  private let session: URLSession
  private let dateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.dateFormat = "yyyy-MM-dd"
    f.timeZone = TimeZone.current
    return f
  }()

  init() {
    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 12
    config.timeoutIntervalForResource = 20
    config.urlCache = nil
    self.session = URLSession(configuration: config)
  }

  func loadDay(_ date: Date) async {
    currentDate = date
    isLoading = true
    defer { isLoading = false }
    let dateStr = dateFormatter.string(from: date)
    guard var components = URLComponents(string: "https://aeonneo.com/health/api/whoop/day") else {
      lastError = "Bad URL components"
      return
    }
    components.queryItems = [URLQueryItem(name: "date", value: dateStr)]
    guard let url = components.url else {
      lastError = "Could not build URL"
      return
    }
    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        lastError = "Bad status \(code) for \(url.absoluteString)"
        return
      }
      let decoded = try JSONDecoder().decode(WhoopDayResponse.self, from: data)
      currentDay = decoded.asDay
      lastFetchedAt = Date()
      lastError = nil
    } catch {
      // URLError.cancelled fires whenever the parent view's .task is
      // invalidated mid-fetch (navigation, re-mount). It's never a real
      // failure — swallow it so the UI doesn't flash a misleading banner.
      if (error as? URLError)?.code == .cancelled || error is CancellationError {
        return
      }
      lastError = "loadDay(\(dateStr)) failed: \(error.localizedDescription)"
    }
  }

  func loadRecoveryHistory() async {
    let url = baseURL.appendingPathComponent("api/whoop")
    do {
      let (data, _) = try await session.data(from: url)
      struct Wrapper: Codable { let recovery: [WhoopOverview.Recovery] }
      let wrapped = try JSONDecoder().decode(Wrapper.self, from: data)
      recoveryHistory = wrapped.recovery
    } catch {
      // supplemental; ignore errors
    }
  }

  func loadHealthspan() async {
    guard let url = URL(string: "https://aeonneo.com/health/api/whoop/healthspan") else { return }
    do {
      let (data, _) = try await session.data(from: url)
      healthspan = try JSONDecoder().decode(WhoopHealthspan.self, from: data)
    } catch {
      // supplemental; ignore
    }
  }

  func loadActivities() async {
    guard let url = URL(string: "https://aeonneo.com/health/api/activities") else { return }
    do {
      let (data, _) = try await session.data(from: url)
      activities = try JSONDecoder().decode([WhoopActivity].self, from: data)
    } catch {
      // supplemental; ignore
    }
  }

  func loadCalendar() async {
    let url = baseURL.appendingPathComponent("api/whoop/calendar")
    do {
      let (data, _) = try await session.data(from: url)
      calendar = try JSONDecoder().decode(WhoopCalendar.self, from: data)
    } catch {
      // calendar is supplemental; ignore errors
    }
  }

  func recoveryScore(forISODate isoDate: String) -> Double? {
    calendar?.dates.first { $0.date == isoDate }?.recovery_score
  }

  func hasWorkout(onISODate isoDate: String) -> Bool {
    calendar?.workout_dates?.contains(isoDate) ?? false
  }

  func isoDate(_ date: Date) -> String {
    dateFormatter.string(from: date)
  }
}
