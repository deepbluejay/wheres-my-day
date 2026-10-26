import Core
import Foundation
@testable import Inbound
@testable import Shell
@testable import Storage
import XCTest

extension AgentLogTests {
  private func assertAbsentFromDatabase(_ strings: [String], file: StaticString = #filePath, line: UInt = #line) throws {
    for suffix in ["", "-wal"] {
      let bytes = (try? Data(contentsOf: root.appendingPathComponent("invented.sqlite" + suffix))) ?? Data()
      for string in strings {
        XCTAssertNil(bytes.range(of: Data(string.utf8)), file: file, line: line)
      }
    }
  }
  func testFallbackStringTokensMaskEscapesAndNestedCredentialKeysAtParserAndStorage() throws {
    let secret = "sk-" + String(repeating: "Invented", count: 5)
    let escaped = secret.map { String(format: "\\u%04x", $0.asciiValue!) }.joined()
    let base = "{\"type\":\"assistant\",\"timestamp\":100,\"content\":\"" + escaped + "\"}"
    let nested = try json(["type": "assistant", "timestamp": 100,
      "content": try json(["password": "invented-nested-credential", "safe": "Invented safe text"])])
    let variants: [(Data, Bool)] = [
      (Data(base.dropLast().utf8), false),
      (Data(escaped.utf8), false),
      (Data("{\"password\":{\"value\":\"invented-nested-credential\",\"other\":\"invented-malformed-credential\"}".utf8), false),
      (Data(base.utf8) + Data([0xff]), false),
      (Data(base.dropLast().utf8), true),
      (Data(("{\"content\":\"" + escaped.dropLast(2)).utf8), true),
      (Data(nested.utf8), false),
      (Data(try json(["type": "assistant", "timestamp": 100, "content": escaped]).utf8), false),
      (Data("{\"password\":\"invented-malformed-credential\"".utf8), false),
    ]
    for (index, variant) in variants.enumerated() {
      var state = AgentLogState()
      let event = try XCTUnwrap(AgentLogEventParser.parse(variant.0,
        byteCount: variant.0.count + (variant.1 ? 100 : 0), offset: index, observedAt: 200,
        tool: .claude, file: "invented", state: &state, logsRelativePath: nil, fingerprint: { $0 }))
      XCTAssertTrue(event.payload.contains("[secret]"))
      for value in [secret, escaped, "invented-nested-credential", "invented-malformed-credential"] {
        XCTAssertFalse(event.payload.contains(value))
      }
      try store.appendLogEvents([event], evidence: [], position: LogPosition(
        path: "invented", device: 1, inode: 1, offset: index + 1, state: "{}", seenAt: 200))
      // Storage must sanitize an independently supplied raw payload as well.
      var untrusted = event
      untrusted.offset += 100
      untrusted.payload = String(decoding: variant.0, as: UTF8.self)
      try store.appendLogEvents([untrusted], evidence: [], position: LogPosition(
        path: "invented", device: 1, inode: 1, offset: index + 101, state: "{}", seenAt: 200))
    }
    XCTAssertEqual(try eventCount(), variants.count * 2)
    try assertAbsentFromDatabase([secret, escaped, "invented-nested-credential", "invented-malformed-credential"])
  }
  func testOversizeReaderMasksEscapedCredentialBeforeCommittingCursor() throws {
    let secret = "sk-" + String(repeating: "Invented", count: 5)
    let escaped = secret.map { String(format: "\\u%04x", $0.asciiValue!) }.joined()
    let prefix = "{\"type\":\"assistant\",\"timestamp\":100,\"content\":\"" + escaped + "\",\"tail\":\""
    let bytes = Data((try meta(.claude) + "\n" + prefix).utf8) + Data(repeating: 120, count: AgentLogFiles.longestLineBytes) + Data("\"}\n".utf8)
    let url = try file(.claude)
    try bytes.write(to: url)
    try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 200)
    XCTAssertEqual(try eventCount(), 2)
    XCTAssertEqual(try eventCount("parse_status='truncated'"), 1)
    XCTAssertEqual(try store.logPosition(path: url.path)?.offset, bytes.count)
    try assertAbsentFromDatabase([secret, escaped])
  }
  func testOwnershipPreflightExcludesRecordsBeforeLateOwnMetadataForBothTools() throws {
    for tool in AgentLogTool.allCases {
      let url = try file(tool)
      let early = try json(["type": "file-history-snapshot", "timestamp": 100])
      let own = tool == .claude
        ? try json(["type": "user", "timestamp": stamp(101), "cwd": "/invented/" + AgentWindowIdentity.relativeFolder,
          "message": ["content": "Invented own prompt"]])
        : try json(["type": "session_meta", "payload": ["originator": AgentWindowIdentity.codexOriginator]])
      try write([early, own], to: url)
      try AgentLogTask(reader: reader(tool), storage: store).scan(at: 200)
      XCTAssertEqual(try eventCount(), 0)
      XCTAssertTrue(try store.evidence(in: all).isEmpty)
    }
  }
  func testMissingOwnershipMetadataAdvancesAcrossRestartAndLateOwnDetectionPurges() throws {
    for own in [false, true] {
      let url = try file(.claude, name: "invented-ownership-\(own).jsonl")
      let early = try json(["type": "file-history-snapshot", "timestamp": 100])
      try write([early], to: url)
      let task = AgentLogTask(reader: reader(.claude), storage: store)
      try task.scan(at: 200)
      XCTAssertEqual(try eventCount(), own ? 3 : 1)
      XCTAssertEqual(try store.logPosition(path: url.path)?.offset, early.utf8.count + 1)
      XCTAssertEqual(task.health.ownershipDeferredBatches, 0)
      store = nil
      store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
      let folder = own ? "/invented/" + AgentWindowIdentity.relativeFolder : "/invented/project"
      let metadata = try json(["type": "system", "timestamp": 101, "cwd": folder])
      try append(Data((metadata + "\n").utf8), to: url)
      try AgentLogTask(reader: reader(.claude), storage: store).scan(at: 201)
      XCTAssertEqual(try eventCount(), 2)
      XCTAssertEqual(try store.logPosition(path: url.path)?.offset, early.utf8.count + metadata.utf8.count + 2)
    }
  }
  func testRegisteredOwnPathExcludesMetadataFreeRecordsAcrossByteBoundaryAndRestart() throws {
    let url = try file(.claude)
    let blanks = AgentLogFiles.batchBytes + 10
    try Data(repeating: 10, count: blanks).write(to: url)
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    try registry.registerPath(url, tool: .claude)
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first)
    let first = try AgentLogFiles.read(source, tool: .claude, position: nil, at: 200, ownSources: registry)
    XCTAssertFalse(first.ownershipDeferred)
    XCTAssertEqual(first.position.offset, AgentLogFiles.batchBytes)
    XCTAssertTrue(first.events.isEmpty)
    try store.appendLogEvents(first.events, evidence: first.evidence, position: first.position)
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let second = try AgentLogFiles.read(source, tool: .claude, position: store.logPosition(path: url.path),
      at: 201, ownSources: AgentLogFiles.ownSources(appDataDirectory: root))
    try store.appendLogEvents(second.events, evidence: second.evidence, position: second.position)
    XCTAssertEqual(try eventCount(), 0)
    XCTAssertEqual(second.position.offset, blanks)
  }
  func testTimestampBooleansAndNumericExtremesRemainUnknown() throws {
    for value: Any in [true, false, Double.infinity, -Double.infinity, Double.nan,
      Double(Int.max), Double(Int.min), "1e1000", "-1e1000"] {
      XCTAssertNil(AgentLogEventParser.timestamp(value))
    }
    XCTAssertEqual(AgentLogEventParser.timestamp(NSNumber(value: 1)), 1)
    XCTAssertEqual(AgentLogEventParser.timestamp(-42.5), -42)
    for value in [true, false] {
      var state = AgentLogState()
      let bytes = Data(try json(["type": "assistant", "timestamp": value]).utf8)
      let event = try XCTUnwrap(AgentLogEventParser.parse(bytes, byteCount: bytes.count,
        offset: 0, observedAt: 200, tool: .claude, file: "invented", state: &state,
        logsRelativePath: nil, fingerprint: { $0 }))
      XCTAssertNil(event.timestamp)
      XCTAssertEqual(event.parseStatus, "timestampUnknown")
    }
  }
  func testManySmallRecordsDrainAcrossMemoryBoundedBatchesWithoutLossOrRepeat() throws {
    let url = try file(.claude)
    let count = 1 << 20
    let header = Data((try meta(.claude) + "\n").utf8)
    try (header + Data(repeating: 10, count: count)).write(to: url)
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first)
    var position: LogPosition?
    var seen = 0
    var expectedOffset = 0
    var batches = 0
    while seen < count + 1 {
      let batch = try AgentLogFiles.read(source, tool: .claude, position: position, at: 200)
      XCTAssertFalse(batch.events.isEmpty)
      XCTAssertLessThanOrEqual(batch.events.reduce(0) { $0 + $1.retainedByteEstimate }, AgentLogFiles.batchRetainedBytes)
      for event in batch.events {
        XCTAssertEqual(event.offset, expectedOffset)
        expectedOffset += seen == 0 ? header.count : 1
        seen += 1
      }
      XCTAssertEqual(batch.position.offset, expectedOffset)
      XCTAssertGreaterThan(batch.position.offset, position?.offset ?? -1)
      position = batch.position
      batches += 1
    }
    XCTAssertGreaterThan(batches, 1)
    XCTAssertEqual(seen, count + 1)
    XCTAssertTrue(try AgentLogFiles.read(source, tool: .claude, position: position, at: 201).events.isEmpty)
  }
  func testLateExplicitLinkAndCanonicalOnlyCopyKeepOnePromptAcrossRestartAndOrderings() throws {
    for reverse in [false, true] {
      let a = "claude:late-a-\(reverse)"
      let c = "claude:late-c-\(reverse)"
      func row(_ id: String, aliases: [String] = []) -> EvidenceText {
        EvidenceText(ts: 100, kind: .prompt, source: "invented-\(id)", sourceID: id,
          sourceAliases: aliases, text: "Invented instruction")
      }
      XCTAssertEqual(try store.appendEvidence([row(reverse ? c : a)]).stored, 1)
      XCTAssertEqual(try store.appendEvidence([row(c, aliases: [a])]).stored, 0)
      store = nil
      store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
      XCTAssertEqual(try store.appendEvidence([row(c)]).stored, 0)
      XCTAssertEqual(try store.appendEvidence([row(a)]).stored, 0)
    }
    XCTAssertEqual(try store.evidence(in: all).count, 2)
  }
  func testHistoricalRefusalTraversesKnownAliasesForEveryRoleAndDirectionAcrossRestart() throws {
    for paused in [false, true] {
      for reverse in [false, true] {
        for role in ["user", "assistant", "tool", "system"] {
          let suffix = "\(paused)-\(reverse)-\(role)"
          let a = "a-" + suffix
          let c = "c-" + suffix
          func importRow(_ id: String, command: String? = nil, at time: Int) throws {
            let url = try file(.claude, name: "invented-\(suffix)-\(time).jsonl")
            var fields: [String: Any] = ["type": role, "uuid": id, "timestamp": stamp(time),
              "cwd": "/invented/project", "message": ["role": role, "content": "Invented words"]]
            if let command { fields["commandUuid"] = command }
            try write([json(fields)], to: url)
            let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first { $0.path == url.path })
            let batch = try AgentLogFiles.read(source, tool: .claude, position: nil, at: 600)
            try store.appendLogEvents(batch.events, evidence: batch.evidence, position: batch.position)
          }
          try importRow(reverse ? c : a, at: 100)
          try importRow(a, command: c, at: 200)
          try store.saveSettings(paused ? StorageSettings(pausedUntil: 500) : StorageSettings(recordingEnabled: false), at: 400)
          try store.saveSettings(StorageSettings(), at: 500)
          try importRow(reverse ? c : a, at: 450)
          let before = try eventCount()
          let prompts = try store.evidence(in: all).count
          store = nil
          store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
          try importRow(reverse ? a : c, at: 550)
          XCTAssertEqual(try eventCount(), before, suffix)
          XCTAssertEqual(try store.evidence(in: all).count, prompts, suffix)
        }
      }
    }
  }
  func testDeletionPreviewTracksOnlyReachableAliasEdges() throws {
    try store.appendEvidence([EvidenceText(ts: 100, kind: .prompt, source: "invented",
      sourceID: "claude:preview-root", text: "Invented")])
    let range = TimeRange(100, 101)
    let first = try store.previewDeletion(in: range)
    try store.appendEvidence([EvidenceText(ts: 200, kind: .prompt, source: "invented-copy",
      sourceID: "claude:preview-root", sourceAliases: ["claude:preview-copy"], text: "Invented")])
    let linked = try store.previewDeletion(in: range)
    XCTAssertNotEqual(first.confirmation, linked.confirmation)
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: first.confirmation))
    try store.connection.run("INSERT INTO agent_prompt_edges VALUES('claude:unrelated-a','claude:unrelated-c')")
    XCTAssertEqual(try store.previewDeletion(in: range).confirmation, linked.confirmation)
    try store.connection.run("UPDATE agent_prompt_edges SET canonical='claude:preview-copy' WHERE alias='claude:preview-copy'")
    XCTAssertNotEqual(try store.previewDeletion(in: range).confirmation, linked.confirmation)
    try store.connection.run("UPDATE agent_prompt_edges SET canonical='claude:preview-root' WHERE alias='claude:preview-copy'")
    let restored = try store.previewDeletion(in: range)
    try store.connection.run("DELETE FROM agent_prompt_edges WHERE alias='claude:preview-copy'")
    XCTAssertNotEqual(try store.previewDeletion(in: range).confirmation, restored.confirmation)
    XCTAssertThrowsError(try store.deleteRecords(in: range, confirmation: restored.confirmation))
  }
  func testAliasCyclesAndSameTransactionRefusalAreResolvedBeforePromptContent() throws {
    try store.connection.run("INSERT INTO agent_prompt_aliases VALUES('claude:cycle-a','claude:cycle-b')")
    try store.connection.run("INSERT INTO agent_prompt_aliases VALUES('claude:cycle-b','claude:cycle-c')")
    try store.connection.run("INSERT INTO agent_prompt_aliases VALUES('claude:cycle-c','claude:cycle-a')")
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: 400)
    try store.saveSettings(StorageSettings(), at: 500)
    let rows = [EvidenceText(ts: 550, kind: .prompt, source: "invented", sourceID: "claude:cycle-a", text: "Invented"),
      EvidenceText(ts: 450, kind: .prompt, source: "invented-copy", sourceID: "claude:cycle-c", text: "Invented")]
    let result = try store.appendLogBatch(rows, position: LogPosition(
      path: "invented", device: 1, inode: 1, offset: 2, state: "{}", seenAt: 600))
    XCTAssertEqual(result.stored, 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(DISTINCT source_id) FROM forgotten_sources"), 3)
    XCTAssertTrue(try store.evidence(in: all).isEmpty)
  }
  func testMainAdoptionPayloadCleanupIndexAndRetainedPopulation() throws {
    let original = EvidenceText(ts: 100, kind: .prompt, source: "invented", sourceID: "claude:migration", text: "Invented original")
    try store.appendEvidence([original])
    let position = LogPosition(path: "invented-migration", device: 1, inode: 2, offset: 50, state: "{}", seenAt: 200)
    try store.saveLogPosition(position)
    let before = try store.evidence(in: all)
    let beforeSettings = try store.settings()
    let beforeHistory = try store.logRecordingHistory()
    try makeMainLogOrigin(store)
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try store.evidence(in: all), before)
    XCTAssertEqual(try store.settings(), beforeSettings)
    XCTAssertEqual(try store.logRecordingHistory(), beforeHistory)
    XCTAssertEqual(try store.logPosition(path: position.path)?.offset, position.offset)
    XCTAssertEqual(try eventCount(), 0)
    var plan = ""
    try store.connection.namedRows("EXPLAIN QUERY PLAN SELECT 1 FROM agent_log_events WHERE payload_id=1") { plan += try $0.text("detail") }
    XCTAssertTrue(plan.contains("agent_log_events_payload"))
    XCTAssertFalse(plan.contains("SCAN"))
    try store.connection.transaction {
      for index in 0..<2000 {
        try store.connection.run("INSERT INTO agent_log_payloads(id,digest,payload) VALUES(?,?,?)", [.integer(index + 1), .key("invented-\(index)"), .maskedText(String(repeating: "x", count: 4096))])
        try store.connection.run("""
          INSERT INTO agent_log_events(tool,source,device,inode,byte_offset,ts,timestamp_known,observed_ts,project,record_type,role,flags,parse_status,byte_count,payload_id)
          VALUES('claude','invented',1,1,?,?,1,3000000,'','assistant','assistant','[]','parsed',4096,?)
          """, [.integer(index), .integer(index < 1000 ? 100 : 3000000), .integer(index + 1)])
      }
    }
    _ = try store.cleanRetention(at: 31 * 86400)
    XCTAssertEqual(try eventCount(), 1000)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 1000)
  }
  func testDurableGrowthAndHealthDistinguishProjectionDedupAndPrivacy() throws {
    let url = try file(.claude)
    try store.saveSettings(StorageSettings(recordingEnabled: false), at: 90)
    try store.saveSettings(StorageSettings(), at: 110)
    try write([json(["type": "assistant", "timestamp": 120, "uuid": "growth-answer", "cwd": "/invented/project"]),
      prompt(.claude, id: "growth-prompt", at: 120),
      json(["type": "tool", "timestamp": 100, "uuid": "growth-refused"])], to: url)
    try write([prompt(.claude, id: "growth-prompt", at: 120)], to: file(.claude, name: "invented-growth-copy.jsonl"))
    let task = AgentLogTask(reader: reader(.claude), storage: store)
    try task.scan(at: 200)
    XCTAssertEqual(task.health.acquiredEvents, 4)
    XCTAssertEqual(task.health.persistedEvents, 3)
    XCTAssertEqual(task.health.stored, 1)
    XCTAssertEqual(task.health.persistedPayloads, 2)
    XCTAssertEqual(task.health.persistedRefusalOccurrences, 1)
    let growth = try store.agentLogGrowth()
    XCTAssertEqual(growth.events, 3)
    XCTAssertEqual(growth.payloads, 2)
    XCTAssertEqual(growth.refusalOccurrences, 1)
    XCTAssertEqual(growth.sourceBytes, task.health.persistedSourceBytes)
    XCTAssertEqual(growth.payloadBytes, task.health.persistedPayloadBytes)
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    XCTAssertEqual(try store.agentLogGrowth(), growth)
    try task.scan(at: 201)
    XCTAssertEqual(task.health.persistedEvents, 3)
  }
}
