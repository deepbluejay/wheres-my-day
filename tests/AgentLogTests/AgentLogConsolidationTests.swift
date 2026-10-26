@testable import Core
@testable import Inbound
@testable import Storage
import Shell
import Foundation
import CryptoKit
import XCTest

extension AgentLogTests {
  func testConsolidatedReducerMatchesOrdinaryProjectionEventAndRecovery() throws {
    for tool in AgentLogTool.allCases {
      var projection = AgentLogState(), event = AgentLogState(), recovery = AgentLogState()
      let records: [[String: Any]] = tool == .claude ? [
        ["type": "system", "sessionId": "invented-a", "cwd": "/invented/project"],
        ["type": "assistant", "sessionId": "invented-b"],
        ["type": "unknown", "sessionId": NSNull()],
        ["type": "tool", "sessionId": "invented-c"],
        ["type": "system", "cwd": "/invented/" + AgentWindowIdentity.relativeFolder],
        ["type": "unknown", "sessionId": ""],
      ] : [
        ["type": "session_meta", "payload": ["id": "invented-a", "cwd": "/invented/project"]],
        ["type": "unknown", "payload": ["thread_id": "invented-b"]],
        ["type": "unknown", "payload": ["thread_id": NSNull()]],
        ["type": "session_meta", "payload": ["session_id": "invented-c"]],
        ["type": "unknown", "payload": ["item": ["originator": AgentWindowIdentity.codexOriginator]]],
        ["type": "session_meta", "payload": [:]],
      ]
      for fields in records {
        let text = try json(fields)
        var metadata = AgentLogMetadata()
        for byte in text.utf8 { metadata.consume(byte) }
        _ = AgentLogParser.parse(text, tool: tool, file: "/invented/source.jsonl", state: &projection, fingerprint: AgentLogFiles.fingerprint)
        _ = AgentLogEventParser.parse(Data(text.utf8), byteCount: text.utf8.count, offset: 0, observedAt: 300,
          tool: tool, file: "/invented/source.jsonl", state: &event, logsRelativePath: nil,
          metadata: metadata, fingerprint: AgentLogFiles.fingerprint)
        metadata.apply(tool: tool, file: "/invented/source.jsonl", state: &recovery, fingerprint: AgentLogFiles.fingerprint)
        XCTAssertEqual(projection, recovery, tool.rawValue)
        XCTAssertEqual(event, recovery, tool.rawValue)
        recovery = try AgentLogState.decode(recovery.encoded())
      }
      XCTAssertNil(recovery.session)
      XCTAssertEqual(recovery.ownedSession?.storedKey, "invented-c")
    }
  }

  private func consolidationEvent(_ tool: AgentLogTool, thread: String, item: String, turn: String = "invented-turn", at time: Int) throws -> AgentLogEvent {
    let fields: [String: Any] = tool == .claude ? [
      "type": "user", "sessionId": thread, "uuid": item, "timestamp": stamp(time),
      "message": ["role": "user", "content": "Invented consolidation instruction"],
    ] : [
      "type": "event_msg", "timestamp": stamp(time), "payload": ["type": "item_completed", "thread_id": thread,
        "turn_id": turn, "item": ["type": "UserMessage", "id": item,
          "content": [["type": "text", "text": "Invented consolidation instruction"]]]],
    ]
    let text = try json(fields)
    var state = AgentLogState()
    return try XCTUnwrap(AgentLogEventParser.parse(Data(text.utf8), byteCount: text.utf8.count, offset: time,
      observedAt: 300, tool: tool, file: root.appendingPathComponent("invented.jsonl").path,
      state: &state, logsRelativePath: nil, fingerprint: AgentLogFiles.fingerprint))
  }
  private func consolidationPosition(_ tool: AgentLogTool, inode: Int = 2) throws -> LogPosition {
    var state = AgentLogState(); state.tool = tool.rawValue
    return try LogPosition(path: root.appendingPathComponent("invented.jsonl").path,
      device: 1, inode: inode, offset: 1000, state: state.encoded(), seenAt: 300)
  }

