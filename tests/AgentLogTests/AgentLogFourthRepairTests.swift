import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  private func fourthRead(_ url: URL, _ tool: AgentLogTool) throws -> AgentLogBatch {
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
    return try AgentLogFiles.read(source, tool: tool, position: store.logPosition(path: url.path), at: 200,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
  }
  private func fourthCommit(_ batch: AgentLogBatch) throws {
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  }
  private func fourthReopen() throws {
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
  }
  private func fourthMetadata(_ tool: AgentLogTool, _ session: String) throws -> String {
    try json(tool == .claude ? ["type": "system", "sessionId": session]
      : ["type": "session_meta", "payload": ["id": session]])
  }
  private func fourthMarker() throws -> String {
    try json(["type": "system", "cwd": "/invented/" + AgentWindowIdentity.relativeFolder])
  }
  private func fourthRecord(_ tool: AgentLogTool, _ role: String, _ id: String) throws -> String {
    if tool == .claude {
      return try json(["type": role, "timestamp": stamp(100), "uuid": id,
        "message": ["role": role, "content": "Invented fourth repair instruction"]])
    }
    return try json(["type": "event_msg", "timestamp": stamp(100), "payload": [
      "type": "item_completed", "thread_id": "invented-fourth-thread", "turn_id": "invented-turn",
      "item": ["type": role == "user" ? "UserMessage" : "InventedRecord", "role": role,
        "id": id, "content": [["type": "text", "text": "Invented fourth repair instruction"]]]]])
  }
  private func fourthSnapshot(_ table: String, where predicate: String = "1") throws -> [String] {
    var columns: [String] = []
    try store.connection.namedRows("PRAGMA table_info(\(table))") { columns.append(try $0.text("name")) }
    var rows: [String] = []
    let expression = columns.map { "typeof(\($0))||':'||quote(\($0))" }.joined(separator: "||'|'||")
    try store.connection.namedRows("SELECT \(expression) AS value FROM \(table) WHERE \(predicate) ORDER BY rowid") {
      rows.append(try $0.text("value"))
    }
    return rows
  }

  func testLookaheadSessionBetweenCursorsSurvivesRestartAllRolesBothOrders() throws {
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for ownFirst in [false, true] {
          let tag = "invented-fourth-\(tool)-\(role)-\(ownFirst)"
          let session = tag + "-session"
          let own = try file(tool, name: tag + "-own.jsonl")
          let copy = try file(tool, name: tag + "-copy.jsonl")
          let foreign = try file(tool, name: tag + "-foreign.jsonl")
          try write([fourthMetadata(tool, tag + "-foreign"), fourthRecord(tool, "user", tag + "-foreign")], to: foreign)
          try fourthCommit(fourthRead(foreign, tool))
          let foreignEvents = try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
          let foreignCursor = try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
          let evidenceBefore = try store.evidence(in: all).count
          try write([fourthMetadata(tool, session), fourthRecord(tool, role, tag + "-copy")], to: copy)
          if !ownFirst { try fourthCommit(fourthRead(copy, tool)) }
          let prefix = String(repeating: "\n", count: 15000)
          let header = try fourthMetadata(tool, session)
          let padding = try json(["type": "invented-padding", "value": String(repeating: "x", count: AgentLogFiles.batchBytes)])
          try Data((prefix + header + "\n" + padding + "\n").utf8).write(to: own)
          let first = try fourthRead(own, tool)
          let firstState = try AgentLogState.decode(first.position.state)
          XCTAssertLessThan(first.position.offset, prefix.utf8.count)
          XCTAssertGreaterThan(firstState.ownershipScanOffset, prefix.utf8.count + header.utf8.count)
          XCTAssertNil(firstState.session)
          XCTAssertEqual(firstState.ownershipSession?.storedKey, session)
          try fourthCommit(first)
          try fourthReopen()
          // EOF retains lookahead metadata even when the ordinary cursor remains behind it.
          let atEOF = try fourthRead(own, tool)
          XCTAssertNil(try AgentLogState.decode(atEOF.position.state).session)
          XCTAssertEqual(try AgentLogState.decode(atEOF.position.state).ownershipSession?.storedKey, session)
          try fourthCommit(atEOF)
          try fourthReopen()
          try append(Data((try fourthMarker() + "\n" + fourthRecord(tool, role, tag) + "\n").utf8), to: own)
          let discovering = try fourthRead(own, tool)
          XCTAssertTrue(discovering.events.isEmpty)
          XCTAssertEqual(try AgentLogState.decode(discovering.position.state).ownershipSession?.storedKey, session)
          XCTAssertTrue(try AgentLogFiles.ownSources(appDataDirectory: root).containsSession(session, tool: tool))
          let beforeRollback = try eventCount()
          try store.connection.run("CREATE TRIGGER invented_fourth_failure BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
          XCTAssertThrowsError(try fourthCommit(discovering))
          XCTAssertEqual(try eventCount(), beforeRollback)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(session)]), 0)
          try store.connection.run("DROP TRIGGER invented_fourth_failure")
          try fourthReopen()
          try fourthCommit(fourthRead(own, tool))
          if ownFirst { try fourthCommit(fourthRead(copy, tool)) }
          for _ in 0..<2 {
            try fourthReopen()
            try fourthCommit(fourthRead(copy, tool))
            try fourthCommit(fourthRead(own, tool))
            XCTAssertEqual(try eventCount("session_id='\(session)' OR source='\(AgentLogEventParser.pathIdentity(own.path))' OR source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
            XCTAssertEqual(try store.evidence(in: all).count, evidenceBefore)
            XCTAssertEqual(try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignEvents)
            XCTAssertEqual(try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignCursor)
            XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(session)]), 1)
          }
        }
      }
    }
  }

  func testLookaheadDoesNotReassignEarlierRecordIdentityAndRecoversMainCursor() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool, name: "invented-independent-cursors-\(tool).jsonl")
      try write([fourthRecord(tool, "user", "invented-early"), fourthMetadata(tool, "invented-late")], to: url)
      let batch = try fourthRead(url, tool)
      XCTAssertNil(batch.events.first?.session)
      XCTAssertEqual(try AgentLogState.decode(batch.position.state).ownershipSession?.storedKey, "invented-late")
      if tool == .codex { XCTAssertTrue(batch.evidence.first?.sourceID?.contains("invented-fourth-thread") == true) }
      try fourthCommit(batch)
      // Main has no lookahead cursor. Recover metadata at its unchanged collection offset.
      let saved = try XCTUnwrap(store.logPosition(path: url.path))
      try makeMainLogOrigin(store)
      try fourthReopen()
      let recovered = try fourthRead(url, tool)
      XCTAssertEqual(recovered.position.offset, saved.offset)
      XCTAssertTrue(recovered.events.isEmpty)
      XCTAssertEqual(try AgentLogState.decode(recovered.position.state).ownershipSession?.storedKey, "invented-late")
      var state = AgentLogState()
      state.ownershipSession = AgentLogIdentityCodec.session("sk-inventedABCDEFGHIJKLMNOPQRSTUV123456789")
      XCTAssertFalse(try state.encoded().contains("sk-invented"))
    }
  }

  func testLegacyCanonicalOriginStaysUnknownAfterNewOwnDedupBothToolsAndAdoptions() throws {
    for tool in AgentLogTool.allCases {
      for version in [9, SQLiteConnection.schemaVersion] {
        let tag = "invented-legacy-fourth-\(tool)-\(version)"
        let foreign = try file(tool, home: root.appendingPathComponent(tag + "-foreign"), name: tag + ".jsonl")
        let own = try file(tool, home: root.appendingPathComponent(tag + "-own"), name: tag + ".jsonl")
        let record = try fourthRecord(tool, "user", tag)
        try write([fourthMetadata(tool, tag + "-foreign"), record], to: foreign)
        try fourthCommit(fourthRead(foreign, tool))
        if version == 9 { try makeMainLogOrigin(store) }
        else {
          try store.connection.run("DELETE FROM agent_log_evidence_origins")
          try store.connection.run("DELETE FROM agent_log_source_evidence")
        }
        let tables = ["evidence", "settings", "log_recording_history", "log_positions", "forgotten_ranges",
          "forgotten_sources"]
        let snapshots = try tables.map { try fourthSnapshot($0) }
        try fourthReopen()
        XCTAssertEqual(try tables.map { try fourthSnapshot($0) }, snapshots)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_evidence_origins"), 0)
        let evidence = try fourthSnapshot("evidence")
        let foreignEvents = try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        let payloads = try fourthSnapshot("agent_log_payloads")
        var cursor = try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        try write([fourthMetadata(tool, tag + "-own"), record], to: own)
        try fourthCommit(fourthRead(own, tool))
        XCTAssertEqual(try fourthSnapshot("evidence"), evidence)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE source=?", [.key(AgentLogEventParser.pathIdentity(own.path))]), 1)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_evidence_origins"), 0)
        try fourthReopen()
        try append(Data((try fourthMarker() + "\n").utf8), to: own)
        let batch = try fourthRead(own, tool)
        try store.connection.run("CREATE TRIGGER invented_fourth_failure BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
        XCTAssertThrowsError(try fourthCommit(batch))
        XCTAssertEqual(try fourthSnapshot("evidence"), evidence)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE source=?", [.key(AgentLogEventParser.pathIdentity(own.path))]), 1)
        try store.connection.run("DROP TRIGGER invented_fourth_failure")
        try fourthReopen()
        try fourthCommit(fourthRead(own, tool))
        for _ in 0..<2 {
          try fourthReopen()
          try fourthCommit(fourthRead(own, tool))
          XCTAssertEqual(try fourthSnapshot("evidence"), evidence)
          XCTAssertEqual(try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignEvents)
          XCTAssertEqual(try fourthSnapshot("agent_log_payloads"), payloads)
          XCTAssertEqual(try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), cursor)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE source=?", [.key(AgentLogEventParser.pathIdentity(own.path))]), 0)
          let resumed = try fourthRead(foreign, tool)
          XCTAssertTrue(resumed.events.isEmpty)
          let oldPosition = try XCTUnwrap(store.logPosition(path: foreign.path))
          XCTAssertEqual(resumed.position.offset, oldPosition.offset)
          XCTAssertEqual(resumed.position.device, oldPosition.device)
          XCTAssertEqual(resumed.position.inode, oldPosition.inode)
          try fourthCommit(resumed)
          cursor = try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        }
      }
    }
  }

  func testBlankSessionMetadataClearsLookaheadAndPreservesUnrelatedSources() throws {
    for tool in AgentLogTool.allCases {
      let session = "invented-blank-session-\(tool)"
      let foreign = try file(tool, name: session + "-foreign.jsonl")
      let copy = try file(tool, name: session + "-copy.jsonl")
      let own = try file(tool, name: session + "-own.jsonl")
      try write([fourthMetadata(tool, ""), fourthRecord(tool, "user", session + "-foreign")], to: foreign)
      try fourthCommit(fourthRead(foreign, tool))
      let foreignEvents = try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
      let foreignCursor = try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
      try write([fourthMetadata(tool, session), fourthRecord(tool, "user", session + "-copy")], to: copy)
      try fourthCommit(fourthRead(copy, tool))
      let preservedEvidence = try fourthSnapshot("evidence")
      let copyEvents = try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(copy.path))'")
      let padding = try json(["type": "invented-padding", "value": String(repeating: "x", count: AgentLogFiles.batchBytes)])
      try Data((String(repeating: "\n", count: 6000) + (try fourthMetadata(tool, session)) + "\n" + padding + "\n").utf8).write(to: own)
      let first = try fourthRead(own, tool)
      XCTAssertNil(try AgentLogState.decode(first.position.state).session)
      try fourthCommit(first)
      try fourthReopen()
      try append(Data((try fourthMetadata(tool, " ") + "\n" + fourthMarker() + "\n").utf8), to: own)
      let discovering = try fourthRead(own, tool)
      XCTAssertNil(try AgentLogState.decode(discovering.position.state).ownershipSession)
      XCTAssertNil(try AgentLogState.decode(discovering.position.state).ownedSession)
      try fourthCommit(discovering)
      XCTAssertFalse(try AgentLogFiles.ownSources(appDataDirectory: root).containsSession(session, tool: tool))
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(own.path))'"), 0)
      XCTAssertEqual(try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(copy.path))'"), copyEvents)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(session)]), 0)
      for (index, blank) in ["", " \t", "\u{a0}"].enumerated() {
        let ownBlank = try file(tool, name: session + "-own-blank-\(index).jsonl")
        try write([fourthMetadata(tool, blank), fourthMarker()], to: ownBlank)
        try fourthCommit(fourthRead(ownBlank, tool))
        try store.purgeOwnLogSession(AgentLogIdentityCodec.session(blank), tool: tool)
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        try registry.registerSession(blank, tool: tool)
        XCTAssertFalse(try registry.containsSession(blank, tool: tool))
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(AgentLogEventParser.safeIdentity(blank))]), 0)
      }
      try fourthReopen()
      XCTAssertEqual(try fourthSnapshot("evidence"), preservedEvidence)
      XCTAssertEqual(try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignEvents)
      XCTAssertEqual(try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignCursor)
      XCTAssertTrue(try fourthRead(foreign, tool).events.isEmpty)
    }
  }

  func testSessionRevocationUsesIndexesAndCompletedReceiptSkipsLookup() throws {
    var plans: [String] = []
    try store.connection.namedRows("EXPLAIN QUERY PLAN " + ActivityStorage.ownLogSessionSourcesSQL, ActivityStorage.ownLogSessionSourceValues(AgentLogIdentityCodec.session("invented-absent"), tool: .claude)) { plans.append(try $0.text("detail")) }
    XCTAssertTrue(plans.contains { $0.contains("COVERING INDEX agent_log_inherited_session (tool=? AND session_id=?)") }, plans.joined(separator: "; "))
    plans = []
    try store.connection.namedRows("""
      EXPLAIN QUERY PLAN SELECT p.device,p.inode,p.path FROM log_positions p
      WHERE json_valid(p.state) AND json_extract(p.state,'$.session')='invented'
      UNION SELECT p.device,p.inode,p.path FROM log_positions p
      WHERE json_valid(p.state) AND json_extract(p.state,'$.ownershipSession')='invented'
      """) { plans.append(try $0.text("detail")) }
    XCTAssertTrue(plans.contains { $0.contains("log_positions_session") }, plans.joined(separator: "; "))
    XCTAssertTrue(plans.contains { $0.contains("log_positions_ownership_session") }, plans.joined(separator: "; "))
    for tool in AgentLogTool.allCases {
      let session = "invented-completed-\(tool)"
      try store.purgeOwnLogSession(AgentLogIdentityCodec.session(session), tool: tool)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(session)]), 1)
      try fourthReopen()
      // A completed lookup must return before preparing the event scan at all.
      try store.connection.run("ALTER TABLE agent_log_events RENAME TO invented_unavailable_events")
      XCTAssertNoThrow(try store.purgeOwnLogSession(AgentLogIdentityCodec.session(session), tool: tool))
      XCTAssertThrowsError(try store.purgeOwnLogSession(AgentLogIdentityCodec.session(session + "-new"), tool: tool))
      try store.connection.run("ALTER TABLE invented_unavailable_events RENAME TO agent_log_events")
    }
  }

  func testRevocationFindsLookaheadOnlyCheckpointsBeforeOrdinarySession() throws {
    for tool in AgentLogTool.allCases {
      let session = "invented-lookahead-checkpoint-\(tool)"
      let copy = try file(tool, name: session + "-copy.jsonl")
      let own = try file(tool, name: session + "-own.jsonl")
      let prefix = String(repeating: "\n", count: 6000)
      try Data((prefix + (try fourthMetadata(tool, session)) + "\n").utf8).write(to: copy)
      let batch = try fourthRead(copy, tool)
      XCTAssertNil(try AgentLogState.decode(batch.position.state).session)
      XCTAssertEqual(try AgentLogState.decode(batch.position.state).ownershipSession?.storedKey, session)
      XCTAssertFalse(batch.events.isEmpty)
      try fourthCommit(batch)
      let cursor = try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(copy.path))'")
      try fourthReopen()
      try write([fourthMetadata(tool, session), fourthMarker()], to: own)
      try fourthCommit(fourthRead(own, tool))
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
      XCTAssertEqual(try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(copy.path))'"), cursor)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
    }
  }

  func testPreparedSessionBatchCannotAdmitAfterCompletedRevocation() throws {
    for tool in AgentLogTool.allCases {
      let session = "invented-prepared-\(tool)"
      let copy = try file(tool, name: session + "-copy.jsonl")
      let own = try file(tool, name: session + "-own.jsonl")
      try write([fourthMetadata(tool, session), fourthRecord(tool, "user", session)], to: copy)
      let prepared = try fourthRead(copy, tool)
      try write([fourthMetadata(tool, session), fourthMarker()], to: own)
      try fourthCommit(fourthRead(own, tool))
      try fourthReopen()
      // The completed database receipt remains authoritative if the hash-only registry
      // directory is absent, including when the database moves to another app-data root.
      try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
      // A previously read batch can arrive after the completed transaction. Checking
      // only the reader or only the checkpoint would allow stale admissions here.
      var state = AgentLogState()
      state.tool = tool.rawValue
      let position = LogPosition(path: prepared.position.path, device: prepared.position.device,
        inode: prepared.position.inode, offset: prepared.position.offset, state: try state.encoded(), seenAt: 200)
      try store.appendLogEvents(prepared.events, evidence: prepared.evidence, position: position)
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
      XCTAssertTrue(try store.evidence(in: all).isEmpty)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(session)]), 1)
    }
  }
}

