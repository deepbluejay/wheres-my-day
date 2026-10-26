import Foundation
import SQLite3

/// SQLite's automatically deleted temporary database provides an external ordered
/// manifest. One directory scan, a 64 KiB page cache, and one path per cursor row.
/// It contains filenames only. Payloads never enter the manifest or page cache.
final class CollectionFileCursor {
  private var database: OpaquePointer?
  private var building = true
  private var after: String?
  init() throws {
    guard sqlite3_open("", &database) == SQLITE_OK else { throw StorageError("Collection cursor unavailable") }
    do {
      try run("PRAGMA cache_size=-64")
      try run("PRAGMA journal_mode=OFF")
      try run("CREATE TABLE leaves(name TEXT PRIMARY KEY) WITHOUT ROWID")
      try run("BEGIN")
    } catch { sqlite3_close(database); database = nil; throw error }
  }
  deinit { sqlite3_close(database) }
  private func run(_ sql: String) throws {
    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw StorageError("Collection cursor unavailable") }
  }
  func add(_ name: String) throws {
    var insert: OpaquePointer?
    guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO leaves VALUES(?)", -1, &insert, nil) == SQLITE_OK else { throw StorageError("Collection cursor unavailable") }
    defer { sqlite3_finalize(insert) }
    let bound = name.withCString { sqlite3_bind_text(insert, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    guard bound == SQLITE_OK, sqlite3_step(insert) == SQLITE_DONE else { throw StorageError("Collection cursor unavailable") }
  }
  private func finishBuilding() throws {
    if building { try run("COMMIT"); building = false }
  }
  func batch(limit: Int) throws -> [String] {
    try finishBuilding()
    var result: [String] = [], statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "SELECT name FROM leaves WHERE name>? ORDER BY name LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw StorageError("Collection cursor unavailable") }
    defer { sqlite3_finalize(statement) }
    let bound = (after ?? "").withCString { sqlite3_bind_text(statement, 1, $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
    guard bound == SQLITE_OK, sqlite3_bind_int64(statement, 2, Int64(limit)) == SQLITE_OK else { throw StorageError("Collection cursor unavailable") }
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW { result.append(String(cString: sqlite3_column_text(statement, 0))); step = sqlite3_step(statement) }
    guard step == SQLITE_DONE else { throw StorageError("Collection cursor unavailable") }
    return result
  }
  func acknowledge(_ name: String) { after = name }
  func visit(_ body: (String) throws -> Void) throws {
    while true {
      let names = try batch(limit: 64)
      if names.isEmpty { break }
      for name in names { try body(name); acknowledge(name) }
    }
  }
}
