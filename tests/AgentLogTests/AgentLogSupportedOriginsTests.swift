@testable import Core
@testable import Storage
import Foundation
import XCTest

extension AgentLogTests {
  /// Turn an invented fixture into main's channel shape while retaining every main table value.
  func makeMainLogOrigin(_ storage: ActivityStorage) throws {
    var objects: [(String, String)] = []
    try storage.connection.namedRows("""
      SELECT type,name FROM sqlite_master WHERE type IN ('view','trigger','table','index')
      AND (name GLOB 'agent_log_*' OR name GLOB 'agent_prompt_*' OR name IN ('log_positions_session','log_positions_ownership_session'))
      ORDER BY CASE type WHEN 'trigger' THEN 0 WHEN 'view' THEN 1 WHEN 'index' THEN 2 ELSE 3 END
      """) { objects.append((try $0.text("type"), try $0.text("name"))) }
    for (type, name) in objects { try storage.connection.run("DROP \(type) IF EXISTS \"\(name)\"") }
    var positions: [(String, String)] = []
    try storage.connection.namedRows("SELECT path,state FROM log_positions") { positions.append((try $0.text("path"), try $0.text("state"))) }
    let mainKeys: Set<String> = ["session", "project", "folder", "threadID", "queued", "ignoredSession", "metadataRead", "ownWorkingFolder"]
    for (path, state) in positions {
      let object = try JSONSerialization.jsonObject(with: Data(state.utf8)) as! [String: Any]
      let main = object.filter { mainKeys.contains($0.key) }
      let encoded = String(decoding: try JSONSerialization.data(withJSONObject: main, options: .sortedKeys), as: UTF8.self)
      try storage.connection.run("UPDATE log_positions SET state=? WHERE path=?", [.maskedText(encoded), .key(path)])
    }
    try storage.connection.run("PRAGMA user_version=9")
  }

  func testSupportedOriginsRejectUndeployedSchemasAndCheckpointVersions() throws {
    for version in [10, 11, 12] {
      try store.connection.run("PRAGMA user_version=\(version)")
      XCTAssertThrowsError(try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"),
        appDataDirectory: root, databaseScope: .directory(root)))
    }
    try store.connection.run("PRAGMA user_version=\(SQLiteConnection.schemaVersion)")
    for version in 1...4 { XCTAssertThrowsError(try AgentLogState.decode("{\"metadataVersion\":\(version)}")) }
    for version in [0, 5] { XCTAssertNoThrow(try AgentLogState.decode("{\"metadataVersion\":\(version)}")) }
    for version in 0..<6 {
      var scanner = AgentLogMetadata()
      for byte in "{\"ignored\":\"".utf8 { scanner.consume(byte) }
      var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(scanner)) as! [String: Any]
      object["version"] = version
      let state: [String: Any] = ["metadataVersion": 5, "metadataRecoveryScanner": object]
      let data = try JSONSerialization.data(withJSONObject: state)
      XCTAssertThrowsError(try JSONDecoder().decode(AgentLogState.self, from: data))
    }
  }
}
