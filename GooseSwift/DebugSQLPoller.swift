import Foundation

/// On-device SQL query bridge for development. Watches the app's
/// `Documents/debug_queries/` directory for `.sql` files, executes each
/// via the Rust `debug.run_sql` bridge, and writes the JSON result to
/// `Documents/debug_results/<basename>.json`. The Mac drops queries
/// via `xcrun devicectl device copy to ...` and pulls results via
/// `... copy from ...`.
///
/// Much faster than full DB pulls: a targeted SELECT round-trips in
/// 5-10s vs the 2-3 minutes (and flaky network) needed to copy the
/// 2.6 GB sqlite file. Eliminates ~80% of dev-loop friction during
/// data investigations.
///
/// Debug-only: the poller is only started in DEBUG builds. The Rust
/// side also enforces SELECT/WITH/PRAGMA/EXPLAIN to refuse mutations,
/// so even an accidental release-build start can't damage data.
@MainActor
final class DebugSQLPoller {
  static let shared = DebugSQLPoller()

  private let bridge = GooseRustBridge()
  private var timer: Timer?
  private let pollInterval: TimeInterval = 2
  private var inFlight = Set<String>()
  private let fm = FileManager.default

  private lazy var documentsURL: URL = {
    fm.urls(for: .documentDirectory, in: .userDomainMask).first
      ?? fm.temporaryDirectory
  }()
  private var queriesDir: URL { documentsURL.appendingPathComponent("debug_queries", isDirectory: true) }
  private var resultsDir: URL { documentsURL.appendingPathComponent("debug_results", isDirectory: true) }
  private var processedDir: URL { documentsURL.appendingPathComponent("debug_processed", isDirectory: true) }

  func start() {
    #if DEBUG
    ensureDirectory(queriesDir)
    ensureDirectory(resultsDir)
    ensureDirectory(processedDir)
    timer?.invalidate()
    timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.pollOnce() }
    }
    if let timer { RunLoop.main.add(timer, forMode: .common) }
    NSLog("[DebugSQLPoller] watching \(queriesDir.path) every \(pollInterval)s")
    #endif
  }

  func stop() {
    timer?.invalidate()
    timer = nil
  }

  private func ensureDirectory(_ url: URL) {
    if !fm.fileExists(atPath: url.path) {
      try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }
  }

  private func pollOnce() {
    guard let entries = try? fm.contentsOfDirectory(at: queriesDir, includingPropertiesForKeys: nil) else {
      return
    }
    for entry in entries where entry.pathExtension == "sql" {
      let key = entry.lastPathComponent
      if inFlight.contains(key) { continue }
      inFlight.insert(key)
      Task.detached(priority: .userInitiated) { [weak self] in
        await self?.processQuery(at: entry)
        await MainActor.run { self?.inFlight.remove(key) }
      }
    }
  }

  private func processQuery(at url: URL) async {
    let basename = url.deletingPathExtension().lastPathComponent
    let resultURL = await MainActor.run { resultsDir.appendingPathComponent("\(basename).json") }
    let processedURL = await MainActor.run { processedDir.appendingPathComponent(url.lastPathComponent) }
    let sql: String
    do {
      sql = try String(contentsOf: url, encoding: .utf8)
    } catch {
      await write(jsonError: "read failed: \(error.localizedDescription)", to: resultURL)
      return
    }
    let dbPath = await MainActor.run { HealthDataStore.defaultDatabasePath() }
    let bridge = self.bridge
    let response: Any
    do {
      response = try bridge.request(
        method: "debug.run_sql",
        args: ["database_path": dbPath, "sql": sql, "row_limit": 5000]
      )
    } catch {
      await write(jsonError: "bridge call failed: \(error.localizedDescription)", to: resultURL)
      await moveProcessed(from: url, to: processedURL)
      return
    }
    let data: Data
    do {
      data = try JSONSerialization.data(withJSONObject: response, options: [.prettyPrinted, .sortedKeys])
    } catch {
      await write(jsonError: "encode failed: \(error.localizedDescription)", to: resultURL)
      await moveProcessed(from: url, to: processedURL)
      return
    }
    try? data.write(to: resultURL, options: .atomic)
    await moveProcessed(from: url, to: processedURL)
  }

  private func write(jsonError message: String, to url: URL) async {
    let obj: [String: Any] = ["error": message]
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
      try? data.write(to: url, options: .atomic)
    }
  }

  private func moveProcessed(from src: URL, to dst: URL) async {
    try? fm.removeItem(at: dst)
    do {
      try fm.moveItem(at: src, to: dst)
    } catch {
      try? fm.removeItem(at: src)
    }
  }
}
