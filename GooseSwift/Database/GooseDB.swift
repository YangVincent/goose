import Foundation
import SQLite3

// MARK: - Errors

enum GooseDBError: Error, CustomStringConvertible {
  case openFailed(path: String, message: String)
  case prepareFailed(sql: String, message: String)
  case stepFailed(sql: String, message: String)
  case bindFailed(column: Int32, message: String)
  case typeMismatch(column: Int32, expected: String)
  case noRow

  var description: String {
    switch self {
    case .openFailed(let path, let msg): return "openFailed(\(path)): \(msg)"
    case .prepareFailed(let sql, let msg): return "prepareFailed: \(msg) — SQL: \(sql.prefix(200))"
    case .stepFailed(let sql, let msg): return "stepFailed: \(msg) — SQL: \(sql.prefix(200))"
    case .bindFailed(let col, let msg): return "bindFailed(col=\(col)): \(msg)"
    case .typeMismatch(let col, let expected): return "typeMismatch(col=\(col)): expected \(expected)"
    case .noRow: return "noRow"
    }
  }
}

// MARK: - Values

/// A value that can be bound to a SQL parameter or read out of a result row.
/// Mirrors `rusqlite::types::Value`. Adding cases is rare — these are the
/// only SQLite types.
enum GooseDBValue: Equatable {
  case null
  case integer(Int64)
  case real(Double)
  case text(String)
  case blob(Data)

  static func from(_ value: Any?) -> GooseDBValue {
    switch value {
    case nil, is NSNull: return .null
    case let v as Int64: return .integer(v)
    case let v as Int: return .integer(Int64(v))
    case let v as Bool: return .integer(v ? 1 : 0)
    case let v as Double: return .real(v)
    case let v as Float: return .real(Double(v))
    case let v as String: return .text(v)
    case let v as Data: return .blob(v)
    case let v as NSNumber:
      // Heuristic: NSNumber may represent int or double — favor double for
      // values with a fractional component, int otherwise.
      let d = v.doubleValue
      if d.rounded() == d && abs(d) < Double(Int64.max) {
        return .integer(v.int64Value)
      }
      return .real(d)
    default: return .null
    }
  }
}

// MARK: - Row

/// A single result row from a prepared statement step. Indexed access by
/// column position (`row.int(0)`) or by column name (`row.string("date_key")`).
struct GooseDBRow {
  fileprivate let stmt: OpaquePointer
  fileprivate let columnIndex: [String: Int32]

  func value(at column: Int32) -> GooseDBValue {
    let type = sqlite3_column_type(stmt, column)
    switch type {
    case SQLITE_NULL: return .null
    case SQLITE_INTEGER: return .integer(sqlite3_column_int64(stmt, column))
    case SQLITE_FLOAT: return .real(sqlite3_column_double(stmt, column))
    case SQLITE_TEXT:
      if let cString = sqlite3_column_text(stmt, column) {
        return .text(String(cString: cString))
      }
      return .text("")
    case SQLITE_BLOB:
      let bytes = sqlite3_column_blob(stmt, column)
      let count = Int(sqlite3_column_bytes(stmt, column))
      if let bytes, count > 0 {
        return .blob(Data(bytes: bytes, count: count))
      }
      return .blob(Data())
    default:
      return .null
    }
  }

  func value(named column: String) -> GooseDBValue {
    guard let idx = columnIndex[column] else { return .null }
    return value(at: idx)
  }

  // Typed accessors — return optionals because the column could be NULL
  // even when it has a "non-nullable" declared type at the schema level
  // (SQLite is loose about that).
  func int(_ column: Int32) -> Int64? {
    switch value(at: column) {
    case .integer(let v): return v
    case .real(let v): return Int64(v)
    case .null: return nil
    default: return nil
    }
  }
  func intRequired(_ column: Int32) throws -> Int64 {
    if let v = int(column) { return v }
    throw GooseDBError.typeMismatch(column: column, expected: "Int64")
  }
  func double(_ column: Int32) -> Double? {
    switch value(at: column) {
    case .real(let v): return v
    case .integer(let v): return Double(v)
    case .null: return nil
    default: return nil
    }
  }
  func string(_ column: Int32) -> String? {
    switch value(at: column) {
    case .text(let v): return v
    case .null: return nil
    default: return nil
    }
  }
  func data(_ column: Int32) -> Data? {
    switch value(at: column) {
    case .blob(let v): return v
    case .null: return nil
    default: return nil
    }
  }