extension AgentLogTests {
  func testChangingSessionOwnershipPreservesForeignIdentityAllRolesBothOrders() throws {
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for ownFirst in [false, true] {
          let tag = "invented-fifth-\(tool)-\(role)-\(ownFirst)"
          let a = tag + "-A", b = tag + "-B"
          let foreign = try file(tool, name: tag + "-foreign.jsonl")
          let own = try file(tool, name: tag + "-own.jsonl")
          let copy = try file(tool, name: tag + "-copy.jsonl")
          try write([fourthMetadata(tool, a), fourthRecord(tool, "user", tag + "-foreign")], to: foreign)
          try write([fourthMetadata(tool, a), fourthRecord(tool, role, tag + "-initial")], to: own)
          for url in ownFirst ? [own, foreign] : [foreign, own] { try fourthCommit(fourthRead(url, tool)) }
          try write([fourthMetadata(tool, b), fourthRecord(tool, role, tag + "-copy")], to: copy)
          try fourthCommit(fourthRead(copy, tool))
          let evidence = try fourthSnapshot("evidence", where: "source='\(foreign.deletingPathExtension().lastPathComponent)'")
          let events = try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
          let payloads = try fourthSnapshot("agent_log_payloads", where: "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(foreign.path))')")
          let cursor = try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
          let verifyForeign = {
            XCTAssertEqual(try self.fourthSnapshot("evidence", where: "source='\(foreign.deletingPathExtension().lastPathComponent)'"), evidence)
            XCTAssertEqual(try self.fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), events)
            XCTAssertEqual(try self.fourthSnapshot("agent_log_payloads", where: "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(foreign.path))')"), payloads)
            XCTAssertEqual(try self.fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), cursor)
          }
          try fourthReopen()
          try append(Data((try fourthMetadata(tool, b) + "\n" + fourthMarker() + "\n" + fourthRecord(tool, role, tag + "-late") + "\n").utf8), to: own)
          let discovering = try fourthRead(own, tool)
          let state = try AgentLogState.decode(discovering.position.state)
          XCTAssertEqual(state.session?.storedKey, a)
          XCTAssertEqual(state.ownershipSession?.storedKey, b)
          XCTAssertEqual(state.ownedSession?.storedKey, b)
          XCTAssertTrue(discovering.events.isEmpty)
          let registry = AgentLogFiles.ownSources(appDataDirectory: root)
          XCTAssertTrue(try registry.containsSession(b, tool: tool))
          XCTAssertFalse(try registry.containsSession(a, tool: tool))
          // Remove reader receipts to exercise the writer's independent attribution.
          try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
          let count = try eventCount()
          try store.connection.run("CREATE TRIGGER invented_fifth_failure BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
          XCTAssertThrowsError(try fourthCommit(discovering))
          XCTAssertEqual(try eventCount(), count)
          try verifyForeign()
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id IN (?,?)", [.key(a), .key(b)]), 0)
          XCTAssertFalse(try registry.containsSession(a, tool: tool))
          try store.connection.run("DROP TRIGGER invented_fifth_failure")
          try fourthReopen()
          try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
          try fourthCommit(discovering)
          try verifyForeign()
          XCTAssertEqual(try eventCount("session_id='\(b)' OR source='\(AgentLogEventParser.pathIdentity(own.path))' OR source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE source IN (?,?)", [.key(AgentLogEventParser.pathIdentity(own.path)), .key(AgentLogEventParser.pathIdentity(copy.path))]), 0)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(a)]), 0)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(tool.rawValue), .key(b)]), 1)
          try fourthReopen()
          try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
          let future = try file(tool, name: tag + "-future.jsonl")
          try write([fourthMetadata(tool, a), fourthRecord(tool, "user", tag + "-future")], to: future)
          let admitted = try fourthRead(future, tool)
          XCTAssertEqual(admitted.events.count, 2)
          XCTAssertEqual(admitted.evidence.count, 1)
          try fourthCommit(admitted)
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(future.path))'"), 2)
          // The owned identity is still blocked solely by the completed database receipt.
          let blocked = try file(tool, name: tag + "-blocked.jsonl")
          try write([fourthMetadata(tool, b), fourthRecord(tool, role, tag + "-blocked")], to: blocked)
          try fourthCommit(fourthRead(blocked, tool))
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(blocked.path))'"), 0)
          try verifyForeign()
          XCTAssertTrue(try fourthRead(foreign, tool).events.isEmpty)
          try fourthCommit(fourthRead(own, tool))
          try fourthReopen()
          try verifyForeign()
          XCTAssertFalse(try registry.containsSession(a, tool: tool))
        }
      }
    }
  }

  func testPhysicalOwnershipAndUnboundMarkerDoNotPromoteCooccurringSessions() throws {
    for tool in AgentLogTool.allCases {
      for receipt in [false, true] {
        let tag = "invented-unbound-\(tool)-\(receipt)"
        let url = try file(tool, name: tag + ".jsonl")
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        if receipt { try registry.registerPath(url, tool: tool) }
        try write((receipt ? [] : [try fourthMarker()]) + [try fourthMetadata(tool, tag), fourthRecord(tool, "user", tag)], to: url)
        if !receipt {
          // A legacy ordinary cursor can be past metadata that follows the unbound marker.
          // Rewinding lookahead must not borrow that later ordinary identity.
          let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
          var legacy = AgentLogState()
          legacy.metadataVersion = 0
          legacy.session = AgentLogIdentityCodec.session(tag)
          legacy.ownershipScanOffset = source.size
          try store.saveLogPosition(LogPosition(path: source.path, device: source.device, inode: source.inode,
            offset: source.size, state: legacy.encoded(), seenAt: 199))
          try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.ownedSession') WHERE path=?", [.key(AgentLogEventParser.pathIdentity(url.path))])
        }
        for _ in 0..<3 {
          let batch = try fourthRead(url, tool)
          XCTAssertNil(try AgentLogState.decode(batch.position.state).ownedSession)
          XCTAssertTrue(batch.events.isEmpty)
          try fourthCommit(batch)
          try fourthReopen()
          XCTAssertFalse(try registry.containsSession(tag, tool: tool))
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id=?", [.key(tag)]), 0)
        }
      }
    }
    var state = AgentLogState()
    state.ownedSession = AgentLogIdentityCodec.session("sk-inventedABCDEFGHIJKLMNOPQRSTUV123456789")
    XCTAssertFalse(try state.encoded().contains("sk-invented"))
  }

  func testFullLegacySessionRevocationUnionUsesPhysicalSourceIndex() throws {
    for tool in AgentLogTool.allCases {
      let tag = "invented-legacy-plan-\(tool)"
      let url = try file(tool, name: tag + ".jsonl")
      try write([fourthMetadata(tool, tag), fourthRecord(tool, "user", tag)], to: url)
      try fourthCommit(fourthRead(url, tool))
      try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.tool') WHERE path=?", [.key(AgentLogEventParser.pathIdentity(url.path))])
      let args = ActivityStorage.ownLogSessionSourceValues(AgentLogIdentityCodec.session(tag), tool: tool)
      var plans: [String] = []
      try store.connection.namedRows("EXPLAIN QUERY PLAN " + ActivityStorage.ownLogSessionSourcesSQL, args) { plans.append(try $0.text("detail")) }
      let details = plans.joined(separator: "; ")
      XCTAssertTrue(plans.contains { $0.contains("agent_log_inherited_session (tool=? AND session_id=?)") }, details)
      XCTAssertTrue(plans.contains { $0.contains("agent_log_event_session (tool=? AND session_id=?)") }, details)
      XCTAssertTrue(plans.contains { $0.contains("log_positions_session") }, details)
      XCTAssertTrue(plans.contains { $0.contains("log_positions_ownership_session") }, details)
      XCTAssertEqual(plans.filter { $0.contains("COVERING INDEX agent_log_events_tool_source (tool=? AND device=? AND inode=? AND source=?)") }.count, 4, details)
      XCTAssertFalse(plans.contains { $0.contains("SCAN e") || $0.contains("agent_log_events_session") }, details)
      try store.purgeOwnLogSession(AgentLogIdentityCodec.session(tag), tool: tool)
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 0)
      // Main adoption installs the index without rewriting its checkpoint.
      try makeMainLogOrigin(store)
      let before = try fourthSnapshot("log_positions")
      try fourthReopen()
      XCTAssertEqual(try fourthSnapshot("log_positions"), before)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sqlite_master WHERE name='agent_log_events_tool_source'"), 1)
    }
  }
}

