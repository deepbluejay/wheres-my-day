import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  private func sixthRead(_ url: URL, _ tool: AgentLogTool) throws -> AgentLogBatch {
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
    return try AgentLogFiles.read(source, tool: tool, position: store.logPosition(path: url.path), at: 200,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
  }
  private func sixthCommit(_ batch: AgentLogBatch) throws {
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  }
  private func sixthReopen() throws {
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
  }
  private func sixthMetadata(_ tool: AgentLogTool, _ session: String, own: Bool = false) throws -> String {
    var record: [String: Any] = tool == .claude ? ["type": "system", "sessionId": session]
      : ["type": "session_meta", "payload": ["id": session]]
    if own { record["cwd"] = "/invented/" + AgentWindowIdentity.relativeFolder }
    return try json(record)
  }
  private func sixthRecord(_ tool: AgentLogTool, _ thread: String, _ role: String, _ id: String, own: Bool = false) throws -> String {
    var record: [String: Any] = tool == .claude
      ? ["type": role, "timestamp": stamp(100), "sessionId": thread, "uuid": id,
         "message": ["role": role, "content": "Invented sixth repair instruction"]]
      : ["type": "event_msg", "timestamp": stamp(100), "payload": [
          "type": "item_completed", "thread_id": thread, "turn_id": "invented-turn",
          "item": ["type": role == "user" ? "UserMessage" : "InventedRecord", "role": role,
            "id": id, "content": [["type": "text", "text": "Invented sixth repair instruction"]]]]]
    if own { record["cwd"] = "/invented/" + AgentWindowIdentity.relativeFolder }
    return try json(record)
  }
  private func sixthSnapshot(_ table: String, _ predicate: String = "1") throws -> [String] {
    var columns: [String] = []
    try store.connection.namedRows("PRAGMA table_info(\(table))") { columns.append(try $0.text("name")) }
    var rows: [String] = []
    let expression = columns.map { "typeof(\($0))||':'||quote(\($0))" }.joined(separator: "||'|'||")
    try store.connection.namedRows("SELECT \(expression) AS value FROM \(table) WHERE \(predicate) ORDER BY rowid") {
      rows.append(try $0.text("value"))
    }
    return rows
  }

  func testEventOnlyThreadRevocationAllRolesBothOrdersRollbackAndReopen() throws {
    for role in ["user", "assistant", "tool", "system"] {
      for ownFirst in [false, true] {
        let tag = "invented-sixth-\(role)-\(ownFirst)", thread = "invented-thread-\(role)-\(ownFirst)"
        let foreignThread = tag + "-foreign-thread"
        let foreign = try file(.codex, name: tag + "-foreign.jsonl")
        let copy = try file(.codex, name: tag + "-copy.jsonl")
        let own = try file(.codex, name: tag + "-discovery.jsonl")
        try write([sixthRecord(.codex, foreignThread, "user", tag + "-foreign")], to: foreign)
        try sixthCommit(sixthRead(foreign, .codex))
        let evidence = try sixthSnapshot("evidence")
        let foreignEvents = try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        let foreignPayloads = try sixthSnapshot("agent_log_payloads", "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(foreign.path))')")
        let foreignCursor = try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        try write([sixthRecord(.codex, thread, role, tag + "-copy")], to: copy)
        let prepared = try sixthRead(copy, .codex)
        XCTAssertNil(prepared.events.first?.session)
        XCTAssertEqual(prepared.events.first?.explicitSession?.storedKey, thread)
        XCTAssertNil(try AgentLogState.decode(prepared.position.state).session)
        if !ownFirst {
          try sixthCommit(prepared)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_event_sessions WHERE session_id=?", [.key(thread)]), 1)
        }
        // A separate header-plus-marker source establishes exactly this thread's ownership.
        try write([sixthMetadata(.codex, thread, own: true)], to: own)
        let discovery = try sixthRead(own, .codex)
        let count = try eventCount()
        try store.connection.run("CREATE TRIGGER invented_sixth_abort BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
        XCTAssertThrowsError(try sixthCommit(discovery))
        XCTAssertEqual(try eventCount(), count)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id=?", [.key(thread)]), 0)
        try store.connection.run("DROP TRIGGER invented_sixth_abort")
        try sixthReopen()
        try sixthCommit(discovery)
        if ownFirst { try sixthCommit(prepared) }
        for _ in 0..<2 {
          try sixthReopen()
          let blocked = try sixthRead(copy, .codex)
          XCTAssertTrue(blocked.events.isEmpty)
          XCTAssertTrue(blocked.evidence.isEmpty)
          try sixthCommit(blocked)
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))' OR source='\(AgentLogEventParser.pathIdentity(own.path))'"), 0)
          XCTAssertEqual(try sixthSnapshot("evidence"), evidence)
          XCTAssertEqual(try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignEvents)
          XCTAssertEqual(try sixthSnapshot("agent_log_payloads", "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(foreign.path))')"), foreignPayloads)
          XCTAssertEqual(try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignCursor)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id=?", [.key(foreignThread)]), 0)
          XCTAssertFalse(try AgentLogFiles.ownSources(appDataDirectory: root).containsSession(foreignThread, tool: .codex))
        }
      }
    }
  }

  func testPreparedExplicitThreadsHonorFilesystemAndDatabaseReceiptsEveryRole() throws {
    for role in ["user", "assistant", "tool", "system"] {
      for durable in [false, true] {
        let tag = "invented-prepared-sixth-\(role)-\(durable)"
        let a = tag + "-A", b = tag + "-B"
        let foreign = try file(.codex, name: tag + "-foreign.jsonl")
        let mixed = try file(.codex, name: tag + "-mixed.jsonl")
        try write([sixthRecord(.codex, a, "user", tag + "-foreign")], to: foreign)
        try sixthCommit(sixthRead(foreign, .codex))
        let evidence = try sixthSnapshot("evidence")
        let events = try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        let cursor = try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        try write([sixthRecord(.codex, a, role, tag + "-A"), sixthRecord(.codex, b, role, tag + "-B")], to: mixed)
        let prepared = try sixthRead(mixed, .codex)
        XCTAssertEqual(prepared.events.map { $0.explicitSession?.storedKey }, [a, b])
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        if durable {
          try store.purgeOwnLogSession(AgentLogIdentityCodec.session(b), tool: .codex)
          let receipts = root.appendingPathComponent(AgentLogOwnSources.folderName)
          if FileManager.default.fileExists(atPath: receipts.path) { try FileManager.default.removeItem(at: receipts) }
        } else { try registry.registerSession(b, tool: .codex) }
        try sixthReopen()
        try sixthCommit(prepared)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(mixed.path))'"), 0)
        XCTAssertEqual(try sixthSnapshot("evidence"), evidence)
        XCTAssertEqual(try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), events)
        XCTAssertEqual(try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), cursor)
        XCTAssertFalse(try registry.containsSession(a, tool: .codex))
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id=?", [.key(a)]), 0)
        // A header-free source read after a filesystem receipt is rejected before append.
        let later = try file(.codex, name: tag + "-later.jsonl")
        try write([sixthRecord(.codex, b, role, tag + "-later")], to: later)
        XCTAssertTrue(try sixthRead(later, .codex).events.isEmpty)
      }
    }
  }

  func testExplicitThreadMarkerDoesNotBorrowHeaderOrLineageOwnership() throws {
    let a = "invented-sixth-header-A", b = "invented-sixth-explicit-B"
    let foreign = try file(.codex, name: "invented-sixth-header-foreign.jsonl")
    let own = try file(.codex, name: "invented-sixth-header-marker.jsonl")
    try write([sixthMetadata(.codex, a), sixthRecord(.codex, a, "user", "invented-foreign")], to: foreign)
    try sixthCommit(sixthRead(foreign, .codex))
    let evidence = try sixthSnapshot("evidence")
    try write([sixthMetadata(.codex, a), sixthRecord(.codex, b, "system", "invented-marker", own: true)], to: own)
    let batch = try sixthRead(own, .codex)
    XCTAssertEqual(try AgentLogState.decode(batch.position.state).ownedSession?.storedKey, b)
    try sixthCommit(batch)
    XCTAssertEqual(try sixthSnapshot("evidence"), evidence)
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    XCTAssertFalse(try registry.containsSession(a, tool: .codex))
    XCTAssertTrue(try registry.containsSession(b, tool: .codex))
    // Parent/child references and native item IDs are not current-thread ownership facts.
    let unrelated = try file(.codex, name: "invented-sixth-lineage.jsonl")
    try write([json(["type": "event_msg", "timestamp": stamp(100), "payload": [
      "thread_id": a, "parent_thread_id": b, "turn_id": b,
      "item": ["id": b, "type": "InventedRecord", "child_thread_id": b]]])], to: unrelated)
    XCTAssertEqual(try sixthRead(unrelated, .codex).events.count, 1)
  }

  func testItemOriginatorMarkerBindsExplicitThreadEveryRoleBothOrders() throws {
    for role in ["user", "assistant", "tool", "system"] {
      for ownFirst in [false, true] {
        let tag = "invented-sixth-item-marker-\(role)-\(ownFirst)"
        let a = tag + "-A", b = tag + "-B"
        let foreign = try file(.codex, name: tag + "-foreign.jsonl")
        let own = try file(.codex, name: tag + "-own.jsonl")
        let copy = try file(.codex, name: tag + "-copy.jsonl")
        try write([sixthRecord(.codex, a, "user", tag + "-foreign")], to: foreign)
        try sixthCommit(sixthRead(foreign, .codex))
        let evidence = try sixthSnapshot("evidence")
        let events = try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        let cursor = try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(foreign.path))'")
        try write([sixthRecord(.codex, b, role, tag + "-copy")], to: copy)
        if !ownFirst { try sixthCommit(sixthRead(copy, .codex)) }
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sixthRecord(.codex, b, role, tag).utf8)) as? [String: Any])
        var payload = try XCTUnwrap(record["payload"] as? [String: Any])
        var item = try XCTUnwrap(payload["item"] as? [String: Any])
        item["originator"] = AgentWindowIdentity.codexOriginator
        payload["item"] = item
        record["payload"] = payload
        try write([sixthMetadata(.codex, a), json(record)], to: own)
        let batch = try sixthRead(own, .codex)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(try AgentLogState.decode(batch.position.state).ownedSession?.storedKey, b)
        try sixthCommit(batch)
        if ownFirst { try sixthCommit(sixthRead(copy, .codex)) }
        try sixthReopen()
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(own.path))' OR source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
        XCTAssertEqual(try sixthSnapshot("evidence"), evidence)
        XCTAssertEqual(try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), events)
        XCTAssertEqual(try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(foreign.path))'"), cursor)
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        XCTAssertTrue(try registry.containsSession(b, tool: .codex))
        XCTAssertFalse(try registry.containsSession(a, tool: .codex))
      }
    }
  }

  func testToollessCheckpointCannotBorrowOtherToolReceiptBothDirectionsAndAppend() throws {
    for original in AgentLogTool.allCases {
      for legacy in [false, true] {
        let other: AgentLogTool = original == .claude ? .codex : .claude
        let tag = "invented-sixth-tools-\(original)-\(legacy)"
        let shared = try file(original, name: tag + "-shared.jsonl")
        try write([sixthMetadata(original, tag), sixthRecord(original, tag, "user", tag + "-first")], to: shared)
        try sixthCommit(sixthRead(shared, original))
        let evidence = try sixthSnapshot("evidence")
        let events = try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(shared.path))'")
        let payloads = try sixthSnapshot("agent_log_payloads", "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(shared.path))')")
        let cursor = try XCTUnwrap(store.logPosition(path: shared.path)).offset
        if legacy { try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.tool','$.ownershipSession','$.ownedSession') WHERE path=?", [.key(AgentLogEventParser.pathIdentity(shared.path))]) }
        try AgentLogFiles.ownSources(appDataDirectory: root).registerSession(tag, tool: other)
        try sixthReopen()
        let alias = root.appendingPathComponent(tag + "-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: shared.deletingLastPathComponent())
        let listed = try AgentLogFiles.listing([alias.path, shared.deletingLastPathComponent().path])
        XCTAssertEqual(listed.files.filter { $0.path == shared.path }.count, 1)
        let changed = try sixthRead(shared, other)
        XCTAssertEqual(changed.position.offset, cursor)
        XCTAssertNil(try AgentLogState.decode(changed.position.state).ownedSession)
        try sixthCommit(changed)
        XCTAssertEqual(try sixthSnapshot("evidence"), evidence)
        XCTAssertEqual(try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(shared.path))'"), events)
        XCTAssertEqual(try sixthSnapshot("agent_log_payloads", "id IN (SELECT payload_id FROM agent_log_events WHERE source='\(AgentLogEventParser.pathIdentity(shared.path))')"), payloads)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_tool_own_sources WHERE path=?", [.key(AgentLogEventParser.pathIdentity(shared.path))]), 0)
        try sixthReopen()
        try append(Data((try sixthRecord(original, tag, "user", tag + "-second") + "\n").utf8), to: shared)
        let resumed = try sixthRead(shared, original)
        XCTAssertEqual(resumed.events.count, 1)
        XCTAssertEqual(resumed.events.first?.offset, cursor)
        XCTAssertEqual(try AgentLogState.decode(resumed.position.state).session?.storedKey, tag)
        try sixthCommit(resumed)
        XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(shared.path))'"), 3)
        XCTAssertEqual(try store.evidence(in: all).filter { $0.source == shared.deletingPathExtension().lastPathComponent }.count, 2)
      }
    }
  }

  func testSameToolLegacyMetadataRecoveryPreservesCommittedCursor() throws {
    for tool in AgentLogTool.allCases {
      let tag = "invented-sixth-recover-\(tool)"
      let url = try file(tool, name: tag + ".jsonl")
      try write([sixthMetadata(tool, tag), sixthRecord(tool, tag, "user", tag + "-first")], to: url)
      try sixthCommit(sixthRead(url, tool))
      let offset = try XCTUnwrap(store.logPosition(path: url.path)).offset
      try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.tool','$.ownershipSession','$.ownedSession') WHERE path=?", [.key(AgentLogEventParser.pathIdentity(url.path))])
      try sixthReopen()
      let eof = try sixthRead(url, tool)
      XCTAssertTrue(eof.events.isEmpty)
      XCTAssertEqual(eof.position.offset, offset)
      XCTAssertEqual(try AgentLogState.decode(eof.position.state).session?.storedKey, tag)
      try sixthCommit(eof)
      try append(Data((try sixthRecord(tool, tag, "assistant", tag + "-second") + "\n").utf8), to: url)
      let later = try sixthRead(url, tool)
      XCTAssertEqual(later.events.count, 1)
      XCTAssertEqual(later.events.first?.offset, offset)
      XCTAssertEqual(later.events.first?.session?.storedKey, tag)
    }
  }

  func testPhysicalOwnershipAndPreparedPathReceiptsAreToolScoped() throws {
    for owner in AgentLogTool.allCases {
      let other: AgentLogTool = owner == .claude ? .codex : .claude
      let tag = "invented-sixth-physical-\(owner)"
      let shared = try file(owner, name: tag + ".jsonl")
      try write([sixthRecord(owner, tag + "-own", "user", tag + "-own")], to: shared)
      let prepared = try sixthRead(shared, owner)
      try AgentLogFiles.ownSources(appDataDirectory: root).registerPath(shared, tool: owner)
      try sixthCommit(prepared)
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(shared.path))'"), 0)
      try sixthReopen()
      try append(Data((try sixthRecord(other, tag + "-foreign", "user", tag + "-foreign") + "\n").utf8), to: shared)
      try sixthCommit(sixthRead(shared, other))
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(shared.path))' AND tool='\(other.rawValue)'"), 1)
      let evidence = try sixthSnapshot("evidence")
      let events = try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(shared.path))'")
      try sixthReopen()
      try sixthCommit(sixthRead(shared, owner))
      XCTAssertEqual(try sixthSnapshot("evidence"), evidence)
      XCTAssertEqual(try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(shared.path))'"), events)
    }
  }

  func testWriterDiscardsUnscopedCheckpointProofAndRejectsMixedNamespaces() throws {
    let tag = "invented-sixth-writer-namespace"
    let url = try file(.codex, name: tag + ".jsonl")
    try write([sixthRecord(.codex, tag, "user", tag)], to: url)
    let prepared = try sixthRead(url, .codex)
    try AgentLogFiles.ownSources(appDataDirectory: root).registerSession(tag + "-other", tool: .codex)
    for namespace in [String?.none, "invented-unknown-tool"] {
      var legacy = AgentLogState()
      legacy.tool = namespace
      legacy.session = AgentLogIdentityCodec.session(tag + "-other")
      legacy.ownedSession = AgentLogIdentityCodec.session(tag + "-other")
      legacy.ownWorkingFolder = true
      var position = prepared.position
      position.state = try legacy.encoded()
      try store.appendLogEvents(prepared.events, evidence: prepared.evidence, position: position)
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 1)
      XCTAssertEqual(try store.evidence(in: all).count, 1)
    }
    var mixed = prepared.events
    mixed[0].tool = .claude
    XCTAssertThrowsError(try store.appendLogEvents(mixed, evidence: prepared.evidence, position: prepared.position))
    XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(url.path))'"), 1)
  }

  func testAmbiguousLegacyPhysicalProvenanceCannotAttributeCheckpointToEitherTool() throws {
    for tool in AgentLogTool.allCases {
      let other: AgentLogTool = tool == .claude ? .codex : .claude
      let tag = "invented-sixth-ambiguous-\(tool)"
      let url = try file(tool, name: tag + ".jsonl")
      try write([sixthRecord(tool, tag + "-foreign-A", "user", tag + "-A")], to: url)
      try sixthCommit(sixthRead(url, tool))
      try append(Data((try sixthRecord(other, tag + "-foreign-B", "user", tag + "-B") + "\n").utf8), to: url)
      try sixthCommit(sixthRead(url, other))
      var legacy = AgentLogState()
      legacy.session = AgentLogIdentityCodec.session(tag + "-unproven")
      legacy.ownershipSession = AgentLogIdentityCodec.session(tag + "-unproven")
      var position = try XCTUnwrap(store.logPosition(path: url.path))
      position.state = try legacy.encoded()
      try store.saveLogPosition(position)
      let events = try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(url.path))'")
      let evidence = try sixthSnapshot("evidence")
      let cursor = try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(url.path))'")
      try sixthReopen()
      for namespace in [tool, other] { try store.purgeOwnLogSession(AgentLogIdentityCodec.session(tag + "-unproven"), tool: namespace) }
      XCTAssertEqual(try sixthSnapshot("agent_log_events", "source='\(AgentLogEventParser.pathIdentity(url.path))'"), events)
      XCTAssertEqual(try sixthSnapshot("evidence"), evidence)
      XCTAssertEqual(try sixthSnapshot("log_positions", "path='\(AgentLogEventParser.pathIdentity(url.path))'"), cursor)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_tool_own_sources WHERE path=?", [.key(AgentLogEventParser.pathIdentity(url.path))]), 0)
    }
  }

  func testExplicitSessionMaskingAdoptionCleanupAndPreviewFreshness() throws {
    let url = try file(.codex, name: "invented-sixth-attribution.jsonl")
    try write([sixthRecord(.codex, "invented-sixth-attribution", "user", "invented-attribution")], to: url)
    var batch = try sixthRead(url, .codex)
    batch.events[0].explicitSession = AgentLogIdentityCodec.session("sk-inventedABCDEFGHIJKLMNOPQRSTUV123456789")
    try sixthCommit(batch)
    XCTAssertFalse(try sixthSnapshot("agent_log_event_sessions").joined().contains("sk-invented"))
    let preview = try store.previewDeletion(in: TimeRange(100, 101))
    try store.connection.run("UPDATE agent_log_event_sessions SET session_id='invented-changed'")
    XCTAssertNotEqual(try store.previewDeletion(in: preview.range).confirmation, preview.confirmation)
    XCTAssertThrowsError(try store.deleteRecords(in: preview.range, confirmation: preview.confirmation))
    try makeMainLogOrigin(store)
    let cursor = try sixthSnapshot("log_positions")
    try sixthReopen()
    XCTAssertEqual(try sixthSnapshot("log_positions"), cursor)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM sqlite_master WHERE name IN ('agent_log_event_sessions','agent_log_event_session','agent_log_event_session_cleanup','agent_log_tool_own_sources')"), 4)
    try sixthCommit(batch)
    let current = try store.previewDeletion(in: TimeRange(100, 101))
    try store.deleteRecords(in: current.range, confirmation: current.confirmation)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_event_sessions"), 0)
  }
}