  // Name-keyed sugar for the most common reads.
  func int(_ column: String) -> Int64? {
    columnIndex[column].flatMap(int)
  }
  func double(_ column: String) -> Double? {
    columnIndex[column].flatMap(double)
  }
  func string(_ column: String) -> String? {
    columnIndex[column].flatMap(string)
  }
}

// MARK: - Statement

/// A prepared statement. Bind, step, and read rows out. Mirrors
/// `rusqlite::Statement` — `query_map(...)` returns an Array, `query_one`
/// returns the first row (or throws), `execute(...)` runs an INSERT/UPDATE
/// /DELETE and returns the changed-row count.
final class GooseDBStatement {
  fileprivate let stmt: OpaquePointer
  fileprivate let sql: String
  fileprivate let columnIndex: [String: Int32]

  fileprivate init(stmt: OpaquePointer, sql: String) {
    self.stmt = stmt
    self.sql = sql
    var byName: [String: Int32] = [:]
    let n = sqlite3_column_count(stmt)
    for i in 0..<n {
      if let cName = sqlite3_column_name(stmt, i) {
        byName[String(cString: cName)] = i
      }
    }
    self.columnIndex = byName
  }

  deinit {
    sqlite3_finalize(stmt)
  }

  // MARK: Binding

  func bind(_ params: [GooseDBValue]) throws {
    sqlite3_reset(stmt)
    sqlite3_clear_bindings(stmt)
    for (idx, value) in params.enumerated() {
      let col = Int32(idx + 1) // SQLite param indices are 1-based.
      try bind(col: col, value: value)
    }
  }

  /// Convenience: bind from heterogeneous Swift values.
  func bind(_ params: [Any?]) throws {
    try bind(params.map(GooseDBValue.from))
  }

  private func bind(col: Int32, value: GooseDBValue) throws {
    let rc: Int32
    switch value {
    case .null:
      rc = sqlite3_bind_null(stmt, col)
    case .integer(let v):
      rc = sqlite3_bind_int64(stmt, col, v)
    case .real(let v):
      rc = sqlite3_bind_double(stmt, col, v)
    case .text(let v):
      // SQLITE_TRANSIENT = -1 — copy the string immediately so the buffer
      // can be released after this call. Required for safety.
      rc = sqlite3_bind_text(stmt, col, v, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    case .blob(let v):
      rc = v.withUnsafeBytes { raw in
        sqlite3_bind_blob(
          stmt, col, raw.baseAddress, Int32(v.count),
          unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        )
      }
    }
    if rc != SQLITE_OK {
      throw GooseDBError.bindFailed(column: col, message: "rc=\(rc)")
    }
  }

  // MARK: Stepping

  /// Step the statement once. Returns true if a row is available, false if
  /// the statement is done. Throws on error.
  @discardableResult
  func step() throws -> Bool {
    let rc = sqlite3_step(stmt)
    switch rc {
    case SQLITE_ROW: return true
    case SQLITE_DONE: return false
    default:
      let msg = sqlite3_errmsg(sqlite3_db_handle(stmt)).map { String(cString: $0) } ?? "rc=\(rc)"
      throw GooseDBError.stepFailed(sql: sql, message: msg)
    }
  }

  func currentRow() -> GooseDBRow {
    GooseDBRow(stmt: stmt, columnIndex: columnIndex)
  }

  /// Run as a value-yielding query, mapping each row via `mapper`. The
  /// statement is reset before iteration so the same Statement can be
  /// reused with new bindings.
  func queryMap<T>(_ mapper: (GooseDBRow) throws -> T) throws -> [T] {
    var out: [T] = []
    while try step() {
      out.append(try mapper(currentRow()))
    }
    return out
  }

  /// Run a query that expects at most one row. Returns nil if no row.
  func queryFirst<T>(_ mapper: (GooseDBRow) throws -> T) throws -> T? {
    if try step() {
      return try mapper(currentRow())
    }
    return nil
  }

  /// Execute an INSERT/UPDATE/DELETE. Returns the number of changed rows.
  @discardableResult
  func execute() throws -> Int {
    while try step() { /* consume any side rows (rare) */ }
    return Int(sqlite3_changes(sqlite3_db_handle(stmt)))
  }
}

// MARK: - Connection

/// Owns an SQLite connection. Thread-safety: every operation is dispatched
/// through a serial queue so the underlying handle is only touched from one
/// thread at a time. Mirrors rusqlite's single-handle / single-writer
/// pattern. For UI threads that don't want to block, wrap calls in a
/// Task.detached.
///
/// The connection opens in WAL mode for better concurrency between the
/// app's reads and the background-task writes. Foreign keys are enforced.
final class GooseDB {
  private var handle: OpaquePointer?
  private let queue = DispatchQueue(label: "goose.db.serial")
  let path: String