  func testConsolidatedPlanBindsAllHistoricalCorrespondencesBeforeAnyContent() throws {
    let old = "codex:invented-thread:a:b:c"
    try store.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(50,'prompt','invented-main',?,'','','Invented historical content')", [.key(old)])
    try store.legacyLogAdapter.adoptNativeIdentities()
    try store.saveFixtureSettings(StorageSettings(recordingEnabled: false), at: 130)
    try store.saveFixtureSettings(StorageSettings(), at: 150)
    let early = try consolidationEvent(.codex, thread: "invented-thread:a", item: "c", turn: "b", at: 100)
    let later = try consolidationEvent(.codex, thread: "invented-thread", item: "b:c", turn: "a", at: 140)
    let position = try consolidationPosition(.codex)
    let events = [early, later]
    let evidence = events.compactMap(\.prompt)
    enum Abort: Error { case expected }
    XCTAssertThrowsError(try store.connection.transaction {
      let plan = try store.planLogAdmission(events, evidence: evidence, position: position)
      XCTAssertTrue(plan.events.isEmpty)
      XCTAssertEqual(plan.projections, [false, false])
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_payloads"), 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 1)
      throw Abort.expected
    })
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM forgotten_sources"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_refusals"), 0)
    for ordered in [events, Array(events.reversed())] {
      let result = try store.appendLogEvents(Array(ordered), evidence: ordered.compactMap(\.prompt), position: position)
      XCTAssertEqual(result.stored, 0)
      XCTAssertEqual(result.refused, 2)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
      XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 1)
    }
    let future = try consolidationEvent(.codex, thread: "invented-thread:a", item: "c", turn: "b", at: 200)
    XCTAssertEqual(try store.appendLogEvents([future], evidence: [XCTUnwrap(future.prompt)],
      position: consolidationPosition(.codex, inode: 3)).stored, 0)
  }

  func testConsolidatedStoppedBatchSealsHistoricalProofWithoutContentCorrespondences() throws {
    for (inherited, historical) in [(false, false), (false, true), (true, false), (true, true)] {
      let base = root.appendingPathComponent("stopped-main-\(inherited)-\(historical)")
      try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
      let storage = try ActivityStorage(url: base.appendingPathComponent("invented.sqlite"), appDataDirectory: base, databaseScope: .directory(base))
      try storage.saveSettings(StorageSettings(), at: 0)
      let thread = inherited ? "activityprobe:invented-thread" : "invented-thread"
      let old = "codex:" + thread + ":a:b:c"
      if historical {
        try storage.connection.run("INSERT INTO evidence(ts,kind,source,source_id,document_key,project,text) VALUES(50,'prompt','invented-main',?,'','','Invented historical content')", [.key(old)])
        try storage.legacyLogAdapter.adoptNativeIdentities()
      }
      let stopped: AgentLogEvent
      if inherited {
        var state = AgentLogState()
        let header = try json(["type": "session_meta", "payload": ["id": thread + ":a"]])
        _ = AgentLogEventParser.parse(Data(header.utf8), byteCount: header.utf8.count, offset: 0, observedAt: 300,
          tool: .codex, file: base.appendingPathComponent("invented.jsonl").path, state: &state,
          logsRelativePath: nil, fingerprint: AgentLogFiles.fingerprint)
        let record = try json(["type": "event_msg", "timestamp": stamp(100), "payload": ["type": "item_completed",
          "turn_id": "b", "item": ["type": "UserMessage", "id": "c", "content": [["type": "text", "text": "Invented stopped instruction"]]]]])
        stopped = try XCTUnwrap(AgentLogEventParser.parse(Data(record.utf8), byteCount: record.utf8.count, offset: 100,
          observedAt: 300, tool: .codex, file: base.appendingPathComponent("invented.jsonl").path,
          state: &state, logsRelativePath: nil, fingerprint: AgentLogFiles.fingerprint))
        XCTAssertNotNil(stopped.legacyRefusal.codexThread)
      } else {
        stopped = try consolidationEvent(.codex, thread: thread + ":a", item: "c", turn: "b", at: 100)
      }
      try storage.saveSettings(StorageSettings(recordingEnabled: false), at: 250)
      try storage.appendLogEvents([stopped], evidence: [XCTUnwrap(stopped.prompt)], position: consolidationPosition(.codex))
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_content_keys"), 0)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
      XCTAssertNil(try storage.logPosition(path: consolidationPosition(.codex).path))
      try storage.saveSettings(StorageSettings(), at: 350)
      let future = try consolidationEvent(.codex, thread: thread, item: "b:c", turn: "a", at: 400)
      let cursor = try consolidationPosition(.codex, inode: 3)
      let position = LogPosition(path: cursor.path, device: cursor.device, inode: cursor.inode,
        offset: cursor.offset, state: cursor.state, seenAt: 500)
      let result = try storage.appendLogEvents([future], evidence: [XCTUnwrap(future.prompt)], position: position)
      let expected = historical ? 0 : 1
      XCTAssertEqual(result.logGrowth.events, expected, "Only an actual adopted main class may conservatively join distinct modern tuples")
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_events"), expected)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM agent_log_source_evidence"), expected)
      XCTAssertEqual(try storage.connection.integer("SELECT count(*) FROM evidence"), 1)
    }
  }

  func testConsolidatedWriterRechecksCurrentOffAndPauseWithoutAdvancingCursor() throws {
    for tool in AgentLogTool.allCases {
      let event = try consolidationEvent(tool, thread: "invented-session", item: "invented-item", at: 100)
      let position = try consolidationPosition(tool)
      for settings in [StorageSettings(recordingEnabled: false), StorageSettings(pausedUntil: 400)] {
        try store.saveFixtureSettings(settings, at: 250)
        let result = try store.appendLogEvents([event], evidence: [XCTUnwrap(event.prompt)], position: position)
        XCTAssertEqual(result.stored, 0)
        XCTAssertNil(try store.logPosition(path: position.path))
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_refusals WHERE tool=?", [.key(tool.rawValue)]), 1)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_content_keys"), 0)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_tool_own_sources"), 0)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions"), 0)
        XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_own_baseline_runs"), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(AgentLogOwnSources.folderName).path))
        var future = try XCTUnwrap(event.prompt)
        future.ts = 500; future.source = "invented-future-copy"
        XCTAssertEqual(try store.appendEvidence([future]).stored, 0)
      }
      try store.saveFixtureSettings(StorageSettings(), at: 250)
    }
  }

  func testConsolidatedHistoricalBaselinePrecedesFirstReadAndSurvivesReceiptLoss() throws {
    let registry = AgentLogFiles.ownSources(appDataDirectory: root)
    let own = AgentLogIdentity.decoded("invented-own-session")
    try registry.registerSession(own, tool: .claude)
    try registry.registerSession(AgentLogIdentity.decoded("invented-unseen-own-session"), tool: .claude)
    let ownFile = try file(.claude, home: root.appendingPathComponent("claude"))
    let personal = try file(.claude)
    try write([prompt(.claude, id: "invented-own-home")], to: ownFile)
    try write([try json(["type": "assistant", "sessionId": "invented-own-session", "timestamp": stamp(100),
      "message": ["content": "Invented own receipt"]])], to: personal)
    processes.listed = [AgentLogProcess(pid: 1, tool: .claude)]
    processes.homes = [1: root.appendingPathComponent("claude").path]
    let source = ClaudeAgentLogReader(userHome: root.path, processes: processes, appDataDirectory: root)
    let task = AgentLogTask(reader: source, storage: store)
    try task.scan(at: 300)
    XCTAssertEqual(task.health.acquiredEvents, 0)
    XCTAssertEqual(try store.connection.integer("SELECT receipts FROM agent_log_own_baseline_runs"), 8)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM evidence"), 0)
    let inventory = try registry.inventory()
    XCTAssertEqual(inventory.count, 10) // Initial 8 plus two discovered physical-source receipts.
    try FileManager.default.removeItem(at: root.appendingPathComponent(AgentLogOwnSources.folderName))
    store = nil
    store = try ActivityStorage(url: root.appendingPathComponent("invented.sqlite"), appDataDirectory: root, databaseScope: .directory(root))
    let unseen = AgentLogIdentity.decoded("invented-unseen-own-session").session.subject!
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_revoked_sessions WHERE session_id=?", [.key(unseen)]), 0)
    let event = try consolidationEvent(.claude, thread: "invented-unseen-own-session", item: "invented-new-copy", at: 200)
    let result = try store.appendLogEvents([event], evidence: [XCTUnwrap(event.prompt)], position: consolidationPosition(.claude, inode: 19))
    XCTAssertEqual(result.stored, 0)
    XCTAssertEqual(try store.connection.integer("SELECT count(*) FROM agent_log_events"), 0)
    XCTAssertEqual(try store.connection.integer("SELECT receipts FROM agent_log_own_baseline_runs"), 8)
    let foreign = try consolidationEvent(.codex, thread: "invented-foreign-session", item: "invented-own-home-copy", at: 200)
    var state = AgentLogState(); state.tool = "codex"
    let knownHome = LogPosition(path: root.appendingPathComponent("agent-home/.codex/sessions/unseen.jsonl").path,
      device: 1, inode: 20, offset: 1000, state: try state.encoded(), seenAt: 300)
    XCTAssertEqual(try store.appendLogEvents([foreign], evidence: [XCTUnwrap(foreign.prompt)], position: knownHome).stored, 0)
    XCTAssertFalse(try store.ownLogSources().containsSession(AgentLogIdentity.decoded("invented-foreign-session"), tool: .codex))
  }

  func testConsolidatedReaderEvaluatesPhysicalReceiptsOncePerRead() throws {
    let url = try file(.claude)
    try write(Array(repeating: "{}", count: 1000), to: url)
    let source = try XCTUnwrap(AgentLogFiles.listing([url.deletingLastPathComponent().path]).files.first)
    for restoredLookahead in [false, true] {
      var pathChecks = 0, futureSessionChecks = 0
      let registry = AgentLogOwnSources(appDataDirectory: root, digest: { bytes in
        if bytes.starts(with: Data("claude:path:".utf8)) { pathChecks += 1 }
        if bytes == Data("claude:session:invented-future-session".utf8) { futureSessionChecks += 1 }
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      })
      var state = AgentLogState(); state.tool = "claude"
      state.ownershipSession = restoredLookahead ? AgentLogIdentity.decoded("invented-future-session").session.subject : nil
      state.ownershipScanOffset = restoredLookahead ? source.size : 0
      let position = restoredLookahead ? LogPosition(path: source.path, device: source.device, inode: source.inode,
        offset: 0, state: try state.encoded(), seenAt: 200) : nil
      let batch = try AgentLogFiles.read(source, tool: .claude, position: position, at: 300, ownSources: registry)
      XCTAssertEqual(batch.events.count, 1000)
      XCTAssertEqual(pathChecks, 1, "Physical receipts are checked at the read boundary; the final writer rechecks fresh receipts")
      XCTAssertEqual(futureSessionChecks, restoredLookahead ? 1 : 0, "Independent cursor receipts are checked at the read boundary, not per ordinary record")
    }
  }

  func testConsolidatedLegacyAmbiguityIsVisibleWithoutExposingKeys() throws {
    let key = "codex:invented:a:b:c"
    try store.legacyLogAdapter.indexLegacyLogKey(key)
    let wildcard = "codex:[secret]:invented-turn:invented-item"
    try store.legacyLogAdapter.indexLegacyLogRefusal(wildcard)
    let status = try store.agentLogLegacyStatus()
    XCTAssertEqual(status, "legacy_ambiguous_keys=2 legacy_wildcard_refusals=1")
    XCTAssertFalse(status.contains("invented"))
  }
}
