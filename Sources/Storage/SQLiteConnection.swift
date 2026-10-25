import Core
import Foundation
import SQLite3

public enum StorageError: Error, CustomStringConvertible {
  case busy(String)
  case broken(String)
  case constraint(String)
  init(_ description: String) { self = .broken(description) }
  public var description: String {
    switch self {
    case .busy(let message), .broken(let message), .constraint(let message): return message
    }
  }
}

enum SQLValue {
  case integer(Int)
  case text(String)
  case key(String)
  case maskedText(String)
  case null
}

struct DatabaseRow {
  private let values: [String: SQLValue]
  init(_ statement: OpaquePointer) {
    var values: [String: SQLValue] = [:]
    for index in 0..<sqlite3_column_count(statement) {
      let name = String(cString: sqlite3_column_name(statement, index))
      switch sqlite3_column_type(statement, index) {
      case SQLITE_NULL: values[name] = .null
      case SQLITE_INTEGER: values[name] = .integer(SQLiteConnection.int(statement, index))
      default: values[name] = .text(SQLiteConnection.text(statement, index))
      }
    }
    self.values = values
  }
  func value(_ name: String) throws -> SQLValue {
    guard let value = values[name] else { throw StorageError("Missing column: \(name)") }
    return value
  }
  func int(_ name: String) throws -> Int {
    if case .integer(let value) = try value(name) { return value }
    return 0
  }
  func optionalText(_ name: String) throws -> String? {
    if case .text(let value) = try value(name) { return value }
    return nil
  }
  func text(_ name: String) throws -> String { try optionalText(name) ?? "" }
}

final class SQLiteConnection {
  var handle: OpaquePointer?
  private let busyMilliseconds: Int32
  init(url: URL, readOnly: Bool = false, immutable: Bool = false, scope: DatabaseOpenScope, busyMilliseconds: Int32 = 3000) throws {
    self.busyMilliseconds = busyMilliseconds
    guard try DatabaseOpenBoundary.open(url, scope: scope,
      readOnly: readOnly, immutable: immutable, handle: &handle) == SQLITE_OK else {
      let error = failure()
      sqlite3_close(handle)
      handle = nil
      throw error
    }
    sqlite3_busy_timeout(handle, busyMilliseconds)
  }
  deinit { sqlite3_close(handle) }
  func close() throws {
    guard sqlite3_close(handle) == SQLITE_OK else { throw failure() }
    handle = nil
  }
  /// A snapshot can prevent truncation. Limit this attempt to 25 ms, then restore the caller's wait.
  func truncateWAL() -> Bool {
    sqlite3_busy_timeout(handle, min(busyMilliseconds, 25))
    defer { sqlite3_busy_timeout(handle, busyMilliseconds) }
    var logFrames: Int32 = -1
    var checkpointed: Int32 = -1
    let result = sqlite3_wal_checkpoint_v2(handle, nil, SQLITE_CHECKPOINT_TRUNCATE, &logFrames, &checkpointed)
    return result == SQLITE_OK && logFrames == 0 && checkpointed == 0
  }
  func failure() -> StorageError {
    let message = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "Database unavailable"
    let code = sqlite3_errcode(handle)
    if code == SQLITE_BUSY || code == SQLITE_LOCKED { return .busy(message) }
    return code == SQLITE_CONSTRAINT ? .constraint(message) : .broken(message)
  }
  func run(_ sql: String, _ values: [SQLValue] = []) throws {
    try rows(sql, values) { _ in }
  }
  func rows(_ sql: String, _ values: [SQLValue] = [], _ visit: (OpaquePointer) throws -> Void) throws {
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw failure() }
    defer { sqlite3_finalize(statement) }
    for (offset, value) in values.enumerated() {
      let index = Int32(offset + 1)
      let result: Int32
      switch value {
      case .integer(let number): result = sqlite3_bind_int64(statement, index, Int64(number))
      case .null: result = sqlite3_bind_null(statement, index)
      case .text(let text), .key(let text), .maskedText(let text):
        // Lookup keys must retain identity. Only keys use .key; every free-text value is masked.
        let masked: String
        if case .text = value { masked = Redaction.apply(text).text }
        else if case .key = value { masked = Redaction.applyKnownSecrets(text).text }
        else { masked = text }
        result = masked.withCString {
          sqlite3_bind_text(
            statement, index, $0, Int32(masked.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
      }
      guard result == SQLITE_OK else { throw failure() }
    }
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      try visit(statement)
      result = sqlite3_step(statement)
    }
    guard result == SQLITE_DONE else { throw failure() }
  }
  func namedRows(_ sql: String, _ values: [SQLValue] = [], _ visit: (DatabaseRow) throws -> Void) throws {
    try rows(sql, values) { try visit(DatabaseRow($0)) }
  }
  func integer(_ sql: String, _ values: [SQLValue] = []) throws -> Int {
    var value = 0
    try rows(sql, values) { value = Self.int($0, 0) }
    return value
  }
  func transaction<T>(write: Bool = true, _ body: () throws -> T) throws -> T {
    try run(write ? "BEGIN IMMEDIATE" : "BEGIN")
    do {
      let result = try body()
      try run("COMMIT")
      return result
    } catch {
      try? run("ROLLBACK")
      throw error
    }
  }
  static func int(_ s: OpaquePointer, _ c: Int32) -> Int { Int(sqlite3_column_int64(s, c)) }
  static func text(_ s: OpaquePointer, _ c: Int32) -> String {
    guard let text = sqlite3_column_text(s, c) else { return "" }
    let bytes = UnsafeBufferPointer(start: text, count: Int(sqlite3_column_bytes(s, c)))
    return String(decoding: bytes, as: UTF8.self)
  }
  static func optionalText(_ s: OpaquePointer, _ c: Int32) -> String? {
    sqlite3_column_type(s, c) == SQLITE_NULL ? nil : text(s, c)
  }
}