extension AgentLogTests {
  func testKnownSessionReceiptNeverPromotesOtherPreparedBatchSessions() throws {
    for tool in AgentLogTool.allCases {
      for durable in [false, true] {
        let tag = "invented-prepared-mixed-\(tool)-\(durable)"
        let a = tag + "-A", b = tag + "-B"
        let foreign = try file(tool, name: tag + "-foreign.jsonl")
        let mixed = try file(tool, name: tag + "-mixed.jsonl")
        try write([fourthMetadata(tool, a), fourthRecord(tool, "user", tag + "-foreign")], to: foreign)
        try fourthCommit(fourthRead(foreign, tool))
        let foreignEvents = try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        let foreignEvidence = try fourthSnapshot("evidence")
        let cursor = try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        try write([fourthMetadata(tool, a), fourthRecord(tool, "user", tag + "-A"),
          fourthMetadata(tool, b), fourthRecord(tool, "user", tag + "-B")], to: mixed)
        let prepared = try fourthRead(mixed, tool)
        XCTAssertEqual(prepared.events.first?.session?.storedKey, a)
        XCTAssertEqual(prepared.events.last?.session?.storedKey, b)
        XCTAssertNil(try AgentLogState.decode(prepared.position.state).ownedSession)
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        if durable { try store.purgeOwnLogSession(AgentLogIdentityCodec.session(b), tool: tool) }
        else { try registry.registerSession(b, tool: tool) }
        try fourthReopen()
        try fourthCommit(prepared)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(mixed.path))'"), 0)
        XCTAssertEqual(try fourthSnapshot("agent_log_events", where: "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignEvents)
        XCTAssertEqual(try fourthSnapshot("evidence"), foreignEvidence)
        XCTAssertEqual(try fourthSnapshot("log_positions", where: "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), cursor)
        XCTAssertFalse(try registry.containsSession(a, tool: tool))
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id=?", [.key(a)]), 0)
      }
    }
  }
}

extension AgentLogTests {
  func testPositiveCheckpointOwnershipCannotCrossToolIdentity() throws {
    for owner in AgentLogTool.allCases {
      let other: AgentLogTool = owner == .claude ? .codex : .claude
      let session = "invented-tool-boundary-\(owner)"
      let shared = try file(owner, name: session + "-shared.jsonl")
      let registry = AgentLogFiles.ownSources(appDataDirectory: root)
      try registry.registerSession(session, tool: owner)
      try write([fourthMetadata(owner, session), fourthRecord(owner, "user", session + "-owned")], to: shared)
      try fourthCommit(fourthRead(shared, owner))
      XCTAssertEqual(try AgentLogState.decode(XCTUnwrap(store.logPosition(path: shared.path)).state).ownedSession?.storedKey, session)
      let cursor = try XCTUnwrap(store.logPosition(path: shared.path))
      try fourthReopen()
      // Symlinked discovery roots can present one canonical path to both readers.
      let changed = try fourthRead(shared, other)
      XCTAssertEqual(changed.position.offset, cursor.offset)
      XCTAssertNil(try AgentLogState.decode(changed.position.state).ownedSession)
      XCTAssertFalse(try registry.containsSession(session, tool: other))
      try fourthCommit(changed)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE tool=? AND session_id=?", [.key(other.rawValue), .key(session)]), 0)
      let foreign = try file(other, name: session + "-foreign.jsonl")
      try write([fourthMetadata(other, session), fourthRecord(other, "user", session + "-foreign")], to: foreign)
      let admitted = try fourthRead(foreign, other)
      XCTAssertEqual(admitted.events.count, 2)
      XCTAssertEqual(admitted.evidence.count, 1)
      try fourthCommit(admitted)
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 2)
    }
  }
}
