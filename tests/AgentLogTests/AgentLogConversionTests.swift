import Core
import CryptoKit
import Foundation
import XCTest

@testable import Inbound
@testable import Shell
@testable import Storage

extension AgentLogTests {
  func oldLogsDatabase(_ name: String) throws -> URL {
    let url = root.appendingPathComponent(name + ".sqlite")
    let db = try SQLiteConnection(url: url, scope: .directory(root))
    try db.run("""
      CREATE TABLE evidence(id INTEGER PRIMARY KEY,ts INTEGER,bundle_id TEXT,doc_key TEXT,
        kind TEXT,role TEXT,text TEXT,source_id TEXT,project TEXT)
      """)
    try db.run("""
      CREATE TABLE log_cursors(path TEXT,device INTEGER,inode INTEGER,offset INTEGER,state TEXT,seen_ts INTEGER)
      """)
    try db.run("CREATE TABLE forgotten(start_ts INTEGER,end_ts INTEGER)")
    try db.run("CREATE TABLE forgotten_session_rows(bundle_id TEXT,source_id TEXT)")
    return url
  }
  func oldCursor(_ db: SQLiteConnection, file: AgentLogFile, thread: String = "invented-session") throws {
    try db.run("INSERT INTO log_cursors VALUES(?,?,?,?,?,200)", [
      .key(file.path), .integer(file.device), .integer(file.inode), .integer(file.size),
      .text(try json(["folder": "/invented/project", "threadID": thread])),
    ])
  }
  func replaceLog(_ url: URL) throws {
    let replacement = url.appendingPathExtension("replacement")
    try Data(contentsOf: url).write(to: replacement)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.moveItem(at: replacement, to: url)
  }
  func testConvertedOldIdentitiesSurviveEveryFileReplacementWithZeroDuplicates() throws {
    let oldURL = try oldLogsDatabase("invented-old-identities")
    var logs: [URL] = []
    do {
      let old = try SQLiteConnection(url: oldURL, scope: .directory(root))
      for tool in AgentLogTool.allCases {
        let url = try file(tool, name: "invented-identities-" + tool.rawValue + ".jsonl")
        logs.append(url)
        let legacyText = "  Invented legacy words  "
        let hash = SHA256.hash(data: Data("Invented legacy words".utf8))
          .map { String(format: "%02x", $0) }.joined()
        var legacy = try JSONSerialization.jsonObject(
          with: Data(prompt(tool, id: "invented-remove", at: 102, text: legacyText).utf8)) as! [String: Any]
        let middle: String
        let middleID: String
        let middleTS: Int
        if tool == .claude {
          legacy.removeValue(forKey: "uuid")
          middle = try [enqueue("invented-queued", at: 90), queued("invented-queued", at: 95),
            queuedCopy("invented-copy", at: 96)].joined(separator: "\n")
          middleID = "claude:invented-queued"
          middleTS = 90
        } else {
          var payload = legacy["payload"] as! [String: Any]
          var item = payload["item"] as! [String: Any]
          item.removeValue(forKey: "id")
          payload["item"] = item
          legacy["payload"] = payload
          var line = try JSONSerialization.jsonObject(with: Data(prompt(tool, id: "invented-seconds", at: 101).utf8))
            as! [String: Any]
          var fields = line["payload"] as! [String: Any]
          fields.removeValue(forKey: "turn_id")
          line["payload"] = fields
          middle = try json(line)
          middleID = "codex:invented-session:101:invented-seconds"
          middleTS = 101
        }
        try write([meta(tool), prompt(tool, id: "invented-native"), middle, json(legacy)], to: url)
        let source = url.deletingPathExtension().lastPathComponent
        let nativeID = tool == .claude ? "claude:invented-native"
          : "codex:invented-session:invented-turn:invented-native"
        let rows = [(100, nativeID, "Invented request"), (middleTS, middleID,
          tool == .claude ? "Invented repeated queue words" : "Invented request"),
          (102, tool.rawValue + ":legacy:102:" + hash, legacyText)]
        for row in rows {
          try old.run("""
            INSERT INTO evidence(ts,bundle_id,doc_key,kind,role,text,source_id,project)
            VALUES(?,?,'','prompt','',?,?,'/invented/project')
            """, [.integer(row.0), .text(source), .text(row.2), .text(row.1)])
        }
        try oldCursor(old, file: XCTUnwrap(reader(tool).files().first { $0.path == url.path }))
      }
    }
    let converted = try ActivityStorage(url: root.appendingPathComponent("invented-converted-identities.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let result = try converted.convertOldDatabase(at: oldURL)
    XCTAssertEqual(result.evidence, 6)
    try converted.saveFixtureSettings(StorageSettings(subscriptionConnected: true), at: 0)
    for tool in AgentLogTool.allCases {
      let task = AgentLogTask(reader: reader(tool), storage: converted)
      try task.scan(at: 300)
      XCTAssertEqual(task.health.stored, 0)
    }
    for url in logs { try replaceLog(url) }
    for tool in AgentLogTool.allCases {
      let task = AgentLogTask(reader: reader(tool), storage: converted)
      try task.scan(at: 500)
      XCTAssertEqual(task.health.stored, 0, tool.rawValue)
      XCTAssertEqual(task.health.refused, tool == .claude ? 4 : 3)
    }
    XCTAssertEqual(try converted.evidence(in: all).count, 6)
    // A different parent path retains the old session-file identity as well.
    let alias = root.appendingPathComponent("invented-moved")
    try FileManager.default.createDirectory(at: alias, withIntermediateDirectories: true)
    let moved = alias.appendingPathComponent(logs[0].lastPathComponent)
    try FileManager.default.copyItem(at: logs[0], to: moved)
    let file = try XCTUnwrap(AgentLogFiles.enumerate([alias.path]).first)
    let batch = try AgentLogFiles.read(file, tool: .claude, position: nil, at: 700)
    XCTAssertEqual(try converted.appendLogBatch(batch.evidence, position: batch.position).stored, 0)
  }
  func testOldDeletedQueueStaysDeletedAfterConversionAndReplacement() throws {
    for protection in ["range", "identity", "both"] {
      let oldURL = try oldLogsDatabase("invented-old-deleted-queue-" + protection)
      let url = try file(.claude, name: "invented-deleted-queue-" + protection + ".jsonl")
      try write([enqueue("invented-forgotten", at: 90), queued("invented-forgotten", at: 95),
        queuedCopy("invented-forgotten-copy", at: 96)], to: url)
      do {
        let old = try SQLiteConnection(url: oldURL, scope: .directory(root))
        if protection != "identity" { try old.run("INSERT INTO forgotten VALUES(90,91)") }
        if protection != "range" {
          try old.run("INSERT INTO forgotten_session_rows VALUES(?,'claude:invented-forgotten')",
            [.text(url.deletingPathExtension().lastPathComponent)])
        }
        try oldCursor(old, file: XCTUnwrap(reader(.claude).files().first { $0.path == url.path }))
      }
      let destination = root.appendingPathComponent("invented-new-deleted-queue-" + protection + ".sqlite")
      let converted = try ActivityStorage(url: destination, appDataDirectory: destination.deletingLastPathComponent(), databaseScope: .directory(root))
      _ = try converted.convertOldDatabase(at: oldURL)
      try converted.saveFixtureSettings(StorageSettings(subscriptionConnected: true), at: 0)
      let listed = try XCTUnwrap(reader(.claude).files().first { $0.path == url.path })
      let taskReader = ControlledLogReader()
      taskReader.listed = [listed]
      let task = AgentLogTask(reader: taskReader, storage: converted)
      try task.scan(at: 300)
      XCTAssertEqual(task.health.stored, 0)
      try replaceLog(url)
      taskReader.listed = try reader(.claude).files().filter { $0.path == url.path }
      try task.scan(at: 500)
      XCTAssertEqual(task.health.stored, 0, protection)
      XCTAssertEqual(task.health.refused, 2, protection)
      XCTAssertEqual(try converted.evidence(in: all), [])
      XCTAssertEqual(try converted.logPosition(path: url.path)?.offset, (try Data(contentsOf: url)).count)
    }
  }
  func testOldPendingQueueCheckpointPreservesArrivalTimeWithoutText() throws {
    let url = try file(.claude)
    try write([queued("invented-pending", at: 95)], to: url)
    let listed = try XCTUnwrap(reader(.claude).files().first)
    let hash = SHA256.hash(data: Data("Invented repeated queue words".utf8))
      .map { String(format: "%02x", $0) }.joined()
    let oldState = try json(["queued": [[
      "hash": hash, "id": "invented-pending", "ts": 90, "delivered": false,
    ]]])
    let position = LogPosition(path: listed.path, device: listed.device, inode: listed.inode,
      offset: 0, state: oldState, seenAt: 100)
    let batch = try AgentLogFiles.read(listed, tool: .claude, position: position, at: 200)
    XCTAssertEqual(batch.evidence.first?.ts, 90)
    XCTAssertEqual(batch.evidence.first?.sourceID, "claude:invented-pending")
    XCTAssertFalse(batch.position.state.contains("Invented repeated queue words"))
  }

  func testOldAbsorbedQueueIDAndClockReversalKeepTheirIdentityAndArrival() throws {
    var state = AgentLogState()
    let arrival = try json([
      "type": "queue-operation", "operation": "enqueue", "timestamp": stamp(90),
      "content": "Invented repeated queue words",
    ])
    let absorbed = try json([
      "type": "queue-operation", "operation": "remove", "reason": "absorbed_mid_turn",
      "timestamp": stamp(94), "commandUuid": "invented-absorbed", "content": "Invented repeated queue words",
    ])
    for line in [arrival, absorbed] {
      _ = AgentLogParser.parse(line, tool: .claude, file: "/invented/session.jsonl", state: &state,
        fingerprint: AgentLogFiles.fingerprint)
    }
    guard case .prompt(let row) = AgentLogParser.parse(try queuedCopy("invented-copy", at: 96),
      tool: .claude, file: "/invented/session.jsonl", state: &state, fingerprint: AgentLogFiles.fingerprint)
    else { return XCTFail("absorbed queue must be delivered") }
    XCTAssertEqual(row.sourceID, "claude:invented-absorbed")
    XCTAssertEqual(row.ts, 90)
    _ = AgentLogParser.parse(try enqueue("invented-reversal", at: 110), tool: .claude,
      file: "/invented/session.jsonl", state: &state, fingerprint: AgentLogFiles.fingerprint)
    guard case .prompt(let reversed) = AgentLogParser.parse(try queued("invented-reversal", at: 105),
      tool: .claude, file: "/invented/session.jsonl", state: &state, fingerprint: AgentLogFiles.fingerprint)
    else { return XCTFail("identified delivery must survive a backward clock") }
    XCTAssertEqual(reversed.ts, 110)
    guard case .prompt(let copy) = AgentLogParser.parse(try queuedCopy("invented-reversal-copy", at: 106),
      tool: .claude, file: "/invented/session.jsonl", state: &state, fingerprint: AgentLogFiles.fingerprint)
    else { return XCTFail("queued copy must pair even after a backward clock") }
    XCTAssertEqual(copy.sourceID, reversed.sourceID)
    XCTAssertEqual(copy.ts, 110)
  }

}
