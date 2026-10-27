import Core
import Foundation
@testable import Inbound
@testable import Storage
import XCTest

extension AgentLogTests {
  private func thirdSource(_ url: URL) throws -> AgentLogFile {
    try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
  }
  private func thirdRead(_ url: URL, tool: AgentLogTool) throws -> AgentLogBatch {
    try AgentLogFiles.read(thirdSource(url), tool: tool, position: store.logPosition(path: url.path), at: 200,
      ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
  }
  private func thirdCommit(_ batch: AgentLogBatch) throws {
    try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
  }
  private func thirdReopen() throws {
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root,
      databaseScope: .directory(root))
  }
  private func thirdMetadata(_ tool: AgentLogTool, session: String, own: Bool = false) throws -> String {
    if tool == .claude {
      var fields: [String: Any] = ["type": "system", "sessionId": session]
      if own { fields["cwd"] = "/invented/" + AgentWindowIdentity.relativeFolder }
      return try json(fields)
    }
    var payload: [String: Any] = ["id": session]
    if own { payload["originator"] = AgentWindowIdentity.codexOriginator }
    return try json(["type": "session_meta", "payload": payload])
  }
  private func thirdRecord(_ tool: AgentLogTool, role: String, id: String) throws -> String {
    if tool == .claude {
      return try json(["type": role, "timestamp": stamp(100), "uuid": id,
        "message": ["role": role, "content": "Invented third repair instruction"]])
    }
    return try json(["type": "event_msg", "timestamp": stamp(100), "payload": [
      "type": "item_completed", "thread_id": "invented-explicit-thread", "turn_id": "invented-turn",
      "item": ["type": role == "user" ? "UserMessage" : "InventedRecord", "role": role, "id": id,
        "content": [["type": "text", "text": "Invented third repair instruction"]]]]])
  }
  func testDiscoveredOwnSessionsRevokeEveryRoleBothOrdersSplitRestartAndRollback() throws {
    for tool in AgentLogTool.allCases {
      for role in ["user", "assistant", "tool", "system"] {
        for ownFirst in [false, true] {
          for split in [false, true] {
            let tag = "invented-\(tool)-\(role)-\(ownFirst)-\(split)"
            let session = tag + "-session"
            let own = try file(tool, name: tag + "-own.jsonl")
            let copy = try file(tool, name: tag + "-copy.jsonl")
            let foreign = try file(tool, name: tag + "-foreign.jsonl")
            try write([thirdMetadata(tool, session: session), thirdRecord(tool, role: role, id: tag + "-copy")], to: copy)
            try write([thirdMetadata(tool, session: tag + "-other"), thirdRecord(tool, role: "user", id: tag + "-foreign")], to: foreign)
            try thirdCommit(thirdRead(foreign, tool: tool))
            let foreignPosition = try XCTUnwrap(store.logPosition(path: foreign.path))
            let foreignEvents = try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'")
            let foreignEvidence = try store.evidence(in: all).count
            if !ownFirst { try thirdCommit(thirdRead(copy, tool: tool)) }
            if split {
              try write([thirdMetadata(tool, session: session), thirdRecord(tool, role: role, id: tag + "-own")], to: own)
              try thirdCommit(thirdRead(own, tool: tool))
              try thirdReopen()
              try append(Data((try thirdMetadata(tool, session: session, own: true) + "\n").utf8), to: own)
            } else {
              try write([thirdMetadata(tool, session: session, own: true), thirdRecord(tool, role: role, id: tag + "-own")], to: own)
            }
            let priorCount = try eventCount()
            let priorEvidence = try store.evidence(in: all).count
            let priorOwnPosition = try store.logPosition(path: own.path)
            let batch = try thirdRead(own, tool: tool)
            XCTAssertTrue(batch.events.isEmpty, tag)
            XCTAssertTrue(batch.evidence.isEmpty, tag)
            XCTAssertEqual(try AgentLogState.decode(batch.position.state).ownershipSession?.storedKey, session)
            XCTAssertTrue(try AgentLogFiles.ownSources(appDataDirectory: root).containsSession(session, tool: tool))
            try store.connection.run("CREATE TRIGGER invented_third_failure BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
            XCTAssertThrowsError(try thirdCommit(batch))
            XCTAssertEqual(try eventCount(), priorCount)
            XCTAssertEqual(try store.evidence(in: all).count, priorEvidence)
            XCTAssertEqual(try store.logPosition(path: own.path)?.offset, priorOwnPosition?.offset)
            try store.connection.run("DROP TRIGGER invented_third_failure")
            try thirdReopen()
            try thirdCommit(thirdRead(own, tool: tool))
            XCTAssertEqual(try eventCount("session_id='\(session)'"), 0, tag)
            XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(own.path))'"), 0, tag)
            XCTAssertEqual(try store.evidence(in: all).count, foreignEvidence, tag)
            XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), foreignEvents)
            XCTAssertEqual(try store.logPosition(path: foreign.path)?.offset, foreignPosition.offset)
            try thirdReopen()
            let copyBatch = try thirdRead(copy, tool: tool)
            XCTAssertTrue(copyBatch.events.isEmpty, tag)
            XCTAssertTrue(copyBatch.evidence.isEmpty, tag)
            try thirdCommit(copyBatch)
            // Launch-style session filenames also exclude copies with no metadata at all.
            let bare = try file(tool, home: root.appendingPathComponent(tag), name: session + ".jsonl")
            try write([thirdRecord(tool, role: role, id: tag + "-bare"), "{invented-malformed"], to: bare)
            let bareBatch = try thirdRead(bare, tool: tool)
            XCTAssertTrue(bareBatch.events.isEmpty, tag)
            XCTAssertTrue(bareBatch.evidence.isEmpty, tag)
            try thirdCommit(bareBatch)
            XCTAssertEqual(try store.evidence(in: all).count, foreignEvidence, tag)
          }
        }
      }
    }
  }
  func testLateOwnPurgePreservesEveryForeignCanonicalReceiptBothToolsAndImportOrders() throws {
    for tool in AgentLogTool.allCases {
      for ownFirst in [false, true] {
        let tag = "invented-shared-\(tool)-\(ownFirst)"
        let foreign = try file(tool, home: root.appendingPathComponent(tag + "-foreign"), name: tag + ".jsonl")
        let own = try file(tool, home: root.appendingPathComponent(tag + "-own"), name: tag + ".jsonl")
        let record = try thirdRecord(tool, role: "user", id: tag)
        try write([thirdMetadata(tool, session: tag + "-foreign"), record], to: foreign)
        try write([thirdMetadata(tool, session: tag + "-own"), record], to: own)
        let before = try store.evidence(in: all).count
        for url in ownFirst ? [own, foreign] : [foreign, own] {
          try thirdCommit(thirdRead(url, tool: tool))
          try thirdReopen()
        }
        XCTAssertEqual(try store.evidence(in: all).count, before + 1)
        let source = try thirdSource(foreign)
        let foreignPosition = try XCTUnwrap(store.logPosition(path: foreign.path))
        var evidenceID = 0
        var payloadIDs: [Int] = []
        try store.connection.namedRows("SELECT evidence_id FROM agent_log_source_evidence WHERE source=?", [.key(AgentLogEventParser.pathIdentity(foreign.path))]) {
          evidenceID = try $0.int("evidence_id")
        }
        XCTAssertGreaterThan(evidenceID, 0)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE evidence_id=?", [.integer(evidenceID)]), 2)
        try store.connection.namedRows("SELECT payload_id FROM agent_log_events WHERE source=? ORDER BY id", [.key(AgentLogEventParser.pathIdentity(foreign.path))]) {
          payloadIDs.append(try $0.int("payload_id"))
        }
        try append(Data((try thirdMetadata(tool, session: tag + "-own", own: true) + "\n").utf8), to: own)
        let ownPosition = try XCTUnwrap(store.logPosition(path: own.path))
        let batch = try thirdRead(own, tool: tool)
        try store.connection.run("CREATE TRIGGER invented_third_failure BEFORE INSERT ON log_positions BEGIN SELECT RAISE(ABORT,'invented failure'); END")
        XCTAssertThrowsError(try thirdCommit(batch))
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE evidence_id=?", [.integer(evidenceID)]), 2)
        XCTAssertEqual(try store.logPosition(path: own.path)?.offset, ownPosition.offset)
        try store.connection.run("DROP TRIGGER invented_third_failure")
        try thirdReopen()
        try thirdCommit(thirdRead(own, tool: tool))
        for _ in 0..<2 {
          try thirdReopen()
          try thirdCommit(thirdRead(foreign, tool: tool))
          try thirdCommit(thirdRead(own, tool: tool))
          XCTAssertEqual(try store.evidence(in: all).count, before + 1)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence WHERE id=?", [.integer(evidenceID)]), 1)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE source=? AND evidence_id=?", [.key(AgentLogEventParser.pathIdentity(foreign.path)), .integer(evidenceID)]), 1)
          XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_source_evidence WHERE source=?", [.key(AgentLogEventParser.pathIdentity(own.path))]), 0)
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(foreign.path))'"), 2)
          XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(own.path))'"), 0)
          XCTAssertEqual(try store.logPosition(path: foreign.path)?.offset, foreignPosition.offset)
          XCTAssertEqual(try store.logPosition(path: foreign.path)?.device, source.device)
          XCTAssertEqual(try store.logPosition(path: foreign.path)?.inode, source.inode)
          var remaining: [Int] = []
          try store.connection.namedRows("SELECT payload_id FROM agent_log_events WHERE source=? ORDER BY id", [.key(AgentLogEventParser.pathIdentity(foreign.path))]) {
            remaining.append(try $0.int("payload_id"))
          }
          XCTAssertEqual(remaining, payloadIDs)
          for id in payloadIDs {
            XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads WHERE id=?", [.integer(id)]), 1)
          }
        }
      }
    }
  }
  func testReadOnlyDeletionPreviewAcrossMainAndCurrentLeavesDatabaseBytesUnchanged() throws {
    for version in [9, SQLiteConnection.schemaVersion] {
      let directory = root.appendingPathComponent("invented-schema-\(version)")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appendingPathComponent("invented.sqlite")
      var fixture: ActivityStorage? = try ActivityStorage(url: url, appDataDirectory: directory, databaseScope: .directory(directory))
      try fixture!.appendEvidence([EvidenceText(ts: 100, kind: .prompt, source: "invented-legacy",
        sourceID: "claude:invented-canonical", text: "Invented legacy instruction")])
      if version == 9 { try makeMainLogOrigin(fixture!) }
      else { try fixture!.connection.run("INSERT INTO agent_prompt_aliases VALUES('claude:invented-alias','claude:invented-canonical')") }
      fixture = nil
      let before = try Data(contentsOf: url)
      let wal = try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal"))
      let readOnly = try ActivityStorage(url: url, appDataDirectory: directory, readOnly: true, databaseScope: .directory(directory))
      let preview = try readOnly.previewDeletion(in: TimeRange(100, 101))
      XCTAssertEqual(preview.counts["evidence"], 1)
      XCTAssertEqual(try readOnly.previewDeletion(in: TimeRange(100, 101)).confirmation, preview.confirmation)
      XCTAssertEqual(try readOnly.connection.integer("PRAGMA user_version"), version)
      // Preview owns a separate WAL reader; verify legacy lineage on this reader too.
      try readOnly.resolveDeletionIdentities(TimeRange(100, 101))
      XCTAssertEqual(try readOnly.connection.integer("SELECT count(*) FROM log_identity_component"), version == 9 ? 1 : 2)
      XCTAssertEqual(try Data(contentsOf: url), before)
      XCTAssertEqual(try? Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")), wal)
    }
  }
  func testDiscoveredSessionAfterBoundedLookaheadPurgesPreviouslyCompletedCopies() throws {
    for tool in AgentLogTool.allCases {
      let session = "invented-bounded-\(tool)"
      let own = try file(tool, name: session + "-own.jsonl")
      let copy = try file(tool, name: session + "-copy.jsonl")
      try write([thirdMetadata(tool, session: session), thirdRecord(tool, role: "user", id: session + "-copy")], to: copy)
      try thirdCommit(thirdRead(copy, tool: tool))
      // Lookahead and ordinary acquisition both stop before the later own marker.
      let padding = try json(["type": "invented-padding", "value": String(repeating: "x", count: AgentLogFiles.batchBytes)])
      try write([thirdMetadata(tool, session: session), padding,
        thirdMetadata(tool, session: session, own: true), thirdRecord(tool, role: "assistant", id: session)], to: own)
      let first = try thirdRead(own, tool: tool)
      XCTAssertFalse(first.events.isEmpty)
      XCTAssertLessThan(first.position.offset, try Data(contentsOf: own).count)
      try thirdCommit(first)
      try thirdReopen()
      let last = try thirdRead(own, tool: tool)
      XCTAssertTrue(last.events.isEmpty)
      XCTAssertTrue(try AgentLogFiles.ownSources(appDataDirectory: root).containsSession(session, tool: tool))
      try thirdCommit(last)
      XCTAssertEqual(try eventCount("session_id='\(session)'"), 0)
      XCTAssertTrue(try store.evidence(in: all).isEmpty)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
      let replay = try thirdRead(copy, tool: tool)
      XCTAssertTrue(replay.events.isEmpty)
      XCTAssertTrue(replay.evidence.isEmpty)
    }
  }
  func testLateOwnPurgeRemovesLegacyEvidenceWithExactPhysicalOccurrenceProvenance() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool, name: "invented-physical-\(tool).jsonl")
      try write(["{}"], to: url)
      let source = try thirdSource(url)
      try store.appendEvidence([EvidenceText(ts: 100, kind: .prompt, source: "invented-physical",
        sourceID: "\(tool.rawValue):occurrence:\(source.device):\(source.inode):0", text: "Invented legacy instruction")])
      try append(Data((try thirdMetadata(tool, session: "invented-physical-\(tool)", own: true) + "\n").utf8), to: url)
      try thirdCommit(thirdRead(url, tool: tool))
      XCTAssertTrue(try store.evidence(in: all).isEmpty)
    }
  }
  func testOwnershipReceiptsUseAuthoritativeSessionFieldsOnly() throws {
    for tool in AgentLogTool.allCases {
      let unrelated = "invented-nonsession-payload-\(tool)"
      let session = "invented-authoritative-\(tool)"
      let marker = try json(["type": "system", "cwd": "/invented/" + AgentWindowIdentity.relativeFolder,
        "payload": ["id": unrelated, "session_id": unrelated]])
      for withSession in [false, true] {
        let url = try file(tool, name: "invented-fields-\(tool)-\(withSession).jsonl")
        try write((withSession ? [try thirdMetadata(tool, session: session)] : []) + [marker], to: url)
        let batch = try thirdRead(url, tool: tool)
        XCTAssertTrue(batch.events.isEmpty)
        XCTAssertEqual(try AgentLogState.decode(batch.position.state).ownershipSession?.storedKey, withSession ? session : nil)
        let registry = AgentLogFiles.ownSources(appDataDirectory: root)
        XCTAssertFalse(try registry.containsSession(unrelated, tool: tool))
        XCTAssertEqual(try registry.containsSession(session, tool: tool), withSession)
        try thirdCommit(batch)
      }
      let external = try file(tool, name: "invented-fields-external-\(tool).jsonl")
      try write([thirdMetadata(tool, session: unrelated), thirdRecord(tool, role: "user", id: unrelated)], to: external)
      let allowed = try thirdRead(external, tool: tool)
      XCTAssertEqual(allowed.events.count, 2)
      XCTAssertEqual(allowed.evidence.count, 1)
      try thirdCommit(allowed)
    }
  }
  func testPreexistingOwnCheckpointRegistersSessionAndRevokesPreviouslyAdmittedCopy() throws {
    for tool in AgentLogTool.allCases {
      let session = "invented-preexisting-own-\(tool)"
      let own = try file(tool, name: session + "-own.jsonl")
      let copy = try file(tool, name: session + "-copy.jsonl")
      try write([thirdMetadata(tool, session: session, own: true)], to: own)
      let physical = try thirdSource(own)
      var state = AgentLogState()
      state.session = AgentLogIdentityCodec.session(session)
      state.ownWorkingFolder = true
      state.ownershipScanOffset = physical.size
      try store.saveLogPosition(LogPosition(path: own.path, device: physical.device, inode: physical.inode,
        offset: physical.size, state: state.encoded(), seenAt: 199))
      try store.connection.run("UPDATE log_positions SET state=json_remove(state,'$.ownedSession') WHERE path=?", [.key(AgentLogEventParser.pathIdentity(own.path))])
      try store.connection.run("INSERT INTO agent_log_own_sources VALUES(?,?,?)",
        [.integer(physical.device), .integer(physical.inode), .key(own.path)])
      try AgentLogFiles.ownSources(appDataDirectory: root).registerPath(own, tool: tool)
      try write([thirdMetadata(tool, session: session), thirdRecord(tool, role: "user", id: session)], to: copy)
      try thirdCommit(thirdRead(copy, tool: tool))
      XCTAssertEqual(try store.evidence(in: all).count, 1)
      try thirdReopen()
      try thirdCommit(thirdRead(own, tool: tool))
      XCTAssertTrue(try AgentLogFiles.ownSources(appDataDirectory: root).containsSession(session, tool: tool))
      XCTAssertEqual(try eventCount("session_id='\(session)'"), 0)
      XCTAssertTrue(try store.evidence(in: all).isEmpty)
    }
  }
  func testLateSessionCheckpointRevokesCopyEvenWhenItsMetadataEventWasHistoricallyRefused() throws {
    for tool in AgentLogTool.allCases {
      let session = "invented-late-checkpoint-\(tool)"
      let copy = try file(tool, name: session + "-copy.jsonl")
      let own = try file(tool, name: session + "-own.jsonl")
      try store.saveSettings(StorageSettings(recordingEnabled: false), at: 10)
      try store.saveSettings(StorageSettings(), at: 20)
      try write([thirdRecord(tool, role: "user", id: session), thirdMetadata(tool, session: session)], to: copy)
      try thirdCommit(thirdRead(copy, tool: tool))
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 1)
      XCTAssertEqual(try eventCount("session_id='\(session)'"), 0)
      XCTAssertEqual(try store.evidence(in: all).count, 1)
      XCTAssertEqual(try AgentLogState.decode(try XCTUnwrap(store.logPosition(path: copy.path)).state).session?.storedKey, session)
      try thirdReopen()
      try write([thirdMetadata(tool, session: session, own: true)], to: own)
      try thirdCommit(thirdRead(own, tool: tool))
      XCTAssertEqual(try eventCount("source='\(AgentLogEventParser.pathIdentity(copy.path))'"), 0)
      XCTAssertTrue(try store.evidence(in: all).isEmpty)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
    }
  }
}
