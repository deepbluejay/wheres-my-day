import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  private func seventhRead(_ url: URL, _ tool: AgentLogTool) throws -> AgentLogBatch {
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
    return try AgentLogFiles.read(source, tool: tool, position: store.logPosition(path: url.path), at: 300,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
  }
  private func seventhCommit(_ batch: AgentLogBatch) throws {
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  }
  private func seventhReopen() throws {
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
  }
  private func seventhHeader(_ tool: AgentLogTool, _ session: String, own: Bool = false) throws -> String {
    var record: [String: Any] = tool == .claude ? ["type": "system", "sessionId": session]
      : ["type": "session_meta", "payload": ["id": session]]
    if own { record["cwd"] = "/invented/" + AgentWindowIdentity.relativeFolder }
    // Literal dotted members must never replace the actual nested header or manufacture an own marker.
    let encoded = try json(record)
    return "{\"payload.id\":\"invented-dotted-before\"," + encoded.dropFirst().dropLast()
      + ",\"payload\\u002eid\":\"invented-dotted-after\",\"payload.item.originator\":\"ActivityProbe\"}"
  }
  private func seventhItem(_ session: String?, _ id: String, time: Int = 200) throws -> String {
    var payload: [String: Any] = ["type": "item_completed", "turn_id": "invented-turn",
      "item": ["type": "UserMessage", "id": id, "content": [["type": "text", "text": "Invented seventh instruction"]]]]
    payload["thread_id"] = session
    return try json(["type": "event_msg", "timestamp": stamp(time), "payload": payload])
  }
  private func seventhOversized(_ tool: AgentLogTool, _ session: String, _ role: String, identityLast: Bool = false, size: Int = AgentLogFiles.longestLineBytes + 32) -> String {
    let field = tool == .claude ? "\"sessionId\":\"\(session)\"" : "\"payload\":{\"thread_id\":\"\(session)\"}"
    let head = "\"type\":\"\(role)\",\"message\":{\"role\":\"\(role)\",\"content\":\"Invented complete text\"}"
    let padding = "\"padding\":\"" + String(repeating: "x", count: size) + "\""
    return "{\"payload.thread_id\":\"invented-decoy-before\"," + head + ","
      + (identityLast ? padding + "," + field : field + "," + padding)
      + ",\"payload\\u002ethread_id\":\"invented-decoy-after\"}"
  }

  func testOversizedExplicitOwnershipAllRolesBothToolsBothOrdersAndPreparedReceipts() throws {
    for tool in AgentLogTool.allCases {
      let foreign = try file(tool, name: "invented-seventh-foreign-\(tool).jsonl")
      try write([seventhOversized(tool, "invented-seventh-foreign-\(tool)", "assistant")], to: foreign)
      let permitted = try seventhRead(foreign, tool)
      XCTAssertEqual(permitted.events.first?.parseStatus, "truncated")
      XCTAssertEqual(permitted.events.first?.explicitSession?.storedKey, "invented-seventh-foreign-\(tool)")
      try seventhCommit(permitted)
      let foreignCursor = try XCTUnwrap(store.logPosition(path: foreign.path))
      for role in ["user", "assistant", "tool", "system"] {
        let session = "invented-seventh-\(tool)-\(role)"
        let copy = try file(tool, name: session + "-copy.jsonl")
        let discovery = try file(tool, name: session + "-discovery.jsonl")
        let fsCopy = try file(tool, name: session + "-prepared-fs.jsonl")
        let dbCopy = try file(tool, name: session + "-prepared-db.jsonl")
        try write([seventhOversized(tool, session, role)], to: copy)
        let prepared = try seventhRead(copy, tool)
        try FileManager.default.copyItem(at: copy, to: fsCopy)
        try FileManager.default.copyItem(at: copy, to: dbCopy)
        let fsPrepared = try seventhRead(fsCopy, tool)
        let dbPrepared = try seventhRead(dbCopy, tool)
        XCTAssertEqual(prepared.events.count, 1)
        XCTAssertEqual(prepared.events.first?.explicitSession?.storedKey, session)
        XCTAssertTrue(prepared.evidence.isEmpty)
        // Copy-first import, then a transactional late revocation, including abort and reopen.
        try seventhCommit(prepared)
        try write([seventhHeader(tool, session, own: true)], to: discovery)
        let own = try seventhRead(discovery, tool)
        try store.connection.run("CREATE TRIGGER invented_seventh_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
        XCTAssertThrowsError(try seventhCommit(own))
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 1)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id=?", [.key(session)]), 0)
        try store.connection.run("DROP TRIGGER invented_seventh_abort")
        try seventhReopen()
        try seventhCommit(own)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
        // Own-first and a stale prepared batch are checked again by both receipt stores.
        try seventhCommit(fsPrepared)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(fsCopy.path))'"), 0)
        try seventhCommit(prepared)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
        try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
        try seventhReopen()
        try seventhCommit(dbPrepared)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(dbCopy.path))'"), 0)
        try seventhCommit(prepared)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
        let blocked = try seventhRead(copy, tool)
        // The durable source/session receipt refuses at writer even with filesystem receipts removed.
        try seventhCommit(blocked)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 0)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads WHERE id NOT IN (SELECT payload_id FROM agent_log_events)"), 0)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 1)
        XCTAssertEqual(try store.logPosition(path: foreign.path)?.offset, foreignCursor.offset)
        XCTAssertEqual(try store.logPosition(path: foreign.path)?.state, foreignCursor.state)
        // A known filesystem session receipt blocks a distinct oversized occurrence at read time.
        try AgentLogFiles.ownSources(appDataDirectory: root).registerSession(session, tool: tool)
        let known = try file(tool, name: session + "-known.jsonl")
        try write([seventhOversized(tool, session, role)], to: known)
        let knownBatch = try seventhRead(known, tool)
        XCTAssertTrue(knownBatch.events.isEmpty)
        XCTAssertTrue(knownBatch.evidence.isEmpty)
        try seventhCommit(knownBatch)
        let control = try file(tool, name: session + "-control.jsonl")
        try write([seventhOversized(tool, session, role, size: AgentLogFiles.batchBytes)], to: control)
        let controlBatch = try seventhRead(control, tool)
        XCTAssertTrue(controlBatch.events.isEmpty)
        XCTAssertTrue(controlBatch.evidence.isEmpty)
        try seventhCommit(controlBatch)
      }
    }
  }

  func testOversizedMetadataAfterPrefixAndPartialFinalLine() throws {
    for tool in AgentLogTool.allCases {
      let session = "invented-seventh-tail-\(tool)"
      let url = try file(tool, name: session + ".jsonl")
      let record = seventhOversized(tool, session, "user", identityLast: true)
      try Data(record.utf8).write(to: url)
      let partial = try seventhRead(url, tool)
      XCTAssertEqual(partial.position.offset, 0)
      XCTAssertTrue(partial.events.isEmpty)
      try seventhCommit(partial)
      try append(Data([10]), to: url)
      let complete = try seventhRead(url, tool)
      XCTAssertEqual(complete.events.first?.explicitSession?.storedKey, session)
      XCTAssertEqual(complete.position.offset, record.utf8.count + 1)
      try seventhCommit(complete)
      let discovery = try file(tool, name: session + "-marker.jsonl")
      let marked = String(record.dropLast()) + ",\"cwd\":\"/invented/" + AgentWindowIdentity.relativeFolder + "\"}"
      try write([marked], to: discovery)
      let own = try seventhRead(discovery, tool)
      XCTAssertTrue(own.events.isEmpty)
      XCTAssertEqual(try AgentLogState.decode(own.position.state).ownedSession?.storedKey, session)
      try seventhCommit(own)
      try seventhReopen()
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
    }
  }

  func testCursorMetadataRecoveryBeyondBatchLegacyCurrentAndSwitchBack() throws {
    let padding = "{\"type\":\"system\",\"padding\":\"" + String(repeating: "x", count: AgentLogFiles.batchBytes + 8192) + "\"}"
    var forgottenTime = 100
    for mode in ["legacy", "current", "switch"] {
      for early in [false, true] {
        for protection in ["foreign", "own", "forgotten"] {
          let tag = "invented-seventh-\(mode)-\(early)-\(protection)"
          let session = tag + "-B", item = tag + "-item"
          let url = try file(.codex, name: tag + ".jsonl")
          if protection == "forgotten" {
            let seed = try file(.codex, name: tag + "-seed.jsonl")
            let seedTime = forgottenTime
            forgottenTime += 1
            try write([seventhHeader(.codex, session), seventhItem(nil, item, time: seedTime)], to: seed)
            try seventhCommit(seventhRead(seed, .codex))
            XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE source_id=?", [.key("codex:\(session):invented-turn:\(item)")]), 1)
            let preview = try store.previewDeletion(in: TimeRange(seedTime, seedTime + 1))
            try store.deleteRecords(in: preview.range, confirmation: preview.confirmation)
          }
          var prefix = early ? [try seventhHeader(.codex, tag + "-A")] : []
          prefix += [padding, try seventhHeader(.codex, session)]
          try write(prefix, to: url)
          let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
          var state = AgentLogState()
          state.tool = mode == "legacy" ? nil : "codex"
          state.session = AgentLogIdentityCodec.session(session)
          state.metadataRead = true
          let position = LogPosition(path: url.path, device: source.device, inode: source.inode,
            offset: source.size, state: try state.encoded(), seenAt: 200)
          try store.appendLogEvents([], evidence: [], position: position)
          if mode == "switch" {
            for _ in 0..<5 {
              let other = try seventhRead(url, .claude)
              XCTAssertTrue(other.events.isEmpty)
              XCTAssertEqual(other.position.offset, source.size)
              try seventhCommit(other)
              try seventhReopen()
              if !other.ownershipDeferred { break }
            }
          }
          if protection == "own" { try AgentLogFiles.ownSources(appDataDirectory: root).registerSession(session, tool: .codex) }
          try seventhReopen()
          try append(Data((try seventhItem(nil, item) + "\n").utf8), to: url)
          var completed: AgentLogBatch?
          var previousRecovery = -1
          for _ in 0..<6 {
            let batch = try seventhRead(url, .codex)
            if batch.ownershipDeferred {
              XCTAssertEqual(batch.position.offset, source.size)
              XCTAssertTrue(batch.events.isEmpty)
              XCTAssertTrue(batch.evidence.isEmpty)
              let recovery = try XCTUnwrap(AgentLogState.decode(batch.position.state).metadataRecoveryOffset)
              XCTAssertGreaterThan(recovery, previousRecovery)
              XCTAssertLessThanOrEqual(recovery, source.size)
              previousRecovery = recovery
            } else { completed = batch }
            try seventhCommit(batch)
            try seventhReopen()
            if completed != nil { break }
          }
          let batch = try XCTUnwrap(completed)
          XCTAssertEqual(batch.position.offset, source.size + (try seventhItem(nil, item)).utf8.count + 1)
          XCTAssertEqual(try AgentLogState.decode(batch.position.state).session?.storedKey, session)
          if protection == "foreign" {
            XCTAssertEqual(batch.events.count, 1)
            XCTAssertEqual(batch.events.first?.session?.storedKey, session)
            XCTAssertEqual(batch.evidence.first?.sourceID, "codex:\(session):invented-turn:\(item)")
            XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 1)
            try append(Data((try seventhItem(nil, item + "-future", time: 201) + "\n").utf8), to: url)
            let future = try seventhRead(url, .codex)
            XCTAssertEqual(future.events.first?.offset, batch.position.offset)
            XCTAssertEqual(future.events.first?.session?.storedKey, session)
            try seventhCommit(future)
            XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 2)
          } else {
            XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
            XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE source_id=?", [.key("codex:\(session):invented-turn:\(item)")]), 0)
            try append(Data((try seventhItem(nil, item, time: 201) + "\n").utf8), to: url)
            try seventhCommit(seventhRead(url, .codex))
            try seventhReopen()
            XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
            XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE source_id=?", [.key("codex:\(session):invented-turn:\(item)")]), 0)
          }
        }
      }
    }
  }

  func testRecoveryStreamsOversizedHeaderAndMetadataFreeCommittedPrefix() throws {
    for tool in AgentLogTool.allCases {
      for header in [false, true] {
        let tag = "invented-seventh-stream-\(tool)-\(header)", session = "invented-stream-B-\(tool)"
        let url = try file(tool, name: tag + ".jsonl")
        let prefix = header ? seventhOversized(tool, session, tool == .codex ? "session_meta" : "system", identityLast: true)
          .replacingOccurrences(of: "\"thread_id\"", with: "\"id\"")
          : "{\"type\":\"system\",\"padding\":\"" + String(repeating: "x", count: AgentLogFiles.longestLineBytes + 32) + "\"}"
        try write([prefix], to: url)
        let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
        try store.appendLogEvents([], evidence: [], position: LogPosition(path: url.path, device: source.device,
          inode: source.inode, offset: source.size, state: "{}", seenAt: 200))
        let item = tool == .codex ? try seventhItem(nil, tag) : try json(["type": "user", "uuid": tag,
          "timestamp": stamp(200), "message": ["content": "Invented stream append"]])
        try append(Data((item + "\n").utf8), to: url)
        var deferred = 0
        for _ in 0..<24 {
          let batch = try seventhRead(url, tool)
          if batch.ownershipDeferred {
            deferred += 1
            XCTAssertEqual(batch.position.offset, source.size)
            XCTAssertTrue(batch.events.isEmpty)
            XCTAssertLessThan(batch.position.state.utf8.count, 8192)
          } else {
            XCTAssertEqual(batch.events.count, 1)
            XCTAssertEqual(batch.events.first?.offset, source.size)
            XCTAssertEqual(batch.events.first?.session?.storedKey, header ? session : nil)
            try seventhCommit(batch)
            break
          }
          try seventhCommit(batch)
          try seventhReopen()
        }
        XCTAssertEqual(deferred, 16)
        XCTAssertEqual(try store.logPosition(path: url.path)?.offset, source.size + item.utf8.count + 1)
      }
    }
  }

  func testStreamingMetadataUsesOnlyExactPathsAndMasksRecoveryCheckpoints() throws {
    let record = "{\"type\":\"event_msg\",\"payload\":{\"thread_id\":\"invented-current\",\"item\":{\"thread_id\":\"invented-nested\"}},\"message\":\"sessionId invented-text\",\"sessionId\":\"invented-claude\"}"
    var metadata = AgentLogMetadata()
    for byte in record.utf8 { metadata.consume(byte) }
    XCTAssertEqual(metadata.explicitSession(tool: .codex)?.storedKey, "invented-current")
    XCTAssertEqual(metadata.explicitSession(tool: .claude)?.storedKey, "invented-claude")
    XCTAssertNil(metadata.authoritativeSession(tool: .codex))
    let secret = "sk-proj-" + String(repeating: "z", count: 48)
    let header = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"invented-safe\",\"cwd\":\"/invented/\(secret)\"},\"ignored\":\"\(secret)"
    var recovering = AgentLogMetadata()
    for byte in header.utf8 { recovering.consume(byte) }
    XCTAssertTrue(recovering.checkpointSafe)
    let saved = try JSONEncoder().encode(recovering)
    XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains(secret))
    recovering = try JSONDecoder().decode(AgentLogMetadata.self, from: saved)
    for byte in "\"}".utf8 { recovering.consume(byte) }
    XCTAssertEqual(recovering.authoritativeSession(tool: .codex)?.storedKey, "invented-safe")
    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
    raw["values"] = ["payload.id": secret, "type": "session_meta"]
    raw["token"] = [UInt8]()
    let rawState = try JSONSerialization.data(withJSONObject: ["tool": "codex", "metadataRead": true,
      "metadataRecoveryOffset": 10, "metadataRecoveryScanner": raw])
    let path = root.appendingPathComponent("invented-seventh-unsafe-state").path
    try store.saveLogPosition(LogPosition(path: path, device: 1, inode: 1, offset: 100,
      state: String(decoding: rawState, as: UTF8.self), seenAt: 200))
    let stored = try XCTUnwrap(store.logPosition(path: path)).state
    XCTAssertFalse(stored.contains(secret))
    XCTAssertFalse(stored.contains(Data(secret.utf8).base64EncodedString()))
    for text in [
      "{\"type\":\"event_msg\",\"payload\":{\"thread_id\":\"invented-old\"},\"payload\":{\"thread_id\":\"invented-new\"}}",
      "{\"type\":\"event_msg\",\"payload\":{\"thread_id\":\"invented-new\",\"originator\":\"\(AgentWindowIdentity.codexOriginator)\",\"originator\":null}}"
    ] {
      var lastMember = AgentLogMetadata()
      for byte in text.utf8 { lastMember.consume(byte) }
      XCTAssertEqual(lastMember.explicitSession(tool: .codex)?.storedKey, "invented-new")
      XCTAssertFalse(lastMember.ownMarker)
    }
  }
}