  init(path: String) throws {
    self.path = path
    var db: OpaquePointer?
    let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
    let rc = sqlite3_open_v2(path, &db, flags, nil)
    guard rc == SQLITE_OK, let db else {
      let msg = sqlite3_errmsg(db).map { String(cString: $0) } ?? "rc=\(rc)"
      sqlite3_close_v2(db)
      throw GooseDBError.openFailed(path: path, message: msg)
    }
    self.handle = db
    // Standard pragmas — WAL for concurrent reads, foreign keys on,
    // synchronous NORMAL is a sane balance (FULL is too slow, OFF is unsafe).
    try execute("PRAGMA journal_mode=WAL")
    try execute("PRAGMA foreign_keys=ON")
    try execute("PRAGMA synchronous=NORMAL")
    try execute("PRAGMA temp_store=MEMORY")
  }

  deinit {
    if let handle { sqlite3_close_v2(handle) }
  }

  /// Compile a SQL statement. Reuse across calls when possible — preparing
  /// is the expensive part.
  func prepare(_ sql: String) throws -> GooseDBStatement {
    try queue.sync {
      guard let handle else {
        throw GooseDBError.openFailed(path: path, message: "handle nil")
      }
      var stmt: OpaquePointer?
      let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
      guard rc == SQLITE_OK, let stmt else {
        let msg = sqlite3_errmsg(handle).map { String(cString: $0) } ?? "rc=\(rc)"
        throw GooseDBError.prepareFailed(sql: sql, message: msg)
      }
      return GooseDBStatement(stmt: stmt, sql: sql)
    }
  }

  /// One-shot execute with no bindings. For multi-statement scripts
  /// (separated by `;`), uses sqlite3_exec which handles them in one call.
  @discardableResult
  func execute(_ sql: String) throws -> Int {
    try queue.sync {
      guard let handle else {
        throw GooseDBError.openFailed(path: path, message: "handle nil")
      }
      var errMsg: UnsafeMutablePointer<CChar>?
      let rc = sqlite3_exec(handle, sql, nil, nil, &errMsg)
      if rc != SQLITE_OK {
        let msg = errMsg.map { String(cString: $0) } ?? "rc=\(rc)"
        sqlite3_free(errMsg)
        throw GooseDBError.stepFailed(sql: sql, message: msg)
      }
      return Int(sqlite3_changes(handle))
    }
  }

  /// Convenience: prepare + bind + step-once + map. For single-row reads
  /// (e.g. `SELECT COUNT(*) FROM x`).
  func queryFirst<T>(
    _ sql: String,
    params: [Any?] = [],
    _ mapper: (GooseDBRow) throws -> T
  ) throws -> T? {
    let stmt = try prepare(sql)
    try stmt.bind(params)
    return try stmt.queryFirst(mapper)
  }

  /// Convenience: prepare + bind + iterate. For bounded result sets.
  func queryMap<T>(
    _ sql: String,
    params: [Any?] = [],
    _ mapper: (GooseDBRow) throws -> T
  ) throws -> [T] {
    let stmt = try prepare(sql)
    try stmt.bind(params)
    return try stmt.queryMap(mapper)
  }

  /// Convenience: prepare + bind + execute. For INSERT/UPDATE/DELETE.
  @discardableResult
  func executeStatement(_ sql: String, params: [Any?] = []) throws -> Int {
    let stmt = try prepare(sql)
    try stmt.bind(params)
    return try stmt.execute()
  }

  /// Run `block` inside a single transaction. Commits on normal return,
  /// rolls back on thrown error.
  func transaction<T>(_ block: () throws -> T) throws -> T {
    try execute("BEGIN")
    do {
      let value = try block()
      try execute("COMMIT")
      return value
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  /// Schema-introspection helper — does `table` have a column named
  /// `column`? Used by migration code to make ALTER TABLE idempotent.
  func tableHasColumn(_ table: String, column: String) -> Bool {
    do {
      let rows = try queryMap("PRAGMA table_info(\(table))") { row in
        row.string(1) ?? ""
      }
      return rows.contains(column)
    } catch {
      return false
    }
  }

  /// PRAGMA user_version, used as our schema_version counter. Mirrors
  /// what the Rust side reads — same column, same meaning.
  func schemaVersion() throws -> Int {
    let n = try queryFirst("PRAGMA user_version") { row in
      row.int(0) ?? 0
    } ?? 0
    return Int(n)
  }

  func setSchemaVersion(_ version: Int) throws {
    try execute("PRAGMA user_version = \(version)")
  }
}
