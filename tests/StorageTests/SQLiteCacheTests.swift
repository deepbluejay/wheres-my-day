import Foundation
import SQLite3
@testable import Storage
import XCTest

final class SQLiteCacheTests: XCTestCase {
  func testWriterAndReadOnlySnapshotSpillLargeTempStages() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("invented.sqlite")
    let writer = try SQLiteConnection(url: url, scope: .directory(root))
    try writer.run("CREATE TABLE invented(value INTEGER)")
    let snapshot = try SQLiteConnection(url: url, readOnly: true, scope: .directory(root))
    for connection in [writer, snapshot] {
      XCTAssertEqual(try connection.integer("PRAGMA main.cache_size"), -1024)
      XCTAssertEqual(try connection.integer("PRAGMA main.cache_spill"), 256)
      XCTAssertEqual(try connection.integer("PRAGMA temp_store"), 1)
      XCTAssertEqual(try connection.integer("PRAGMA temp.cache_size"), -1024)
      XCTAssertEqual(try connection.integer("PRAGMA temp.cache_spill"), 256)
      try connection.run("CREATE TEMP TABLE invented_stage(ordinal INTEGER PRIMARY KEY,payload BLOB)")
      let block = Data(repeating: 120, count: 65536)
      // Even an open snapshot transaction must spill, rather than retain its dirty TEMP pages.
      try connection.transaction(write: false) {
        for ordinal in 0..<128 {
          try connection.run("INSERT INTO invented_stage VALUES(?,?)", [.integer(ordinal), .maskedBlob(block)])
          var current: Int32 = 0, high: Int32 = 0
          XCTAssertEqual(sqlite3_db_status(connection.handle, SQLITE_DBSTATUS_CACHE_USED, &current, &high, 0), SQLITE_OK)
          XCTAssertLessThan(current, 2 << 20)
        }
        XCTAssertEqual(try connection.integer("SELECT sum(length(payload)) FROM invented_stage"), 8 << 20)
      }
    }
  }
}
